# ============================================================================
# Makefile — VCS + Verdi simulation / functional-verification flow
#            for the BRV32P (RV32I) 5-stage pipelined SoC
# ----------------------------------------------------------------------------
# Typical usage (run from inside sim/):
#   source ./setup_env.sh     # set VCS_HOME / VERDI_HOME / license first
#   make comp                 # compile with VCS (FSDB + KDB debug enabled)
#   make run                  # compile (if needed) and run simulation
#   make verdi                # open the dumped FSDB waveform in Verdi
#   make clean                # remove all generated files
# ============================================================================

# ---- Directories ----------------------------------------------------------
RTL_DIR   := ../rtl
TB_DIR    := ../tb
FW_DIR    := ../firmware
FILELIST  := filelist.f

# ---- Design ---------------------------------------------------------------
TOP       := tb_brv32p_soc
FW_HEX    := firmware.hex
FSDB      := brv32p_soc.fsdb

# ---- Tools ----------------------------------------------------------------
VCS       := vcs
VERDI     := verdi

# ---- VCS compile options --------------------------------------------------
#  -full64          : 64-bit build
#  -sverilog        : accept (System)Verilog syntax
#  -debug_access+all: full interactive/post-process debug visibility
#  -kdb             : emit Knowledge DataBase for Verdi source debug
#  -lca             : enable LCA features required by -kdb on some versions
#  +define+FSDB     : turns on the $fsdbDump* block inside the testbench
VCS_OPTS  := -full64 -sverilog -timescale=1ns/1ps \
             -debug_access+all -kdb -lca \
             +define+FSDB \
             -f $(FILELIST) \
             -top $(TOP) \
             -l comp.log \
             -o simv

# ---- Verdi FSDB PLI (linked only when VERDI_HOME is defined) ---------------
PLATFORM  ?= LINUX64
ifdef VERDI_HOME
VCS_OPTS  += -P $(VERDI_HOME)/share/PLI/VCS/$(PLATFORM)/novas.tab \
                $(VERDI_HOME)/share/PLI/VCS/$(PLATFORM)/pli.a
endif

# ---- Simulation run options ----------------------------------------------
SIM_OPTS  := -l sim.log
# Extra plusargs can be appended on the command line, e.g.:
#   make run RUN_ARGS="+VCD"
RUN_ARGS  ?=

.PHONY: all comp run sim verdi wave clean help

all: run

# ---- Stage firmware image into the run directory --------------------------
$(FW_HEX): $(FW_DIR)/$(FW_HEX)
	cp $(FW_DIR)/$(FW_HEX) $(FW_HEX)

# ---- Compile --------------------------------------------------------------
comp: $(FW_HEX)
	$(VCS) $(VCS_OPTS)

# ---- Run ------------------------------------------------------------------
run: comp
	./simv $(SIM_OPTS) $(RUN_ARGS)

sim: run

# ---- Post-process waveform debug in Verdi ---------------------------------
#  Opens the FSDB together with the KDB so you get source-level debug.
verdi:
	$(VERDI) -dbdir simv.daidir -ssf $(FSDB) -nologo &

# Alias
wave: verdi

# ---- Cleanup --------------------------------------------------------------
clean:
	rm -rf simv simv.daidir csrc *.log *.fsdb *.vcd \
	       verdiLog novas.* novas_dump.log DVEfiles \
	       ucli.key vc_hdrs.h vcs.key inter.vpd \
	       .vcs.timestamp AN.DB $(FW_HEX)

help:
	@echo "Targets:"
	@echo "  make comp   - compile RTL+tb with VCS (FSDB+KDB debug)"
	@echo "  make run    - run the simulation (depends on comp)"
	@echo "  make verdi  - open $(FSDB) in Verdi for waveform debug"
	@echo "  make clean  - remove all generated artifacts"
	@echo ""
	@echo "Set VCS_HOME / VERDI_HOME / license via 'source ./setup_env.sh' first."
