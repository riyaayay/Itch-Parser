// =============================================================================
// File        : tb/sv/tb_symfilter.sv
// Spec Section: 8.1, 8.2, 12.2 (SF-1 sub-cases a through e)
// Description : Unit testbench for t2t_symfilter verifying hit on 8 slots,
//               near misses, non-add passthrough, duplicate priority, and inactive slots.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module tb_symfilter;

    logic         clk = 1'b0;
    logic         rst = 1'b1;

    logic         i_msg_valid;
    logic [319:0] i_msg;
    logic [511:0] i_cfg_stock;

    wire          o_valid;
    wire [324:0]  o_fa;
    wire          o_cnt_hit;
    wire          o_cnt_miss;

    always #5 clk = ~clk;

    t2t_symfilter dut (
        .clk         (clk),
        .rst         (rst),
        .i_msg_valid (i_msg_valid),
        .i_msg       (i_msg),
        .i_cfg_stock (i_cfg_stock),
        .o_valid     (o_valid),
        .o_fa        (o_fa),
        .o_cnt_hit   (o_cnt_hit),
        .o_cnt_miss  (o_cnt_miss)
    );

    // Helpers to unpack o_fa
    wire         fa_hit  = o_fa[`T2T_FA_HIT_BIT];
    wire [3:0]   fa_sym  = o_fa[`T2T_FA_SYM_HI : `T2T_FA_SYM_LO];
    wire [319:0] fa_msg  = o_fa[`T2T_FA_MSG_HI : `T2T_FA_MSG_LO];

    task automatic set_slot(input [2:0] slot_idx, input [63:0] stock_str);
        begin
            i_cfg_stock[64*slot_idx +: 64] = stock_str;
        end
    endtask

    task automatic send_and_check_hit(
        input [7:0]   mtype,
        input [63:0]  mstock,
        input [31:0]  midx,
        input [3:0]   expected_sym
    );
        begin
            @(negedge clk);
            i_msg_valid = 1'b1;
            i_msg = 320'd0;
            i_msg[`T2T_MSG_TYPE_HI  : `T2T_MSG_TYPE_LO]  = mtype;
            i_msg[`T2T_MSG_STOCK_HI : `T2T_MSG_STOCK_LO] = mstock;
            i_msg[`T2T_MSG_IDX_HI   : `T2T_MSG_IDX_LO]   = midx;
            i_msg[`T2T_MSG_SHARES_HI: `T2T_MSG_SHARES_LO]= 32'd100;
            i_msg[`T2T_MSG_PRICE_HI : `T2T_MSG_PRICE_LO] = 32'd50000;

            @(negedge clk); // After posedge 1 (Stage 1 captured input)
            i_msg_valid = 1'b0;
            i_msg = 320'd0;

            @(negedge clk); // After posedge 2 (Stage 2 captured Stage 1)
            if (!o_valid || !o_cnt_hit || o_cnt_miss || !fa_hit || fa_sym != expected_sym) begin
                $display("FAILED: valid=%0d hit=%0d miss=%0d fa_hit=%0d fa_sym=%0d (expected sym=%0d)",
                         o_valid, o_cnt_hit, o_cnt_miss, fa_hit, fa_sym, expected_sym);
                $fatal(1);
            end
        end
    endtask

    task automatic send_and_check_miss(
        input [7:0]   mtype,
        input [63:0]  mstock,
        input [31:0]  midx
    );
        begin
            @(negedge clk);
            i_msg_valid = 1'b1;
            i_msg = 320'd0;
            i_msg[`T2T_MSG_TYPE_HI  : `T2T_MSG_TYPE_LO]  = mtype;
            i_msg[`T2T_MSG_STOCK_HI : `T2T_MSG_STOCK_LO] = mstock;
            i_msg[`T2T_MSG_IDX_HI   : `T2T_MSG_IDX_LO]   = midx;
            i_msg[`T2T_MSG_SHARES_HI: `T2T_MSG_SHARES_LO]= 32'd100;
            i_msg[`T2T_MSG_PRICE_HI : `T2T_MSG_PRICE_LO] = 32'd50000;

            @(negedge clk); // After posedge 1 (Stage 1 captured input)
            i_msg_valid = 1'b0;
            i_msg = 320'd0;

            @(negedge clk); // After posedge 2 (Stage 2 captured Stage 1)
            if (o_valid || !o_cnt_miss || o_cnt_hit) begin
                $display("FAILED: Expected miss, got valid=%0d hit=%0d miss=%0d",
                         o_valid, o_cnt_hit, o_cnt_miss);
                $fatal(1);
            end
        end
    endtask

    task automatic send_and_check_passthrough(
        input [7:0]   mtype,
        input [63:0]  mstock,
        input [31:0]  midx
    );
        begin
            @(negedge clk);
            i_msg_valid = 1'b1;
            i_msg = 320'd0;
            i_msg[`T2T_MSG_TYPE_HI  : `T2T_MSG_TYPE_LO]  = mtype;
            i_msg[`T2T_MSG_STOCK_HI : `T2T_MSG_STOCK_LO] = mstock;
            i_msg[`T2T_MSG_IDX_HI   : `T2T_MSG_IDX_LO]   = midx;
            i_msg[`T2T_MSG_SHARES_HI: `T2T_MSG_SHARES_LO]= 32'd100;
            i_msg[`T2T_MSG_PRICE_HI : `T2T_MSG_PRICE_LO] = 32'd50000;

            @(negedge clk); // After posedge 1 (Stage 1 captured input)
            i_msg_valid = 1'b0;
            i_msg = 320'd0;

            @(negedge clk); // After posedge 2 (Stage 2 captured Stage 1)
            if (!o_valid || o_cnt_hit || o_cnt_miss || fa_hit || fa_sym != 4'd0) begin
                $display("FAILED: Expected non-add passthrough, got valid=%0d fa_hit=%0d fa_sym=%0d",
                         o_valid, fa_hit, fa_sym);
                $fatal(1);
            end
        end
    endtask

    initial begin
        reg [63:0] test_stocks [0:7];
        integer s;

        test_stocks[0] = "AAPL    ";
        test_stocks[1] = "SPY     ";
        test_stocks[2] = "MSFT    ";
        test_stocks[3] = "QQQ     ";
        test_stocks[4] = "NVDA    ";
        test_stocks[5] = "AMZN    ";
        test_stocks[6] = "TSLA    ";
        test_stocks[7] = "META    ";

        $display("=============================================================================");
        $display("SF-1: t2t_symfilter Verification (sub-cases a through e)");
        $display("=============================================================================");

        i_msg_valid = 1'b0;
        i_msg       = 320'd0;
        i_cfg_stock = 512'd0;

        for (s = 0; s < 8; s = s + 1) begin
            set_slot(s[2:0], test_stocks[s]);
        end

        rst = 1'b1;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ---------------------------------------------------------------------
        // SF-1(a): A hit on each of 8 slots
        // ---------------------------------------------------------------------
        $display("[SF-1.a] Testing hits on each of 8 slots...");
        for (s = 0; s < 8; s = s + 1) begin
            send_and_check_hit(`T2T_TYPE_A, test_stocks[s], 32'd100 + s, s[3:0]);
        end
        // Also test Type 'F' (Add Order MPID) on slot 0
        send_and_check_hit(`T2T_TYPE_F, test_stocks[0], 32'd108, 4'd0);
        $display("  PASS: All 8 slots hit with exact symbol index.");

        // ---------------------------------------------------------------------
        // SF-1(b): Near misses do not hit
        // ---------------------------------------------------------------------
        $display("[SF-1.b] Testing near misses...");
        send_and_check_miss(`T2T_TYPE_A, "aapl    ", 32'd201); // lowercase
        send_and_check_miss(`T2T_TYPE_A, {"AAPL", 32'd0}, 32'd202); // null-padded
        send_and_check_miss(`T2T_TYPE_A, " AAPL   ", 32'd203); // left space-padded
        $display("  PASS: Near misses rejected and pulsed o_cnt_miss.");

        // ---------------------------------------------------------------------
        // SF-1(c): Non-add types always pass (hit=0, sym=0)
        // ---------------------------------------------------------------------
        $display("[SF-1.c] Testing non-add types (E, C, X, D, U)...");
        send_and_check_passthrough(`T2T_TYPE_E, 64'd0, 32'd301);
        send_and_check_passthrough(`T2T_TYPE_C, "UNKNOWN ", 32'd302);
        send_and_check_passthrough(`T2T_TYPE_X, 64'd0, 32'd303);
        send_and_check_passthrough(`T2T_TYPE_D, 64'd0, 32'd304);
        send_and_check_passthrough(`T2T_TYPE_U, 64'd0, 32'd305);
        $display("  PASS: All non-add types passed with hit=0, sym=0.");

        // ---------------------------------------------------------------------
        // SF-1(d): Duplicate slot stock: lowest wins
        // ---------------------------------------------------------------------
        $display("[SF-1.d] Testing duplicate slot stock priority...");
        // Set slot 1 and slot 5 both to "SPY     "
        set_slot(3'd1, "SPY     ");
        set_slot(3'd5, "SPY     ");
        repeat (2) @(posedge clk);
        send_and_check_hit(`T2T_TYPE_A, "SPY     ", 32'd401, 4'd1);
        $display("  PASS: Duplicate slot resolved to lowest index 1.");

        // ---------------------------------------------------------------------
        // SF-1(e): Unused slot (all-zero stock) never hits
        // ---------------------------------------------------------------------
        $display("[SF-1.e] Testing unused (all-zero) slot...");
        set_slot(3'd7, 64'd0); // Deactivate slot 7
        repeat (2) @(posedge clk);
        send_and_check_miss(`T2T_TYPE_A, 64'd0, 32'd501);
        send_and_check_miss(`T2T_TYPE_A, "META    ", 32'd502);
        $display("  PASS: Inactive all-zero slot never hits.");

        $display("=============================================================================");
        $display("SF-1 RESULT: PASS (All sub-cases a through e verified successfully)");
        $display("=============================================================================");
        $finish;
    end

endmodule
