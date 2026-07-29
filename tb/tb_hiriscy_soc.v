`timescale 1ns / 1ps

module tb_hiriscy_soc;

  reg         clk, rst_n, start_pause;
  reg  [11:0] start_pc;
  reg  [1:0]  configuration;
  wire [1:0]  core_status, exceptions;
  wire [31:0] exceptions_pc;

  initial clk = 0;
  always #5 clk = ~clk;

  hiriscy_soc #(.IMEM_DEPTH(1024), .DMEM_DEPTH(256), .INIT_FILE("")) dut (
    .clk(clk), .rst_n(rst_n), .start_pause(start_pause),
    .start_pc(start_pc), .configuration(configuration),
    .core_status(core_status), .exceptions(exceptions),
    .exceptions_pc(exceptions_pc)
  );

  `define RF   dut.u_core.u_rf
  `define DMEM dut.u_dmem
  `define IMEM dut.u_imem

  function [31:0] get_reg;
    input integer idx;
    begin
      if (idx == 0) get_reg = 0;
      else get_reg = `RF.regs[idx];
    end
  endfunction

  integer pass_cnt, fail_cnt, test_num;
  initial begin pass_cnt=0; fail_cnt=0; test_num=0; end

  task check;
    input [255:0] name; input [31:0] actual, expected;
    begin
      test_num = test_num + 1;
      if (actual === expected) begin
        $display("[PASS] #%0d %0s = 0x%08h", test_num, name, actual);
        pass_cnt = pass_cnt + 1;
      end else begin
        $display("[FAIL] #%0d %0s: got 0x%08h, exp 0x%08h", test_num, name, actual, expected);
        fail_cnt = fail_cnt + 1;
      end
    end
  endtask

  task run_cycles;
    input integer n; integer i;
    begin for (i=0;i<n;i=i+1) @(posedge clk); end
  endtask

  task wait_halt;
    input integer timeout; integer cnt;
    begin
      cnt = 0;
      while (core_status[0] !== 1'b1 && cnt < timeout) begin
        @(posedge clk); cnt = cnt + 1;
      end
      if (cnt >= timeout) $display("[WARN] Timeout waiting for halt");
    end
  endtask

  reg [8*32-1:0] test_name;
  reg [8*64-1:0] hex_file;

  initial begin
    if ($value$plusargs("TEST=%s", test_name))
      hex_file = {"../tb/firmware_", test_name, ".hex"};
    else
      hex_file = "firmware.hex";
    $display("Loading firmware: %0s", hex_file);
    #1;  // let IMEM initial block fill NOPs first
    $readmemh(hex_file, `IMEM.mem);
  end

  initial begin
    $display("=============================================================");
    $display("  HiRiscy SoC Testbench");
    $display("=============================================================");
    rst_n=0; start_pause=0; start_pc=0; configuration=0;
    run_cycles(10); rst_n=1; run_cycles(2);

    if (test_name == "exc_illegal")         test_exc_illegal;
    else if (test_name == "exc_branch_misalign") test_exc_branch_misalign;
    else if (test_name == "exc_priority")   test_exc_priority;
    else if (test_name == "exc_fetch_misalign") test_exc_fetch_misalign;
    else                                    test_basic;

    $display("\n=============================================================");
    $display("  Results: %0d PASSED, %0d FAILED out of %0d", pass_cnt, fail_cnt, test_num);
    if (fail_cnt == 0) $display("  *** ALL TESTS PASSED ***");
    else               $display("  *** SOME TESTS FAILED ***");
    $display("=============================================================");
    $finish;
  end

  task test_basic;
    begin
      $display("\n--- Test: Basic Functional ---");
      configuration = 2'b11; start_pause=1; start_pc=0;
      run_cycles(50000);
      check("ADDI x1=42",  get_reg(1), 32'd42);
      check("ADDI x2=10",  get_reg(2), 32'd10);
      check("ADD  x3=52",  get_reg(3), 32'd52);
      check("SUB  x4=32",  get_reg(4), 32'd32);
      check("ANDI x5=52",  get_reg(5), 32'd52);
      check("ORI  x6=0x55",get_reg(6), 32'h55);
      check("XORI x7=0xAA",get_reg(7), 32'hAA);
      check("SLLI x8=160", get_reg(8), 32'd160);
      check("SRLI x9=40",  get_reg(9), 32'd40);
      check("SLTI x18=1",  get_reg(18),32'd1);
      check("SLT  x19=1",  get_reg(19),32'd1);
      check("SW+LW x11=52",get_reg(11),32'd52);
      check("Branch x15=2",get_reg(15),32'd2);
      check("JAL x17=3",   get_reg(17),32'd3);
      check("Loop x23=0",  get_reg(23),32'd0);
      check("DMEM[0]=52",  `DMEM.mem[0],32'd52);
      check("no exceptions",{30'b0,exceptions},32'd0);
    end
  endtask

  task test_exc_illegal;
    begin
      $display("\n--- Test: Illegal Instruction Exception ---");
      configuration = 2'b00; start_pause=1; start_pc=0;
      wait_halt(100000);
      check("x1=42 (retired)", get_reg(1), 32'd42);
      check("x2=10 (retired)", get_reg(2), 32'd10);
      check("x3=52 (retired)", get_reg(3), 32'd52);
      check("DMEM[0]=52 (sw retired)", `DMEM.mem[0], 32'd52);
      check("x5=0 (not executed)", get_reg(5), 32'd0);
      check("exceptions=illegal(2)", {30'b0,exceptions}, 32'd2);
      check("exceptions_pc=0x14", exceptions_pc, 32'h14);
      check("core_status=IDLE(1)", {30'b0,core_status}, 32'd1);
    end
  endtask

  task test_exc_branch_misalign;
    begin
      $display("\n--- Test: Branch Target Misalign ---");
      configuration = 2'b00; start_pause=1; start_pc=0;
      wait_halt(100000);
      check("x1=42 (retired)", get_reg(1), 32'd42);
      check("x2=10 (retired)", get_reg(2), 32'd10);
      check("x5=0 (not executed)", get_reg(5), 32'd0);
      check("exceptions=misalign(1)", {30'b0,exceptions}, 32'd1);
      check("exceptions_pc=0x08", exceptions_pc, 32'h08);
      check("core_status=IDLE(1)", {30'b0,core_status}, 32'd1);
    end
  endtask

  task test_exc_priority;
    begin
      $display("\n--- Test: Exception Priority ---");
      configuration = 2'b00; start_pause=1; start_pc=0;
      wait_halt(100000);
      check("x1=42 (retired)", get_reg(1), 32'd42);
      check("x2=10 (retired)", get_reg(2), 32'd10);
      check("exceptions=illegal(2) priority", {30'b0,exceptions}, 32'd2);
      check("exceptions_pc=0x08 (oldest)", exceptions_pc, 32'h08);
      check("core_status=IDLE(1)", {30'b0,core_status}, 32'd1);
    end
  endtask

  task test_exc_fetch_misalign;
    begin
      $display("\n--- Test: Fetch PC Misalign ---");
      configuration = 2'b00; start_pause=1; start_pc=12'd1;
      wait_halt(100000);
      check("x1=0 (not executed)", get_reg(1), 32'd0);
      check("exceptions=misalign(1)", {30'b0,exceptions}, 32'd1);
      check("exceptions_pc=0x01", exceptions_pc, 32'h01);
      check("core_status=IDLE(1)", {30'b0,core_status}, 32'd1);
    end
  endtask

  initial begin
    #20_000_000;
    $display("[ERROR] Global timeout!");
    $finish;
  end

  initial begin
    if ($test$plusargs("VCD")) begin
      $dumpfile("hiriscy_soc.vcd");
      $dumpvars(0, tb_hiriscy_soc);
    end
  end

`ifdef FSDB
  initial begin
    $fsdbDumpfile("hiriscy_soc.fsdb");
    $fsdbDumpvars(0, tb_hiriscy_soc, "+all");
    $fsdbDumpMDA(0, tb_hiriscy_soc);
  end
`endif

endmodule
