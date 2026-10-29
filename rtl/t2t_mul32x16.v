// =============================================================================
// File        : rtl/t2t_mul32x16.v
// Spec Section: 10.2 (Pre-Trade Risk Engine: LUT Multiplier)
// Description : Two-stage pipelined 32-bit x 16-bit unsigned multiplier
//               synthesized purely to LUTs (DSP blocks disabled).
// Latency     : 2 clock cycles.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps

(* use_dsp = "no" *)
module t2t_mul32x16 (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] i_a,      // Execution price (32 bits)
    input  wire [15:0] i_b,      // Order quantity (16 bits)
    output reg  [47:0] o_prod    // Unsigned Notional value (48 bits)
);

    // -------------------------------------------------------------------------
    // Stage 1: Partial products calculation (split into 8-bit slices)
    // -------------------------------------------------------------------------
    wire [7:0] b_lo = i_b[7:0];
    wire [7:0] b_hi = i_b[15:8];

    (* use_dsp = "no" *) reg [39:0] stg1_pp_lo;
    (* use_dsp = "no" *) reg [39:0] stg1_pp_hi;

    always @(posedge clk) begin
        if (rst) begin
            stg1_pp_lo <= 40'd0;
            stg1_pp_hi <= 40'd0;
        end else begin
            stg1_pp_lo <= i_a * b_lo;
            stg1_pp_hi <= i_a * b_hi;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2: Sum partial products to produce 48-bit result
    // -------------------------------------------------------------------------
    (* use_dsp = "no" *) wire [47:0] sum_prod = {8'd0, stg1_pp_lo} + ({stg1_pp_hi, 8'd0});

    always @(posedge clk) begin
        if (rst) begin
            o_prod <= 48'd0;
        end else begin
            o_prod <= sum_prod;
        end
    end

endmodule

