module hiriscy_core #(
  parameter PIPE_MODE = 5
)(
  input  wire        clk,
  input  wire        rst_n,

  input  wire        start_pause,
  input  wire [11:0] start_pc,
  input  wire [1:0]  configuration,
  output wire [1:0]  core_status,
  output wire [1:0]  exceptions,
  output wire [31:0] exceptions_pc,

  output wire [31:0] imem_addr,
  output wire        imem_ce,
  output wire        imem_we,
  output wire [31:0] imem_we_data,
  input  wire [31:0] imem_rd_data,

  output wire [11:0] dmem_addr,
  output wire        dmem_ce,
  output wire [127:0] dmem_we,
  output wire [127:0] dmem_we_data,
  input  wire [127:0] dmem_rd_data,

  input  wire        ext_irq,
  input  wire        timer_irq
);

  `include "hiriscy_defs.vh"

  wire stall_if, stall_id, stall_ex;
  wire flush_id_hazard, flush_ex_hazard, flush_mem_hazard;

  wire mem_stall = 1'b0;

  wire flush_id_exc, flush_ex_exc, flush_mem_exc;
  wire exc_pending;
  wire stop_fetch_exc;

  wire        start_pause_d;
  wire        halted;
  wire [1:0]  exceptions_r;
  wire [31:0] exceptions_pc_r;
  wire        wfi_active;
  wire        wfi_idle;

  wire [31:0]         pc_if;
  wire [31:0]         pc_id, instr_id;
  wire [31:0]         pc_ex;
  wire [31:0]         pc_base_ex;
  wire [31:0]         op1_ex, op2_ex;
  wire [31:0]         store_data_ex;
  wire [4:0]          rd_addr_ex;
  wire [`CTRL_W-1:0]  ctrl_ex;
  wire [31:0]         ex_result_mem;
  wire [4:0]          rd_addr_mem;
  wire [`CTRL_W-1:0]  ctrl_mem;
  wire [31:0]         mem_result_wb;
  wire [4:0]          rd_addr_wb;
  wire [`CTRL_W-1:0]  ctrl_wb;

  wire [31:0] pc_next;
  wire [4:0]  rs1_addr_id, rs2_addr_id, rd_addr_id;
  wire [`CTRL_W-1:0] ctrl_id;
  wire [31:0] rs1_data_raw, rs2_data_raw;
  wire [31:0] op1_id, op2_id;
  wire [31:0] store_data_id;
  wire [31:0] pc_base_id;
  wire [31:0] ex_result;
  wire        branch_mispredict_ex;
  wire [31:0] branch_target_ex;
  wire [31:0] mem_result;
  wire        fetch_misalign;
  wire        branch_misalign_raw;

  wire        wb_wr_en  = ctrl_wb[`CTRL_REG_WR];
  wire [4:0]  wb_rd_addr = rd_addr_wb;
  wire [31:0] wb_rd_data = mem_result_wb;

  wire restart = start_pause & ~start_pause_d;
  wire run     = start_pause & ~halted & ~wfi_idle;

  wire wfi_in_id = ctrl_id[`CTRL_WFI];

  wire wfi_flush = ctrl_ex[`CTRL_WFI] | wfi_active;

  hiriscy_dff #(.WIDTH(1)) u_start_pause_d (
    .clk (clk), .rst_n (rst_n), .rst_val (1'b0),
    .d   (start_pause), .q (start_pause_d)
  );

  wire exc_from_ex = branch_misalign_raw;
  wire exc_from_id = ctrl_id[`CTRL_ILLEGAL];
  wire exc_from_if = fetch_misalign;

  wire        any_exc    = exc_from_ex | exc_from_id | exc_from_if;

  wire [1:0]  exc_cause  = (PIPE_MODE == 3) ?
                           (exc_from_ex ? 2'b01 :
                            exc_from_if ? 2'b01 :
                            exc_from_id ? 2'b10 :
                                         2'b00) :
                           (exc_from_ex ? 2'b01 :
                            exc_from_id ? 2'b10 :
                            exc_from_if ? 2'b01 :
                                         2'b00);
  wire [31:0] exc_pc     = (PIPE_MODE == 3) ?
                           (exc_from_ex ? pc_ex :
                            exc_from_if ? pc_if :
                            exc_from_id ? pc_id :
                                         32'b0) :
                           (exc_from_ex ? pc_ex :
                            exc_from_id ? pc_id :
                            exc_from_if ? pc_if :
                                         32'b0);

  wire [1:0]  exc_cause_masked = { exc_cause[1] & ~configuration[1],
                                   exc_cause[0] & ~configuration[0] };

  assign flush_id_exc  = (PIPE_MODE == 5) ? (any_exc | exc_pending) : 1'b0;
  assign flush_ex_exc  = (PIPE_MODE == 3) ? (any_exc | exc_pending)
                                          : (exc_from_ex | exc_from_id | exc_pending);
  assign flush_mem_exc = exc_from_ex;

  assign stop_fetch_exc = any_exc | exc_pending;

  wire ex_is_bubble  = (ctrl_ex  == {`CTRL_W{1'b0}});
  wire mem_is_bubble = (ctrl_mem == {`CTRL_W{1'b0}});
  wire backend_empty = ex_is_bubble & mem_is_bubble;

  wire exc_pending_set = run & ~halted & ~exc_pending & any_exc;
  wire exc_pending_upd = restart | exc_pending_set;
  wire exc_pending_d  = restart ? 1'b0 : 1'b1;

  hiriscy_dff_en #(.WIDTH(1)) u_exc_pending (
    .clk (clk), .rst_n (rst_n), .en (exc_pending_upd), .rst_val (1'b0),
    .d   (exc_pending_d), .q (exc_pending)
  );

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

  wire exc_set   = run & ~halted & exc_pending & backend_empty;
  wire exc_upd   = restart | exc_set;
  wire halted_d  = restart ? 1'b0 : 1'b1;

  hiriscy_dff_en #(.WIDTH(1)) u_halted (
    .clk (clk), .rst_n (rst_n), .en (exc_upd), .rst_val (1'b0),
    .d   (halted_d), .q (halted)
  );

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
  assign core_status[0] = halted | wfi_idle;
  assign core_status[1] = wfi_idle;

  wire flush_id  = flush_id_hazard  | flush_id_exc;
  wire flush_ex  = flush_ex_hazard  | flush_ex_exc;
  wire flush_mem = flush_mem_hazard | flush_mem_exc;

  wire stall_if_final = stall_if & ~flush_id_exc;
  wire stall_id_final = stall_id & ~flush_id_exc;

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

  generate
    if (PIPE_MODE == 3) begin : g_ifid_bypass
      assign pc_id    = pc_if;
      assign instr_id = imem_rd_data;
    end else begin : g_ifid_reg
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
    end
  endgenerate

  hiriscy_idu #(.PIPE_MODE(PIPE_MODE)) u_idu (

    .instr           (instr_id),
    .pc_id           (pc_id),
    .rs1_addr        (rs1_addr_id),
    .rs2_addr        (rs2_addr_id),
    .rd_addr         (rd_addr_id),
    .ctrl            (ctrl_id),

    .rs1_data_raw    (rs1_data_raw),
    .rs2_data_raw    (rs2_data_raw),

    .ex_result       (ex_result),
    .mem_result      (mem_result),
    .mem_result_wb   (mem_result_wb),

    .ex_rd           (rd_addr_ex),
    .ex_reg_wr       (ctrl_ex[`CTRL_REG_WR]),
    .ex_mem_rd       (ctrl_ex[`CTRL_MEM_RD]),
    .mem_rd          (rd_addr_mem),
    .mem_reg_wr      (ctrl_mem[`CTRL_REG_WR]),
    .wb_rd           (rd_addr_wb),
    .wb_reg_wr       (ctrl_wb[`CTRL_REG_WR]),
    .branch_redirect (branch_mispredict_ex | wfi_flush),

    .ctrl_ex_full    (ctrl_ex),
    .ctrl_mem_full   (ctrl_mem),

    .op1             (op1_id),
    .op2             (op2_id),
    .store_data      (store_data_id),
    .pc_base         (pc_base_id),

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

  wire [127:0] ex_we_data_aligned = (ex_mem_width == MEM_BYTE) ? {16{store_data_ex[7:0]}}   :
                                    (ex_mem_width == MEM_HALF) ? {8{store_data_ex[15:0]}}  :
                                    {4{store_data_ex}};

  assign dmem_addr    = ex_result[11:0];

  assign dmem_ce      = (ex_mem_rd | ex_mem_wr) & run & ~flush_mem_exc;
  assign dmem_we      = (ex_mem_wr & ~flush_mem_exc) ? ex_wstrb_128 : 128'b0;
  assign dmem_we_data = ex_we_data_aligned;

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

  hiriscy_lsu u_lsu (
    .ctrl_mem      (ctrl_mem),
    .ex_result_mem (ex_result_mem),
    .dmem_rd_data  (dmem_rd_data),
    .mem_result    (mem_result)
  );

  generate
    if (PIPE_MODE == 3) begin : g_memwb_bypass
      assign ctrl_wb       = ctrl_mem;
      assign mem_result_wb = mem_result;
      assign rd_addr_wb    = rd_addr_mem;
    end else begin : g_memwb_reg
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
    end
  endgenerate

endmodule
