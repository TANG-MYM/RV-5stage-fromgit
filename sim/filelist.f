// ============================================================================
// filelist.f — BRV32P (RV32I) RTL + testbench source list for VCS / Verdi
// ----------------------------------------------------------------------------
// Paths are relative to the sim/ directory. Run `make` from inside sim/.
// ============================================================================

// ---- Include directories (for `include "brv32p_defs.vh") ----
+incdir+../rtl/pkg
+incdir+../rtl/core

// ---- Core ----
../rtl/core/alu.v
../rtl/core/regfile.v
../rtl/core/decoder.v
../rtl/core/branch_predictor.v
../rtl/core/hazard_unit.v
../rtl/core/csr.v
../rtl/core/brv32p_core.v

// ---- Cache ----
../rtl/cache/icache.v
../rtl/cache/dcache.v

// ---- Bus ----
../rtl/bus/axi_interconnect.v
../rtl/bus/axi_sram.v
../rtl/bus/axi_periph_bridge.v

// ---- Peripherals ----
../rtl/periph/gpio.v
../rtl/periph/uart.v
../rtl/periph/timer.v

// ---- SoC top ----
../rtl/brv32p_soc.v

// ---- Testbench ----
../tb/tb_brv32p_soc.v
