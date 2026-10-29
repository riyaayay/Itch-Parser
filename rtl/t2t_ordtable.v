// =============================================================================
// File        : rtl/t2t_ordtable.v
// Spec Section: 5.2 (OP Bus), 5.3 (Depth 4), 8.3 (Stage S5)
// Description : 4-way set-associative order table mapping 64-bit order references
//               to symbol, side, price, and resting quantity. Depth 4.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module t2t_ordtable #(
    parameter TABLE_AW   = `T2T_TABLE_AW,    // 9 for Artix-7 (512 sets)
    parameter TABLE_WAYS = `T2T_TABLE_WAYS   // 4 ways per set
)(
    input  wire                   clk,
    input  wire                   rst,

    // Interface from FA FIFO (FA bus: {hit[0], sym[3:0], MSG[319:0]})
    input  wire                   i_valid,
    input  wire [324:0]           i_fa,
    output wire                   o_pop,

    // Flow control from FB FIFO
    input  wire                   i_fb_afull,

    // Session control (init sweep writes all-invalid words)
    input  wire                   i_init_busy,

    // Interface to FB FIFO (OP bus)
    output reg                    o_op_valid,
    output reg  [104:0]           o_op,

    // Diagnostic & Performance Counters
    output reg                    o_cnt_ins,
    output reg                    o_cnt_ref_miss,
    output reg                    o_cnt_dup_ref,
    output reg                    o_cnt_set_full,
    output reg                    o_cnt_qty_underflow,
    output reg                    o_cnt_same_set_stall
);

    localparam NUM_SETS = (1 << TABLE_AW);
    localparam ENTRY_W  = 134; // {valid[1], ref[64], sym[4], side[1], price[32], shares[32]}

    // -------------------------------------------------------------------------
    // Dual-Port RAM storage: 4 ways per set
    // -------------------------------------------------------------------------
    (* ram_style = "block" *) reg [ENTRY_W-1:0] ram_way0 [0:NUM_SETS-1];
    (* ram_style = "block" *) reg [ENTRY_W-1:0] ram_way1 [0:NUM_SETS-1];
    (* ram_style = "block" *) reg [ENTRY_W-1:0] ram_way2 [0:NUM_SETS-1];
    (* ram_style = "block" *) reg [ENTRY_W-1:0] ram_way3 [0:NUM_SETS-1];

    // Read ports (Port A)
    reg [TABLE_AW-1:0] rd_addr;
    reg [ENTRY_W-1:0]  ram_out0;
    reg [ENTRY_W-1:0]  ram_out1;
    reg [ENTRY_W-1:0]  ram_out2;
    reg [ENTRY_W-1:0]  ram_out3;

    always @(posedge clk) begin
        ram_out0 <= ram_way0[rd_addr];
        ram_out1 <= ram_way1[rd_addr];
        ram_out2 <= ram_way2[rd_addr];
        ram_out3 <= ram_way3[rd_addr];
    end

    // Write ports (Port B)
    reg [TABLE_AW-1:0] wr_addr;
    reg [ENTRY_W-1:0]  wr_data;
    reg [3:0]          wr_en;

    always @(posedge clk) begin
        if (wr_en[0]) ram_way0[wr_addr] <= wr_data;
        if (wr_en[1]) ram_way1[wr_addr] <= wr_data;
        if (wr_en[2]) ram_way2[wr_addr] <= wr_data;
        if (wr_en[3]) ram_way3[wr_addr] <= wr_data;
    end

    // -------------------------------------------------------------------------
    // Init sweep logic
    // -------------------------------------------------------------------------
    reg [TABLE_AW-1:0] sweep_cnt;
    always @(posedge clk) begin
        if (rst) begin
            sweep_cnt <= {TABLE_AW{1'b0}};
        end else if (i_init_busy) begin
            sweep_cnt <= sweep_cnt + 1'b1;
        end else begin
            sweep_cnt <= {TABLE_AW{1'b0}};
        end
    end

    // Unpack candidate message from FA
    wire         cand_fa_hit  = i_fa[`T2T_FA_HIT_BIT];
    wire [3:0]   cand_fa_sym  = i_fa[`T2T_FA_SYM_HI : `T2T_FA_SYM_LO];
    wire [319:0] cand_msg     = i_fa[`T2T_FA_MSG_HI : `T2T_FA_MSG_LO];
    wire [31:0]  cand_idx     = cand_msg[`T2T_MSG_IDX_HI    : `T2T_MSG_IDX_LO];
    wire [7:0]   cand_type    = cand_msg[`T2T_MSG_TYPE_HI   : `T2T_MSG_TYPE_LO];
    wire [63:0]  cand_ref     = cand_msg[`T2T_MSG_REF_HI    : `T2T_MSG_REF_LO];
    wire [63:0]  cand_newref  = cand_msg[`T2T_MSG_NEWREF_HI : `T2T_MSG_NEWREF_LO];
    wire [7:0]   cand_side_b  = cand_msg[`T2T_MSG_SIDE_HI   : `T2T_MSG_SIDE_LO];
    wire [31:0]  cand_shares  = cand_msg[`T2T_MSG_SHARES_HI : `T2T_MSG_SHARES_LO];
    wire [31:0]  cand_price   = cand_msg[`T2T_MSG_PRICE_HI  : `T2T_MSG_PRICE_LO];

    // Replace (U) multi-step state machine
    reg        u_pending;
    reg [3:0]  u_saved_sym;
    reg        u_saved_side;
    reg [31:0] u_saved_idx;
    reg [63:0] u_newref;
    reg [31:0] u_newshares;
    reg [31:0] u_newprice;

    // Determine candidate for Stage 0 Issue
    wire is_replace_subop2 = u_pending;

    wire [7:0]  issue_type   = is_replace_subop2 ? `T2T_TYPE_A : cand_type;
    wire [63:0] issue_ref    = is_replace_subop2 ? u_newref    : cand_ref;
    wire [31:0] issue_idx    = is_replace_subop2 ? u_saved_idx : cand_idx;
    wire [3:0]  issue_sym    = is_replace_subop2 ? u_saved_sym : cand_fa_sym;
    wire        issue_side   = is_replace_subop2 ? u_saved_side: ((cand_side_b == `T2T_ASCII_SELL) ? `T2T_SIDE_ASK : `T2T_SIDE_BID);
    wire        issue_side_ok= is_replace_subop2 ? 1'b1 : ((cand_side_b == `T2T_ASCII_BUY) || (cand_side_b == `T2T_ASCII_SELL));
    wire [31:0] issue_shares = is_replace_subop2 ? u_newshares : cand_shares;
    wire [31:0] issue_price  = is_replace_subop2 ? u_newprice  : cand_price;
    wire [63:0] issue_newref = is_replace_subop2 ? 64'd0       : cand_newref;
    wire        issue_subop2 = is_replace_subop2;

    wire [TABLE_AW-1:0] issue_set = issue_ref[TABLE_AW-1:0];

    // -------------------------------------------------------------------------
    // Pipeline Registers
    // -------------------------------------------------------------------------
    // Stage 1 Registers (Memory Read cycle)
    reg                  stg1_valid;
    reg [TABLE_AW-1:0]   stg1_set;
    reg [7:0]            stg1_type;
    reg [63:0]           stg1_ref;
    reg [31:0]           stg1_idx;
    reg [3:0]            stg1_sym;
    reg                  stg1_side;
    reg                  stg1_side_ok;
    reg [31:0]           stg1_shares;
    reg [31:0]           stg1_price;
    reg [63:0]           stg1_newref;
    reg                  stg1_subop2;

    // Stage 2 Registers (Way Compare & Match)
    reg                  stg2_valid;
    reg [TABLE_AW-1:0]   stg2_set;
    reg [7:0]            stg2_type;
    reg [63:0]           stg2_ref;
    reg [31:0]           stg2_idx;
    reg [3:0]            stg2_sym;
    reg                  stg2_side;
    reg                  stg2_side_ok;
    reg [31:0]           stg2_shares;
    reg [31:0]           stg2_price;
    reg [63:0]           stg2_newref;
    reg                  stg2_subop2;
    reg [ENTRY_W-1:0]    stg2_out0;
    reg [ENTRY_W-1:0]    stg2_out1;
    reg [ENTRY_W-1:0]    stg2_out2;
    reg [ENTRY_W-1:0]    stg2_out3;

    // Stage 3 Registers (Write-back tracking)
    reg                  stg3_valid;
    reg [TABLE_AW-1:0]   stg3_set;

    // Same-set hazard detection across inflight stages 1, 2, 3
    wire same_set_hazard = (stg1_valid && (stg1_set == issue_set)) ||
                           (stg2_valid && (stg2_set == issue_set)) ||
                           (stg3_valid && (stg3_set == issue_set));

    // Replace (U) atomicity: while a Replace is inflight, do not issue next message from FA FIFO
    wire replace_inflight = (stg1_valid && (stg1_type == `T2T_TYPE_U)) ||
                            (stg2_valid && (stg2_type == `T2T_TYPE_U)) ||
                            u_pending;

    // Can issue new op from Stage 0 into Stage 1?
    wire can_issue = !i_init_busy && !i_fb_afull && !same_set_hazard &&
                     (is_replace_subop2 || (i_valid && !replace_inflight));

    // Combinational pop to FA FIFO
    assign o_pop = can_issue && !is_replace_subop2;

    // Stage 0: Read Address Generation
    always @(*) begin
        if (i_init_busy) begin
            rd_addr = sweep_cnt;
        end else if (can_issue) begin
            rd_addr = issue_set;
        end else begin
            rd_addr = issue_set;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 1 Pipeline Register Update
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst || i_init_busy) begin
            stg1_valid   <= 1'b0;
            stg1_set     <= {TABLE_AW{1'b0}};
            stg1_type    <= 8'd0;
            stg1_ref     <= 64'd0;
            stg1_idx     <= 32'd0;
            stg1_sym     <= 4'd0;
            stg1_side    <= 1'b0;
            stg1_side_ok <= 1'b0;
            stg1_shares  <= 32'd0;
            stg1_price   <= 32'd0;
            stg1_newref  <= 64'd0;
            stg1_subop2  <= 1'b0;
            o_cnt_same_set_stall <= 1'b0;
        end else begin
            o_cnt_same_set_stall <= 1'b0;

            if (can_issue) begin
                stg1_valid   <= 1'b1;
                stg1_set     <= issue_set;
                stg1_type    <= issue_type;
                stg1_ref     <= issue_ref;
                stg1_idx     <= issue_idx;
                stg1_sym     <= issue_sym;
                stg1_side    <= issue_side;
                stg1_side_ok <= issue_side_ok;
                stg1_shares  <= issue_shares;
                stg1_price   <= issue_price;
                stg1_newref  <= issue_newref;
                stg1_subop2  <= issue_subop2;
            end else begin
                stg1_valid <= 1'b0;
                if ((is_replace_subop2 || (i_valid && !replace_inflight)) && same_set_hazard && !i_fb_afull) begin
                    o_cnt_same_set_stall <= 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2 Pipeline Register Update
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst || i_init_busy) begin
            stg2_valid   <= 1'b0;
            stg2_set     <= {TABLE_AW{1'b0}};
            stg2_type    <= 8'd0;
            stg2_ref     <= 64'd0;
            stg2_idx     <= 32'd0;
            stg2_sym     <= 4'd0;
            stg2_side    <= 1'b0;
            stg2_side_ok <= 1'b0;
            stg2_shares  <= 32'd0;
            stg2_price   <= 32'd0;
            stg2_newref  <= 64'd0;
            stg2_subop2  <= 1'b0;
            stg2_out0    <= {ENTRY_W{1'b0}};
            stg2_out1    <= {ENTRY_W{1'b0}};
            stg2_out2    <= {ENTRY_W{1'b0}};
            stg2_out3    <= {ENTRY_W{1'b0}};
        end else begin
            stg2_valid   <= stg1_valid;
            stg2_set     <= stg1_set;
            stg2_type    <= stg1_type;
            stg2_ref     <= stg1_ref;
            stg2_idx     <= stg1_idx;
            stg2_sym     <= stg1_sym;
            stg2_side    <= stg1_side;
            stg2_side_ok <= stg1_side_ok;
            stg2_shares  <= stg1_shares;
            stg2_price   <= stg1_price;
            stg2_newref  <= stg1_newref;
            stg2_subop2  <= stg1_subop2;
            stg2_out0    <= ram_out0;
            stg2_out1    <= ram_out1;
            stg2_out2    <= ram_out2;
            stg2_out3    <= ram_out3;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 3: Match & Way Compare (Combinational on stg2 registers)
    // -------------------------------------------------------------------------
    wire [ENTRY_W-1:0] stg2_ways [0:3];
    assign stg2_ways[0] = stg2_out0;
    assign stg2_ways[1] = stg2_out1;
    assign stg2_ways[2] = stg2_out2;
    assign stg2_ways[3] = stg2_out3;

    reg [3:0] way_hit;
    reg [3:0] way_empty;
    integer w;
    always @(*) begin
        for (w = 0; w < 4; w = w + 1) begin
            way_hit[w]   = stg2_ways[w][133] && (stg2_ways[w][132:69] == stg2_ref);
            way_empty[w] = !stg2_ways[w][133];
        end
    end

    wire hit_any   = |way_hit;
    wire has_empty = |way_empty;

    // Lowest hit way index
    reg [1:0] hit_way_idx;
    always @(*) begin
        casez (way_hit)
            4'b???1: hit_way_idx = 2'd0;
            4'b??10: hit_way_idx = 2'd1;
            4'b?100: hit_way_idx = 2'd2;
            4'b1000: hit_way_idx = 2'd3;
            default: hit_way_idx = 2'd0;
        endcase
    end

    // Lowest empty way index
    reg [1:0] empty_way_idx;
    always @(*) begin
        casez (way_empty)
            4'b???1: empty_way_idx = 2'd0;
            4'b??10: empty_way_idx = 2'd1;
            4'b?100: empty_way_idx = 2'd2;
            4'b1000: empty_way_idx = 2'd3;
            default: empty_way_idx = 2'd0;
        endcase
    end

    wire [ENTRY_W-1:0] hit_entry = stg2_ways[hit_way_idx];
    wire [63:0] hit_ref    = hit_entry[132:69];
    wire [3:0]  hit_sym    = hit_entry[68:65];
    wire        hit_side   = hit_entry[64];
    wire [31:0] hit_price  = hit_entry[63:32];
    wire [31:0] hit_shares = hit_entry[31:0];

    // Helper task to format OP bus line
    function [104:0] make_op(
        input [31:0] idx,
        input [1:0]  code,
        input [3:0]  sym,
        input        side,
        input        remove,
        input        last,
        input [31:0] price,
        input [31:0] qty
    );
        begin
            make_op = 105'd0;
            make_op[`T2T_OP_IDX_HI    : `T2T_OP_IDX_LO]    = idx;
            make_op[`T2T_OP_CODE_HI   : `T2T_OP_CODE_LO]   = code;
            make_op[`T2T_OP_SYM_HI    : `T2T_OP_SYM_LO]    = sym;
            make_op[`T2T_OP_SIDE_BIT]                      = side;
            make_op[`T2T_OP_REMOVE_BIT]                    = remove;
            make_op[`T2T_OP_LAST_BIT]                      = last;
            make_op[`T2T_OP_PRICE_HI  : `T2T_OP_PRICE_LO]  = price;
            make_op[`T2T_OP_QTY_HI    : `T2T_OP_QTY_LO]    = qty;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Stage 3 Sequential Execution & RAM Write-Back
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            stg3_valid          <= 1'b0;
            stg3_set            <= {TABLE_AW{1'b0}};
            u_pending           <= 1'b0;
            u_saved_sym         <= 4'd0;
            u_saved_side        <= 1'b0;
            u_saved_idx         <= 32'd0;
            u_newref            <= 64'd0;
            u_newshares         <= 32'd0;
            u_newprice          <= 32'd0;
            wr_addr             <= {TABLE_AW{1'b0}};
            wr_data             <= {ENTRY_W{1'b0}};
            wr_en               <= 4'b0000;
            o_op_valid          <= 1'b0;
            o_op                <= 105'd0;
            o_cnt_ins           <= 1'b0;
            o_cnt_ref_miss      <= 1'b0;
            o_cnt_dup_ref       <= 1'b0;
            o_cnt_set_full      <= 1'b0;
            o_cnt_qty_underflow <= 1'b0;
        end else if (i_init_busy) begin
            // Sweep all sets writing invalid
            wr_addr             <= sweep_cnt;
            wr_data             <= {ENTRY_W{1'b0}};
            wr_en               <= 4'b1111;
            stg3_valid          <= 1'b0;
            u_pending           <= 1'b0;
            o_op_valid          <= 1'b0;
            o_op                <= 105'd0;
            o_cnt_ins           <= 1'b0;
            o_cnt_ref_miss      <= 1'b0;
            o_cnt_dup_ref       <= 1'b0;
            o_cnt_set_full      <= 1'b0;
            o_cnt_qty_underflow <= 1'b0;
        end else begin
            stg3_valid          <= stg2_valid;
            stg3_set            <= stg2_set;
            wr_en               <= 4'b0000;
            wr_addr             <= stg2_set;
            wr_data             <= {ENTRY_W{1'b0}};
            o_op_valid          <= 1'b0;
            o_op                <= 105'd0;
            o_cnt_ins           <= 1'b0;
            o_cnt_ref_miss      <= 1'b0;
            o_cnt_dup_ref       <= 1'b0;
            o_cnt_set_full      <= 1'b0;
            o_cnt_qty_underflow <= 1'b0;

            if (can_issue && is_replace_subop2) begin
                u_pending <= 1'b0;
            end

            if (stg2_valid) begin
                case (stg2_type)
                    // ---------------------------------------------------------
                    // Types A & F (and Replace Sub-op 2 Insert)
                    // ---------------------------------------------------------
                    `T2T_TYPE_A, `T2T_TYPE_F: begin
                        if (!stg2_side_ok) begin
                            // Side is not B or S: CORRUPT(sym), last
                            o_op_valid <= 1'b1;
                            o_op       <= make_op(stg2_idx, `T2T_OP_CORRUPT, stg2_sym, `T2T_SIDE_BID, 1'b0, 1'b1, 32'd0, 32'd0);
                        end else if (hit_any) begin
                            // Duplicate reference: CORRUPT(sym), last
                            o_cnt_dup_ref <= 1'b1;
                            o_op_valid    <= 1'b1;
                            o_op          <= make_op(stg2_idx, `T2T_OP_CORRUPT, stg2_sym, stg2_side, 1'b0, 1'b1, 32'd0, 32'd0);
                        end else if (!has_empty) begin
                            // Set full: CORRUPT(sym), last
                            o_cnt_set_full <= 1'b1;
                            o_op_valid     <= 1'b1;
                            o_op           <= make_op(stg2_idx, `T2T_OP_CORRUPT, stg2_sym, stg2_side, 1'b0, 1'b1, 32'd0, 32'd0);
                        end else begin
                            // Valid insert: ADD(sym, side, price, shares, remove=0), last
                            o_cnt_ins     <= 1'b1;
                            o_op_valid    <= 1'b1;
                            o_op          <= make_op(stg2_idx, `T2T_OP_ADD, stg2_sym, stg2_side, 1'b0, 1'b1, stg2_price, stg2_shares);
                            wr_en[empty_way_idx] <= 1'b1;
                            wr_data       <= {1'b1, stg2_ref, stg2_sym, stg2_side, stg2_price, stg2_shares};
                        end
                    end

                    // ---------------------------------------------------------
                    // Types E, C, X (Executed, Executed with Price, Cancel)
                    // ---------------------------------------------------------
                    `T2T_TYPE_E, `T2T_TYPE_C, `T2T_TYPE_X: begin
                        if (!hit_any) begin
                            // Benign reference miss
                            o_cnt_ref_miss <= 1'b1;
                        end else if (stg2_shares > hit_shares) begin
                            // Quantity underflow: CORRUPT(entry.sym), last
                            o_cnt_qty_underflow <= 1'b1;
                            o_op_valid          <= 1'b1;
                            o_op                <= make_op(stg2_idx, `T2T_OP_CORRUPT, hit_sym, hit_side, 1'b0, 1'b1, 32'd0, 32'd0);
                        end else if (stg2_shares == hit_shares) begin
                            // Full execution/cancel: invalidate way, REDUCE(remove=1), last
                            o_op_valid <= 1'b1;
                            o_op       <= make_op(stg2_idx, `T2T_OP_REDUCE, hit_sym, hit_side, 1'b1, 1'b1, hit_price, stg2_shares);
                            wr_en[hit_way_idx] <= 1'b1;
                            wr_data            <= {ENTRY_W{1'b0}}; // Invalidate
                        end else begin
                            // Partial execution/cancel: update entry, REDUCE(remove=0), last
                            o_op_valid <= 1'b1;
                            o_op       <= make_op(stg2_idx, `T2T_OP_REDUCE, hit_sym, hit_side, 1'b0, 1'b1, hit_price, stg2_shares);
                            wr_en[hit_way_idx] <= 1'b1;
                            wr_data            <= {1'b1, hit_ref, hit_sym, hit_side, hit_price, hit_shares - stg2_shares};
                        end
                    end

                    // ---------------------------------------------------------
                    // Type D (Delete)
                    // ---------------------------------------------------------
                    `T2T_TYPE_D: begin
                        if (!hit_any) begin
                            o_cnt_ref_miss <= 1'b1;
                        end else begin
                            o_op_valid <= 1'b1;
                            o_op       <= make_op(stg2_idx, `T2T_OP_REDUCE, hit_sym, hit_side, 1'b1, 1'b1, hit_price, hit_shares);
                            wr_en[hit_way_idx] <= 1'b1;
                            wr_data            <= {ENTRY_W{1'b0}}; // Invalidate
                        end
                    end

                    // ---------------------------------------------------------
                    // Type U (Replace Sub-op 1: Old Ref Lookup)
                    // ---------------------------------------------------------
                    `T2T_TYPE_U: begin
                        if (!hit_any) begin
                            o_cnt_ref_miss <= 1'b1;
                        end else begin
                            // Invalidate old entry, emit REDUCE(remove=1, last=0)
                            o_op_valid <= 1'b1;
                            o_op       <= make_op(stg2_idx, `T2T_OP_REDUCE, hit_sym, hit_side, 1'b1, 1'b0, hit_price, hit_shares);
                            wr_en[hit_way_idx] <= 1'b1;
                            wr_data            <= {ENTRY_W{1'b0}}; // Invalidate old way

                            // Setup Sub-op 2 issue
                            u_pending    <= 1'b1;
                            u_saved_sym  <= hit_sym;
                            u_saved_side <= hit_side;
                            u_saved_idx  <= stg2_idx;
                            u_newref     <= stg2_newref;
                            u_newshares  <= stg2_shares;
                            u_newprice   <= stg2_price;
                        end
                    end

                    default: begin
                        // Unhandled
                    end
                endcase
            end
        end
    end

endmodule

