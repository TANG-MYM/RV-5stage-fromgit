# SpyGlass Lint Configuration for HiRiscy

This directory contains the SpyGlass lint setup for the HiRiscy RV32I core.

## Directory Contents

| File | Purpose |
|------|---------|
| `spyglass.prj` | Main SpyGlass project file (source list, top module, ruleset) |
| `lint.sgdc`    | Design constraints (clock `clk`, reset `rst_n`) |
| `run_lint.tcl` | Tcl script to run lint and generate reports |

## How to Run

### Method 1: Using SpyGlass GUI (recommended for first time)

```bash
cd spyglass
spyglass
```

Then in the GUI:
1. File → Open Project → select `spyglass.prj`
2. Run the `lint` goal
3. View results in the GUI or in the `results/` directory

### Method 2: Command-line (batch mode)

```bash
cd spyglass
spyglass -shell -tcl run_lint.tcl
```

After running, the reports will be generated in:

```
spyglass/results/
├── lint_report.rpt
├── lint_violations.rpt
└── lint_summary.rpt
```

## Customization

- Edit `lint.sgdc` to adjust clock period or add more clocks/resets.
- Add more rulesets in `spyglass.prj` (e.g., `STARC`, `RMM`).
- Create a `waiver.waiver` file if you want to suppress known false positives.

## Notes

- The project reuses `../sim/filelist.f` to avoid duplication.
- All paths in `spyglass.prj` are relative to the `spyglass/` directory.
- Make sure SpyGlass is in your `PATH` before running.
