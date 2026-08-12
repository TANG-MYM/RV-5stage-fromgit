// ============================================================================
// filelist.f — HiRiscy (RV32I) RTL + testbench source list for VCS / Verdi
// ----------------------------------------------------------------------------
// Lives under rtl/. Invoke from sim/ with VCS `-F ../rtl/filelist.f` so that
// relative paths resolve against this file's directory (rtl/), not CWD.
// Harvard structure: instruction ROM + data SRAM, no cache / no AXI.
// ============================================================================

// ---- Include directories (for `include "hiriscy_defs.vh") ----
+incdir+pkg
+incdir+core

// ---- Generic library cells (DFF primitives) ----
lib/hiriscy_dff.v
lib/hiriscy_dff_en.v

// ---- Core functional units ----
core/hiriscy_alu.v
core/hiriscy_rf.v
core/hiriscy_idu.v
core/hiriscy_ifu.v
core/hiriscy_exu.v
core/hiriscy_lsu.v
core/hiriscy_core.v

// ---- Memories ----
mem/hiriscy_imem.v
mem/hiriscy_dmem.v

// ---- SoC top ----
hiriscy_soc.v

// ---- Testbench ----
../tb/tb_hiriscy_soc.v
