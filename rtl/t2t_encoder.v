// =============================================================================
// File        : rtl/t2t_encoder.v
// Spec Section: 6.2, 11.1 (Outbound OUCH Enter Order Frame Builder & TXF Interface)
// Description : Pipeline Stage S9: Formats 48-byte OUCH Enter Order frames,
//               advances monotonic user_ref counter, handles TXF overflow
//               fault detection, and drives AXI-Stream framing.
// Latency     : 1 registered cycle.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module t2t_encoder #(
    parameter N_SYMBOLS = `T2T_N_SYMBOLS
) (
    input  wire                               clk,
    input  wire                               rst,

    // Fault clearing (from CTRL.clear_fault)
    input  wire                               i_clear_fault,

    // Stock symbols configuration (8 * 64 bits = 512 bits)
    input  wire [N_SYMBOLS*64-1:0]            i_cfg_stock,

    // Decision interface from S8 Risk
    input  wire                               i_dec_valid,
    input  wire                               i_dec_pass,
    input  wire [3:0]                         i_dec_reason,
    input  wire [3:0]                         i_dec_sym,
    input  wire                               i_dec_side,
    input  wire [31:0]                        i_dec_price,
    input  wire [15:0]                        i_dec_qty,
    input  wire [1:0]                         i_dec_rule,
    input  wire [31:0]                        i_dec_idx,

    // TX FIFO Interface
    input  wire                               i_txf_full,
    output reg                                o_txf_push,
    output reg  [511:0]                       o_txf_data,
    output reg  [63:0]                        o_txf_keep,
    output reg                                o_txf_last,

    // Fault & Diagnostic Status
    output reg                                o_tx_fault,
    output reg                                o_cnt_tx_frames,
    output reg                                o_cnt_tx_overflow
);

    // -------------------------------------------------------------------------
    // Monotonic User Reference Counter (Section 6.2)
    // First order = 1, reset only by hardware rst
    // -------------------------------------------------------------------------
    reg [31:0] user_ref_counter;

    // Extract stock for the decided symbol
    wire [2:0] sym_idx = i_dec_sym[2:0];
    reg [63:0] stock_bytes;
    integer c;
    always @(*) begin
        stock_bytes = i_cfg_stock[63:0];
        for (c = 0; c < N_SYMBOLS; c = c + 1) begin
            if (sym_idx == c[2:0]) begin
                stock_bytes = i_cfg_stock[c*64 +: 64];
            end
        end
    end

    // Pre-calculate frame layout (combinational)
    wire [31:0] next_user_ref = user_ref_counter + 32'd1;

    reg [511:0] frame_data;
    always @(*) begin
        frame_data = 512'd0;

        // Offset  0: type 0x4F ('O')
        frame_data[8*0 +: 8] = `T2T_OUCH_TYPE_ENTER;

        // Offset  1..4: user_ref (Big-Endian)
        frame_data[8*1 +: 8] = next_user_ref[31:24];
        frame_data[8*2 +: 8] = next_user_ref[23:16];
        frame_data[8*3 +: 8] = next_user_ref[15:8];
        frame_data[8*4 +: 8] = next_user_ref[7:0];

        // Offset  5: side ('B' 0x42 or 'S' 0x53)
        frame_data[8*5 +: 8] = (i_dec_side == `T2T_SIDE_BID) ? 8'h42 : 8'h53;

        // Offset  6..9: quantity (32-bit zero-extended Big-Endian)
        frame_data[8*6 +: 8] = 8'h00;
        frame_data[8*7 +: 8] = 8'h00;
        frame_data[8*8 +: 8] = i_dec_qty[15:8];
        frame_data[8*9 +: 8] = i_dec_qty[7:0];

        // Offset 10..17: stock (8 ASCII bytes)
        frame_data[8*10 +: 8] = stock_bytes[63:56];
        frame_data[8*11 +: 8] = stock_bytes[55:48];
        frame_data[8*12 +: 8] = stock_bytes[47:40];
        frame_data[8*13 +: 8] = stock_bytes[39:32];
        frame_data[8*14 +: 8] = stock_bytes[31:24];
        frame_data[8*15 +: 8] = stock_bytes[23:16];
        frame_data[8*16 +: 8] = stock_bytes[15:8];
        frame_data[8*17 +: 8] = stock_bytes[7:0];

        // Offset 18..21: price (32-bit Big-Endian)
        frame_data[8*18 +: 8] = i_dec_price[31:24];
        frame_data[8*19 +: 8] = i_dec_price[23:16];
        frame_data[8*20 +: 8] = i_dec_price[15:8];
        frame_data[8*21 +: 8] = i_dec_price[7:0];

        // Offset 22..25: time_in_force (IOC = 0x00000000)
        frame_data[8*22 +: 8] = 8'h00;
        frame_data[8*23 +: 8] = 8'h00;
        frame_data[8*24 +: 8] = 8'h00;
        frame_data[8*25 +: 8] = 8'h00;

        // Offset 26: display 0x59 ('Y')
        frame_data[8*26 +: 8] = `T2T_OUCH_DISPLAY;

        // Offset 27: capacity 0x50 ('P')
        frame_data[8*27 +: 8] = `T2T_OUCH_CAPACITY;

        // Offset 28: intermarket sweep 0x4E ('N')
        frame_data[8*28 +: 8] = `T2T_OUCH_ISO;

        // Offset 29..32: minimum quantity (0)
        frame_data[8*29 +: 8] = 8'h00;
        frame_data[8*30 +: 8] = 8'h00;
        frame_data[8*31 +: 8] = 8'h00;
        frame_data[8*32 +: 8] = 8'h00;

        // Offset 33: cross type 0x4E ('N')
        frame_data[8*33 +: 8] = `T2T_OUCH_CROSS_TYPE;

        // Offset 34: customer type 0x4E ('N')
        frame_data[8*34 +: 8] = `T2T_OUCH_CUST_TYPE;

        // Offset 35..36: appendage length 0x0000
        frame_data[8*35 +: 8] = 8'h00;
        frame_data[8*36 +: 8] = 8'h00;

        // Offset 37..40: trigger_idx (cand_idx Big-Endian)
        frame_data[8*37 +: 8] = i_dec_idx[31:24];
        frame_data[8*38 +: 8] = i_dec_idx[23:16];
        frame_data[8*39 +: 8] = i_dec_idx[15:8];
        frame_data[8*40 +: 8] = i_dec_idx[7:0];

        // Offset 41: rule_id (1 byte)
        frame_data[8*41 +: 8] = {6'd0, i_dec_rule};

        // Offsets 42..47: pad (6 zero bytes) -> already 0
        // Offsets 48..63: trailing padding -> already 0
    end

    // -------------------------------------------------------------------------
    // Registered Stage & Fault State Machine (Section 11.1)
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            user_ref_counter  <= 32'd0;
            o_txf_push        <= 1'b0;
            o_txf_data        <= 512'd0;
            o_txf_keep        <= 64'd0;
            o_txf_last        <= 1'b0;
            o_tx_fault        <= 1'b0;
            o_cnt_tx_frames   <= 1'b0;
            o_cnt_tx_overflow <= 1'b0;
        end else begin
            // Clear single-cycle strobe outputs by default
            o_txf_push        <= 1'b0;
            o_cnt_tx_frames   <= 1'b0;
            o_cnt_tx_overflow <= 1'b0;

            // Handle fault clear command
            if (i_clear_fault) begin
                o_tx_fault <= 1'b0;
            end

            // Process accepted decision
            if (i_dec_valid && i_dec_pass) begin
                user_ref_counter <= next_user_ref;

                if (i_txf_full) begin
                    // FIFO full: frame dropped, fault set, overflow counted
                    o_tx_fault        <= 1'b1;
                    o_cnt_tx_overflow <= 1'b1;
                end else begin
                    // Write frame to TX FIFO
                    o_txf_push      <= 1'b1;
                    o_txf_data      <= frame_data;
                    o_txf_keep      <= `T2T_OUCH_TKEEP; // 64'h0000_FFFF_FFFF_FFFF
                    o_txf_last      <= 1'b1;
                    o_cnt_tx_frames <= 1'b1;
                end
            end
        end
    end

endmodule

