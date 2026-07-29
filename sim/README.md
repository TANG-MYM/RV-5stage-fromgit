# HiRiscy SoC Simulation Environment (VCS + Verdi)

## Directory Structure

```
sim/
├── Makefile          — VCS/Verdi build & run flow
├── filelist.f        — RTL + testbench source list
├── setup_env.sh      — environment setup (VCS_HOME, VERDI_HOME, license)
└── README.md         — this file

tb/
├── tb_hiriscy_soc.v              — SoC testbench (+TEST= selection)
├── firmware.hex                  — default functional firmware
├── firmware_basic.hex            — basic functional test (copy of firmware.hex)
├── firmware_exc_illegal.hex      — illegal instruction exception test
├── firmware_exc_branch_misalign.hex — branch target misalign test
├── firmware_exc_priority.hex     — illegal + fetch misalign priority test
└── firmware_exc_fetch_misalign.hex — (uses start_pc=1, same as basic hex)
```

## Quick Start

```bash
cd sim
source ./setup_env.sh     # set VCS_HOME / VERDI_HOME / license

make comp                 # compile
make run                  # run default functional test (firmware.hex)
make verdi                # open waveform in Verdi
```

## Running Specific Tests

The testbench supports `+TEST=<name>` to select a test scenario:

```bash
make run TEST=basic                   # basic ALU / forwarding / load-store / branch
make run TEST=exc_illegal             # illegal instruction exception
make run TEST=exc_branch_misalign     # branch target misalign exception
make run TEST=exc_priority            # exception priority (illegal > fetch misalign)
make run TEST=exc_fetch_misalign      # fetch PC misalign (start_pc=1)
```

## Run All Tests

```bash
make test_all
```

This runs every test scenario, logs output to `test_results.log`, and prints a
summary of any failures.

## Test Scenarios

### 1. `basic` — Functional Test
Exercises ALU operations (ADD, SUB, AND, OR, XOR, SLL, SRL, SLT), data
forwarding (EX→MEM→WB→RF), load-use stall, store-then-load, branch taken,
JAL, and a countdown loop. Verifies register file and DMEM contents.

### 2. `exc_illegal` — Illegal Instruction Exception
```
0x00: lui  x10, 0x10000      ; DMEM base
0x04: addi x1,  x0, 42       ; x1 = 42      (retires)
0x08: addi x2,  x0, 10       ; x2 = 10      (retires)
0x0C: add  x3,  x1, x2       ; x3 = 52      (retires, forwarding)
0x10: sw   x3,  0(x10)       ; DMEM[0]=52   (retires, older store)
0x14: 0x00000000              ; illegal opcode → exception
0x18: addi x5,  x0, 99       ; must NOT execute
```
Expected: `exceptions[1]=1` (illegal), `exceptions_pc=0x14`, core halts.
Older instructions (x1, x2, x3, DMEM[0]) retire; younger (x5) does not.

### 3. `exc_branch_misalign` — Branch Target Misalign
```
0x00: addi x1, x0, 42        ; x1 = 42      (retires)
0x04: addi x2, x0, 10        ; x2 = 10      (retires)
0x08: beq  x0, x0, +2        ; target=0x0A, misaligned → exception
0x0C: addi x5, x0, 99        ; must NOT execute (flushed)
```
Expected: `exceptions[0]=1` (misalign), `exceptions_pc=0x08`, core halts.

### 4. `exc_priority` — Exception Priority
Illegal instruction (detected in ID, older) and fetch misalign (detected
in IF, younger) occur simultaneously. The older exception (illegal) must
be reported.
```
0x00: addi x1, x0, 42        ; retires
0x04: addi x2, x0, 10        ; retires
0x08: add  x3, x1, x2        ; retires
0x0C: sw   x3, 0(x10)        ; retires
0x10: 0x00000000              ; illegal (ID stage)
0x14: 0x00000000              ; fetch misalign (IF stage, younger)
```
Expected: `exceptions[1]=1` (illegal wins), `exceptions_pc=0x10`.

### 5. `exc_fetch_misalign` — Fetch PC Misalign
Uses `start_pc=1` (misaligned). The very first fetch triggers a misalign
exception in IF. No instructions execute.
Expected: `exceptions[0]=1`, `exceptions_pc=0x01`.

## Precise Exception Handling

The core implements precise exceptions:
1. **Detection**: Exception detected at IF (fetch misalign), ID (illegal),
   or EX (branch misalign) stage.
2. **Stop fetch**: `stop_fetch_exc` halts instruction fetch immediately.
3. **Flush younger**: Faulting and younger instructions are flushed.
4. **Drain older**: Older instructions continue to execute and retire.
5. **Halt**: When the back end is empty (`backend_empty`), the core halts
   and reports the latched exception cause and PC.

The `configuration` mask only affects the external `exceptions` output;
internal pipeline control uses raw (unmasked) exception events.

## Waveform Debug

### VCS + Verdi (FSDB)
```bash
make comp                 # FSDB dump enabled via +define+FSDB
make run TEST=exc_illegal
make verdi                # open Verdi with FSDB + KDB source debug
```

### VCD (if Verdi unavailable)
```bash
make run TEST=exc_illegal RUN_ARGS="+VCD"
# opens hiriscy_soc.vcd — view with gtkwave or similar
```

## Cleanup
```bash
make clean
```
