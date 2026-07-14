// ============================================================================
// hiriscy_core.v — HiRiscy 5-Stage Pipelined RV32I CPU Core (top)
// ----------------------------------------------------------------------------
// Functional decomposition (per the HiRiscy block diagram):
//   IFU (hiriscy_ifu) : IF datapath  (next-PC, IMEM request, static not-taken)
//   IDU (hiriscy_idu) : ID decode + hazard (control/imm/addrs, forward/stall)
//   EXU (hiriscy_exu) : EX datapath  (forwarding, ALU, branch/exception)
//   LSU (hiriscy_lsu) : MEM datapath (DMEM request, load/ALU result select)
//   RF  (hiriscy_rf)  : register file (read in ID, write in WB)
// Branch prediction is STATIC not-taken inside the IFU (no predictor state),
// and all hazard/forwarding logic lives inside the IDU. There are therefore no
// separate BPU or hazard modules.
//
// All pipeline registers (PC, IF/ID, ID/EX, EX/MEM, MEM/WB) and all run-control
// state live HERE in the top; the functional units above are combinational
// datapath blocks. Behaviour is identical to the previous monolithic core.
//
// External run control & status:
//   start_pause   : level run/pause. A rising edge (re)starts from start_pc;
//                   while high the core runs, while low it freezes (pause).
//   start_pc      : 12-bit byte address used as the (re)start PC.
//   configuration : exception masks (1 = SUPPRESS). [0] misalign, [1] illegal
//   exceptions    : latched exception cause. [0] PC-misaligned, [1] illegal
//   exceptions_pc : PC of the faulting instruction (latched on halt)
//   core_status   : [0] IDLE (exception halt OR after a WFI retires),
//                   [1] WFI  (after a WFI retires). Both cleared by a Start
//                   pulse (start_pause rising edge -> re-fetch from start_pc).
//
// NOTE: CSR/Zicsr and the trap mechanism (ECALL/EBREAK/MRET, mtvec/mepc,
//       interrupts) are not implemented. WFI is the only SYSTEM instruction:
//       it drains older instructions, stops fetch, flushes younger
//       instructions, and parks the core in IDLE.
// ============================================================================

module hiriscy_core (
  input  wire        clk,
  input  wire        rst_n,

  // Run control / status
  input  wire        start_pause,
  input  wire [11:0] start_pc,
  input  wire [1:0]  configuration,
  output wire [1:0]  core_status,
  output wire [1:0]  exceptions,
  output wire [31:0] exceptions_pc,

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

  // Interrupts (unused: no interrupt/CSR mechanism in this core)
  input  wire        ext_irq,
  input  wire        timer_irq
);

  `include "hiriscy_defs.vh"

  // ════════════════════════════════════════════════════════════════════
  // Pipeline control signals (from the IDU's hazard logic) + memory stalls
  // ════════════════════════════════════════════════════════════════════
  wire stall_if, stall_id, stall_ex;
  wire flush_id, flush_ex, flush_mem;
  wire [1:0] fwd_rs1, fwd_rs2;
  wire dmem_stall = (dmem_rd | dmem_wr) & ~dmem_ready;
  wire imem_stall = imem_rd & ~imem_ready;
  wire mem_stall  = dmem_stall | imem_stall;

  // ════════════════════════════════════════════════════════════════════
  // Run / Pause / Restart control + exception halt + WFI
  // ════════════════════════════════════════════════════════════════════
  wire        start_pause_d;
  wire        halted;          // set when an unmasked exception is detected检测到未被屏蔽的异常后置 1，CPU 停机
  wire [1:0]  exceptions_r;    // latched exception cause
  wire [31:0] exceptions_pc_r; // latched PC of the faulting instruction
  wire        wfi_active;      // WFI in flight: draining older instrs, fetch off
  wire        wfi_idle;        // WFI retired -> core parked in IDLE

  // Pipeline registers (DFF .q outputs; driven by hiriscy_dff/-_en instances)
  wire [31:0]         pc_if;
  wire [31:0]         pc_id, instr_id;
  wire [31:0]         pc_ex, rs1_data_ex, rs2_data_ex, imm_ex;
  wire [4:0]          rs1_addr_ex, rs2_addr_ex, rd_addr_ex;
  wire [`CTRL_W-1:0]  ctrl_ex;
  wire [31:0]         ex_result_mem, rs2_data_mem;
  wire [4:0]          rd_addr_mem;
  wire [`CTRL_W-1:0]  ctrl_mem;
  wire [31:0]         mem_result_wb;
  wire [4:0]          rd_addr_wb;
  wire [`CTRL_W-1:0]  ctrl_wb;

  // Inter-unit datapath wires
  wire [31:0] pc_next;
  wire [4:0]  rs1_addr_id, rs2_addr_id, rd_addr_id;
  wire [31:0] imm_id;
  wire [`CTRL_W-1:0] ctrl_id;
  wire [31:0] rs1_data_raw, rs2_data_raw;
  wire [31:0] ex_result, rs2_fwd;
  wire        branch_mispredict_ex;
  wire [31:0] branch_target_ex;
  wire [1:0]  exceptions_next;
  wire        any_exc;
  wire [31:0] mem_result;

  // Writeback (WB) mux + forwarding taps
  wire        wb_wr_en  = ctrl_wb[`CTRL_REG_WR];
  wire [4:0]  wb_rd_addr = rd_addr_wb;
  wire [31:0] wb_rd_data = mem_result_wb;  // WB_ALU/WB_PC4 fold into mem_result via EX

  wire restart = start_pause & ~start_pause_d;        // rising edge -> (re)start
  wire run     = start_pause & ~halted & ~wfi_idle;   // advance only when running

  // WFI flush: while a WFI is in flight (in EX or draining) kill younger
  // instructions in ID/EX so they never commit.
  wire wfi_flush = ctrl_ex[`CTRL_WFI] | wfi_active;

  hiriscy_dff #(.WIDTH(1)) u_start_pause_d (
    .clk (clk), .rst_n (rst_n), .rst_val (1'b0),
    .d   (start_pause), .q (start_pause_d)
  );

  // ── Exception halt latch ──────────────────────────────────────────────
  // Set on the first unmasked exception (any_exc) while running; cleared by a
  // Start pulse (restart). Enable covers both events; d selects the value.
  wire        exc_set   = run & ~halted & any_exc;   // detect an exception
  wire        exc_upd   = restart | exc_set;         // latch changes this cycle
  wire        halted_d  = restart ? 1'b0 : 1'b1;
  wire [1:0]  exc_r_d   = restart ? 2'b0 : exceptions_next;
  wire [31:0] exc_pc_d  = restart ? 32'b0 : pc_ex;   // EX PC == faulting PC

  hiriscy_dff_en #(.WIDTH(1)) u_halted (
    .clk (clk), .rst_n (rst_n), .en (exc_upd), .rst_val (1'b0),
    .d   (halted_d), .q (halted)
  );
  hiriscy_dff_en #(.WIDTH(2)) u_exceptions_r (
    .clk (clk), .rst_n (rst_n), .en (exc_upd), .rst_val (2'b0),
    .d   (exc_r_d), .q (exceptions_r)
  );
  hiriscy_dff_en #(.WIDTH(32)) u_exceptions_pc_r (
    .clk (clk), .rst_n (rst_n), .en (exc_upd), .rst_val (32'b0),
    .d   (exc_pc_d), .q (exceptions_pc_r)
  );

  // ── WFI control ───────────────────────────────────────────────────────
  //  1. WFI reaches EX  -> wfi_active: stop fetch, flush younger, drain older.
  //  2. WFI reaches WB  -> retires; core enters wfi_idle (IDLE).
  //  3. A Start pulse (restart) clears the state and re-fetches from start_pc.
  wire wfi_wb = ctrl_wb[`CTRL_WFI];
  wire wfi_ex = ctrl_ex[`CTRL_WFI];

  wire wfi_active_d = restart ? 1'b0 :
                      run     ? (wfi_wb ? 1'b0 : (wfi_ex ? 1'b1 : wfi_active))
                              : wfi_active;
  wire wfi_idle_d   = restart ? 1'b0 :
                      run     ? (wfi_wb ? 1'b1 : wfi_idle)
                              : wfi_idle;

  hiriscy_dff #(.WIDTH(1)) u_wfi_active (
    .clk (clk), .rst_n (rst_n), .rst_val (1'b0),
    .d   (wfi_active_d), .q (wfi_active)
  );
  hiriscy_dff #(.WIDTH(1)) u_wfi_idle (
    .clk (clk), .rst_n (rst_n), .rst_val (1'b0),
    .d   (wfi_idle_d), .q (wfi_idle)
  );

  assign exceptions     = exceptions_r;
  assign exceptions_pc  = exceptions_pc_r;
  assign core_status[0] = halted | wfi_idle;   // IDLE
  assign core_status[1] = wfi_idle;            // WFI

  // ════════════════════════════════════════════════════════════════════
  // IF — PC register + fetch unit (static not-taken prediction)
  // ════════════════════════════════════════════════════════════════════
  //   advance when running and not stalled/parked; restart reloads start_pc;
  //   otherwise (paused / stalled / WFI) hold -> stop fetch.
  wire        pc_if_en = restart | (run & ~stall_if & ~mem_stall & ~wfi_active);
  wire [31:0] pc_if_d  = restart ? {20'b0, start_pc} : pc_next;

  hiriscy_dff_en #(.WIDTH(32)) u_pc_if (
    .clk (clk), .rst_n (rst_n), .en (pc_if_en),
    .rst_val ({20'b0, start_pc}), .d (pc_if_d), .q (pc_if)
  );

  hiriscy_ifu u_ifu (
    .pc_if                (pc_if),
    .branch_mispredict_ex (branch_mispredict_ex),
    .branch_target_ex     (branch_target_ex),
    .wfi_active           (wfi_active),
    .wfi_idle             (wfi_idle),
    .pc_next              (pc_next),
    .imem_addr            (imem_addr),
    .imem_rd              (imem_rd)
  );

  // ── IF/ID Pipeline Register ───────────────────────────────────────────
  //   restart/flush inject a NOP; otherwise capture the fetched instruction
  //   when advancing; hold when paused or stalled.
  wire        ifid_nop = restart | flush_id;
  wire        ifid_en  = restart | (run & (flush_id | (~stall_id & ~mem_stall)));
  wire [31:0] pc_id_d    = ifid_nop ? 32'b0        : pc_if;
  wire [31:0] instr_id_d = ifid_nop ? 32'h0000_0013 : imem_rdata; // NOP

  hiriscy_dff_en #(.WIDTH(32)) u_pc_id (
    .clk (clk), .rst_n (rst_n), .en (ifid_en),
    .rst_val (32'b0), .d (pc_id_d), .q (pc_id)
  );
  hiriscy_dff_en #(.WIDTH(32)) u_instr_id (
    .clk (clk), .rst_n (rst_n), .en (ifid_en),
    .rst_val (32'h0000_0013), .d (instr_id_d), .q (instr_id)
  );

  // ════════════════════════════════════════════════════════════════════
  // ID — Decode unit (+ integrated hazard/forwarding) + register file
  // ════════════════════════════════════════════════════════════════════
  hiriscy_idu u_idu (
    // Decode
    .instr           (instr_id),
    .rs1_addr        (rs1_addr_id),
    .rs2_addr        (rs2_addr_id),
    .rd_addr         (rd_addr_id),
    .imm             (imm_id),
    .ctrl            (ctrl_id),
    // Hazard taps from later pipeline stages
    .ex_rs1          (rs1_addr_ex),
    .ex_rs2          (rs2_addr_ex),
    .ex_rd           (rd_addr_ex),
    .ex_mem_rd       (ctrl_ex[`CTRL_MEM_RD]),
    .mem_rd          (rd_addr_mem),
    .mem_reg_wr      (ctrl_mem[`CTRL_REG_WR]),
    .wb_rd           (rd_addr_wb),
    .wb_reg_wr       (ctrl_wb[`CTRL_REG_WR]),
    .branch_redirect (branch_mispredict_ex | wfi_flush),
    // Forwarding controls -> EXU
    .fwd_rs1         (fwd_rs1),
    .fwd_rs2         (fwd_rs2),
    // Pipeline control -> stage registers
    .stall_if        (stall_if),
    .stall_id        (stall_id),
    .stall_ex        (stall_ex),
    .flush_id        (flush_id),
    .flush_ex        (flush_ex),
    .flush_mem       (flush_mem)
  );

  hiriscy_rf u_rf (
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

  // ── ID/EX Pipeline Register ───────────────────────────────────────────
  //   restart/flush inject a bubble (all-zero ctrl); capture when advancing.
  wire idex_nop = restart | flush_ex;
  wire idex_en  = restart | (run & (flush_ex | (~stall_ex & ~mem_stall)));

  hiriscy_dff_en #(.WIDTH(`CTRL_W)) u_ctrl_ex (
    .clk (clk), .rst_n (rst_n), .en (idex_en), .rst_val ({`CTRL_W{1'b0}}),
    .d   (idex_nop ? {`CTRL_W{1'b0}} : ctrl_id), .q (ctrl_ex)
  );
  hiriscy_dff_en #(.WIDTH(32)) u_pc_ex (
    .clk (clk), .rst_n (rst_n), .en (idex_en), .rst_val (32'b0),
    .d   (idex_nop ? 32'b0 : pc_id), .q (pc_ex)
  );
  hiriscy_dff_en #(.WIDTH(32)) u_rs1_data_ex (
    .clk (clk), .rst_n (rst_n), .en (idex_en), .rst_val (32'b0),
    .d   (idex_nop ? 32'b0 : rs1_data_raw), .q (rs1_data_ex)
  );
  hiriscy_dff_en #(.WIDTH(32)) u_rs2_data_ex (
    .clk (clk), .rst_n (rst_n), .en (idex_en), .rst_val (32'b0),
    .d   (idex_nop ? 32'b0 : rs2_data_raw), .q (rs2_data_ex)
  );
  hiriscy_dff_en #(.WIDTH(32)) u_imm_ex (
    .clk (clk), .rst_n (rst_n), .en (idex_en), .rst_val (32'b0),
    .d   (idex_nop ? 32'b0 : imm_id), .q (imm_ex)
  );
  hiriscy_dff_en #(.WIDTH(5)) u_rs1_addr_ex (
    .clk (clk), .rst_n (rst_n), .en (idex_en), .rst_val (5'b0),
    .d   (idex_nop ? 5'b0 : rs1_addr_id), .q (rs1_addr_ex)
  );
  hiriscy_dff_en #(.WIDTH(5)) u_rs2_addr_ex (
    .clk (clk), .rst_n (rst_n), .en (idex_en), .rst_val (5'b0),
    .d   (idex_nop ? 5'b0 : rs2_addr_id), .q (rs2_addr_ex)
  );
  hiriscy_dff_en #(.WIDTH(5)) u_rd_addr_ex (
    .clk (clk), .rst_n (rst_n), .en (idex_en), .rst_val (5'b0),
    .d   (idex_nop ? 5'b0 : rd_addr_id), .q (rd_addr_ex)
  );

  // ════════════════════════════════════════════════════════════════════
  // EX — Execute unit (forwarding + ALU + branch/exception)
  // ════════════════════════════════════════════════════════════════════
  hiriscy_exu u_exu (
    .pc_ex                (pc_ex),
    .ctrl_ex              (ctrl_ex),
    .rs1_data_ex          (rs1_data_ex),
    .rs2_data_ex          (rs2_data_ex),
    .imm_ex               (imm_ex),
    .fwd_rs1              (fwd_rs1),
    .fwd_rs2              (fwd_rs2),
    .fwd_ex_mem_data      (ex_result_mem),  // EX/MEM forwarding tap
    .fwd_mem_wb_data      (wb_rd_data),     // MEM/WB forwarding tap
    .configuration        (configuration),
    .ex_result            (ex_result),
    .store_data           (rs2_fwd),
    .branch_mispredict_ex (branch_mispredict_ex),
    .branch_target_ex     (branch_target_ex),
    .exceptions_next      (exceptions_next),
    .any_exc              (any_exc)
  );

  // ── EX/MEM Pipeline Register ──────────────────────────────────────────
  wire exmem_nop = restart | flush_mem;
  wire exmem_en  = restart | (run & (flush_mem | ~mem_stall));

  hiriscy_dff_en #(.WIDTH(`CTRL_W)) u_ctrl_mem (
    .clk (clk), .rst_n (rst_n), .en (exmem_en), .rst_val ({`CTRL_W{1'b0}}),
    .d   (exmem_nop ? {`CTRL_W{1'b0}} : ctrl_ex), .q (ctrl_mem)
  );
  hiriscy_dff_en #(.WIDTH(32)) u_ex_result_mem (
    .clk (clk), .rst_n (rst_n), .en (exmem_en), .rst_val (32'b0),
    .d   (exmem_nop ? 32'b0 : ex_result), .q (ex_result_mem)
  );
  hiriscy_dff_en #(.WIDTH(32)) u_rs2_data_mem (
    .clk (clk), .rst_n (rst_n), .en (exmem_en), .rst_val (32'b0),
    .d   (exmem_nop ? 32'b0 : rs2_fwd), .q (rs2_data_mem)
  );
  hiriscy_dff_en #(.WIDTH(5)) u_rd_addr_mem (
    .clk (clk), .rst_n (rst_n), .en (exmem_en), .rst_val (5'b0),
    .d   (exmem_nop ? 5'b0 : rd_addr_ex), .q (rd_addr_mem)
  );

  // ════════════════════════════════════════════════════════════════════
  // MEM — Load/Store unit
  // ════════════════════════════════════════════════════════════════════
  hiriscy_lsu u_lsu (
    .ctrl_mem      (ctrl_mem),
    .ex_result_mem (ex_result_mem),
    .rs2_data_mem  (rs2_data_mem),
    .run           (run),
    .dmem_addr     (dmem_addr),
    .dmem_rd       (dmem_rd),
    .dmem_wr       (dmem_wr),
    .dmem_width    (dmem_width),
    .dmem_sign_ext (dmem_sign_ext),
    .dmem_wdata    (dmem_wdata),
    .dmem_rdata    (dmem_rdata),
    .mem_result    (mem_result)
  );

  // ── MEM/WB Pipeline Register ──────────────────────────────────────────
  //   restart clears to a bubble; otherwise advance when running & not stalled.
  wire memwb_en = restart | (run & ~mem_stall);

  hiriscy_dff_en #(.WIDTH(`CTRL_W)) u_ctrl_wb (
    .clk (clk), .rst_n (rst_n), .en (memwb_en), .rst_val ({`CTRL_W{1'b0}}),
    .d   (restart ? {`CTRL_W{1'b0}} : ctrl_mem), .q (ctrl_wb)
  );
  hiriscy_dff_en #(.WIDTH(32)) u_mem_result_wb (
    .clk (clk), .rst_n (rst_n), .en (memwb_en), .rst_val (32'b0),
    .d   (restart ? 32'b0 : mem_result), .q (mem_result_wb)
  );
  hiriscy_dff_en #(.WIDTH(5)) u_rd_addr_wb (
    .clk (clk), .rst_n (rst_n), .en (memwb_en), .rst_val (5'b0),
    .d   (restart ? 5'b0 : rd_addr_mem), .q (rd_addr_wb)
  );

endmodule
