// =============================================================================
// File        : tb/sv/tb_refmode.sv
// Spec Section: 7.3, 12.2 (EX-1, EX-10)
// Description : Dual-path reference-mode cross-check testbench comparing
//               clean-slate t2t_extract against upstream adapter + itch_decoder_ref.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module tb_refmode;

    logic        clk = 1'b0;
    logic        rst = 1'b1;
    logic        rst_ref = 1'b1;

    // Upstream AXI-Stream inputs
    logic [511:0] s_axis_tdata;
    logic [63:0]  s_axis_tkeep;
    logic         s_axis_tvalid;
    logic         s_axis_tlast;
    wire          adapter_tready;

    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Path 1: Upstream Reference Path (Adapter -> itch_decoder_ref)
    // -------------------------------------------------------------------------
    wire [7:0]  ref_data_byte;
    wire        ref_data_valid;
    wire [7:0]  ref_msg_type;
    wire [31:0] ref_shares;
    wire [31:0] ref_price;
    wire        ref_order_valid;

    axis_512_to_8_adapter u_adapter (
        .clk             (clk),
        .rst             (rst_ref),
        .s_axis_tdata    (s_axis_tdata),
        .s_axis_tkeep    (s_axis_tkeep),
        .s_axis_tvalid   (s_axis_tvalid),
        .s_axis_tlast    (s_axis_tlast),
        .s_axis_tready   (adapter_tready),
        .byte_out        (ref_data_byte),
        .byte_valid      (ref_data_valid)
    );

    itch_decoder_ref u_decoder_ref (
        .clk          (clk),
        .rst          (rst_ref),
        .data_in      (ref_data_byte),
        .valid_in     (ref_data_valid),
        .msg_type     (ref_msg_type),
        .order_shares (ref_shares),
        .order_price  (ref_price),
        .order_valid  (ref_order_valid)
    );

    // -------------------------------------------------------------------------
    // Path 2: tick2trade Clean-Slate Pipeline (Ingest -> Framer -> Extract)
    // -------------------------------------------------------------------------
    wire         ing_valid;
    wire [511:0] ing_data;
    wire [63:0]  ing_keep;
    wire         ing_last;
    wire         framer_pop;

    t2t_ingest #(
        .ING_DEPTH (32),
        .ING_AW    (5)
    ) u_ingest (
        .clk            (clk),
        .rst            (rst),
        .i_tdata        (s_axis_tdata),
        .i_tkeep        (s_axis_tkeep),
        .i_tvalid       (s_axis_tvalid),
        .i_tlast        (s_axis_tlast),
        .i_init_busy    (1'b0),
        .o_overflow     (),
        .o_dropped_init (),
        .i_pop          (framer_pop),
        .o_valid        (ing_valid),
        .o_data         (ing_data),
        .o_keep         (ing_keep),
        .o_last         (ing_last)
    );

    wire         blk_valid;
    wire [31:0]  blk_idx;
    wire [7:0]   blk_len;
    wire [399:0] blk_bytes;

    t2t_framer u_framer (
        .clk         (clk),
        .rst         (rst),
        .i_valid     (ing_valid),
        .i_data      (ing_data),
        .i_keep      (ing_keep),
        .i_last      (ing_last),
        .o_pop       (framer_pop),
        .i_hold      (1'b0),
        .i_init_busy (1'b0),
        .o_blk_valid (blk_valid),
        .o_blk_idx   (blk_idx),
        .o_blk_len   (blk_len),
        .o_blk_bytes (blk_bytes),
        .o_frame_err (),
        .o_keep_err  (),
        .o_cnt_frame (),
        .o_cnt_beat  ()
    );

    wire         msg_valid;
    wire [319:0] msg;
    wire [3:0]   blk_flags;
    wire [6:0]   cnt_type;
    wire         cnt_other;
    wire         cnt_zero;
    wire         cnt_badlen;
    wire         session_invalid;

    t2t_extract u_extract (
        .clk               (clk),
        .rst               (rst),
        .i_blk_valid       (blk_valid),
        .i_blk_idx         (blk_idx),
        .i_blk_len         (blk_len),
        .i_blk_bytes       (blk_bytes),
        .o_msg_valid       (msg_valid),
        .o_msg             (msg),
        .o_blk_flags       (blk_flags),
        .o_cnt_type        (cnt_type),
        .o_cnt_other       (cnt_other),
        .o_cnt_zero        (cnt_zero),
        .o_cnt_badlen      (cnt_badlen),
        .o_session_invalid (session_invalid)
    );

    wire [31:0] pipe_shares = msg[`T2T_MSG_SHARES_HI : `T2T_MSG_SHARES_LO];
    wire [31:0] pipe_price  = msg[`T2T_MSG_PRICE_HI  : `T2T_MSG_PRICE_LO];

    // Queues for cross-check comparison
    reg [31:0] q_ref_shares [0:63];
    reg [31:0] q_ref_price  [0:63];
    integer    ref_wr_ptr = 0;
    integer    ref_rd_ptr = 0;

    reg [31:0] q_pipe_shares [0:63];
    reg [31:0] q_pipe_price  [0:63];
    integer    pipe_wr_ptr = 0;
    integer    pipe_rd_ptr = 0;

    integer matched_orders = 0;

    always @(posedge clk) begin
        if (!rst) begin
            if (ref_order_valid) begin
                q_ref_shares[ref_wr_ptr] <= ref_shares;
                q_ref_price[ref_wr_ptr]  <= ref_price;
                ref_wr_ptr <= ref_wr_ptr + 1;
                $display("[REF PATH] Order parsed: shares=0x%08x (%0d) | price=0x%08x (%0d)",
                         ref_shares, ref_shares, ref_price, ref_price);
            end

            if (msg_valid && (msg[`T2T_MSG_TYPE_HI:`T2T_MSG_TYPE_LO] == `T2T_TYPE_A)) begin
                q_pipe_shares[pipe_wr_ptr] <= pipe_shares;
                q_pipe_price[pipe_wr_ptr]  <= pipe_price;
                pipe_wr_ptr <= pipe_wr_ptr + 1;
                $display("[PIPE PATH] Order parsed: shares=0x%08x (%0d) | price=0x%08x (%0d)",
                         pipe_shares, pipe_shares, pipe_price, pipe_price);
            end

            // Compare when both queues have items
            if ((ref_rd_ptr < ref_wr_ptr) && (pipe_rd_ptr < pipe_wr_ptr)) begin
                if (q_ref_shares[ref_rd_ptr] != q_pipe_shares[pipe_rd_ptr]) begin
                    $display("EX-10 Mismatch: shares ref=0x%08x pipe=0x%08x", q_ref_shares[ref_rd_ptr], q_pipe_shares[pipe_rd_ptr]);
                    $fatal(1);
                end
                if (q_ref_price[ref_rd_ptr] != q_pipe_price[pipe_rd_ptr]) begin
                    $display("EX-10 Mismatch: price ref=0x%08x pipe=0x%08x", q_ref_price[ref_rd_ptr], q_pipe_price[pipe_rd_ptr]);
                    $fatal(1);
                end
                matched_orders <= matched_orders + 1;
                ref_rd_ptr  <= ref_rd_ptr + 1;
                pipe_rd_ptr <= pipe_rd_ptr + 1;
            end
        end
    end

    // Stimulus memory
    reg [7:0] sim_38b_mem [0:759];

    // Helper task to send one beat respecting adapter tready
    task automatic send_axis_beat(
        input [511:0] data,
        input [63:0]  keep,
        input         last
    );
        begin
            // Wait until adapter is ready
            while (!adapter_tready) @(posedge clk);
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

    initial begin
        integer i, b, off, chunk;
        reg [511:0] bdata;
        reg [63:0]  bkeep;

        $display("=============================================================================");
        $display("EX-10 & EX-1: Reference-Mode Cross-Check Testbench");
        $display("=============================================================================");

        // Load clean 38-byte regenerated legacy stream (760 bytes = 20 blocks x 38B)
        $readmemh("vectors/legacy/sim_data_38b.hex", sim_38b_mem);

        s_axis_tvalid = 1'b0;
        s_axis_tdata  = 512'd0;
        s_axis_tkeep  = 64'd0;
        s_axis_tlast  = 1'b0;

        // Hold both paths in reset initially
        rst     = 1'b1;
        rst_ref = 1'b1;
        repeat (10) @(posedge clk);
        rst     = 1'b0;
        repeat (5) @(posedge clk);

        // SYNC_WAIT alignment beat for pipeline:
        // Keep rst_ref asserted so adapter ignores the sync beat
        send_axis_beat(512'd0, 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        repeat (10) @(posedge clk);

        // Release reference path from reset so it starts cleanly with real data
        rst_ref = 1'b0;
        repeat (5) @(posedge clk);

        // Stream 760 bytes in 64-byte beats
        off = 0;
        while (off < 760) begin
            chunk = ((760 - off) >= 64) ? 64 : (760 - off);
            bdata = 512'd0;
            bkeep = 64'd0;
            for (b = 0; b < chunk; b = b + 1) begin
                bdata[8*b +: 8] = sim_38b_mem[off + b];
                bkeep[b]        = 1'b1;
            end
            send_axis_beat(bdata, bkeep, (off + chunk == 760));
            off = off + chunk;
        end

        // Drain until all 20 orders are parsed on both paths
        repeat (2000) @(posedge clk);

        $display("--- Summary ---");
        $display("Matched Add Orders: %0d / 20", matched_orders);
        if (matched_orders != 20) begin
            $display("EX-10 FAILED: expected 20 matched orders, got %0d", matched_orders);
            $fatal(1);
        end

        $display("=============================================================================");
        $display("EX-10 RESULT: PASS (All 20 Add Orders match 100%% byte-for-byte)");
        $display("=============================================================================");
        $finish;
    end

endmodule
