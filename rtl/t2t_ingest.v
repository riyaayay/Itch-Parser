// =============================================================================
// File        : rtl/t2t_ingest.v
// Spec Section: 7.1 (t2t_ingest - Stage S1)
// Description : Wide AXI-Stream ingest registering 512-bit Ethernet RX beats
//               into the ING FIFO with overflow and init-busy dropping.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module t2t_ingest #(
    parameter ING_DEPTH = `T2T_ING_DEPTH,
    parameter ING_AW    = `T2T_ING_AW
) (
    input  wire         clk,
    input  wire         rst,

    // Wide CMAC RX AXI-Stream Interface (No backpressure)
    input  wire [511:0] i_tdata,
    input  wire [63:0]  i_tkeep,
    input  wire         i_tvalid,
    input  wire         i_tlast,

    // Control & status
    input  wire         i_init_busy,
    output reg          o_overflow,
    output reg          o_dropped_init,

    // Interface to S2 Framer
    input  wire         i_pop,
    output wire         o_valid,
    output wire [511:0] o_data,
    output wire [63:0]  o_keep,
    output wire         o_last
);

    // Register input beat (Stage 1 register)
    reg [511:0] reg_data;
    reg [63:0]  reg_keep;
    reg         reg_last;
    reg         reg_valid;

    always @(posedge clk) begin
        if (rst) begin
            reg_valid      <= 1'b0;
            reg_data       <= 512'd0;
            reg_keep       <= 64'd0;
            reg_last       <= 1'b0;
            o_overflow     <= 1'b0;
            o_dropped_init <= 1'b0;
        end else begin
            o_overflow     <= 1'b0;
            o_dropped_init <= 1'b0;

            if (i_tvalid) begin
                if (i_init_busy) begin
                    o_dropped_init <= 1'b1;
                end else begin
                    reg_valid <= 1'b1;
                    reg_data  <= i_tdata;
                    reg_keep  <= i_tkeep;
                    reg_last  <= i_tlast;
                end
            end else begin
                reg_valid <= 1'b0;
            end
        end
    end

    // FIFO width: 512 (data) + 64 (keep) + 1 (last) = 577 bits
    wire [576:0] fifo_din = {reg_data, reg_keep, reg_last};
    wire [576:0] fifo_dout;
    wire         fifo_full;
    wire         fifo_empty;
    wire         fifo_push = reg_valid && !fifo_full;

    // Detect overflow when pushing to full FIFO
    always @(posedge clk) begin
        if (!rst && reg_valid && fifo_full) begin
            o_overflow <= 1'b1;
        end
    end

    t2t_sfifo #(
        .WIDTH              (577),
        .DEPTH              (ING_DEPTH),
        .ADDR_W             (ING_AW),
        .ALMOST_FULL_THRESH (ING_DEPTH - 4)
    ) u_ing_fifo (
        .clk     (clk),
        .rst     (rst),
        .i_push  (fifo_push),
        .i_data  (fifo_din),
        .o_full  (fifo_full),
        .o_afull (),
        .i_pop   (i_pop),
        .o_data  (fifo_dout),
        .o_empty (fifo_empty),
        .o_count ()
    );

    assign o_valid = !fifo_empty;
    assign o_data  = fifo_dout[576:65];
    assign o_keep  = fifo_dout[64:1];
    assign o_last  = fifo_dout[0];

endmodule
