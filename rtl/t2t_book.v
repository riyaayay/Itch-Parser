// =============================================================================
// File        : rtl/t2t_book.v
// Spec Section: 5.2 (UPD Signals), 5.3 (Depth 3), 9.1, 9.2, 9.3, 9.4 (Stage S6)
// Description : Top-N price-level order book engine with hidden order tracking,
//               forwarding, same-key hazard protection, and real-time UPD emission.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module t2t_book #(
    parameter BOOK_N    = `T2T_BOOK_N,      // Default 8 levels
    parameter N_SYMBOLS = `T2T_N_SYMBOLS    // Default 8 symbols
)(
    input  wire                   clk,
    input  wire                   rst,

    // Interface from FB FIFO (OP bus)
    input  wire                   i_op_valid,
    input  wire [104:0]           i_op,
    output reg                    o_fb_pop,

    // Session control (init sweep clears all ladders and counters in 1 cycle)
    input  wire                   i_init_busy,

    // Outbound UPD Interface (to S7 Trigger & Registers)
    output reg                    o_upd_valid,
    output reg  [3:0]             o_upd_sym,
    output reg  [31:0]            o_upd_idx,
    output reg                    o_upd_last,
    output reg  [31:0]            o_upd_bid_px,
    output reg  [31:0]            o_upd_bid_qty,
    output reg  [31:0]            o_upd_ask_px,
    output reg  [31:0]            o_upd_ask_qty,
    output reg  [3:0]             o_upd_bid_lv,
    output reg  [3:0]             o_upd_ask_lv,
    output reg                    o_upd_bid_stale,
    output reg                    o_upd_ask_stale,
    output reg                    o_upd_corrupt,
    output reg  [31:0]            o_upd_seq,

    // Top-of-book flat bus for AXI-Lite register readback (Section 9.4 / 11.2)
    output wire [8*176-1:0]       o_bk_tob_flat,

    // Diagnostic & Performance Counters
    output reg                    o_cnt_ops,
    output reg                    o_cnt_same_key_bubbles,
    output reg                    o_cnt_corrupt_events,
    output reg                    o_cnt_hidden_adds,
    output reg                    o_cnt_evictions,
    output reg                    o_cnt_upd_total,
    output reg                    o_cnt_upd_with_stale
);

    localparam NUM_KEYS = N_SYMBOLS * 2; // 16 keys (8 symbols x 2 sides)

    // -------------------------------------------------------------------------
    // Order Book Storage: 16 ladders (keys 0..15 = {sym[2:0], side})
    // -------------------------------------------------------------------------
    reg [31:0] lad_px     [0:NUM_KEYS-1][0:BOOK_N-1];
    reg [31:0] lad_qty    [0:NUM_KEYS-1][0:BOOK_N-1];
    reg [15:0] lad_cnt    [0:NUM_KEYS-1][0:BOOK_N-1];
    reg [3:0]  lad_lv     [0:NUM_KEYS-1];
    reg [19:0] lad_hidden [0:NUM_KEYS-1];

    // Per-symbol status
    reg        sym_corrupt [0:N_SYMBOLS-1];
    reg [31:0] sym_seq     [0:N_SYMBOLS-1];

    // Helpers to unpack OP bus fields
    wire [31:0] in_idx    = i_op[`T2T_OP_IDX_HI    : `T2T_OP_IDX_LO];
    wire [1:0]  in_code   = i_op[`T2T_OP_CODE_HI   : `T2T_OP_CODE_LO];
    wire [3:0]  in_sym    = i_op[`T2T_OP_SYM_HI    : `T2T_OP_SYM_LO];
    wire        in_side   = i_op[`T2T_OP_SIDE_BIT];
    wire        in_remove = i_op[`T2T_OP_REMOVE_BIT];
    wire        in_last   = i_op[`T2T_OP_LAST_BIT];
    wire [31:0] in_price  = i_op[`T2T_OP_PRICE_HI  : `T2T_OP_PRICE_LO];
    wire [31:0] in_qty    = i_op[`T2T_OP_QTY_HI    : `T2T_OP_QTY_LO];

    wire [3:0]  in_key    = {in_sym[2:0], in_side};

    // -------------------------------------------------------------------------
    // Pipeline Registers
    // -------------------------------------------------------------------------
    // Stage B1 Registers
    reg         b1_valid;
    reg [104:0] b1_op;
    reg [3:0]   b1_key;

    // Stage B2 Registers
    reg         b2_valid;
    reg [104:0] b2_op;
    reg [3:0]   b2_key;

    // Stage B2 Output / Forwarding Registers
    reg [31:0]  fwd_px     [0:BOOK_N-1];
    reg [31:0]  fwd_qty    [0:BOOK_N-1];
    reg [15:0]  fwd_cnt    [0:BOOK_N-1];
    reg [3:0]   fwd_lv;
    reg [19:0]  fwd_hidden;
    reg         fwd_corrupt;
    reg [3:0]   fwd_key;
    reg         fwd_valid;

    // -------------------------------------------------------------------------
    // Stage B0: Hazard Detection & Issue
    // -------------------------------------------------------------------------
    // Spec 9.4: If the op at B0 has the same {sym, side} as the op in B1,
    // hold it for one cycle (one bubble, counted in book_same_key_bubbles).
    wire same_key_hazard = b1_valid && (b1_key == in_key);
    wire can_issue_b0    = !i_init_busy && i_op_valid && !same_key_hazard;

    always @(posedge clk) begin
        if (rst || i_init_busy) begin
            b1_valid               <= 1'b0;
            b1_op                  <= 105'd0;
            b1_key                 <= 4'd0;
            o_fb_pop               <= 1'b0;
            o_cnt_same_key_bubbles <= 1'b0;
        end else begin
            o_cnt_same_key_bubbles <= 1'b0;
            o_fb_pop               <= 1'b0;

            if (can_issue_b0) begin
                b1_valid <= 1'b1;
                b1_op    <= i_op;
                b1_key   <= in_key;
                o_fb_pop <= 1'b1;
            end else begin
                b1_valid <= 1'b0;
                if (i_op_valid && same_key_hazard) begin
                    o_cnt_same_key_bubbles <= 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage B1: Ladder Read / Forwarding & Parallel Compare
    // -------------------------------------------------------------------------
    // Forwarding mux: B1 takes ladder from B2 output register when keys match
    wire fwd_match = fwd_valid && (fwd_key == b1_key);

    wire [3:0]  cur_lv     = fwd_match ? fwd_lv     : lad_lv[b1_key];
    wire [19:0] cur_hidden = fwd_match ? fwd_hidden : lad_hidden[b1_key];
    wire [3:0]  b1_sym     = b1_op[`T2T_OP_SYM_HI : `T2T_OP_SYM_LO];
    wire        cur_corrupt= fwd_match ? fwd_corrupt: sym_corrupt[b1_sym[2:0]];

    wire [31:0] cur_px  [0:BOOK_N-1];
    wire [31:0] cur_qty [0:BOOK_N-1];
    wire [15:0] cur_cnt [0:BOOK_N-1];

    genvar l;
    generate
        for (l = 0; l < BOOK_N; l = l + 1) begin : gen_cur_ladder
            assign cur_px[l]  = fwd_match ? fwd_px[l]  : lad_px[b1_key][l];
            assign cur_qty[l] = fwd_match ? fwd_qty[l] : lad_qty[b1_key][l];
            assign cur_cnt[l] = fwd_match ? fwd_cnt[l] : lad_cnt[b1_key][l];
        end
    endgenerate

    wire [1:0]  b1_code   = b1_op[`T2T_OP_CODE_HI   : `T2T_OP_CODE_LO];
    wire        b1_side   = b1_op[`T2T_OP_SIDE_BIT];
    wire        b1_remove = b1_op[`T2T_OP_REMOVE_BIT];
    wire [31:0] b1_price  = b1_op[`T2T_OP_PRICE_HI  : `T2T_OP_PRICE_LO];
    wire [31:0] b1_qty    = b1_op[`T2T_OP_QTY_HI    : `T2T_OP_QTY_LO];

    // Better price function
    function is_better(input [31:0] p1, input [31:0] p2, input s);
        begin
            is_better = (s == `T2T_SIDE_BID) ? (p1 > p2) : (p1 < p2);
        end
    endfunction

    // Parallel level compares
    reg [BOOK_N-1:0] eq_vec;
    reg [BOOK_N-1:0] better_vec;
    integer j;
    always @(*) begin
        for (j = 0; j < BOOK_N; j = j + 1) begin
            if (j < cur_lv) begin
                eq_vec[j]     = (cur_px[j] == b1_price);
                better_vec[j] = is_better(b1_price, cur_px[j], b1_side);
            end else begin
                eq_vec[j]     = 1'b0;
                better_vec[j] = 1'b0;
            end
        end
    end

    wire has_match = |eq_vec;

    reg [2:0] match_pos;
    integer p;
    always @(*) begin
        match_pos = 3'd0;
        for (p = BOOK_N - 1; p >= 0; p = p - 1) begin
            if (eq_vec[p]) match_pos = p[2:0];
        end
    end

    // First position where new price is better (lowest index)
    reg [3:0] insert_pos;
    integer q;
    always @(*) begin
        insert_pos = cur_lv;
        for (q = BOOK_N - 1; q >= 0; q = q - 1) begin
            if (better_vec[q]) insert_pos = q[3:0];
        end
    end

    wire [31:0] worst_px          = (cur_lv > 0) ? cur_px[cur_lv - 1] : 32'd0;
    wire        better_than_worst = (cur_lv > 0) && is_better(b1_price, worst_px, b1_side);
    wire        worse_than_worst  = (cur_lv > 0) && is_better(worst_px, b1_price, b1_side);

    // Operation classification
    localparam [3:0]
        ACT_NOP               = 4'd0,
        ACT_CORRUPT           = 4'd1,
        ACT_ADD_MERGE         = 4'd2,
        ACT_ADD_INSERT_NOEVICT= 4'd3,
        ACT_ADD_INSERT_EVICT  = 4'd4,
        ACT_ADD_HIDDEN        = 4'd5,
        ACT_RED_UPDATE        = 4'd6,
        ACT_RED_DELETE        = 4'd7,
        ACT_RED_HIDDEN        = 4'd8;

    reg [3:0] b1_act;
    always @(*) begin
        b1_act = ACT_NOP;
        if (b1_valid) begin
            if (b1_code == `T2T_OP_CORRUPT) begin
                b1_act = ACT_CORRUPT;
            end else if (b1_code == `T2T_OP_ADD) begin
                if (has_match) begin
                    b1_act = ACT_ADD_MERGE;
                end else if (cur_hidden == 20'd0 && cur_lv < BOOK_N) begin
                    b1_act = ACT_ADD_INSERT_NOEVICT;
                end else if (cur_lv > 0 && better_than_worst) begin
                    b1_act = (cur_lv == BOOK_N) ? ACT_ADD_INSERT_EVICT : ACT_ADD_INSERT_NOEVICT;
                end else begin
                    b1_act = ACT_ADD_HIDDEN;
                end
            end else if (b1_code == `T2T_OP_REDUCE) begin
                if (has_match) begin
                    if (cur_qty[match_pos] < b1_qty) begin
                        b1_act = ACT_CORRUPT;
                    end else if (b1_remove && (cur_cnt[match_pos] == 16'd0 ||
                                (cur_cnt[match_pos] == 16'd1 && cur_qty[match_pos] != b1_qty) ||
                                (cur_cnt[match_pos] > 16'd1 && cur_qty[match_pos] == b1_qty))) begin
                        b1_act = ACT_CORRUPT;
                    end else if (b1_remove && (cur_qty[match_pos] == b1_qty) && (cur_cnt[match_pos] == 16'd1)) begin
                        b1_act = ACT_RED_DELETE;
                    end else begin
                        b1_act = ACT_RED_UPDATE;
                    end
                end else if (cur_hidden > 20'd0 && (cur_lv == 0 || worse_than_worst)) begin
                    b1_act = b1_remove ? ACT_RED_HIDDEN : ACT_NOP;
                end else begin
                    b1_act = ACT_CORRUPT;
                end
            end
        end
    end

    // Stage B1 -> B2 Pipeline registers
    reg [3:0]  b2_act;
    reg [2:0]  b2_match_pos;
    reg [3:0]  b2_insert_pos;
    reg [3:0]  b2_lv;
    reg [19:0] b2_hidden;
    reg        b2_corrupt;
    reg [31:0] b2_px  [0:BOOK_N-1];
    reg [31:0] b2_qty [0:BOOK_N-1];
    reg [15:0] b2_cnt [0:BOOK_N-1];

    always @(posedge clk) begin
        if (rst || i_init_busy) begin
            b2_valid      <= 1'b0;
            b2_op         <= 105'd0;
            b2_key        <= 4'd0;
            b2_act        <= ACT_NOP;
            b2_match_pos  <= 3'd0;
            b2_insert_pos <= 4'd0;
            b2_lv         <= 4'd0;
            b2_hidden     <= 20'd0;
            b2_corrupt    <= 1'b0;
            for (j = 0; j < BOOK_N; j = j + 1) begin
                b2_px[j]  <= 32'd0;
                b2_qty[j] <= 32'd0;
                b2_cnt[j] <= 16'd0;
            end
        end else begin
            b2_valid      <= b1_valid;
            b2_op         <= b1_op;
            b2_key        <= b1_key;
            b2_act        <= b1_act;
            b2_match_pos  <= match_pos;
            b2_insert_pos <= insert_pos;
            b2_lv         <= cur_lv;
            b2_hidden     <= cur_hidden;
            b2_corrupt    <= cur_corrupt;
            for (j = 0; j < BOOK_N; j = j + 1) begin
                b2_px[j]  <= cur_px[j];
                b2_qty[j] <= cur_qty[j];
                b2_cnt[j] <= cur_cnt[j];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage B2: Execution, Write-Back, Forwarding & UPD Emission
    // -------------------------------------------------------------------------
    wire [1:0]  b2_code   = b2_op[`T2T_OP_CODE_HI   : `T2T_OP_CODE_LO];
    wire [3:0]  b2_sym    = b2_op[`T2T_OP_SYM_HI    : `T2T_OP_SYM_LO];
    wire        b2_side   = b2_op[`T2T_OP_SIDE_BIT];
    wire        b2_remove = b2_op[`T2T_OP_REMOVE_BIT];
    wire        b2_last   = b2_op[`T2T_OP_LAST_BIT];
    wire [31:0] b2_price  = b2_op[`T2T_OP_PRICE_HI  : `T2T_OP_PRICE_LO];
    wire [31:0] b2_qty_in = b2_op[`T2T_OP_QTY_HI    : `T2T_OP_QTY_LO];
    wire [31:0] b2_idx    = b2_op[`T2T_OP_IDX_HI    : `T2T_OP_IDX_LO];

    reg [31:0] nxt_px     [0:BOOK_N-1];
    reg [31:0] nxt_qty    [0:BOOK_N-1];
    reg [15:0] nxt_cnt    [0:BOOK_N-1];
    reg [3:0]  nxt_lv;
    reg [19:0] nxt_hidden;
    reg        nxt_corrupt;
    reg        cnt_evict_pulse;
    reg        cnt_hidden_add_pulse;

    integer k;
    always @(*) begin
        for (k = 0; k < BOOK_N; k = k + 1) begin
            nxt_px[k]  = b2_px[k];
            nxt_qty[k] = b2_qty[k];
            nxt_cnt[k] = b2_cnt[k];
        end
        nxt_lv               = b2_lv;
        nxt_hidden           = b2_hidden;
        nxt_corrupt          = b2_corrupt;
        cnt_evict_pulse      = 1'b0;
        cnt_hidden_add_pulse = 1'b0;

        case (b2_act)
            ACT_CORRUPT: begin
                nxt_corrupt = 1'b1;
            end

            ACT_ADD_MERGE: begin
                nxt_qty[b2_match_pos] = b2_qty[b2_match_pos] + b2_qty_in;
                if (b2_cnt[b2_match_pos] == 16'hFFFF) begin
                    nxt_corrupt = 1'b1;
                end else begin
                    nxt_cnt[b2_match_pos] = b2_cnt[b2_match_pos] + 16'd1;
                end
            end

            ACT_ADD_INSERT_NOEVICT: begin
                // Shift down from insert_pos
                for (k = BOOK_N - 1; k >= 0; k = k - 1) begin
                    if (k > b2_insert_pos) begin
                        nxt_px[k]  = b2_px[k - 1];
                        nxt_qty[k] = b2_qty[k - 1];
                        nxt_cnt[k] = b2_cnt[k - 1];
                    end
                end
                nxt_px[b2_insert_pos]  = b2_price;
                nxt_qty[b2_insert_pos] = b2_qty_in;
                nxt_cnt[b2_insert_pos] = 16'd1;
                nxt_lv = b2_lv + 4'd1;
            end

            ACT_ADD_INSERT_EVICT: begin
                // Worst level evicted to hidden
                nxt_hidden = b2_hidden + b2_cnt[BOOK_N - 1];
                cnt_evict_pulse = 1'b1;
                for (k = BOOK_N - 1; k >= 0; k = k - 1) begin
                    if (k > b2_insert_pos) begin
                        nxt_px[k]  = b2_px[k - 1];
                        nxt_qty[k] = b2_qty[k - 1];
                        nxt_cnt[k] = b2_cnt[k - 1];
                    end
                end
                nxt_px[b2_insert_pos]  = b2_price;
                nxt_qty[b2_insert_pos] = b2_qty_in;
                nxt_cnt[b2_insert_pos] = 16'd1;
                // lv stays at BOOK_N
            end

            ACT_ADD_HIDDEN: begin
                nxt_hidden = b2_hidden + 20'd1;
                cnt_hidden_add_pulse = 1'b1;
            end

            ACT_RED_UPDATE: begin
                nxt_qty[b2_match_pos] = b2_qty[b2_match_pos] - b2_qty_in;
                if (b2_remove) begin
                    nxt_cnt[b2_match_pos] = b2_cnt[b2_match_pos] - 16'd1;
                end
            end

            ACT_RED_DELETE: begin
                // Shift up to remove level at match_pos
                for (k = 0; k < BOOK_N; k = k + 1) begin
                    if (k >= b2_match_pos && k < BOOK_N - 1) begin
                        nxt_px[k]  = b2_px[k + 1];
                        nxt_qty[k] = b2_qty[k + 1];
                        nxt_cnt[k] = b2_cnt[k + 1];
                    end
                end
                nxt_px[BOOK_N - 1]  = 32'd0;
                nxt_qty[BOOK_N - 1] = 32'd0;
                nxt_cnt[BOOK_N - 1] = 16'd0;
                nxt_lv = b2_lv - 4'd1;
            end

            ACT_RED_HIDDEN: begin
                if (b2_hidden > 20'd0) begin
                    nxt_hidden = b2_hidden - 20'd1;
                end
            end

            default: begin
                // NOP
            end
        endcase
    end

    // Register storage write-back, UPD emission & counters
    integer m, n;
    always @(posedge clk) begin
        if (rst || i_init_busy) begin
            // 1-cycle reset of all ladders, hidden counts, corrupt, seq (Spec Section 9.4)
            for (m = 0; m < NUM_KEYS; m = m + 1) begin
                lad_lv[m]     <= 4'd0;
                lad_hidden[m] <= 20'd0;
                for (n = 0; n < BOOK_N; n = n + 1) begin
                    lad_px[m][n]  <= 32'd0;
                    lad_qty[m][n] <= 32'd0;
                    lad_cnt[m][n] <= 16'd0;
                end
            end
            for (m = 0; m < N_SYMBOLS; m = m + 1) begin
                sym_corrupt[m] <= 1'b0;
                sym_seq[m]     <= 32'd0;
            end

            fwd_valid              <= 1'b0;
            fwd_key                <= 4'd0;
            fwd_lv                 <= 4'd0;
            fwd_hidden             <= 20'd0;
            fwd_corrupt            <= 1'b0;
            for (n = 0; n < BOOK_N; n = n + 1) begin
                fwd_px[n]  <= 32'd0;
                fwd_qty[n] <= 32'd0;
                fwd_cnt[n] <= 16'd0;
            end

            o_upd_valid            <= 1'b0;
            o_upd_sym              <= 4'd0;
            o_upd_idx              <= 32'd0;
            o_upd_last             <= 1'b0;
            o_upd_bid_px           <= 32'd0;
            o_upd_bid_qty          <= 32'd0;
            o_upd_ask_px           <= 32'd0;
            o_upd_ask_qty          <= 32'd0;
            o_upd_bid_lv           <= 4'd0;
            o_upd_ask_lv           <= 4'd0;
            o_upd_bid_stale        <= 1'b0;
            o_upd_ask_stale        <= 1'b0;
            o_upd_corrupt          <= 1'b0;
            o_upd_seq              <= 32'd0;

            o_cnt_ops              <= 1'b0;
            o_cnt_corrupt_events   <= 1'b0;
            o_cnt_hidden_adds      <= 1'b0;
            o_cnt_evictions        <= 1'b0;
            o_cnt_upd_total        <= 1'b0;
            o_cnt_upd_with_stale   <= 1'b0;
        end else begin
            fwd_valid              <= 1'b0;
            o_upd_valid            <= 1'b0;
            o_cnt_ops              <= 1'b0;
            o_cnt_corrupt_events   <= 1'b0;
            o_cnt_hidden_adds      <= 1'b0;
            o_cnt_evictions        <= 1'b0;
            o_cnt_upd_total        <= 1'b0;
            o_cnt_upd_with_stale   <= 1'b0;

            if (b2_valid) begin
                o_cnt_ops <= 1'b1;

                // Write-back to ladder storage
                lad_lv[b2_key]     <= nxt_lv;
                lad_hidden[b2_key] <= nxt_hidden;
                for (n = 0; n < BOOK_N; n = n + 1) begin
                    lad_px[b2_key][n]  <= nxt_px[n];
                    lad_qty[b2_key][n] <= nxt_qty[n];
                    lad_cnt[b2_key][n] <= nxt_cnt[n];
                end

                // Per-symbol corrupt & seq
                if (nxt_corrupt && !sym_corrupt[b2_sym[2:0]]) begin
                    o_cnt_corrupt_events <= 1'b1;
                end
                sym_corrupt[b2_sym[2:0]] <= nxt_corrupt;
                sym_seq[b2_sym[2:0]]     <= sym_seq[b2_sym[2:0]] + 32'd1;

                // Forwarding register update
                fwd_valid   <= 1'b1;
                fwd_key     <= b2_key;
                fwd_lv      <= nxt_lv;
                fwd_hidden  <= nxt_hidden;
                fwd_corrupt <= nxt_corrupt;
                for (n = 0; n < BOOK_N; n = n + 1) begin
                    fwd_px[n]  <= nxt_px[n];
                    fwd_qty[n] <= nxt_qty[n];
                    fwd_cnt[n] <= nxt_cnt[n];
                end

                // Diagnostic counters
                if (cnt_evict_pulse)      o_cnt_evictions   <= 1'b1;
                if (cnt_hidden_add_pulse) o_cnt_hidden_adds <= 1'b1;

                // -------------------------------------------------------------
                // Outbound UPD emission (Top-of-Book for both sides)
                // -------------------------------------------------------------
                o_upd_valid <= 1'b1;
                o_upd_sym   <= b2_sym;
                o_upd_idx   <= b2_idx;
                o_upd_last  <= b2_last;
                o_upd_seq   <= sym_seq[b2_sym[2:0]];
                o_upd_corrupt <= nxt_corrupt;
                o_cnt_upd_total <= 1'b1;

                // Bid side top of book
                if (b2_side == `T2T_SIDE_BID) begin
                    o_upd_bid_px    <= (nxt_lv > 0) ? nxt_px[0] : 32'd0;
                    o_upd_bid_qty   <= (nxt_lv > 0) ? nxt_qty[0] : 32'd0;
                    o_upd_bid_lv    <= nxt_lv;
                    o_upd_bid_stale <= (nxt_lv == 0 && nxt_hidden != 0);

                    // Ask side read directly from storage
                    o_upd_ask_px    <= (lad_lv[{b2_sym[2:0], `T2T_SIDE_ASK}] > 0) ? lad_px[{b2_sym[2:0], `T2T_SIDE_ASK}][0] : 32'd0;
                    o_upd_ask_qty   <= (lad_lv[{b2_sym[2:0], `T2T_SIDE_ASK}] > 0) ? lad_qty[{b2_sym[2:0], `T2T_SIDE_ASK}][0] : 32'd0;
                    o_upd_ask_lv    <= lad_lv[{b2_sym[2:0], `T2T_SIDE_ASK}];
                    o_upd_ask_stale <= (lad_lv[{b2_sym[2:0], `T2T_SIDE_ASK}] == 0 && lad_hidden[{b2_sym[2:0], `T2T_SIDE_ASK}] != 0);

                    if ((nxt_lv == 0 && nxt_hidden != 0) || (lad_lv[{b2_sym[2:0], `T2T_SIDE_ASK}] == 0 && lad_hidden[{b2_sym[2:0], `T2T_SIDE_ASK}] != 0)) begin
                        o_cnt_upd_with_stale <= 1'b1;
                    end
                end else begin
                    // Ask side updated
                    o_upd_ask_px    <= (nxt_lv > 0) ? nxt_px[0] : 32'd0;
                    o_upd_ask_qty   <= (nxt_lv > 0) ? nxt_qty[0] : 32'd0;
                    o_upd_ask_lv    <= nxt_lv;
                    o_upd_ask_stale <= (nxt_lv == 0 && nxt_hidden != 0);

                    // Bid side read directly from storage
                    o_upd_bid_px    <= (lad_lv[{b2_sym[2:0], `T2T_SIDE_BID}] > 0) ? lad_px[{b2_sym[2:0], `T2T_SIDE_BID}][0] : 32'd0;
                    o_upd_bid_qty   <= (lad_lv[{b2_sym[2:0], `T2T_SIDE_BID}] > 0) ? lad_qty[{b2_sym[2:0], `T2T_SIDE_BID}][0] : 32'd0;
                    o_upd_bid_lv    <= lad_lv[{b2_sym[2:0], `T2T_SIDE_BID}];
                    o_upd_bid_stale <= (lad_lv[{b2_sym[2:0], `T2T_SIDE_BID}] == 0 && lad_hidden[{b2_sym[2:0], `T2T_SIDE_BID}] != 0);

                    if ((nxt_lv == 0 && nxt_hidden != 0) || (lad_lv[{b2_sym[2:0], `T2T_SIDE_BID}] == 0 && lad_hidden[{b2_sym[2:0], `T2T_SIDE_BID}] != 0)) begin
                        o_cnt_upd_with_stale <= 1'b1;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Top-of-Book Flat Output (Section 9.4 / 11.2)
    // -------------------------------------------------------------------------
    // Flat vector per symbol (176 bits each x 8 symbols):
    // {seq[31:0], crossed[1], corrupt[1], ask_stale[1], bid_stale[1], ask_hid[20], bid_hid[20],
    //  ask_lv[4], bid_lv[4], ask_qty[32], ask_px[32], bid_qty[32], bid_px[32]}
    genvar s;
    generate
        for (s = 0; s < N_SYMBOLS; s = s + 1) begin : gen_tob_flat
            wire [31:0] b_px   = (lad_lv[{s[2:0], `T2T_SIDE_BID}] > 0) ? lad_px[{s[2:0], `T2T_SIDE_BID}][0] : 32'd0;
            wire [31:0] b_qty  = (lad_lv[{s[2:0], `T2T_SIDE_BID}] > 0) ? lad_qty[{s[2:0], `T2T_SIDE_BID}][0] : 32'd0;
            wire [3:0]  b_lv   = lad_lv[{s[2:0], `T2T_SIDE_BID}];
            wire [19:0] b_hid  = lad_hidden[{s[2:0], `T2T_SIDE_BID}];
            wire        b_stl  = (b_lv == 0 && b_hid != 0);

            wire [31:0] a_px   = (lad_lv[{s[2:0], `T2T_SIDE_ASK}] > 0) ? lad_px[{s[2:0], `T2T_SIDE_ASK}][0] : 32'd0;
            wire [31:0] a_qty  = (lad_lv[{s[2:0], `T2T_SIDE_ASK}] > 0) ? lad_qty[{s[2:0], `T2T_SIDE_ASK}][0] : 32'd0;
            wire [3:0]  a_lv   = lad_lv[{s[2:0], `T2T_SIDE_ASK}];
            wire [19:0] a_hid  = lad_hidden[{s[2:0], `T2T_SIDE_ASK}];
            wire        a_stl  = (a_lv == 0 && a_hid != 0);

            wire        is_crossed = (b_lv > 0 && a_lv > 0 && (b_px >= a_px));
            wire        corr       = sym_corrupt[s];
            wire [31:0] sq         = sym_seq[s];

            assign o_bk_tob_flat[176*s +: 176] = {
                sq, is_crossed, corr, a_stl, b_stl, a_hid, b_hid, a_lv, b_lv,
                a_qty, a_px, b_qty, b_px
            };
        end
    endgenerate

endmodule
