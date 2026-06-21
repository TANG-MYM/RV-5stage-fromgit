// ============================================================================
// brv32p_soc.v — BRV32P SoC Top-Level (Harvard, no cache / no AXI)
// ----------------------------------------------------------------------------
//   - Instruction memory : depth x 32-bit read-only ROM (combinational read)
//   - Data memory        : 4 KB SRAM, simple 1-cycle-latency handshake
//   - No caches, no AXI interconnect, no peripherals
// ============================================================================

module brv32p_soc #(
  parameter IMEM_DEPTH = 1024,            // instruction words (depth x 32)
  parameter DMEM_DEPTH = 1024,            // data words (1024 x 32 = 4 KB)
  parameter INIT_FILE  = "firmware.hex"
)(
  input  wire        clk,
  input  wire        rst_n,

  // Run control / status
  input  wire        start_pause,         // rising edge restarts @ start_pc; level: 1=run, 0=pause
  input  wire [11:0] start_pc,            // (re)start PC (byte address)
  input  wire [1:0]  configuration,       // exception masks (1 = suppress): [0]=misalign, [1]=illegal
  output wire [1:0]  core_status,         // [0]=IDLE (exception halt or WFI retire), [1]=WFI retired
  output wire [1:0]  exceptions,          // [0]=PC-misaligned, [1]=illegal instruction
  output wire [31:0] exceptions_pc        // PC of the faulting instruction (latched on halt)
);

  // ── Core <-> Instruction memory ────────────────────────────────────────
  wire [31:0] core_imem_addr, core_imem_rdata;
  wire        core_imem_rd,   core_imem_ready;

  // ── Core <-> Data memory ───────────────────────────────────────────────
  wire [31:0] core_dmem_addr, core_dmem_wdata, core_dmem_rdata;
  wire        core_dmem_rd,   core_dmem_wr,    core_dmem_ready;
  wire [1:0]  core_dmem_width;
  wire        core_dmem_sign_ext;

  // ══════════════════════════════════════════════════════════════════════
  // CPU Core
  // ══════════════════════════════════════════════════════════════════════
  brv32p_core u_core (
    .clk           (clk),
    .rst_n         (rst_n),
    .start_pause   (start_pause),
    .start_pc      (start_pc),
    .configuration (configuration),
    .core_status   (core_status),
    .exceptions    (exceptions),
    .exceptions_pc (exceptions_pc),
    .imem_addr     (core_imem_addr),
    .imem_rd       (core_imem_rd),
    .imem_rdata    (core_imem_rdata),
    .imem_ready    (core_imem_ready),
    .dmem_addr     (core_dmem_addr),
    .dmem_rd       (core_dmem_rd),
    .dmem_wr       (core_dmem_wr),
    .dmem_width    (core_dmem_width),
    .dmem_sign_ext (core_dmem_sign_ext),
    .dmem_wdata    (core_dmem_wdata),
    .dmem_rdata    (core_dmem_rdata),
    .dmem_ready    (core_dmem_ready),
    .ext_irq       (1'b0),
    .timer_irq     (1'b0)
  );

  // ══════════════════════════════════════════════════════════════════════
  // Instruction memory (read-only ROM, depth x 32)
  // ══════════════════════════════════════════════════════════════════════
  imem_rom #(
    .DEPTH     (IMEM_DEPTH),
    .INIT_FILE (INIT_FILE)
  ) u_imem (
    .addr  (core_imem_addr),
    .rd_en (core_imem_rd),
    .rdata (core_imem_rdata),
    .ready (core_imem_ready)
  );

  // ══════════════════════════════════════════════════════════════════════
  // Data memory (4 KB SRAM, simple handshake)
  // ══════════════════════════════════════════════════════════════════════
  dmem_sram #(
    .DEPTH (DMEM_DEPTH)
  ) u_dmem (
    .clk      (clk),
    .rst_n    (rst_n),
    .addr     (core_dmem_addr),
    .rd_en    (core_dmem_rd),
    .wr_en    (core_dmem_wr),
    .width    (core_dmem_width),
    .sign_ext (core_dmem_sign_ext),
    .wdata    (core_dmem_wdata),
    .rdata    (core_dmem_rdata),
    .ready    (core_dmem_ready)
  );

endmodule
