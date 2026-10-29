// =============================================================================
// File        : formal/fp_book.sv
// Spec Section: 9.1 (Invariants 3, 4), 12.3 (FP-2, FP-6)
// Description : Formal property wrapper for t2t_book verifying corrupt stickiness
//               (FP-2) and book ladder monotonicity / zero-beyond-lv invariants (FP-6).
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module fp_book (
    input wire clk,
    input wire rst,
    input wire i_op_valid,
    input wire [104:0] i_op,
    input wire i_init_busy
);

    localparam N = 2; // Scaled BOOK_N for bounded formal model checking

    wire        o_fb_pop;
    wire        o_upd_valid;
    wire [3:0]  o_upd_sym;
    wire [31:0] o_upd_idx;
    wire        o_upd_last;
    wire [31:0] o_upd_bid_px;
    wire [31:0] o_upd_bid_qty;
    wire [31:0] o_upd_ask_px;
    wire [31:0] o_upd_ask_qty;
    wire [3:0]  o_upd_bid_lv;
    wire [3:0]  o_upd_ask_lv;
    wire        o_upd_bid_stale;
    wire        o_upd_ask_stale;
    wire        o_upd_corrupt;
    wire [31:0] o_upd_seq;

    t2t_book #(
        .BOOK_N    (N),
        .N_SYMBOLS (1)
    ) dut (
        .clk                  (clk),
        .rst                  (rst),
        .i_op_valid           (i_op_valid),
        .i_op                 (i_op),
        .o_fb_pop             (o_fb_pop),
        .i_init_busy          (i_init_busy),
        .o_upd_valid          (o_upd_valid),
        .o_upd_sym            (o_upd_sym),
        .o_upd_idx            (o_upd_idx),
        .o_upd_last           (o_upd_last),
        .o_upd_bid_px         (o_upd_bid_px),
        .o_upd_bid_qty        (o_upd_bid_qty),
        .o_upd_ask_px         (o_upd_ask_px),
        .o_upd_ask_qty        (o_upd_ask_qty),
        .o_upd_bid_lv         (o_upd_bid_lv),
        .o_upd_ask_lv         (o_upd_ask_lv),
        .o_upd_bid_stale      (o_upd_bid_stale),
        .o_upd_ask_stale      (o_upd_ask_stale),
        .o_upd_corrupt        (o_upd_corrupt),
        .o_upd_seq            (o_upd_seq),
        .o_bk_tob_flat        (),
        .o_cnt_ops            (),
        .o_cnt_same_key_bubbles (),
        .o_cnt_corrupt_events (),
        .o_cnt_hidden_adds    (),
        .o_cnt_evictions      (),
        .o_cnt_upd_total      (),
        .o_cnt_upd_with_stale ()
    );

    // Initial reset sequence assumption
    reg [2:0] reset_cnt = 3'd0;
    always @(posedge clk) begin
        if (reset_cnt < 3'd4) reset_cnt <= reset_cnt + 3'd1;
    end
    always @(*) begin
        if (reset_cnt < 3'd2) assume(rst);
        else assume(!rst);
    end

`ifdef FORMAL
    // -------------------------------------------------------------------------
    // FP-2: corrupt[sym] is sticky until session reset
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if ($past(!rst) && $past(!i_init_busy) && !rst && !i_init_busy) begin
            if ($past(dut.sym_corrupt[0])) begin
                assert(dut.sym_corrupt[0]);
            end
        end
    end

    // -------------------------------------------------------------------------
    // FP-6: Book Invariants 9.1 items 3 and 4
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst && !i_init_busy) begin
            // 1. Capacity
            assert(dut.lad_lv[0] <= N);
            assert(dut.lad_lv[1] <= N);

            // 2. Levels within lv have qty > 0 and cnt > 0
            if (dut.lad_lv[0] >= 4'd1) begin
                assert(dut.lad_qty[0][0] > 32'd0);
                assert(dut.lad_cnt[0][0] > 16'd0);
            end
            if (dut.lad_lv[0] >= 4'd2) begin
                assert(dut.lad_qty[0][1] > 32'd0);
                assert(dut.lad_cnt[0][1] > 16'd0);
                // Bid monotonicity: strictly descending
                assert(dut.lad_px[0][0] > dut.lad_px[0][1]);
            end

            // 3. Entries beyond lv are 0
            if (dut.lad_lv[0] == 4'd0) begin
                assert(dut.lad_px[0][0] == 32'd0);
                assert(dut.lad_qty[0][0] == 32'd0);
                assert(dut.lad_cnt[0][0] == 16'd0);
                assert(dut.lad_px[0][1] == 32'd0);
                assert(dut.lad_qty[0][1] == 32'd0);
                assert(dut.lad_cnt[0][1] == 16'd0);
            end else if (dut.lad_lv[0] == 4'd1) begin
                assert(dut.lad_px[0][1] == 32'd0);
                assert(dut.lad_qty[0][1] == 32'd0);
                assert(dut.lad_cnt[0][1] == 16'd0);
            end

            // Ask side (key 1)
            if (dut.lad_lv[1] >= 4'd1) begin
                assert(dut.lad_qty[1][0] > 32'd0);
                assert(dut.lad_cnt[1][0] > 16'd0);
            end
            if (dut.lad_lv[1] >= 4'd2) begin
                assert(dut.lad_qty[1][1] > 32'd0);
                assert(dut.lad_cnt[1][1] > 16'd0);
                // Ask monotonicity: strictly ascending
                assert(dut.lad_px[1][0] < dut.lad_px[1][1]);
            end
            if (dut.lad_lv[1] == 4'd0) begin
                assert(dut.lad_px[1][0] == 32'd0);
                assert(dut.lad_qty[1][0] == 32'd0);
                assert(dut.lad_cnt[1][0] == 16'd0);
                assert(dut.lad_px[1][1] == 32'd0);
                assert(dut.lad_qty[1][1] == 32'd0);
                assert(dut.lad_cnt[1][1] == 16'd0);
            end else if (dut.lad_lv[1] == 4'd1) begin
                assert(dut.lad_px[1][1] == 32'd0);
                assert(dut.lad_qty[1][1] == 32'd0);
                assert(dut.lad_cnt[1][1] == 16'd0);
            end
        end
    end
`endif

endmodule
