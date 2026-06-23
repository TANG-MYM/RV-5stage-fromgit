// ============================================================================
// hiriscy_idu.v — Instruction Decode Unit (IDU)
// ============================================================================
// Combinational decode of a 32-bit instruction into the control bundle plus
// register addresses and the sign-extended immediate. Register reads are done
// by the RF (hiriscy_rf) using the addresses produced here.
//
// This unit also owns all pipeline-HAZARD handling (previously a separate
// hiriscy_hazard block): load-use hazard detection, data-forwarding control,
// and the stall/flush signals. It remains purely combinational — every piece
// of pipeline STATE (the stage registers) lives in the core top, which simply
// feeds the EX/MEM/WB register addresses and write-enables back in here.
//
//   - Load-use hazard : a load in EX whose rd feeds the instruction now in ID
//                       -> stall IF/ID and bubble EX for one cycle.
//   - Forwarding      : EX/MEM and MEM/WB results bypassed into the EX operands
//                       (control sent to the EXU forwarding MUXes).
//   - Control hazard  : a taken branch/jump (or a WFI) redirects the front end
//                       -> flush ID and EX.
//
// SYSTEM handling: CSR/Zicsr and ECALL/EBREAK/MRET are NOT supported. WFI
// (0x10500073) is the only legal SYSTEM instruction; anything else is illegal.
// ============================================================================

module hiriscy_idu (
  // ── Instruction decode ────────────────────────────────────────────────
  input  wire [31:0]          instr,
  output wire [4:0]           rs1_addr,
  output wire [4:0]           rs2_addr,
  output wire [4:0]           rd_addr,
  output reg  [31:0]          imm,
  output reg  [43:0]          ctrl,   // CTRL_W = 44

  // ── Hazard inputs (taps from the core's pipeline registers) ───────────
  input  wire [4:0]           ex_rs1,      // EX-stage rs1 addr (forwarding)
  input  wire [4:0]           ex_rs2,      // EX-stage rs2 addr (forwarding)
  input  wire [4:0]           ex_rd,       // EX-stage rd addr  (load-use)
  input  wire                 ex_mem_rd,   // EX-stage is a load (load-use)
  input  wire [4:0]           mem_rd,
  input  wire                 mem_reg_wr,
  input  wire [4:0]           wb_rd,
  input  wire                 wb_reg_wr,
  input  wire                 branch_redirect, // taken branch/jump or WFI flush

  // ── Forwarding controls (to EXU) ──────────────────────────────────────
  output reg  [1:0]           fwd_rs1,
  output reg  [1:0]           fwd_rs2,

  // ── Pipeline control (to core stage registers) ───────────────────────
  output reg                  stall_if,
  output reg                  stall_id,
  output reg                  stall_ex,
  output reg                  flush_id,
  output reg                  flush_ex,
  output reg                  flush_mem
);

  `include "hiriscy_defs.vh"

  wire [6:0] opcode;
  wire [2:0] funct3;
  wire [6:0] funct7;

  assign opcode   = instr[6:0];
  assign funct3   = instr[14:12];
  assign funct7   = instr[31:25];
  assign rs1_addr = instr[19:15];
  assign rs2_addr = instr[24:20];
  assign rd_addr  = instr[11:7];

  // ── Immediate generation ─────────────────────────────────────────────
  always @(*) begin
    case (opcode)
      OP_LOAD, OP_JALR, OP_IMM, OP_SYSTEM:
        imm = {{20{instr[31]}}, instr[31:20]};
      OP_STORE:
        imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
      OP_BRANCH:
        imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
      OP_LUI, OP_AUIPC:
        imm = {instr[31:12], 12'b0};
      OP_JAL:
        imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
      default:
        imm = 32'b0;
    endcase
  end

  // ── Control signal generation ────────────────────────────────────────
  always @(*) begin
    // Defaults — everything off
    ctrl = {`CTRL_W{1'b0}};

    case (opcode)
      OP_LUI: begin
        ctrl[`CTRL_REG_WR]  = 1'b1;
        ctrl[`CTRL_ALU_OP]  = ALU_PASS_B;
        ctrl[`CTRL_ALU_SRC] = 1'b1;
        ctrl[`CTRL_WB_SEL]  = WB_ALU;
      end

      OP_AUIPC: begin
        ctrl[`CTRL_REG_WR]  = 1'b1;
        ctrl[`CTRL_ALU_OP]  = ALU_ADD;
        ctrl[`CTRL_ALU_SRC] = 1'b1;
        ctrl[`CTRL_WB_SEL]  = WB_ALU;
      end

      OP_JAL: begin
        ctrl[`CTRL_JAL]     = 1'b1;
        ctrl[`CTRL_REG_WR]  = 1'b1;
        ctrl[`CTRL_WB_SEL]  = WB_PC4;
      end

      OP_JALR: begin
        ctrl[`CTRL_JALR]    = 1'b1;
        ctrl[`CTRL_REG_WR]  = 1'b1;
        ctrl[`CTRL_ALU_SRC] = 1'b1;
        ctrl[`CTRL_ALU_OP]  = ALU_ADD;
        ctrl[`CTRL_WB_SEL]  = WB_PC4;
      end

      OP_BRANCH: begin
        case (funct3)
          3'b000: ctrl[`CTRL_BR_TYPE] = BR_EQ;
          3'b001: ctrl[`CTRL_BR_TYPE] = BR_NE;
          3'b100: ctrl[`CTRL_BR_TYPE] = BR_LT;
          3'b101: ctrl[`CTRL_BR_TYPE] = BR_GE;
          3'b110: ctrl[`CTRL_BR_TYPE] = BR_LTU;
          3'b111: ctrl[`CTRL_BR_TYPE] = BR_GEU;
          default: ctrl[`CTRL_ILLEGAL] = 1'b1;
        endcase
      end

      OP_LOAD: begin
        ctrl[`CTRL_MEM_RD]    = 1'b1;
        ctrl[`CTRL_REG_WR]    = 1'b1;
        ctrl[`CTRL_ALU_SRC]   = 1'b1;
        ctrl[`CTRL_ALU_OP]    = ALU_ADD;
        ctrl[`CTRL_WB_SEL]    = WB_MEM;
        ctrl[`CTRL_MEM_WIDTH] = funct3[1:0];
        ctrl[`CTRL_MEM_SIGN]  = ~funct3[2];
      end

      OP_STORE: begin
        ctrl[`CTRL_MEM_WR]    = 1'b1;
        ctrl[`CTRL_ALU_SRC]   = 1'b1;
        ctrl[`CTRL_ALU_OP]    = ALU_ADD;
        ctrl[`CTRL_MEM_WIDTH] = funct3[1:0];
      end

      OP_IMM: begin
        ctrl[`CTRL_REG_WR]  = 1'b1;
        ctrl[`CTRL_ALU_SRC] = 1'b1;
        ctrl[`CTRL_WB_SEL]  = WB_ALU;
        case (funct3)
          3'b000: ctrl[`CTRL_ALU_OP] = ALU_ADD;
          3'b001: ctrl[`CTRL_ALU_OP] = ALU_SLL;
          3'b010: ctrl[`CTRL_ALU_OP] = ALU_SLT;
          3'b011: ctrl[`CTRL_ALU_OP] = ALU_SLTU;
          3'b100: ctrl[`CTRL_ALU_OP] = ALU_XOR;
          3'b101: ctrl[`CTRL_ALU_OP] = funct7[5] ? ALU_SRA : ALU_SRL;
          3'b110: ctrl[`CTRL_ALU_OP] = ALU_OR;
          3'b111: ctrl[`CTRL_ALU_OP] = ALU_AND;
        endcase
      end

      OP_REG: begin
        if (funct7 == 7'b0000001) begin
          // RV32M removed — multiply/divide instructions are illegal in RV32I
          ctrl[`CTRL_ILLEGAL] = 1'b1;
        end else begin
          ctrl[`CTRL_REG_WR] = 1'b1;
          ctrl[`CTRL_WB_SEL] = WB_ALU;
          case (funct3)
            3'b000: ctrl[`CTRL_ALU_OP] = funct7[5] ? ALU_SUB : ALU_ADD;
            3'b001: ctrl[`CTRL_ALU_OP] = ALU_SLL;
            3'b010: ctrl[`CTRL_ALU_OP] = ALU_SLT;
            3'b011: ctrl[`CTRL_ALU_OP] = ALU_SLTU;
            3'b100: ctrl[`CTRL_ALU_OP] = ALU_XOR;
            3'b101: ctrl[`CTRL_ALU_OP] = funct7[5] ? ALU_SRA : ALU_SRL;
            3'b110: ctrl[`CTRL_ALU_OP] = ALU_OR;
            3'b111: ctrl[`CTRL_ALU_OP] = ALU_AND;
          endcase
        end
      end

      OP_SYSTEM: begin
        // CSR/trap (Zicsr, ECALL/EBREAK/MRET) support removed.
        // Only WFI (0x10500073) remains; everything else is illegal.
        if (funct3 == 3'b000 && instr[31:20] == 12'h105)
          ctrl[`CTRL_WFI] = 1'b1;
        else
          ctrl[`CTRL_ILLEGAL] = 1'b1;
      end

      OP_FENCE: begin
        ctrl[`CTRL_FENCE] = 1'b1;
      end

      default: begin
        ctrl[`CTRL_ILLEGAL] = 1'b1;
      end
    endcase
  end

  // ════════════════════════════════════════════════════════════════════
  // Hazard detection & data forwarding (integrated, combinational)
  // ════════════════════════════════════════════════════════════════════

  // ── Load-use hazard ───────────────────────────────────────────────────
  // A load currently in EX produces its data too late for the dependent
  // instruction in ID; stall one cycle so the value can later be forwarded.
  wire load_use_hazard;
  assign load_use_hazard = ex_mem_rd && (ex_rd != 5'd0) &&
                           ((ex_rd == rs1_addr) || (ex_rd == rs2_addr));

  // ── Data forwarding (based on EX-stage source addresses) ──────────────
  always @(*) begin
    // RS1
    if (mem_reg_wr && (mem_rd != 5'd0) && (mem_rd == ex_rs1))
      fwd_rs1 = FWD_EX_MEM;
    else if (wb_reg_wr && (wb_rd != 5'd0) && (wb_rd == ex_rs1))
      fwd_rs1 = FWD_MEM_WB;
    else
      fwd_rs1 = FWD_NONE;

    // RS2
    if (mem_reg_wr && (mem_rd != 5'd0) && (mem_rd == ex_rs2))
      fwd_rs2 = FWD_EX_MEM;
    else if (wb_reg_wr && (wb_rd != 5'd0) && (wb_rd == ex_rs2))
      fwd_rs2 = FWD_MEM_WB;
    else
      fwd_rs2 = FWD_NONE;
  end

  // ── Stall / flush logic ───────────────────────────────────────────────
  always @(*) begin
    stall_if  = 1'b0;
    stall_id  = 1'b0;
    stall_ex  = 1'b0;
    flush_id  = 1'b0;
    flush_ex  = 1'b0;
    flush_mem = 1'b0;

    // Load-use: freeze IF/ID, drop a bubble into EX.
    if (load_use_hazard) begin
      stall_if = 1'b1;
      stall_id = 1'b1;
      flush_ex = 1'b1;
    end

    // Control hazard (taken branch/jump or WFI flush): kill the wrongly
    // fetched instructions in ID and EX. Flush wins over any stall above.
    if (branch_redirect) begin
      flush_id = 1'b1;
      flush_ex = 1'b1;
      stall_if = 1'b0;
      stall_id = 1'b0;
    end
  end

endmodule
