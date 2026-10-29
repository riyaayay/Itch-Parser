// =============================================================================
// File        : rtl/t2t_sess.v
// Spec Section: 4.4, 11.2, 11.4 (Session State Manager & Initialization Sweep)
// Description : Manages session lifecycle, owns init_busy timing, performs
//               2^TABLE_AW + 4 cycle RAM initialization sweep, tracks sticky
//               session_invalid flag, and distributes session reset pulses.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

module t2t_sess #(
    parameter TABLE_AW = `T2T_TABLE_AW
) (
    input  wire        clk,
    input  wire        rst,

    // Host session reset request (1-cycle pulse from CTRL.session_reset)
    input  wire        i_session_reset,

    // Error triggers that invalidate the session (Section 4.4)
    input  wire        i_ingest_overflow,
    input  wire        i_frame_err,
    input  wire        i_keep_err,
    input  wire        i_bad_len,
    input  wire        i_fatal_overflow,

    // Session status outputs
    output reg         o_init_busy,
    output reg         o_sess_reset_pulse,
    output reg         o_session_invalid
);

    // Number of sweep cycles: 2^TABLE_AW + 4
    localparam SWEEP_TOTAL = (1 << TABLE_AW) + 4;

    reg [TABLE_AW+1:0] busy_cnt;

    wire any_err = i_ingest_overflow | i_frame_err | i_keep_err | i_bad_len | i_fatal_overflow;

    always @(posedge clk) begin
        if (rst) begin
            busy_cnt           <= SWEEP_TOTAL[TABLE_AW+1:0];
            o_init_busy        <= 1'b1;
            o_sess_reset_pulse <= 1'b1;
            o_session_invalid  <= 1'b0;
        end else begin
            // 1-cycle reset strobe clears by default
            o_sess_reset_pulse <= 1'b0;

            // Host session reset request
            if (i_session_reset) begin
                busy_cnt           <= SWEEP_TOTAL[TABLE_AW+1:0];
                o_init_busy        <= 1'b1;
                o_sess_reset_pulse <= 1'b1;
                o_session_invalid  <= 1'b0;
            end else if (busy_cnt > 0) begin
                busy_cnt <= busy_cnt - 1'b1;
                if (busy_cnt == 1) begin
                    o_init_busy <= 1'b0;
                end
            end

            // Session invalidation error detection (sticky until next session reset)
            if (any_err && !i_session_reset) begin
                o_session_invalid <= 1'b1;
            end
        end
    end

endmodule

