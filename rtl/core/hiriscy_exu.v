// ============================================================================
// hiriscy_exu.v — Execute Unit (EX datapath, combinational)
// ============================================================================
// Performs ALU computation, branch/jump resolution, mispredict detection,
// and branch-target misalignment detection.
//
// All operand selection is done in the ID stage:
//   op1_ex       : PC (JAL/JALR/AUIPC) or forwarded rs1 (everything else)
//   op2_ex       : imm (everything except R-type) or rs2 (R-type)
//   store_data   : forwarded rs2 (for STORE write data AND B-type comparison)
//   pc_base      : PC (JAL/B-type) or forwarded rs1 (JALR) — for branch target
//
// The ALU b-input selects: 4 for JAL/JALR (PC+4 return addr), store_data for
// B-type (rs2 comparison), op2 otherwise.  branch_target = pc_base + op2
// (op2 carries imm for all jumps/branches; JALR clears bit 0 of the sum).
//
// Exception detection: only branch-target misalignment here. The RAW flag
// is output (unmasked); the core uses it for internal flush/drain/halt and
// applies the configuration mask only on the external exceptions output.
// Illegal instruction is flagged in the IDU (ctrl[CTRL_ILLEGAL]).
// ============================================================================

module hiriscy_exu (
  // ID/EX register contents (operand MUXes already done in ID)
  input  wire [31:0]          pc_ex,          // actual PC (for exception reporting)
  input  wire [31:0]          pc_base_ex,     // branch target base (PC or rs1)
  input  wire [31:0]          op1_ex,         // ALU operand A
  input  wire [31:0]          op2_ex,         // ALU operand B / jump adder imm
  input  wire [31:0]          store_data_ex,  // forwarded rs2 (STORE + B-type compare)
  input  wire [43:0]          ctrl_ex,        // CTRL_W = 44

  // Datapath result to EX/MEM register
  output wire [31:0]          ex_result,

  // Branch resolution (to IFU next-PC + hazard)
  output wire                 branch_mispredict_ex,
  output wire [31:0]          branch_target_ex,

  // Raw branch-target misalignment flag (unmasked; core handles flush/drain
  // and applies the configuration mask only on the external output)
  output wire                 branch_misalign_raw
);

  `include "hiriscy_defs.vh"

  // ── ALU ───────────────────────────────────────────────────────────────
  // b-input priority: 4 for JAL/JALR (PC+4), store_data for B-type (rs2
  // comparison), op2_ex otherwise (imm for I/S/U-type, rs2 for R-type).
  wire is_branch_ex = (ctrl_ex[`CTRL_BR_TYPE] != BR_NONE);
  wire [31:0] alu_b = (ctrl_ex[`CTRL_JAL] | ctrl_ex[`CTRL_JALR]) ? 32'd4 :
                      is_branch_ex ? store_data_ex : op2_ex;
  wire [31:0] alu_result_ex;
  wire        alu_zero;

  hiriscy_alu u_alu (
    .a      (op1_ex),
    .b      (alu_b),
    .op     (ctrl_ex[`CTRL_ALU_OP]),
    .result (alu_result_ex),
    .zero   (alu_zero)
  );

  // ex_result = ALU result (PC+4 for JAL/JALR via op1=PC, b=4)
  assign ex_result = alu_result_ex;

  // ── Branch resolution ─────────────────────────────────────────────────
  // B-type: op1 = rs1, store_data = rs2 (comparison).  JAL/JALR: always taken.
  wire [2:0] br_type = ctrl_ex[`CTRL_BR_TYPE];
  wire branch_taken_ex =
    (br_type == BR_EQ)  ? (op1_ex == store_data_ex)                 :
    (br_type == BR_NE)  ? (op1_ex != store_data_ex)                 :
    (br_type == BR_LT)  ? ($signed(op1_ex) <  $signed(store_data_ex)) :
    (br_type == BR_GE)  ? ($signed(op1_ex) >= $signed(store_data_ex)) :
    (br_type == BR_LTU) ? (op1_ex <  store_data_ex)                 :
    (br_type == BR_GEU) ? (op1_ex >= store_data_ex)                 : 1'b0;

  // Branch target = pc_base + op2 (op2 = imm for all jumps/branches).  JALR clears bit 0.
  wire [31:0] branch_target_sum = pc_base_ex + op2_ex;
  wire [31:0] branch_target_computed = ctrl_ex[`CTRL_JALR] ?
    {branch_target_sum[31:1], 1'b0} : branch_target_sum;

  // ── Mispredict detection ──────────────────────────────────────────────
  // Static not-taken prediction: a branch/jump mispredicts when actually taken.
  wire is_branch_or_jump;
  assign is_branch_or_jump = (ctrl_ex[`CTRL_BR_TYPE] != BR_NONE) ||
                              ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR];

  wire actual_taken;
  assign actual_taken = branch_taken_ex || ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR];

  assign branch_mispredict_ex = is_branch_or_jump && actual_taken;
  assign branch_target_ex     = branch_target_computed;

  // ── Exception: branch-target misalignment ─────────────────────────────
  //  Raw flag (unmasked). The core uses it for internal flush/drain/halt;
  //  the configuration mask is applied only on the external exceptions output.
  assign branch_misalign_raw = is_branch_or_jump && actual_taken &&
                               (branch_target_computed[1:0] != 2'b00);

endmodule
