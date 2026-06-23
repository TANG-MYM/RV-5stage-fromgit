# ============================================================================
# run_lint.tcl — SpyGlass Lint Run Script for HiRiscy
# ----------------------------------------------------------------------------
# Usage:
#   spyglass -shell -tcl run_lint.tcl
# ============================================================================

# Load project
read_file -format sgdc lint.sgdc
read_file -format prj  spyglass.prj

# Run lint analysis
run_goal lint

# Generate reports
write_report -goal lint -file results/lint_report.rpt
write_report -goal lint -file results/lint_violations.rpt -violations
write_report -goal lint -file results/lint_summary.rpt -summary

# Optional: generate waiver template
# write_waiver -file results/waiver_template.waiver

puts "SpyGlass Lint finished. Reports are in ./results/"
exit
