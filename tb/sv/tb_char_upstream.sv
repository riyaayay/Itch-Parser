// =============================================================================
// File        : tb/sv/tb_char_upstream.sv
// Spec Section: 3.2 (F2, F3, F9, F10), 12.2 (CHAR-2), 16.1 (VERIFY-4)
// Description : Instrumented characterisation testbench for unmodified
//               upstream/itch_decoder.v. Logs every order_valid pulse,
//               order_shares, order_price, and internal state transitions
//               to close VERIFY-4.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================
`timescale 1ns / 1ps

module tb_char_upstream;

    // -------------------------------------------------------------------------
    // Clock & Reset (100 MHz -> 10 ns period, matching upstream testbench)
    // -------------------------------------------------------------------------
    logic        clk = 1'b0;
    logic        rst = 1'b1;
    logic [7:0]  data_in = 8'h00;
    logic        valid_in = 1'b0;

    wire  [7:0]  msg_type;
    wire  [31:0] order_shares;
    wire  [31:0] order_price;
    wire         order_valid;

    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Instantiate unmodified upstream itch_decoder
    // -------------------------------------------------------------------------
    itch_decoder u_dut (
        .clk          (clk),
        .rst          (rst),
        .data_in      (data_in),
        .valid_in     (valid_in),
        .msg_type     (msg_type),
        .order_shares (order_shares),
        .order_price  (order_price),
        .order_valid  (order_valid)
    );

    // -------------------------------------------------------------------------
    // Stimulus memory & instrumentation counters
    // -------------------------------------------------------------------------
    reg [7:0] sim_mem [0:719];
    integer   order_valid_pulses_part1 = 0;
    integer   order_valid_pulses_part2 = 0;
    integer   last_byte_transitions    = 0;
    integer   i;

    // Monitor every clock edge for order_valid pulses and last-byte transitions
    always @(posedge clk) begin
        if (!rst) begin
            if (order_valid) begin
                $display("[CHAR-2 MON] t=%0t ns | order_valid=1 | msg_type=0x%02x | shares=0x%08x (%0d) | price=0x%08x (%0d)",
                         $time, msg_type, order_shares, order_shares, order_price, order_price);
            end
            // Probe internal state transition on last payload byte (F2 / F3)
            if (valid_in && (u_dut.state == 2'b11) && (u_dut.byte_count == (u_dut.msg_length - 16'd1))) begin
                last_byte_transitions = last_byte_transitions + 1;
                $display("[CHAR-2 F2/F3 PROBE] t=%0t ns | state=%0d -> next_state=%0d on byte_count=%0d (msg_length=%0d), data_in=0x%02x | order_price_before=0x%08x",
                         $time, u_dut.state, u_dut.next_state, u_dut.byte_count, u_dut.msg_length, data_in, order_price);
            end
        end
    end

    // Helper task to feed one byte synchronous to clk
    task automatic send_byte(input [7:0] b);
        begin
            @(posedge clk);
            valid_in <= 1'b1;
            data_in  <= b;
        end
    endtask

    // 38-byte well-formed ITCH 5.0 Add Order (2B prefix 0x0024 + 36B payload)
    // Shares = 0x00000064 (100), Price = 0x001A2B3C (last byte = 0x3C)
    reg [7:0] valid_38b_frame [0:37];

    initial begin
        $display("=============================================================================");
        $display("CHAR-2: Instrumented Upstream itch_decoder.v Characterisation (VERIFY-4)");
        $display("=============================================================================");

        // Load upstream sim_data.hex
        $readmemh("upstream/sim_data.hex", sim_mem);

        // Hold reset for 100 ns, then wait 20 ns (matches tb_itch_decoder_real_data.v)
        rst      = 1'b1;
        valid_in = 1'b0;
        data_in  = 8'h00;
        #100;
        rst      = 1'b0;
        #20;

        $display("--- Part 1: Streaming 720-byte upstream/sim_data.hex ---");
        for (i = 0; i < 720; i = i + 1) begin
            @(posedge clk);
            valid_in <= 1'b1;
            data_in  <= sim_mem[i];
            if (order_valid) begin
                order_valid_pulses_part1 = order_valid_pulses_part1 + 1;
            end
        end

        @(posedge clk);
        valid_in <= 1'b0;
        data_in  <= 8'h00;

        // Drain 20 cycles
        repeat (20) begin
            @(posedge clk);
            if (order_valid) begin
                order_valid_pulses_part1 = order_valid_pulses_part1 + 1;
            end
        end

        $display("[CHAR-2 PART 1] Completed 720-byte sim_data.hex stream at t=%0t ns.", $time);
        $display("[CHAR-2 PART 1] order_valid_pulses=%0d | final order_shares=0x%08x | final order_price=0x%08x",
                 order_valid_pulses_part1, order_shares, order_price);

        // ---------------------------------------------------------------------
        // Part 2: Reset and feed a single well-formed 38-byte Add Order block
        // ---------------------------------------------------------------------
        $display("--- Part 2: Streaming clean 38-byte Add Order (Price=0x001A2B3C, Shares=0x00000064) ---");
        for (i = 0; i < 38; i = i + 1) valid_38b_frame[i] = 8'h00;
        // 2-byte big-endian length prefix = 36 (0x0024)
        valid_38b_frame[0]  = 8'h00;
        valid_38b_frame[1]  = 8'h24;
        // Payload offset 0 (frame index 2): Type 'A' (0x41)
        valid_38b_frame[2]  = 8'h41;
        // Payload offset 19 (frame index 21): Side 'B' (0x42)
        valid_38b_frame[21] = 8'h42;
        // Payload offsets 20..23 (frame indices 22..25): Shares = 0x00000064
        valid_38b_frame[22] = 8'h00;
        valid_38b_frame[23] = 8'h00;
        valid_38b_frame[24] = 8'h00;
        valid_38b_frame[25] = 8'h64;
        // Payload offsets 24..31 (frame indices 26..33): Stock "AAPL    "
        valid_38b_frame[26] = "A";
        valid_38b_frame[27] = "A";
        valid_38b_frame[28] = "P";
        valid_38b_frame[29] = "L";
        valid_38b_frame[30] = " ";
        valid_38b_frame[31] = " ";
        valid_38b_frame[32] = " ";
        valid_38b_frame[33] = " ";
        // Payload offsets 32..35 (frame indices 34..37): Price = 0x001A2B3C
        valid_38b_frame[34] = 8'h00;
        valid_38b_frame[35] = 8'h1A;
        valid_38b_frame[36] = 8'h2B;
        valid_38b_frame[37] = 8'h3C; // Offset 35: should go into order_price[7:0], dropped by F3

        @(posedge clk);
        rst <= 1'b1;
        @(posedge clk);
        @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        for (i = 0; i < 38; i = i + 1) begin
            send_byte(valid_38b_frame[i]);
            if (order_valid) begin
                order_valid_pulses_part2 = order_valid_pulses_part2 + 1;
            end
        end

        @(posedge clk);
        valid_in <= 1'b0;
        data_in  <= 8'h00;

        repeat (10) begin
            @(posedge clk);
            if (order_valid) begin
                order_valid_pulses_part2 = order_valid_pulses_part2 + 1;
            end
        end

        $display("[CHAR-2 PART 2] Expected Shares = 0x00000064 | Captured order_shares = 0x%08x", order_shares);
        $display("[CHAR-2 PART 2] Expected Price  = 0x001A2B3C | Captured order_price  = 0x%08x (LSB 0x%02x dropped -> 0x00)",
                 order_price, valid_38b_frame[37]);
        $display("[CHAR-2 PART 2] order_valid_pulses = %0d", order_valid_pulses_part2);

        $display("-----------------------------------------------------------------------------");
        if (order_valid_pulses_part1 == 0 &&
            order_valid_pulses_part2 == 0 &&
            order_shares == 32'h0000_0064 &&
            order_price  == 32'h001A_2B00) begin
            $display("VERIFY-4 / CHAR-2 RESULT: PASS (Confirmed F2 & F3: order_valid pulses = 0,");
            $display("and order_price[7:0] is never captured because next_state=IDLE on byte_count==35).");
        end else begin
            $display("VERIFY-4 / CHAR-2 RESULT: UNEXPECTED BEHAVIOUR (Review logs above).");
            $fatal(1, "CHAR-2 verification check failed");
        end
        $display("=============================================================================");
        $finish;
    end

endmodule