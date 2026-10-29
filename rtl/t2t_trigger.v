// =============================================================================
// File        : rtl/t2t_trigger.v
// Spec Section: 5.2, 5.3, 10.1 (Edge-Triggered Trading Rules)
// Description : Pipeline Stage S7: Edge-triggered quantitative trading rules
//               evaluating Top-of-Book updates with spread gating, 4 rule engines,
//               lowest-rule-id priority arbitration, and edge re-arming.
// Latency     : Depth 2 cycles.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module t2t_trigger #(
    parameter N_SYMBOLS = `T2T_N_SYMBOLS
) (
    input  wire                               clk,
    input  wire                               rst,

    // Global session control & enables
    input  wire                               i_global_enable,
    input  wire                               i_session_invalid,

    // Per-symbol trigger configuration (8 * 120 = 960 bits)
    input  wire [N_SYMBOLS*`T2T_TCFG_SYM_W-1:0] i_tcfg,

    // Input UPD interface from S6 Book
    input  wire                               i_upd_valid,
    input  wire [3:0]                         i_upd_sym,
    input  wire [31:0]                        i_upd_idx,
    input  wire                               i_upd_last,
    input  wire [31:0]                        i_upd_bid_px,
    input  wire [31:0]                        i_upd_bid_qty,
    input  wire [31:0]                        i_upd_ask_px,
    input  wire [31:0]                        i_upd_ask_qty,
    input  wire [3:0]                         i_upd_bid_lv,
    input  wire [3:0]                         i_upd_ask_lv,
    input  wire                               i_upd_bid_stale,
    input  wire                               i_upd_ask_stale,
    input  wire                               i_upd_corrupt,
    input  wire [31:0]                        i_upd_seq,

    // Output CAND interface to S8 Risk (Depth 2)
    output reg                                o_cand_valid,
    output reg  [3:0]                         o_cand_sym,
    output reg                                o_cand_side,
    output reg  [31:0]                        o_cand_price,
    output reg  [15:0]                        o_cand_qty,
    output reg  [1:0]                         o_cand_rule,
    output reg  [31:0]                        o_cand_idx,

    // Performance / Diagnostic Counter pulse
    output reg                                o_cnt_cand
);

    // -------------------------------------------------------------------------
    // Configuration Extraction for current symbol
    // -------------------------------------------------------------------------
    wire [2:0] sym_idx = i_upd_sym[2:0];
    reg [`T2T_TCFG_SYM_W-1:0] cfg;
    integer c;
    always @(*) begin
        cfg = i_tcfg[`T2T_TCFG_SYM_W-1:0];
        for (c = 0; c < N_SYMBOLS; c = c + 1) begin
            if (sym_idx == c[2:0]) begin
                cfg = i_tcfg[c*`T2T_TCFG_SYM_W +: `T2T_TCFG_SYM_W];
            end
        end
    end

    wire        cfg_en         = cfg[`T2T_TCFG_EN_BIT];
    wire [3:0]  cfg_rule_mask  = cfg[`T2T_TCFG_MASK_HI : `T2T_TCFG_MASK_LO];
    wire [2:0]  cfg_imb_shift  = cfg[`T2T_TCFG_IMB_HI : `T2T_TCFG_IMB_LO];
    wire [31:0] cfg_buy_limit  = cfg[`T2T_TCFG_BUYLIM_HI : `T2T_TCFG_BUYLIM_LO];
    wire [31:0] cfg_sell_limit = cfg[`T2T_TCFG_SELLLIM_HI : `T2T_TCFG_SELLLIM_LO];
    wire [31:0] cfg_max_spread = cfg[`T2T_TCFG_MAXSPR_HI : `T2T_TCFG_MAXSPR_LO];
    wire [15:0] cfg_qty        = cfg[`T2T_TCFG_QTY_HI : `T2T_TCFG_QTY_LO];

    // -------------------------------------------------------------------------
    // Precondition P Evaluation (Section 10.1 & 9.1)
    // P = global_enable && en && tradable(sym) && (ask_px - bid_px <= max_spread)
    // tradable(sym) = both sides ok, not crossed, not corrupt, not session_invalid
    // -------------------------------------------------------------------------
    wire sym_valid_range     = (i_upd_sym < 4'd8);
    wire sides_ok            = (i_upd_bid_lv != 4'd0) && (i_upd_ask_lv != 4'd0);
    wire not_stale           = (!i_upd_bid_stale) && (!i_upd_ask_stale);
    wire not_corrupt         = (!i_upd_corrupt);
    wire not_session_invalid = (!i_session_invalid);
    // Crossed: both sides ok and bid_px >= ask_px
    wire not_crossed         = (i_upd_bid_px < i_upd_ask_px);

    wire tradable = sym_valid_range && sides_ok && not_stale && not_corrupt &&
                    not_session_invalid && not_crossed;

    wire [31:0] spread = not_crossed ? (i_upd_ask_px - i_upd_bid_px) : 32'hFFFF_FFFF;
    wire p_spread      = (spread <= cfg_max_spread);

    wire P = i_global_enable && cfg_en && tradable && p_spread;

    // -------------------------------------------------------------------------
    // Rule Conditions (Section 10.1)
    // -------------------------------------------------------------------------
    // Rule 0: CROSS_BUY: ask_px <= buy_limit -> buy at ask_px
    wire cond_0 = (i_upd_ask_px <= cfg_buy_limit);

    // Rule 1: CROSS_SELL: bid_px >= sell_limit -> sell at bid_px
    wire cond_1 = (i_upd_bid_px >= cfg_sell_limit);

    // Rule 2: IMB_BUY: bid_qty >= (ask_qty << imb_shift) (39-bit compare) -> buy at ask_px
    wire [38:0] shifted_ask = {7'd0, i_upd_ask_qty} << cfg_imb_shift;
    wire cond_2 = ({7'd0, i_upd_bid_qty} >= shifted_ask);

    // Rule 3: IMB_SELL: ask_qty >= (bid_qty << imb_shift) (39-bit compare) -> sell at bid_px
    wire [38:0] shifted_bid = {7'd0, i_upd_bid_qty} << cfg_imb_shift;
    wire cond_3 = ({7'd0, i_upd_ask_qty} >= shifted_bid);

    // -------------------------------------------------------------------------
    // Edge-Trigger Armed State Machine (Section 10.1)
    // State: armed[sym][4], one bit per rule.
    // Evaluation happens only on upd_valid and upd_last.
    // After every evaluation armed[i] <= P and cond_i.
    // -------------------------------------------------------------------------
    reg [3:0] armed [0:N_SYMBOLS-1];

    wire [3:0] cur_armed = armed[sym_idx];

    // Firing logic
    wire [3:0] fire;
    assign fire[0] = P && cfg_rule_mask[0] && cond_0 && !cur_armed[0];
    assign fire[1] = P && cfg_rule_mask[1] && cond_1 && !cur_armed[1];
    assign fire[2] = P && cfg_rule_mask[2] && cond_2 && !cur_armed[2];
    assign fire[3] = P && cfg_rule_mask[3] && cond_3 && !cur_armed[3];

    // Priority arbitration: lowest rule id emits
    reg        cand_fire;
    reg [1:0]  cand_rule_sel;
    reg        cand_side_sel;
    reg [31:0] cand_price_sel;

    always @(*) begin
        cand_fire      = 1'b0;
        cand_rule_sel  = 2'd0;
        cand_side_sel  = `T2T_SIDE_BID;
        cand_price_sel = i_upd_ask_px;

        if (fire[0]) begin
            cand_fire      = 1'b1;
            cand_rule_sel  = 2'd0;
            cand_side_sel  = `T2T_SIDE_BID; // Buy at touch ask
            cand_price_sel = i_upd_ask_px;
        end else if (fire[1]) begin
            cand_fire      = 1'b1;
            cand_rule_sel  = 2'd1;
            cand_side_sel  = `T2T_SIDE_ASK; // Sell at touch bid
            cand_price_sel = i_upd_bid_px;
        end else if (fire[2]) begin
            cand_fire      = 1'b1;
            cand_rule_sel  = 2'd2;
            cand_side_sel  = `T2T_SIDE_BID; // Buy at touch ask
            cand_price_sel = i_upd_ask_px;
        end else if (fire[3]) begin
            cand_fire      = 1'b1;
            cand_rule_sel  = 2'd3;
            cand_side_sel  = `T2T_SIDE_ASK; // Sell at touch bid
            cand_price_sel = i_upd_bid_px;
        end
    end

    // Sequential state update for armed bits
    integer s;
    always @(posedge clk) begin
        if (rst) begin
            for (s = 0; s < N_SYMBOLS; s = s + 1) begin
                armed[s] <= 4'd0;
            end
        end else if (i_upd_valid && i_upd_last && sym_valid_range) begin
            armed[sym_idx][0] <= P && cond_0;
            armed[sym_idx][1] <= P && cond_1;
            armed[sym_idx][2] <= P && cond_2;
            armed[sym_idx][3] <= P && cond_3;
        end
    end

    // -------------------------------------------------------------------------
    // Pipeline Stage 1 Registers (Cycle 1)
    // -------------------------------------------------------------------------
    reg        stg1_valid;
    reg [3:0]  stg1_sym;
    reg        stg1_side;
    reg [31:0] stg1_price;
    reg [15:0] stg1_qty;
    reg [1:0]  stg1_rule;
    reg [31:0] stg1_idx;

    always @(posedge clk) begin
        if (rst) begin
            stg1_valid <= 1'b0;
            stg1_sym   <= 4'd0;
            stg1_side  <= 1'b0;
            stg1_price <= 32'd0;
            stg1_qty   <= 16'd0;
            stg1_rule  <= 2'd0;
            stg1_idx   <= 32'd0;
        end else begin
            stg1_valid <= i_upd_valid && i_upd_last && cand_fire;
            stg1_sym   <= i_upd_sym;
            stg1_side  <= cand_side_sel;
            stg1_price <= cand_price_sel;
            stg1_qty   <= cfg_qty;
            stg1_rule  <= cand_rule_sel;
            stg1_idx   <= i_upd_idx;
        end
    end

    // -------------------------------------------------------------------------
    // Pipeline Stage 2 Registers (Cycle 2, Outputs)
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            o_cand_valid <= 1'b0;
            o_cand_sym   <= 4'd0;
            o_cand_side  <= 1'b0;
            o_cand_price <= 32'd0;
            o_cand_qty   <= 16'd0;
            o_cand_rule  <= 2'd0;
            o_cand_idx   <= 32'd0;
            o_cnt_cand   <= 1'b0;
        end else begin
            o_cand_valid <= stg1_valid;
            o_cand_sym   <= stg1_sym;
            o_cand_side  <= stg1_side;
            o_cand_price <= stg1_price;
            o_cand_qty   <= stg1_qty;
            o_cand_rule  <= stg1_rule;
            o_cand_idx   <= stg1_idx;
            o_cnt_cand   <= stg1_valid;
        end
    end

endmodule
