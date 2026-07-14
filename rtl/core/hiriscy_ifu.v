// ============================================================================
// hiriscy_ifu.v — Instruction Fetch Unit (IF datapath, combinational)
// ============================================================================
// Computes the next-PC and drives the instruction-memory request. All fetch
// state (the PC register itself) lives in the core top; this unit is purely
// combinational.
//
// Branch prediction is STATIC "always not-taken": the fetch unit always
// predicts the sequential path (PC+4). Branches and jumps are resolved in EX;
// when a branch/jump is actually taken the EX stage signals a mispredict and
// the corrected target is fetched. There is therefore no predictor state and
// no separate BPU module.
//
// Next-PC priority:
//   1. EX-stage branch/jump taken (mispredict) -> corrected target
//   2. Sequential PC + 4 (the static not-taken prediction)
//
// WFI gating: while a WFI is draining (wfi_active) or the core is parked in
// WFI idle (wfi_idle), instruction fetch is stopped (imem_rd deasserted).
// ============================================================================

module hiriscy_ifu (
  input  wire [31:0] pc_if,

  // EX-stage branch resolution
  input  wire        branch_mispredict_ex,
  input  wire [31:0] branch_target_ex,

  // WFI fetch gating
  input  wire        wfi_active,
  input  wire        wfi_idle,

  // Outputs
  output wire [31:0] pc_next,
  output wire [31:0] imem_addr,
  output wire        imem_rd
);

  // Static not-taken prediction: take the sequential path unless EX corrects us.
  assign pc_next   = branch_mispredict_ex ? branch_target_ex : (pc_if + 32'd4);

  assign imem_addr = pc_if;
  assign imem_rd   = ~(wfi_active | wfi_idle);   // WFI stops instruction fetch

endmodule
