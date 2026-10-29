// =============================================================================
// File        : rtl/t2t_kernel.v
// Spec Section: 11.4 (Vitis / XRT Shell Compatibility Kernel Wrapper)
// Description : Drop-in replacement wrapper for upstream hft_trading_kernel.
//               Converts active-low shell reset to synchronous active-high rst,
//               ties rx_axis_tready = 1 (A2), and wraps t2t_top.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module t2t_kernel #(
    parameter N_SYMBOLS  = `T2T_N_SYMBOLS,
    parameter BOOK_N     = `T2T_BOOK_N,
    parameter TABLE_AW   = `T2T_TABLE_AW,
    parameter TABLE_WAYS = `T2T_TABLE_WAYS
) (
    // Kernel clock & active-low reset
    input  wire         ap_clk,
    input  wire         ap_rst_n,

    // Inbound AXI-Stream RX (from CMAC RX – 512-bit bus)
    input  wire [511:0] rx_axis_tdata,
    input  wire [63:0]  rx_axis_tkeep,
    input  wire         rx_axis_tvalid,
    output wire         rx_axis_tready,
    input  wire         rx_axis_tlast,

    // Outbound AXI-Stream TX (to CMAC TX)
    output wire [511:0] tx_axis_tdata,
    output wire [63:0]  tx_axis_tkeep,
    output wire         tx_axis_tvalid,
    input  wire         tx_axis_tready,
    output wire         tx_axis_tlast,

    // AXI-Lite Control Interface
    input  wire [11:0]  s_axi_ctrl_awaddr,
    input  wire         s_axi_ctrl_awvalid,
    output wire         s_axi_ctrl_awready,
    input  wire [31:0]  s_axi_ctrl_wdata,
    input  wire [3:0]   s_axi_ctrl_wstrb,
    input  wire         s_axi_ctrl_wvalid,
    output wire         s_axi_ctrl_wready,
    output wire [1:0]   s_axi_ctrl_bresp,
    output wire         s_axi_ctrl_bvalid,
    input  wire         s_axi_ctrl_bready,

    input  wire [11:0]  s_axi_ctrl_araddr,
    input  wire         s_axi_ctrl_arvalid,
    output wire         s_axi_ctrl_arready,
    output wire [31:0]  s_axi_ctrl_rdata,
    output wire [1:0]   s_axi_ctrl_rresp,
    output wire         s_axi_ctrl_rvalid,
    input  wire         s_axi_ctrl_rready
);

    // Assumption A2: CMAC RX stream cannot be backpressured
    assign rx_axis_tready = 1'b1;

    // Reset synchronization: 2-flop active-high synchronizer (Section 4.3 Rule 1)
    reg rst_sync_0;
    reg rst_sync_1;
    always @(posedge ap_clk or negedge ap_rst_n) begin
        if (!ap_rst_n) begin
            rst_sync_0 <= 1'b1;
            rst_sync_1 <= 1'b1;
        end else begin
            rst_sync_0 <= 1'b0;
            rst_sync_1 <= rst_sync_0;
        end
    end
    wire rst = rst_sync_1;

    // Instantiation of normative top-level trading core
    t2t_top #(
        .N_SYMBOLS  (N_SYMBOLS),
        .BOOK_N     (BOOK_N),
        .TABLE_AW   (TABLE_AW),
        .TABLE_WAYS (TABLE_WAYS)
    ) u_t2t_top (
        .clk               (ap_clk),
        .rst               (rst),
        .rx_axis_tdata     (rx_axis_tdata),
        .rx_axis_tkeep     (rx_axis_tkeep),
        .rx_axis_tvalid    (rx_axis_tvalid),
        .rx_axis_tlast     (rx_axis_tlast),
        .tx_axis_tdata     (tx_axis_tdata),
        .tx_axis_tkeep     (tx_axis_tkeep),
        .tx_axis_tvalid    (tx_axis_tvalid),
        .tx_axis_tready    (tx_axis_tready),
        .tx_axis_tlast     (tx_axis_tlast),
        .s_axi_ctrl_awaddr (s_axi_ctrl_awaddr),
        .s_axi_ctrl_awvalid(s_axi_ctrl_awvalid),
        .s_axi_ctrl_awready(s_axi_ctrl_awready),
        .s_axi_ctrl_wdata  (s_axi_ctrl_wdata),
        .s_axi_ctrl_wstrb  (s_axi_ctrl_wstrb),
        .s_axi_ctrl_wvalid (s_axi_ctrl_wvalid),
        .s_axi_ctrl_wready (s_axi_ctrl_wready),
        .s_axi_ctrl_bresp  (s_axi_ctrl_bresp),
        .s_axi_ctrl_bvalid (s_axi_ctrl_bvalid),
        .s_axi_ctrl_bready (s_axi_ctrl_bready),
        .s_axi_ctrl_araddr (s_axi_ctrl_araddr),
        .s_axi_ctrl_arvalid(s_axi_ctrl_arvalid),
        .s_axi_ctrl_arready(s_axi_ctrl_arready),
        .s_axi_ctrl_rdata  (s_axi_ctrl_rdata),
        .s_axi_ctrl_rresp  (s_axi_ctrl_rresp),
        .s_axi_ctrl_rvalid (s_axi_ctrl_rvalid),
        .s_axi_ctrl_rready (s_axi_ctrl_rready)
    );

endmodule

