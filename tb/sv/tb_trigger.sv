// =============================================================================
// File        : tb/sv/tb_trigger.sv
// Spec Section: 10.1, 15 (TR-1)
// Description : Unit testbench for t2t_trigger verifying all 9 sub-cases
//               of gate TR-1 (a through i).
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
/* verilator lint_off INITIALDLY */
`include "t2t_defs.vh"

module tb_trigger;

    reg clk;
    reg rst;

    reg        i_global_enable;
    reg        i_session_invalid;
    reg [8*`T2T_TCFG_SYM_W-1:0] i_tcfg;

    reg        i_upd_valid;
    reg [3:0]  i_upd_sym;
    reg [31:0] i_upd_idx;
    reg        i_upd_last;
    reg [31:0] i_upd_bid_px;
    reg [31:0] i_upd_bid_qty;
    reg [31:0] i_upd_ask_px;
    reg [31:0] i_upd_ask_qty;
    reg [3:0]  i_upd_bid_lv;
    reg [3:0]  i_upd_ask_lv;
    reg        i_upd_bid_stale;
    reg        i_upd_ask_stale;
    reg        i_upd_corrupt;
    reg [31:0] i_upd_seq;

    wire        o_cand_valid;
    wire [3:0]  o_cand_sym;
    wire        o_cand_side;
    wire [31:0] o_cand_price;
    wire [15:0] o_cand_qty;
    wire [1:0]  o_cand_rule;
    wire [31:0] o_cand_idx;
    wire        o_cnt_cand;

    t2t_trigger #(
        .N_SYMBOLS(8)
    ) dut (
        .clk               (clk),
        .rst               (rst),
        .i_global_enable   (i_global_enable),
        .i_session_invalid (i_session_invalid),
        .i_tcfg            (i_tcfg),
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

    // Clock generator: 200 MHz (5.0 ns period)
    always #2.5 clk = ~clk;

    // Helper task to configure a symbol slot
    task set_symbol_cfg(
        input [2:0]  sym,
        input        en,
        input [3:0]  rule_mask,
        input [2:0]  imb_shift,
        input [31:0] buy_limit,
        input [31:0] sell_limit,
        input [31:0] max_spread,
        input [15:0] qty
    );
        reg [`T2T_TCFG_SYM_W-1:0] cfg_word;
        begin
            cfg_word = 120'd0;
            cfg_word[`T2T_TCFG_EN_BIT]                    = en;
            cfg_word[`T2T_TCFG_MASK_HI : `T2T_TCFG_MASK_LO] = rule_mask;
            cfg_word[`T2T_TCFG_IMB_HI  : `T2T_TCFG_IMB_LO]  = imb_shift;
            cfg_word[`T2T_TCFG_BUYLIM_HI : `T2T_TCFG_BUYLIM_LO] = buy_limit;
            cfg_word[`T2T_TCFG_SELLLIM_HI : `T2T_TCFG_SELLLIM_LO] = sell_limit;
            cfg_word[`T2T_TCFG_MAXSPR_HI : `T2T_TCFG_MAXSPR_LO] = max_spread;
            cfg_word[`T2T_TCFG_QTY_HI : `T2T_TCFG_QTY_LO] = qty;

            i_tcfg[sym*`T2T_TCFG_SYM_W +: `T2T_TCFG_SYM_W] = cfg_word;
        end
    endtask

    // Helper task to send an update beat
    task send_upd(
        input [3:0]  sym,
        input [31:0] idx,
        input        last,
        input [31:0] bid_px,
        input [31:0] bid_qty,
        input [31:0] ask_px,
        input [31:0] ask_qty,
        input [3:0]  bid_lv,
        input [3:0]  ask_lv,
        input        bid_stale,
        input        ask_stale,
        input        corrupt
    );
        begin
            @(negedge clk);
            i_upd_valid     <= 1'b1;
            i_upd_sym       <= sym;
            i_upd_idx       <= idx;
            i_upd_last      <= last;
            i_upd_bid_px    <= bid_px;
            i_upd_bid_qty   <= bid_qty;
            i_upd_ask_px    <= ask_px;
            i_upd_ask_qty   <= ask_qty;
            i_upd_bid_lv    <= bid_lv;
            i_upd_ask_lv    <= ask_lv;
            i_upd_bid_stale <= bid_stale;
            i_upd_ask_stale <= ask_stale;
            i_upd_corrupt   <= corrupt;
            i_upd_seq       <= i_upd_seq + 1'b1;
            @(negedge clk);
            i_upd_valid     <= 1'b0;
        end
    endtask

    // Latency is 2 cycles: wait 2 cycles and sample output
    task wait_cand(
        output        valid,
        output [3:0]  sym,
        output        side,
        output [31:0] price,
        output [15:0] qty,
        output [1:0]  rule,
        output [31:0] idx
    );
        begin
            // Since input was sent at negedge and held for 1 cycle,
            // 2 clock cycles later at negedge, output will be valid.
            @(negedge clk);
            valid = o_cand_valid;
            sym   = o_cand_sym;
            side  = o_cand_side;
            price = o_cand_price;
            qty   = o_cand_qty;
            rule  = o_cand_rule;
            idx   = o_cand_idx;
        end
    endtask

    integer pass_count = 0;
    integer fail_count = 0;

    reg v_valid;
    reg [3:0] v_sym;
    reg v_side;
    reg [31:0] v_px;
    reg [15:0] v_qty;
    reg [1:0] v_rule;
    reg [31:0] v_idx;

    initial begin
        clk = 0;
        rst = 1;
        i_global_enable = 1;
        i_session_invalid = 0;
        i_tcfg = 0;
        i_upd_valid = 0;
        i_upd_sym = 0;
        i_upd_idx = 0;
        i_upd_last = 0;
        i_upd_bid_px = 0;
        i_upd_bid_qty = 0;
        i_upd_ask_px = 0;
        i_upd_ask_qty = 0;
        i_upd_bid_lv = 0;
        i_upd_ask_lv = 0;
        i_upd_bid_stale = 0;
        i_upd_ask_stale = 0;
        i_upd_corrupt = 0;
        i_upd_seq = 0;

        repeat (5) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        $display("===============================================================");
        $display("[TR-1] Beginning Verification of Edge-Triggered Trading Rules");
        $display("===============================================================");

        // ---------------------------------------------------------------------
        // Sub-case (a): Each rule fires
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (a): Each rule fires ---");

        // Rule 0: CROSS_BUY (ask_px <= buy_limit -> buy at ask_px)
        set_symbol_cfg(3'd0, 1'b1, 4'b0001, 3'd0, 32'd1000, 32'd0, 32'd100, 16'd500);
        send_upd(4'd0, 32'd101, 1'b1, 32'd950, 32'd100, 32'd990, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (v_valid && v_sym == 4'd0 && v_side == `T2T_SIDE_BID && v_px == 32'd990 && v_qty == 16'd500 && v_rule == 2'd0 && v_idx == 32'd101) begin
            $display("[PASS] TR-1.a.0: Rule 0 CROSS_BUY fired: side=BUY px=990 qty=500 rule=0");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.a.0: Rule 0 CROSS_BUY failed: valid=%0d sym=%0d side=%0d px=%0d rule=%0d", v_valid, v_sym, v_side, v_px, v_rule);
            fail_count = fail_count + 1;
        end

        // Re-arm symbol 0 by breaking condition
        send_upd(4'd0, 32'd102, 1'b1, 32'd950, 32'd100, 32'd1050, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);

        // Rule 1: CROSS_SELL (bid_px >= sell_limit -> sell at bid_px)
        set_symbol_cfg(3'd1, 1'b1, 4'b0010, 3'd0, 32'd0, 32'd900, 32'd100, 16'd300);
        send_upd(4'd1, 32'd103, 1'b1, 32'd920, 32'd100, 32'd960, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (v_valid && v_sym == 4'd1 && v_side == `T2T_SIDE_ASK && v_px == 32'd920 && v_qty == 16'd300 && v_rule == 2'd1 && v_idx == 32'd103) begin
            $display("[PASS] TR-1.a.1: Rule 1 CROSS_SELL fired: side=SELL px=920 qty=300 rule=1");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.a.1: Rule 1 CROSS_SELL failed: valid=%0d sym=%0d side=%0d px=%0d rule=%0d", v_valid, v_sym, v_side, v_px, v_rule);
            fail_count = fail_count + 1;
        end

        // Rule 2: IMB_BUY (bid_qty >= ask_qty << shift -> buy at ask_px)
        set_symbol_cfg(3'd2, 1'b1, 4'b0100, 3'd2, 32'd0, 32'd0, 32'd100, 16'd400); // shift=2 (4x)
        send_upd(4'd2, 32'd104, 1'b1, 32'd900, 32'd800, 32'd950, 32'd200, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0); // 800 >= 200<<2 (800)
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (v_valid && v_sym == 4'd2 && v_side == `T2T_SIDE_BID && v_px == 32'd950 && v_qty == 16'd400 && v_rule == 2'd2 && v_idx == 32'd104) begin
            $display("[PASS] TR-1.a.2: Rule 2 IMB_BUY fired: side=BUY px=950 qty=400 rule=2");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.a.2: Rule 2 IMB_BUY failed: valid=%0d sym=%0d side=%0d px=%0d rule=%0d", v_valid, v_sym, v_side, v_px, v_rule);
            fail_count = fail_count + 1;
        end

        // Rule 3: IMB_SELL (ask_qty >= bid_qty << shift -> sell at bid_px)
        set_symbol_cfg(3'd3, 1'b1, 4'b1000, 3'd1, 32'd0, 32'd0, 32'd100, 16'd250); // shift=1 (2x)
        send_upd(4'd3, 32'd105, 1'b1, 32'd900, 32'd300, 32'd950, 32'd700, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0); // 700 >= 300<<1 (600)
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (v_valid && v_sym == 4'd3 && v_side == `T2T_SIDE_ASK && v_px == 32'd900 && v_qty == 16'd250 && v_rule == 2'd3 && v_idx == 32'd105) begin
            $display("[PASS] TR-1.a.3: Rule 3 IMB_SELL fired: side=SELL px=900 qty=250 rule=3");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.a.3: Rule 3 IMB_SELL failed: valid=%0d sym=%0d side=%0d px=%0d rule=%0d", v_valid, v_sym, v_side, v_px, v_rule);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Sub-case (b): Rule ID Priority (lowest rule id wins)
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (b): Priority ---");
        // Symbol 4 configured with all 4 rules enabled
        set_symbol_cfg(3'd4, 1'b1, 4'b1111, 3'd1, 32'd1000, 32'd850, 32'd100, 16'd100);

        // Update satisfies Rule 0, 1, 2, 3:
        // ask_px=950 <= buy_limit(1000) [Rule 0]
        // bid_px=900 >= sell_limit(850) [Rule 1]
        // bid_qty=500 >= ask_qty(200)<<1 = 400 [Rule 2]
        // ask_qty not >= bid_qty<<1
        // Expected winner: Rule 0
        send_upd(4'd4, 32'd106, 1'b1, 32'd900, 32'd500, 32'd950, 32'd200, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (v_valid && v_rule == 2'd0) begin
            $display("[PASS] TR-1.b.0: Rule 0 wins over Rule 1, 2");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.b.0: Expected Rule 0, got valid=%0d rule=%0d", v_valid, v_rule);
            fail_count = fail_count + 1;
        end

        // Reset symbol 5 to test Rule 1 vs Rule 2
        set_symbol_cfg(3'd5, 1'b1, 4'b0110, 3'd1, 32'd0, 32'd850, 32'd100, 16'd100);
        // Rule 0 disabled. Rule 1 satisfied (bid 900 >= 850). Rule 2 satisfied (bid_qty 500 >= 400).
        send_upd(4'd5, 32'd107, 1'b1, 32'd900, 32'd500, 32'd950, 32'd200, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (v_valid && v_rule == 2'd1) begin
            $display("[PASS] TR-1.b.1: Rule 1 wins over Rule 2");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.b.1: Expected Rule 1, got valid=%0d rule=%0d", v_valid, v_rule);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Sub-case (c): Edge re-arming
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (c): Edge re-arming ---");
        // Symbol 6 with Rule 0 enabled
        set_symbol_cfg(3'd6, 1'b1, 4'b0001, 3'd0, 32'd1000, 32'd0, 32'd100, 16'd100);

        // 1. Initial fire
        send_upd(4'd6, 32'd201, 1'b1, 32'd950, 32'd100, 32'd990, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (v_valid && v_rule == 2'd0) begin
            $display("[PASS] TR-1.c.1: Initial condition fires");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.c.1: Initial condition did not fire");
            fail_count = fail_count + 1;
        end

        // 2. Condition remains true on next update: must NOT fire (suppressed by armed)
        send_upd(4'd6, 32'd202, 1'b1, 32'd950, 32'd100, 32'd990, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (!v_valid) begin
            $display("[PASS] TR-1.c.2: Condition still true does not fire (edge-triggered)");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.c.2: Rule fired again without re-arming! valid=%0d", v_valid);
            fail_count = fail_count + 1;
        end

        // 3. Condition drops (ask_px 1050 > buy_limit 1000): re-arms
        send_upd(4'd6, 32'd203, 1'b1, 32'd950, 32'd100, 32'd1050, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (!v_valid) begin
            $display("[PASS] TR-1.c.3: Condition drop re-arms without firing");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.c.3: Unexpected fire on condition drop");
            fail_count = fail_count + 1;
        end

        // 4. Condition met again: fires again!
        send_upd(4'd6, 32'd204, 1'b1, 32'd950, 32'd100, 32'd980, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (v_valid && v_rule == 2'd0) begin
            $display("[PASS] TR-1.c.4: Rule fires again after re-arming");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.c.4: Rule did not fire after re-arming! valid=%0d", v_valid);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Sub-case (d): Blocked by stale
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (d): Blocked by stale ---");
        set_symbol_cfg(3'd7, 1'b1, 4'b0001, 3'd0, 32'd1000, 32'd0, 32'd100, 16'd100);

        // Stale bid
        send_upd(4'd7, 32'd301, 1'b1, 32'd950, 32'd100, 32'd990, 32'd100, 4'd1, 4'd1, 1'b1, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (!v_valid) begin
            $display("[PASS] TR-1.d.1: Blocked by bid_stale");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.d.1: Not blocked by bid_stale!");
            fail_count = fail_count + 1;
        end

        // Stale ask
        send_upd(4'd7, 32'd302, 1'b1, 32'd950, 32'd100, 32'd990, 32'd100, 4'd1, 4'd1, 1'b0, 1'b1, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (!v_valid) begin
            $display("[PASS] TR-1.d.2: Blocked by ask_stale");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.d.2: Not blocked by ask_stale!");
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Sub-case (e): Blocked by corrupt
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (e): Blocked by corrupt ---");
        send_upd(4'd7, 32'd303, 1'b1, 32'd950, 32'd100, 32'd990, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b1);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (!v_valid) begin
            $display("[PASS] TR-1.e: Blocked by corrupt");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.e: Not blocked by corrupt!");
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Sub-case (f): Blocked by crossed
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (f): Blocked by crossed ---");
        // bid_px 1050 >= ask_px 990
        send_upd(4'd7, 32'd304, 1'b1, 32'd1050, 32'd100, 32'd990, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (!v_valid) begin
            $display("[PASS] TR-1.f: Blocked by crossed book (bid >= ask)");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.f: Not blocked by crossed!");
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Sub-case (g): Blocked by spread
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (g): Blocked by spread ---");
        // max_spread is 100. bid 850, ask 990 (spread 140 > 100)
        send_upd(4'd7, 32'd305, 1'b1, 32'd850, 32'd100, 32'd990, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (!v_valid) begin
            $display("[PASS] TR-1.g: Blocked by spread > max_spread");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.g: Not blocked by spread!");
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Sub-case (h): Blocked by global_enable = 0, cfg_en = 0, session_invalid
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (h): Blocked by enables / session ---");
        // 1. global_enable = 0
        i_global_enable = 0;
        send_upd(4'd7, 32'd306, 1'b1, 32'd950, 32'd100, 32'd990, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (!v_valid) begin
            $display("[PASS] TR-1.h.1: Blocked by global_enable = 0");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.h.1: Not blocked by global_enable = 0!");
            fail_count = fail_count + 1;
        end
        i_global_enable = 1;

        // 2. session_invalid = 1
        i_session_invalid = 1;
        send_upd(4'd7, 32'd307, 1'b1, 32'd950, 32'd100, 32'd990, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (!v_valid) begin
            $display("[PASS] TR-1.h.2: Blocked by session_invalid = 1");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.h.2: Not blocked by session_invalid = 1!");
            fail_count = fail_count + 1;
        end
        i_session_invalid = 0;

        // 3. cfg.en = 0
        set_symbol_cfg(3'd7, 1'b0, 4'b0001, 3'd0, 32'd1000, 32'd0, 32'd100, 16'd100);
        send_upd(4'd7, 32'd308, 1'b1, 32'd950, 32'd100, 32'd990, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (!v_valid) begin
            $display("[PASS] TR-1.h.3: Blocked by cfg.en = 0");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.h.3: Not blocked by cfg.en = 0!");
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Sub-case (i): A Replace's first op causes no candidate
        // ---------------------------------------------------------------------
        $display("\n--- Sub-case (i): Replace first op causes no candidate ---");
        set_symbol_cfg(3'd7, 1'b1, 4'b0001, 3'd0, 32'd1000, 32'd0, 32'd100, 16'd100);

        // First op of replace: last = 0. Meets condition, but last=0 -> no candidate!
        send_upd(4'd7, 32'd401, 1'b0, 32'd950, 32'd100, 32'd990, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (!v_valid) begin
            $display("[PASS] TR-1.i.1: Replace first op (last=0) emits no candidate");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.i.1: Candidate emitted on last=0! valid=%0d", v_valid);
            fail_count = fail_count + 1;
        end

        // Second op of replace: last = 1. Meets condition -> fires candidate!
        send_upd(4'd7, 32'd402, 1'b1, 32'd950, 32'd100, 32'd990, 32'd100, 4'd1, 4'd1, 1'b0, 1'b0, 1'b0);
        wait_cand(v_valid, v_sym, v_side, v_px, v_qty, v_rule, v_idx);
        if (v_valid && v_rule == 2'd0) begin
            $display("[PASS] TR-1.i.2: Replace second op (last=1) fires normally");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TR-1.i.2: Expected candidate on last=1, got valid=%0d", v_valid);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Final Summary
        // ---------------------------------------------------------------------
        $display("\n===============================================================");
        $display("[TR-1] Summary: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("===============================================================");

        if (fail_count == 0) begin
            $display("[GATE PASS] TR-1: All trading rule sub-cases verified successfully.");
            $finish(0);
        end else begin
            $display("[GATE FAIL] TR-1: %0d sub-cases failed.", fail_count);
            $finish(1);
        end
    end

endmodule
