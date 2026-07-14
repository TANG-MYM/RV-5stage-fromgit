// ============================================================================
// hiriscy_idu.v — Instruction Decode Unit (IDU, pure combinational assign-based)
// ============================================================================
// Combinational decode of a 32-bit instruction into the control bundle plus
// register addresses and the sign-extended immediate. Register reads are done
// by the RF (hiriscy_rf) using the addresses produced here.
//
// This unit also owns all pipeline-HAZARD handling (previously a separate
// hiriscy_hazard block): load-use hazard detection, data-forwarding control,
// and the stall/flush signals. It is expressed entirely with continuous
// assignments — every piece of pipeline STATE (the stage registers) lives in
// the core top, which feeds the EX/MEM/WB register addresses/enables back here.
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
  output wire [31:0]          imm,
  output wire [43:0]          ctrl,   // CTRL_W = 44

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
  output wire [1:0]           fwd_rs1,
  output wire [1:0]           fwd_rs2,

  // ── Pipeline control (to core stage registers) ───────────────────────
  output wire                 stall_if,
  output wire                 stall_id,
  output wire                 stall_ex,
  output wire                 flush_id,
  output wire                 flush_ex,
  output wire                 flush_mem
);

  `include "hiriscy_defs.vh"

  wire [6:0] opcode = instr[6:0];
  wire [2:0] funct3 = instr[14:12];
  wire [6:0] funct7 = instr[31:25];

  assign rs1_addr = instr[19:15];
  assign rs2_addr = instr[24:20];
  assign rd_addr  = instr[11:7];

  // ── Opcode one-hot decode ─────────────────────────────────────────────
  wire is_lui    = (opcode == OP_LUI);
  wire is_auipc  = (opcode == OP_AUIPC);
  wire is_jal    = (opcode == OP_JAL);
  wire is_jalr   = (opcode == OP_JALR);
  wire is_branch = (opcode == OP_BRANCH);
  wire is_load   = (opcode == OP_LOAD);
  wire is_store  = (opcode == OP_STORE);
  wire is_imm    = (opcode == OP_IMM);
  wire is_reg    = (opcode == OP_REG);
  wire is_fence  = (opcode == OP_FENCE);
  wire is_system = (opcode == OP_SYSTEM);

  wire is_muldiv = is_reg && (funct7 == 7'b0000001); // RV32M removed -> illegal
  wire is_wfi    = is_system && (funct3 == 3'b000) && (instr[31:20] == 12'h105);

  wire known_opcode = is_lui | is_auipc | is_jal | is_jalr | is_branch |
                      is_load | is_store | is_imm | is_reg | is_fence | is_system;

  // ── Immediate generation ─────────────────────────────────────────────
  assign imm =
    (is_load | is_jalr | is_imm | is_system) ?
        {{20{instr[31]}}, instr[31:20]} :
    is_store ?
        {{20{instr[31]}}, instr[31:25], instr[11:7]} :
    is_branch ?
        {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0} :
    (is_lui | is_auipc) ?
        {instr[31:12], 12'b0} :
    is_jal ?
        {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0} :
        32'b0;

  // ── Control field decode ──────────────────────────────────────────────
  // Register write-back enable
  wire reg_wr = is_lui | is_auipc | is_jal | is_jalr | is_load | is_imm |
                (is_reg & ~is_muldiv);

  // ALU B operand = immediate (else forwarded rs2)
  wire alu_src = is_lui | is_auipc | is_jalr | is_load | is_store | is_imm;

  // ALU op for OP_IMM / OP_REG (shared, only funct3==000 differs on funct7[5])
  wire [3:0] alu_op_imm = (funct3 == 3'b000) ? ALU_ADD  :
                          (funct3 == 3'b001) ? ALU_SLL  :
                          (funct3 == 3'b010) ? ALU_SLT  :
                          (funct3 == 3'b011) ? ALU_SLTU :
                          (funct3 == 3'b100) ? ALU_XOR  :
                          (funct3 == 3'b101) ? (funct7[5] ? ALU_SRA : ALU_SRL) :
                          (funct3 == 3'b110) ? ALU_OR   : ALU_AND;
  wire [3:0] alu_op_reg = (funct3 == 3'b000) ? (funct7[5] ? ALU_SUB : ALU_ADD) :
                          alu_op_imm;

  wire [3:0] alu_op = is_lui                                    ? ALU_PASS_B :
                      (is_auipc | is_jalr | is_load | is_store) ? ALU_ADD    :
                      is_imm                                    ? alu_op_imm :
                      is_reg                                    ? alu_op_reg :
                                                                  ALU_ADD;

  // Write-back source select
  wire [2:0] wb_sel = (is_jal | is_jalr) ? WB_PC4 :
                      is_load            ? WB_MEM : WB_ALU;

  // Memory controls (dec_ prefix avoids clashing with the MEM-stage hazard
  // input ports mem_rd / mem_reg_wr further down)
  wire        dec_mem_rd    = is_load;
  wire        dec_mem_wr    = is_store;
  wire [1:0]  dec_mem_width = (is_load | is_store) ? funct3[1:0] : 2'b00;
  wire        dec_mem_sign  = is_load ? ~funct3[2] : 1'b0;

  // Branch type
  wire [2:0] br_type = is_branch ? (
      (funct3 == 3'b000) ? BR_EQ  :
      (funct3 == 3'b001) ? BR_NE  :
      (funct3 == 3'b100) ? BR_LT  :
      (funct3 == 3'b101) ? BR_GE  :
      (funct3 == 3'b110) ? BR_LTU :
      (funct3 == 3'b111) ? BR_GEU : BR_NONE
    ) : BR_NONE;

  // Illegal instruction detection
  wire branch_illegal = is_branch  & ((funct3 == 3'b010) | (funct3 == 3'b011));
  wire system_illegal = is_system  & ~is_wfi;
  wire illegal = ~known_opcode | branch_illegal | system_illegal | is_muldiv;

  // ── Control bundle assembly (each bit driven exactly once) ────────────
  assign ctrl[`CTRL_ALU_OP]    = alu_op;
  assign ctrl[`CTRL_ALU_SRC]   = alu_src;
  assign ctrl[`CTRL_MULDIV_EN] = 1'b0;             // reserved (RV32M removed)
  assign ctrl[`CTRL_MULDIV_OP] = 3'b0;             // reserved
  assign ctrl[`CTRL_MEM_RD]    = dec_mem_rd;
  assign ctrl[`CTRL_MEM_WR]    = dec_mem_wr;
  assign ctrl[`CTRL_MEM_WIDTH] = dec_mem_width;
  assign ctrl[`CTRL_MEM_SIGN]  = dec_mem_sign;
  assign ctrl[`CTRL_REG_WR]    = reg_wr;
  assign ctrl[`CTRL_WB_SEL]    = wb_sel;
  assign ctrl[`CTRL_BR_TYPE]   = br_type;
  assign ctrl[`CTRL_JAL]       = is_jal;
  assign ctrl[`CTRL_JALR]      = is_jalr;
  assign ctrl[20:5]            = 16'b0;             // reserved (former Zicsr)
  assign ctrl[`CTRL_WFI]       = is_wfi;
  assign ctrl[3:2]             = 2'b0;              // reserved (former EBREAK/MRET)
  assign ctrl[`CTRL_FENCE]     = is_fence;
  assign ctrl[`CTRL_ILLEGAL]   = illegal;

  // ════════════════════════════════════════════════════════════════════
  // Hazard detection & data forwarding
  // ════════════════════════════════════════════════════════════════════

  // ── Data forwarding (based on EX-stage source addresses) ──────────────
  wire mem_rd_addr_nz = (mem_rd != 5'd0);
  wire wb_rd_addr_nz  = (wb_rd  != 5'd0);

  assign fwd_rs1 =
    (mem_reg_wr & mem_rd_addr_nz & (mem_rd == ex_rs1)) ? FWD_EX_MEM :
    (wb_reg_wr  & wb_rd_addr_nz  & (wb_rd  == ex_rs1)) ? FWD_MEM_WB : FWD_NONE;
  assign fwd_rs2 =
    (mem_reg_wr & mem_rd_addr_nz & (mem_rd == ex_rs2)) ? FWD_EX_MEM :
    (wb_reg_wr  & wb_rd_addr_nz  & (wb_rd  == ex_rs2)) ? FWD_MEM_WB : FWD_NONE;

  // ── Load-use hazard ───────────────────────────────────────────────────
  // A load currently in EX produces its data too late for the dependent
  // instruction in ID; stall one cycle so the value can later be forwarded.
  wire load_use_hazard = ex_mem_rd & (ex_rd != 5'd0) &
                         ((ex_rd == rs1_addr) | (ex_rd == rs2_addr));

  // ── Stall / flush logic ───────────────────────────────────────────────
  // Load-use: freeze IF/ID + bubble EX. Control redirect: flush ID/EX and win
  // over the load-use stall (flush has priority).
  assign stall_if  = load_use_hazard & ~branch_redirect;
  assign stall_id  = load_use_hazard & ~branch_redirect;
  assign stall_ex  = 1'b0;
  assign flush_id  = branch_redirect;
  assign flush_ex  = load_use_hazard | branch_redirect;
  assign flush_mem = 1'b0;

endmodule
