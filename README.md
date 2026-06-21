# BRV32P — 5-Stage Pipelined RV32I Core

This project is a simulation-focused RV32I 5-stage pipeline written in Verilog.
The current structure is intentionally small: no cache, no AXI bus, no
peripherals, and no synthesis log archive.

## Current Architecture

| Block | Description |
|---|---|
| `brv32p_core` | 5-stage in-order RV32I pipeline: IF / ID / EX / MEM / WB |
| `imem_rom` | Instruction ROM, `IMEM_DEPTH x 32`, `$readmemh("firmware.hex")` |
| `dmem_sram` | 4 KB data SRAM, simple next-cycle ready handshake |
| `brv32p_soc` | Top wrapper with run/pause/start-PC and exception status ports |

The SoC top interface exposes:

| Signal | Direction | Description |
|---|---|---|
| `clk` / `rst_n` | input | Clock and active-low reset |
| `start_pause` | input | Rising edge restarts from `start_pc`; level `1` runs, `0` pauses |
| `start_pc[11:0]` | input | Restart PC byte address |
| `configuration[1:0]` | input | Exception masks, `1` means suppress |
| `core_status[1:0]` | output | `00` paused, `01` running, `10` halted on exception |
| `exceptions[1:0]` | output | `[0]` PC misaligned, `[1]` illegal instruction |

## Directory Structure

```text
.
├── rtl/
│   ├── brv32p_soc.v
│   ├── core/
│   ├── mem/
│   └── pkg/
├── tb/
│   ├── tb_brv32p_soc.v
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
before compiling/running, because `imem_rom` loads `firmware.hex` via
`$readmemh`.

## Notes

- This repository no longer keeps CocoTB tests, design-report documents,
  firmware generation scripts, or synthesis logs.
- Generated VCS/Verdi artifacts are ignored by `.gitignore`.
