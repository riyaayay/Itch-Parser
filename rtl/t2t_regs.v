// =============================================================================
// File        : rtl/t2t_regs.v
// Spec Section: 11.2, 11.3 (AXI-Lite Register File & Shadowed Diagnostics)
// Description : Memory-mapped control and status interface. Implements
//               atomic snapshot shadowing, 64 saturating hardware counters,
//               strict write gating (SLVERR on violation), and live TOB feeds.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"
`include "t2t_symbols.vh"

module t2t_regs #(
    parameter N_SYMBOLS  = `T2T_N_SYMBOLS,
    parameter BOOK_N     = `T2T_BOOK_N,
    parameter TABLE_AW   = `T2T_TABLE_AW,
    parameter TABLE_WAYS = `T2T_TABLE_WAYS
) (
    input  wire                               clk,
    input  wire                               rst,

    // AXI-Lite Slave Interface (Section 11.2)
    input  wire [11:0]                        s_axi_ctrl_awaddr,
    input  wire                               s_axi_ctrl_awvalid,
    output reg                                s_axi_ctrl_awready,
    input  wire [31:0]                        s_axi_ctrl_wdata,
    input  wire [3:0]                         s_axi_ctrl_wstrb,
    input  wire                               s_axi_ctrl_wvalid,
    output reg                                s_axi_ctrl_wready,
    output reg  [1:0]                         s_axi_ctrl_bresp,
    output reg                                s_axi_ctrl_bvalid,
    input  wire                               s_axi_ctrl_bready,

    input  wire [11:0]                        s_axi_ctrl_araddr,
    input  wire                               s_axi_ctrl_arvalid,
    output reg                                s_axi_ctrl_arready,
    output reg  [31:0]                        s_axi_ctrl_rdata,
    output reg  [1:0]                         s_axi_ctrl_rresp,
    output reg                                s_axi_ctrl_rvalid,
    input  wire                               s_axi_ctrl_rready,

    // Live status inputs
    input  wire                               i_session_invalid,
    input  wire                               i_init_busy,
    input  wire                               i_tx_fault,

    // Live Best Bid / Ask for Symbol 0 (addresses 0x010, 0x018)
    input  wire [31:0]                        i_live_best_bid0,
    input  wire [31:0]                        i_live_best_ask0,

    // Live Book state from S6 Book (8 symbols * 224 bits)
    input  wire [N_SYMBOLS*`T2T_TOB_SYM_W-1:0] i_bk_tob_flat,

    // Live Risk state from S8 Risk
    input  wire [N_SYMBOLS*32-1:0]            i_risk_pos_flat,
    input  wire [31:0]                        i_risk_gross,
    input  wire [31:0]                        i_risk_win_id,
    input  wire [15:0]                        i_risk_win_cnt,

    // Performance & Diagnostic Counter pulses (64 counters)
    input  wire [63:0]                        i_cnt_pulses,

    // Control plane outputs
    output reg                                o_session_reset,
    output reg                                o_kill_switch,
    output reg                                o_clear_counters,
    output reg                                o_global_enable,
    output reg                                o_clear_fault,

    // Configuration buses distributed to pipeline
    output wire [N_SYMBOLS*64-1:0]            o_cfg_stock,
    output wire [N_SYMBOLS*`T2T_TCFG_SYM_W-1:0] o_tcfg,
    output wire [N_SYMBOLS*`T2T_RCFG_SYM_W-1:0] o_rcfg,
    output reg  [31:0]                        o_max_gross,
    output reg  [15:0]                        o_max_orders,
    output reg  [4:0]                         o_win_shift
);

    localparam RESP_OKAY   = 2'b00;
    localparam RESP_SLVERR = 2'b10;

    // -------------------------------------------------------------------------
    // Per-Symbol Configuration Storage (Section 11.2)
    // -------------------------------------------------------------------------
    reg [63:0] reg_stock        [0:N_SYMBOLS-1];
    reg        reg_en           [0:N_SYMBOLS-1];
    reg        reg_cfg_valid    [0:N_SYMBOLS-1];
    reg [3:0]  reg_rule_mask    [0:N_SYMBOLS-1];
    reg [2:0]  reg_imb_shift    [0:N_SYMBOLS-1];
    reg [31:0] reg_buy_limit    [0:N_SYMBOLS-1];
    reg [31:0] reg_sell_limit   [0:N_SYMBOLS-1];
    reg [31:0] reg_max_spread   [0:N_SYMBOLS-1];
    reg [15:0] reg_order_qty    [0:N_SYMBOLS-1];
    reg [15:0] reg_max_qty      [0:N_SYMBOLS-1];
    reg [47:0] reg_max_notional [0:N_SYMBOLS-1];
    reg [31:0] reg_collar_abs   [0:N_SYMBOLS-1];
    reg [31:0] reg_ref_px       [0:N_SYMBOLS-1];
    reg [31:0] reg_max_pos      [0:N_SYMBOLS-1];

    // Assign packed configuration buses
    genvar gi;
    generate
        for (gi = 0; gi < N_SYMBOLS; gi = gi + 1) begin : gen_cfg_pack
            assign o_cfg_stock[gi*64 +: 64] = reg_stock[gi];

            assign o_tcfg[gi*`T2T_TCFG_SYM_W +: `T2T_TCFG_SYM_W] = {
                reg_order_qty[gi],
                reg_max_spread[gi],
                reg_sell_limit[gi],
                reg_buy_limit[gi],
                reg_imb_shift[gi],
                reg_rule_mask[gi],
                reg_en[gi]
            };

            assign o_rcfg[gi*`T2T_RCFG_SYM_W +: `T2T_RCFG_SYM_W] = {
                reg_max_pos[gi],
                reg_ref_px[gi],
                reg_collar_abs[gi],
                reg_max_notional[gi],
                reg_max_qty[gi],
                reg_cfg_valid[gi]
            };
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 64 Hardware Counters (Saturating at 0xFFFFFFFF, Section 11.3)
    // -------------------------------------------------------------------------
    reg [31:0] live_counters [0:63];
    integer ci;
    always @(posedge clk) begin
        if (rst || o_clear_counters) begin
            for (ci = 0; ci < 64; ci = ci + 1) begin
                live_counters[ci] <= 32'd0;
            end
        end else begin
            for (ci = 0; ci < 64; ci = ci + 1) begin
                if (i_cnt_pulses[ci] && (live_counters[ci] != 32'hFFFF_FFFF)) begin
                    live_counters[ci] <= live_counters[ci] + 32'd1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Shadow Snapshot Storage (Section 11.2)
    // Coherent freeze latched all at once by CTRL.snapshot
    // -------------------------------------------------------------------------
    reg [31:0] shadow_counters [0:63];
    reg [31:0] shadow_book_bid_px  [0:N_SYMBOLS-1];
    reg [31:0] shadow_book_bid_qty [0:N_SYMBOLS-1];
    reg [31:0] shadow_book_ask_px  [0:N_SYMBOLS-1];
    reg [31:0] shadow_book_ask_qty [0:N_SYMBOLS-1];
    reg [31:0] shadow_book_flags   [0:N_SYMBOLS-1];
    reg [19:0] shadow_book_bid_hid [0:N_SYMBOLS-1];
    reg [19:0] shadow_book_ask_hid [0:N_SYMBOLS-1];
    reg [31:0] shadow_book_seq     [0:N_SYMBOLS-1];

    reg [31:0] shadow_risk_pos     [0:N_SYMBOLS-1];
    reg [31:0] shadow_risk_gross;

    integer si;
    always @(posedge clk) begin
        if (rst) begin
            for (si = 0; si < 64; si = si + 1) shadow_counters[si] <= 32'd0;
            for (si = 0; si < N_SYMBOLS; si = si + 1) begin
                shadow_book_bid_px[si]  <= 32'd0;
                shadow_book_bid_qty[si] <= 32'd0;
                shadow_book_ask_px[si]  <= 32'd0;
                shadow_book_ask_qty[si] <= 32'd0;
                shadow_book_flags[si]   <= 32'd0;
                shadow_book_bid_hid[si] <= 20'd0;
                shadow_book_ask_hid[si] <= 20'd0;
                shadow_book_seq[si]     <= 32'd0;
                shadow_risk_pos[si]     <= 32'd0;
            end
            shadow_risk_gross <= 32'd0;
        end else if (s_axi_ctrl_awvalid && s_axi_ctrl_wvalid && s_axi_ctrl_awready &&
                     (s_axi_ctrl_awaddr == 12'h004) && s_axi_ctrl_wdata[4]) begin
            // CTRL.snapshot pulse: freeze all coherent S registers
            for (si = 0; si < 64; si = si + 1) begin
                shadow_counters[si] <= live_counters[si];
            end
            for (si = 0; si < N_SYMBOLS; si = si + 1) begin
                shadow_book_bid_px[si]  <= i_bk_tob_flat[si*`T2T_TOB_SYM_W + `T2T_TOB_BID_PX_LO +: 32];
                shadow_book_bid_qty[si] <= i_bk_tob_flat[si*`T2T_TOB_SYM_W + `T2T_TOB_BID_QTY_LO +: 32];
                shadow_book_ask_px[si]  <= i_bk_tob_flat[si*`T2T_TOB_SYM_W + `T2T_TOB_ASK_PX_LO +: 32];
                shadow_book_ask_qty[si] <= i_bk_tob_flat[si*`T2T_TOB_SYM_W + `T2T_TOB_ASK_QTY_LO +: 32];
                shadow_book_flags[si]   <= {16'd0, i_bk_tob_flat[si*`T2T_TOB_SYM_W + `T2T_TOB_FLAGS_LO +: 16]};
                shadow_book_bid_hid[si] <= i_bk_tob_flat[si*`T2T_TOB_SYM_W + `T2T_TOB_BID_HID_LO +: 20];
                shadow_book_ask_hid[si] <= i_bk_tob_flat[si*`T2T_TOB_SYM_W + `T2T_TOB_ASK_HID_LO +: 20];
                shadow_book_seq[si]     <= i_bk_tob_flat[si*`T2T_TOB_SYM_W + `T2T_TOB_SEQ_LO +: 32];
                shadow_risk_pos[si]     <= i_risk_pos_flat[si*32 +: 32];
            end
            shadow_risk_gross <= i_risk_gross;
        end
    end

    // -------------------------------------------------------------------------
    // AXI-Lite Write Transaction Handling (Section 11.2)
    // -------------------------------------------------------------------------
    wire write_fire = s_axi_ctrl_awvalid && s_axi_ctrl_wvalid && s_axi_ctrl_awready;

    // Address decode for write validation
    wire [11:0] waddr = s_axi_ctrl_awaddr;
    wire [31:0] wdata = s_axi_ctrl_wdata;

    reg write_valid_target;
    reg write_slverr;

    // Helper functions for symbol decode
    wire is_sym_block = (waddr >= 12'h400) && (waddr < 12'h400 + N_SYMBOLS * 12'h40);
    wire [11:0] wsym_diff = waddr - 12'h400;
    wire [2:0]  wsym_idx  = wsym_diff[8:6];
    wire [5:0]  wsym_off  = wsym_diff[5:0];

    always @(*) begin
        write_valid_target = 1'b0;
        write_slverr        = 1'b0;

        if (waddr == 12'h004) begin
            // CTRL register: writable
            write_valid_target = 1'b1;
        end else if (is_sym_block) begin
            case (wsym_off)
                6'h00, 6'h04: begin
                    // Stock symbols: reject with SLVERR if global_enable == 1
                    if (o_global_enable) begin
                        write_slverr = 1'b1;
                    end else begin
                        write_valid_target = 1'b1;
                    end
                end
                6'h08: begin // sym_ctrl: [10:8] imb, [7:4] mask, bit1 valid, bit0 en
                    if ((wdata[3:2] != 2'b00) || (wdata[31:11] != 21'd0)) begin
                        write_slverr = 1'b1;
                    end else begin
                        write_valid_target = 1'b1;
                    end
                end
                6'h0C, 6'h10, 6'h14, 6'h20, 6'h28, 6'h2C, 6'h30: begin
                    // 32-bit fields: buy_limit, sell_limit, max_spread, max_notional_lo, collar, ref_px, max_pos
                    write_valid_target = 1'b1;
                end
                6'h18: begin // order_qty: 16-bit
                    if (wdata[31:16] != 16'd0) write_slverr = 1'b1;
                    else write_valid_target = 1'b1;
                end
                6'h1C: begin // max_qty: 16-bit
                    if (wdata[31:16] != 16'd0) write_slverr = 1'b1;
                    else write_valid_target = 1'b1;
                end
                6'h24: begin // max_notional_hi: 16-bit
                    if (wdata[31:16] != 16'd0) write_slverr = 1'b1;
                    else write_valid_target = 1'b1;
                end
                default: begin
                    // Unmapped or read-only (like pos at +0x34)
                    write_slverr = 1'b1;
                end
            endcase
        end else if (waddr == 12'h800) begin
            write_valid_target = 1'b1; // max_gross
        end else if (waddr == 12'h808) begin
            if (wdata[31:16] != 16'd0) write_slverr = 1'b1;
            else write_valid_target = 1'b1;
        end else if (waddr == 12'h80C) begin
            if (wdata[31:5] != 27'd0) write_slverr = 1'b1;
            else write_valid_target = 1'b1;
        end else begin
            // RO registers (0x000, 0x008, 0x00C, 0x010, 0x018, counters, book, etc.) or unmapped
            write_slverr = 1'b1;
        end
    end

    integer rst_i;
    always @(posedge clk) begin
        if (rst) begin
            s_axi_ctrl_awready <= 1'b1;
            s_axi_ctrl_wready  <= 1'b1;
            s_axi_ctrl_bvalid  <= 1'b0;
            s_axi_ctrl_bresp   <= RESP_OKAY;

            // Control outputs reset
            o_session_reset    <= 1'b0;
            o_kill_switch      <= 1'b1; // Resets to 1 (fail-closed, Section 11.2)
            o_clear_counters   <= 1'b0;
            o_global_enable    <= 1'b0;
            o_clear_fault      <= 1'b0;

            // Global risk limits
            o_max_gross        <= 32'd0;
            o_max_orders       <= 16'd0;
            o_win_shift        <= 5'd0;

            // Per-symbol default tickers from rtl/t2t_symbols.vh
            reg_stock[0] <= `T2T_SYM_SLOT0;
            reg_stock[1] <= `T2T_SYM_SLOT1;
            reg_stock[2] <= `T2T_SYM_SLOT2;
            reg_stock[3] <= `T2T_SYM_SLOT3;
            reg_stock[4] <= `T2T_SYM_SLOT4;
            reg_stock[5] <= `T2T_SYM_SLOT5;
            reg_stock[6] <= `T2T_SYM_SLOT6;
            reg_stock[7] <= `T2T_SYM_SLOT7;

            for (rst_i = 0; rst_i < N_SYMBOLS; rst_i = rst_i + 1) begin
                reg_en[rst_i]           <= 1'b0;
                reg_cfg_valid[rst_i]    <= 1'b0;
                reg_rule_mask[rst_i]    <= 4'd0;
                reg_imb_shift[rst_i]    <= 3'd0;
                reg_buy_limit[rst_i]    <= 32'd0;
                reg_sell_limit[rst_i]   <= 32'd0;
                reg_max_spread[rst_i]   <= 32'd0;
                reg_order_qty[rst_i]    <= 16'd0;
                reg_max_qty[rst_i]      <= 16'd0;
                reg_max_notional[rst_i] <= 48'd0;
                reg_collar_abs[rst_i]   <= 32'd0;
                reg_ref_px[rst_i]       <= 32'd0;
                reg_max_pos[rst_i]      <= 32'd0;
            end
        end else begin
            // Self-clearing strobe pulses
            o_session_reset  <= 1'b0;
            o_clear_counters <= 1'b0;
            o_clear_fault    <= 1'b0;

            if (s_axi_ctrl_bvalid && s_axi_ctrl_bready) begin
                s_axi_ctrl_bvalid  <= 1'b0;
                s_axi_ctrl_awready <= 1'b1;
                s_axi_ctrl_wready  <= 1'b1;
            end

            if (write_fire) begin
                s_axi_ctrl_awready <= 1'b0;
                s_axi_ctrl_wready  <= 1'b0;
                s_axi_ctrl_bvalid  <= 1'b1;

                if (write_slverr) begin
                    s_axi_ctrl_bresp <= RESP_SLVERR;
                end else begin
                    s_axi_ctrl_bresp <= RESP_OKAY;

                    if (waddr == 12'h004) begin
                        if (wdata[0]) o_session_reset  <= 1'b1;
                        o_kill_switch                  <= wdata[1];
                        if (wdata[2]) o_clear_counters <= 1'b1;
                        o_global_enable                <= wdata[3];
                        if (wdata[5]) o_clear_fault    <= 1'b1;
                    end else if (is_sym_block) begin
                        case (wsym_off)
                            6'h00: reg_stock[wsym_idx][63:32] <= wdata;
                            6'h04: reg_stock[wsym_idx][31:0]  <= wdata;
                            6'h08: begin
                                reg_en[wsym_idx]        <= wdata[0];
                                reg_cfg_valid[wsym_idx] <= wdata[1];
                                reg_rule_mask[wsym_idx] <= wdata[7:4];
                                reg_imb_shift[wsym_idx] <= wdata[10:8];
                            end
                            6'h0C: reg_buy_limit[wsym_idx]     <= wdata;
                            6'h10: reg_sell_limit[wsym_idx]    <= wdata;
                            6'h14: reg_max_spread[wsym_idx]    <= wdata;
                            6'h18: reg_order_qty[wsym_idx]     <= wdata[15:0];
                            6'h1C: reg_max_qty[wsym_idx]       <= wdata[15:0];
                            6'h20: reg_max_notional[wsym_idx][31:0]  <= wdata;
                            6'h24: reg_max_notional[wsym_idx][47:32] <= wdata[15:0];
                            6'h28: reg_collar_abs[wsym_idx]    <= wdata;
                            6'h2C: reg_ref_px[wsym_idx]        <= wdata;
                            6'h30: reg_max_pos[wsym_idx]       <= wdata;
                            default: ;
                        endcase
                    end else if (waddr == 12'h800) begin
                        o_max_gross <= wdata;
                    end else if (waddr == 12'h808) begin
                        o_max_orders <= wdata[15:0];
                    end else if (waddr == 12'h80C) begin
                        o_win_shift <= wdata[4:0];
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // AXI-Lite Read Transaction Handling (Section 11.2)
    // -------------------------------------------------------------------------
    wire read_fire = s_axi_ctrl_arvalid && s_axi_ctrl_arready;
    wire [11:0] raddr = s_axi_ctrl_araddr;

    wire is_rd_cnt = (raddr >= 12'h100) && (raddr < 12'h200);
    wire [11:0] rcnt_diff   = raddr - 12'h100;
    wire [5:0]  rd_cnt_idx  = rcnt_diff[7:2];

    wire is_rd_book = (raddr >= 12'h200) && (raddr < 12'h200 + N_SYMBOLS * 12'h20);
    wire [11:0] rbook_diff  = raddr - 12'h200;
    wire [2:0]  rd_book_sym = rbook_diff[7:5];
    wire [4:0]  rd_book_off = rbook_diff[4:0];

    wire is_rd_sym = (raddr >= 12'h400) && (raddr < 12'h400 + N_SYMBOLS * 12'h40);
    wire [11:0] rsym_diff   = raddr - 12'h400;
    wire [2:0]  rd_sym_idx  = rsym_diff[8:6];
    wire [5:0]  rd_sym_off  = rsym_diff[5:0];

    reg [31:0] rdata_comb;

    always @(*) begin
        rdata_comb = 32'hDEAD_BEEF; // Upstream-compatible unmapped value

        if (raddr == 12'h000) begin
            rdata_comb = `T2T_REG_ID_VAL; // 0x74320001
        end else if (raddr == 12'h004) begin
            rdata_comb = {26'd0, 1'b0, 1'b0, o_global_enable, 1'b0, o_kill_switch, 1'b0};
        end else if (raddr == 12'h008) begin
            rdata_comb = {28'd0, o_kill_switch, i_tx_fault, i_init_busy, i_session_invalid};
        end else if (raddr == 12'h00C) begin
            rdata_comb = {12'd0, TABLE_WAYS[3:0], TABLE_AW[7:0], BOOK_N[3:0], (N_SYMBOLS[3:0] - 4'd1)};
        end else if (raddr == 12'h010) begin
            rdata_comb = i_live_best_bid0;
        end else if (raddr == 12'h018) begin
            rdata_comb = i_live_best_ask0;
        end else if (is_rd_cnt) begin
            rdata_comb = shadow_counters[rd_cnt_idx];
        end else if (is_rd_book) begin
            case (rd_book_off)
                5'h00: rdata_comb = shadow_book_bid_px[rd_book_sym];
                5'h04: rdata_comb = shadow_book_bid_qty[rd_book_sym];
                5'h08: rdata_comb = shadow_book_ask_px[rd_book_sym];
                5'h0C: rdata_comb = shadow_book_ask_qty[rd_book_sym];
                5'h10: rdata_comb = shadow_book_flags[rd_book_sym];
                5'h14: rdata_comb = {12'd0, shadow_book_bid_hid[rd_book_sym]};
                5'h18: rdata_comb = {12'd0, shadow_book_ask_hid[rd_book_sym]};
                5'h1C: rdata_comb = shadow_book_seq[rd_book_sym];
                default: rdata_comb = 32'hDEAD_BEEF;
            endcase
        end else if (is_rd_sym) begin
            case (rd_sym_off)
                6'h00: rdata_comb = reg_stock[rd_sym_idx][63:32];
                6'h04: rdata_comb = reg_stock[rd_sym_idx][31:0];
                6'h08: rdata_comb = {21'd0, reg_imb_shift[rd_sym_idx], reg_rule_mask[rd_sym_idx], 2'b00, reg_cfg_valid[rd_sym_idx], reg_en[rd_sym_idx]};
                6'h0C: rdata_comb = reg_buy_limit[rd_sym_idx];
                6'h10: rdata_comb = reg_sell_limit[rd_sym_idx];
                6'h14: rdata_comb = reg_max_spread[rd_sym_idx];
                6'h18: rdata_comb = {16'd0, reg_order_qty[rd_sym_idx]};
                6'h1C: rdata_comb = {16'd0, reg_max_qty[rd_sym_idx]};
                6'h20: rdata_comb = reg_max_notional[rd_sym_idx][31:0];
                6'h24: rdata_comb = {16'd0, reg_max_notional[rd_sym_idx][47:32]};
                6'h28: rdata_comb = reg_collar_abs[rd_sym_idx];
                6'h2C: rdata_comb = reg_ref_px[rd_sym_idx];
                6'h30: rdata_comb = reg_max_pos[rd_sym_idx];
                6'h34: rdata_comb = shadow_risk_pos[rd_sym_idx];
                default: rdata_comb = 32'hDEAD_BEEF;
            endcase
        end else if (raddr == 12'h800) begin
            rdata_comb = o_max_gross;
        end else if (raddr == 12'h804) begin
            rdata_comb = shadow_risk_gross;
        end else if (raddr == 12'h808) begin
            rdata_comb = {16'd0, o_max_orders};
        end else if (raddr == 12'h80C) begin
            rdata_comb = {27'd0, o_win_shift};
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            s_axi_ctrl_arready <= 1'b1;
            s_axi_ctrl_rvalid  <= 1'b0;
            s_axi_ctrl_rresp   <= RESP_OKAY;
            s_axi_ctrl_rdata   <= 32'd0;
        end else begin
            if (s_axi_ctrl_rvalid && s_axi_ctrl_rready) begin
                s_axi_ctrl_rvalid  <= 1'b0;
                s_axi_ctrl_arready <= 1'b1;
            end

            if (read_fire) begin
                s_axi_ctrl_arready <= 1'b0;
                s_axi_ctrl_rvalid  <= 1'b1;
                s_axi_ctrl_rresp   <= RESP_OKAY;
                s_axi_ctrl_rdata   <= rdata_comb;
            end
        end
    end

endmodule
