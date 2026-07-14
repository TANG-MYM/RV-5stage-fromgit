# HiRiscy — 5-Stage Pipelined RV32I Core

This project is a simulation-focused RV32I 5-stage pipeline written in Verilog.
The current structure is intentionally small: no cache, no AXI bus, no
peripherals, and no synthesis log archive.

The core is decomposed into functional units (per the HiRiscy block diagram):
IFU / IDU / EXU(ALU) / LSU over a shared register file (RF). All pipeline
registers and run-control state live in the core top (`hiriscy_core`); the
functional units are combinational datapath blocks.

## Current Architecture

| Block | Description |
|---|---|
| `hiriscy_core` | Core top: holds PC + all pipeline registers (IF/ID, ID/EX, EX/MEM, MEM/WB) and the run/halt/WFI control FSM; wires the units below |
| `hiriscy_ifu` | Instruction Fetch Unit — next-PC mux + IMEM request, static not-taken branch prediction (combinational) |
| `hiriscy_idu` | Instruction Decode Unit — control bundle, immediate, register addresses, plus integrated hazard detection / data forwarding / stall-flush control |
| `hiriscy_exu` | Execute Unit — forwarding, ALU, branch/jump resolution, exception detect (instantiates `hiriscy_alu`) |
| `hiriscy_lsu` | Load/Store Unit — DMEM request + load/ALU result select |
| `hiriscy_rf` | 32x32 register file (read in ID, write in WB) |
| `hiriscy_alu` | 32-bit ALU |
| `hiriscy_imem` | Instruction ROM, `IMEM_DEPTH x 32`, `$readmemh("firmware.hex")` |
| `hiriscy_dmem` | 4 KB data SRAM, simple next-cycle ready handshake |
| `hiriscy_soc` | Top wrapper with run/pause/start-PC and exception status ports |

The SoC top interface exposes:

| Signal | Direction | Description |
|---|---|---|
| `clk` / `rst_n` | input | Clock and active-low reset |
| `start_pause` | input | Rising edge restarts from `start_pc`; level `1` runs, `0` pauses |
| `start_pc[11:0]` | input | Restart PC byte address |
| `configuration[1:0]` | input | Exception masks, `1` means suppress |
| `core_status[1:0]` | output | `[0]` IDLE (exception halt or after a WFI retires), `[1]` WFI (after a WFI retires) |
| `exceptions[1:0]` | output | `[0]` PC misaligned, `[1]` illegal instruction |
| `exceptions_pc[31:0]` | output | PC of the faulting instruction (latched on halt) |

> Note: CSR/Zicsr and the trap mechanism (ECALL/EBREAK/MRET, interrupts) are not
> implemented. `WFI` is the only SYSTEM instruction; it drains the pipeline,
> stops fetch, and parks the core in IDLE until the next Start pulse.

### Coding style

All combinational logic is written with continuous `assign` statements (and
instantiated combinational sub-modules); all state is realised by instantiating
the flip-flop primitives in `rtl/lib/` (`hiriscy_dff`, `hiriscy_dff_en`). Clocked
`always` blocks therefore exist only inside those two primitives and inside the
behavioural memory arrays (`hiriscy_imem` ROM, `hiriscy_dmem` SRAM), which model
memory macros rather than discrete flip-flops.

## Directory Structure

```text
.
├── rtl/
│   ├── hiriscy_soc.v
│   ├── core/        # hiriscy_core + ifu/idu/exu/lsu/alu/rf
│   ├── lib/         # hiriscy_dff / hiriscy_dff_en (flip-flop primitives)
│   ├── mem/         # hiriscy_imem / hiriscy_dmem
│   └── pkg/         # hiriscy_defs.vh
├── tb/
│   ├── tb_hiriscy_soc.v
│   └── firmware.hex
├── sim/
│   ├── Makefile
│   ├── filelist.f
│   ├── setup_env.sh
│   └── README.md
└── README.md
```

## Run Simulation

The supported flow is VCS + Verdi:

```bash
cd sim
source ./setup_env.sh
make run
make verdi
```

`sim/Makefile` copies `../tb/firmware.hex` into the simulation run directory
before compiling/running, because `hiriscy_imem` loads `firmware.hex` via
`$readmemh`.

## Notes

- This repository no longer keeps CocoTB tests, design-report documents,
  firmware generation scripts, or synthesis logs.
- Generated VCS/Verdi artifacts are ignored by `.gitignore`.
