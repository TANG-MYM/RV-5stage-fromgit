// ============================================================================
// hiriscy_defs.vh — Shared definitions for the HiRiscy pipelined RISC-V core
// ============================================================================
// Plain-Verilog defines/localparams (iverilog/VCS friendly).
// Include this file inside module bodies after port declarations.
// ============================================================================

// ── ctrl_t field position defines (global, guarded) ──────────────────
`ifndef HIRISCY_CTRL_DEFS
`define HIRISCY_CTRL_DEFS
`define CTRL_W          44
`define CTRL_ALU_OP     43:40
`define CTRL_ALU_SRC    39
`define CTRL_MULDIV_EN  38      // unused in RV32I (kept to preserve ctrl bit layout)
`define CTRL_MULDIV_OP  37:35   // unused in RV32I (kept to preserve ctrl bit layout)
`define CTRL_MEM_RD     34
`define CTRL_MEM_WR     33
`define CTRL_MEM_WIDTH  32:31
`define CTRL_MEM_SIGN   30
`define CTRL_REG_WR     29
`define CTRL_WB_SEL     28:26
`define CTRL_BR_TYPE    25:23
`define CTRL_JAL        22
`define CTRL_JALR       21
// bits [20:5] reserved (formerly Zicsr CSR_EN/CSR_OP/CSR_ADDR — CSR support removed)
`define CTRL_WFI        4       // Wait-For-Interrupt (reuses former ECALL bit)
// bits [3:2] reserved (formerly EBREAK/MRET — trap support removed)
`define CTRL_FENCE      1
`define CTRL_ILLEGAL    0
`endif

// ── Instruction Opcodes ──────────────────────────────────────────────
localparam [6:0] OP_LUI    = 7'b0110111;
localparam [6:0] OP_AUIPC  = 7'b0010111;
localparam [6:0] OP_JAL    = 7'b1101111;
localparam [6:0] OP_JALR   = 7'b1100111;
localparam [6:0] OP_BRANCH = 7'b1100011;
localparam [6:0] OP_LOAD   = 7'b0000011;
localparam [6:0] OP_STORE  = 7'b0100011;
localparam [6:0] OP_IMM    = 7'b0010011;
localparam [6:0] OP_REG    = 7'b0110011;
localparam [6:0] OP_FENCE  = 7'b0001111;
localparam [6:0] OP_SYSTEM = 7'b1110011;

// ── ALU Operations ───────────────────────────────────────────────────
localparam [3:0] ALU_ADD    = 4'b0000;
localparam [3:0] ALU_SUB    = 4'b1000;
localparam [3:0] ALU_SLL    = 4'b0001;
localparam [3:0] ALU_SLT    = 4'b0010;
localparam [3:0] ALU_SLTU   = 4'b0011;
localparam [3:0] ALU_XOR    = 4'b0100;
localparam [3:0] ALU_SRL    = 4'b0101;
localparam [3:0] ALU_SRA    = 4'b1101;
localparam [3:0] ALU_OR     = 4'b0110;
localparam [3:0] ALU_AND    = 4'b0111;
localparam [3:0] ALU_PASS_B = 4'b1111;

// ── Writeback source select ──────────────────────────────────────────
localparam [2:0] WB_ALU    = 3'd0;
localparam [2:0] WB_MEM    = 3'd1;
localparam [2:0] WB_PC4    = 3'd2;

// ── Memory access width ──────────────────────────────────────────────
localparam [1:0] MEM_BYTE = 2'b00;
localparam [1:0] MEM_HALF = 2'b01;
localparam [1:0] MEM_WORD = 2'b10;

// ── Branch type ──────────────────────────────────────────────────────
localparam [2:0] BR_NONE = 3'b000;
localparam [2:0] BR_EQ   = 3'b001;
localparam [2:0] BR_NE   = 3'b010;
localparam [2:0] BR_LT   = 3'b011;
localparam [2:0] BR_GE   = 3'b100;
localparam [2:0] BR_LTU  = 3'b101;
localparam [2:0] BR_GEU  = 3'b110;

// ── Forward select ───────────────────────────────────────────────────
localparam [1:0] FWD_NONE   = 2'b00;
localparam [1:0] FWD_EX_MEM = 2'b01;
localparam [1:0] FWD_MEM_WB = 2'b10;

// ── Memory Map ───────────────────────────────────────────────────────
localparam [31:0] RESET_VECTOR = 32'h0000_0000;
localparam [31:0] IMEM_BASE    = 32'h0000_0000;
localparam [31:0] DMEM_BASE    = 32'h1000_0000;
