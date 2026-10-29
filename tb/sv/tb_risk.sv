// =============================================================================
// File        : tb/sv/tb_risk.sv
// Spec Section: 10.2, 15 (RK-1)
// Description : Unit testbench for t2t_risk verifying all 14 sub-cases
//               of gate RK-1 (a through n).
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
/* verilator lint_off INITIALDLY */
`include "t2t_defs.vh"

module tb_risk;

    reg clk;
    reg rst;

    reg        i_kill;
    reg        i_tx_fault;
    reg [31:0] i_max_gross;
    reg [15:0] i_max_orders;
    reg [4:0]  i_win_shift;

    reg [8*`T2T_RCFG_SYM_W-1:0] i_rcfg;

    reg        i_cand_valid;
    reg [3:0]  i_cand_sym;
    reg        i_cand_side;
    reg [31:0] i_cand_price;
    reg [15:0] i_cand_qty;
    reg [1:0]  i_cand_rule;
    reg [31:0] i_cand_idx;

    wire        o_dec_valid;
    wire        o_dec_pass;
    wire [3:0]  o_dec_reason;
    wire [3:0]  o_dec_sym;
    wire        o_dec_side;
    wire [31:0] o_dec_price;
    wire [15:0] o_dec_qty;
    wire [1:0]  o_dec_rule;
    wire [31:0] o_dec_idx;

    wire [8*32-1:0] o_risk_pos_flat;
    wire [31:0]     o_risk_gross;
    wire [31:0]     o_risk_win_id;
    wire [15:0]     o_risk_win_cnt;

    wire o_cnt_pass;
    wire o_cnt_rej_1;
    wire o_cnt_rej_2;
    wire o_cnt_rej_3;
    wire o_cnt_rej_4;
    wire o_cnt_rej_5;
    wire o_cnt_rej_6;
    wire o_cnt_rej_7;
    wire o_cnt_rej_8;
    wire o_cnt_rej_15;

    t2t_risk #(
        .N_SYMBOLS(8)
    ) dut (
        .clk             (clk),
        .rst             (rst),
        .i_kill          (i_kill),
        .i_tx_fault      (i_tx_fault),
        .i_max_gross     (i_max_gross),
        .i_max_orders    (i_max_orders),
        .i_win_shift     (i_win_shift),
        .i_rcfg          (i_rcfg),
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
        .o_risk_pos_flat (o_risk_pos_flat),
        .o_risk_gross    (o_risk_gross),
        .o_risk_win_id   (o_risk_win_id),
        .o_risk_win_cnt  (o_risk_win_cnt),
        .o_cnt_pass      (o_cnt_pass),
        .o_cnt_rej_1     (o_cnt_rej_1),
        .o_cnt_rej_2     (o_cnt_rej_2),
        .o_cnt_rej_3     (o_cnt_rej_3),
        .o_cnt_rej_4     (o_cnt_rej_4),
        .o_cnt_rej_5     (o_cnt_rej_5),
        .o_cnt_rej_6     (o_cnt_rej_6),
        .o_cnt_rej_7     (o_cnt_rej_7),
        .o_cnt_rej_8     (o_cnt_rej_8),
        .o_cnt_rej_15    (o_cnt_rej_15)
    );

    // 200 MHz Clock (5.0 ns period)
    always #2.5 clk = ~clk;

    // Helper task to configure a symbol
    task set_sym_rcfg(
        input [2:0]  sym,
        input        valid,
        input [15:0] max_qty,
        input [47:0] max_notional,
        input [31:0] collar_abs,
        input [31:0] ref_px,
        input [31:0] max_pos
    );
        reg [`T2T_RCFG_SYM_W-1:0] word;
        begin
            word = 161'd0;
            word[`T2T_RCFG_VALID_BIT]                  = valid;
            word[`T2T_RCFG_MAXQTY_HI : `T2T_RCFG_MAXQTY_LO] = max_qty;
            word[`T2T_RCFG_MAXNOT_HI : `T2T_RCFG_MAXNOT_LO] = max_notional;
            word[`T2T_RCFG_COLLAR_HI : `T2T_RCFG_COLLAR_LO] = collar_abs;
            word[`T2T_RCFG_REFPX_HI  : `T2T_RCFG_REFPX_LO]  = ref_px;
            word[`T2T_RCFG_MAXPOS_HI : `T2T_RCFG_MAXPOS_LO] = max_pos;

            i_rcfg[sym*`T2T_RCFG_SYM_W +: `T2T_RCFG_SYM_W] = word;
        end
    endtask

    // Helper task to send candidate and sample decision 4 cycles later
    task eval_cand(
        input [3:0]  sym,
        input        side,
        input [31:0] price,
        input [15:0] qty,
        input [1:0]  rule,
        input [31:0] idx,
        output       pass,
        output [3:0] reason
    );
        begin
            @(negedge clk);
            i_cand_valid <= 1'b1;
            i_cand_sym   <= sym;
            i_cand_side  <= side;
            i_cand_price <= price;
            i_cand_qty   <= qty;
            i_cand_rule  <= rule;
            i_cand_idx   <= idx;

            @(negedge clk);
            i_cand_valid <= 1'b0;

            // Wait remaining 3 cycles of depth 4
            repeat (3) @(negedge clk);
            pass   = o_dec_pass;
            reason = o_dec_reason;
        end
    endtask

    integer pass_count = 0;
    integer fail_count = 0;
    reg v_pass;
    reg [3:0] v_reason;

    initial begin
        clk = 0;
        rst = 1;
        i_kill = 0;
        i_tx_fault = 0;
        i_max_gross = 32'd10000;
        i_max_orders = 16'd100;
        i_win_shift = 5'd5;
        i_rcfg = 0;
        i_cand_valid = 0;
        i_cand_sym = 0;
        i_cand_side = 0;
        i_cand_price = 0;
        i_cand_qty = 0;
        i_cand_rule = 0;
        i_cand_idx = 0;

        repeat (5) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        $display("===============================================================");
        $display("[RK-1] Beginning Verification of Pre-Trade Risk Engine");
        $display("===============================================================");

        // ---------------------------------------------------------------------
        // Limit 1: QTY (one below, at, one above, zero)
        // ---------------------------------------------------------------------
        $display("\n--- Limit 1: QTY ---");
        // Symbol 0: max_qty = 100, max_notional = 10,000,000, collar = 1000, ref = 1000, max_pos = 10000
        set_sym_rcfg(3'd0, 1'b1, 16'd100, 48'd10000000, 32'd1000, 32'd1000, 32'd10000);

        // Qty zero -> reject QTY
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd1000, 16'd0, 2'd0, 32'd1, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_QTY) begin
            $display("[PASS] RK-1.qty.0: Qty=0 rejected with QTY");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.qty.0: Expected reject QTY, got pass=%0d reason=%0d", v_pass, v_reason);
            fail_count = fail_count + 1;
        end

        // Qty one below (99) -> pass
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd1000, 16'd99, 2'd0, 32'd2, v_pass, v_reason);
        if (v_pass && v_reason == `T2T_RSN_PASS) begin
            $display("[PASS] RK-1.qty.below: Qty=99 passed");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.qty.below: Expected PASS, got pass=%0d reason=%0d", v_pass, v_reason);
            fail_count = fail_count + 1;
        end

        // Qty at limit (100) -> pass
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd1000, 16'd100, 2'd0, 32'd3, v_pass, v_reason);
        if (v_pass && v_reason == `T2T_RSN_PASS) begin
            $display("[PASS] RK-1.qty.at: Qty=100 passed");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.qty.at: Expected PASS, got pass=%0d reason=%0d", v_pass, v_reason);
            fail_count = fail_count + 1;
        end

        // Qty one above (101) -> reject QTY
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd1000, 16'd101, 2'd0, 32'd4, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_QTY) begin
            $display("[PASS] RK-1.qty.above: Qty=101 rejected with QTY");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.qty.above: Expected reject QTY, got pass=%0d reason=%0d", v_pass, v_reason);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Limit 2: NOTIONAL (one below, at, one above)
        // ---------------------------------------------------------------------
        $display("\n--- Limit 2: NOTIONAL ---");
        // Symbol 1: max_qty = 1000, max_notional = 100,000, ref = 100, collar = 100
        set_sym_rcfg(3'd1, 1'b1, 16'd1000, 48'd100000, 32'd100, 32'd100, 32'd10000);

        // Notional = price * qty = 100 * 999 = 99,900 <= 100,000 -> pass
        eval_cand(4'd1, `T2T_SIDE_BID, 32'd100, 16'd999, 2'd0, 32'd10, v_pass, v_reason);
        if (v_pass) begin
            $display("[PASS] RK-1.notional.below: Notional 99,900 passed");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.notional.below: Expected PASS, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end

        // Notional = 100 * 1000 = 100,000 == max_notional -> pass
        eval_cand(4'd1, `T2T_SIDE_BID, 32'd100, 16'd1000, 2'd0, 32'd11, v_pass, v_reason);
        if (v_pass) begin
            $display("[PASS] RK-1.notional.at: Notional 100,000 passed");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.notional.at: Expected PASS, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end

        // Notional = 101 * 1000 = 101,000 > max_notional -> reject NOTIONAL
        eval_cand(4'd1, `T2T_SIDE_BID, 32'd101, 16'd1000, 2'd0, 32'd12, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_NOTIONAL) begin
            $display("[PASS] RK-1.notional.above: Notional 101,000 rejected with NOTIONAL");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.notional.above: Expected reject NOTIONAL, got pass=%0d reason=%0d", v_pass, v_reason);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Limit 3: COLLAR (one below, at, one above)
        // ---------------------------------------------------------------------
        $display("\n--- Limit 3: COLLAR ---");
        // Symbol 2: ref_px = 500, collar_abs = 50. Max price = 550, Min price = 450
        set_sym_rcfg(3'd2, 1'b1, 16'd100, 48'd10000000, 32'd50, 32'd500, 32'd10000);

        // Price = 549 (delta 49 <= 50) -> pass
        eval_cand(4'd2, `T2T_SIDE_BID, 32'd549, 16'd10, 2'd0, 32'd20, v_pass, v_reason);
        if (v_pass) begin
            $display("[PASS] RK-1.collar.below: Delta 49 passed");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.collar.below: Expected PASS, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end

        // Price = 550 (delta 50 == 50) -> pass
        eval_cand(4'd2, `T2T_SIDE_BID, 32'd550, 16'd10, 2'd0, 32'd21, v_pass, v_reason);
        if (v_pass) begin
            $display("[PASS] RK-1.collar.at: Delta 50 passed");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.collar.at: Expected PASS, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end

        // Price = 551 (delta 51 > 50) -> reject COLLAR
        eval_cand(4'd2, `T2T_SIDE_BID, 32'd551, 16'd10, 2'd0, 32'd22, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_COLLAR) begin
            $display("[PASS] RK-1.collar.above: Delta 51 rejected with COLLAR");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.collar.above: Expected reject COLLAR, got pass=%0d reason=%0d", v_pass, v_reason);
            fail_count = fail_count + 1;
        end

        // Price = 449 (lower collar: 500 - 449 = 51 > 50) -> reject COLLAR
        eval_cand(4'd2, `T2T_SIDE_ASK, 32'd449, 16'd10, 2'd0, 32'd23, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_COLLAR) begin
            $display("[PASS] RK-1.collar.lower_above: Lower Delta 51 rejected with COLLAR");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.collar.lower_above: Expected reject COLLAR, got pass=%0d reason=%0d", v_pass, v_reason);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Limit 4: POS_SYM (symbol position limit)
        // ---------------------------------------------------------------------
        $display("\n--- Limit 4: POS_SYM ---");
        // Symbol 3: max_pos = 100. Currently pos = 0
        set_sym_rcfg(3'd3, 1'b1, 16'd500, 48'd10000000, 32'd1000, 32'd500, 32'd100);

        // Buy 99 shares -> pos becomes 99 <= 100 -> pass
        eval_cand(4'd3, `T2T_SIDE_BID, 32'd500, 16'd99, 2'd0, 32'd30, v_pass, v_reason);
        if (v_pass) begin
            $display("[PASS] RK-1.pos_sym.99: Pos to 99 passed");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.pos_sym.99: Expected PASS, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end

        // Buy 1 share -> pos becomes 100 == 100 -> pass
        eval_cand(4'd3, `T2T_SIDE_BID, 32'd500, 16'd1, 2'd0, 32'd31, v_pass, v_reason);
        if (v_pass) begin
            $display("[PASS] RK-1.pos_sym.100: Pos to 100 passed");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.pos_sym.100: Expected PASS, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end

        // Buy 1 share -> pos would become 101 > 100 -> reject POS_SYM
        eval_cand(4'd3, `T2T_SIDE_BID, 32'd500, 16'd1, 2'd0, 32'd32, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_POS_SYM) begin
            $display("[PASS] RK-1.pos_sym.101: Pos to 101 rejected with POS_SYM");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.pos_sym.101: Expected reject POS_SYM, got pass=%0d reason=%0d", v_pass, v_reason);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Limit 5: POS_GLOB (global gross limit)
        // ---------------------------------------------------------------------
        $display("\n--- Limit 5: POS_GLOB ---");
        // Reset gross by doing reset or set gross limit:
        rst = 1;
        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        i_max_gross = 32'd200;
        set_sym_rcfg(3'd0, 1'b1, 16'd500, 48'd10000000, 32'd1000, 32'd500, 32'd10000);
        // Order 1: qty = 150 -> gross = 150 <= 200 -> pass
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd500, 16'd150, 2'd0, 32'd40, v_pass, v_reason);
        if (v_pass) begin
            $display("[PASS] RK-1.pos_glob.150: Gross to 150 passed");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.pos_glob.150: Expected PASS, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end

        // Order 2: qty = 50 -> gross = 200 == 200 -> pass
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd500, 16'd50, 2'd0, 32'd41, v_pass, v_reason);
        if (v_pass) begin
            $display("[PASS] RK-1.pos_glob.200: Gross to 200 passed");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.pos_glob.200: Expected PASS, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end

        // Order 3: qty = 1 -> gross would be 201 > 200 -> reject POS_GLOB
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd500, 16'd1, 2'd0, 32'd42, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_POS_GLOB) begin
            $display("[PASS] RK-1.pos_glob.201: Gross to 201 rejected with POS_GLOB");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.pos_glob.201: Expected reject POS_GLOB, got pass=%0d reason=%0d", v_pass, v_reason);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Limit 6: RATE (max_orders in rate window)
        // ---------------------------------------------------------------------
        $display("\n--- Limit 6: RATE ---");
        i_max_gross = 32'd100000;
        i_max_orders = 16'd2; // Limit 2 orders per window
        i_win_shift = 5'd5;   // Window size = 32 messages

        // Order 1 at idx 64 (win_id = 2): 1st order -> pass
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd500, 16'd10, 2'd0, 32'd64, v_pass, v_reason);
        if (v_pass) begin
            $display("[PASS] RK-1.rate.1: 1st order in window passed");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.rate.1: Expected PASS, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end

        // Order 2 at idx 65: 2nd order -> pass
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd500, 16'd10, 2'd0, 32'd65, v_pass, v_reason);
        if (v_pass) begin
            $display("[PASS] RK-1.rate.2: 2nd order in window passed");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.rate.2: Expected PASS, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end

        // Order 3 at idx 66: 3rd order in same window -> reject RATE
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd500, 16'd10, 2'd0, 32'd66, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_RATE) begin
            $display("[PASS] RK-1.rate.3: 3rd order rejected with RATE");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.rate.3: Expected reject RATE, got pass=%0d reason=%0d", v_pass, v_reason);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Sub-case (i): KILL
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (i): KILL ---");
        i_kill = 1;
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd500, 16'd10, 2'd0, 32'd100, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_KILL) begin
            $display("[PASS] RK-1.i: kill=1 rejected with KILL");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.i: Expected reject KILL, got pass=%0d reason=%0d", v_pass, v_reason);
            fail_count = fail_count + 1;
        end
        i_kill = 0;

        // ---------------------------------------------------------------------
        // Sub-case (j): UNKNOWN config
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (j): UNKNOWN config ---");
        // Symbol 7 not valid (cfg_valid = 0)
        set_sym_rcfg(3'd7, 1'b0, 16'd100, 48'd10000000, 32'd1000, 32'd500, 32'd10000);
        eval_cand(4'd7, `T2T_SIDE_BID, 32'd500, 16'd10, 2'd0, 32'd110, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_UNKNOWN) begin
            $display("[PASS] RK-1.j: cfg_valid=0 rejected with UNKNOWN");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.j: Expected reject UNKNOWN, got pass=%0d reason=%0d", v_pass, v_reason);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Sub-case (k): Reason priority with several failures
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (k): Reason priority ---");
        // Fail KILL and QTY: KILL wins
        i_kill = 1;
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd500, 16'd0, 2'd0, 32'd120, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_KILL) begin
            $display("[PASS] RK-1.k.1: KILL wins over QTY");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.k.1: Expected KILL, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end
        i_kill = 0;

        // Fail TX_FAULT and QTY: TX_FAULT wins
        i_tx_fault = 1;
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd500, 16'd0, 2'd0, 32'd121, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_TX_FAULT) begin
            $display("[PASS] RK-1.k.2: TX_FAULT wins over QTY");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.k.2: Expected TX_FAULT, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end
        i_tx_fault = 0;

        // Fail QTY and NOTIONAL: QTY wins
        // Set max_qty = 10, max_notional = 100. Send qty = 20, price = 100 (notional = 2000 > 100)
        set_sym_rcfg(3'd4, 1'b1, 16'd10, 48'd100, 32'd1000, 32'd100, 32'd10000);
        eval_cand(4'd4, `T2T_SIDE_BID, 32'd100, 16'd20, 2'd0, 32'd122, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_QTY) begin
            $display("[PASS] RK-1.k.3: QTY wins over NOTIONAL");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.k.3: Expected QTY, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end

        // Fail NOTIONAL and COLLAR: NOTIONAL wins
        // Set max_qty = 100, max_notional = 100, collar_abs = 10, ref_px = 100.
        // Send qty = 10, price = 200 (notional 2000 > 100, collar 100 > 10)
        set_sym_rcfg(3'd4, 1'b1, 16'd100, 48'd100, 32'd10, 32'd100, 32'd10000);
        eval_cand(4'd4, `T2T_SIDE_BID, 32'd200, 16'd10, 2'd0, 32'd123, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_NOTIONAL) begin
            $display("[PASS] RK-1.k.4: NOTIONAL wins over COLLAR");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.k.4: Expected NOTIONAL, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Sub-case (l): Back-to-back candidates see each other's state
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (l): Back-to-back sequential consistency ---");
        // Symbol 5: max_pos = 100. We will drive two candidates back-to-back:
        // Candidate 1: qty = 60 BUY -> should PASS, pos becomes 60
        // Candidate 2: qty = 50 BUY -> would make pos 110 > 100 -> should REJECT POS_SYM!
        set_sym_rcfg(3'd5, 1'b1, 16'd500, 48'd10000000, 32'd1000, 32'd100, 32'd100);
        i_max_orders = 16'd100;

        @(negedge clk);
        // Candidate 1 at Cycle T
        i_cand_valid <= 1'b1;
        i_cand_sym   <= 4'd5;
        i_cand_side  <= `T2T_SIDE_BID;
        i_cand_price <= 32'd100;
        i_cand_qty   <= 16'd60;
        i_cand_rule  <= 2'd0;
        i_cand_idx   <= 32'd201;

        @(negedge clk);
        // Candidate 2 at Cycle T+1 (consecutive cycle, 0 bubbles)
        i_cand_valid <= 1'b1;
        i_cand_sym   <= 4'd5;
        i_cand_side  <= `T2T_SIDE_BID;
        i_cand_price <= 32'd100;
        i_cand_qty   <= 16'd50;
        i_cand_rule  <= 2'd0;
        i_cand_idx   <= 32'd202;

        @(negedge clk);
        i_cand_valid <= 1'b0;

        // Wait for Candidate 1 output (at cycle T + 4)
        repeat (2) @(negedge clk);
        if (o_dec_valid && o_dec_pass && o_dec_idx == 32'd201) begin
            $display("[PASS] RK-1.l.1: Candidate 1 passed (pos updated to 60)");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.l.1: Candidate 1 failed! pass=%0d reason=%0d", o_dec_pass, o_dec_reason);
            fail_count = fail_count + 1;
        end

        // Wait for Candidate 2 output on the very next cycle (at cycle T + 5)
        @(negedge clk);
        if (o_dec_valid && !o_dec_pass && o_dec_reason == `T2T_RSN_POS_SYM && o_dec_idx == 32'd202) begin
            $display("[PASS] RK-1.l.2: Candidate 2 sequentially saw Candidate 1 state and rejected with POS_SYM");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.l.2: Candidate 2 failed sequential check! pass=%0d reason=%0d", o_dec_pass, o_dec_reason);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Sub-case (m): Rate window roll-over
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (m): Rate window roll-over ---");
        // Candidate arrived at idx 66 was rejected due to RATE (window 2: idx 64..95)
        // Candidate arriving at idx 96 (window 3: 96 >> 5 = 3 != 2) must ROLL OVER and PASS!
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd500, 16'd10, 2'd0, 32'd96, v_pass, v_reason);
        if (v_pass && v_reason == `T2T_RSN_PASS) begin
            $display("[PASS] RK-1.m: Window rolled over to idx 96, order passed");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.m: Expected PASS on window roll-over, got reason=%0d", v_reason);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Sub-case (n): max_orders = 0 rejects everything with RATE
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (n): max_orders = 0 ---");
        i_max_orders = 16'd0;
        eval_cand(4'd0, `T2T_SIDE_BID, 32'd500, 16'd10, 2'd0, 32'd200, v_pass, v_reason);
        if (!v_pass && v_reason == `T2T_RSN_RATE) begin
            $display("[PASS] RK-1.n: max_orders=0 rejected with RATE");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RK-1.n: Expected reject RATE on max_orders=0, got pass=%0d reason=%0d", v_pass, v_reason);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $display("\n===============================================================");
        $display("[RK-1] Summary: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("===============================================================");

        if (fail_count == 0) begin
            $display("[GATE PASS] RK-1: All risk engine sub-cases verified successfully.");
            $finish(0);
        end else begin
            $display("[GATE FAIL] RK-1: %0d sub-cases failed.", fail_count);
            $finish(1);
        end
    end

endmodule
