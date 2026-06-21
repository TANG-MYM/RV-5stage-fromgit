// ============================================================================
// brv32p_core.v — 5-Stage Pipelined RV32I CPU Core
// ----------------------------------------------------------------------------
// External run control & exception monitor:
//   start_pause   : level run/pause. A rising edge (re)starts from start_pc;
//                   while high the core runs, while low it freezes (pause).
//   start_pc      : 12-bit byte address used as the (re)start PC.
//   configuration : exception masks (1 = SUPPRESS that exception).
//                     [0] PC-misaligned, [1] illegal instruction
//   exceptions    : detected-and-not-suppressed exceptions (latched on halt).
//                     [0] PC-misaligned, [1] illegal instruction
//   core_status   : per-bit status, both cleared by a Start pulse (start_pause
//                   rising edge, which re-fetches from start_pc):
//                     [0] IDLE : set on exception halt OR after a WFI retires
//                     [1] WFI  : set after a WFI retires
//                   So {[1],[0]} = 00 running/paused, 01 exception halt,
//                   11 WFI idle.
//
// NOTE: CSR/Zicsr and the trap mechanism (ECALL/EBREAK/MRET, mtvec/mepc,
//       interrupts) have been removed from this core. WFI is the only
//       remaining SYSTEM instruction: it drains older instructions, stops
//       fetch, flushes younger instructions, and parks the core in IDLE.
// ============================================================================

module brv32p_core (
  input  wire        clk,
  input  wire        rst_n,

  // Run control / status
  input  wire        start_pause,
  input  wire [11:0] start_pc,
  input  wire [1:0]  configuration,
  output wire [1:0]  core_status,
  output wire [1:0]  exceptions,
  output wire [31:0] exceptions_pc,       // PC of the faulting instruction (latched on halt)

  // Instruction memory interface
  output wire [31:0] imem_addr,
  output wire        imem_rd,
  input  wire [31:0] imem_rdata,
  input  wire        imem_ready,

  // Data memory interface
  output wire [31:0] dmem_addr,
  output wire        dmem_rd,
  output wire        dmem_wr,
  output wire [1:0]  dmem_width,
  output wire        dmem_sign_ext,
  output wire [31:0] dmem_wdata,
  input  wire [31:0] dmem_rdata,
  input  wire        dmem_ready,

  // Interrupts
  input  wire        ext_irq,
  input  wire        timer_irq
);

  `include "brv32p_defs.vh"

  // ════════════════════════════════════════════════════════════════════
  // Pipeline control signals
  // ════════════════════════════════════════════════════════════════════
  wire stall_if, stall_id, stall_ex;
  wire flush_id, flush_ex, flush_mem;
  wire [1:0] fwd_rs1, fwd_rs2;
  wire mem_stall;
  wire dmem_stall;
  wire imem_stall;

  assign dmem_stall = (dmem_rd | dmem_wr) & ~dmem_ready;
  assign imem_stall = imem_rd & ~imem_ready;
  assign mem_stall  = dmem_stall | imem_stall;

  // ════════════════════════════════════════════════════════════════════
  // Run / Pause / Restart control + exception halt
  // ════════════════════════════════════════════════════════════════════
  reg         start_pause_d;
  reg         halted;          // set when an unmasked exception is detected
  reg  [1:0]  exceptions_r;    // latched exception cause
  reg  [31:0] exceptions_pc_r; // latched PC of the faulting instruction
  wire [1:0]  exceptions_next; // exception(s) detected this cycle (after mask)
  wire        any_exc;         // any unmasked exception this cycle (EX stage)

  // WFI (Wait-For-Interrupt) state
  reg         wfi_active;      // WFI in flight: draining older instrs, fetch stopped
  reg         wfi_idle;        // WFI retired -> core parked in IDLE until Start pulse

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) start_pause_d <= 1'b0;
    else        start_pause_d <= start_pause;
  end

  wire restart = start_pause & ~start_pause_d;        // rising edge -> (re)start
  wire run     = start_pause & ~halted & ~wfi_idle;   // pipeline advances only when running

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      halted          <= 1'b0;
      exceptions_r    <= 2'b0;
      exceptions_pc_r <= 32'b0;
    end else if (restart) begin
      halted          <= 1'b0;
      exceptions_r    <= 2'b0;
      exceptions_pc_r <= 32'b0;
    end else if (run && !halted && any_exc) begin
      halted          <= 1'b1;
      exceptions_r    <= exceptions_next;
      exceptions_pc_r <= pc_ex;          // EX-stage PC == faulting instruction's PC
    end
  end

  // ── WFI control ─────────────────────────────────────────────────────────
  //  1. WFI reaches EX  -> wfi_active: stop fetch, flush younger instructions,
  //     let WFI plus all older (in MEM/WB) instructions drain in program order.
  //  2. WFI reaches WB  -> it retires; core enters wfi_idle (IDLE state).
  //  3. A new Start pulse (start_pause rising edge) clears the state and the
  //     pipeline (via `restart`) and re-fetches from start_pc.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wfi_active <= 1'b0;
      wfi_idle   <= 1'b0;
    end else if (restart) begin
      wfi_active <= 1'b0;
      wfi_idle   <= 1'b0;
    end else if (run) begin
      if (ctrl_wb[`CTRL_WFI]) begin           // WFI retiring in WB
        wfi_active <= 1'b0;
        wfi_idle   <= 1'b1;
      end else if (ctrl_ex[`CTRL_WFI]) begin  // WFI reached EX
        wfi_active <= 1'b1;
      end
    end
  end

  assign exceptions    = exceptions_r;
  assign exceptions_pc = exceptions_pc_r;
  // core_status[0] = IDLE : high on exception halt or after a WFI retires;
  //                         driven low again by a Start pulse (restart).
  // core_status[1] = WFI  : high after a WFI retires; low again on a Start pulse.
  assign core_status[0] = halted | wfi_idle;
  assign core_status[1] = wfi_idle;

  // ════════════════════════════════════════════════════════════════════
  // IF — Instruction Fetch
  // ════════════════════════════════════════════════════════════════════
  reg  [31:0] pc_if;
  reg  [31:0] pc_next;
  wire [31:0] instr_raw_if;
  wire        bp_pred_taken;
  wire [31:0] bp_pred_target;
  wire        bp_pred_valid;

  // PC Register
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      pc_if <= {20'b0, start_pc};
    else if (restart)
      pc_if <= {20'b0, start_pc};         // (re)start from start_pc
    else if (run && !stall_if && !mem_stall && !wfi_active)
      pc_if <= pc_next;
    // else: paused / stalled / WFI -> hold (stop fetch)
  end

  assign imem_addr = pc_if;
  assign imem_rd   = ~(wfi_active | wfi_idle);   // WFI stops instruction fetch
  assign instr_raw_if = imem_rdata;

  // Branch predictor
  wire        bp_update_en;
  wire [31:0] bp_update_pc, bp_update_target;
  wire        bp_update_taken;

  branch_predictor u_bp (
    .clk         (clk),
    .rst_n       (rst_n),
    .pc          (pc_if),
    .pred_taken  (bp_pred_taken),
    .pred_target (bp_pred_target),
    .pred_valid  (bp_pred_valid),
    .update_en   (bp_update_en),
    .update_pc   (bp_update_pc),
    .update_taken(bp_update_taken),
    .update_target(bp_update_target)
  );

  // Next PC MUX
  wire        branch_mispredict_ex;
  wire [31:0] branch_target_ex;

  always @(*) begin
    if (branch_mispredict_ex)
      pc_next = branch_target_ex;
    else if (bp_pred_taken && bp_pred_valid)
      pc_next = bp_pred_target;
    else
      pc_next = pc_if + 32'd4;
  end

  // ════════════════════════════════════════════════════════════════════
  // IF/ID Pipeline Register
  // ════════════════════════════════════════════════════════════════════
  reg [31:0] pc_id, instr_id;
  reg        pred_taken_id;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || restart) begin
      pc_id         <= 32'b0;
      instr_id      <= 32'h0000_0013; // NOP
      pred_taken_id <= 1'b0;
    end else if (run) begin
      if (flush_id) begin
        pc_id         <= 32'b0;
        instr_id      <= 32'h0000_0013; // NOP
        pred_taken_id <= 1'b0;
      end else if (!stall_id && !mem_stall) begin
        pc_id         <= pc_if;
        instr_id      <= instr_raw_if;
        pred_taken_id <= bp_pred_taken && bp_pred_valid;
      end
    end
    // else: paused -> hold
  end

  // ════════════════════════════════════════════════════════════════════
  // ID — Instruction Decode
  // ════════════════════════════════════════════════════════════════════
  wire [4:0]          rs1_addr_id, rs2_addr_id, rd_addr_id;
  wire [31:0]         imm_id;
  wire [`CTRL_W-1:0]  ctrl_id;
  wire [31:0]         rs1_data_raw, rs2_data_raw;

  decoder u_decoder (
    .instr    (instr_id),
    .rs1_addr (rs1_addr_id),
    .rs2_addr (rs2_addr_id),
    .rd_addr  (rd_addr_id),
    .imm      (imm_id),
    .ctrl     (ctrl_id)
  );

  // Register file
  wire        wb_wr_en;
  wire [4:0]  wb_rd_addr;
  reg  [31:0] wb_rd_data;

  regfile u_regfile (
    .clk      (clk),
    .rst_n    (rst_n),
    .rs1_addr (rs1_addr_id),
    .rs1_data (rs1_data_raw),
    .rs2_addr (rs2_addr_id),
    .rs2_data (rs2_data_raw),
    .wr_en    (wb_wr_en),
    .rd_addr  (wb_rd_addr),
    .rd_data  (wb_rd_data)
  );

  // ════════════════════════════════════════════════════════════════════
  // ID/EX Pipeline Register
  // ════════════════════════════════════════════════════════════════════
  reg [31:0]         pc_ex, rs1_data_ex, rs2_data_ex, imm_ex;
  reg [4:0]          rs1_addr_ex, rs2_addr_ex, rd_addr_ex;
  reg [`CTRL_W-1:0]  ctrl_ex;
  reg                pred_taken_ex;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || restart) begin
      ctrl_ex       <= {`CTRL_W{1'b0}};
      pc_ex         <= 32'b0;
      rs1_data_ex   <= 32'b0;
      rs2_data_ex   <= 32'b0;
      imm_ex        <= 32'b0;
      rs1_addr_ex   <= 5'b0;
      rs2_addr_ex   <= 5'b0;
      rd_addr_ex    <= 5'b0;
      pred_taken_ex <= 1'b0;
    end else if (run) begin
      if (flush_ex) begin
        ctrl_ex       <= {`CTRL_W{1'b0}};
        pc_ex         <= 32'b0;
        rs1_data_ex   <= 32'b0;
        rs2_data_ex   <= 32'b0;
        imm_ex        <= 32'b0;
        rs1_addr_ex   <= 5'b0;
        rs2_addr_ex   <= 5'b0;
        rd_addr_ex    <= 5'b0;
        pred_taken_ex <= 1'b0;
      end else if (!stall_ex && !mem_stall) begin
        ctrl_ex       <= ctrl_id;
        pc_ex         <= pc_id;
        rs1_data_ex   <= rs1_data_raw;
        rs2_data_ex   <= rs2_data_raw;
        imm_ex        <= imm_id;
        rs1_addr_ex   <= rs1_addr_id;
        rs2_addr_ex   <= rs2_addr_id;
        rd_addr_ex    <= rd_addr_id;
        pred_taken_ex <= pred_taken_id;
      end
    end
    // else: paused -> hold
  end

  // ════════════════════════════════════════════════════════════════════
  // EX — Execute
  // ════════════════════════════════════════════════════════════════════

  // Forwarding MUXes
  reg  [31:0] rs1_fwd, rs2_fwd;
  wire [31:0] alu_result_mem;  // From EX/MEM register
  wire [31:0] wb_data_fwd;     // From MEM/WB

  always @(*) begin
    case (fwd_rs1)
      FWD_EX_MEM:  rs1_fwd = alu_result_mem;
      FWD_MEM_WB:  rs1_fwd = wb_data_fwd;
      default:     rs1_fwd = rs1_data_ex;
    endcase
    case (fwd_rs2)
      FWD_EX_MEM:  rs2_fwd = alu_result_mem;
      FWD_MEM_WB:  rs2_fwd = wb_data_fwd;
      default:     rs2_fwd = rs2_data_ex;
    endcase
  end

  // ALU
  wire [31:0] alu_b, alu_result_ex;
  wire        alu_zero;

  assign alu_b = ctrl_ex[`CTRL_ALU_SRC] ? imm_ex : rs2_fwd;

  alu u_alu (
    .a      (rs1_fwd),
    .b      (alu_b),
    .op     (ctrl_ex[`CTRL_ALU_OP]),
    .result (alu_result_ex),
    .zero   (alu_zero)
  );

  // AUIPC result
  wire [31:0] auipc_result;
  assign auipc_result = pc_ex + imm_ex;

  // Branch resolution
  reg  branch_taken_ex;
  wire [31:0] branch_target_computed;

  always @(*) begin
    branch_taken_ex = 1'b0;
    case (ctrl_ex[`CTRL_BR_TYPE])
      BR_EQ:  branch_taken_ex = (rs1_fwd == rs2_fwd);
      BR_NE:  branch_taken_ex = (rs1_fwd != rs2_fwd);
      BR_LT:  branch_taken_ex = ($signed(rs1_fwd) < $signed(rs2_fwd));
      BR_GE:  branch_taken_ex = ($signed(rs1_fwd) >= $signed(rs2_fwd));
      BR_LTU: branch_taken_ex = (rs1_fwd < rs2_fwd);
      BR_GEU: branch_taken_ex = (rs1_fwd >= rs2_fwd);
      default: branch_taken_ex = 1'b0;
    endcase
  end

  assign branch_target_computed = ctrl_ex[`CTRL_JALR] ?
    {alu_result_ex[31:1], 1'b0} : (pc_ex + imm_ex);

  // Mispredict detection
  wire is_branch_or_jump;
  assign is_branch_or_jump = (ctrl_ex[`CTRL_BR_TYPE] != BR_NONE) ||
                              ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR];

  wire actual_taken;
  assign actual_taken = branch_taken_ex || ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR];

  assign branch_mispredict_ex = is_branch_or_jump &&
    ((actual_taken != pred_taken_ex) ||
     (actual_taken && (branch_target_computed != pc_ex + 32'd4)));

  assign branch_target_ex = actual_taken ? branch_target_computed :
                            (pc_ex + 32'd4);

  // ── Exception detection (EX stage) ─────────────────────────────────────
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

  // Branch predictor update
  assign bp_update_en     = (ctrl_ex[`CTRL_BR_TYPE] != BR_NONE);
  assign bp_update_pc     = pc_ex;
  assign bp_update_taken  = branch_taken_ex;
  assign bp_update_target = branch_target_computed;

  // WFI flush: while a WFI is in flight (EX or draining), kill younger
  // instructions in ID/EX so they never commit.
  wire wfi_flush = ctrl_ex[`CTRL_WFI] | wfi_active;

  // EX result select
  reg [31:0] ex_result;
  always @(*) begin
    case (ctrl_ex[`CTRL_WB_SEL])
      WB_ALU:    ex_result = alu_result_ex;
      WB_PC4:    ex_result = pc_ex + 32'd4;
      default:   ex_result = alu_result_ex;
    endcase
  end

  // ════════════════════════════════════════════════════════════════════
  // EX/MEM Pipeline Register
  // ════════════════════════════════════════════════════════════════════
  reg [31:0]         ex_result_mem, rs2_data_mem;
  reg [4:0]          rd_addr_mem;
  reg [`CTRL_W-1:0]  ctrl_mem;

  assign alu_result_mem = ex_result_mem;  // Forwarding tap

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || restart) begin
      ctrl_mem       <= {`CTRL_W{1'b0}};
      ex_result_mem  <= 32'b0;
      rs2_data_mem   <= 32'b0;
      rd_addr_mem    <= 5'b0;
    end else if (run) begin
      if (flush_mem) begin
        ctrl_mem       <= {`CTRL_W{1'b0}};
        ex_result_mem  <= 32'b0;
        rs2_data_mem   <= 32'b0;
        rd_addr_mem    <= 5'b0;
      end else if (!mem_stall) begin
        ctrl_mem       <= ctrl_ex;
        ex_result_mem  <= ex_result;
        rs2_data_mem   <= rs2_fwd;
        rd_addr_mem    <= rd_addr_ex;
      end
    end
    // else: paused -> hold
  end

  // ════════════════════════════════════════════════════════════════════
  // MEM — Memory Access
  // ════════════════════════════════════════════════════════════════════
  assign dmem_addr     = ex_result_mem;
  assign dmem_rd       = ctrl_mem[`CTRL_MEM_RD] & run;
  assign dmem_wr       = ctrl_mem[`CTRL_MEM_WR] & run;
  assign dmem_width    = ctrl_mem[`CTRL_MEM_WIDTH];
  assign dmem_sign_ext = ctrl_mem[`CTRL_MEM_SIGN];
  assign dmem_wdata    = rs2_data_mem;

  // MEM result
  wire [31:0] mem_result;
  assign mem_result = ctrl_mem[`CTRL_MEM_RD] ? dmem_rdata : ex_result_mem;

  // ════════════════════════════════════════════════════════════════════
  // MEM/WB Pipeline Register
  // ════════════════════════════════════════════════════════════════════
  reg [31:0]         mem_result_wb;
  reg [4:0]          rd_addr_wb;
  reg [`CTRL_W-1:0]  ctrl_wb;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || restart) begin
      ctrl_wb       <= {`CTRL_W{1'b0}};
      mem_result_wb <= 32'b0;
      rd_addr_wb    <= 5'b0;
    end else if (run && !mem_stall) begin
      ctrl_wb       <= ctrl_mem;
      mem_result_wb <= mem_result;
      rd_addr_wb    <= rd_addr_mem;
    end
    // else: paused -> hold
  end

  // ════════════════════════════════════════════════════════════════════
  // WB — Writeback
  // ════════════════════════════════════════════════════════════════════
  always @(*) begin
    wb_rd_data = mem_result_wb;   // WB_ALU/WB_PC4 fold into mem_result via EX
  end

  assign wb_wr_en   = ctrl_wb[`CTRL_REG_WR];
  assign wb_rd_addr = rd_addr_wb;
  assign wb_data_fwd = wb_rd_data;  // Forwarding tap

  // ════════════════════════════════════════════════════════════════════
  // Hazard Unit
  // ════════════════════════════════════════════════════════════════════
  hazard_unit u_hazard (
    .id_rs1           (rs1_addr_id),
    .id_rs2           (rs2_addr_id),
    .ex_rs1           (rs1_addr_ex),
    .ex_rs2           (rs2_addr_ex),
    .ex_rd            (rd_addr_ex),
    .ex_reg_wr        (ctrl_ex[`CTRL_REG_WR]),
    .ex_mem_rd        (ctrl_ex[`CTRL_MEM_RD]),
    .ex_wb_sel        (ctrl_ex[`CTRL_WB_SEL]),
    .mem_rd           (rd_addr_mem),
    .mem_reg_wr       (ctrl_mem[`CTRL_REG_WR]),
    .wb_rd            (rd_addr_wb),
    .wb_reg_wr        (ctrl_wb[`CTRL_REG_WR]),
    .branch_mispredict(branch_mispredict_ex || wfi_flush),
    .jump_ex          (ctrl_ex[`CTRL_JAL] || ctrl_ex[`CTRL_JALR]),
    .fwd_rs1          (fwd_rs1),
    .fwd_rs2          (fwd_rs2),
    .stall_if         (stall_if),
    .stall_id         (stall_id),
    .stall_ex         (stall_ex),
    .flush_id         (flush_id),
    .flush_ex         (flush_ex),
    .flush_mem        (flush_mem)
  );

endmodule
