// =============================================================================
// File        : rtl/t2t_framer.v
// Spec Section: 7.2 (t2t_framer - Stage S2)
// Description : Ethernet beat framer, 2-byte BE length prefix decoder,
//               and 2-beat sliding window block extractor.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module t2t_framer (
    input  wire         clk,
    input  wire         rst,

    // Interface from S1 Ingest (Head of ING FIFO)
    input  wire         i_valid,
    input  wire [511:0] i_data,
    input  wire [63:0]  i_keep,
    input  wire         i_last,
    output reg          o_pop,

    // Flow control & Session
    input  wire         i_hold,
    input  wire         i_init_busy,

    // Block stream to S3 Extract
    output reg          o_blk_valid,
    output reg  [31:0]  o_blk_idx,
    output reg  [7:0]   o_blk_len,
    output reg  [399:0] o_blk_bytes,

    // Diagnostics & Counters
    output reg          o_frame_err,
    output reg          o_keep_err,
    output reg          o_cnt_frame,
    output reg          o_cnt_beat
);

    // FSM States
    localparam [1:0]
        ST_SYNC_WAIT  = 2'd0,
        ST_RUN        = 2'd1,
        ST_DROP_FRAME = 2'd2;

    reg [1:0] state;

    // 2-Beat Window Buffers
    // Beat 0 (Current draining beat)
    reg [511:0] b0_data;
    reg [63:0]  b0_keep;
    reg         b0_last;
    reg         b0_valid;
    reg [6:0]   b0_bytes;     // Number of valid bytes in b0 (1..64)
    reg [6:0]   b0_ptr;       // Current byte read pointer in b0 (0..64)

    // Beat 1 (Lookahead beat)
    reg [511:0] b1_data;
    reg [63:0]  b1_keep;
    reg         b1_last;
    reg         b1_valid;
    reg [6:0]   b1_bytes;

    // Monotonic block index
    reg [31:0] blk_idx_reg;

    // Helper function: count contiguous bytes from tkeep
    function [6:0] count_keep_bytes;
        input [63:0] keep;
        integer k;
        reg [6:0] cnt;
        begin
            cnt = 7'd0;
            for (k = 0; k < 64; k = k + 1) begin
                if (keep[k]) cnt = cnt + 7'd1;
            end
            count_keep_bytes = cnt;
        end
    endfunction

    // Helper function: validate tkeep contiguous ones from LSB
    function is_keep_valid;
        input [63:0] keep;
        input last;
        reg [6:0] n;
        begin
            if (!last) begin
                is_keep_valid = (keep == 64'hFFFF_FFFF_FFFF_FFFF);
            end else begin
                if (keep == 64'd0) begin
                    is_keep_valid = 1'b0;
                end else begin
                    n = count_keep_bytes(keep);
                    if (n == 7'd64) begin
                        is_keep_valid = (keep == 64'hFFFF_FFFF_FFFF_FFFF);
                    end else begin
                        is_keep_valid = (keep == ((64'd1 << n) - 64'd1));
                    end
                end
            end
        end
    endfunction

    // 128-byte window constructed by concatenating b1 and b0
    wire [1023:0] win_data = {b1_data, b0_data};

    // Helper byte extraction from 128-byte window
    function [7:0] get_win_byte;
        input [1023:0] w;
        input [6:0] idx;
        begin
            get_win_byte = w[8*idx +: 8];
        end
    endfunction

    // Available bytes in window starting from b0_ptr
    wire [7:0] b0_remain = (b0_valid && (b0_ptr <= b0_bytes)) ? ({1'b0, b0_bytes} - {1'b0, b0_ptr}) : 8'd0;
    wire [7:0] b1_avail  = b1_valid ? {1'b0, b1_bytes} : 8'd0;
    wire [7:0] total_win_avail = b0_remain + b1_avail;

    // Length prefix parse at b0_ptr
    wire [7:0] pfx_hi = get_win_byte(win_data, b0_ptr);
    wire [7:0] pfx_lo = get_win_byte(win_data, b0_ptr + 7'd1);
    wire [15:0] parsed_len = {pfx_hi, pfx_lo};

    // Does window have complete block?
    // Total block size = 2 (prefix) + parsed_len
    wire [7:0] req_bytes = 8'd2 + parsed_len[7:0];
    wire block_complete = (b0_remain >= 8'd2) &&
                          (parsed_len <= 16'd50) &&
                          (total_win_avail >= req_bytes);

    // Frame end detection
    wire frame_truncated = (b0_valid && b0_last && (b0_remain < req_bytes)) ||
                           (b0_valid && !b0_last && b1_valid && b1_last && (total_win_avail < req_bytes));

    integer b_idx;
    reg [399:0] extracted_payload;

    always @(*) begin
        extracted_payload = 400'd0;
        for (b_idx = 0; b_idx < 50; b_idx = b_idx + 1) begin
            if (b_idx < parsed_len[7:0]) begin
                extracted_payload[8*b_idx +: 8] = get_win_byte(win_data, b0_ptr + 7'd2 + b_idx[6:0]);
            end
        end
    end

    // FSM & Datapath
    always @(posedge clk) begin
        if (rst || i_init_busy) begin
            state        <= ST_RUN;
            b0_data      <= 512'd0;
            b0_keep      <= 64'd0;
            b0_last      <= 1'b0;
            b0_valid     <= 1'b0;
            b0_bytes     <= 7'd0;
            b0_ptr       <= 7'd0;
            b1_data      <= 512'd0;
            b1_keep      <= 64'd0;
            b1_last      <= 1'b0;
            b1_valid     <= 1'b0;
            b1_bytes     <= 7'd0;
            blk_idx_reg  <= 32'd0;
            o_pop        <= 1'b0;
            o_blk_valid  <= 1'b0;
            o_blk_idx    <= 32'd0;
            o_blk_len    <= 8'd0;
            o_blk_bytes  <= 400'd0;
            o_frame_err  <= 1'b0;
            o_keep_err   <= 1'b0;
            o_cnt_frame  <= 1'b0;
            o_cnt_beat   <= 1'b0;
        end else begin
            // Default single-cycle pulse outputs
            o_pop       <= 1'b0;
            o_blk_valid <= 1'b0;
            o_frame_err <= 1'b0;
            o_keep_err  <= 1'b0;
            o_cnt_frame <= 1'b0;
            o_cnt_beat  <= 1'b0;

            // Pipeline stage 1: Pull beats from ING FIFO into b1 when b1 is empty
            if (!b1_valid && i_valid && !o_pop) begin
                // Check tkeep validity immediately
                if (!is_keep_valid(i_keep, i_last)) begin
                    o_keep_err <= 1'b1;
                    o_pop      <= 1'b1;
                    state      <= i_last ? ST_RUN : ST_DROP_FRAME;
                    // Invalidate buffers on keep error
                    b0_valid   <= 1'b0;
                    b1_valid   <= 1'b0;
                end else begin
                    b1_data  <= i_data;
                    b1_keep  <= i_keep;
                    b1_last  <= i_last;
                    b1_valid <= 1'b1;
                    b1_bytes <= count_keep_bytes(i_keep);
                    o_pop    <= 1'b1;
                    o_cnt_beat <= 1'b1;
                    if (i_last) o_cnt_frame <= 1'b1;
                end
            end

            // Main FSM
            case (state)
                ST_SYNC_WAIT: begin
                    if (b0_valid) begin
                        if (b0_last) begin
                            b0_valid <= 1'b0;
                            state    <= ST_RUN;
                        end else begin
                            b0_valid <= 1'b0;
                        end
                    end else if (b1_valid) begin
                        b0_data  <= b1_data;
                        b0_keep  <= b1_keep;
                        b0_last  <= b1_last;
                        b0_valid <= 1'b1;
                        b0_bytes <= b1_bytes;
                        b0_ptr   <= 7'd0;
                        b1_valid <= 1'b0;
                    end
                end

                ST_DROP_FRAME: begin
                    if (b0_valid) begin
                        if (b0_last) state <= ST_RUN;
                        b0_valid <= 1'b0;
                    end else if (b1_valid) begin
                        if (b1_last) state <= ST_RUN;
                        b1_valid <= 1'b0;
                    end
                end

                ST_RUN: begin
                    if (!b0_valid) begin
                        if (b1_valid) begin
                            b0_data  <= b1_data;
                            b0_keep  <= b1_keep;
                            b0_last  <= b1_last;
                            b0_valid <= 1'b1;
                            b0_bytes <= b1_bytes;
                            b0_ptr   <= 7'd0;
                            b1_valid <= 1'b0;
                        end
                    end else begin
                        if (b0_ptr >= b0_bytes) begin
                            if (b1_valid) begin
                                b0_data  <= b1_data;
                                b0_keep  <= b1_keep;
                                b0_last  <= b1_last;
                                b0_valid <= 1'b1;
                                b0_bytes <= b1_bytes;
                                b0_ptr   <= b0_ptr - b0_bytes;
                                b1_valid <= 1'b0;
                            end else begin
                                b0_valid <= 1'b0;
                            end
                        end else begin
                            if (total_win_avail < 8'd2) begin
                                if (b0_last) begin
                                    o_frame_err <= 1'b1;
                                    b0_valid    <= 1'b0;
                                    state       <= ST_RUN;
                                end
                            end else begin
                                if (parsed_len > 16'd50) begin
                                    o_frame_err <= 1'b1;
                                    state       <= b0_last ? ST_RUN : ST_DROP_FRAME;
                                    b0_valid    <= 1'b0;
                                    b1_valid    <= 1'b0;
                                end else if (frame_truncated) begin
                                    o_frame_err <= 1'b1;
                                    state       <= ST_RUN;
                                    b0_valid    <= 1'b0;
                                    b1_valid    <= 1'b0;
                                end else if (block_complete) begin
                                    if (!i_hold) begin
                                        o_blk_valid <= 1'b1;
                                        o_blk_idx   <= blk_idx_reg;
                                        o_blk_len   <= parsed_len[7:0];
                                        o_blk_bytes <= extracted_payload;
                                        blk_idx_reg <= blk_idx_reg + 32'd1;

                                        if ({1'b0, b0_ptr} + req_bytes < {1'b0, b0_bytes}) begin
                                            b0_ptr <= b0_ptr + req_bytes[6:0];
                                        end else begin
                                            if (b1_valid) begin
                                                b0_data  <= b1_data;
                                                b0_keep  <= b1_keep;
                                                b0_last  <= b1_last;
                                                b0_valid <= 1'b1;
                                                b0_bytes <= b1_bytes;
                                                b0_ptr   <= (b0_ptr + req_bytes[6:0]) - b0_bytes;
                                                b1_valid <= 1'b0;
                                            end else begin
                                                b0_ptr   <= b0_ptr + req_bytes[6:0];
                                                b0_valid <= 1'b0;
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                default: state <= ST_RUN;
            endcase
        end
    end

endmodule
