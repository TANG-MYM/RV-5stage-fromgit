// ============================================================================
// hiriscy_exu.v — Execute Unit (EX datapath, combinational)
// ============================================================================
// Performs operand forwarding, ALU computation, branch/jump resolution,
// mispredict detection, exception detection and the EX-stage writeback select.
// Instantiates hiriscy_alu. All EX pipeline state (the ID/EX register) lives in
// the core top.
//
// Forwarding inputs:
//   fwd_ex_mem_data : EX/MEM ALU/PC result (tap from EX/MEM register)
//   fwd_mem_wb_data : MEM/WB writeback data (tap from MEM/WB writeback mux)
// ============================================================================

module hiriscy_exu (
  // ID/EX register contents
  input  wire [31:0]          pc_ex,
  input  wire [43:0]          ctrl_ex,       // CTRL_W = 44
  input  wire [31:0]          rs1_data_ex,
  input  wire [31:0]          rs2_data_ex,
  input  wire [31:0]          imm_ex,

  // Forwarding controls + taps
  input  wire [1:0]           fwd_rs1,
  input  wire [1:0]           fwd_rs2,
  input  wire [31:0]          fwd_ex_mem_data,
  input  wire [31:0]          fwd_mem_wb_data,

  // Exception masks (1 = SUPPRESS)
  input  wire [1:0]           configuration,

  // Datapath results to EX/MEM register
  output wire [31:0]          ex_result,
  output wire [31:0]          store_data,    // forwarded rs2 (store data)

  // Branch resolution (to IFU next-PC + hazard)
  output wire                 branch_mispredict_ex,
  output wire [31:0]          branch_target_ex,

  // Exception report (to core control FSM)
  output wire [1:0]           exceptions_next,
  output wire                 any_exc
);

  `include "hiriscy_defs.vh"

  // ── Forwarding MUXes ──────────────────────────────────────────────────
  wire [31:0] rs1_fwd = (fwd_rs1 == FWD_EX_MEM) ? fwd_ex_mem_data :
                        (fwd_rs1 == FWD_MEM_WB) ? fwd_mem_wb_data : rs1_data_ex;
  wire [31:0] rs2_fwd = (fwd_rs2 == FWD_EX_MEM) ? fwd_ex_mem_data :
                        (fwd_rs2 == FWD_MEM_WB) ? fwd_mem_wb_data : rs2_data_ex;

  assign store_data = rs2_fwd;

  // ── ALU ───────────────────────────────────────────────────────────────
  wire [31:0] alu_b, alu_result_ex;
  wire        alu_zero;

  assign alu_b = ctrl_ex[`CTRL_ALU_SRC] ? imm_ex : rs2_fwd;

  hiriscy_alu u_alu (
    .a      (rs1_fwd),
    .b      (alu_b),
    .op     (ctrl_ex[`CTRL_ALU_OP]),
    .result (alu_result_ex),
    .zero   (alu_zero)
  );

  // ── Branch resolution ─────────────────────────────────────────────────
  wire [2:0] br_type = ctrl_ex[`CTRL_BR_TYPE];
  wire branch_taken_ex =
    (br_type == BR_EQ)  ? (rs1_fwd == rs2_fwd)                 :
    (br_type == BR_NE)  ? (rs1_fwd != rs2_fwd)                 :
    (br_type == BR_LT)  ? ($signed(rs1_fwd) <  $signed(rs2_fwd)) :
    (br_type == BR_GE)  ? ($signed(rs1_fwd) >= $signed(rs2_fwd)) :
    (br_type == BR_LTU) ? (rs1_fwd <  rs2_fwd)                 :
    (br_type == BR_GEU) ? (rs1_fwd >= rs2_fwd)                 : 1'b0;

  wire [31:0] branch_target_computed = ctrl_ex[`CTRL_JALR] ?
    {alu_result_ex[31:1], 1'b0} : (pc_ex + imm_ex);

  // ── Mispredict detection ──────────────────────────────────────────────
  // The front end predicts STATIC not-taken (sequential PC+4). A branch/jump
  // therefore mispredicts exactly when it is actually taken; otherwise the
  // sequential prediction was correct and nothing is redirected.
  wire is_branch_or_jump;
  assign is_branch_or_jump = (ctrl_ex[`CTRL_BR_TYPE] != BR_NONE) ||
                              ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR];

  wire actual_taken;
  assign actual_taken = branch_taken_ex || ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR];

  assign branch_mispredict_ex = is_branch_or_jump && actual_taken;

  // Only consumed by the IFU when branch_mispredict_ex is asserted (i.e. when
  // actual_taken is true), so the computed target is always the right value.
  assign branch_target_ex = branch_target_computed;

  // ── Exception detection ───────────────────────────────────────────────
  //  - PC-misaligned : a taken branch/jump whose target is not 4-byte aligned
  //  - illegal instr : decoder flagged the EX-stage instruction as illegal
  //  configuration[i] = 1 SUPPRESSES the corresponding exception.
  wire exc_misalign_raw = is_branch_or_jump && actual_taken &&
                          (branch_target_computed[1:0] != 2'b00);
  wire exc_illegal_raw  = ctrl_ex[`CTRL_ILLEGAL];

  wire exc_misalign = exc_misalign_raw & ~configuration[0];
  wire exc_illegal  = exc_illegal_raw  & ~configuration[1];

  assign exceptions_next = {exc_illegal, exc_misalign};
  assign any_exc         = exc_misalign | exc_illegal;

  // ── EX result select ──────────────────────────────────────────────────
  // WB_PC4 -> return address (PC+4); everything else (WB_ALU / WB_MEM path)
  // carries the ALU result forward (the LSU substitutes load data in MEM).
  assign ex_result = (ctrl_ex[`CTRL_WB_SEL] == WB_PC4) ? (pc_ex + 32'd4)
                                                       : alu_result_ex;

endmodule
