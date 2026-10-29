// =============================================================================
// File        : rtl/t2t_symfilter.v
// Spec Section: 5.2 (FA Bus), 5.3 (Depth 2), 8.1, 8.2 (Stage S4)
// Description : Symbol filter matching incoming Add/Add-MPID orders against
//               up to 8 configured active stock symbols. 2-stage pipelined.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module t2t_symfilter (
    input  wire                   clk,
    input  wire                   rst,

    // Interface from S3 Extract (MSG bus)
    input  wire                   i_msg_valid,
    input  wire [319:0]           i_msg,

    // Configuration: Flat array of 8 x 64-bit stock symbols
    input  wire [8*64-1:0]        i_cfg_stock,

    // Interface to FA FIFO / S5 Order Table (FA bus)
    output reg                    o_valid,
    output reg  [324:0]           o_fa,

    // Diagnostic & Performance Counters
    output reg                    o_cnt_hit,
    output reg                    o_cnt_miss
);

    // Slices from MSG bus
    wire [7:0]  msg_type  = i_msg[`T2T_MSG_TYPE_HI  : `T2T_MSG_TYPE_LO];
    wire [63:0] msg_stock = i_msg[`T2T_MSG_STOCK_HI : `T2T_MSG_STOCK_LO];
    wire        is_add    = (msg_type == `T2T_TYPE_A) || (msg_type == `T2T_TYPE_F);

    // -------------------------------------------------------------------------
    // Stage 1: Two 32-bit halves compared in parallel (Spec Section 8.2)
    // -------------------------------------------------------------------------
    reg         stg1_valid;
    reg [319:0] stg1_msg;
    reg         stg1_is_add;
    reg [7:0]   stg1_match_hi;
    reg [7:0]   stg1_match_lo;

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            stg1_valid    <= 1'b0;
            stg1_msg      <= 320'd0;
            stg1_is_add   <= 1'b0;
            stg1_match_hi <= 8'd0;
            stg1_match_lo <= 8'd0;
        end else begin
            stg1_valid  <= i_msg_valid;
            stg1_msg    <= i_msg;
            stg1_is_add <= is_add;

            for (i = 0; i < 8; i = i + 1) begin
                // Spec 8.1: A slot is active when its configured stock is not all zero
                if (i_cfg_stock[64*i +: 64] != 64'd0) begin
                    stg1_match_hi[i] <= (msg_stock[63:32] == i_cfg_stock[64*i + 32 +: 32]);
                    stg1_match_lo[i] <= (msg_stock[31:0]  == i_cfg_stock[64*i      +: 32]);
                end else begin
                    stg1_match_hi[i] <= 1'b0;
                    stg1_match_lo[i] <= 1'b0;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2: Combine matches & lowest-index priority encode (Spec Section 8.2)
    // -------------------------------------------------------------------------
    wire [7:0] slot_match;
    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : gen_match
            assign slot_match[g] = stg1_match_hi[g] & stg1_match_lo[g];
        end
    endgenerate

    // Spec 8.1: If two slots hold the same stock the lowest index wins
    reg [3:0] hit_sym;
    reg       hit_found;
    integer k;
    always @(*) begin
        hit_found = 1'b0;
        hit_sym   = 4'd0;
        for (k = 7; k >= 0; k = k - 1) begin
            if (slot_match[k]) begin
                hit_found = 1'b1;
                hit_sym   = k[3:0];
            end
        end
    end

    // Registered Stage 2 Output (FA bus: {hit[0], sym[3:0], MSG[319:0]})
    always @(posedge clk) begin
        if (rst) begin
            o_valid    <= 1'b0;
            o_fa       <= 325'd0;
            o_cnt_hit  <= 1'b0;
            o_cnt_miss <= 1'b0;
        end else begin
            o_valid    <= 1'b0;
            o_fa       <= 325'd0;
            o_cnt_hit  <= 1'b0;
            o_cnt_miss <= 1'b0;

            if (stg1_valid) begin
                if (stg1_is_add) begin
                    if (hit_found) begin
                        o_valid                               <= 1'b1;
                        o_cnt_hit                             <= 1'b1;
                        o_fa[`T2T_FA_HIT_BIT]                 <= 1'b1;
                        o_fa[`T2T_FA_SYM_HI : `T2T_FA_SYM_LO] <= hit_sym;
                        o_fa[`T2T_FA_MSG_HI : `T2T_FA_MSG_LO] <= stg1_msg;
                    end else begin
                        // Miss: drop and pulse o_cnt_miss
                        o_valid    <= 1'b0;
                        o_cnt_miss <= 1'b1;
                    end
                end else begin
                    // Non-add types (E, C, X, D, U):
                    // Forward with hit=0, sym=0; the table supplies the symbol
                    o_valid                               <= 1'b1;
                    o_fa[`T2T_FA_HIT_BIT]                 <= 1'b0;
                    o_fa[`T2T_FA_SYM_HI : `T2T_FA_SYM_LO] <= 4'd0;
                    o_fa[`T2T_FA_MSG_HI : `T2T_FA_MSG_LO] <= stg1_msg;
                end
            end
        end
    end

endmodule
