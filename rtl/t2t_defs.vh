// =============================================================================
// File        : rtl/t2t_defs.vh
// Spec Section: 4.1, 4.2, 5.2, 6.1, 8, 9, 10, 11
// Description : Single source-of-truth global macro & parameter definitions
//               for tick2trade-fpga. Synthesizable Verilog-2005.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`ifndef T2T_DEFS_VH
`define T2T_DEFS_VH

// -----------------------------------------------------------------------------
// 4.1 Build Profiles [N]
// Default target: Artix-7 xc7a35tcpg236-1 (T2T_PROFILE_A7)
// -----------------------------------------------------------------------------
`ifndef T2T_PROFILE_U55C
  `ifndef T2T_PROFILE_A7
    `define T2T_PROFILE_A7
  `endif
`endif

`ifdef T2T_PROFILE_U55C
  `define T2T_TABLE_AW       12
  `define T2T_ORDER_CAP      16384
`else
  `define T2T_TABLE_AW       9
  `define T2T_ORDER_CAP      2048
`endif

`define T2T_N_SYMBOLS        8
`define T2T_MAX_SYMBOLS      16
`define T2T_BOOK_N           8
`define T2T_TABLE_WAYS       4
`define T2T_ING_DEPTH        64
`define T2T_ING_AW           6
`define T2T_FA_DEPTH         32
`define T2T_FA_AW            5
`define T2T_FB_DEPTH         32
`define T2T_FB_AW            5
`define T2T_TXF_DEPTH        16
`define T2T_TXF_AW           4

// Credit margins (Section 4.3 Rule 5)
`define T2T_FA_MARGIN        12
`define T2T_FB_MARGIN        12

// -----------------------------------------------------------------------------
// 4.1 Fixed Field Widths [N]
// -----------------------------------------------------------------------------
`define T2T_SYM_W            4
`define T2T_LV_W             4
`define T2T_PX_W             32
`define T2T_QTY_W            32
`define T2T_CNT_W            16
`define T2T_HID_W            20
`define T2T_IDX_W            32
`define T2T_SEQ_W            32
`define T2T_REF_W            64
`define T2T_LOC_W            16
`define T2T_STOCK_W          64
`define T2T_TYPE_W           8
`define T2T_SIDE_BYTE_W      8

// -----------------------------------------------------------------------------
// 4.2 & 6.1 Inbound ITCH 5.0 Type & Length Constants [N]
// -----------------------------------------------------------------------------
`define T2T_TYPE_A           8'h41   // 'A' Add Order (No MPID)
`define T2T_TYPE_F           8'h46   // 'F' Add Order (With MPID)
`define T2T_TYPE_E           8'h45   // 'E' Order Executed
`define T2T_TYPE_C           8'h43   // 'C' Order Executed With Price
`define T2T_TYPE_X           8'h58   // 'X' Order Cancel
`define T2T_TYPE_D           8'h44   // 'D' Order Delete
`define T2T_TYPE_U           8'h55   // 'U' Order Replace

`define T2T_LEN_A            8'd36
`define T2T_LEN_F            8'd40
`define T2T_LEN_E            8'd31
`define T2T_LEN_C            8'd36
`define T2T_LEN_X            8'd23
`define T2T_LEN_D            8'd19
`define T2T_LEN_U            8'd35
`define T2T_MAX_ITCH_LEN     8'd50

// -----------------------------------------------------------------------------
// 4.2 & 4.6 Side Constants & Internal Operation Codes [N]
// -----------------------------------------------------------------------------
`define T2T_ASCII_BUY        8'h42   // 'B'
`define T2T_ASCII_SELL       8'h53   // 'S'
`define T2T_SIDE_BID         1'b0    // 0 = bid (buy)
`define T2T_SIDE_ASK         1'b1    // 1 = ask (sell)

`define T2T_OP_W             2
`define T2T_OP_ADD           2'd0
`define T2T_OP_REDUCE        2'd1
`define T2T_OP_CORRUPT       2'd2

// -----------------------------------------------------------------------------
// 4.2 & 10.1 Trigger Rule IDs [N]
// -----------------------------------------------------------------------------
`define T2T_RULE_W           2
`define T2T_RULE_CROSS_BUY   2'd0
`define T2T_RULE_CROSS_SELL  2'd1
`define T2T_RULE_IMB_BUY     2'd2
`define T2T_RULE_IMB_SELL    2'd3

// -----------------------------------------------------------------------------
// 4.2 & 10.2 Pre-Trade Risk Reason Codes [N]
// Priority order: KILL(1) > TX_FAULT(8) > UNKNOWN(15) > QTY(2) > NOTIONAL(3)
//                 > COLLAR(4) > POS_SYM(5) > POS_GLOB(6) > RATE(7)
// -----------------------------------------------------------------------------
`define T2T_RSN_W            4
`define T2T_RSN_PASS         4'd0
`define T2T_RSN_KILL         4'd1
`define T2T_RSN_QTY          4'd2
`define T2T_RSN_NOTIONAL     4'd3
`define T2T_RSN_COLLAR       4'd4
`define T2T_RSN_POS_SYM      4'd5
`define T2T_RSN_POS_GLOB     4'd6
`define T2T_RSN_RATE         4'd7
`define T2T_RSN_TX_FAULT     4'd8
`define T2T_RSN_UNKNOWN      4'd15

// -----------------------------------------------------------------------------
// 5.2 Pipeline Bus Definitions & Slice Macros [N]
// -----------------------------------------------------------------------------

// MSG Bus (S3 Extract -> S4 SymFilter): 320 bits
`define T2T_MSG_W            320
`define T2T_MSG_IDX_LO       0
`define T2T_MSG_IDX_HI       31
`define T2T_MSG_TYPE_LO      32
`define T2T_MSG_TYPE_HI      39
`define T2T_MSG_LOCATE_LO    40
`define T2T_MSG_LOCATE_HI    55
`define T2T_MSG_REF_LO       56
`define T2T_MSG_REF_HI       119
`define T2T_MSG_NEWREF_LO    120
`define T2T_MSG_NEWREF_HI    183
`define T2T_MSG_SIDE_LO      184
`define T2T_MSG_SIDE_HI      191
`define T2T_MSG_SHARES_LO    192
`define T2T_MSG_SHARES_HI    223
`define T2T_MSG_PRICE_LO     224
`define T2T_MSG_PRICE_HI     255
`define T2T_MSG_STOCK_LO     256
`define T2T_MSG_STOCK_HI     319

// FA Bus (S4 SymFilter -> FA FIFO -> S5 OrdTable): 325 bits
`define T2T_FA_W             325
`define T2T_FA_MSG_LO        0
`define T2T_FA_MSG_HI        319
`define T2T_FA_SYM_LO        320
`define T2T_FA_SYM_HI        323
`define T2T_FA_HIT_BIT       324

// OP Bus (S5 OrdTable -> FB FIFO -> S6 Book): 105 bits
`define T2T_OP_BUS_W         105
`define T2T_OP_IDX_LO        0
`define T2T_OP_IDX_HI        31
`define T2T_OP_QTY_LO        32
`define T2T_OP_QTY_HI        63
`define T2T_OP_PRICE_LO      64
`define T2T_OP_PRICE_HI      95
`define T2T_OP_SYM_LO        96
`define T2T_OP_SYM_HI        99
`define T2T_OP_SIDE_BIT      100
`define T2T_OP_CODE_LO       101
`define T2T_OP_CODE_HI       102
`define T2T_OP_REMOVE_BIT    103
`define T2T_OP_LAST_BIT      104

// Order Table Entry Layout (Section 8.3): 134 bits per way
// {valid[1], ref[64], sym[4], side[1], price[32], shares[32]}
`define T2T_OT_ENTRY_W       134
`define T2T_OT_SHARES_LO     0
`define T2T_OT_SHARES_HI     31
`define T2T_OT_PRICE_LO      32
`define T2T_OT_PRICE_HI      63
`define T2T_OT_SIDE_BIT      64
`define T2T_OT_SYM_LO        65
`define T2T_OT_SYM_HI        68
`define T2T_OT_REF_LO        69
`define T2T_OT_REF_HI        132
`define T2T_OT_VALID_BIT     133
`define T2T_OT_SET_W         (`T2T_OT_ENTRY_W * `T2T_TABLE_WAYS)

// Book Level Entry Layout (Section 9.1): 80 bits per level
// {cnt[16], qty[32], px[32]}
`define T2T_BK_LVL_W         80
`define T2T_BK_LVL_PX_LO     0
`define T2T_BK_LVL_PX_HI     31
`define T2T_BK_LVL_QTY_LO    32
`define T2T_BK_LVL_QTY_HI    63
`define T2T_BK_LVL_CNT_LO    64
`define T2T_BK_LVL_CNT_HI    79

// Host Top-of-Book Snapshot per Symbol (Section 9.4 & 11.2): 224 bits per symbol
// [31:0]    bid_px
// [63:32]   bid_qty
// [95:64]   ask_px
// [127:96]  ask_qty
// [143:128] flags: {ask_lv[3:0], bid_lv[3:0], 2'b00, crossed, corrupt, ask_stale, bid_stale, ask_ok, bid_ok}
// [163:144] bid_hidden (20b)
// [183:164] ask_hidden (20b)
// [215:184] seq (32b)
// [223:216] reserved (8b)
`define T2T_TOB_SYM_W        224
`define T2T_TOB_BID_PX_LO    0
`define T2T_TOB_BID_PX_HI    31
`define T2T_TOB_BID_QTY_LO   32
`define T2T_TOB_BID_QTY_HI   63
`define T2T_TOB_ASK_PX_LO    64
`define T2T_TOB_ASK_PX_HI    95
`define T2T_TOB_ASK_QTY_LO   96
`define T2T_TOB_ASK_QTY_HI   127
`define T2T_TOB_FLAGS_LO     128
`define T2T_TOB_FLAGS_HI     143
`define T2T_TOB_BID_HID_LO   144
`define T2T_TOB_BID_HID_HI   163
`define T2T_TOB_ASK_HID_LO   164
`define T2T_TOB_ASK_HID_HI   183
`define T2T_TOB_SEQ_LO       184
`define T2T_TOB_SEQ_HI       215

// Trigger Per-Symbol Config Bus (Section 10.1): 120 bits per symbol
`define T2T_TCFG_SYM_W       120
`define T2T_TCFG_EN_BIT      0
`define T2T_TCFG_MASK_LO     1
`define T2T_TCFG_MASK_HI     4
`define T2T_TCFG_IMB_LO      5
`define T2T_TCFG_IMB_HI      7
`define T2T_TCFG_BUYLIM_LO   8
`define T2T_TCFG_BUYLIM_HI   39
`define T2T_TCFG_SELLLIM_LO  40
`define T2T_TCFG_SELLLIM_HI  71
`define T2T_TCFG_MAXSPR_LO   72
`define T2T_TCFG_MAXSPR_HI   103
`define T2T_TCFG_QTY_LO      104
`define T2T_TCFG_QTY_HI      119

// Risk Per-Symbol Config Bus (Section 10.2): 161 bits per symbol
`define T2T_RCFG_SYM_W       161
`define T2T_RCFG_VALID_BIT   0
`define T2T_RCFG_MAXQTY_LO   1
`define T2T_RCFG_MAXQTY_HI   16
`define T2T_RCFG_MAXNOT_LO   17
`define T2T_RCFG_MAXNOT_HI   64
`define T2T_RCFG_COLLAR_LO   65
`define T2T_RCFG_COLLAR_HI   96
`define T2T_RCFG_REFPX_LO    97
`define T2T_RCFG_REFPX_HI    128
`define T2T_RCFG_MAXPOS_LO   129
`define T2T_RCFG_MAXPOS_HI   160

// -----------------------------------------------------------------------------
// 6.2 Outbound OUCH-Style Enter Order Frame Constants (48 bytes) [N]
// -----------------------------------------------------------------------------
`define T2T_OUCH_TYPE_ENTER  8'h4F   // 'O'
`define T2T_OUCH_TIF_IOC     32'h0000_0000
`define T2T_OUCH_DISPLAY     8'h59   // 'Y'
`define T2T_OUCH_CAPACITY    8'h50   // 'P'
`define T2T_OUCH_ISO         8'h4E   // 'N'
`define T2T_OUCH_MIN_QTY     32'h0000_0000
`define T2T_OUCH_CROSS_TYPE  8'h4E   // 'N'
`define T2T_OUCH_CUST_TYPE   8'h4E   // 'N'
`define T2T_OUCH_APPEND_LEN  16'h0000
`define T2T_OUCH_TKEEP       64'h0000_FFFF_FFFF_FFFF

// -----------------------------------------------------------------------------
// 11.2 & 11.3 AXI-Lite Register Map & Counter IDs [N]
// -----------------------------------------------------------------------------
`define T2T_REG_ID_VAL       32'h7432_0001
`define T2T_REG_UNMAPPED_VAL 32'hDEAD_BEEF

`define T2T_ADDR_ID          12'h000
`define T2T_ADDR_CTRL        12'h004
`define T2T_ADDR_STATUS      12'h008
`define T2T_ADDR_CAPS        12'h00C
`define T2T_ADDR_BEST_BID0   12'h010
`define T2T_ADDR_BEST_ASK0   12'h018
`define T2T_ADDR_CNT_BASE    12'h100
`define T2T_ADDR_BOOK_BASE   12'h200
`define T2T_ADDR_SYM_BASE    12'h400
`define T2T_ADDR_RISKG_BASE  12'h800

`define T2T_NUM_COUNTERS     47
`define T2T_CNT_BANK_SIZE    64

`define T2T_CNT_RX_BEATS             0
`define T2T_CNT_RX_FRAMES            1
`define T2T_CNT_INGEST_OVERFLOW      2
`define T2T_CNT_RX_DROPPED_INIT      3
`define T2T_CNT_FRAME_ERR            4
`define T2T_CNT_KEEP_ERR             5
`define T2T_CNT_BLOCKS_TOTAL         6
`define T2T_CNT_N_A                  7
`define T2T_CNT_N_F                  8
`define T2T_CNT_N_E                  9
`define T2T_CNT_N_C                  10
`define T2T_CNT_N_X                  11
`define T2T_CNT_N_D                  12
`define T2T_CNT_N_U                  13
`define T2T_CNT_N_OTHER_SKIPPED      14
`define T2T_CNT_N_ZERO_LEN           15
`define T2T_CNT_N_BAD_LEN            16
`define T2T_CNT_N_BAD_SIDE           17
`define T2T_CNT_SYM_HIT              18
`define T2T_CNT_SYM_MISS             19
`define T2T_CNT_TBL_INS              20
`define T2T_CNT_TBL_REF_MISS         21
`define T2T_CNT_TBL_DUP_REF          22
`define T2T_CNT_TBL_SET_FULL         23
`define T2T_CNT_TBL_QTY_UNDERFLOW    24
`define T2T_CNT_TBL_SAME_SET_STALLS  25
`define T2T_CNT_BOOK_OPS             26
`define T2T_CNT_BOOK_SAME_KEY_BUB    27
`define T2T_CNT_BOOK_CORRUPT_EVENTS  28
`define T2T_CNT_BOOK_HIDDEN_ADDS     29
`define T2T_CNT_BOOK_EVICTIONS       30
`define T2T_CNT_TRIG_CAND            31
`define T2T_CNT_RISK_PASS            32
`define T2T_CNT_RISK_REJ_1           33
`define T2T_CNT_RISK_REJ_2           34
`define T2T_CNT_RISK_REJ_3           35
`define T2T_CNT_RISK_REJ_4           36
`define T2T_CNT_RISK_REJ_5           37
`define T2T_CNT_RISK_REJ_6           38
`define T2T_CNT_RISK_REJ_7           39
`define T2T_CNT_RISK_REJ_8           40
`define T2T_CNT_RISK_REJ_15          41
`define T2T_CNT_TX_FRAMES            42
`define T2T_CNT_TX_OVERFLOW          43
`define T2T_CNT_UPD_TOTAL            44
`define T2T_CNT_UPD_WITH_STALE       45
`define T2T_CNT_FATAL_OVERFLOW       46

`endif // T2T_DEFS_VH