// =============================================================================
// File        : rtl/t2t_extract.v
// Spec Section: 5.2 (MSG Bus), 6.1 (Inbound Wire Formats), 7.3 (Stage S3)
// Description : ITCH 5.0 message field extractor and type decoder.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module t2t_extract (
    input  wire         clk,
    input  wire         rst,

    // Interface from S2 Framer
    input  wire         i_blk_valid,
    input  wire [31:0]  i_blk_idx,
    input  wire [7:0]   i_blk_len,
    input  wire [399:0] i_blk_bytes,

    // Interface to S4 Symbol Filter
    output reg          o_msg_valid,
    output reg  [319:0] o_msg,
    output reg  [3:0]   o_blk_flags,

    // Diagnostic & Performance Counters
    output reg  [6:0]   o_cnt_type, // one-hot: [0]=A, [1]=F, [2]=E, [3]=C, [4]=X, [5]=D, [6]=U
    output reg          o_cnt_other,
    output reg          o_cnt_zero,
    output reg          o_cnt_badlen,
    output reg          o_session_invalid
);

    // Byte helper slicing from i_blk_bytes (byte b in [8*b +: 8])
    function [7:0] b(input [6:0] idx);
        begin
            b = i_blk_bytes[8*idx +: 8];
        end
    endfunction

    // 16-bit big-endian extract
    function [15:0] be16(input [6:0] idx);
        begin
            be16 = {b(idx), b(idx + 7'd1)};
        end
    endfunction

    // 32-bit big-endian extract
    function [31:0] be32(input [6:0] idx);
        begin
            be32 = {b(idx), b(idx + 7'd1), b(idx + 7'd2), b(idx + 7'd3)};
        end
    endfunction

    // 64-bit big-endian extract
    function [63:0] be64(input [6:0] idx);
        begin
            be64 = {b(idx),        b(idx + 7'd1), b(idx + 7'd2), b(idx + 7'd3),
                    b(idx + 7'd4), b(idx + 7'd5), b(idx + 7'd6), b(idx + 7'd7)};
        end
    endfunction

    wire [7:0] type_byte = i_blk_bytes[7:0];

    always @(posedge clk) begin
        if (rst) begin
            o_msg_valid       <= 1'b0;
            o_msg             <= 320'd0;
            o_blk_flags       <= 4'd0;
            o_cnt_type        <= 7'd0;
            o_cnt_other       <= 1'b0;
            o_cnt_zero        <= 1'b0;
            o_cnt_badlen      <= 1'b0;
            o_session_invalid <= 1'b0;
        end else begin
            // Default pulse outputs
            o_msg_valid  <= 1'b0;
            o_cnt_type   <= 7'd0;
            o_cnt_other  <= 1'b0;
            o_cnt_zero   <= 1'b0;
            o_cnt_badlen <= 1'b0;

            if (i_blk_valid) begin
                if (i_blk_len == 8'd0) begin
                    // Zero length block
                    o_cnt_zero  <= 1'b1;
                    o_blk_flags <= 4'b0100; // bit2: zero_len
                end else begin
                    case (type_byte)
                        `T2T_TYPE_A: begin
                            if (i_blk_len != `T2T_LEN_A) begin
                                o_cnt_badlen      <= 1'b1;
                                o_session_invalid <= 1'b1;
                                o_blk_flags       <= 4'b0010; // bit1: bad_len
                            end else begin
                                o_msg_valid <= 1'b1;
                                o_cnt_type[0] <= 1'b1;
                                o_blk_flags <= (b(7'd19) != `T2T_ASCII_BUY && b(7'd19) != `T2T_ASCII_SELL) ? 4'b1001 : 4'b0001;
                                o_msg[`T2T_MSG_IDX_HI    : `T2T_MSG_IDX_LO]    <= i_blk_idx;
                                o_msg[`T2T_MSG_TYPE_HI   : `T2T_MSG_TYPE_LO]   <= `T2T_TYPE_A;
                                o_msg[`T2T_MSG_LOCATE_HI : `T2T_MSG_LOCATE_LO] <= be16(7'd1);
                                o_msg[`T2T_MSG_REF_HI    : `T2T_MSG_REF_LO]    <= be64(7'd11);
                                o_msg[`T2T_MSG_NEWREF_HI : `T2T_MSG_NEWREF_LO] <= 64'd0;
                                o_msg[`T2T_MSG_SIDE_HI   : `T2T_MSG_SIDE_LO]   <= b(7'd19);
                                o_msg[`T2T_MSG_SHARES_HI : `T2T_MSG_SHARES_LO] <= be32(7'd20);
                                o_msg[`T2T_MSG_PRICE_HI  : `T2T_MSG_PRICE_LO]  <= be32(7'd32);
                                o_msg[`T2T_MSG_STOCK_HI  : `T2T_MSG_STOCK_LO]  <= be64(7'd24);
                            end
                        end

                        `T2T_TYPE_F: begin
                            if (i_blk_len != `T2T_LEN_F) begin
                                o_cnt_badlen      <= 1'b1;
                                o_session_invalid <= 1'b1;
                                o_blk_flags       <= 4'b0010;
                            end else begin
                                o_msg_valid <= 1'b1;
                                o_cnt_type[1] <= 1'b1;
                                o_blk_flags <= (b(7'd19) != `T2T_ASCII_BUY && b(7'd19) != `T2T_ASCII_SELL) ? 4'b1001 : 4'b0001;
                                o_msg[`T2T_MSG_IDX_HI    : `T2T_MSG_IDX_LO]    <= i_blk_idx;
                                o_msg[`T2T_MSG_TYPE_HI   : `T2T_MSG_TYPE_LO]   <= `T2T_TYPE_F;
                                o_msg[`T2T_MSG_LOCATE_HI : `T2T_MSG_LOCATE_LO] <= be16(7'd1);
                                o_msg[`T2T_MSG_REF_HI    : `T2T_MSG_REF_LO]    <= be64(7'd11);
                                o_msg[`T2T_MSG_NEWREF_HI : `T2T_MSG_NEWREF_LO] <= 64'd0;
                                o_msg[`T2T_MSG_SIDE_HI   : `T2T_MSG_SIDE_LO]   <= b(7'd19);
                                o_msg[`T2T_MSG_SHARES_HI : `T2T_MSG_SHARES_LO] <= be32(7'd20);
                                o_msg[`T2T_MSG_PRICE_HI  : `T2T_MSG_PRICE_LO]  <= be32(7'd32);
                                o_msg[`T2T_MSG_STOCK_HI  : `T2T_MSG_STOCK_LO]  <= be64(7'd24);
                            end
                        end

                        `T2T_TYPE_E: begin
                            if (i_blk_len != `T2T_LEN_E) begin
                                o_cnt_badlen      <= 1'b1;
                                o_session_invalid <= 1'b1;
                                o_blk_flags       <= 4'b0010;
                            end else begin
                                o_msg_valid <= 1'b1;
                                o_cnt_type[2] <= 1'b1;
                                o_blk_flags <= 4'b0001;
                                o_msg[`T2T_MSG_IDX_HI    : `T2T_MSG_IDX_LO]    <= i_blk_idx;
                                o_msg[`T2T_MSG_TYPE_HI   : `T2T_MSG_TYPE_LO]   <= `T2T_TYPE_E;
                                o_msg[`T2T_MSG_LOCATE_HI : `T2T_MSG_LOCATE_LO] <= be16(7'd1);
                                o_msg[`T2T_MSG_REF_HI    : `T2T_MSG_REF_LO]    <= be64(7'd11);
                                o_msg[`T2T_MSG_NEWREF_HI : `T2T_MSG_NEWREF_LO] <= 64'd0;
                                o_msg[`T2T_MSG_SIDE_HI   : `T2T_MSG_SIDE_LO]   <= 8'd0;
                                o_msg[`T2T_MSG_SHARES_HI : `T2T_MSG_SHARES_LO] <= be32(7'd19);
                                o_msg[`T2T_MSG_PRICE_HI  : `T2T_MSG_PRICE_LO]  <= 32'd0;
                                o_msg[`T2T_MSG_STOCK_HI  : `T2T_MSG_STOCK_LO]  <= 64'd0;
                            end
                        end

                        `T2T_TYPE_C: begin
                            if (i_blk_len != `T2T_LEN_C) begin
                                o_cnt_badlen      <= 1'b1;
                                o_session_invalid <= 1'b1;
                                o_blk_flags       <= 4'b0010;
                            end else begin
                                o_msg_valid <= 1'b1;
                                o_cnt_type[3] <= 1'b1;
                                o_blk_flags <= 4'b0001;
                                o_msg[`T2T_MSG_IDX_HI    : `T2T_MSG_IDX_LO]    <= i_blk_idx;
                                o_msg[`T2T_MSG_TYPE_HI   : `T2T_MSG_TYPE_LO]   <= `T2T_TYPE_C;
                                o_msg[`T2T_MSG_LOCATE_HI : `T2T_MSG_LOCATE_LO] <= be16(7'd1);
                                o_msg[`T2T_MSG_REF_HI    : `T2T_MSG_REF_LO]    <= be64(7'd11);
                                o_msg[`T2T_MSG_NEWREF_HI : `T2T_MSG_NEWREF_LO] <= 64'd0;
                                o_msg[`T2T_MSG_SIDE_HI   : `T2T_MSG_SIDE_LO]   <= 8'd0;
                                o_msg[`T2T_MSG_SHARES_HI : `T2T_MSG_SHARES_LO] <= be32(7'd19);
                                o_msg[`T2T_MSG_PRICE_HI  : `T2T_MSG_PRICE_LO]  <= be32(7'd32);
                                o_msg[`T2T_MSG_STOCK_HI  : `T2T_MSG_STOCK_LO]  <= 64'd0;
                            end
                        end

                        `T2T_TYPE_X: begin
                            if (i_blk_len != `T2T_LEN_X) begin
                                o_cnt_badlen      <= 1'b1;
                                o_session_invalid <= 1'b1;
                                o_blk_flags       <= 4'b0010;
                            end else begin
                                o_msg_valid <= 1'b1;
                                o_cnt_type[4] <= 1'b1;
                                o_blk_flags <= 4'b0001;
                                o_msg[`T2T_MSG_IDX_HI    : `T2T_MSG_IDX_LO]    <= i_blk_idx;
                                o_msg[`T2T_MSG_TYPE_HI   : `T2T_MSG_TYPE_LO]   <= `T2T_TYPE_X;
                                o_msg[`T2T_MSG_LOCATE_HI : `T2T_MSG_LOCATE_LO] <= be16(7'd1);
                                o_msg[`T2T_MSG_REF_HI    : `T2T_MSG_REF_LO]    <= be64(7'd11);
                                o_msg[`T2T_MSG_NEWREF_HI : `T2T_MSG_NEWREF_LO] <= 64'd0;
                                o_msg[`T2T_MSG_SIDE_HI   : `T2T_MSG_SIDE_LO]   <= 8'd0;
                                o_msg[`T2T_MSG_SHARES_HI : `T2T_MSG_SHARES_LO] <= be32(7'd19);
                                o_msg[`T2T_MSG_PRICE_HI  : `T2T_MSG_PRICE_LO]  <= 32'd0;
                                o_msg[`T2T_MSG_STOCK_HI  : `T2T_MSG_STOCK_LO]  <= 64'd0;
                            end
                        end

                        `T2T_TYPE_D: begin
                            if (i_blk_len != `T2T_LEN_D) begin
                                o_cnt_badlen      <= 1'b1;
                                o_session_invalid <= 1'b1;
                                o_blk_flags       <= 4'b0010;
                            end else begin
                                o_msg_valid <= 1'b1;
                                o_cnt_type[5] <= 1'b1;
                                o_blk_flags <= 4'b0001;
                                o_msg[`T2T_MSG_IDX_HI    : `T2T_MSG_IDX_LO]    <= i_blk_idx;
                                o_msg[`T2T_MSG_TYPE_HI   : `T2T_MSG_TYPE_LO]   <= `T2T_TYPE_D;
                                o_msg[`T2T_MSG_LOCATE_HI : `T2T_MSG_LOCATE_LO] <= be16(7'd1);
                                o_msg[`T2T_MSG_REF_HI    : `T2T_MSG_REF_LO]    <= be64(7'd11);
                                o_msg[`T2T_MSG_NEWREF_HI : `T2T_MSG_NEWREF_LO] <= 64'd0;
                                o_msg[`T2T_MSG_SIDE_HI   : `T2T_MSG_SIDE_LO]   <= 8'd0;
                                o_msg[`T2T_MSG_SHARES_HI : `T2T_MSG_SHARES_LO] <= 32'd0;
                                o_msg[`T2T_MSG_PRICE_HI  : `T2T_MSG_PRICE_LO]  <= 32'd0;
                                o_msg[`T2T_MSG_STOCK_HI  : `T2T_MSG_STOCK_LO]  <= 64'd0;
                            end
                        end

                        `T2T_TYPE_U: begin
                            if (i_blk_len != `T2T_LEN_U) begin
                                o_cnt_badlen      <= 1'b1;
                                o_session_invalid <= 1'b1;
                                o_blk_flags       <= 4'b0010;
                            end else begin
                                o_msg_valid <= 1'b1;
                                o_cnt_type[6] <= 1'b1;
                                o_blk_flags <= 4'b0001;
                                o_msg[`T2T_MSG_IDX_HI    : `T2T_MSG_IDX_LO]    <= i_blk_idx;
                                o_msg[`T2T_MSG_TYPE_HI   : `T2T_MSG_TYPE_LO]   <= `T2T_TYPE_U;
                                o_msg[`T2T_MSG_LOCATE_HI : `T2T_MSG_LOCATE_LO] <= be16(7'd1);
                                o_msg[`T2T_MSG_REF_HI    : `T2T_MSG_REF_LO]    <= be64(7'd11);
                                o_msg[`T2T_MSG_NEWREF_HI : `T2T_MSG_NEWREF_LO] <= be64(7'd19);
                                o_msg[`T2T_MSG_SIDE_HI   : `T2T_MSG_SIDE_LO]   <= 8'd0;
                                o_msg[`T2T_MSG_SHARES_HI : `T2T_MSG_SHARES_LO] <= be32(7'd27);
                                o_msg[`T2T_MSG_PRICE_HI  : `T2T_MSG_PRICE_LO]  <= be32(7'd31);
                                o_msg[`T2T_MSG_STOCK_HI  : `T2T_MSG_STOCK_LO]  <= 64'd0;
                            end
                        end

                        default: begin
                            // Unhandled ITCH message type
                            o_cnt_other <= 1'b1;
                            o_blk_flags <= 4'b0000;
                        end
                    endcase
                end
            end
        end
    end

endmodule

