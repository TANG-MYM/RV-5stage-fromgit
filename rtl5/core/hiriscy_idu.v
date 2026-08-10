// ============================================================================
// hiriscy_idu.v — Instruction Decode Unit (IDU, pure combinational assign-based)
// ============================================================================
// Combinational decode of a 32-bit instruction into the control bundle plus
// register addresses and the sign-extended immediate. Register reads are done
// by the RF (hiriscy_rf) using the addresses produced here; the RF outputs
// (combinational) are fed back into this unit for forwarding and operand MUX.
//
// This unit owns ALL of the ID-stage datapath plus pipeline-HAZARD handling:
//
//   1. Decode          : opcode/funct3/funct7 → control bundle + addresses + imm
//   2. Forwarding MUX  : 3-stage (EX/MEM/WB) forwarded rs1/rs2 selected here
//   3. Operand MUXes   : op1 (PC or rs1), op2 (imm or rs2), store_data (rs2),
//                        pc_base (PC or rs1, for branch target in EX)
//   4. Hazard detect   : load-use stall, WFI drain stall, branch/WFI flush
//   5. Exception detect : illegal instruction (raw flag in ctrl; the core
//                        uses it for flush/drain/halt and applies the
//                        configuration mask only on the external output)
//
// Forwarding MUX selects the newest available value for rs1/rs2:
//   EX (combinational ALU output) > MEM (LSU output) > WB (MEM/WB reg) > RF
//   EX can't forward a load (data not ready — handled by load-use stall).
//
// Operand MUX strategy (keeps EXU simple — no MUXes in EX):
//   op1 = (JAL|JALR|AUIPC) ? PC : rs1_fwd   — ALU computes PC+4 or PC+imm
//   op2 = is_reg ? rs2_fwd : imm            — rs2 for R-type ALU; imm for
//                                            everything else (incl. B-type,
//                                            whose rs2 comes via store_data)
//   pc_base = JALR ? rs1_fwd : PC           — branch target = pc_base + op2
//   store_data = rs2_fwd                    — rs2 for STORE write data AND
//                                            B-type branch comparison (in EX)
//
// WFI handling: WFI is stalled in ID until the pipeline drains (EX and MEM
// are both bubbles). This ensures all older instructions have retired before
// WFI executes. While WFI sits in ID, fetch is stopped (wfi_in_id in core)
// and a bubble is injected into ID/EX each cycle (flush_ex). When the
// pipeline drains, WFI is released to EX and a NOP is injected into IF/ID
// (wfi_leaving_id -> flush_id) so no stale fetch enters the pipeline.
//
// SYSTEM handling: CSR/Zicsr and ECALL/EBREAK/MRET are NOT supported. WFI
// (0x10500073) is the only legal SYSTEM instruction; anything else is illegal.
// ============================================================================

module hiriscy_idu (
  // ── Instruction decode ────────────────────────────────────────────────
  input  wire [31:0]          instr,
  input  wire [31:0]          pc_id,          // PC of this instruction (for op1/pc_base MUX)
  output wire [4:0]           rs1_addr,
  output wire [4:0]           rs2_addr,
  output wire [4:0]           rd_addr,
  output wire [43:0]          ctrl,           // CTRL_W = 44

  // ── RF read data (combinational from hiriscy_rf) ─────────────────────
  input  wire [31:0]          rs1_data_raw,
  input  wire [31:0]          rs2_data_raw,

  // ── Forwarding sources (from later pipeline stages) ──────────────────
  input  wire [31:0]          ex_result,      // EX combinational ALU output
  input  wire [31:0]          mem_result,     // MEM stage LSU output
  input  wire [31:0]          mem_result_wb,  // WB stage MEM/WB register

  // ── Hazard taps (from core's pipeline registers) ─────────────────────
  input  wire [4:0]           ex_rd,          // EX-stage rd addr
  input  wire                 ex_reg_wr,      // EX-stage writes back
  input  wire                 ex_mem_rd,       // EX-stage is a load (load-use)
  input  wire [4:0]           mem_rd,
  input  wire                 mem_reg_wr,
  input  wire [4:0]           wb_rd,
  input  wire                 wb_reg_wr,
  input  wire                 branch_redirect, // taken branch/jump or WFI flush

  // ── Full ctrl bundles for WFI drain detection ───────────────────────
  input  wire [43:0]          ctrl_ex_full,   // EX-stage ctrl (bubble detect)
  input  wire [43:0]          ctrl_mem_full,  // MEM-stage ctrl (bubble detect)

  // ── ID-stage datapath outputs (to ID/EX register) ────────────────────
  output wire [31:0]          op1,            // ALU operand A (PC or forwarded rs1)
  output wire [31:0]          op2,            // ALU operand B (imm or forwarded rs2)
  output wire [31:0]          store_data,     // forwarded rs2 (for STORE write data)
  output wire [31:0]          pc_base,        // branch target base (PC or forwarded rs1)

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

  // ── Immediate generation (internal; no longer output — op2 carries imm) ─
  wire [31:0] imm;
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

  // ALU B operand source flag (stored in ctrl for reference; the actual op2
  // MUX below uses is_reg directly, and EXU's alu_b overrides for JAL/JALR/B)
  wire alu_src = is_lui | is_auipc | is_jal | is_jalr | is_load | is_store | is_imm;

  // ALU op — JAL/JALR use ADD (op1=PC, ALU b=4 → PC+4); AUIPC uses ADD (PC+imm)
  wire [3:0] alu_op_imm = (funct3 == 3'b000) ? ALU_ADD  :
                          (funct3 == 3'b001) ? ALU_SLL  :
                          (funct3 == 3'b010) ? ALU_SLT  :
                          (funct3 == 3'b011) ? ALU_SLTU :
                          (funct3 == 3'b100) ? ALU_XOR  :
                          (funct3 == 3'b101) ? (funct7[5] ? ALU_SRA : ALU_SRL) :
                          (funct3 == 3'b110) ? ALU_OR   : ALU_AND;
  wire [3:0] alu_op_reg = (funct3 == 3'b000) ? (funct7[5] ? ALU_SUB : ALU_ADD) :
                          alu_op_imm;

  wire [3:0] alu_op = is_lui                                              ? ALU_PASS_B   :
                       (is_jal | is_auipc | is_jalr | is_load | is_store)   ? ALU_ADD      :
                       is_imm                                                ? alu_op_imm   :
                       is_reg                                                ? alu_op_reg   :
                                                                           ALU_ADD;

  // Write-back source select — ALU now handles PC+4 for JAL/JALR directly,
  // so WB_PC4 is no longer needed; everything is WB_ALU except loads (WB_MEM).
  wire [2:0] wb_sel = is_load ? WB_MEM : WB_ALU;

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

  // Illegal instruction detection (raw flag; core handles flush/drain/halt
  // and applies the configuration mask only on the external output)
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
  // 3-stage forwarding (EX/MEM/WB at ID) + operand MUXes
  // ════════════════════════════════════════════════════════════════════

  // ── Forwarding select (compare ID rs1/rs2 with EX/MEM/WB rd) ──────────
  // Priority: EX > MEM > WB (EX is newest). EX can't forward a load
  // (load data not available in EX — handled by load-use stall).
  wire ex_rd_addr_nz  = (ex_rd  != 5'd0);
  wire mem_rd_addr_nz = (mem_rd != 5'd0);
  wire wb_rd_addr_nz  = (wb_rd  != 5'd0);
  wire ex_can_fwd     = ex_reg_wr & ~ex_mem_rd & ex_rd_addr_nz;

  wire [1:0] fwd_rs1_sel =
    (ex_can_fwd  & (ex_rd  == rs1_addr)) ? FWD_EX  :
    (mem_reg_wr  & mem_rd_addr_nz & (mem_rd == rs1_addr)) ? FWD_MEM :
    (wb_reg_wr   & wb_rd_addr_nz  & (wb_rd  == rs1_addr)) ? FWD_WB  : FWD_NONE;

  wire [1:0] fwd_rs2_sel =
    (ex_can_fwd  & (ex_rd  == rs2_addr)) ? FWD_EX  :
    (mem_reg_wr  & mem_rd_addr_nz & (mem_rd == rs2_addr)) ? FWD_MEM :
    (wb_reg_wr   & wb_rd_addr_nz  & (wb_rd  == rs2_addr)) ? FWD_WB  : FWD_NONE;

  // ── Forwarding MUX (inside IDU) ───────────────────────────────────────
  wire [31:0] rs1_data_fwd = (fwd_rs1_sel == FWD_EX)  ? ex_result      :
                            (fwd_rs1_sel == FWD_MEM) ? mem_result     :
                            (fwd_rs1_sel == FWD_WB)  ? mem_result_wb  : rs1_data_raw;

  // Only forward rs2 when the ID instruction actually uses rs2 (R-type/STORE/
  // BRANCH). I-type/U-type/J-type have instr[24:20] as immediate, not rs2.
  wire uses_rs2 = is_reg | is_store | is_branch;
  wire [31:0] rs2_data_fwd = (fwd_rs2_sel == FWD_EX)  ? ex_result      :
                            (fwd_rs2_sel == FWD_MEM) ? mem_result     :
                            (fwd_rs2_sel == FWD_WB)  ? mem_result_wb  : rs2_data_raw;

  // ── Operand MUXes (all in ID stage, nothing in EX) ────────────────────
  // op1: PC when the instruction returns a PC-based value to rd (JAL/JALR/AUIPC);
  //      otherwise forwarded rs1.
  wire op1_sel_pc = is_jal | is_jalr | is_auipc;
  assign op1 = op1_sel_pc ? pc_id : rs1_data_fwd;

  // op2: rs2 for R-type (ALU operation); imm for everything else.
  // B-type gets imm here for the jump adder; its rs2 comparison uses store_data.
  // ALU overrides op2 with constant 4 for JAL/JALR (PC+4) in EXU.
  assign op2 = is_reg ? rs2_data_fwd : imm;

  // store_data: forwarded rs2 (for STORE write data, independent of op2 which = imm)
  assign store_data = rs2_data_fwd;

  // pc_base: branch target base. JALR uses rs1 (target = rs1 + imm);
  //          everything else uses PC (target = PC + imm).
  assign pc_base = is_jalr ? rs1_data_fwd : pc_id;

  // ════════════════════════════════════════════════════════════════════
  // Hazard detection & stall / flush
  // ════════════════════════════════════════════════════════════════════

  // rs1 is actually used by: JALR (pc_base), B-type/LOAD/STORE/I-type/R-type (op1)
  wire uses_rs1 = is_jalr | is_branch | is_load | is_store | is_imm | is_reg;

  // ── Load-use hazard ───────────────────────────────────────────────────
  // A load in EX can't forward its data from EX (dmem read initiated in EX,
  // data available in MEM next cycle). Stall one cycle so the value can be
  // forwarded from MEM.
  wire ex_load_use = ex_mem_rd & (ex_rd != 5'd0) &
                     ((uses_rs1 & (ex_rd == rs1_addr)) |
                      (uses_rs2 & (ex_rd == rs2_addr)));
  wire load_use_hazard = ex_load_use;

  // ── WFI stall: wait for older instructions to drain ───────────────────
  // WFI must not execute until all older instructions have retired. Stall
  // WFI in ID (freeze IF/ID, inject bubble into ID/EX) until both EX and
  // MEM are bubbles (pipeline drained). When drained, let WFI proceed to
  // EX and inject a NOP into IF/ID (wfi_leaving_id -> flush_id) so no stale
  // fetched instruction enters the pipeline.
  wire ex_is_bubble    = (ctrl_ex_full  == {`CTRL_W{1'b0}});
  wire mem_is_bubble   = (ctrl_mem_full == {`CTRL_W{1'b0}});
  wire pipeline_drained = ex_is_bubble & mem_is_bubble;

  wire wfi_stall       = is_wfi & ~pipeline_drained;
  wire wfi_leaving_id  = is_wfi &  pipeline_drained & ~load_use_hazard;

  // ── Stall / flush logic ───────────────────────────────────────────────
  // Load-use: freeze IF/ID + bubble EX.
  // WFI stall: freeze IF/ID + bubble EX (same pattern as load-use).
  // WFI leaving: inject NOP into IF/ID, let WFI flow to EX.
  // Control redirect (branch/WFI flush): flush ID/EX, wins over load-use.
  assign stall_if  = (load_use_hazard & ~branch_redirect) | wfi_stall;
  assign stall_id  = (load_use_hazard & ~branch_redirect) | wfi_stall;
  assign stall_ex  = 1'b0;
  assign flush_id  = branch_redirect | wfi_leaving_id;
  assign flush_ex  = load_use_hazard | branch_redirect | wfi_stall;
  assign flush_mem = 1'b0;

endmodule
