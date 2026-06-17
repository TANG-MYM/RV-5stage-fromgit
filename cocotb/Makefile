TOPLEVEL_LANG = verilog
VERILOG_SOURCES = \
    $(PWD)/../rtl/core/alu.v \
    $(PWD)/../rtl/core/regfile.v \
    $(PWD)/../rtl/core/decoder.v \
    $(PWD)/../rtl/core/branch_predictor.v \
    $(PWD)/../rtl/core/hazard_unit.v \
    $(PWD)/../rtl/core/csr.v \
    $(PWD)/../rtl/core/brv32p_core.v \
    $(PWD)/../rtl/mem/imem_rom.v \
    $(PWD)/../rtl/mem/dmem_sram.v \
    $(PWD)/../rtl/brv32p_soc.v

TOPLEVEL = brv32p_soc
COCOTB_TEST_MODULES = test_brv32p_soc
SIM ?= icarus

ifeq ($(SIM),icarus)
  COMPILE_ARGS += -g2005
  COMPILE_ARGS += -I$(PWD)/../rtl/pkg
  COMPILE_ARGS += -I$(PWD)/../rtl/core
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
