// ============================================================================
// riscv_ref_model.sv — UVM reference model (Spike golden-model wrapper)
// ----------------------------------------------------------------------------
// The reference model is a uvm_component whose ONLY job is:
//   1. Receive DUT retire events from the monitor (LOCKSTEP TRIGGER).
//   2. Advance Spike by exactly one instruction in response.
//   3. Capture the expected architectural effect (RF write / exception).
//   4. Publish an "expected" riscv_retire_txn to the scoreboard.
//
// It does NOT compare anything (that's the scoreboard's job) and it is
// TEST-AGNOSTIC: the same component serves basic, exception, WFI, and random
// tests. Whatever varies per test lives in the sequence/test, not here.
//
// Connection in the env:
//   monitor.retire_ap  ──►  rm.dut_export   (lockstep trigger)
//   rm.exp_ap          ──►  sb.exp_export    (expected)
//   monitor.retire_ap  ──►  sb.act_export    (actual)
// ============================================================================

`ifndef RISCV_REF_MODEL_SV
`define RISCV_REF_MODEL_SV

class riscv_ref_model extends uvm_component;

  `uvm_component_utils(riscv_ref_model)

  // Publishes expected retire transactions.
  uvm_analysis_port #(riscv_retire_txn) exp_ap;

  // Receives actual retire transactions from the DUT monitor (lockstep).
  uvm_analysis_export #(riscv_retire_txn) dut_export;

  // Config (set by the test via uvm_config_db).
  string    elf_path;
  bit [31:0] start_pc;

  // Internal: the last faulting-PC, used to stop stepping after an exception.
  bit        stopped;       // set once an exception/WFI is reached; freeze

  function new(string name, uvm_component parent);
    super.new(name, parent);
    exp_ap     = new("exp_ap",     this);
    dut_export = new("dut_export", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(string)::get(this, "", "elf_path", elf_path);
    uvm_config_db#(bit [31:0])::get(this, "", "start_pc", start_pc);
    if (spike_init(elf_path, start_pc) != 0)
      `uvm_fatal("RM", "spike_init failed — check elf_path / ISS build")
  endfunction

  // Lockstep: one DUT retire -> one Spike step. This is the heart of the RM.
  // The monitor's analysis write calls this directly.
  function void write(riscv_retire_txn act_txn);
    riscv_retire_txn exp_txn;
    bit [31:0] cause;
    bit [31:0] rm_pc;

    // If we already stopped (exception/WFI observed), do not advance Spike.
    if (stopped) begin
      return;
    end

    exp_txn = riscv_retire_txn::type_id::create("exp");
    exp_txn.is_expected = 1'b1;

    // ---- Step the ISS by exactly one instruction --------------------------
    // spike_step reports the cause the instruction WOULD raise, without
    // taking the trap. PC stays on the faulting instruction on a fault.
    spike_step(cause);

    // ---- Capture expected architectural state -----------------------------
    spike_get_pc(rm_pc);
    exp_txn.pc = rm_pc;

    if (cause == 32'b0) begin
      // Normal retire: query whether the ISS wrote a register this step.
      // (In a real wrapper, spike_step would directly return rd/rd_data;
      //  here we keep it simple and read back the current RF state.)
      capture_rf_write(exp_txn);
      exp_txn.exc = 1'b0;
    end else begin
      // Exception: the DUT halts and reports cause; the ISS must stop too.
      exp_txn.exc       = 1'b1;
      exp_txn.exc_cause = cause[1:0];
      exp_txn.exc_pc    = rm_pc;     // faulting instruction PC
      stopped           = 1'b1;      // freeze — DUT will halt here
    end

    `uvm_info("RM", $sformatf("expected: %s", exp_txn.summary()), UVM_HIGH)
    exp_ap.write(exp_txn);
  endfunction

  // Helper: figure out which register (if any) the just-stepped instruction
  // wrote. A real wrapper would have spike_step return {rd, valid, data};
  // this shows the structure.
  function void capture_rf_write(ref riscv_retire_txn txn);
    bit [31:0] dummy;
    // Placeholder: query Spike's "last writer" hook here and fill txn.rd /
    // txn.rd_data / txn.reg_wr. Left abstract — adapt to your C wrapper.
    txn.reg_wr  = 1'b0;   // TODO: from wrapper
    txn.rd      = 5'd0;
    txn.rd_data = 32'b0;
    void'(dummy);
  endfunction

  function void final_phase(uvm_phase phase);
    spike_finish();
  endfunction

endclass

`endif
