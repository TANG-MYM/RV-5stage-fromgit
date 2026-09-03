module hiriscy_exu (

  input  wire [31:0]          pc_ex,
  input  wire [31:0]          pc_base_ex,
  input  wire [31:0]          op1_ex,
  input  wire [31:0]          op2_ex,
  input  wire [31:0]          store_data_ex,
  input  wire [43:0]          ctrl_ex,

  output wire [31:0]          ex_result,

  output wire                 branch_mispredict_ex,
  output wire [31:0]          branch_target_ex,

  output wire                 branch_misalign_raw
);

  `include "hiriscy_defs.vh"

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

  assign ex_result = alu_result_ex;

  wire [2:0] br_type = ctrl_ex[`CTRL_BR_TYPE];
  wire branch_taken_ex =
    (br_type == BR_EQ)  ? (op1_ex == store_data_ex)                 :
    (br_type == BR_NE)  ? (op1_ex != store_data_ex)                 :
    (br_type == BR_LT)  ? ($signed(op1_ex) <  $signed(store_data_ex)) :
    (br_type == BR_GE)  ? ($signed(op1_ex) >= $signed(store_data_ex)) :
    (br_type == BR_LTU) ? (op1_ex <  store_data_ex)                 :
    (br_type == BR_GEU) ? (op1_ex >= store_data_ex)                 : 1'b0;

  wire [31:0] branch_target_sum = pc_base_ex + op2_ex;
  wire [31:0] branch_target_computed = ctrl_ex[`CTRL_JALR] ?
    {branch_target_sum[31:1], 1'b0} : branch_target_sum;

  wire is_branch_or_jump;
  assign is_branch_or_jump = (ctrl_ex[`CTRL_BR_TYPE] != BR_NONE) ||
                              ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR];

  wire actual_taken;
  assign actual_taken = branch_taken_ex || ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR];

  assign branch_mispredict_ex = is_branch_or_jump && actual_taken;
  assign branch_target_ex     = branch_target_computed;

  assign branch_misalign_raw = is_branch_or_jump && actual_taken &&
                               (branch_target_computed[1:0] != 2'b00);

endmodule
