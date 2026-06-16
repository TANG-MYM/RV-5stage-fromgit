#!/usr/bin/env bash
# ============================================================================
# setup_env.sh — Environment template for the VCS + Verdi flow
# ----------------------------------------------------------------------------
# Edit the paths below to match your local Synopsys installation, then:
#     source ./setup_env.sh
# (Use `source`, NOT `./setup_env.sh`, so the variables stay in your shell.)
# ============================================================================

# ---- Synopsys VCS ----------------------------------------------------------
export VCS_HOME=/path/to/synopsys/vcs/<version>
export PATH=$VCS_HOME/bin:$PATH

# ---- Synopsys Verdi --------------------------------------------------------
export VERDI_HOME=/path/to/synopsys/verdi/<version>
export PATH=$VERDI_HOME/bin:$PATH

# Platform sub-dir used to locate the Verdi FSDB PLI (novas.tab / pli.a).
# Common values: LINUX64, LINUX, SUSE64
export PLATFORM=LINUX64

# ---- License ---------------------------------------------------------------
# Point this at your license server (port@host) or license file.
export SNPSLMD_LICENSE_FILE=27000@your-license-server
# export LM_LICENSE_FILE=$SNPSLMD_LICENSE_FILE

# ---- Sanity check ----------------------------------------------------------
echo "VCS_HOME   = $VCS_HOME"
echo "VERDI_HOME = $VERDI_HOME"
echo "vcs        : $(command -v vcs   2>/dev/null || echo 'NOT FOUND')"
echo "verdi      : $(command -v verdi 2>/dev/null || echo 'NOT FOUND')"
