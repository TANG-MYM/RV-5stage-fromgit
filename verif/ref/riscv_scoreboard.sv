// ============================================================================
// riscv_scoreboard.sv — Compare DUT actual vs RM expected retire transactions
// ----------------------------------------------------------------------------
// Receives two streams in lockstep:
//   act_export : from the DUT monitor  (actual retire)
//   exp_export : from the reference model (expected retire, post-Spike-step)
//
// Compare policy is TEST-AGNOSTIC in structure; per-test differences are
// expressed via a config object (what to compare, what to mask). For this
// core: CSR is not implemented, so CSR fields are never compared here; the
// "check_csr" flag exists only to make the mask pattern explicit.
// ============================================================================

`ifndef RISCV_SCOREBOARD_SV
`define RISCV_SCOREBOARD_SV

class riscv_sb_cfg extends uvm_object;
  `uvm_object_utils(riscv_sb_cfg)
  bit check_rf        = 1'b1;   // compare register writes
  bit check_pc        = 1'b1;   // compare retire PC
  bit check_exception = 1'b1;  // compare exception cause/PC
  bit check_csr       = 1'b0;   // NEVER: this core has no CSR
  function new(string name = "riscv_sb_cfg");
    super.new(name);
  endfunction
endclass

class riscv_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(riscv_scoreboard)

  uvm_analysis_export #(riscv_retire_txn) act_export;
  uvm_analysis_export #(riscv_retire_txn) exp_export;

  riscv_sb_cfg cfg;

  // Two-deep queues to align actual/expected arriving in the same step.
  riscv_retire_txn act_q[$];
  riscv_retire_txn exp_q[$];

  int pass_cnt;
  int fail_cnt;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    act_export = new("act_export", this);
    exp_export = new("exp_export", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = riscv_sb_cfg::type_id::create("cfg");
    uvm_config_db#(riscv_sb_cfg)::get(this, "", "sb_cfg", cfg);
  endfunction

  function void write_act(riscv_retire_txn txn);
    act_q.push_back(txn);
    try_match();
  endfunction

  function void write_exp(riscv_retire_txn txn);
    exp_q.push_back(txn);
    try_match();
  endfunction

  // Compare one actual against one expected.
  function void try_match();
    riscv_retire_txn a, e;
    bit mismatch;
    if (act_q.size() == 0 || exp_q.size() == 0) return;
    a = act_q.pop_front();
    e = exp_q.pop_front();

    if (cfg.check_pc && (a.pc !== e.pc)) mismatch = 1;

    if (cfg.check_exception) begin
      if (a.exc !== e.exc)               mismatch = 1;
      if (a.exc && (a.exc_cause !== e.exc_cause)) mismatch = 1;
      if (a.exc && (a.exc_pc   !== e.exc_pc))    mismatch = 1;
    end

    if (cfg.check_rf && (a.reg_wr || e.reg_wr)) begin
      if (a.reg_wr  !== e.reg_wr)  mismatch = 1;
      if (a.reg_wr && (a.rd       !== e.rd))       mismatch = 1;
      if (a.reg_wr && (a.rd_data  !== e.rd_data))  mismatch = 1;
    end

    if (mismatch) begin
      fail_cnt++;
      `uvm_error("SB", $sformatf("MISMATCH\n  act: %s\n  exp: %s",
                                 a.summary(), e.summary()))
    end else begin
      pass_cnt++;
      `uvm_info("SB", $sformatf("MATCH %s", a.summary()), UVM_HIGH)
    end
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("SB", $sformatf("pass=%0d fail=%0d", pass_cnt, fail_cnt), UVM_LOW)
    if (fail_cnt != 0) `uvm_error("SB", "TEST FAILED")
  endfunction

endclass

`endif
