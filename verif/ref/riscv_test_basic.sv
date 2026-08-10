// ============================================================================
// riscv_test_basic.sv — Basic functional test (run-to-WFI, compare RF writes)
// ----------------------------------------------------------------------------
// Shows the TEST layer: what changes per test.
//   - which firmware (elf_path) to load into both DUT imem and Spike
//   - run-control stimulus (start_pause waveform, start_pc)
//   - end-of-test condition (run until core_status==IDLE, i.e. WFI parked)
//
// The reference model, scoreboard, monitor, and env are NOT defined here —
// they live in the env package and are reused by every test. Only the
// sequence + test class + config are per-test.
// ============================================================================

`ifndef RISCV_TEST_BASIC_SV
`define RISCV_TEST_BASIC_SV

// ── Sequence: drive start_pause/start_pc and let the core run ──────────────
class riscv_basic_seq extends uvm_sequence;
  `uvm_object_utils(riscv_basic_seq)
  function new(string name = "riscv_basic_seq");
    super.new(name);
  endfunction

  task body();
    // The driver (in the env) translates these into start_pause/start_pc
    // pin wiggles on the DUT's run-control interface.
    start_item(/* ... */);
    // 1) deassert start_pause, apply reset
    // 2) pulse start_pause rising edge with start_pc -> restart
    // 3) hold start_pause high until core parks (WFI) or exception halt
    finish_item(/* ... */);
  endtask
endclass

// ── Test: wire up env + config + run sequence + wait for end condition ───────
class riscv_test_basic extends uvm_test;
  `uvm_component_utils(riscv_test_basic)

  riscv_env   m_env;          // (declared in the env package, not shown)
  riscv_sb_cfg sb_cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // Per-test configuration: which firmware, what start PC, what to compare.
    uvm_config_db#(string)::set(this, "m_env.rm", "elf_path", "firmware_basic.elf");
    uvm_config_db#(bit [31:0])::set(this, "m_env.rm", "start_pc", 32'h0000_0000);

    // Scoreboard config: full RF + PC compare, no exception expected (but
    // the compare logic still runs — if one fires it just means a bug).
    sb_cfg = riscv_sb_cfg::type_id::create("sb_cfg");
    sb_cfg.check_rf        = 1'b1;
    sb_cfg.check_pc        = 1'b1;
    sb_cfg.check_exception = 1'b1;   // still verify none fires
    uvm_config_db#(riscv_sb_cfg)::set(this, "m_env.sb", "sb_cfg", sb_cfg);
  endfunction

  task run_phase(uvm_phase phase);
    riscv_basic_seq seq;
    seq = riscv_basic_seq::type_id::create("seq");
    phase.raise_objection(this);
    seq.start(m_env.agent.sqr);
    // End condition for THIS test: wait until the core parks in WFI idle.
    wait (m_env.monitor.core_status[0] === 1'b1);
    phase.drop_objection(this);
  endtask

endclass

`endif
