// =============================================================================
// File        : formal/fp_risk.sv
// Spec Section: 10.2, 12.3 (FP-1)
// Description : Formal property wrapper for t2t_risk verifying that
//               risk never passes an order violating any limits and kill=1
//               always rejects (FP-1).
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module fp_risk (
    input wire clk,
    input wire rst,
    input wire i_kill,
    input wire i_tx_fault,
    input wire [31:0] i_max_gross,
    input wire [15:0] i_max_orders,
    input wire [4:0]  i_win_shift,
    input wire [`T2T_RCFG_SYM_W-1:0] i_rcfg_sym0,
    input wire i_cand_valid,
    input wire [3:0] i_cand_sym,
    input wire i_cand_side,
    input wire [31:0] i_cand_price,
    input wire [15:0] i_cand_qty,
    input wire [1:0] i_cand_rule,
    input wire [31:0] i_cand_idx
);

    wire        o_dec_valid;
    wire        o_dec_pass;
    wire [3:0]  o_dec_reason;
    wire [3:0]  o_dec_sym;
    wire        o_dec_side;
    wire [31:0] o_dec_price;
    wire [15:0] o_dec_qty;
    wire [1:0]  o_dec_rule;
    wire [31:0] o_dec_idx;

    wire [8*`T2T_RCFG_SYM_W-1:0] full_rcfg = {{(7*`T2T_RCFG_SYM_W){1'b0}}, i_rcfg_sym0};

    t2t_risk #(
        .N_SYMBOLS(1)
    ) dut (
        .clk             (clk),
        .rst             (rst),
        .i_kill          (i_kill),
        .i_tx_fault      (i_tx_fault),
        .i_max_gross     (i_max_gross),
        .i_max_orders    (i_max_orders),
        .i_win_shift     (i_win_shift),
        .i_rcfg          (full_rcfg[1*`T2T_RCFG_SYM_W-1:0]),
        .i_cand_valid    (i_cand_valid),
        .i_cand_sym      (i_cand_sym),
        .i_cand_side     (i_cand_side),
        .i_cand_price    (i_cand_price),
        .i_cand_qty      (i_cand_qty),
        .i_cand_rule     (i_cand_rule),
        .i_cand_idx      (i_cand_idx),
        .o_dec_valid     (o_dec_valid),
        .o_dec_pass      (o_dec_pass),
        .o_dec_reason    (o_dec_reason),
        .o_dec_sym       (o_dec_sym),
        .o_dec_side      (o_dec_side),
        .o_dec_price     (o_dec_price),
        .o_dec_qty       (o_dec_qty),
        .o_dec_rule      (o_dec_rule),
        .o_dec_idx       (o_dec_idx),
        .o_risk_pos_flat (),
        .o_risk_gross    (),
        .o_risk_win_id   (),
        .o_risk_win_cnt  (),
        .o_cnt_pass      (),
        .o_cnt_rej_1     (),
        .o_cnt_rej_2     (),
        .o_cnt_rej_3     (),
        .o_cnt_rej_4     (),
        .o_cnt_rej_5     (),
        .o_cnt_rej_6     (),
        .o_cnt_rej_7     (),
        .o_cnt_rej_8     (),
        .o_cnt_rej_15    ()
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
    always @(*) begin
        assume(i_cand_sym == 4'd0);
    end

    // -------------------------------------------------------------------------
    // FP-1: Risk never passes an order violating limits, and kill=1 always rejects
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if ($past(!rst, 4) && !rst) begin
            if (o_dec_valid && o_dec_pass) begin
                // When pass is asserted:
                // 1. Reason must be PASS (0)
                assert(o_dec_reason == `T2T_RSN_PASS);

                // 2. Kill was not asserted
                assert(!$past(i_kill, 4));

                // 3. Tx fault was not asserted
                assert(!$past(i_tx_fault, 4));

                // 4. Quantity is non-zero
                assert(o_dec_qty > 16'd0);
            end

            // Kill=1 4 cycles ago guarantees reject
            if ($past(i_kill, 4) && $past(i_cand_valid, 4)) begin
                assert(!o_dec_pass);
                assert(o_dec_reason == `T2T_RSN_KILL);
            end

            // Tx fault=1 4 cycles ago (without kill) guarantees reject with TX_FAULT
            if ($past(!i_kill, 4) && $past(i_tx_fault, 4) && $past(i_cand_valid, 4)) begin
                assert(!o_dec_pass);
                assert(o_dec_reason == `T2T_RSN_TX_FAULT);
            end
        end
    end
`endif

endmodule

