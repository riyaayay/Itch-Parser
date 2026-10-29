// =============================================================================
// File        : rtl/t2t_risk.v
// Spec Section: 5.2, 5.3, 10.2 (Sequentially Consistent Pre-Trade Risk Engine)
// Description : Pipeline Stage S8: Pre-trade risk checks with 9-step priority
//               ladder, 2-stage LUT multiplier, and single-cycle state mutation
//               loop ensuring strict sequential consistency.
// Latency     : Depth 4 cycles.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module t2t_risk #(
    parameter N_SYMBOLS = `T2T_N_SYMBOLS
) (
    input  wire                               clk,
    input  wire                               rst,

    // Out-of-band kill and fault inputs
    input  wire                               i_kill,
    input  wire                               i_tx_fault,

    // Global Risk Limits
    input  wire [31:0]                        i_max_gross,
    input  wire [15:0]                        i_max_orders,
    input  wire [4:0]                         i_win_shift,

    // Per-Symbol Risk Configuration (8 * 161 = 1288 bits)
    input  wire [N_SYMBOLS*`T2T_RCFG_SYM_W-1:0] i_rcfg,

    // Input CAND interface from S7 Trigger
    input  wire                               i_cand_valid,
    input  wire [3:0]                         i_cand_sym,
    input  wire                               i_cand_side,
    input  wire [31:0]                        i_cand_price,
    input  wire [15:0]                        i_cand_qty,
    input  wire [1:0]                         i_cand_rule,
    input  wire [31:0]                        i_cand_idx,

    // Output DEC interface to S9 Encoder (Depth 4)
    output reg                                o_dec_valid,
    output reg                                o_dec_pass,
    output reg  [3:0]                         o_dec_reason,
    output reg  [3:0]                         o_dec_sym,
    output reg                                o_dec_side,
    output reg  [31:0]                        o_dec_price,
    output reg  [15:0]                        o_dec_qty,
    output reg  [1:0]                         o_dec_rule,
    output reg  [31:0]                        o_dec_idx,

    // Diagnostic Snapshot Outputs (to Host Register File 11.2)
    output wire [N_SYMBOLS*32-1:0]            o_risk_pos_flat,
    output wire [31:0]                        o_risk_gross,
    output wire [31:0]                        o_risk_win_id,
    output wire [15:0]                        o_risk_win_cnt,

    // Performance / Diagnostic Counter Pulses
    output reg                                o_cnt_pass,
    output reg                                o_cnt_rej_1,
    output reg                                o_cnt_rej_2,
    output reg                                o_cnt_rej_3,
    output reg                                o_cnt_rej_4,
    output reg                                o_cnt_rej_5,
    output reg                                o_cnt_rej_6,
    output reg                                o_cnt_rej_7,
    output reg                                o_cnt_rej_8,
    output reg                                o_cnt_rej_15
);

    // -------------------------------------------------------------------------
    // Configuration Extraction for current symbol
    // -------------------------------------------------------------------------
    wire [2:0] sym_idx = i_cand_sym[2:0];
    reg [`T2T_RCFG_SYM_W-1:0] cfg;
    integer c;
    always @(*) begin
        cfg = i_rcfg[`T2T_RCFG_SYM_W-1:0];
        for (c = 0; c < N_SYMBOLS; c = c + 1) begin
            if (sym_idx == c[2:0]) begin
                cfg = i_rcfg[c*`T2T_RCFG_SYM_W +: `T2T_RCFG_SYM_W];
            end
        end
    end

    wire        cfg_valid        = cfg[`T2T_RCFG_VALID_BIT];
    wire [15:0] cfg_max_qty      = cfg[`T2T_RCFG_MAXQTY_HI  : `T2T_RCFG_MAXQTY_LO];
    wire [47:0] cfg_max_notional = cfg[`T2T_RCFG_MAXNOT_HI  : `T2T_RCFG_MAXNOT_LO];
    wire [31:0] cfg_collar_abs   = cfg[`T2T_RCFG_COLLAR_HI  : `T2T_RCFG_COLLAR_LO];
    wire [31:0] cfg_ref_px       = cfg[`T2T_RCFG_REFPX_HI   : `T2T_RCFG_REFPX_LO];
    wire [31:0] cfg_max_pos      = cfg[`T2T_RCFG_MAXPOS_HI  : `T2T_RCFG_MAXPOS_LO];

    // -------------------------------------------------------------------------
    // 2-Stage LUT Multiplier for Notional = price * qty (Section 10.2, no DSP)
    // -------------------------------------------------------------------------
    wire [47:0] mul_prod;
    t2t_mul32x16 u_mul (
        .clk    (clk),
        .rst    (rst),
        .i_a    (i_cand_price),
        .i_b    (i_cand_qty),
        .o_prod (mul_prod)
    );

    // -------------------------------------------------------------------------
    // Pipeline Stage 1 Registers (Cycle 1)
    // -------------------------------------------------------------------------
    reg        s1_valid;
    reg [3:0]  s1_sym;
    reg        s1_side;
    reg [31:0] s1_price;
    reg [15:0] s1_qty;
    reg [1:0]  s1_rule;
    reg [31:0] s1_idx;
    reg        s1_kill;
    reg        s1_tx_fault;
    reg        s1_cfg_valid;
    reg [15:0] s1_max_qty;
    reg [47:0] s1_max_notional;
    reg [31:0] s1_collar_abs;
    reg [31:0] s1_ref_px;
    reg [31:0] s1_max_pos;
    reg [31:0] s1_max_gross;
    reg [15:0] s1_max_orders;
    reg [4:0]  s1_win_shift;

    always @(posedge clk) begin
        if (rst) begin
            s1_valid        <= 1'b0;
            s1_sym          <= 4'd0;
            s1_side         <= 1'b0;
            s1_price        <= 32'd0;
            s1_qty          <= 16'd0;
            s1_rule         <= 2'd0;
            s1_idx          <= 32'd0;
            s1_kill         <= 1'b0;
            s1_tx_fault     <= 1'b0;
            s1_cfg_valid    <= 1'b0;
            s1_max_qty      <= 16'd0;
            s1_max_notional <= 48'd0;
            s1_collar_abs   <= 32'd0;
            s1_ref_px       <= 32'd0;
            s1_max_pos      <= 32'd0;
            s1_max_gross    <= 32'd0;
            s1_max_orders   <= 16'd0;
            s1_win_shift    <= 5'd0;
        end else begin
            s1_valid        <= i_cand_valid;
            s1_sym          <= i_cand_sym;
            s1_side         <= i_cand_side;
            s1_price        <= i_cand_price;
            s1_qty          <= i_cand_qty;
            s1_rule         <= i_cand_rule;
            s1_idx          <= i_cand_idx;
            s1_kill         <= i_kill;
            s1_tx_fault     <= i_tx_fault;
            s1_cfg_valid    <= cfg_valid;
            s1_max_qty      <= cfg_max_qty;
            s1_max_notional <= cfg_max_notional;
            s1_collar_abs   <= cfg_collar_abs;
            s1_ref_px       <= cfg_ref_px;
            s1_max_pos      <= cfg_max_pos;
            s1_max_gross    <= i_max_gross;
            s1_max_orders   <= i_max_orders;
            s1_win_shift    <= i_win_shift;
        end
    end

    // -------------------------------------------------------------------------
    // Pipeline Stage 2 Registers (Cycle 2, Multiplier finishes)
    // -------------------------------------------------------------------------
    reg        s2_valid;
    reg [3:0]  s2_sym;
    reg        s2_side;
    reg [31:0] s2_price;
    reg [15:0] s2_qty;
    reg [1:0]  s2_rule;
    reg [31:0] s2_idx;
    reg [31:0] s2_collar_delta;
    reg        s2_kill;
    reg        s2_tx_fault;
    reg        s2_cfg_valid;
    reg [15:0] s2_max_qty;
    reg [47:0] s2_max_notional;
    reg [31:0] s2_collar_abs;
    reg [31:0] s2_max_pos;
    reg [31:0] s2_max_gross;
    reg [15:0] s2_max_orders;
    reg [4:0]  s2_win_shift;

    wire [31:0] collar_delta = (s1_price >= s1_ref_px) ? (s1_price - s1_ref_px) : (s1_ref_px - s1_price);

    always @(posedge clk) begin
        if (rst) begin
            s2_valid        <= 1'b0;
            s2_sym          <= 4'd0;
            s2_side         <= 1'b0;
            s2_price        <= 32'd0;
            s2_qty          <= 16'd0;
            s2_rule         <= 2'd0;
            s2_idx          <= 32'd0;
            s2_collar_delta <= 32'd0;
            s2_kill         <= 1'b0;
            s2_tx_fault     <= 1'b0;
            s2_cfg_valid    <= 1'b0;
            s2_max_qty      <= 16'd0;
            s2_max_notional <= 48'd0;
            s2_collar_abs   <= 32'd0;
            s2_max_pos      <= 32'd0;
            s2_max_gross    <= 32'd0;
            s2_max_orders   <= 16'd0;
            s2_win_shift    <= 5'd0;
        end else begin
            s2_valid        <= s1_valid;
            s2_sym          <= s1_sym;
            s2_side         <= s1_side;
            s2_price        <= s1_price;
            s2_qty          <= s1_qty;
            s2_rule         <= s1_rule;
            s2_idx          <= s1_idx;
            s2_collar_delta <= collar_delta;
            s2_kill         <= s1_kill;
            s2_tx_fault     <= s1_tx_fault;
            s2_cfg_valid    <= s1_cfg_valid;
            s2_max_qty      <= s1_max_qty;
            s2_max_notional <= s1_max_notional;
            s2_collar_abs   <= s1_collar_abs;
            s2_max_pos      <= s1_max_pos;
            s2_max_gross    <= s1_max_gross;
            s2_max_orders   <= s1_max_orders;
            s2_win_shift    <= s1_win_shift;
        end
    end

    // -------------------------------------------------------------------------
    // Pipeline Stage 3 Registers (Cycle 3, State-independent checks)
    // -------------------------------------------------------------------------
    wire chk_kill     = s2_kill;
    wire chk_tx_fault = s2_tx_fault;
    wire chk_unknown  = !s2_cfg_valid;
    wire chk_qty      = (s2_qty == 16'd0) || (s2_qty > s2_max_qty);
    wire chk_notional = (mul_prod > s2_max_notional);
    wire chk_collar   = (s2_collar_delta > s2_collar_abs);

    reg       early_fail;
    reg [3:0] early_reason;

    always @(*) begin
        early_fail   = 1'b0;
        early_reason = `T2T_RSN_PASS;

        if (chk_kill) begin
            early_fail   = 1'b1;
            early_reason = `T2T_RSN_KILL;
        end else if (chk_tx_fault) begin
            early_fail   = 1'b1;
            early_reason = `T2T_RSN_TX_FAULT;
        end else if (chk_unknown) begin
            early_fail   = 1'b1;
            early_reason = `T2T_RSN_UNKNOWN;
        end else if (chk_qty) begin
            early_fail   = 1'b1;
            early_reason = `T2T_RSN_QTY;
        end else if (chk_notional) begin
            early_fail   = 1'b1;
            early_reason = `T2T_RSN_NOTIONAL;
        end else if (chk_collar) begin
            early_fail   = 1'b1;
            early_reason = `T2T_RSN_COLLAR;
        end
    end

    reg        s3_valid;
    reg [3:0]  s3_sym;
    reg        s3_side;
    reg [31:0] s3_price;
    reg [15:0] s3_qty;
    reg [1:0]  s3_rule;
    reg [31:0] s3_idx;
    reg        s3_early_fail;
    reg [3:0]  s3_early_reason;
    reg [31:0] s3_max_pos;
    reg [31:0] s3_max_gross;
    reg [15:0] s3_max_orders;
    reg [4:0]  s3_win_shift;

    always @(posedge clk) begin
        if (rst) begin
            s3_valid        <= 1'b0;
            s3_sym          <= 4'd0;
            s3_side         <= 1'b0;
            s3_price        <= 32'd0;
            s3_qty          <= 16'd0;
            s3_rule         <= 2'd0;
            s3_idx          <= 32'd0;
            s3_early_fail   <= 1'b0;
            s3_early_reason <= 4'd0;
            s3_max_pos      <= 32'd0;
            s3_max_gross    <= 32'd0;
            s3_max_orders   <= 16'd0;
            s3_win_shift    <= 5'd0;
        end else begin
            s3_valid        <= s2_valid;
            s3_sym          <= s2_sym;
            s3_side         <= s2_side;
            s3_price        <= s2_price;
            s3_qty          <= s2_qty;
            s3_rule         <= s2_rule;
            s3_idx          <= s2_idx;
            s3_early_fail   <= early_fail;
            s3_early_reason <= early_reason;
            s3_max_pos      <= s2_max_pos;
            s3_max_gross    <= s2_max_gross;
            s3_max_orders   <= s2_max_orders;
            s3_win_shift    <= s2_win_shift;
        end
    end

    // -------------------------------------------------------------------------
    // Pipeline Stage 4: State-Dependent Checks & 1-Cycle Mutation Loop (Cycle 4)
    // -------------------------------------------------------------------------
    reg signed [31:0] pos [0:N_SYMBOLS-1];
    reg [31:0]        gross;
    reg [31:0]        r_win_id;
    reg [15:0]        r_win_cnt;

    // Rate window sliding calculation (Section 10.2)
    wire [31:0] cand_win_id   = s3_idx >> s3_win_shift;
    wire        win_rolled    = (cand_win_id != r_win_id);
    wire [15:0] eval_win_cnt  = win_rolled ? 16'd0 : r_win_cnt;
    wire        chk_rate      = (eval_win_cnt >= s3_max_orders);

    // Position check (signed 32-bit net shares)
    wire [2:0] s3_sym_idx = s3_sym[2:0];
    wire signed [32:0] cur_pos = $signed({pos[s3_sym_idx][31], pos[s3_sym_idx]});
    wire signed [32:0] delta_pos = (s3_side == `T2T_SIDE_BID) ? $signed({17'd0, s3_qty}) : -$signed({17'd0, s3_qty});
    wire signed [32:0] next_pos = cur_pos + delta_pos;
    wire [31:0] abs_next_pos = (next_pos < 0) ? -next_pos[31:0] : next_pos[31:0];
    wire        chk_pos_sym  = (abs_next_pos > s3_max_pos);

    // Gross position check (saturating unsigned 32-bit sum)
    wire [32:0] sum_gross = {1'b0, gross} + {17'd0, s3_qty};
    wire        chk_pos_glob = (sum_gross > {1'b0, s3_max_gross});

    // 9-Step Priority Arbitration (Section 10.2)
    reg       eval_pass;
    reg [3:0] eval_reason;

    always @(*) begin
        if (s3_early_fail) begin
            eval_pass   = 1'b0;
            eval_reason = s3_early_reason;
        end else if (chk_pos_sym) begin
            eval_pass   = 1'b0;
            eval_reason = `T2T_RSN_POS_SYM;
        end else if (chk_pos_glob) begin
            eval_pass   = 1'b0;
            eval_reason = `T2T_RSN_POS_GLOB;
        end else if (chk_rate) begin
            eval_pass   = 1'b0;
            eval_reason = `T2T_RSN_RATE;
        end else begin
            eval_pass   = 1'b1;
            eval_reason = `T2T_RSN_PASS;
        end
    end

    // Sequential state update & output registration
    integer p;
    always @(posedge clk) begin
        if (rst) begin
            for (p = 0; p < N_SYMBOLS; p = p + 1) begin
                pos[p] <= 32'sd0;
            end
            gross     <= 32'd0;
            r_win_id  <= 32'hFFFF_FFFF;
            r_win_cnt <= 16'd0;

            o_dec_valid  <= 1'b0;
            o_dec_pass   <= 1'b0;
            o_dec_reason <= 4'd0;
            o_dec_sym    <= 4'd0;
            o_dec_side   <= 1'b0;
            o_dec_price  <= 32'd0;
            o_dec_qty    <= 16'd0;
            o_dec_rule   <= 2'd0;
            o_dec_idx    <= 32'd0;

            o_cnt_pass   <= 1'b0;
            o_cnt_rej_1  <= 1'b0;
            o_cnt_rej_2  <= 1'b0;
            o_cnt_rej_3  <= 1'b0;
            o_cnt_rej_4  <= 1'b0;
            o_cnt_rej_5  <= 1'b0;
            o_cnt_rej_6  <= 1'b0;
            o_cnt_rej_7  <= 1'b0;
            o_cnt_rej_8  <= 1'b0;
            o_cnt_rej_15 <= 1'b0;
        end else begin
            // Register DEC output
            o_dec_valid  <= s3_valid;
            o_dec_pass   <= eval_pass;
            o_dec_reason <= eval_reason;
            o_dec_sym    <= s3_sym;
            o_dec_side   <= s3_side;
            o_dec_price  <= s3_price;
            o_dec_qty    <= s3_qty;
            o_dec_rule   <= s3_rule;
            o_dec_idx    <= s3_idx;

            // Clear counter pulses by default
            o_cnt_pass   <= 1'b0;
            o_cnt_rej_1  <= 1'b0;
            o_cnt_rej_2  <= 1'b0;
            o_cnt_rej_3  <= 1'b0;
            o_cnt_rej_4  <= 1'b0;
            o_cnt_rej_5  <= 1'b0;
            o_cnt_rej_6  <= 1'b0;
            o_cnt_rej_7  <= 1'b0;
            o_cnt_rej_8  <= 1'b0;
            o_cnt_rej_15 <= 1'b0;

            if (s3_valid) begin
                // Update diagnostic counter pulses
                if (eval_pass) begin
                    o_cnt_pass <= 1'b1;
                end else begin
                    case (eval_reason)
                        `T2T_RSN_KILL:     o_cnt_rej_1  <= 1'b1;
                        `T2T_RSN_QTY:      o_cnt_rej_2  <= 1'b1;
                        `T2T_RSN_NOTIONAL: o_cnt_rej_3  <= 1'b1;
                        `T2T_RSN_COLLAR:   o_cnt_rej_4  <= 1'b1;
                        `T2T_RSN_POS_SYM:  o_cnt_rej_5  <= 1'b1;
                        `T2T_RSN_POS_GLOB: o_cnt_rej_6  <= 1'b1;
                        `T2T_RSN_RATE:     o_cnt_rej_7  <= 1'b1;
                        `T2T_RSN_TX_FAULT: o_cnt_rej_8  <= 1'b1;
                        `T2T_RSN_UNKNOWN:  o_cnt_rej_15 <= 1'b1;
                        default: ;
                    endcase
                end

                // Window ID updates whenever candidate belongs to a new window
                if (win_rolled) begin
                    r_win_id  <= cand_win_id;
                    r_win_cnt <= eval_pass ? 16'd1 : 16'd0;
                end else if (eval_pass) begin
                    r_win_cnt <= r_win_cnt + 16'd1;
                end

                // State mutation on PASS only (Sequential Consistency)
                if (eval_pass) begin
                    pos[s3_sym_idx] <= next_pos[31:0];
                    gross <= (sum_gross > 33'h0_FFFF_FFFF) ? 32'hFFFF_FFFF : sum_gross[31:0];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Diagnostic Flattened Outputs (Section 11.2)
    // -------------------------------------------------------------------------
    genvar g;
    generate
        for (g = 0; g < N_SYMBOLS; g = g + 1) begin : gen_pos_flat
            assign o_risk_pos_flat[g*32 +: 32] = pos[g];
        end
    endgenerate

    assign o_risk_gross   = gross;
    assign o_risk_win_id  = r_win_id;
    assign o_risk_win_cnt = r_win_cnt;

endmodule
