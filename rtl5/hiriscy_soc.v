module hiriscy_soc #(
  parameter IMEM_DEPTH = 1024,
  parameter DMEM_DEPTH = 256,
  parameter INIT_FILE  = "firmware.hex"
)(
  input  wire        clk,
  input  wire        rst_n,

  input  wire        start_pause,
  input  wire [11:0] start_pc,
  input  wire [1:0]  configuration,
  output wire [1:0]  core_status,
  output wire [1:0]  exceptions,
  output wire [31:0] exceptions_pc
);

  wire [31:0] core_imem_addr;
  wire        core_imem_ce;
  wire        core_imem_we;
  wire [31:0] core_imem_we_data;
  wire [31:0] core_imem_rd_data;

  wire [11:0] core_dmem_addr;
  wire        core_dmem_ce;
  wire [127:0] core_dmem_we;
  wire [127:0] core_dmem_we_data;
  wire [127:0] core_dmem_rd_data;

  hiriscy_core u_core (
    .clk           (clk),
    .rst_n         (rst_n),
    .start_pause   (start_pause),
    .start_pc      (start_pc),
    .configuration (configuration),
    .core_status   (core_status),
    .exceptions    (exceptions),
    .exceptions_pc (exceptions_pc),
    .imem_addr     (core_imem_addr),
    .imem_ce       (core_imem_ce),
    .imem_we       (core_imem_we),
    .imem_we_data  (core_imem_we_data),
    .imem_rd_data  (core_imem_rd_data),
    .dmem_addr     (core_dmem_addr),
    .dmem_ce       (core_dmem_ce),
    .dmem_we       (core_dmem_we),
    .dmem_we_data  (core_dmem_we_data),
    .dmem_rd_data  (core_dmem_rd_data),
    .ext_irq       (1'b0),
    .timer_irq     (1'b0)
  );

  hiriscy_imem #(
    .DEPTH     (IMEM_DEPTH),
    .INIT_FILE (INIT_FILE)
  ) u_imem (
    .clk      (clk),
    .rst_n    (rst_n),
    .addr     (core_imem_addr),
    .ce       (core_imem_ce),
    .we       (core_imem_we),
    .we_data  (core_imem_we_data),
    .rd_data  (core_imem_rd_data)
  );

  hiriscy_dmem #(
    .DEPTH (DMEM_DEPTH)
  ) u_dmem (
    .clk      (clk),
    .rst_n    (rst_n),
    .addr     (core_dmem_addr),
    .ce       (core_dmem_ce),
    .we       (core_dmem_we),
    .we_data  (core_dmem_we_data),
    .rd_data  (core_dmem_rd_data)
  );

endmodule
