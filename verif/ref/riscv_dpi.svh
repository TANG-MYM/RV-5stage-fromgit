// ============================================================================
// riscv_dpi.svh — DPI-C interface to Spike (riscv-isa-sim) as golden ISS
// ----------------------------------------------------------------------------
// This header declares the SV side of the bridge. The matching C side is a
// thin wrapper around Spike's sim_t (see riscv_dpi_c.cpp):
//   - spike_init        : load program image, set PC, reset ISS state
//   - spike_step        : execute ONE architectural instruction, return the
//                        exception cause the ISS would take (0 = none)
//   - spike_get_*       : combinational reads of the ISS architectural state
//   - spike_load_mem    : backdoor mirror of imem/dmem image into the ISS
//
// Design rule: the C side NEVER advances Spike autonomously. Spike only moves
// when the UVM reference model calls spike_step() in lockstep with a DUT
// retire. This is what keeps the two models architecturally aligned.
// ============================================================================

`ifndef RISCV_DPI_SVH
`define RISCV_DPI_SVH

// Initialize Spike: load ELF/hex, set reset PC, zero RF/CSR.
// Returns 0 on success, nonzero on error.
import "DPI-C" context function int  spike_init  (input string    elf_path,
                                                  input bit [31:0] start_pc);

// Step exactly one instruction. Returns the exception cause the instruction
// would raise (0 = none). The ISS is NOT allowed to take the trap (it would
// jump to mtvec); the C wrapper detects the fault and reports the cause,
// leaving PC on the faulting instruction so the RM can compare and stop.
import "DPI-C" context function void spike_step  (output bit [31:0] exc_cause);

// Architectural state queries (post-step).
import "DPI-C" function void spike_get_reg (input  int       idx,   // 0..31
                                             output bit [31:0] val);
import "DPI-C" function void spike_get_pc  (output bit [31:0] val);
import "DPI-C" function void spike_get_csr (input  int       idx,
                                             output bit [31:0] val);

// Backdoor memory mirror: load one 32-bit word into the ISS memory at addr.
// Used to preload the same imem/dmem image the DUT sees.
import "DPI-C" function void spike_load_mem (input bit [31:0] addr,
                                              input bit [31:0] data);

// Tear down the ISS instance (release memory).
import "DPI-C" function void spike_finish ();

`endif
