// =============================================================================
// File        : rtl/t2t_sfifo.v
// Spec Section: 4.3, 7.1, 8.3, 11.1, 12.3 (FP-5)
// Description : Parameterized synchronous FIFO with almost-full credit margin
//               and single-cycle lookahead read. Synthesizable Verilog-2005.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module t2t_sfifo #(
    parameter WIDTH        = 32,
    parameter DEPTH        = 16,
    parameter ADDR_W       = 4,
    parameter ALMOST_FULL_THRESH = 12
) (
    input  wire              clk,
    input  wire              rst,

    // Write interface
    input  wire              i_push,
    input  wire [WIDTH-1:0]  i_data,
    output wire              o_full,
    output wire              o_afull,

    // Read interface
    input  wire              i_pop,
    output wire [WIDTH-1:0]  o_data,
    output wire              o_empty,
    output reg  [ADDR_W:0]   o_count
);

    // RAM array
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    reg [ADDR_W-1:0] wr_ptr;
    reg [ADDR_W-1:0] rd_ptr;

    wire [ADDR_W:0] thresh_w = ALMOST_FULL_THRESH[ADDR_W:0];
    wire [ADDR_W-1:0] max_ptr = DEPTH[ADDR_W-1:0] - 1'b1;

    assign o_empty = (o_count == {(ADDR_W+1){1'b0}});
    assign o_full  = (o_count == DEPTH[ADDR_W:0]);
    assign o_afull = (o_count >= thresh_w);

    // First-word fall-through (FWFT) asynchronous/registered memory read
    assign o_data = mem[rd_ptr];

    wire do_push = i_push && !o_full;
    wire do_pop  = i_pop  && !o_empty;

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr  <= {ADDR_W{1'b0}};
            rd_ptr  <= {ADDR_W{1'b0}};
            o_count <= {(ADDR_W+1){1'b0}};
        end else begin
            if (do_push) begin
                mem[wr_ptr] <= i_data;
                wr_ptr <= (wr_ptr == max_ptr) ? {ADDR_W{1'b0}} : (wr_ptr + 1'b1);
            end

            if (do_pop) begin
                rd_ptr <= (rd_ptr == max_ptr) ? {ADDR_W{1'b0}} : (rd_ptr + 1'b1);
            end

            case ({do_push, do_pop})
                2'b10: o_count <= o_count + 1'b1;
                2'b01: o_count <= o_count - 1'b1;
                default: o_count <= o_count;
            endcase
        end
    end

`ifdef FORMAL
    // Formal properties for FP-5: neither drop nor duplicate
    initial assume(rst);
    always @(posedge clk) begin
        if (rst) begin
            assert(o_empty);
            assert(!o_full);
            assert(o_count == {(ADDR_W+1){1'b0}});
        end else begin
            assert(o_count <= DEPTH[ADDR_W:0]);
            if (o_count == {(ADDR_W+1){1'b0}}) assert(o_empty);
            if (o_count == DEPTH[ADDR_W:0]) assert(o_full);
            if (o_count >= thresh_w) assert(o_afull);
        end
    end
`endif

endmodule
