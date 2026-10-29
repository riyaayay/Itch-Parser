// =============================================================================
// File        : formal/fp_trigger.sv
// Spec Section: 10.1, 12.3 (FP-3)
// Description : Formal property wrapper for t2t_trigger verifying that
//               trigger emits nothing when Precondition P is false (FP-3).
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module fp_trigger (
    input wire clk,
    input wire rst,
    input wire i_global_enable,
    input wire i_session_invalid,
    input wire [`T2T_TCFG_SYM_W-1:0] i_tcfg_sym0,
    input wire i_upd_valid,
    input wire [3:0] i_upd_sym,
    input wire [31:0] i_upd_idx,
    input wire i_upd_last,
    input wire [31:0] i_upd_bid_px,
    input wire [31:0] i_upd_bid_qty,
    input wire [31:0] i_upd_ask_px,
    input wire [31:0] i_upd_ask_qty,
    input wire [3:0] i_upd_bid_lv,
    input wire [3:0] i_upd_ask_lv,
    input wire i_upd_bid_stale,
    input wire i_upd_ask_stale,
    input wire i_upd_corrupt,
    input wire [31:0] i_upd_seq
);

    wire        o_cand_valid;
    wire [3:0]  o_cand_sym;
    wire        o_cand_side;
    wire [31:0] o_cand_price;
    wire [15:0] o_cand_qty;
    wire [1:0]  o_cand_rule;
    wire [31:0] o_cand_idx;
    wire        o_cnt_cand;

    // Single-symbol instantiation for formal model checking
    wire [8*`T2T_TCFG_SYM_W-1:0] full_tcfg = {{(7*`T2T_TCFG_SYM_W){1'b0}}, i_tcfg_sym0};

    t2t_trigger #(
        .N_SYMBOLS(1)
    ) dut (
        .clk               (clk),
        .rst               (rst),
        .i_global_enable   (i_global_enable),
        .i_session_invalid (i_session_invalid),
        .i_tcfg            (full_tcfg[1*`T2T_TCFG_SYM_W-1:0]),
        .i_upd_valid       (i_upd_valid),
        .i_upd_sym         (i_upd_sym),
        .i_upd_idx         (i_upd_idx),
        .i_upd_last        (i_upd_last),
        .i_upd_bid_px      (i_upd_bid_px),
        .i_upd_bid_qty     (i_upd_bid_qty),
        .i_upd_ask_px      (i_upd_ask_px),
        .i_upd_ask_qty     (i_upd_ask_qty),
        .i_upd_bid_lv      (i_upd_bid_lv),
        .i_upd_ask_lv      (i_upd_ask_lv),
        .i_upd_bid_stale   (i_upd_bid_stale),
        .i_upd_ask_stale   (i_upd_ask_stale),
        .i_upd_corrupt     (i_upd_corrupt),
        .i_upd_seq         (i_upd_seq),
        .o_cand_valid      (o_cand_valid),
        .o_cand_sym        (o_cand_sym),
        .o_cand_side       (o_cand_side),
        .o_cand_price      (o_cand_price),
        .o_cand_qty        (o_cand_qty),
        .o_cand_rule       (o_cand_rule),
        .o_cand_idx        (o_cand_idx),
        .o_cnt_cand        (o_cnt_cand)
    );

    // Initial reset sequence
    reg [2:0] reset_cnt = 3'd0;
    always @(posedge clk) begin
        if (reset_cnt < 3'd4) reset_cnt <= reset_cnt + 3'd1;
    end
    always @(*) begin
        if (reset_cnt < 3'd2) assume(rst);
        else assume(!rst);
    end

`ifdef FORMAL
    // Restrict symbol to 0 for single-symbol instance
    always @(*) begin
        assume(i_upd_sym == 4'd0);
    end

    // -------------------------------------------------------------------------
    // FP-3: Trigger emits nothing when P is false (Section 10.1, 12.3)
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if ($past(!rst, 2) && $past(!rst, 1) && !rst) begin
            // If o_cand_valid is asserted, P must have been TRUE 2 cycles ago
            if (o_cand_valid) begin
                assert($past(dut.P, 2));
                assert($past(i_upd_valid, 2));
                assert($past(i_upd_last, 2));
            end

            // Conversely, if P was false 2 cycles ago, o_cand_valid must be 0
            if (!$past(dut.P, 2)) begin
                assert(!o_cand_valid);
            end

            // Explicit individual false preconditions 2 cycles ago guarantee silence
            if ($past(!i_global_enable, 2)) assert(!o_cand_valid);
            if ($past(i_session_invalid, 2)) assert(!o_cand_valid);
            if ($past(i_upd_bid_stale, 2)) assert(!o_cand_valid);
            if ($past(i_upd_ask_stale, 2)) assert(!o_cand_valid);
            if ($past(i_upd_corrupt, 2)) assert(!o_cand_valid);
            if ($past(i_upd_bid_px >= i_upd_ask_px, 2)) assert(!o_cand_valid);
            if ($past(!dut.p_spread, 2)) assert(!o_cand_valid);
            if ($past(!dut.cfg_en, 2)) assert(!o_cand_valid);
            if ($past(!i_upd_last, 2)) assert(!o_cand_valid);
        end
    end
`endif

endmodule
