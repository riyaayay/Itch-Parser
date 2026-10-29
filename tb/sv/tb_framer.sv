// =============================================================================
// File        : tb/sv/tb_framer.sv
// Spec Section: 7.1, 7.2, 12.2 (FR-1 sub-cases a through m)
// Description : Unit testbench for t2t_ingest and t2t_framer verifying all 13
//               normative framing and boundary cases.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module tb_framer;

    logic         clk = 1'b0;
    logic         rst = 1'b1;

    // Ingest inputs
    logic [511:0] s_axis_tdata;
    logic [63:0]  s_axis_tkeep;
    logic         s_axis_tvalid;
    logic         s_axis_tlast;
    logic         init_busy = 1'b0;

    // Ingest outputs / Framer inputs
    wire          ing_overflow;
    wire          ing_dropped_init;
    wire          ing_valid;
    wire  [511:0] ing_data;
    wire  [63:0]  ing_keep;
    wire          ing_last;
    wire          framer_pop;

    // Framer controls & outputs
    logic         hold = 1'b0;
    wire          blk_valid;
    wire  [31:0]  blk_idx;
    wire  [7:0]   blk_len;
    wire  [399:0] blk_bytes;
    wire          frame_err;
    wire          keep_err;
    wire          cnt_frame;
    wire          cnt_beat;

    always #5 clk = ~clk;

    // Instantiate S1 Ingest
    t2t_ingest #(
        .ING_DEPTH (16),
        .ING_AW    (4)
    ) u_ingest (
        .clk            (clk),
        .rst            (rst),
        .i_tdata        (s_axis_tdata),
        .i_tkeep        (s_axis_tkeep),
        .i_tvalid       (s_axis_tvalid),
        .i_tlast        (s_axis_tlast),
        .i_init_busy    (init_busy),
        .o_overflow     (ing_overflow),
        .o_dropped_init (ing_dropped_init),
        .i_pop          (framer_pop),
        .o_valid        (ing_valid),
        .o_data         (ing_data),
        .o_keep         (ing_keep),
        .o_last         (ing_last)
    );

    // Instantiate S2 Framer
    t2t_framer u_framer (
        .clk         (clk),
        .rst         (rst),
        .i_valid     (ing_valid),
        .i_data      (ing_data),
        .i_keep      (ing_keep),
        .i_last      (ing_last),
        .o_pop       (framer_pop),
        .i_hold      (hold),
        .i_init_busy (init_busy),
        .o_blk_valid (blk_valid),
        .o_blk_idx   (blk_idx),
        .o_blk_len   (blk_len),
        .o_blk_bytes (blk_bytes),
        .o_frame_err (frame_err),
        .o_keep_err  (keep_err),
        .o_cnt_frame (cnt_frame),
        .o_cnt_beat  (cnt_beat)
    );

    // Monitored captures
    integer blocks_received = 0;
    integer frame_err_count = 0;
    integer keep_err_count  = 0;

    always @(posedge clk) begin
        if (!rst) begin
            if (blk_valid) begin
                blocks_received <= blocks_received + 1;
                $display("[FR-MON] t=%0t | blk_idx=%0d | len=%0d | type=0x%02x ('%c')",
                         $time, blk_idx, blk_len, blk_bytes[7:0], blk_bytes[7:0]);
            end
            if (frame_err) frame_err_count <= frame_err_count + 1;
            if (keep_err)  keep_err_count  <= keep_err_count + 1;
        end
    end

    // Task to send one 64-byte beat
    task automatic send_beat(
        input [511:0] data,
        input [63:0]  keep,
        input         last
    );
        begin
            @(posedge clk);
            s_axis_tvalid = 1'b1;
            s_axis_tdata  = data;
            s_axis_tkeep  = keep;
            s_axis_tlast  = last;
            @(posedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tdata  = 512'd0;
            s_axis_tkeep  = 64'd0;
            s_axis_tlast  = 1'b0;
        end
    endtask

    // Helper to build a 64-byte buffer
    reg [7:0] beat_buf [0:63];

    function [511:0] pack_buf;
        input integer dummy;
        integer b;
        reg [511:0] packed_val;
        begin
            packed_val = 512'd0;
            for (b = 0; b < 64; b = b + 1) begin
                packed_val[8*b +: 8] = beat_buf[b];
            end
            pack_buf = packed_val;
        end
    endfunction

    initial begin
        integer i, prev_blk_cnt;
        $display("=============================================================================");
        $display("FR-1: Framer Comprehensive Unit Testbench (Sub-cases a through m)");
        $display("=============================================================================");

        s_axis_tvalid = 1'b0;
        s_axis_tdata  = 512'd0;
        s_axis_tkeep  = 64'd0;
        s_axis_tlast  = 1'b0;
        hold          = 1'b0;
        init_busy     = 1'b0;

        // Reset sequence
        rst = 1'b1;
        repeat (10) @(posedge clk);
        rst = 1'b0;
        repeat (10) @(posedge clk);

        // SYNC_WAIT alignment beat (to clear ST_SYNC_WAIT)
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        repeat (5) @(posedge clk);

        // ---------------------------------------------------------------------
        // FR-1(a): One block per beat (e.g. 38-byte block in 64-byte beat)
        // ---------------------------------------------------------------------
        $display("--- Testing FR-1(a): One block per beat ---");
        prev_blk_cnt = blocks_received;
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        beat_buf[0] = 8'h00; beat_buf[1] = 8'd36; beat_buf[2] = 8'h41; // 'A'
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        repeat (10) @(posedge clk);
        assert(blocks_received == prev_blk_cnt + 1) else $fatal(1, "FR-1(a) failed");

        // ---------------------------------------------------------------------
        // FR-1(b): Several blocks per beat (e.g. two 21-byte blocks in 64B beat)
        // Block 1: offset 0..20 (len=19, prefix 0x0013)
        // Block 2: offset 21..41 (len=19, prefix 0x0013)
        // ---------------------------------------------------------------------
        $display("--- Testing FR-1(b): Several blocks per beat ---");
        prev_blk_cnt = blocks_received;
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        beat_buf[0]  = 8'h00; beat_buf[1]  = 8'd19; beat_buf[2]  = 8'h44; // 'D'
        beat_buf[21] = 8'h00; beat_buf[22] = 8'd19; beat_buf[23] = 8'h44; // 'D'
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        repeat (10) @(posedge clk);
        assert(blocks_received == prev_blk_cnt + 2) else $fatal(1, "FR-1(b) failed");

        // ---------------------------------------------------------------------
        // FR-1(c): Block straddling two beats
        // Beat 1: 50 bytes of padding, then 2B prefix + 12B of block
        // Beat 2: Remaining 24B of block + rest padding
        // ---------------------------------------------------------------------
        $display("--- Testing FR-1(c): Block straddling two beats ---");
        prev_blk_cnt = blocks_received;
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        beat_buf[50] = 8'h00; beat_buf[51] = 8'd36; beat_buf[52] = 8'h41; // 'A'
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b0); // not last

        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1); // last
        repeat (15) @(posedge clk);
        assert(blocks_received == prev_blk_cnt + 1) else $fatal(1, "FR-1(c) failed");

        // ---------------------------------------------------------------------
        // FR-1(d): Block ending exactly at a beat end
        // Block of 38 bytes starting at offset 26 (26 + 38 = 64)
        // ---------------------------------------------------------------------
        $display("--- Testing FR-1(d): Block ending exactly at beat end ---");
        prev_blk_cnt = blocks_received;
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        beat_buf[26] = 8'h00; beat_buf[27] = 8'd36; beat_buf[28] = 8'h41; // 'A'
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        repeat (10) @(posedge clk);
        assert(blocks_received == prev_blk_cnt + 1) else $fatal(1, "FR-1(d) failed");

        // ---------------------------------------------------------------------
        // FR-1(e): Partial last tkeep (e.g. 38 bytes on last beat)
        // ---------------------------------------------------------------------
        $display("--- Testing FR-1(e): Partial last tkeep ---");
        prev_blk_cnt = blocks_received;
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        beat_buf[0] = 8'h00; beat_buf[1] = 8'd36; beat_buf[2] = 8'h41; // 'A'
        send_beat(pack_buf(0), (64'd1 << 38) - 64'd1, 1'b1);
        repeat (10) @(posedge clk);
        assert(blocks_received == prev_blk_cnt + 1) else $fatal(1, "FR-1(e) failed");

        // ---------------------------------------------------------------------
        // FR-1(f): Zero-length block (len == 0)
        // ---------------------------------------------------------------------
        $display("--- Testing FR-1(f): Zero-length block ---");
        prev_blk_cnt = blocks_received;
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        beat_buf[0] = 8'h00; beat_buf[1] = 8'h00; // len = 0
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        repeat (10) @(posedge clk);
        assert(blocks_received == prev_blk_cnt + 1) else $fatal(1, "FR-1(f) failed");

        // ---------------------------------------------------------------------
        // FR-1(g): Unhandled type (len 39, type 'R')
        // ---------------------------------------------------------------------
        $display("--- Testing FR-1(g): Unhandled type ---");
        prev_blk_cnt = blocks_received;
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        beat_buf[0] = 8'h00; beat_buf[1] = 8'd39; beat_buf[2] = 8'h52; // 'R'
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        repeat (10) @(posedge clk);
        assert(blocks_received == prev_blk_cnt + 1) else $fatal(1, "FR-1(g) failed");

        // ---------------------------------------------------------------------
        // FR-1(h): len 51 gives frame_err, rest of frame dropped, next frame ok
        // ---------------------------------------------------------------------
        $display("--- Testing FR-1(h): len 51 frame_err ---");
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        beat_buf[0] = 8'h00; beat_buf[1] = 8'd51; // len 51 > 50!
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b0); // not last
        repeat (5) @(posedge clk);
        assert(frame_err_count >= 1) else $fatal(1, "FR-1(h) expected frame_err");

        // Send remaining beat with tlast to complete dropped frame
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        repeat (5) @(posedge clk);

        // Next frame decoded cleanly
        prev_blk_cnt = blocks_received;
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        beat_buf[0] = 8'h00; beat_buf[1] = 8'd36; beat_buf[2] = 8'h41;
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        repeat (10) @(posedge clk);
        assert(blocks_received == prev_blk_cnt + 1) else $fatal(1, "FR-1(h) recovery failed");

        // ---------------------------------------------------------------------
        // FR-1(i): Non-contiguous last tkeep gives keep_err
        // ---------------------------------------------------------------------
        $display("--- Testing FR-1(i): Non-contiguous last tkeep ---");
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        send_beat(pack_buf(0), 64'h0000_0000_0000_0005, 1'b1);
        repeat (5) @(posedge clk);
        assert(keep_err_count >= 1) else $fatal(1, "FR-1(i) expected keep_err");

        // ---------------------------------------------------------------------
        // FR-1(j): Short tkeep mid-frame gives keep_err
        // ---------------------------------------------------------------------
        $display("--- Testing FR-1(j): Short tkeep mid-frame ---");
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        send_beat(pack_buf(0), 64'h0000_FFFF_FFFF_FFFF, 1'b0);
        repeat (5) @(posedge clk);
        assert(keep_err_count >= 2) else $fatal(1, "FR-1(j) expected keep_err");

        // Finish dropping the frame
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        repeat (5) @(posedge clk);

        // ---------------------------------------------------------------------
        // FR-1(k): Overload fills ING -> ingest_overflow
        // ---------------------------------------------------------------------
        $display("--- Testing FR-1(k): Ingest FIFO overflow ---");
        hold = 1'b1;
        for (i = 0; i < 25; i = i + 1) begin
            send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b0);
        end
        repeat (5) @(posedge clk);
        assert(ing_overflow == 1'b1) else $fatal(1, "FR-1(k) expected ing_overflow");
        hold = 1'b0;
        repeat (50) @(posedge clk);

        // ---------------------------------------------------------------------
        // FR-1(l): i_hold for many cycles loses nothing
        // ---------------------------------------------------------------------
        $display("--- Testing FR-1(l): i_hold backpressure ---");
        hold = 1'b1;
        prev_blk_cnt = blocks_received;
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        beat_buf[0] = 8'h00; beat_buf[1] = 8'd36; beat_buf[2] = 8'h41;
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        repeat (20) @(posedge clk);
        assert(blocks_received == prev_blk_cnt) else $fatal(1, "FR-1(l) issued block while hold=1");
        hold = 1'b0;
        repeat (20) @(posedge clk);
        assert(blocks_received == prev_blk_cnt + 1) else $fatal(1, "FR-1(l) failed to drain after hold=0");

        // ---------------------------------------------------------------------
        // FR-1(m): Reset in middle of burst, then SYNC_WAIT realigns
        // ---------------------------------------------------------------------
        $display("--- Testing FR-1(m): Mid-burst reset & SYNC_WAIT realignment ---");
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b0);
        @(posedge clk);
        rst = 1'b1;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        repeat (10) @(posedge clk);

        prev_blk_cnt = blocks_received;
        for (i = 0; i < 64; i = i + 1) beat_buf[i] = 8'h00;
        beat_buf[0] = 8'h00; beat_buf[1] = 8'd36; beat_buf[2] = 8'h41;
        send_beat(pack_buf(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        repeat (15) @(posedge clk);
        assert(blocks_received == prev_blk_cnt + 1) else $fatal(1, "FR-1(m) failed realignment");

        $display("=============================================================================");
        $display("FR-1 RESULT: PASS (All sub-cases a through m verified successfully)");
        $display("=============================================================================");
        $finish;
    end

endmodule
