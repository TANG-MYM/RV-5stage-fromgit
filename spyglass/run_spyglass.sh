#!/usr/bin/env bash
# ============================================================================
# run_spyglass.sh — Convenience wrapper to run SpyGlass Lint
# ----------------------------------------------------------------------------
# Usage:
#   ./run_spyglass.sh
# ============================================================================

set -e

echo "[SpyGlass] Starting lint run..."

# Create results directory if it doesn't exist
mkdir -p results

# Run SpyGlass in batch mode
spyglass -shell -tcl run_lint.tcl

echo "[SpyGlass] Lint finished. Reports are in ./results/"
echo "  - lint_report.rpt"
echo "  - lint_violations.rpt"
echo "  - lint_summary.rpt"
