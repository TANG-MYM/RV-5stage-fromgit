module hiriscy_idu (

  input  wire [31:0]          instr,
  input  wire [31:0]          pc_id,
  output wire [4:0]           rs1_addr,
  output wire [4:0]           rs2_addr,
  output wire [4:0]           rd_addr,
  output wire [43:0]          ctrl,

  input  wire [31:0]          rs1_data_raw,
  input  wire [31:0]          rs2_data_raw,

  input  wire [31:0]          ex_result,
  input  wire [31:0]          mem_result,
  input  wire [31:0]          mem_result_wb,

  input  wire [4:0]           ex_rd,
  input  wire                 ex_reg_wr,
  input  wire                 ex_mem_rd,
  input  wire [4:0]           mem_rd,
  input  wire                 mem_reg_wr,
  input  wire [4:0]           wb_rd,
  input  wire                 wb_reg_wr,
  input  wire                 branch_redirect,

  input  wire [43:0]          ctrl_ex_full,
  input  wire [43:0]          ctrl_mem_full,

  output wire [31:0]          op1,
  output wire [31:0]          op2,
  output wire [31:0]          store_data,
  output wire [31:0]          pc_base,

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

  wire is_muldiv = is_reg && (funct7 == 7'b0000001);
  wire is_wfi    = is_system && (funct3 == 3'b000) && (instr[31:20] == 12'h105);

  wire known_opcode = is_lui | is_auipc | is_jal | is_jalr | is_branch |
                      is_load | is_store | is_imm | is_reg | is_fence | is_system;

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

  wire reg_wr = is_lui | is_auipc | is_jal | is_jalr | is_load | is_imm |
                (is_reg & ~is_muldiv);

  wire alu_src = is_lui | is_auipc | is_jal | is_jalr | is_load | is_store | is_imm;

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

  wire [2:0] wb_sel = is_load ? WB_MEM : WB_ALU;

  wire        dec_mem_rd    = is_load;
  wire        dec_mem_wr    = is_store;
  wire [1:0]  dec_mem_width = (is_load | is_store) ? funct3[1:0] : 2'b00;
  wire        dec_mem_sign  = is_load ? ~funct3[2] : 1'b0;

  wire [2:0] br_type = is_branch ? (
      (funct3 == 3'b000) ? BR_EQ  :
      (funct3 == 3'b001) ? BR_NE  :
      (funct3 == 3'b100) ? BR_LT  :
      (funct3 == 3'b101) ? BR_GE  :
      (funct3 == 3'b110) ? BR_LTU :
      (funct3 == 3'b111) ? BR_GEU : BR_NONE
    ) : BR_NONE;

  wire branch_illegal = is_branch  & ((funct3 == 3'b010) | (funct3 == 3'b011));
  wire system_illegal = is_system  & ~is_wfi;
  wire illegal = ~known_opcode | branch_illegal | system_illegal | is_muldiv;

  assign ctrl[`CTRL_ALU_OP]    = alu_op;
  assign ctrl[`CTRL_ALU_SRC]   = alu_src;
  assign ctrl[`CTRL_MULDIV_EN] = 1'b0;
  assign ctrl[`CTRL_MULDIV_OP] = 3'b0;
  assign ctrl[`CTRL_MEM_RD]    = dec_mem_rd;
  assign ctrl[`CTRL_MEM_WR]    = dec_mem_wr;
  assign ctrl[`CTRL_MEM_WIDTH] = dec_mem_width;
  assign ctrl[`CTRL_MEM_SIGN]  = dec_mem_sign;
  assign ctrl[`CTRL_REG_WR]    = reg_wr;
  assign ctrl[`CTRL_WB_SEL]    = wb_sel;
  assign ctrl[`CTRL_BR_TYPE]   = br_type;
  assign ctrl[`CTRL_JAL]       = is_jal;
  assign ctrl[`CTRL_JALR]      = is_jalr;
  assign ctrl[20:5]            = 16'b0;
  assign ctrl[`CTRL_WFI]       = is_wfi;
  assign ctrl[3:2]             = 2'b0;
  assign ctrl[`CTRL_FENCE]     = is_fence;
  assign ctrl[`CTRL_ILLEGAL]   = illegal;

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

  wire [31:0] rs1_data_fwd = (fwd_rs1_sel == FWD_EX)  ? ex_result      :
                            (fwd_rs1_sel == FWD_MEM) ? mem_result     :
                            (fwd_rs1_sel == FWD_WB)  ? mem_result_wb  : rs1_data_raw;

  wire uses_rs2 = is_reg | is_store | is_branch;
  wire [31:0] rs2_data_fwd = (fwd_rs2_sel == FWD_EX)  ? ex_result      :
                            (fwd_rs2_sel == FWD_MEM) ? mem_result     :
                            (fwd_rs2_sel == FWD_WB)  ? mem_result_wb  : rs2_data_raw;

  wire op1_sel_pc = is_jal | is_jalr | is_auipc;
  assign op1 = op1_sel_pc ? pc_id : rs1_data_fwd;

  assign op2 = is_reg ? rs2_data_fwd : imm;

  assign store_data = rs2_data_fwd;

  assign pc_base = is_jalr ? rs1_data_fwd : pc_id;

  wire uses_rs1 = is_jalr | is_branch | is_load | is_store | is_imm | is_reg;

  wire ex_load_use = ex_mem_rd & (ex_rd != 5'd0) &
                     ((uses_rs1 & (ex_rd == rs1_addr)) |
                      (uses_rs2 & (ex_rd == rs2_addr)));
  wire load_use_hazard = ex_load_use;

  wire ex_is_bubble    = (ctrl_ex_full  == {`CTRL_W{1'b0}});
  wire mem_is_bubble   = (ctrl_mem_full == {`CTRL_W{1'b0}});
  wire pipeline_drained = ex_is_bubble & mem_is_bubble;

  wire wfi_stall       = is_wfi & ~pipeline_drained;
  wire wfi_leaving_id  = is_wfi &  pipeline_drained & ~load_use_hazard;

  assign stall_if  = (load_use_hazard & ~branch_redirect) | wfi_stall;
  assign stall_id  = (load_use_hazard & ~branch_redirect) | wfi_stall;
  assign stall_ex  = 1'b0;
  assign flush_id  = branch_redirect | wfi_leaving_id;
  assign flush_ex  = load_use_hazard | branch_redirect | wfi_stall;
  assign flush_mem = 1'b0;

endmodule
