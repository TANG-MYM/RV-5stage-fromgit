// ============================================================================
// riscv_test_exc_illegal.sv — Illegal-instruction exception test
// ----------------------------------------------------------------------------
// Contrast with riscv_test_basic: the reference model is the SAME component,
// the scoreboard is the SAME component. Only the test/sequence/config differ:
//   - different firmware (contains an illegal instruction)
//   - different end-of-test condition (wait for exception halt, not WFI)
//   - the scoreboard config is identical (it already compares exceptions)
//
// This is the methodological point: tests vary stimulus + end condition;
// the golden-model infrastructure is built once and shared.
// ============================================================================

`ifndef RISCV_TEST_EXC_ILLEGAL_SV
`define RISCV_TEST_EXC_ILLEGAL_SV

class riscv_exc_illegal_seq extends uvm_sequence;
  `uvm_object_utils(riscv_exc_illegal_seq)
  function new(string name = "riscv_exc_illegal_seq");
    super.new(name);
  endfunction

  task body();
    start_item(/* ... */);
    // 1) reset, 2) start_pause rising edge with start_pc, 3) hold until halt.
    // The DUT should detect the illegal instruction, halt, and raise
    // core_status[0] (IDLE) with exceptions = 2'b10 (illegal).
    finish_item(/* ... */);
  endtask
endclass

class riscv_test_exc_illegal extends uvm_test;
  `uvm_component_utils(riscv_test_exc_illegal)

  riscv_env   m_env;
  riscv_sb_cfg sb_cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // Different firmware — the ONLY substantive per-test change.
    uvm_config_db#(string)::set(this, "m_env.rm", "elf_path", "firmware_exc_illegal.elf");
    uvm_config_db#(bit [31:0])::set(this, "m_env.rm", "start_pc", 32'h0000_0000);

    // Scoreboard config is identical to the basic test — the same compare
    // logic already covers exceptions (check_exception = 1). No RM edit.
    sb_cfg = riscv_sb_cfg::type_id::create("sb_cfg");
    sb_cfg.check_rf        = 1'b1;
    sb_cfg.check_pc        = 1'b1;
    sb_cfg.check_exception = 1'b1;
    uvm_config_db#(riscv_sb_cfg)::set(this, "m_env.sb", "sb_cfg", sb_cfg);
  endfunction

  task run_phase(uvm_phase phase);
    riscv_exc_illegal_seq seq;
    seq = riscv_exc_illegal_seq::type_id::create("seq");
    phase.raise_objection(this);
    seq.start(m_env.agent.sqr);
    // End condition for THIS test: exception halt. core_status[0] (IDLE) is
    // set by both exception-halt and WFI-idle; the discriminator is the
    // exceptions output being nonzero.
    wait (m_env.monitor.core_status[0] === 1'b1 &&
          m_env.monitor.exceptions    !== 2'b00);
    phase.drop_objection(this);
  endtask

endclass

`endif
