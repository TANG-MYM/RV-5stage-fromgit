// ============================================================================
// hiriscy_core.v — HiRiscy 5-Stage Pipelined RV32I CPU Core (top)
// ----------------------------------------------------------------------------
// Functional decomposition (per the HiRiscy block diagram):
//   IFU (hiriscy_ifu) : IF datapath  (next-PC, IMEM request, static not-taken)
//   IDU (hiriscy_idu) : ID decode + hazard + operand MUXes (control/forwarding)
//   EXU (hiriscy_exu) : EX datapath  (ALU, branch/exception, no operand MUXes)
//   LSU (hiriscy_lsu) : MEM datapath (DMEM request, load/ALU result select)
//   RF  (hiriscy_rf)  : register file (read in ID, write in WB)
//
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

  // Instruction memory interface (32-bit data width)
  output wire [31:0] imem_addr,
  output wire        imem_ce,
  output wire        imem_we,
  output wire [31:0] imem_we_data,
  input  wire [31:0] imem_rd_data,

  // Data memory interface (128-bit data width)
  output wire [11:0] dmem_addr,
  output wire        dmem_ce,
  output wire [127:0] dmem_we,
  output wire [127:0] dmem_we_data,
  input  wire [127:0] dmem_rd_data,

  // Interrupts (unused: no interrupt/CSR mechanism in this core)
  input  wire        ext_irq,
  input  wire        timer_irq
);

  `include "hiriscy_defs.vh"

  // ════════════════════════════════════════════════════════════════════
  // Pipeline control signals (from the IDU's hazard logic)
  // ════════════════════════════════════════════════════════════════════
  wire stall_if, stall_id, stall_ex;
  wire flush_id_hazard, flush_ex_hazard, flush_mem_hazard;

  // dmem access is issued in EX; read data is available in MEM (registered
  // in the dmem macro). No mem_stall needed — each pipeline stage is 1 cycle.
  wire mem_stall = 1'b0;

  // ── Exception flush (separate from hazard flush) ─────────────────────
  // On exception detection we stop fetch and flush the faulting instruction
  // and all younger instructions, while letting older instructions in
  // EX/MEM/WB continue to retire.  Once the back end is empty we latch the
  // exception and assert halted.
  //   flush_id_exc  : kill IF/ID  (faulting-or-younger in ID/IF)
  //   flush_ex_exc  : kill ID/EX (faulting-or-younger entering EX)
  //   flush_mem_exc : kill EX/MEM(faulting instruction currently in EX)
  wire flush_id_exc, flush_ex_exc, flush_mem_exc;
  wire exc_pending;     // exception detected, back end still draining
  wire stop_fetch_exc;  // hold PC and IF/ID once exception is detected

  // ════════════════════════════════════════════════════════════════════
  // Run / Pause / Restart control + exception halt + WFI
  // ════════════════════════════════════════════════════════════════════
  wire        start_pause_d;
  wire        halted;          // set when an exception is detected and the back end has drained
  wire [1:0]  exceptions_r;    // latched exception cause
  wire [31:0] exceptions_pc_r; // latched PC of the faulting instruction
  wire        wfi_active;      // WFI in flight: draining older instrs, fetch off
  wire        wfi_idle;        // WFI retired -> core parked in IDLE

  // Pipeline registers (DFF .q outputs; driven by hiriscy_dff/-_en instances)
  wire [31:0]         pc_if;
  wire [31:0]         pc_id, instr_id;
  wire [31:0]         pc_ex;                // actual PC of EX-stage instruction
  wire [31:0]         pc_base_ex;           // branch target base (PC or rs1 for JALR)
  wire [31:0]         op1_ex, op2_ex;       // ALU operands (selected in ID)
  wire [31:0]         store_data_ex;        // rs2 for STORE + B-type compare (in ID/EX reg)
  wire [4:0]          rd_addr_ex;
  wire [`CTRL_W-1:0]  ctrl_ex;
  wire [31:0]         ex_result_mem;
  wire [4:0]          rd_addr_mem;
  wire [`CTRL_W-1:0]  ctrl_mem;
  wire [31:0]         mem_result_wb;
  wire [4:0]          rd_addr_wb;
  wire [`CTRL_W-1:0]  ctrl_wb;

  // Inter-unit datapath wires
  wire [31:0] pc_next;
  wire [4:0]  rs1_addr_id, rs2_addr_id, rd_addr_id;
  wire [`CTRL_W-1:0] ctrl_id;
  wire [31:0] rs1_data_raw, rs2_data_raw;   // RF read outputs (combinational)
  wire [31:0] op1_id, op2_id;               // IDU operand outputs (to ID/EX reg)
  wire [31:0] store_data_id;                // forwarded rs2 (to ID/EX reg)
  wire [31:0] pc_base_id;                   // branch base (to ID/EX reg)
  wire [31:0] ex_result;
  wire        branch_mispredict_ex;
  wire [31:0] branch_target_ex;
  wire [31:0] mem_result;
  wire        fetch_misalign;
  wire        branch_misalign_raw;            // raw branch-target misalign (EXU)

  // Writeback (WB) mux + forwarding taps
  wire        wb_wr_en  = ctrl_wb[`CTRL_REG_WR];
  wire [4:0]  wb_rd_addr = rd_addr_wb;
  wire [31:0] wb_rd_data = mem_result_wb;

  wire restart = start_pause & ~start_pause_d;        // rising edge -> (re)start
  wire run     = start_pause & ~halted & ~wfi_idle;   // advance only when running

  // WFI in ID: stop fetch immediately (before wfi_active is set). Keeps
  // fetch halted while WFI sits in ID waiting for the pipeline to drain,
  // and during the single-cycle gap when WFI transitions ID->EX (before
  // wfi_active is registered).
  wire wfi_in_id = ctrl_id[`CTRL_WFI];

  // WFI flush: while a WFI is in flight (in EX or draining) kill younger
  // instructions in ID/EX so they never commit.
  wire wfi_flush = ctrl_ex[`CTRL_WFI] | wfi_active;

  hiriscy_dff #(.WIDTH(1)) u_start_pause_d (
    .clk (clk), .rst_n (rst_n), .rst_val (1'b0),
    .d   (start_pause), .q (start_pause_d)
  );

  // ── Exception handling: detect, flush younger, drain older, then halt ─
  // Each stage reports its exception event directly to the core.  The core
  // arbitrates by priority EX > ID > IF (EX is the oldest instruction in
  // the pipeline at any given cycle).
  //
  // On detection (regardless of configuration mask):
  //   - stop fetch immediately (stop_fetch_exc)
  //   - flush the faulting instruction and younger ones (flush_*_exc)
  //   - latch the exception cause/PC so they survive after the faulting
  //     instruction is flushed out of the pipeline
  //   - keep older instructions in EX/MEM/WB advancing until they retire
  //   - once EX/MEM are all bubbles, assert halted
  //
  // configuration only gates the EXTERNAL output (exceptions / exceptions_pc):
  //   pc_unalign_exception      = pc_unalign_event      & ~configuration[0]
  //   illegal_instruction_exc   = illegal_event        & ~configuration[1]
  // Internal handling (flush / drain / halt) uses the raw event, so a masked
  // exception still suppresses the faulting instruction and halts the core;
  // it simply does not appear on the exceptions output port.
  wire exc_from_ex = branch_misalign_raw;        // raw event (EX)
  wire exc_from_id = ctrl_id[`CTRL_ILLEGAL];     // raw event (ID)
  wire exc_from_if = fetch_misalign;             // raw event (IF)

  wire        any_exc    = exc_from_ex | exc_from_id | exc_from_if;
  wire [1:0]  exc_cause  = exc_from_ex ? 2'b01 :   // misalign (branch, oldest)
                           exc_from_id ? 2'b10 :   // illegal
                           exc_from_if ? 2'b01 :   // misalign (fetch, youngest)
                                        2'b00;
  wire [31:0] exc_pc     = exc_from_ex ? pc_ex :   // branch instr PC
                           exc_from_id ? pc_id :   // illegal instr PC
                           exc_from_if ? pc_if :   // misaligned fetch PC
                                        32'b0;

  // Masked exception output (configuration = 1 suppresses the corresponding
  // exception bit on the external port; internal handling is unaffected).
  wire [1:0]  exc_cause_masked = { exc_cause[1] & ~configuration[1],
                                   exc_cause[0] & ~configuration[0] };

  // Exception flush: kill faulting + younger instructions by stage of origin.
  //   IF exception  : only IF/ID is faulting-or-younger; ID/EX, EX/MEM are older
  //   ID exception  : IF/ID and ID/EX are faulting-or-younger; EX/MEM are older
  //   EX exception  : IF/ID, ID/EX, EX/MEM all contain faulting-or-younger
  // flush_id_exc is held by exc_pending so IF/ID stays a bubble while the
  // back end drains (any_exc may drop once the faulting instruction is
  // flushed out of IF/ID).
  assign flush_id_exc  = any_exc | exc_pending;
  assign flush_ex_exc  = exc_from_ex | exc_from_id;
  assign flush_mem_exc = exc_from_ex;

  // Stop fetch as soon as an exception is seen (combinational, same cycle).
  // Also keep fetch stopped while we are draining the back end.
  assign stop_fetch_exc = any_exc | exc_pending;

  // Back-end bubble detection.  A stage is a bubble when its ctrl bundle is
  // all-zero (restart-injected NOP / flushed bubble).  We only need EX and MEM
  // to drain; WB retires independently and is allowed to commit its last
  // instruction the cycle EX/MEM become empty.
  wire ex_is_bubble  = (ctrl_ex  == {`CTRL_W{1'b0}});
  wire mem_is_bubble = (ctrl_mem == {`CTRL_W{1'b0}});
  wire backend_empty = ex_is_bubble & mem_is_bubble;

  // exc_pending + latched cause/PC: set once an exception is detected,
  // cleared by restart.  The cause/PC are latched at detection time because
  // the combinational exc_cause/exc_pc drop to zero once the faulting
  // instruction is flushed out of the pipeline.
  wire exc_pending_set = run & ~halted & ~exc_pending & any_exc;
  wire exc_pending_upd = restart | exc_pending_set;
  wire exc_pending_d  = restart ? 1'b0 : 1'b1;

  hiriscy_dff_en #(.WIDTH(1)) u_exc_pending (
    .clk (clk), .rst_n (rst_n), .en (exc_pending_upd), .rst_val (1'b0),
    .d   (exc_pending_d), .q (exc_pending)
  );

  // Latched (masked) cause and PC — captured at detection, held until restart.
  wire [1:0]  exc_cause_lat_d = restart ? 2'b0 : exc_cause_masked;
  wire [31:0] exc_pc_lat_d    = restart ? 32'b0 : exc_pc;

  hiriscy_dff_en #(.WIDTH(2))  u_exc_cause_lat (
    .clk (clk), .rst_n (rst_n), .en (exc_pending_upd), .rst_val (2'b0),
    .d   (exc_cause_lat_d), .q (exceptions_r)
  );
  hiriscy_dff_en #(.WIDTH(32)) u_exc_pc_lat (
    .clk (clk), .rst_n (rst_n), .en (exc_pending_upd), .rst_val (32'b0),
    .d   (exc_pc_lat_d), .q (exceptions_pc_r)
  );

  // Halt once the back end has drained.
  wire exc_set   = run & ~halted & exc_pending & backend_empty;
  wire exc_upd   = restart | exc_set;
  wire halted_d  = restart ? 1'b0 : 1'b1;

  hiriscy_dff_en #(.WIDTH(1)) u_halted (
    .clk (clk), .rst_n (rst_n), .en (exc_upd), .rst_val (1'b0),
    .d   (halted_d), .q (halted)
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

  // ── Final pipeline control: hazard (from IDU) OR exception (from core) ──
  // The IDU keeps generating its own flush_*_hazard / stall_* for load-use /
  // WFI / branch redirect.  The core's exception control is OR-ed on top.
  // Exception flush takes priority over hazard stall: when an exception is
  // detected the faulting/younger instructions must be flushed (turned into
  // bubbles), not merely frozen — a stall would leave the faulting instruction
  // sitting in IF/ID and re-trigger the exception every cycle.
  wire flush_id  = flush_id_hazard  | flush_id_exc;
  wire flush_ex  = flush_ex_hazard  | flush_ex_exc;
  wire flush_mem = flush_mem_hazard | flush_mem_exc;

  // Cancel hazard stall when exception flush is active (exception wins).
  wire stall_if_final = stall_if & ~flush_id_exc;
  wire stall_id_final = stall_id & ~flush_id_exc;

  // ════════════════════════════════════════════════════════════════════
  // IF — PC register + fetch unit (static not-taken prediction)
  // ════════════════════════════════════════════════════════════════════
//   advance when running and not stalled/parked; restart reloads start_pc;
//   otherwise (paused / stalled / WFI / exception) hold -> stop fetch.
//   wfi_in_id      : stop fetch the moment WFI is decoded (before drain completes)
//   wfi_active     : keep fetch stopped while WFI is in EX/MEM/WB
//   stop_fetch_exc : stop fetch once an exception is detected (until restart)
  wire        pc_if_en = restart | (run & ~stall_if_final & ~mem_stall &
                                    ~wfi_active & ~wfi_in_id & ~stop_fetch_exc);
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
    .stop_fetch_exc       (stop_fetch_exc),
    .pc_next              (pc_next),
    .imem_addr            (imem_addr),
    .imem_ce              (imem_ce),
    .fetch_misalign       (fetch_misalign)
  );

  assign imem_we      = 1'b0;
  assign imem_we_data = 32'b0;

  // ── IF/ID Pipeline Register ───────────────────────────────────────────
  //   restart/flush inject a NOP; otherwise capture the fetched instruction
  //   when advancing; hold when paused or stalled.
  wire        ifid_nop = restart | flush_id;
  wire        ifid_en  = restart | (run & (flush_id | (~stall_id_final & ~mem_stall)));
  wire [31:0] pc_id_d    = ifid_nop ? 32'b0        : pc_if;
  wire [31:0] instr_id_d = ifid_nop ? 32'h0000_0013 : imem_rd_data;

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
    .pc_id           (pc_id),
    .rs1_addr        (rs1_addr_id),
    .rs2_addr        (rs2_addr_id),
    .rd_addr         (rd_addr_id),
    .ctrl            (ctrl_id),
    // RF read data (combinational from hiriscy_rf, below)
    .rs1_data_raw    (rs1_data_raw),
    .rs2_data_raw    (rs2_data_raw),
    // Forwarding sources (from later pipeline stages)
    .ex_result       (ex_result),
    .mem_result      (mem_result),
    .mem_result_wb   (mem_result_wb),
    // Hazard taps from later pipeline stages
    .ex_rd           (rd_addr_ex),
    .ex_reg_wr       (ctrl_ex[`CTRL_REG_WR]),
    .ex_mem_rd       (ctrl_ex[`CTRL_MEM_RD]),
    .mem_rd          (rd_addr_mem),
    .mem_reg_wr      (ctrl_mem[`CTRL_REG_WR]),
    .wb_rd           (rd_addr_wb),
    .wb_reg_wr       (ctrl_wb[`CTRL_REG_WR]),
    .branch_redirect (branch_mispredict_ex | wfi_flush),
    // Full ctrl bundles for WFI drain detection
    .ctrl_ex_full    (ctrl_ex),
    .ctrl_mem_full   (ctrl_mem),
    // ID-stage datapath outputs (to ID/EX register)
    .op1             (op1_id),
    .op2             (op2_id),
    .store_data      (store_data_id),
    .pc_base         (pc_base_id),
    // Pipeline control (hazard-only; exception flush is OR-ed in the core)
    .stall_if        (stall_if),
    .stall_id        (stall_id),
    .stall_ex        (stall_ex),
    .flush_id        (flush_id_hazard),
    .flush_ex        (flush_ex_hazard),
    .flush_mem       (flush_mem_hazard)
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
  hiriscy_dff_en #(.WIDTH(32)) u_pc_base_ex (
    .clk (clk), .rst_n (rst_n), .en (idex_en), .rst_val (32'b0),
    .d   (idex_nop ? 32'b0 : pc_base_id), .q (pc_base_ex)
  );
  hiriscy_dff_en #(.WIDTH(32)) u_op1_ex (
    .clk (clk), .rst_n (rst_n), .en (idex_en), .rst_val (32'b0),
    .d   (idex_nop ? 32'b0 : op1_id), .q (op1_ex)
  );
  hiriscy_dff_en #(.WIDTH(32)) u_op2_ex (
    .clk (clk), .rst_n (rst_n), .en (idex_en), .rst_val (32'b0),
    .d   (idex_nop ? 32'b0 : op2_id), .q (op2_ex)
  );
  hiriscy_dff_en #(.WIDTH(32)) u_store_data_ex (
    .clk (clk), .rst_n (rst_n), .en (idex_en), .rst_val (32'b0),
    .d   (idex_nop ? 32'b0 : store_data_id), .q (store_data_ex)
  );
  hiriscy_dff_en #(.WIDTH(5)) u_rd_addr_ex (
    .clk (clk), .rst_n (rst_n), .en (idex_en), .rst_val (5'b0),
    .d   (idex_nop ? 5'b0 : rd_addr_id), .q (rd_addr_ex)
  );

  // ════════════════════════════════════════════════════════════════════
  // EX — Execute unit (ALU + branch/exception) + dmem access
  // ════════════════════════════════════════════════════════════════════
  hiriscy_exu u_exu (
    .pc_ex                (pc_ex),
    .pc_base_ex           (pc_base_ex),
    .op1_ex               (op1_ex),
    .op2_ex               (op2_ex),
    .store_data_ex        (store_data_ex),
    .ctrl_ex              (ctrl_ex),
    .ex_result            (ex_result),
    .branch_mispredict_ex (branch_mispredict_ex),
    .branch_target_ex     (branch_target_ex),
    .branch_misalign_raw  (branch_misalign_raw)
  );

  // ── EX-stage dmem access ──────────────────────────────────────────────
  // Address (from ALU), ce, we, we_data are all presented in EX.
  // The dmem macro registers the read data internally; it is valid in MEM.
  wire [1:0]  ex_byte_off  = ex_result[1:0];
  wire [1:0]  ex_word_sel  = ex_result[3:2];
  wire [1:0]  ex_mem_width = ctrl_ex[`CTRL_MEM_WIDTH];
  wire        ex_mem_wr    = ctrl_ex[`CTRL_MEM_WR];
  wire        ex_mem_rd    = ctrl_ex[`CTRL_MEM_RD];

  wire [3:0]  ex_wstrb_word = (ex_mem_width == MEM_BYTE) ? (4'b0001 << ex_byte_off)          :
                              (ex_mem_width == MEM_HALF) ? (ex_byte_off[1] ? 4'b1100 : 4'b0011) :
                              4'b1111;
  wire [31:0] ex_wstrb_bits = {{8{ex_wstrb_word[3]}}, {8{ex_wstrb_word[2]}},
                               {8{ex_wstrb_word[1]}}, {8{ex_wstrb_word[0]}}};
  wire [127:0] ex_wstrb_128 = {96'b0, ex_wstrb_bits} << (ex_word_sel * 32);

  // store_data_ex is the forwarded rs2 value from the ID/EX register
  wire [127:0] ex_we_data_aligned = (ex_mem_width == MEM_BYTE) ? {16{store_data_ex[7:0]}}   :
                                    (ex_mem_width == MEM_HALF) ? {8{store_data_ex[15:0]}}  :
                                    {4{store_data_ex}};

  assign dmem_addr    = ex_result[11:0];
  // Suppress dmem access for the faulting EX-stage instruction (e.g. a
  // future load/store misalign exception).  Older instructions in MEM/WB
  // are not affected because flush_mem_exc only fires on EX exceptions.
  assign dmem_ce      = (ex_mem_rd | ex_mem_wr) & run & ~flush_mem_exc;
  assign dmem_we      = (ex_mem_wr & ~flush_mem_exc) ? ex_wstrb_128 : 128'b0;
  assign dmem_we_data = ex_we_data_aligned;

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
  hiriscy_dff_en #(.WIDTH(5)) u_rd_addr_mem (
    .clk (clk), .rst_n (rst_n), .en (exmem_en), .rst_val (5'b0),
    .d   (exmem_nop ? 5'b0 : rd_addr_ex), .q (rd_addr_mem)
  );

  // ════════════════════════════════════════════════════════════════════
  // MEM — Load/Store unit (data_sel + result select)
  // ════════════════════════════════════════════════════════════════════
  hiriscy_lsu u_lsu (
    .ctrl_mem      (ctrl_mem),
    .ex_result_mem (ex_result_mem),
    .dmem_rd_data  (dmem_rd_data),
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