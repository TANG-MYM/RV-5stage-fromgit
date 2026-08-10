# ============================================================================
# Makefile — VCS + Verdi simulation flow for HiRiscy RV32IMC 5-stage SoC
# ----------------------------------------------------------------------------\
# Usage (from sim/):
#   source ./setup_env.sh
#   make comp
#   make run                      # default test (firmware.hex)
#   make run TEST=exc_illegal     # illegal-instruction exception test
#   make run TEST=exc_branch_misalign
#   make run TEST=exc_priority
#   make run TEST=exc_fetch_misalign
#   make test_all                # run every test and summarize
#   make comp PIPE=3             # build the 3-stage pipeline variant
#   make verdi                   # open FSDB in Verdi
#   make clean
# ============================================================================

RTL_DIR  := ../rtl
TB_DIR   := ../tb
FILELIST := filelist.f
TOP      := tb_hiriscy_soc
FW_HEX   := firmware.hex
FSDB     := hiriscy_soc.fsdb

VCS   := vcs
VERDI := verdi

VCS_OPTS := -full64 -sverilog -timescale=1ns/1ps \
            -debug_access+all -kdb -lca \
            +define+FSDB \
            -f $(FILELIST) -top $(TOP) \
            -l comp.log -o simv

PLATFORM ?= LINUX64
ifdef VERDI_HOME
VCS_OPTS += -P $(VERDI_HOME)/share/PLI/VCS/$(PLATFORM)/novas.tab \
               $(VERDI_HOME)/share/PLI/VCS/$(PLATFORM)/pli.a
endif

SIM_OPTS := -l sim.log
RUN_ARGS ?=
TEST     ?=
PIPE     ?= 5          # pipeline mode: 5 (default) or 3

# Add +define+PIPE_MODE_3 to the 3-stage build so the testbench selects the
# 3-stage variant at elaboration (otherwise the 5-stage default is used).
ifeq ($(PIPE),3)
VCS_OPTS += +define+PIPE_MODE_3
endif

TESTS := basic exc_illegal exc_branch_misalign exc_priority exc_fetch_misalign

.PHONY: all comp run sim verdi wave clean help test_all $(TESTS)

all: run

$(FW_HEX): $(TB_DIR)/$(FW_HEX)
	cp $(TB_DIR)/$(FW_HEX) $(FW_HEX)

comp: $(FW_HEX)
	$(VCS) $(VCS_OPTS)

run: comp
	$(if $(TEST),./simv $(SIM_OPTS) +TEST=$(TEST) $(RUN_ARGS),\
	              ./simv $(SIM_OPTS) $(RUN_ARGS))

sim: run

# Per-test convenience targets
basic: comp
	./simv $(SIM_OPTS) +TEST=basic $(RUN_ARGS)

exc_illegal: comp
	./simv $(SIM_OPTS) +TEST=exc_illegal $(RUN_ARGS)

exc_branch_misalign: comp
	./simv $(SIM_OPTS) +TEST=exc_branch_misalign $(RUN_ARGS)

exc_priority: comp
	./simv $(SIM_OPTS) +TEST=exc_priority $(RUN_ARGS)

exc_fetch_misalign: comp
	./simv $(SIM_OPTS) +TEST=exc_fetch_misalign $(RUN_ARGS)

# Run all tests and collect pass/fail summary
test_all: comp
	@echo "============================================================="
	@echo "  Running all test scenarios"
	@echo "============================================================="
	@rm -f test_results.log
	@for t in $(TESTS); do \
		echo "--- Running test: $$t ---" | tee -a test_results.log; \
		./simv $(SIM_OPTS) +TEST=$$t $(RUN_ARGS) 2>&1 | tee -a test_results.log; \
		echo "" | tee -a test_results.log; \
	done
	@echo "============================================================="
	@echo "  Test Summary (FAIL/ERROR lines):"
	@grep -E "\[FAIL\]|\[ERROR\]|SOME TESTS FAILED" test_results.log || echo "  No failures detected."
	@echo "============================================================="

verdi:
	$(VERDI) -dbdir simv.daidir -ssf $(FSDB) -nologo &

wave: verdi

clean:
	rm -rf simv simv.daidir csrc *.log *.fsdb *.vcd \
	       verdiLog novas.* novas_dump.log DVEfiles \
	       ucli.key vc_hdrs.h vcs.key inter.vpd \
	       .vcs.timestamp AN.DB $(FW_HEX) test_results.log

help:
	@echo "Targets:"
	@echo "  make comp                   - compile RTL+tb with VCS (FSDB+KDB)"
	@echo "  make run                    - run default test (firmware.hex)"
	@echo "  make run TEST=<name>        - run a specific test"
	@echo "  make test_all               - run all tests and summarize"
	@echo "  make verdi                  - open $(FSDB) in Verdi"
	@echo "  make clean                  - remove all generated artifacts"
	@echo ""
	@echo "Available TEST names:"
	@echo "  basic, exc_illegal, exc_branch_misalign, exc_priority, exc_fetch_misalign"
	@echo ""
	@echo "Set VCS_HOME / VERDI_HOME / license via 'source ./setup_env.sh' first."
