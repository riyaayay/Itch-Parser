// =============================================================================
// File        : rtl/ref/itch_decoder_ref.v
// Spec Section: 3.2 (F2, F3), 3.3 (Derived-Pending-Permission), 7.3, 12.2 (EX-10)
// Description : Reference-mode ITCH decoder derived from upstream/itch_decoder.v
//               with Findings F2 & F3 resolved (last-byte capture & order_valid).
// Derivative Attribution:
//   Based on upstream/itch_decoder.v by tmlee06 (All Rights Reserved Pending Confirmation).
//   Modifications Copyright (c) 2026 Riya Rathod.
// =============================================================================

`timescale 1ns / 1ps

module itch_decoder_ref (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  data_in,
    input  wire        valid_in,

    output reg  [7:0]  msg_type,
    output reg  [31:0] order_shares,
    output reg  [31:0] order_price,
    output reg         order_valid
);

    // FSM States
    localparam [2:0]
        IDLE         = 3'd0,
        READ_LEN_1   = 3'd1,
        READ_LEN_2   = 3'd2,
        READ_TYPE    = 3'd3,
        READ_PAYLOAD = 3'd4;

    reg [2:0] state, next_state;
    reg [15:0] msg_length;
    reg [15:0] byte_count;

    // Sequential Logic: Move to next state on every clock tick (matching upstream structure)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state        <= IDLE;
            byte_count   <= 16'd0;
            msg_length   <= 16'd0;
            order_shares <= 32'd0;
            order_price  <= 32'd0;
            order_valid  <= 1'b0;
            msg_type     <= 8'd0;
        end else if (valid_in) begin
            state       <= next_state;
            order_valid <= 1'b0;

            case (next_state)
                IDLE: begin
                    byte_count <= 16'd0;
                end

                READ_LEN_1: begin
                    msg_length[15:8] <= data_in;
                    byte_count       <= 16'd0;
                end

                READ_LEN_2: begin
                    msg_length[7:0] <= data_in;
                end

                READ_TYPE: begin
                    msg_type   <= data_in;
                    byte_count <= 16'd1;
                end

                READ_PAYLOAD: begin
                    byte_count <= byte_count + 16'd1;

                    if (msg_type == 8'h41) begin
                        if (byte_count == 16'd20) order_shares[31:24] <= data_in;
                        if (byte_count == 16'd21) order_shares[23:16] <= data_in;
                        if (byte_count == 16'd22) order_shares[15:8]  <= data_in;
                        if (byte_count == 16'd23) order_shares[7:0]   <= data_in;

                        if (byte_count == 16'd32) order_price[31:24]  <= data_in;
                        if (byte_count == 16'd33) order_price[23:16]  <= data_in;
                        if (byte_count == 16'd34) order_price[15:8]   <= data_in;
                        if (byte_count == 16'd35) order_price[7:0]    <= data_in;
                    end

                    // Once we hit the last byte of the message (msg_length - 1 = 35 for 36B Add Order),
                    // pulse order_valid.
                    if (byte_count == msg_length - 16'd1) begin
                        if (msg_type == 8'h41) order_valid <= 1'b1;
                    end
                end

                default: state <= IDLE;
            endcase
        end else begin
            order_valid <= 1'b0;
        end
    end

    // Combinational Next-State Logic (Fix for F2 & F3)
    // Upstream bug: transitioned to IDLE when byte_count == msg_length - 1.
    // Because datapath evaluates case (next_state), this prematurely forced
    // state to IDLE on the final payload byte (offset 35), preventing order_valid
    // from asserting and dropping order_price[7:0].
    // Fix: stay in READ_PAYLOAD until all msg_length bytes are processed.
    // When byte_count == msg_length, transition to READ_LEN_1 (if valid_in) or IDLE.
    always @(*) begin
        next_state = state;
        case (state)
            IDLE: begin
                if (valid_in) next_state = READ_LEN_1;
            end

            READ_LEN_1: begin
                next_state = READ_LEN_2;
            end

            READ_LEN_2: begin
                next_state = READ_TYPE;
            end

            READ_TYPE: begin
                next_state = READ_PAYLOAD;
            end

            READ_PAYLOAD: begin
                if (byte_count == msg_length) begin
                    if (valid_in)
                        next_state = READ_LEN_1;
                    else
                        next_state = IDLE;
                end
            end

            default: next_state = IDLE;
        endcase
    end

endmodule
