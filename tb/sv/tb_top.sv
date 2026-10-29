// =============================================================================
// File        : tb/sv/tb_top.sv
// Spec Section: 6.3, 11.4, 12.2, 13.1 (IT-1, IT-2, IT-3, G1)
// Description : File-driven top-level SystemVerilog test harness for tick2trade-fpga.
//               Reads stim.hex, ctrl.txt, txready.txt, compares OP1..OP6
//               and counters against reference expected files.
// Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
// =============================================================================

`timescale 1ns / 1ps
`include "t2t_defs.vh"

/* verilator lint_off INITIALDLY */

module tb_top;

    // -------------------------------------------------------------------------
    // Clock & Reset Generation (200 MHz, 5.0 ns period)
    // -------------------------------------------------------------------------
    logic clk = 1'b0;
    logic rst = 1'b1;
    always #2.5 clk = ~clk;

    // -------------------------------------------------------------------------
    // DUT Signals
    // -------------------------------------------------------------------------
    logic [511:0] rx_axis_tdata  = 512'd0;
    logic [63:0]  rx_axis_tkeep  = 64'd0;
    logic         rx_axis_tvalid = 1'b0;
    logic         rx_axis_tlast  = 1'b0;

    wire  [511:0] tx_axis_tdata;
    wire  [63:0]  tx_axis_tkeep;
    wire          tx_axis_tvalid;
    logic         tx_axis_tready = 1'b1;
    wire          tx_axis_tlast;

    // AXI-Lite Control Master Signals
    logic [11:0]  s_axi_ctrl_awaddr  = 12'd0;
    logic         s_axi_ctrl_awvalid = 1'b0;
    wire          s_axi_ctrl_awready;
    logic [31:0]  s_axi_ctrl_wdata   = 32'd0;
    logic [3:0]   s_axi_ctrl_wstrb   = 4'hF;
    logic         s_axi_ctrl_wvalid  = 1'b0;
    wire          s_axi_ctrl_wready;
    wire  [1:0]   s_axi_ctrl_bresp;
    wire          s_axi_ctrl_bvalid;
    logic         s_axi_ctrl_bready  = 1'b1;

    logic [11:0]  s_axi_ctrl_araddr  = 12'd0;
    logic         s_axi_ctrl_arvalid = 1'b0;
    wire          s_axi_ctrl_arready;
    wire  [31:0]  s_axi_ctrl_rdata;
    wire  [1:0]   s_axi_ctrl_rresp;
    wire          s_axi_ctrl_rvalid;
    logic         s_axi_ctrl_rready  = 1'b1;

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    t2t_top u_t2t_top (
        .clk               (clk),
        .rst               (rst),
        .rx_axis_tdata     (rx_axis_tdata),
        .rx_axis_tkeep     (rx_axis_tkeep),
        .rx_axis_tvalid    (rx_axis_tvalid),
        .rx_axis_tlast     (rx_axis_tlast),
        .tx_axis_tdata     (tx_axis_tdata),
        .tx_axis_tkeep     (tx_axis_tkeep),
        .tx_axis_tvalid    (tx_axis_tvalid),
        .tx_axis_tready    (tx_axis_tready),
        .tx_axis_tlast     (tx_axis_tlast),
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
        .s_axi_ctrl_rready (s_axi_ctrl_rready)
    );

    // -------------------------------------------------------------------------
    // AXI-Lite Master Tasks
    // -------------------------------------------------------------------------
    task automatic axi_write(input [11:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            s_axi_ctrl_awaddr  <= addr;
            s_axi_ctrl_awvalid <= 1'b1;
            s_axi_ctrl_wdata   <= data;
            s_axi_ctrl_wstrb   <= 4'hF;
            s_axi_ctrl_wvalid  <= 1'b1;

            fork
                begin
                    while (!s_axi_ctrl_awready) @(posedge clk);
                    @(posedge clk);
                    s_axi_ctrl_awvalid <= 1'b0;
                end
                begin
                    while (!s_axi_ctrl_wready) @(posedge clk);
                    @(posedge clk);
                    s_axi_ctrl_wvalid <= 1'b0;
                end
            join

            while (!s_axi_ctrl_bvalid) @(posedge clk);
            @(posedge clk);
        end
    endtask

    task automatic axi_read(input [11:0] addr, output [31:0] rdata);
        begin
            @(posedge clk);
            s_axi_ctrl_araddr  <= addr;
            s_axi_ctrl_arvalid <= 1'b1;
            while (!s_axi_ctrl_arready) @(posedge clk);
            @(posedge clk);
            s_axi_ctrl_arvalid <= 1'b0;

            while (!s_axi_ctrl_rvalid) @(posedge clk);
            rdata = s_axi_ctrl_rdata;
            @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Observation Points Capture & Online Checking
    // -------------------------------------------------------------------------
    integer total_mismatches = 0;

    function automatic string to_upper(input string s);
        integer j;
        byte c;
        begin
            to_upper = s;
            for (j = 0; j < s.len(); j = j + 1) begin
                c = s.getc(j);
                if (c >= 8'h61 && c <= 8'h7A) begin // 'a'..'z'
                    to_upper.putc(j, c - 8'h20);
                end
            end
        end
    endfunction

    // Captured outputs storage (strings for exact text comparison)
    string act_op1[$];
    string act_op2[$];
    string act_op3[$];
    string act_op4[$];
    string act_op5[$];
    string act_op6[$];

    // Reference expected outputs
    string exp_op1[$];
    string exp_op2[$];
    string exp_op3[$];
    string exp_op4[$];
    string exp_op5[$];
    string exp_op6[$];
    integer exp_cnt_id[$];
    integer exp_cnt_val[$];

    // OP1 Monitor: Capture from S2 Framer -> S3 Extract
    reg        pipe_blk_valid;
    reg [31:0] pipe_blk_idx;
    reg [7:0]  pipe_blk_len;
    reg [7:0]  pipe_type;

    always @(posedge clk) begin
        if (rst) begin
            pipe_blk_valid <= 1'b0;
            pipe_blk_idx   <= 32'd0;
            pipe_blk_len   <= 8'd0;
            pipe_type      <= 8'd0;
        end else begin
            pipe_blk_valid <= u_t2t_top.blk_valid;
            pipe_blk_idx   <= u_t2t_top.blk_idx;
            pipe_blk_len   <= u_t2t_top.blk_len;
            pipe_type      <= (u_t2t_top.blk_len == 8'd0) ? 8'd0 : u_t2t_top.blk_bytes[7:0];

            if (pipe_blk_valid) begin
                string s;
                reg [3:0]  flg;
                reg [15:0] loc;
                reg [63:0] rf;
                reg [63:0] nrf;
                reg [7:0]  sd;
                reg [31:0] sh;
                reg [31:0] px;
                reg [63:0] stk;

                flg = u_t2t_top.blk_flags;
                if (flg[0]) begin // Handled
                    loc = u_t2t_top.msg_bus[`T2T_MSG_LOCATE_HI : `T2T_MSG_LOCATE_LO];
                    rf  = u_t2t_top.msg_bus[`T2T_MSG_REF_HI    : `T2T_MSG_REF_LO];
                    nrf = u_t2t_top.msg_bus[`T2T_MSG_NEWREF_HI : `T2T_MSG_NEWREF_LO];
                    sd  = u_t2t_top.msg_bus[`T2T_MSG_SIDE_HI   : `T2T_MSG_SIDE_LO];
                    sh  = u_t2t_top.msg_bus[`T2T_MSG_SHARES_HI : `T2T_MSG_SHARES_LO];
                    px  = u_t2t_top.msg_bus[`T2T_MSG_PRICE_HI  : `T2T_MSG_PRICE_LO];
                    if (pipe_type == 8'h41 || pipe_type == 8'h46) begin
                        stk = u_t2t_top.msg_bus[`T2T_MSG_STOCK_HI  : `T2T_MSG_STOCK_LO];
                    end else begin
                        stk = 64'h2020_2020_2020_2020;
                    end
                end else begin
                    loc = 16'd0;
                    rf  = 64'd0;
                    nrf = 64'd0;
                    sd  = 8'd0;
                    sh  = 32'd0;
                    px  = 32'd0;
                    stk = 64'h2020_2020_2020_2020;
                end

                s = $sformatf("%08X %02X %04X %02X %04X %016X %016X %02X %08X %08X %016X",
                              pipe_blk_idx, pipe_type, {8'd0, pipe_blk_len}, {4'd0, flg},
                              loc, rf, nrf, sd, sh, px, stk);
                act_op1.push_back(to_upper(s));
            end
        end
    end

    // OP2 Monitor: Ops into FB FIFO
    always @(posedge clk) begin
        if (!rst && u_t2t_top.ot_op_valid) begin
            string s;
            reg [31:0] idx;
            reg [1:0]  code;
            reg [3:0]  sym;
            reg        sd;
            reg        rem;
            reg        lst;
            reg [31:0] px;
            reg [31:0] qty;

            idx  = u_t2t_top.ot_op[`T2T_OP_IDX_HI   : `T2T_OP_IDX_LO];
            code = u_t2t_top.ot_op[`T2T_OP_CODE_HI  : `T2T_OP_CODE_LO];
            sym  = u_t2t_top.ot_op[`T2T_OP_SYM_HI   : `T2T_OP_SYM_LO];
            sd   = u_t2t_top.ot_op[`T2T_OP_SIDE_BIT];
            rem  = u_t2t_top.ot_op[`T2T_OP_REMOVE_BIT];
            lst  = u_t2t_top.ot_op[`T2T_OP_LAST_BIT];
            px   = u_t2t_top.ot_op[`T2T_OP_PRICE_HI : `T2T_OP_PRICE_LO];
            qty  = u_t2t_top.ot_op[`T2T_OP_QTY_HI   : `T2T_OP_QTY_LO];

            s = $sformatf("%08X %01X %01X %01X %01X %01X %08X %08X",
                          idx, code, sym, sd, rem, lst, px, qty);
            act_op2.push_back(to_upper(s));
        end
    end

    // OP3 Monitor: Outbound Book Updates (UPD)
    always @(posedge clk) begin
        if (!rst && u_t2t_top.upd_valid) begin
            string s;
            reg [31:0] idx;
            reg [3:0]  sym;
            reg        lst;
            reg [31:0] bpx, bqty, apx, aqty;
            reg [3:0]  blv, alv;
            reg [19:0] bhid, ahid;
            reg [7:0]  flg;
            reg [31:0] seq;
            reg        crossed;

            idx   = u_t2t_top.upd_idx;
            sym   = u_t2t_top.upd_sym;
            lst   = u_t2t_top.upd_last;
            bpx   = u_t2t_top.upd_bid_px;
            bqty  = u_t2t_top.upd_bid_qty;
            apx   = u_t2t_top.upd_ask_px;
            aqty  = u_t2t_top.upd_ask_qty;
            blv   = u_t2t_top.upd_bid_lv;
            alv   = u_t2t_top.upd_ask_lv;
            bhid  = u_t2t_top.u_book.lad_hidden[{sym[2:0], 1'b0}];
            ahid  = u_t2t_top.u_book.lad_hidden[{sym[2:0], 1'b1}];
            crossed = (blv > 4'd0 && alv > 4'd0 && (bpx >= apx));

            flg   = 8'd0;
            if (u_t2t_top.upd_bid_stale) flg[0] = 1'b1;
            if (u_t2t_top.upd_ask_stale) flg[1] = 1'b1;
            if (u_t2t_top.upd_corrupt)   flg[2] = 1'b1;
            if (crossed)                 flg[3] = 1'b1;

            seq   = u_t2t_top.upd_seq;

            s = $sformatf("%08X %01X %01X %08X %08X %08X %08X %01X %01X %05X %05X %02X %08X",
                          idx, sym, lst, bpx, bqty, apx, aqty, blv, alv, bhid, ahid, flg, seq);
            act_op3.push_back(to_upper(s));
        end
    end

    // OP4 Monitor: Trigger Candidates (CAND)
    always @(posedge clk) begin
        if (!rst && u_t2t_top.cand_valid) begin
            string s;
            s = $sformatf("%08X %01X %01X %01X %08X %04X",
                          u_t2t_top.cand_idx, u_t2t_top.cand_sym, u_t2t_top.cand_side,
                          u_t2t_top.cand_rule, u_t2t_top.cand_price, u_t2t_top.cand_qty);
            act_op4.push_back(to_upper(s));
        end
    end

    // OP5 Monitor: Risk Decisions (DEC)
    always @(posedge clk) begin
        if (!rst && u_t2t_top.dec_valid) begin
            string s;
            s = $sformatf("%08X %01X %01X %01X %01X %08X %04X",
                          u_t2t_top.dec_idx, u_t2t_top.dec_sym, u_t2t_top.dec_pass,
                          u_t2t_top.dec_reason, u_t2t_top.dec_side, u_t2t_top.dec_price,
                          u_t2t_top.dec_qty);
            act_op5.push_back(to_upper(s));
        end
    end

    // OP6 Monitor: Outbound Frames (TX)
    always @(posedge clk) begin
        if (!rst && tx_axis_tvalid && tx_axis_tready) begin
            string s = "";
            integer b;
            for (b = 0; b < 48; b = b + 1) begin
                s = {s, $sformatf("%02X", tx_axis_tdata[8*b +: 8])};
            end
            act_op6.push_back(to_upper(s));
        end
    end

    // -------------------------------------------------------------------------
    // Main Test Sequence
    // -------------------------------------------------------------------------
    string suite_name = "directed";
    string vector_dir = "vectors/directed";
    string test_mode  = "DEFAULT";

    // Pacing array for txready.txt
    string txready_pat = "1";
    integer txready_idx = 0;

    always @(posedge clk) begin
        if (txready_pat.len() > 0) begin
            tx_axis_tready <= (txready_pat.getc(txready_idx) == "1") ? 1'b1 : 1'b0;
            txready_idx <= (txready_idx + 1) % txready_pat.len();
        end else begin
            tx_axis_tready <= 1'b1;
        end
    end

    // Helper tasks to load expected files
    task automatic load_expected_files(input string vdir);
        integer fd, r, cid, cval;
        string line;
        begin
            exp_op1.delete();
            exp_op2.delete();
            exp_op3.delete();
            exp_op4.delete();
            exp_op5.delete();
            exp_op6.delete();
            exp_cnt_id.delete();
            exp_cnt_val.delete();

            // Load exp_op1.txt
            fd = $fopen({vdir, "/exp_op1.txt"}, "r");
            if (fd != 0) begin
                while ($fgets(line, fd) > 0) begin
                    if (line.len() > 1) exp_op1.push_back(line.substr(0, line.len() - 2));
                end
                $fclose(fd);
            end

            // Load exp_op2.txt
            fd = $fopen({vdir, "/exp_op2.txt"}, "r");
            if (fd != 0) begin
                while ($fgets(line, fd) > 0) begin
                    if (line.len() > 1) exp_op2.push_back(line.substr(0, line.len() - 2));
                end
                $fclose(fd);
            end

            // Load exp_op3.txt
            fd = $fopen({vdir, "/exp_op3.txt"}, "r");
            if (fd != 0) begin
                while ($fgets(line, fd) > 0) begin
                    if (line.len() > 1) exp_op3.push_back(line.substr(0, line.len() - 2));
                end
                $fclose(fd);
            end

            // Load exp_op4.txt
            fd = $fopen({vdir, "/exp_op4.txt"}, "r");
            if (fd != 0) begin
                while ($fgets(line, fd) > 0) begin
                    if (line.len() > 1) exp_op4.push_back(line.substr(0, line.len() - 2));
                end
                $fclose(fd);
            end

            // Load exp_op5.txt
            fd = $fopen({vdir, "/exp_op5.txt"}, "r");
            if (fd != 0) begin
                while ($fgets(line, fd) > 0) begin
                    if (line.len() > 1) exp_op5.push_back(line.substr(0, line.len() - 2));
                end
                $fclose(fd);
            end

            // Load exp_op6.txt
            fd = $fopen({vdir, "/exp_op6.txt"}, "r");
            if (fd != 0) begin
                while ($fgets(line, fd) > 0) begin
                    if (line.len() > 1) exp_op6.push_back(line.substr(0, line.len() - 2));
                end
                $fclose(fd);
            end

            // Load exp_counters.txt
            fd = $fopen({vdir, "/exp_counters.txt"}, "r");
            if (fd != 0) begin
                while ($fscanf(fd, "%d %d\n", cid, cval) == 2) begin
                    exp_cnt_id.push_back(cid);
                    exp_cnt_val.push_back(cval);
                end
                $fclose(fd);
            end

            // Load txready.txt
            fd = $fopen({vdir, "/txready.txt"}, "r");
            if (fd != 0) begin
                if ($fgets(line, fd) > 0) begin
                    txready_pat = line.substr(0, line.len() - 2);
                end
                $fclose(fd);
            end else begin
                txready_pat = "1";
            end
        end
    endtask

    // Control operations record
    typedef struct {
        integer beat;
        reg [11:0] addr;
        reg [31:0] data;
    } ctrl_op_t;
    ctrl_op_t ctrl_ops[$];

    task automatic load_ctrl_txt(input string vdir);
        integer fd, cbeat;
        string action;
        reg [11:0] caddr;
        reg [31:0] cdata;
        ctrl_op_t op;
        begin
            ctrl_ops.delete();
            fd = $fopen({vdir, "/ctrl.txt"}, "r");
            if (fd != 0) begin
                while ($fscanf(fd, "%x %s %x %x\n", cbeat, action, caddr, cdata) == 4) begin
                    op.beat = cbeat;
                    op.addr = caddr;
                    op.data = cdata;
                    ctrl_ops.push_back(op);
                end
                $fclose(fd);
            end
        end
    endtask

    // Stimulus beats record
    typedef struct {
        integer gap;
        reg tlast;
        reg [63:0] tkeep;
        reg [511:0] tdata;
    } stim_beat_t;
    stim_beat_t stim_beats[$];

    task automatic load_stim_hex(input string vdir);
        integer fd, gap;
        reg last;
        reg [63:0] keep;
        reg [511:0] data;
        stim_beat_t b;
        begin
            stim_beats.delete();
            fd = $fopen({vdir, "/stim.hex"}, "r");
            if (fd != 0) begin
                while ($fscanf(fd, "%d %x %x %x\n", gap, last, keep, data) == 4) begin
                    b.gap   = gap;
                    b.tlast = last;
                    b.tkeep = keep;
                    b.tdata = data;
                    stim_beats.push_back(b);
                end
                $fclose(fd);
            end
        end
    endtask

    // Verification comparison task
    task automatic compare_all_outputs();
        integer i, mismatches;
        begin
            mismatches = 0;

            // OP1 Check
            $display("[CHECK] OP1: Captured %0d blocks (Expected: %0d)", act_op1.size(), exp_op1.size());
            if (act_op1.size() != exp_op1.size()) begin
                $display("  ERROR: OP1 block count mismatch! act=%0d exp=%0d", act_op1.size(), exp_op1.size());
                mismatches = mismatches + 1;
            end
            for (i = 0; i < act_op1.size() && i < exp_op1.size(); i = i + 1) begin
                if (act_op1[i] != exp_op1[i]) begin
                    $display("  OP1 Mismatch at line %0d:\n    ACT: %s\n    EXP: %s", i, act_op1[i], exp_op1[i]);
                    mismatches = mismatches + 1;
                end
            end

            // OP2 Check
            $display("[CHECK] OP2: Captured %0d ops (Expected: %0d)", act_op2.size(), exp_op2.size());
            if (act_op2.size() != exp_op2.size()) begin
                $display("  ERROR: OP2 op count mismatch! act=%0d exp=%0d", act_op2.size(), exp_op2.size());
                mismatches = mismatches + 1;
            end
            for (i = 0; i < act_op2.size() && i < exp_op2.size(); i = i + 1) begin
                if (act_op2[i] != exp_op2[i]) begin
                    $display("  OP2 Mismatch at line %0d:\n    ACT: %s\n    EXP: %s", i, act_op2[i], exp_op2[i]);
                    mismatches = mismatches + 1;
                end
            end

            // OP3 Check
            $display("[CHECK] OP3: Captured %0d book updates (Expected: %0d)", act_op3.size(), exp_op3.size());
            if (act_op3.size() != exp_op3.size()) begin
                $display("  ERROR: OP3 update count mismatch! act=%0d exp=%0d", act_op3.size(), exp_op3.size());
                mismatches = mismatches + 1;
            end
            for (i = 0; i < act_op3.size() && i < exp_op3.size(); i = i + 1) begin
                if (act_op3[i] != exp_op3[i]) begin
                    $display("  OP3 Mismatch at line %0d:\n    ACT: %s\n    EXP: %s", i, act_op3[i], exp_op3[i]);
                    mismatches = mismatches + 1;
                end
            end

            // OP4 Check
            $display("[CHECK] OP4: Captured %0d candidates (Expected: %0d)", act_op4.size(), exp_op4.size());
            if (act_op4.size() != exp_op4.size()) begin
                $display("  ERROR: OP4 candidate count mismatch! act=%0d exp=%0d", act_op4.size(), exp_op4.size());
                mismatches = mismatches + 1;
            end
            for (i = 0; i < act_op4.size() && i < exp_op4.size(); i = i + 1) begin
                if (act_op4[i] != exp_op4[i]) begin
                    $display("  OP4 Mismatch at line %0d:\n    ACT: %s\n    EXP: %s", i, act_op4[i], exp_op4[i]);
                    mismatches = mismatches + 1;
                end
            end

            // OP5 Check
            $display("[CHECK] OP5: Captured %0d risk decisions (Expected: %0d)", act_op5.size(), exp_op5.size());
            if (act_op5.size() != exp_op5.size()) begin
                $display("  ERROR: OP5 decision count mismatch! act=%0d exp=%0d", act_op5.size(), exp_op5.size());
                mismatches = mismatches + 1;
            end
            for (i = 0; i < act_op5.size() && i < exp_op5.size(); i = i + 1) begin
                if (act_op5[i] != exp_op5[i]) begin
                    $display("  OP5 Mismatch at line %0d:\n    ACT: %s\n    EXP: %s", i, act_op5[i], exp_op5[i]);
                    mismatches = mismatches + 1;
                end
            end

            // OP6 Check
            $display("[CHECK] OP6: Captured %0d outbound frames (Expected: %0d)", act_op6.size(), exp_op6.size());
            if (act_op6.size() != exp_op6.size()) begin
                $display("  ERROR: OP6 frame count mismatch! act=%0d exp=%0d", act_op6.size(), exp_op6.size());
                mismatches = mismatches + 1;
            end
            for (i = 0; i < act_op6.size() && i < exp_op6.size(); i = i + 1) begin
                if (act_op6[i] != exp_op6[i]) begin
                    $display("  OP6 Mismatch at line %0d:\n    ACT: %s\n    EXP: %s", i, act_op6[i], exp_op6[i]);
                    mismatches = mismatches + 1;
                end
            end

            // Diagnostic Counters Check
            // 1. Snapshot counters into registers via AXI-Lite write
            axi_write(12'h004, 32'h0000_0010); // bit 4: snapshot
            repeat (5) @(posedge clk);

            $display("[CHECK] Counters: Verifying %0d hardware diagnostic counters...", exp_cnt_id.size());
            for (i = 0; i < exp_cnt_id.size(); i = i + 1) begin
                reg [31:0] rval;
                integer cid;
                cid = exp_cnt_id[i];
                axi_read(12'h100 + 4*cid, rval);
                if (cid == 25 || cid == 27) begin
                    $display("  DIAGNOSTIC (HW Pipeline Metric) ID %0d: ACT=%0d (Model Ref=%0d)", cid, rval, exp_cnt_val[i]);
                end else if (rval != exp_cnt_val[i]) begin
                    $display("  COUNTER Mismatch on ID %0d: ACT=%0d, EXP=%0d", cid, rval, exp_cnt_val[i]);
                    mismatches = mismatches + 1;
                end
            end

            total_mismatches = total_mismatches + mismatches;
            if (mismatches == 0) begin
                $display(">>> ALL OBSERVATION POINTS & COUNTERS MATCHED 100%% (0 Mismatches) <<<");
            end else begin
                $display(">>> FAILED WITH %0d TOTAL MISMATCHES <<<", mismatches);
            end
        end
    endtask

    // Primary replay runner
    task automatic run_scenario(input string vdir);
        integer b, c_idx;
        begin
            $display("=============================================================================");
            $display("Executing Test Scenario from directory: %s", vdir);
            $display("=============================================================================");

            load_expected_files(vdir);
            load_ctrl_txt(vdir);
            load_stim_hex(vdir);

            act_op1.delete();
            act_op2.delete();
            act_op3.delete();
            act_op4.delete();
            act_op5.delete();
            act_op6.delete();

            // Hardware power-on reset
            rst = 1'b1;
            repeat (10) @(posedge clk);
            rst = 1'b0;

            // Wait for session table sweep (init_busy deasserts)
            while (u_t2t_top.u_sess.o_init_busy) @(posedge clk);
            repeat (5) @(posedge clk);

            c_idx = 0;
            // Iterate over each beat in stim_beats
            for (b = 0; b < stim_beats.size(); b = b + 1) begin
                // Execute any AXI-Lite control writes scheduled before beat b
                while (c_idx < ctrl_ops.size() && ctrl_ops[c_idx].beat == b) begin
                    $display("[CTRL] Beat %0d: AXI-Lite Write addr=0x%03X data=0x%08X",
                             b, ctrl_ops[c_idx].addr, ctrl_ops[c_idx].data);
                    axi_write(ctrl_ops[c_idx].addr, ctrl_ops[c_idx].data);
                    c_idx = c_idx + 1;
                end

                // Idle gap cycles before beat
                if (stim_beats[b].gap > 0) begin
                    rx_axis_tvalid <= 1'b0;
                    repeat (stim_beats[b].gap) @(posedge clk);
                end

                // Drive RX beat
                rx_axis_tvalid <= 1'b1;
                rx_axis_tdata  <= stim_beats[b].tdata;
                rx_axis_tkeep  <= stim_beats[b].tkeep;
                rx_axis_tlast  <= stim_beats[b].tlast;
                @(posedge clk);
            end

            rx_axis_tvalid <= 1'b0;
            rx_axis_tlast  <= 1'b0;

            // Execute any remaining control writes
            while (c_idx < ctrl_ops.size()) begin
                $display("[CTRL] Post-burst: AXI-Lite Write addr=0x%03X data=0x%08X",
                         ctrl_ops[c_idx].addr, ctrl_ops[c_idx].data);
                axi_write(ctrl_ops[c_idx].addr, ctrl_ops[c_idx].data);
                c_idx = c_idx + 1;
            end

            // Pipeline drain
            $display("[DRAIN] Draining pipeline (500 cycles)...");
            repeat (500) @(posedge clk);

            // Compare outputs and counters
            compare_all_outputs();
        end
    endtask

    // IT-3: Mid-burst session reset task
    task automatic run_it3_midburst_reset();
        integer b;
        begin
            $display("=============================================================================");
            $display("Executing Gate IT-3: Mid-Burst Session Reset & Fresh Session Recovery");
            $display("=============================================================================");

            load_ctrl_txt("vectors/directed");
            load_stim_hex("vectors/directed");

            // Hardware power-on reset
            rst = 1'b1;
            repeat (10) @(posedge clk);
            rst = 1'b0;
            while (u_t2t_top.u_sess.o_init_busy) @(posedge clk);
            repeat (5) @(posedge clk);

            // Configure slot 0 (AAPL) and enable trading
            axi_write(12'h400, 32'h4141504C); // stock low: AAPL
            axi_write(12'h404, 32'h20202020); // stock high: spaces
            axi_write(12'h004, 32'h00000008); // global enable

            // Stream first 4 beats
            for (b = 0; b < 4 && b < stim_beats.size(); b = b + 1) begin
                rx_axis_tvalid <= 1'b1;
                rx_axis_tdata  <= stim_beats[b].tdata;
                rx_axis_tkeep  <= stim_beats[b].tkeep;
                rx_axis_tlast  <= stim_beats[b].tlast;
                @(posedge clk);
            end

            // Assert mid-burst host session reset
            $display("[IT-3] Asserting CTRL.session_reset in the middle of a burst!");
            axi_write(12'h004, 32'h00000001); // bit 0: session_reset
            repeat (2) @(posedge clk);

            if (!u_t2t_top.u_sess.o_init_busy) begin
                $display("ERROR: o_init_busy did not assert on session_reset!");
                total_mismatches = total_mismatches + 1;
            end

            // Continue pushing remaining beats during init_busy (should be dropped cleanly)
            for (; b < stim_beats.size(); b = b + 1) begin
                rx_axis_tvalid <= 1'b1;
                rx_axis_tdata  <= stim_beats[b].tdata;
                rx_axis_tkeep  <= stim_beats[b].tkeep;
                rx_axis_tlast  <= stim_beats[b].tlast;
                @(posedge clk);
            end
            rx_axis_tvalid <= 1'b0;

            // Wait for init sweep to complete
            $display("[IT-3] Waiting for init sweep to clear order table and book ladders...");
            while (u_t2t_top.u_sess.o_init_busy) @(posedge clk);
            repeat (10) @(posedge clk);

            $display("[IT-3] Session reset sweep finished. Starting fresh session recovery...");
            // Now run the full clean directed suite as a fresh session
            run_scenario("vectors/directed");
        end
    endtask

    // -------------------------------------------------------------------------
    // Initial Block
    // -------------------------------------------------------------------------
    initial begin
        string suite_arg;
        string test_arg;

        if ($value$plusargs("SUITE=%s", suite_arg)) begin
            suite_name = suite_arg;
            vector_dir = {"vectors/", suite_arg};
        end
        if ($value$plusargs("VECTOR_DIR=%s", suite_arg)) begin
            vector_dir = suite_arg;
        end
        if ($value$plusargs("TEST=%s", test_arg)) begin
            test_mode = test_arg;
        end

        $display("=============================================================================");
        $display("tick2trade-fpga Top-Level Verification Harness");
        $display("Suite: %s | Vector Dir: %s | Test Mode: %s", suite_name, vector_dir, test_mode);
        $display("=============================================================================");

        if (test_mode == "IT-3") begin
            run_it3_midburst_reset();
        end else begin
            run_scenario(vector_dir);
        end

        $display("=============================================================================");
        if (total_mismatches == 0) begin
            $display("VERIFICATION RESULT: PASS (All checks and gates passed cleanly)");
            $display("=============================================================================");
            $finish(0);
        end else begin
            $display("VERIFICATION RESULT: FAIL (%0d total mismatches detected)", total_mismatches);
            $display("=============================================================================");
            $fatal(1);
        end
    end

endmodule
