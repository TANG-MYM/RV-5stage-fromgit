// ============================================================================
// riscv_txn.sv — Retire transaction (shared by monitor, reference model,
//                scoreboard)
// ----------------------------------------------------------------------------
// One riscv_retire_txn represents the architectural effect of ONE retired
// instruction: what it wrote (if anything), whether it took an exception,
// and the PC it executed at. The DUT monitor produces the "actual" instance;
// the reference model (Spike) produces the "expected" instance. The
// scoreboard compares them field-by-field.
// ============================================================================

`ifndef RISCV_TXN_SV
`define RISCV_TXN_SV

class riscv_retire_txn extends uvm_sequence_item;

  // Architectural PC of the retired instruction (post-step PC = next PC).
  rand bit [31:0] pc;

  // Register write effect (NONE if the instruction does not write rd).
  bit        reg_wr;
  bit [4:0]  rd;
  bit [31:0] rd_data;

  // Exception (illegal / fetch-misalign / branch-misalign), if any.
  bit        exc;
  bit [1:0]  exc_cause;   // 2'b01 = misalign, 2'b10 = illegal
  bit [31:0] exc_pc;      // PC of the faulting instruction

  // Origin tag (for debug): which model produced this txn.
  bit        is_expected; // 0 = actual (DUT), 1 = expected (RM)

  `uvm_object_utils_begin(riscv_retire_txn)
    `uvm_object_field_int(pc,        UVM_ALL_ON)
    `uvm_object_field_int(reg_wr,    UVM_ALL_ON)
    `uvm_object_field_int(rd,        UVM_ALL_ON)
    `uvm_object_field_int(rd_data,   UVM_ALL_ON)
    `uvm_object_field_int(exc,       UVM_ALL_ON)
    `uvm_object_field_int(exc_cause, UVM_ALL_ON)
    `uvm_object_field_int(exc_pc,    UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "riscv_retire_txn");
    super.new(name);
  endfunction

  // Human-readable summary for the log/scoreboard diff.
  function string summary();
    string s;
    s = $sformatf("pc=0x%08h %s wr=%b rd=%0d data=0x%08h",
                  pc, (exc ? "EXC" : "   "), reg_wr, rd, rd_data);
    if (exc) s = {s, $sformatf(" cause=%b exc_pc=0x%08h", exc_cause, exc_pc)};
    return s;
  endfunction

endclass

`endif
