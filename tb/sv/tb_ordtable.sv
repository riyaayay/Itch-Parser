// =============================================================================
// File        : tb/sv/tb_ordtable.sv
// Spec Section: 8.3, 12.2 (TB-1 sub-cases a through k)
// Description : Unit testbench for t2t_ordtable verifying 4-way set-associative
//               order operations, hazards, sweeps, and replace mechanics.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module tb_ordtable;

    logic         clk = 1'b0;
    logic         rst = 1'b1;

    logic         i_valid;
    logic [324:0] i_fa;
    wire          o_pop;

    logic         i_fb_afull;
    logic         i_init_busy;

    wire          o_op_valid;
    wire [104:0]  o_op;

    wire          o_cnt_ins;
    wire          o_cnt_ref_miss;
    wire          o_cnt_dup_ref;
    wire          o_cnt_set_full;
    wire          o_cnt_qty_underflow;
    wire          o_cnt_same_set_stall;

    always #5 clk = ~clk;

    t2t_ordtable #(
        .TABLE_AW   (9),
        .TABLE_WAYS (4)
    ) dut (
        .clk                  (clk),
        .rst                  (rst),
        .i_valid              (i_valid),
        .i_fa                 (i_fa),
        .o_pop                (o_pop),
        .i_fb_afull           (i_fb_afull),
        .i_init_busy          (i_init_busy),
        .o_op_valid           (o_op_valid),
        .o_op                 (o_op),
        .o_cnt_ins            (o_cnt_ins),
        .o_cnt_ref_miss       (o_cnt_ref_miss),
        .o_cnt_dup_ref        (o_cnt_dup_ref),
        .o_cnt_set_full       (o_cnt_set_full),
        .o_cnt_qty_underflow  (o_cnt_qty_underflow),
        .o_cnt_same_set_stall (o_cnt_same_set_stall)
    );

    // Helpers to unpack o_op
    wire [31:0] op_idx    = o_op[`T2T_OP_IDX_HI    : `T2T_OP_IDX_LO];
    wire [1:0]  op_code   = o_op[`T2T_OP_CODE_HI   : `T2T_OP_CODE_LO];
    wire [3:0]  op_sym    = o_op[`T2T_OP_SYM_HI    : `T2T_OP_SYM_LO];
    wire        op_side   = o_op[`T2T_OP_SIDE_BIT];
    wire        op_remove = o_op[`T2T_OP_REMOVE_BIT];
    wire        op_last   = o_op[`T2T_OP_LAST_BIT];
    wire [31:0] op_price  = o_op[`T2T_OP_PRICE_HI  : `T2T_OP_PRICE_LO];
    wire [31:0] op_qty    = o_op[`T2T_OP_QTY_HI    : `T2T_OP_QTY_LO];

    // FIFO simulation for FA interface
    reg [324:0] fa_fifo_mem [0:63];
    int fa_wr_ptr = 0;
    int fa_rd_ptr = 0;

    always @(posedge clk) begin
        if (rst) begin
            fa_wr_ptr <= 0;
            fa_rd_ptr <= 0;
            i_valid   <= 1'b0;
            i_fa      <= 325'd0;
        end else begin
            if (o_pop && (fa_rd_ptr < fa_wr_ptr)) begin
                fa_rd_ptr <= fa_rd_ptr + 1;
            end

            // Drive i_valid and i_fa
            if (fa_rd_ptr < fa_wr_ptr) begin
                i_valid <= 1'b1;
                i_fa    <= fa_fifo_mem[fa_rd_ptr];
            end else begin
                i_valid <= 1'b0;
                i_fa    <= 325'd0;
            end
        end
    end

    task automatic push_fa(
        input [7:0]   mtype,
        input [3:0]   sym,
        input [63:0]  oref,
        input [63:0]  newref,
        input [7:0]   side_b,
        input [31:0]  shares,
        input [31:0]  price,
        input [31:0]  midx
    );
        reg [324:0] entry;
        begin
            entry = 325'd0;
            entry[`T2T_FA_HIT_BIT]                 = 1'b1;
            entry[`T2T_FA_SYM_HI : `T2T_FA_SYM_LO] = sym;
            entry[`T2T_MSG_TYPE_HI   : `T2T_MSG_TYPE_LO]   = mtype;
            entry[`T2T_MSG_REF_HI    : `T2T_MSG_REF_LO]    = oref;
            entry[`T2T_MSG_NEWREF_HI : `T2T_MSG_NEWREF_LO] = newref;
            entry[`T2T_MSG_SIDE_HI   : `T2T_MSG_SIDE_LO]   = side_b;
            entry[`T2T_MSG_SHARES_HI : `T2T_MSG_SHARES_LO] = shares;
            entry[`T2T_MSG_PRICE_HI  : `T2T_MSG_PRICE_LO]  = price;
            entry[`T2T_MSG_IDX_HI    : `T2T_MSG_IDX_LO]    = midx;

            @(negedge clk);
            fa_fifo_mem[fa_wr_ptr] = entry;
            fa_wr_ptr = fa_wr_ptr + 1;
        end
    endtask

    // Output capture queue
    reg [104:0] q_op [0:63];
    int q_op_wr = 0;
    int q_op_rd = 0;

    always @(posedge clk) begin
        if (!rst) begin
            if (o_op_valid) begin
                q_op[q_op_wr] <= o_op;
                q_op_wr <= q_op_wr + 1;
            end
        end
    end

    task automatic wait_for_op(
        output [1:0]  out_code,
        output [3:0]  out_sym,
        output        out_side,
        output        out_remove,
        output        out_last,
        output [31:0] out_price,
        output [31:0] out_qty
    );
        int timeout;
        begin
            timeout = 0;
            while (q_op_rd >= q_op_wr && timeout < 50) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 50) begin
                $display("TIMEOUT waiting for OP");
                $fatal(1);
            end
            out_code   = q_op[q_op_rd][`T2T_OP_CODE_HI : `T2T_OP_CODE_LO];
            out_sym    = q_op[q_op_rd][`T2T_OP_SYM_HI  : `T2T_OP_SYM_LO];
            out_side   = q_op[q_op_rd][`T2T_OP_SIDE_BIT];
            out_remove = q_op[q_op_rd][`T2T_OP_REMOVE_BIT];
            out_last   = q_op[q_op_rd][`T2T_OP_LAST_BIT];
            out_price  = q_op[q_op_rd][`T2T_OP_PRICE_HI: `T2T_OP_PRICE_LO];
            out_qty    = q_op[q_op_rd][`T2T_OP_QTY_HI  : `T2T_OP_QTY_LO];
            q_op_rd = q_op_rd + 1;
        end
    endtask

    initial begin
        reg [1:0]  c_code;
        reg [3:0]  c_sym;
        reg        c_side;
        reg        c_rem;
        reg        c_last;
        reg [31:0] c_px;
        reg [31:0] c_qty;

        $display("=============================================================================");
        $display("TB-1: t2t_ordtable Verification (sub-cases a through k)");
        $display("=============================================================================");

        i_fb_afull  = 1'b0;
        i_init_busy = 1'b0;

        // Reset DUT
        rst = 1'b1;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        // ---------------------------------------------------------------------
        // TB-1(a): Add then execute partial then execute rest
        // ---------------------------------------------------------------------
        $display("[TB-1.a] Testing Add -> Execute Partial -> Execute Rest...");
        push_fa(`T2T_TYPE_A, 4'd0, 64'd1001, 64'd0, `T2T_ASCII_BUY, 32'd100, 32'd50000, 32'd1);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        if (c_code != `T2T_OP_ADD || c_qty != 32'd100 || c_px != 32'd50000 || c_sym != 4'd0 || c_side != `T2T_SIDE_BID || !c_last || c_rem) begin
            $display("TB-1.a FAILED on Add op: code=%0d qty=%0d px=%0d", c_code, c_qty, c_px);
            $fatal(1);
        end

        // Partial execute 40
        push_fa(`T2T_TYPE_E, 4'd0, 64'd1001, 64'd0, 8'd0, 32'd40, 32'd0, 32'd2);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        if (c_code != `T2T_OP_REDUCE || c_qty != 32'd40 || c_px != 32'd50000 || c_rem != 1'b0 || !c_last) begin
            $display("TB-1.a FAILED on Partial Execute op: code=%0d qty=%0d rem=%0d", c_code, c_qty, c_rem);
            $fatal(1);
        end

        // Execute rest 60
        push_fa(`T2T_TYPE_E, 4'd0, 64'd1001, 64'd0, 8'd0, 32'd60, 32'd0, 32'd3);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        if (c_code != `T2T_OP_REDUCE || c_qty != 32'd60 || c_px != 32'd50000 || c_rem != 1'b1 || !c_last) begin
            $display("TB-1.a FAILED on Execute Rest op: code=%0d qty=%0d rem=%0d", c_code, c_qty, c_rem);
            $fatal(1);
        end
        $display("  PASS: Add -> Execute Partial -> Execute Rest verified.");

        // ---------------------------------------------------------------------
        // TB-1(b): Cancel partial
        // ---------------------------------------------------------------------
        $display("[TB-1.b] Testing Cancel Partial...");
        push_fa(`T2T_TYPE_A, 4'd1, 64'd2001, 64'd0, `T2T_ASCII_SELL, 32'd80, 32'd60000, 32'd4);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);

        push_fa(`T2T_TYPE_X, 4'd0, 64'd2001, 64'd0, 8'd0, 32'd30, 32'd0, 32'd5);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        if (c_code != `T2T_OP_REDUCE || c_qty != 32'd30 || c_px != 32'd60000 || c_side != `T2T_SIDE_ASK || c_rem != 1'b0) begin
            $display("TB-1.b FAILED: Cancel partial failed");
            $fatal(1);
        end
        $display("  PASS: Cancel Partial verified.");

        // ---------------------------------------------------------------------
        // TB-1(c): Delete
        // ---------------------------------------------------------------------
        $display("[TB-1.c] Testing Delete...");
        push_fa(`T2T_TYPE_A, 4'd2, 64'd3001, 64'd0, `T2T_ASCII_BUY, 32'd50, 32'd70000, 32'd6);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);

        push_fa(`T2T_TYPE_D, 4'd0, 64'd3001, 64'd0, 8'd0, 32'd0, 32'd0, 32'd7);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        if (c_code != `T2T_OP_REDUCE || c_qty != 32'd50 || c_px != 32'd70000 || c_rem != 1'b1) begin
            $display("TB-1.c FAILED: Delete failed");
            $fatal(1);
        end
        $display("  PASS: Delete verified.");

        // ---------------------------------------------------------------------
        // TB-1(d): Replace
        // ---------------------------------------------------------------------
        $display("[TB-1.d] Testing Replace...");
        push_fa(`T2T_TYPE_A, 4'd3, 64'd4001, 64'd0, `T2T_ASCII_SELL, 32'd150, 32'd80000, 32'd8);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);

        // Replace old ref 4001 with new ref 4002, price 81000, shares 200
        push_fa(`T2T_TYPE_U, 4'd0, 64'd4001, 64'd4002, 8'd0, 32'd200, 32'd81000, 32'd9);
        // Sub-op 1: REDUCE(old px 80000, old shares 150, remove=1, last=0)
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        if (c_code != `T2T_OP_REDUCE || c_qty != 32'd150 || c_px != 32'd80000 || c_rem != 1'b1 || c_last != 1'b0) begin
            $display("TB-1.d FAILED on sub-op 1: code=%0d qty=%0d px=%0d rem=%0d last=%0d", c_code, c_qty, c_px, c_rem, c_last);
            $fatal(1);
        end

        // Sub-op 2: ADD(sym 3, side ask, new px 81000, new shares 200, remove=0, last=1)
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        if (c_code != `T2T_OP_ADD || c_qty != 32'd200 || c_px != 32'd81000 || c_sym != 4'd3 || c_side != `T2T_SIDE_ASK || !c_last || c_rem) begin
            $display("TB-1.d FAILED on sub-op 2: code=%0d qty=%0d px=%0d sym=%0d last=%0d", c_code, c_qty, c_px, c_sym, c_last);
            $fatal(1);
        end
        $display("  PASS: Replace 2-step atomic operation verified.");

        // ---------------------------------------------------------------------
        // TB-1(e): Benign reference miss
        // ---------------------------------------------------------------------
        $display("[TB-1.e] Testing Benign Miss...");
        push_fa(`T2T_TYPE_E, 4'd0, 64'd99999, 64'd0, 8'd0, 32'd50, 32'd0, 32'd10);
        repeat (10) @(posedge clk);
        if (q_op_rd < q_op_wr) begin
            $display("TB-1.e FAILED: Unexpected op emitted on reference miss");
            $fatal(1);
        end
        $display("  PASS: Benign reference miss produced no op.");

        // ---------------------------------------------------------------------
        // TB-1(f): Duplicate ref gives CORRUPT
        // ---------------------------------------------------------------------
        $display("[TB-1.f] Testing Duplicate Reference Hazard...");
        push_fa(`T2T_TYPE_A, 4'd4, 64'd5001, 64'd0, `T2T_ASCII_BUY, 32'd100, 32'd50000, 32'd11);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);

        // Add duplicate ref 5001
        push_fa(`T2T_TYPE_A, 4'd4, 64'd5001, 64'd0, `T2T_ASCII_BUY, 32'd100, 32'd50000, 32'd12);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        if (c_code != `T2T_OP_CORRUPT || !c_last) begin
            $display("TB-1.f FAILED: Duplicate ref did not emit CORRUPT");
            $fatal(1);
        end
        $display("  PASS: Duplicate reference produced CORRUPT.");

        // ---------------------------------------------------------------------
        // TB-1(g): Set full (5 refs in one set) gives CORRUPT
        // ---------------------------------------------------------------------
        $display("[TB-1.g] Testing Set Full Hazard...");
        // Use set 15 (all refs with ref % 512 == 15)
        push_fa(`T2T_TYPE_A, 4'd0, 64'd15,        64'd0, `T2T_ASCII_BUY, 32'd10, 32'd1000, 32'd13);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        push_fa(`T2T_TYPE_A, 4'd0, 64'(15+512),  64'd0, `T2T_ASCII_BUY, 32'd20, 32'd1000, 32'd14);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        push_fa(`T2T_TYPE_A, 4'd0, 64'(15+1024), 64'd0, `T2T_ASCII_BUY, 32'd30, 32'd1000, 32'd15);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        push_fa(`T2T_TYPE_A, 4'd0, 64'(15+1536), 64'd0, `T2T_ASCII_BUY, 32'd40, 32'd1000, 32'd16);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);

        // 5th ref in set 15: must fail with set_full -> CORRUPT
        push_fa(`T2T_TYPE_A, 4'd0, 64'(15+2048), 64'd0, `T2T_ASCII_BUY, 32'd50, 32'd1000, 32'd17);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        if (c_code != `T2T_OP_CORRUPT || !c_last) begin
            $display("TB-1.g FAILED: 5th way in set did not emit CORRUPT");
            $fatal(1);
        end
        $display("  PASS: Set full produced CORRUPT.");

        // ---------------------------------------------------------------------
        // TB-1(h): Execute more than resting gives CORRUPT
        // ---------------------------------------------------------------------
        $display("[TB-1.h] Testing Quantity Underflow Hazard...");
        push_fa(`T2T_TYPE_A, 4'd5, 64'd6001, 64'd0, `T2T_ASCII_BUY, 32'd50, 32'd25000, 32'd18);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);

        // Execute 60 when only 50 resting
        push_fa(`T2T_TYPE_E, 4'd0, 64'd6001, 64'd0, 8'd0, 32'd60, 32'd0, 32'd19);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        if (c_code != `T2T_OP_CORRUPT || !c_last) begin
            $display("TB-1.h FAILED: Quantity underflow did not emit CORRUPT");
            $fatal(1);
        end
        $display("  PASS: Quantity underflow produced CORRUPT.");

        // ---------------------------------------------------------------------
        // TB-1(i): Same-set back-to-back obeys the hold and order of effects
        // ---------------------------------------------------------------------
        $display("[TB-1.i] Testing Same-Set Back-to-Back Hazard...");
        // Push Add ref=7001, and immediately next cycle Execute ref=7001
        push_fa(`T2T_TYPE_A, 4'd6, 64'd7001, 64'd0, `T2T_ASCII_BUY, 32'd100, 32'd33000, 32'd20);
        push_fa(`T2T_TYPE_E, 4'd0, 64'd7001, 64'd0, 8'd0,           32'd100, 32'd0,     32'd21);

        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        if (c_code != `T2T_OP_ADD || c_qty != 32'd100) begin
            $display("TB-1.i FAILED on Add");
            $fatal(1);
        end

        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        if (c_code != `T2T_OP_REDUCE || c_qty != 32'd100 || c_rem != 1'b1) begin
            $display("TB-1.i FAILED on Execute");
            $fatal(1);
        end
        $display("  PASS: Same-set back-to-back obeyed stall and preserved order of effects.");

        // ---------------------------------------------------------------------
        // TB-1(j): Sweep after session reset
        // ---------------------------------------------------------------------
        $display("[TB-1.j] Testing Sweep after Session Reset...");
        // Add order 8001
        push_fa(`T2T_TYPE_A, 4'd7, 64'd8001, 64'd0, `T2T_ASCII_BUY, 32'd100, 32'd44000, 32'd22);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);

        // Perform init sweep (512 cycles)
        i_init_busy = 1'b1;
        repeat (520) @(posedge clk);
        i_init_busy = 1'b0;
        repeat (5) @(posedge clk);

        // Try to execute order 8001: must give reference miss
        push_fa(`T2T_TYPE_E, 4'd0, 64'd8001, 64'd0, 8'd0, 32'd100, 32'd0, 32'd23);
        repeat (10) @(posedge clk);
        if (q_op_rd < q_op_wr) begin
            $display("TB-1.j FAILED: Order survived init sweep");
            $fatal(1);
        end
        $display("  PASS: Init sweep wiped table clean; subsequent lookup missed.");

        // ---------------------------------------------------------------------
        // TB-1(k): Replace where old and new share a set
        // ---------------------------------------------------------------------
        $display("[TB-1.k] Testing Replace where old and new share a set...");
        // Set 25: fill 3 other ways
        push_fa(`T2T_TYPE_A, 4'd0, 64'(25+512),  64'd0, `T2T_ASCII_BUY, 32'd10, 32'd1000, 32'd24);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        push_fa(`T2T_TYPE_A, 4'd0, 64'(25+1024), 64'd0, `T2T_ASCII_BUY, 32'd20, 32'd1000, 32'd25);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        push_fa(`T2T_TYPE_A, 4'd0, 64'(25+1536), 64'd0, `T2T_ASCII_BUY, 32'd30, 32'd1000, 32'd26);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);

        // Add 4th way: old_ref = 25
        push_fa(`T2T_TYPE_A, 4'd2, 64'd25, 64'd0, `T2T_ASCII_BUY, 32'd50, 32'd2000, 32'd27);
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);

        // Now all 4 ways of set 25 are full!
        // Replace old_ref 25 with new_ref (25 + 2048) which is IN THE SAME SET!
        push_fa(`T2T_TYPE_U, 4'd0, 64'd25, 64'(25+2048), 8'd0, 32'd75, 32'd2100, 32'd28);

        // Sub-op 1: REDUCE(remove=1, last=0)
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        if (c_code != `T2T_OP_REDUCE || c_rem != 1'b1 || c_last != 1'b0) begin
            $display("TB-1.k FAILED on sub-op 1: code=%0d rem=%0d last=%0d", c_code, c_rem, c_last);
            $fatal(1);
        end

        // Sub-op 2: ADD(new_ref, remove=0, last=1)
        wait_for_op(c_code, c_sym, c_side, c_rem, c_last, c_px, c_qty);
        if (c_code != `T2T_OP_ADD || c_qty != 32'd75 || c_px != 32'd2100 || !c_last || c_rem) begin
            $display("TB-1.k FAILED on sub-op 2: code=%0d qty=%0d px=%0d last=%0d", c_code, c_qty, c_px, c_last);
            $fatal(1);
        end
        $display("  PASS: Replace within same full set succeeded without set_full hazard.");

        $display("=============================================================================");
        $display("TB-1 RESULT: PASS (All sub-cases a through k verified successfully)");
        $display("=============================================================================");
        $finish;
    end

endmodule
