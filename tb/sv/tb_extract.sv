// =============================================================================
// File        : tb/sv/tb_extract.sv
// Spec Section: 7.3, 12.2 (EX-1 sub-cases a through h)
// Description : Unit testbench for t2t_extract verifying all 7 handled ITCH types
//               and error conditions (bad length, zero length, unhandled types).
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module tb_extract;

    logic        clk = 1'b0;
    logic        rst = 1'b1;

    logic        i_blk_valid;
    logic [31:0] i_blk_idx;
    logic [7:0]  i_blk_len;
    logic [399:0] i_blk_bytes;

    wire         o_msg_valid;
    wire [319:0] o_msg;
    wire [3:0]   o_blk_flags;
    wire [6:0]   o_cnt_type;
    wire         o_cnt_other;
    wire         o_cnt_zero;
    wire         o_cnt_badlen;
    wire         o_session_invalid;

    always #5 clk = ~clk;

    t2t_extract dut (
        .clk               (clk),
        .rst               (rst),
        .i_blk_valid       (i_blk_valid),
        .i_blk_idx         (i_blk_idx),
        .i_blk_len         (i_blk_len),
        .i_blk_bytes       (i_blk_bytes),
        .o_msg_valid       (o_msg_valid),
        .o_msg             (o_msg),
        .o_blk_flags       (o_blk_flags),
        .o_cnt_type        (o_cnt_type),
        .o_cnt_other       (o_cnt_other),
        .o_cnt_zero        (o_cnt_zero),
        .o_cnt_badlen      (o_cnt_badlen),
        .o_session_invalid (o_session_invalid)
    );

    // Helpers to unpack o_msg fields
    wire [31:0] msg_idx    = o_msg[`T2T_MSG_IDX_HI    : `T2T_MSG_IDX_LO];
    wire [7:0]  msg_type   = o_msg[`T2T_MSG_TYPE_HI   : `T2T_MSG_TYPE_LO];
    wire [15:0] msg_locate = o_msg[`T2T_MSG_LOCATE_HI : `T2T_MSG_LOCATE_LO];
    wire [63:0] msg_ref    = o_msg[`T2T_MSG_REF_HI    : `T2T_MSG_REF_LO];
    wire [63:0] msg_newref = o_msg[`T2T_MSG_NEWREF_HI : `T2T_MSG_NEWREF_LO];
    wire [7:0]  msg_side   = o_msg[`T2T_MSG_SIDE_HI   : `T2T_MSG_SIDE_LO];
    wire [31:0] msg_shares = o_msg[`T2T_MSG_SHARES_HI : `T2T_MSG_SHARES_LO];
    wire [31:0] msg_price  = o_msg[`T2T_MSG_PRICE_HI  : `T2T_MSG_PRICE_LO];
    wire [63:0] msg_stock  = o_msg[`T2T_MSG_STOCK_HI  : `T2T_MSG_STOCK_LO];

    reg [399:0] b;

    task automatic set_byte(input [6:0] idx, input [7:0] val);
        b[8*idx +: 8] = val;
    endtask

    task automatic set_be16(input [6:0] idx, input [15:0] val);
        b[8*idx       +: 8] = val[15:8];
        b[8*(idx+7'd1)+: 8] = val[7:0];
    endtask

    task automatic set_be32(input [6:0] idx, input [31:0] val);
        b[8*idx       +: 8] = val[31:24];
        b[8*(idx+7'd1)+: 8] = val[23:16];
        b[8*(idx+7'd2)+: 8] = val[15:8];
        b[8*(idx+7'd3)+: 8] = val[7:0];
    endtask

    task automatic set_be64(input [6:0] idx, input [63:0] val);
        b[8*idx       +: 8] = val[63:56];
        b[8*(idx+7'd1)+: 8] = val[55:48];
        b[8*(idx+7'd2)+: 8] = val[47:40];
        b[8*(idx+7'd3)+: 8] = val[39:32];
        b[8*(idx+7'd4)+: 8] = val[31:24];
        b[8*(idx+7'd5)+: 8] = val[23:16];
        b[8*(idx+7'd6)+: 8] = val[15:8];
        b[8*(idx+7'd7)+: 8] = val[7:0];
    endtask

    task automatic send_blk(
        input [31:0]  idx,
        input [7:0]   len
    );
        begin
            i_blk_valid = 1'b1;
            i_blk_idx   = idx;
            i_blk_len   = len;
            i_blk_bytes = b;
            @(posedge clk);
            #1; // Sample post-clock-edge registered outputs
            i_blk_valid = 1'b0;
            i_blk_bytes = 400'd0;
        end
    endtask

    initial begin
        $display("=============================================================================");
        $display("EX-1: t2t_extract Unit Verification (sub-cases a through h)");
        $display("=============================================================================");

        i_blk_valid = 1'b0;
        i_blk_idx   = 32'd0;
        i_blk_len   = 8'd0;
        i_blk_bytes = 400'd0;

        rst = 1'b1;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // ---------------------------------------------------------------------
        // EX-1(a): Type 'A' (Add Order, 36 bytes)
        // ---------------------------------------------------------------------
        $display("[EX-1.a] Testing Type 'A' (Add Order)...");
        b = 400'd0;
        set_byte(7'd0,  8'h41);                      // 'A'
        set_be16(7'd1,  16'h1234);                   // locate = 0x1234
        set_be64(7'd11, 64'h0123456789ABCDEF);       // ref
        set_byte(7'd19, 8'h42);                      // 'B' (Buy)
        set_be32(7'd20, 32'd100);                    // shares = 100
        set_be64(7'd24, "AAPL    ");                 // stock
        set_be32(7'd32, 32'd5953500);                // price = 5953500
        send_blk(32'd1, 8'd36);

        if (!o_msg_valid || msg_type != `T2T_TYPE_A || msg_locate != 16'h1234 ||
            msg_ref != 64'h0123456789ABCDEF || msg_side != 8'h42 ||
            msg_shares != 32'd100 || msg_stock != "AAPL    " ||
            msg_price != 32'd5953500 || o_cnt_type[0] != 1'b1) begin
            $display("EX-1.a FAILED: Mismatch on Type 'A' fields: valid=%0d type=0x%02x loc=0x%04x ref=0x%016x side=0x%02x shares=%0d stock='%s' price=%0d cnt_type=0x%02x",
                     o_msg_valid, msg_type, msg_locate, msg_ref, msg_side, msg_shares, msg_stock, msg_price, o_cnt_type);
            $fatal(1);
        end
        $display("  PASS: Type 'A' decoded successfully.");

        // ---------------------------------------------------------------------
        // EX-1(b): Type 'F' (Add Order with MPID, 40 bytes)
        // ---------------------------------------------------------------------
        $display("[EX-1.b] Testing Type 'F' (Add Order MPID)...");
        b = 400'd0;
        set_byte(7'd0,  8'h46);                      // 'F'
        set_be16(7'd1,  16'h0042);                   // locate = 0x0042
        set_be64(7'd11, 64'hCAFEBABE00000001);       // ref
        set_byte(7'd19, 8'h53);                      // 'S' (Sell)
        set_be32(7'd20, 32'd500);                    // shares = 500
        set_be64(7'd24, "MSFT    ");                 // stock
        set_be32(7'd32, 32'd200000);                 // price = 200000
        set_be32(7'd36, "GSCO");                     // MPID
        send_blk(32'd2, 8'd40);

        if (!o_msg_valid || msg_type != `T2T_TYPE_F || msg_locate != 16'h0042 ||
            msg_ref != 64'hCAFEBABE00000001 || msg_side != 8'h53 ||
            msg_shares != 32'd500 || msg_stock != "MSFT    " ||
            msg_price != 32'd200000 || o_cnt_type[1] != 1'b1) begin
            $display("EX-1.b FAILED: Mismatch on Type 'F' fields");
            $fatal(1);
        end
        $display("  PASS: Type 'F' decoded successfully.");

        // ---------------------------------------------------------------------
        // EX-1(c): Type 'E' (Order Executed, 31 bytes)
        // ---------------------------------------------------------------------
        $display("[EX-1.c] Testing Type 'E' (Order Executed)...");
        b = 400'd0;
        set_byte(7'd0,  8'h45);                      // 'E'
        set_be16(7'd1,  16'h0010);                   // locate = 0x0010
        set_be64(7'd11, 64'h0123456789ABCDEF);       // ref
        set_be32(7'd19, 32'd50);                     // executed shares = 50
        set_be64(7'd23, 64'h99999999);               // match number
        send_blk(32'd3, 8'd31);

        if (!o_msg_valid || msg_type != `T2T_TYPE_E || msg_locate != 16'h0010 ||
            msg_ref != 64'h0123456789ABCDEF || msg_shares != 32'd50 ||
            o_cnt_type[2] != 1'b1) begin
            $display("EX-1.c FAILED: Mismatch on Type 'E' fields");
            $fatal(1);
        end
        $display("  PASS: Type 'E' decoded successfully.");

        // ---------------------------------------------------------------------
        // EX-1(d): Type 'C' (Order Executed with Price, 36 bytes)
        // ---------------------------------------------------------------------
        $display("[EX-1.d] Testing Type 'C' (Order Executed with Price)...");
        b = 400'd0;
        set_byte(7'd0,  8'h43);                      // 'C'
        set_be16(7'd1,  16'h0020);                   // locate = 0x0020
        set_be64(7'd11, 64'h0123456789ABCDEF);       // ref
        set_be32(7'd19, 32'd25);                     // executed shares = 25
        set_be64(7'd23, 64'h88888888);               // match number
        set_byte(7'd31, "Y");                        // printable
        set_be32(7'd32, 32'd5953500);                // price = 5953500
        send_blk(32'd4, 8'd36);

        if (!o_msg_valid || msg_type != `T2T_TYPE_C || msg_locate != 16'h0020 ||
            msg_ref != 64'h0123456789ABCDEF || msg_shares != 32'd25 ||
            msg_price != 32'd5953500 || o_cnt_type[3] != 1'b1) begin
            $display("EX-1.d FAILED: Mismatch on Type 'C' fields");
            $fatal(1);
        end
        $display("  PASS: Type 'C' decoded successfully.");

        // ---------------------------------------------------------------------
        // EX-1(e): Type 'X' (Order Cancel, 23 bytes)
        // ---------------------------------------------------------------------
        $display("[EX-1.e] Testing Type 'X' (Order Cancel)...");
        b = 400'd0;
        set_byte(7'd0,  8'h58);                      // 'X'
        set_be16(7'd1,  16'h0030);                   // locate = 0x0030
        set_be64(7'd11, 64'h0123456789ABCDEF);       // ref
        set_be32(7'd19, 32'd10);                     // cancelled shares = 10
        send_blk(32'd5, 8'd23);

        if (!o_msg_valid || msg_type != `T2T_TYPE_X || msg_locate != 16'h0030 ||
            msg_ref != 64'h0123456789ABCDEF || msg_shares != 32'd10 ||
            o_cnt_type[4] != 1'b1) begin
            $display("EX-1.e FAILED: Mismatch on Type 'X' fields");
            $fatal(1);
        end
        $display("  PASS: Type 'X' decoded successfully.");

        // ---------------------------------------------------------------------
        // EX-1(f): Type 'D' (Order Delete, 19 bytes)
        // ---------------------------------------------------------------------
        $display("[EX-1.f] Testing Type 'D' (Order Delete)...");
        b = 400'd0;
        set_byte(7'd0,  8'h44);                      // 'D'
        set_be16(7'd1,  16'h0040);                   // locate = 0x0040
        set_be64(7'd11, 64'h0123456789ABCDEF);       // ref
        send_blk(32'd6, 8'd19);

        if (!o_msg_valid || msg_type != `T2T_TYPE_D || msg_locate != 16'h0040 ||
            msg_ref != 64'h0123456789ABCDEF || o_cnt_type[5] != 1'b1) begin
            $display("EX-1.f FAILED: Mismatch on Type 'D' fields");
            $fatal(1);
        end
        $display("  PASS: Type 'D' decoded successfully.");

        // ---------------------------------------------------------------------
        // EX-1(g): Type 'U' (Order Replace, 35 bytes)
        // ---------------------------------------------------------------------
        $display("[EX-1.g] Testing Type 'U' (Order Replace)...");
        b = 400'd0;
        set_byte(7'd0,  8'h55);                      // 'U'
        set_be16(7'd1,  16'h0050);                   // locate = 0x0050
        set_be64(7'd11, 64'h0123456789ABCDEF);       // old ref
        set_be64(7'd19, 64'hFEDCBA9876543210);       // new ref
        set_be32(7'd27, 32'd200);                    // new shares = 200
        set_be32(7'd31, 32'd5953536);                // new price = 5953536
        send_blk(32'd7, 8'd35);

        if (!o_msg_valid || msg_type != `T2T_TYPE_U || msg_locate != 16'h0050 ||
            msg_ref != 64'h0123456789ABCDEF || msg_newref != 64'hFEDCBA9876543210 ||
            msg_shares != 32'd200 || msg_price != 32'd5953536 || o_cnt_type[6] != 1'b1) begin
            $display("EX-1.g FAILED: Mismatch on Type 'U' fields");
            $fatal(1);
        end
        $display("  PASS: Type 'U' decoded successfully.");

        // ---------------------------------------------------------------------
        // EX-1(h): Known type with wrong length -> o_cnt_badlen & o_session_invalid
        // ---------------------------------------------------------------------
        $display("[EX-1.h] Testing Bad Length and Error Conditions...");
        b = 400'd0;
        set_byte(7'd0, 8'h41); // 'A' expects 36 bytes, give 35
        send_blk(32'd8, 8'd35);

        if (o_msg_valid || !o_cnt_badlen || !o_session_invalid) begin
            $display("EX-1.h FAILED: Expected badlen and session_invalid pulse");
            $fatal(1);
        end
        $display("  PASS: Bad length detected correctly.");

        // Zero-length block check
        b = 400'd0;
        send_blk(32'd9, 8'd0);
        if (o_msg_valid || !o_cnt_zero) begin
            $display("EX-1.h FAILED: Expected cnt_zero on length 0");
            $fatal(1);
        end
        $display("  PASS: Zero-length block detected correctly.");

        // Unhandled ITCH type check (e.g., 'S' System Event)
        b = 400'd0;
        set_byte(7'd0, 8'h53); // 'S'
        send_blk(32'd10, 8'd12);
        if (o_msg_valid || !o_cnt_other) begin
            $display("EX-1.h FAILED: Expected cnt_other on unhandled type");
            $fatal(1);
        end
        $display("  PASS: Unhandled type detected correctly.");

        $display("=============================================================================");
        $display("EX-1 RESULT: PASS (All sub-cases a through h verified successfully)");
        $display("=============================================================================");
        $finish;
    end

endmodule
