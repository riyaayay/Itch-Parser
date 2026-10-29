// =============================================================================
// File        : rtl/t2t_top.v
// Spec Section: 4.3, 4.5, 5.1, 11.4 (Top-Level Hardware Trading Engine)
// Description : Full tick-to-trade pipeline integration with normative
//               instance hierarchy (u_sess, u_ingest, u_framer, u_extract,
//               u_symfilter, u_fa, u_ordtable, u_fb, u_book, u_trigger,
//               u_risk, u_encoder, u_txf, u_regs). Target: Artix-7 A7.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module t2t_top #(
    parameter N_SYMBOLS  = `T2T_N_SYMBOLS,
    parameter BOOK_N     = `T2T_BOOK_N,
    parameter TABLE_AW   = `T2T_TABLE_AW,
    parameter TABLE_WAYS = `T2T_TABLE_WAYS
) (
    input  wire         clk,
    input  wire         rst,

    // Inbound AXI4-Stream RX Interface (Section 7.1)
    input  wire [511:0] rx_axis_tdata,
    input  wire [63:0]  rx_axis_tkeep,
    input  wire         rx_axis_tvalid,
    input  wire         rx_axis_tlast,

    // Outbound AXI4-Stream TX Interface (Section 11.1)
    output wire [511:0] tx_axis_tdata,
    output wire [63:0]  tx_axis_tkeep,
    output wire         tx_axis_tvalid,
    input  wire         tx_axis_tready,
    output wire         tx_axis_tlast,

    // Control Plane AXI4-Lite Slave Interface (Section 11.2)
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

    // -------------------------------------------------------------------------
    // Control Plane Wires & Registers (u_regs)
    // -------------------------------------------------------------------------
    wire         ctrl_session_reset;
    wire         ctrl_kill_switch;
    wire         ctrl_clear_counters;
    wire         ctrl_global_enable;
    wire         ctrl_clear_fault;

    wire [N_SYMBOLS*64-1:0]             cfg_stock;
    wire [N_SYMBOLS*`T2T_TCFG_SYM_W-1:0] tcfg;
    wire [N_SYMBOLS*`T2T_RCFG_SYM_W-1:0] rcfg;
    wire [31:0]                         max_gross;
    wire [15:0]                         max_orders;
    wire [4:0]                          win_shift;

    wire [63:0]                         cnt_pulses;

    // -------------------------------------------------------------------------
    // Session Manager (u_sess, Section 4.4)
    // -------------------------------------------------------------------------
    wire sess_init_busy;
    wire sess_reset_pulse;
    wire sess_session_invalid;

    wire cnt_ingest_overflow;
    wire cnt_frame_err;
    wire cnt_keep_err;
    wire cnt_bad_len;
    wire fatal_overflow;

    t2t_sess #(
        .TABLE_AW(TABLE_AW)
    ) u_sess (
        .clk               (clk),
        .rst               (rst),
        .i_session_reset   (ctrl_session_reset),
        .i_ingest_overflow (cnt_ingest_overflow),
        .i_frame_err       (cnt_frame_err),
        .i_keep_err        (cnt_keep_err),
        .i_bad_len         (cnt_bad_len),
        .i_fatal_overflow  (fatal_overflow),
        .o_init_busy       (sess_init_busy),
        .o_sess_reset_pulse(sess_reset_pulse),
        .o_session_invalid (sess_session_invalid)
    );

    // -------------------------------------------------------------------------
    // S1: Ingest & ING FIFO (u_ingest, Section 7.1)
    // -------------------------------------------------------------------------
    wire         pop_ing;
    wire         ing_valid;
    wire [511:0] ing_data;
    wire [63:0]  ing_keep;
    wire         ing_last;
    wire         cnt_rx_dropped_init;

    t2t_ingest #(
        .ING_DEPTH (`T2T_ING_DEPTH),
        .ING_AW    (`T2T_ING_AW)
    ) u_ingest (
        .clk                 (clk),
        .rst                 (rst),
        .i_tdata             (rx_axis_tdata),
        .i_tkeep             (rx_axis_tkeep),
        .i_tvalid            (rx_axis_tvalid),
        .i_tlast             (rx_axis_tlast),
        .i_init_busy         (sess_init_busy),
        .i_pop               (pop_ing),
        .o_valid             (ing_valid),
        .o_data              (ing_data),
        .o_keep              (ing_keep),
        .o_last              (ing_last),
        .o_overflow          (cnt_ingest_overflow),
        .o_dropped_init      (cnt_rx_dropped_init)
    );

    // -------------------------------------------------------------------------
    // S2: Framer (u_framer, Section 7.2)
    // -------------------------------------------------------------------------
    wire         fa_afull;
    wire         blk_valid;
    wire [31:0]  blk_idx;
    wire [7:0]   blk_len;
    wire [399:0] blk_bytes;
    wire         cnt_rx_beats;
    wire         cnt_rx_frames;
    wire         cnt_blocks_total = blk_valid;

    t2t_framer u_framer (
        .clk         (clk),
        .rst         (rst),
        .i_valid     (ing_valid),
        .i_data      (ing_data),
        .i_keep      (ing_keep),
        .i_last      (ing_last),
        .o_pop       (pop_ing),
        .i_hold      (fa_afull),
        .i_init_busy (sess_init_busy),
        .o_blk_valid (blk_valid),
        .o_blk_idx   (blk_idx),
        .o_blk_len   (blk_len),
        .o_blk_bytes (blk_bytes),
        .o_frame_err (cnt_frame_err),
        .o_keep_err  (cnt_keep_err),
        .o_cnt_frame (cnt_rx_frames),
        .o_cnt_beat  (cnt_rx_beats)
    );

    // -------------------------------------------------------------------------
    // S3: Extract (u_extract, Section 7.3)
    // -------------------------------------------------------------------------
    wire         msg_valid;
    wire [319:0] msg_bus;
    wire [3:0]   blk_flags;
    wire [6:0]   cnt_extract_type;
    wire         cnt_extract_other;
    wire         cnt_extract_zero;
    wire         extract_session_invalid;

    t2t_extract u_extract (
        .clk               (clk),
        .rst               (rst),
        .i_blk_valid       (blk_valid),
        .i_blk_idx         (blk_idx),
        .i_blk_len         (blk_len),
        .i_blk_bytes       (blk_bytes),
        .o_msg_valid       (msg_valid),
        .o_msg             (msg_bus),
        .o_blk_flags       (blk_flags),
        .o_cnt_type        (cnt_extract_type),
        .o_cnt_other       (cnt_extract_other),
        .o_cnt_zero        (cnt_extract_zero),
        .o_cnt_badlen      (cnt_bad_len),
        .o_session_invalid (extract_session_invalid)
    );

    wire cnt_bad_side = msg_valid & blk_flags[3];

    // -------------------------------------------------------------------------
    // S4: Symbol Filter (u_symfilter, Section 8.2)
    // -------------------------------------------------------------------------
    wire         filter_valid;
    wire [324:0] filter_fa;
    wire cnt_sym_hit, cnt_sym_miss;

    t2t_symfilter u_symfilter (
        .clk                 (clk),
        .rst                 (rst),
        .i_msg_valid         (msg_valid),
        .i_msg               (msg_bus),
        .i_cfg_stock         (cfg_stock),
        .o_valid             (filter_valid),
        .o_fa                (filter_fa),
        .o_cnt_hit           (cnt_sym_hit),
        .o_cnt_miss          (cnt_sym_miss)
    );

    // -------------------------------------------------------------------------
    // FA FIFO (u_fa, Section 4.3)
    // -------------------------------------------------------------------------
    wire         pop_fa;
    wire [324:0] fa_dout;
    wire         fa_empty;
    wire         fa_full;

    t2t_sfifo #(
        .WIDTH              (`T2T_FA_W), // 325
        .DEPTH              (`T2T_FA_DEPTH), // 32
        .ADDR_W             (`T2T_FA_AW), // 5
        .ALMOST_FULL_THRESH (`T2T_FA_DEPTH - `T2T_FA_MARGIN) // 32 - 12 = 20
    ) u_fa (
        .clk     (clk),
        .rst     (rst),
        .i_push  (filter_valid),
        .i_data  (filter_fa),
        .o_full  (fa_full),
        .o_afull (fa_afull),
        .i_pop   (pop_fa),
        .o_data  (fa_dout),
        .o_empty (fa_empty),
        .o_count ()
    );

    // -------------------------------------------------------------------------
    // S5: Order Table (u_ordtable, Section 8.3)
    // -------------------------------------------------------------------------
    wire fb_afull;
    wire         ot_op_valid;
    wire [104:0] ot_op;

    wire cnt_tbl_ins, cnt_tbl_ref_miss, cnt_tbl_dup_ref, cnt_tbl_set_full;
    wire cnt_tbl_qty_underflow, cnt_tbl_same_set_stalls;

    t2t_ordtable #(
        .TABLE_AW  (TABLE_AW),
        .TABLE_WAYS(TABLE_WAYS)
    ) u_ordtable (
        .clk                  (clk),
        .rst                  (rst),
        .i_valid              (!fa_empty),
        .i_fa                 (fa_dout),
        .o_pop                (pop_fa),
        .i_fb_afull           (fb_afull),
        .i_init_busy          (sess_init_busy),
        .o_op_valid           (ot_op_valid),
        .o_op                 (ot_op),
        .o_cnt_ins            (cnt_tbl_ins),
        .o_cnt_ref_miss       (cnt_tbl_ref_miss),
        .o_cnt_dup_ref        (cnt_tbl_dup_ref),
        .o_cnt_set_full       (cnt_tbl_set_full),
        .o_cnt_qty_underflow  (cnt_tbl_qty_underflow),
        .o_cnt_same_set_stall (cnt_tbl_same_set_stalls)
    );

    // -------------------------------------------------------------------------
    // FB FIFO (u_fb, Section 4.3)
    // -------------------------------------------------------------------------
    wire         pop_fb;
    wire [104:0] fb_dout;
    wire         fb_empty;
    wire         fb_full;

    t2t_sfifo #(
        .WIDTH              (`T2T_OP_BUS_W), // 105
        .DEPTH              (`T2T_FB_DEPTH), // 32
        .ADDR_W             (`T2T_FB_AW), // 5
        .ALMOST_FULL_THRESH (`T2T_FB_DEPTH - `T2T_FB_MARGIN) // 32 - 12 = 20
    ) u_fb (
        .clk     (clk),
        .rst     (rst),
        .i_push  (ot_op_valid),
        .i_data  (ot_op),
        .o_full  (fb_full),
        .o_afull (fb_afull),
        .i_pop   (pop_fb),
        .o_data  (fb_dout),
        .o_empty (fb_empty),
        .o_count ()
    );

    // Credit violation detection (Section 4.3 Rule 6)
    assign fatal_overflow = (filter_valid & fa_full) | (ot_op_valid & fb_full);

    // -------------------------------------------------------------------------
    // S6: Order Book Engine (u_book, Section 9)
    // -------------------------------------------------------------------------
    wire         upd_valid;
    wire [3:0]   upd_sym;
    wire [31:0]  upd_idx;
    wire         upd_last;
    wire [31:0]  upd_bid_px;
    wire [31:0]  upd_bid_qty;
    wire [31:0]  upd_ask_px;
    wire [31:0]  upd_ask_qty;
    wire [3:0]   upd_bid_lv;
    wire [3:0]   upd_ask_lv;
    wire         upd_bid_stale;
    wire         upd_ask_stale;
    wire         upd_corrupt;
    wire [31:0]  upd_seq;

    wire [N_SYMBOLS*`T2T_TOB_SYM_W-1:0] bk_tob_flat;
    wire cnt_book_ops, cnt_book_same_key_bub, cnt_book_corrupt_events;
    wire cnt_book_hidden_adds, cnt_book_evictions, cnt_upd_total, cnt_upd_with_stale;

    t2t_book #(
        .BOOK_N    (BOOK_N),
        .N_SYMBOLS (N_SYMBOLS)
    ) u_book (
        .clk                   (clk),
        .rst                   (rst),
        .i_op_valid            (!fb_empty),
        .i_op                  (fb_dout),
        .o_fb_pop              (pop_fb),
        .i_init_busy           (sess_init_busy),
        .o_upd_valid           (upd_valid),
        .o_upd_sym             (upd_sym),
        .o_upd_idx             (upd_idx),
        .o_upd_last            (upd_last),
        .o_upd_bid_px          (upd_bid_px),
        .o_upd_bid_qty         (upd_bid_qty),
        .o_upd_ask_px          (upd_ask_px),
        .o_upd_ask_qty         (upd_ask_qty),
        .o_upd_bid_lv          (upd_bid_lv),
        .o_upd_ask_lv          (upd_ask_lv),
        .o_upd_bid_stale       (upd_bid_stale),
        .o_upd_ask_stale       (upd_ask_stale),
        .o_upd_corrupt         (upd_corrupt),
        .o_upd_seq             (upd_seq),
        .o_bk_tob_flat         (bk_tob_flat),
        .o_cnt_ops             (cnt_book_ops),
        .o_cnt_same_key_bubbles(cnt_book_same_key_bub),
        .o_cnt_corrupt_events  (cnt_book_corrupt_events),
        .o_cnt_hidden_adds     (cnt_book_hidden_adds),
        .o_cnt_evictions       (cnt_book_evictions),
        .o_cnt_upd_total       (cnt_upd_total),
        .o_cnt_upd_with_stale  (cnt_upd_with_stale)
    );

    // -------------------------------------------------------------------------
    // S7: Trigger Engine (u_trigger, Section 10.1)
    // -------------------------------------------------------------------------
    wire        cand_valid;
    wire [3:0]  cand_sym;
    wire        cand_side;
    wire [31:0] cand_price;
    wire [15:0] cand_qty;
    wire [1:0]  cand_rule;
    wire [31:0] cand_idx;
    wire cnt_trig_cand;

    t2t_trigger #(
        .N_SYMBOLS(N_SYMBOLS)
    ) u_trigger (
        .clk               (clk),
        .rst               (rst),
        .i_global_enable   (ctrl_global_enable),
        .i_session_invalid (sess_session_invalid),
        .i_tcfg            (tcfg),
        .i_upd_valid       (upd_valid),
        .i_upd_sym         (upd_sym),
        .i_upd_idx         (upd_idx),
        .i_upd_last        (upd_last),
        .i_upd_bid_px      (upd_bid_px),
        .i_upd_bid_qty     (upd_bid_qty),
        .i_upd_ask_px      (upd_ask_px),
        .i_upd_ask_qty     (upd_ask_qty),
        .i_upd_bid_lv      (upd_bid_lv),
        .i_upd_ask_lv      (upd_ask_lv),
        .i_upd_bid_stale   (upd_bid_stale),
        .i_upd_ask_stale   (upd_ask_stale),
        .i_upd_corrupt     (upd_corrupt),
        .i_upd_seq         (upd_seq),
        .o_cand_valid      (cand_valid),
        .o_cand_sym        (cand_sym),
        .o_cand_side       (cand_side),
        .o_cand_price      (cand_price),
        .o_cand_qty        (cand_qty),
        .o_cand_rule       (cand_rule),
        .o_cand_idx        (cand_idx),
        .o_cnt_cand        (cnt_trig_cand)
    );

    // -------------------------------------------------------------------------
    // S8: Risk Engine (u_risk, Section 10.2)
    // -------------------------------------------------------------------------
    wire        dec_valid;
    wire        dec_pass;
    wire [3:0]  dec_reason;
    wire [3:0]  dec_sym;
    wire        dec_side;
    wire [31:0] dec_price;
    wire [15:0] dec_qty;
    wire [1:0]  dec_rule;
    wire [31:0] dec_idx;

    wire [N_SYMBOLS*32-1:0] risk_pos_flat;
    wire [31:0]            risk_gross;
    wire [31:0]            risk_win_id;
    wire [15:0]            risk_win_cnt;

    wire cnt_risk_pass;
    wire cnt_risk_rej_1, cnt_risk_rej_2, cnt_risk_rej_3, cnt_risk_rej_4;
    wire cnt_risk_rej_5, cnt_risk_rej_6, cnt_risk_rej_7, cnt_risk_rej_8, cnt_risk_rej_15;
    wire tx_fault;

    t2t_risk #(
        .N_SYMBOLS(N_SYMBOLS)
    ) u_risk (
        .clk             (clk),
        .rst             (rst),
        .i_kill          (ctrl_kill_switch),
        .i_tx_fault      (tx_fault),
        .i_max_gross     (max_gross),
        .i_max_orders    (max_orders),
        .i_win_shift     (win_shift),
        .i_rcfg          (rcfg),
        .i_cand_valid    (cand_valid),
        .i_cand_sym      (cand_sym),
        .i_cand_side     (cand_side),
        .i_cand_price    (cand_price),
        .i_cand_qty      (cand_qty),
        .i_cand_rule     (cand_rule),
        .i_cand_idx      (cand_idx),
        .o_dec_valid     (dec_valid),
        .o_dec_pass      (dec_pass),
        .o_dec_reason    (dec_reason),
        .o_dec_sym       (dec_sym),
        .o_dec_side      (dec_side),
        .o_dec_price     (dec_price),
        .o_dec_qty       (dec_qty),
        .o_dec_rule      (dec_rule),
        .o_dec_idx       (dec_idx),
        .o_risk_pos_flat (risk_pos_flat),
        .o_risk_gross    (risk_gross),
        .o_risk_win_id   (risk_win_id),
        .o_risk_win_cnt  (risk_win_cnt),
        .o_cnt_pass      (cnt_risk_pass),
        .o_cnt_rej_1     (cnt_risk_rej_1),
        .o_cnt_rej_2     (cnt_risk_rej_2),
        .o_cnt_rej_3     (cnt_risk_rej_3),
        .o_cnt_rej_4     (cnt_risk_rej_4),
        .o_cnt_rej_5     (cnt_risk_rej_5),
        .o_cnt_rej_6     (cnt_risk_rej_6),
        .o_cnt_rej_7     (cnt_risk_rej_7),
        .o_cnt_rej_8     (cnt_risk_rej_8),
        .o_cnt_rej_15    (cnt_risk_rej_15)
    );

    // -------------------------------------------------------------------------
    // S9: Encoder (u_encoder, Section 11.1)
    // -------------------------------------------------------------------------
    wire         txf_push;
    wire [511:0] txf_data;
    wire [63:0]  txf_keep;
    wire         txf_last;
    wire         txf_full;
    wire         txf_afull;
    wire cnt_tx_frames, cnt_tx_overflow;

    t2t_encoder #(
        .N_SYMBOLS(N_SYMBOLS)
    ) u_encoder (
        .clk               (clk),
        .rst               (rst),
        .i_clear_fault     (ctrl_clear_fault),
        .i_cfg_stock       (cfg_stock),
        .i_dec_valid       (dec_valid),
        .i_dec_pass        (dec_pass),
        .i_dec_reason      (dec_reason),
        .i_dec_sym         (dec_sym),
        .i_dec_side        (dec_side),
        .i_dec_price       (dec_price),
        .i_dec_qty         (dec_qty),
        .i_dec_rule        (dec_rule),
        .i_dec_idx         (dec_idx),
        .i_txf_full        (txf_full),
        .o_txf_push        (txf_push),
        .o_txf_data        (txf_data),
        .o_txf_keep        (txf_keep),
        .o_txf_last        (txf_last),
        .o_tx_fault        (tx_fault),
        .o_cnt_tx_frames   (cnt_tx_frames),
        .o_cnt_tx_overflow (cnt_tx_overflow)
    );

    // -------------------------------------------------------------------------
    // TX FIFO (u_txf, Section 11.1)
    // -------------------------------------------------------------------------
    wire         txf_empty;
    wire [576:0] txf_dout;
    wire         pop_txf = !txf_empty && tx_axis_tready;

    t2t_sfifo #(
        .WIDTH             (512 + 64 + 1), // 577
        .DEPTH             (`T2T_TXF_DEPTH), // 16
        .ADDR_W            (`T2T_TXF_AW), // 4
        .ALMOST_FULL_THRESH(12)
    ) u_txf (
        .clk     (clk),
        .rst     (rst),
        .i_push  (txf_push),
        .i_data  ({txf_last, txf_keep, txf_data}),
        .o_full  (txf_full),
        .o_afull (txf_afull),
        .i_pop   (pop_txf),
        .o_data  (txf_dout),
        .o_empty (txf_empty),
        .o_count ()
    );

    assign tx_axis_tvalid = !txf_empty;
    assign tx_axis_tdata  = txf_dout[511:0];
    assign tx_axis_tkeep  = txf_dout[575:512];
    assign tx_axis_tlast  = txf_dout[576];

    // -------------------------------------------------------------------------
    // 64 Hardware Counters Mapping (Section 11.3)
    // -------------------------------------------------------------------------
    assign cnt_pulses[0]  = cnt_rx_beats;
    assign cnt_pulses[1]  = cnt_rx_frames;
    assign cnt_pulses[2]  = cnt_ingest_overflow;
    assign cnt_pulses[3]  = cnt_rx_dropped_init;
    assign cnt_pulses[4]  = cnt_frame_err;
    assign cnt_pulses[5]  = cnt_keep_err;
    assign cnt_pulses[6]  = cnt_blocks_total;
    assign cnt_pulses[7]  = cnt_extract_type[0]; // A
    assign cnt_pulses[8]  = cnt_extract_type[1]; // F
    assign cnt_pulses[9]  = cnt_extract_type[2]; // E
    assign cnt_pulses[10] = cnt_extract_type[3]; // C
    assign cnt_pulses[11] = cnt_extract_type[4]; // X
    assign cnt_pulses[12] = cnt_extract_type[5]; // D
    assign cnt_pulses[13] = cnt_extract_type[6]; // U
    assign cnt_pulses[14] = cnt_extract_other;
    assign cnt_pulses[15] = cnt_extract_zero;
    assign cnt_pulses[16] = cnt_bad_len;
    assign cnt_pulses[17] = cnt_bad_side;
    assign cnt_pulses[18] = cnt_sym_hit;
    assign cnt_pulses[19] = cnt_sym_miss;
    assign cnt_pulses[20] = cnt_tbl_ins;
    assign cnt_pulses[21] = cnt_tbl_ref_miss;
    assign cnt_pulses[22] = cnt_tbl_dup_ref;
    assign cnt_pulses[23] = cnt_tbl_set_full;
    assign cnt_pulses[24] = cnt_tbl_qty_underflow;
    assign cnt_pulses[25] = cnt_tbl_same_set_stalls;
    assign cnt_pulses[26] = cnt_book_ops;
    assign cnt_pulses[27] = cnt_book_same_key_bub;
    assign cnt_pulses[28] = cnt_book_corrupt_events;
    assign cnt_pulses[29] = cnt_book_hidden_adds;
    assign cnt_pulses[30] = cnt_book_evictions;
    assign cnt_pulses[31] = cnt_trig_cand;
    assign cnt_pulses[32] = cnt_risk_pass;
    assign cnt_pulses[33] = cnt_risk_rej_1;
    assign cnt_pulses[34] = cnt_risk_rej_2;
    assign cnt_pulses[35] = cnt_risk_rej_3;
    assign cnt_pulses[36] = cnt_risk_rej_4;
    assign cnt_pulses[37] = cnt_risk_rej_5;
    assign cnt_pulses[38] = cnt_risk_rej_6;
    assign cnt_pulses[39] = cnt_risk_rej_7;
    assign cnt_pulses[40] = cnt_risk_rej_8;
    assign cnt_pulses[41] = cnt_risk_rej_15;
    assign cnt_pulses[42] = cnt_tx_frames;
    assign cnt_pulses[43] = cnt_tx_overflow;
    assign cnt_pulses[44] = cnt_upd_total;
    assign cnt_pulses[45] = cnt_upd_with_stale;
    assign cnt_pulses[46] = fatal_overflow;
    assign cnt_pulses[63:47] = 17'd0;

    // -------------------------------------------------------------------------
    // Control Plane Register File (u_regs, Section 11.2)
    // -------------------------------------------------------------------------
    wire [31:0] best_bid0 = bk_tob_flat[`T2T_TOB_BID_PX_LO +: 32];
    wire [31:0] best_ask0 = bk_tob_flat[`T2T_TOB_ASK_PX_LO +: 32];

    t2t_regs #(
        .N_SYMBOLS  (N_SYMBOLS),
        .BOOK_N     (BOOK_N),
        .TABLE_AW   (TABLE_AW),
        .TABLE_WAYS (TABLE_WAYS)
    ) u_regs (
        .clk               (clk),
        .rst               (rst),
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
        .s_axi_ctrl_rready (s_axi_ctrl_rready),
        .i_session_invalid (sess_session_invalid),
        .i_init_busy       (sess_init_busy),
        .i_tx_fault        (tx_fault),
        .i_live_best_bid0  (best_bid0),
        .i_live_best_ask0  (best_ask0),
        .i_bk_tob_flat     (bk_tob_flat),
        .i_risk_pos_flat   (risk_pos_flat),
        .i_risk_gross      (risk_gross),
        .i_risk_win_id     (risk_win_id),
        .i_risk_win_cnt    (risk_win_cnt),
        .i_cnt_pulses      (cnt_pulses),
        .o_session_reset   (ctrl_session_reset),
        .o_kill_switch     (ctrl_kill_switch),
        .o_clear_counters  (ctrl_clear_counters),
        .o_global_enable   (ctrl_global_enable),
        .o_clear_fault     (ctrl_clear_fault),
        .o_cfg_stock       (cfg_stock),
        .o_tcfg            (tcfg),
        .o_rcfg            (rcfg),
        .o_max_gross       (max_gross),
        .o_max_orders      (max_orders),
        .o_win_shift       (win_shift)
    );

endmodule
