// ============================================================================
// filelist.f — HiRiscy (RV32I) RTL + testbench source list for VCS / Verdi
// ----------------------------------------------------------------------------
// Paths are relative to the sim/ directory. Run `make` from inside sim/.
// Harvard structure: instruction ROM + data SRAM, no cache / no AXI.
// ============================================================================

// ---- Include directories (for `include "hiriscy_defs.vh") ----
+incdir+../rtl/pkg
+incdir+../rtl/core

// ---- Core functional units ----
../rtl/core/hiriscy_alu.v
../rtl/core/hiriscy_rf.v
../rtl/core/hiriscy_idu.v
../rtl/core/hiriscy_ifu.v
../rtl/core/hiriscy_exu.v
../rtl/core/hiriscy_lsu.v
../rtl/core/hiriscy_core.v

// ---- Memories ----
../rtl/mem/hiriscy_imem.v
../rtl/mem/hiriscy_dmem.v

// ---- SoC top ----
../rtl/hiriscy_soc.v

// ---- Testbench ----
../tb/tb_hiriscy_soc.v
