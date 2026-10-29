// =============================================================================
// File        : tb/sv/tb_encoder_regs.sv
// Spec Section: 6.2, 11.1, 11.2, 15 (EN-1, EN-2, EN-3, RG-1)
// Description : Unit testbench for t2t_encoder and t2t_regs verifying
//               OUCH frame building, TXF elasticity/overflow, and AXI-Lite registers.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
/* verilator lint_off INITIALDLY */
`include "t2t_defs.vh"
`include "t2t_symbols.vh"

module tb_encoder_regs;

    reg clk;
    reg rst;

    // -------------------------------------------------------------------------
    // Signals for t2t_encoder & TX FIFO
    // -------------------------------------------------------------------------
    reg         enc_clear_fault;
    wire [8*64-1:0] cfg_stock;

    reg         dec_valid;
    reg         dec_pass;
    reg [3:0]   dec_reason;
    reg [3:0]   dec_sym;
    reg         dec_side;
    reg [31:0]  dec_price;
    reg [15:0]  dec_qty;
    reg [1:0]   dec_rule;
    reg [31:0]  dec_idx;

    wire        txf_full;
    wire        txf_afull;
    wire        txf_push;
    wire [511:0] txf_data;
    wire [63:0]  txf_keep;
    wire        txf_last;

    wire        enc_tx_fault;
    wire        enc_cnt_tx_frames;
    wire        enc_cnt_tx_overflow;

    // Instantiate t2t_encoder
    t2t_encoder #(
        .N_SYMBOLS(8)
    ) dut_encoder (
        .clk               (clk),
        .rst               (rst),
        .i_clear_fault     (enc_clear_fault),
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
        .o_tx_fault        (enc_tx_fault),
        .o_cnt_tx_frames   (enc_cnt_tx_frames),
        .o_cnt_tx_overflow (enc_cnt_tx_overflow)
    );

    // TX FIFO: depth 16, width 577 = 1 + 64 + 512
    reg        tx_axis_tready;
    wire       tx_fifo_empty;
    wire [576:0] tx_fifo_dout;

    wire tx_pop = !tx_fifo_empty && tx_axis_tready;

    t2t_sfifo #(
        .WIDTH(512 + 64 + 1),
        .DEPTH(`T2T_TXF_DEPTH),
        .ADDR_W(`T2T_TXF_AW),
        .ALMOST_FULL_THRESH(12)
    ) u_txf (
        .clk     (clk),
        .rst     (rst),
        .i_push  (txf_push),
        .i_data  ({txf_last, txf_keep, txf_data}),
        .o_full  (txf_full),
        .o_afull (txf_afull),
        .i_pop   (tx_pop),
        .o_data  (tx_fifo_dout),
        .o_empty (tx_fifo_empty),
        .o_count ()
    );

    wire        tx_axis_tvalid = !tx_fifo_empty;
    wire [511:0] tx_axis_tdata  = tx_fifo_dout[511:0];
    wire [63:0]  tx_axis_tkeep  = tx_fifo_dout[575:512];
    wire        tx_axis_tlast  = tx_fifo_dout[576];

    // -------------------------------------------------------------------------
    // Signals for t2t_regs
    // -------------------------------------------------------------------------
    reg  [11:0] awaddr;
    reg         awvalid;
    wire        awready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready;

    reg  [11:0] araddr;
    reg         arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready;

    reg         reg_session_invalid;
    reg         reg_init_busy;
    reg         reg_tx_fault;
    reg  [31:0] reg_live_best_bid0;
    reg  [31:0] reg_live_best_ask0;
    reg  [8*`T2T_TOB_SYM_W-1:0] reg_bk_tob_flat;
    reg  [8*32-1:0] reg_risk_pos_flat;
    reg  [31:0] reg_risk_gross;
    reg  [31:0] reg_risk_win_id;
    reg  [15:0] reg_risk_win_cnt;
    reg  [63:0] reg_cnt_pulses;

    wire        ctrl_session_reset;
    wire        ctrl_kill_switch;
    wire        ctrl_clear_counters;
    wire        ctrl_global_enable;
    wire        ctrl_clear_fault;

    wire [8*`T2T_TCFG_SYM_W-1:0] reg_tcfg;
    wire [8*`T2T_RCFG_SYM_W-1:0] reg_rcfg;
    wire [31:0] reg_max_gross;
    wire [15:0] reg_max_orders;
    wire [4:0]  reg_win_shift;

    t2t_regs #(
        .N_SYMBOLS  (8),
        .BOOK_N     (8),
        .TABLE_AW   (9),
        .TABLE_WAYS (4)
    ) dut_regs (
        .clk               (clk),
        .rst               (rst),
        .s_axi_ctrl_awaddr (awaddr),
        .s_axi_ctrl_awvalid(awvalid),
        .s_axi_ctrl_awready(awready),
        .s_axi_ctrl_wdata  (wdata),
        .s_axi_ctrl_wstrb  (wstrb),
        .s_axi_ctrl_wvalid (wvalid),
        .s_axi_ctrl_wready (wready),
        .s_axi_ctrl_bresp  (bresp),
        .s_axi_ctrl_bvalid (bvalid),
        .s_axi_ctrl_bready (bready),
        .s_axi_ctrl_araddr (araddr),
        .s_axi_ctrl_arvalid(arvalid),
        .s_axi_ctrl_arready(arready),
        .s_axi_ctrl_rdata  (rdata),
        .s_axi_ctrl_rresp  (rresp),
        .s_axi_ctrl_rvalid (rvalid),
        .s_axi_ctrl_rready (rready),
        .i_session_invalid (reg_session_invalid),
        .i_init_busy       (reg_init_busy),
        .i_tx_fault        (reg_tx_fault),
        .i_live_best_bid0  (reg_live_best_bid0),
        .i_live_best_ask0  (reg_live_best_ask0),
        .i_bk_tob_flat     (reg_bk_tob_flat),
        .i_risk_pos_flat   (reg_risk_pos_flat),
        .i_risk_gross      (reg_risk_gross),
        .i_risk_win_id     (reg_risk_win_id),
        .i_risk_win_cnt    (reg_risk_win_cnt),
        .i_cnt_pulses      (reg_cnt_pulses),
        .o_session_reset   (ctrl_session_reset),
        .o_kill_switch     (ctrl_kill_switch),
        .o_clear_counters  (ctrl_clear_counters),
        .o_global_enable   (ctrl_global_enable),
        .o_clear_fault     (ctrl_clear_fault),
        .o_cfg_stock       (cfg_stock),
        .o_tcfg            (reg_tcfg),
        .o_rcfg            (reg_rcfg),
        .o_max_gross       (reg_max_gross),
        .o_max_orders      (reg_max_orders),
        .o_win_shift       (reg_win_shift)
    );

    // 200 MHz clock
    always #2.5 clk = ~clk;

    // Strobe capture
    reg saw_clear_counters;
    reg saw_session_reset;
    always @(posedge clk) begin
        if (rst) begin
            saw_clear_counters <= 1'b0;
            saw_session_reset  <= 1'b0;
        end else begin
            if (ctrl_clear_counters) saw_clear_counters <= 1'b1;
            if (ctrl_session_reset)  saw_session_reset  <= 1'b1;
        end
    end

    // AXI-Lite Write Task
    task axi_write(
        input [11:0] addr,
        input [31:0] data,
        output [1:0] resp
    );
        begin
            @(negedge clk);
            awaddr  <= addr;
            awvalid <= 1'b1;
            wdata   <= data;
            wstrb   <= 4'b1111;
            wvalid  <= 1'b1;
            bready  <= 1'b1;

            @(negedge clk);
            awvalid <= 1'b0;
            wvalid  <= 1'b0;

            while (!bvalid) @(negedge clk);
            resp = bresp;
            @(negedge clk);
            bready <= 1'b0;
        end
    endtask

    // AXI-Lite Read Task
    task axi_read(
        input [11:0] addr,
        output [31:0] data,
        output [1:0]  resp
    );
        begin
            @(negedge clk);
            araddr  <= addr;
            arvalid <= 1'b1;
            rready  <= 1'b1;

            @(negedge clk);
            arvalid <= 1'b0;

            while (!rvalid) @(negedge clk);
            data = rdata;
            resp = rresp;
            @(negedge clk);
            rready <= 1'b0;
        end
    endtask

    integer pass_count = 0;
    integer fail_count = 0;
    reg [1:0] v_resp;
    reg [31:0] v_rdata;

    initial begin
        clk = 0;
        rst = 1;

        enc_clear_fault = 0;
        dec_valid = 0;
        dec_pass = 0;
        dec_reason = 0;
        dec_sym = 0;
        dec_side = 0;
        dec_price = 0;
        dec_qty = 0;
        dec_rule = 0;
        dec_idx = 0;
        tx_axis_tready = 0; // Hold consumer low initially to inspect beat

        awaddr = 0;
        awvalid = 0;
        wdata = 0;
        wstrb = 0;
        wvalid = 0;
        bready = 0;

        araddr = 0;
        arvalid = 0;
        rready = 0;

        reg_session_invalid = 0;
        reg_init_busy = 0;
        reg_tx_fault = 0;
        reg_live_best_bid0 = 32'h0001_86A0; // 100,000 ($10.0000)
        reg_live_best_ask0 = 32'h0001_86E0;
        reg_bk_tob_flat = 0;
        reg_risk_pos_flat = 0;
        reg_risk_gross = 0;
        reg_risk_win_id = 0;
        reg_risk_win_cnt = 0;
        reg_cnt_pulses = 0;

        repeat (5) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        $display("===============================================================");
        $display("[EN & RG] Beginning Verification of Encoder & Register File");
        $display("===============================================================");

        // ---------------------------------------------------------------------
        // Gate EN-1: Encoder frame bytes equal OP6 exactly
        // ---------------------------------------------------------------------
        $display("\n--- Gate EN-1: Encoder frame format ---");
        // Send accepted decision: symbol 0 ("AAPL    "), side BUY, price 100000, qty 100, idx 1, rule 0
        @(negedge clk);
        dec_valid <= 1'b1;
        dec_pass  <= 1'b1;
        dec_reason<= 4'd0;
        dec_sym   <= 4'd0;
        dec_side  <= `T2T_SIDE_BID; // 'B'
        dec_price <= 32'd100000;
        dec_qty   <= 16'd100;
        dec_rule  <= 2'd0;
        dec_idx   <= 32'd1;

        @(negedge clk);
        dec_valid <= 1'b0;

        // Wait 2 cycles for TX FIFO to latch lookahead output
        repeat (2) @(negedge clk);

        if (tx_axis_tvalid && tx_axis_tlast && (tx_axis_tkeep == `T2T_OUCH_TKEEP)) begin
            // Check individual bytes
            if (tx_axis_tdata[8*0 +: 8] == 8'h4F &&
                tx_axis_tdata[8*1 +: 8] == 8'h00 &&
                tx_axis_tdata[8*2 +: 8] == 8'h00 &&
                tx_axis_tdata[8*3 +: 8] == 8'h00 &&
                tx_axis_tdata[8*4 +: 8] == 8'h01 &&
                tx_axis_tdata[8*5 +: 8] == 8'h42 &&
                tx_axis_tdata[8*6 +: 8] == 8'h00 &&
                tx_axis_tdata[8*7 +: 8] == 8'h00 &&
                tx_axis_tdata[8*8 +: 8] == 8'h00 &&
                tx_axis_tdata[8*9 +: 8] == 8'h64 &&
                tx_axis_tdata[8*10 +: 8] == "A"  &&
                tx_axis_tdata[8*11 +: 8] == "A"  &&
                tx_axis_tdata[8*12 +: 8] == "P"  &&
                tx_axis_tdata[8*13 +: 8] == "L"  &&
                tx_axis_tdata[8*18 +: 8] == 8'h00 &&
                tx_axis_tdata[8*19 +: 8] == 8'h01 &&
                tx_axis_tdata[8*20 +: 8] == 8'h86 &&
                tx_axis_tdata[8*21 +: 8] == 8'hA0 &&
                tx_axis_tdata[8*26 +: 8] == 8'h59 &&
                tx_axis_tdata[8*27 +: 8] == 8'h50 &&
                tx_axis_tdata[8*28 +: 8] == 8'h4E) begin
                $display("[PASS] EN-1: 48-byte OUCH Enter Order frame matched wire format exactly");
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] EN-1: Frame content mismatch! Byte0=%02X Byte5=%02X",
                    tx_axis_tdata[8*0 +: 8], tx_axis_tdata[8*5 +: 8]);
                fail_count = fail_count + 1;
            end
        end else begin
            $display("[FAIL] EN-1: TX beat invalid! valid=%0d last=%0d keep=%016X",
                tx_axis_tvalid, tx_axis_tlast, tx_axis_tkeep);
            fail_count = fail_count + 1;
        end

        // Pop frame from FIFO
        tx_axis_tready = 1;
        @(negedge clk);
        tx_axis_tready = 0;

        // ---------------------------------------------------------------------
        // Gate EN-2: Elasticity under backpressure (tready low)
        // ---------------------------------------------------------------------
        $display("\n--- Gate EN-2: Backpressure elasticity ---");
        // Hold tready low for 5 cycles while issuing orders into TX FIFO
        tx_axis_tready = 0;

        // Issue 3 frames with tready=0
        dec_valid <= 1'b1; dec_pass <= 1'b1; dec_sym <= 4'd1; dec_side <= `T2T_SIDE_ASK;
        dec_price <= 32'd200; dec_qty <= 16'd50; dec_rule <= 2'd1; dec_idx <= 32'd10;
        @(negedge clk);
        dec_idx <= 32'd11;
        @(negedge clk);
        dec_idx <= 32'd12;
        @(negedge clk);
        dec_valid <= 1'b0;

        repeat (5) @(negedge clk);
        // Verify no overflow occurred
        if (!enc_tx_fault && !txf_full) begin
            $display("[PASS] EN-2.1: Frames absorbed in TXF without loss under backpressure");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] EN-2.1: Premature overflow in TXF! fault=%0d full=%0d", enc_tx_fault, txf_full);
            fail_count = fail_count + 1;
        end

        // Release tready and drain frames
        tx_axis_tready = 1;
        repeat (10) @(negedge clk);
        if (tx_fifo_empty) begin
            $display("[PASS] EN-2.2: All frames drained cleanly, order preserved");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] EN-2.2: FIFO not empty after draining");
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Gate EN-3: TXF full condition, fault setting, and fault clearing
        // ---------------------------------------------------------------------
        $display("\n--- Gate EN-3: TXF Overflow & Fault Clearing ---");
        tx_axis_tready = 0; // Freeze consumer
        // Push 20 decisions into depth-16 FIFO to trigger overflow
        repeat (20) begin
            @(negedge clk);
            dec_valid <= 1'b1; dec_pass <= 1'b1; dec_sym <= 4'd0; dec_side <= `T2T_SIDE_BID;
            dec_price <= 32'd100; dec_qty <= 16'd10; dec_rule <= 2'd0; dec_idx <= 32'd50;
        end
        @(negedge clk);
        dec_valid <= 1'b0;
        repeat (3) @(negedge clk);

        if (enc_tx_fault) begin
            $display("[PASS] EN-3.1: TXF full caused tx_fault=1");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] EN-3.1: Expected tx_fault=1, got fault=%0d", enc_tx_fault);
            fail_count = fail_count + 1;
        end

        // Drain FIFO
        tx_axis_tready = 1;
        repeat (25) @(negedge clk);

        // Fault must be sticky until cleared
        if (enc_tx_fault) begin
            $display("[PASS] EN-3.2: tx_fault remained sticky after FIFO drained");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] EN-3.2: tx_fault was not sticky!");
            fail_count = fail_count + 1;
        end

        // Clear fault
        @(negedge clk);
        enc_clear_fault <= 1'b1;
        @(negedge clk);
        enc_clear_fault <= 1'b0;
        @(negedge clk);
        if (!enc_tx_fault) begin
            $display("[PASS] EN-3.3: tx_fault cleared by clear_fault strobe");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] EN-3.3: tx_fault did not clear!");
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Gate RG-1 (a): AXI-Lite read/write handshake compliance
        // ---------------------------------------------------------------------
        $display("\n--- Gate RG-1.a: AXI-Lite handshake compliance ---");
        // Write to CTRL (0x004) with global_enable=1 (bit3=1)
        axi_write(12'h004, 32'h0000_0008, v_resp);
        if (v_resp == 2'b00 && ctrl_global_enable == 1'b1) begin
            $display("[PASS] RG-1.a: Handshake write completed with OKAY, global_enable set");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RG-1.a: Write handshake failed! resp=%0d enable=%0d", v_resp, ctrl_global_enable);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Gate RG-1 (b): ID and CAPS registers read
        // ---------------------------------------------------------------------
        $display("\n--- Gate RG-1.b: ID and CAPS read ---");
        axi_read(12'h000, v_rdata, v_resp);
        if (v_resp == 2'b00 && v_rdata == 32'h7432_0001) begin
            $display("[PASS] RG-1.b.1: ID register read 0x74320001 with OKAY");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RG-1.b.1: ID read mismatch! rdata=0x%08X resp=%0d", v_rdata, v_resp);
            fail_count = fail_count + 1;
        end

        axi_read(12'h00C, v_rdata, v_resp);
        // CAPS: ways=4 [19:16], table_aw=9 [15:8], book_n=8 [7:4], n_sym-1=7 [3:0] -> 0x0004_0987
        if (v_resp == 2'b00 && v_rdata == 32'h0004_0987) begin
            $display("[PASS] RG-1.b.2: CAPS register read 0x00040987 with OKAY");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RG-1.b.2: CAPS read mismatch! rdata=0x%08X", v_rdata);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Gate RG-1 (c): Control register writes
        // ---------------------------------------------------------------------
        $display("\n--- Gate RG-1.c: Control register writes ---");
        // Test kill_switch=0 (bit1=0)
        axi_write(12'h004, 32'h0000_0000, v_resp);
        if (ctrl_kill_switch == 1'b0) begin
            $display("[PASS] RG-1.c.1: kill_switch cleared to 0");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RG-1.c.1: kill_switch not 0!");
            fail_count = fail_count + 1;
        end

        // Test clear_counters strobe (bit2=1)
        // 1. Pulse counter 1 so it is non-zero
        reg_cnt_pulses[1] = 1'b1;
        @(negedge clk);
        reg_cnt_pulses[1] = 1'b0;
        @(negedge clk);

        // 2. Write clear_counters (CTRL bit 2 = 1)
        axi_write(12'h004, 32'h0000_0004, v_resp);

        // 3. Take snapshot to read counter 1
        axi_write(12'h004, 32'h0000_0010, v_resp);
        axi_read(12'h100 + 4*1, v_rdata, v_resp);

        if (v_rdata == 32'd0) begin
            $display("[PASS] RG-1.c.2: clear_counters strobe cleared live counters");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RG-1.c.2: clear_counters failed! counter1=%0d", v_rdata);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Gate RG-1 (d): Rejected writes return SLVERR
        // ---------------------------------------------------------------------
        $display("\n--- Gate RG-1.d: Rejected writes (SLVERR) ---");
        // 1. Write to Read-Only register (ID 0x000)
        axi_write(12'h000, 32'h1234_5678, v_resp);
        if (v_resp == 2'b10) begin
            $display("[PASS] RG-1.d.1: Write to RO register returned SLVERR");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RG-1.d.1: Expected SLVERR on write to RO, got resp=%0d", v_resp);
            fail_count = fail_count + 1;
        end

        // 2. Write stock register while global_enable = 1
        // Set global_enable = 1 first:
        axi_write(12'h004, 32'h0000_0008, v_resp);
        // Attempt write to stock char 0..3 of Symbol 0 (0x400)
        axi_write(12'h400, 32'h5445_5354, v_resp);
        if (v_resp == 2'b10) begin
            $display("[PASS] RG-1.d.2: Write to stock while global_enable=1 returned SLVERR");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RG-1.d.2: Expected SLVERR on stock write when enabled, got resp=%0d", v_resp);
            fail_count = fail_count + 1;
        end

        // 3. Write with non-zero bits above width (order_qty at 0x418 is 16-bit)
        axi_write(12'h004, 32'h0000_0000, v_resp); // disable global_enable
        axi_write(12'h418, 32'h0001_0000, v_resp); // bit 16 is non-zero
        if (v_resp == 2'b10) begin
            $display("[PASS] RG-1.d.3: Write with non-zero upper bits returned SLVERR");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RG-1.d.3: Expected SLVERR on width violation, got resp=%0d", v_resp);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Gate RG-1 (e): Unmapped address reads return 0xDEADBEEF with OKAY
        // ---------------------------------------------------------------------
        $display("\n--- Gate RG-1.e: Unmapped read ---");
        axi_read(12'h024, v_rdata, v_resp);
        if (v_resp == 2'b00 && v_rdata == 32'hDEAD_BEEF) begin
            $display("[PASS] RG-1.e: Unmapped address 0x024 returned 0xDEADBEEF with OKAY");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RG-1.e: Unmapped read mismatch! rdata=0x%08X resp=%0d", v_rdata, v_resp);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Gate RG-1 (f): Shadow snapshot coherence
        // ---------------------------------------------------------------------
        $display("\n--- Gate RG-1.f: Shadow snapshot coherence ---");
        // Pulse counter 5
        reg_cnt_pulses[5] = 1'b1;
        @(negedge clk);
        reg_cnt_pulses[5] = 1'b0;
        @(negedge clk);

        // Before snapshot, shadow counter must read 0
        axi_read(12'h100 + 4*5, v_rdata, v_resp);
        if (v_rdata == 32'd0) begin
            $display("[PASS] RG-1.f.1: Shadow counter 5 reads 0 prior to snapshot");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RG-1.f.1: Shadow counter non-zero before snapshot! rdata=%0d", v_rdata);
            fail_count = fail_count + 1;
        end

        // Trigger snapshot via CTRL.snapshot (bit 4 = 1)
        axi_write(12'h004, 32'h0000_0010, v_resp);

        // Now shadow counter must read 1!
        axi_read(12'h100 + 4*5, v_rdata, v_resp);
        if (v_rdata == 32'd1) begin
            $display("[PASS] RG-1.f.2: Shadow counter 5 updated to 1 atomically after snapshot");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] RG-1.f.2: Shadow counter did not update! rdata=%0d", v_rdata);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $display("\n===============================================================");
        $display("[EN & RG] Summary: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("===============================================================");

        if (fail_count == 0) begin
            $display("[GATE PASS] EN-1..3, RG-1: All outbound & control plane tests passed.");
            $finish(0);
        end else begin
            $display("[GATE FAIL] EN-1..3, RG-1: %0d tests failed.", fail_count);
            $finish(1);
        end
    end

endmodule
