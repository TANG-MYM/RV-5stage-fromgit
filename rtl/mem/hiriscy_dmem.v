// ============================================================================
// hiriscy_dmem.v — Data SRAM (simple handshake, no AXI)
// ----------------------------------------------------------------------------
// DEPTH x 32-bit synchronous SRAM (default 1024 words = 4 KB).
// Access protocol: assert rd_en/wr_en with a stable address; data/ack arrive
// on the NEXT cycle (ready pulses one cycle after the request is presented).
// Supports byte / half / word access with sign extension on reads.
// The CPU holds the request stable while ready is low (pipeline stalls), so a
// single-cycle latency is modelled by a 1-bit ready toggle.
//
// Style note: all random logic is expressed with continuous `assign`s and the
// registers are hiriscy_dff cells. The STORAGE ARRAY itself (`mem`) is a memory
// macro and is intentionally kept behavioural (it is not built from discrete
// flip-flops); its byte-write is the only clocked always-block left here.
// ============================================================================

module hiriscy_dmem #(
  parameter DEPTH = 1024  // 1024 x 32-bit = 4 KB
)(
  input  wire        clk,
  input  wire        rst_n,

  input  wire [31:0] addr,
  input  wire        rd_en,
  input  wire        wr_en,
  input  wire [1:0]  width,      // MEM_BYTE / MEM_HALF / MEM_WORD
  input  wire        sign_ext,
  input  wire [31:0] wdata,
  output wire [31:0] rdata,
  output wire        ready
);

  `include "hiriscy_defs.vh"

  localparam AW = $clog2(DEPTH);

  reg [31:0] mem [0:DEPTH-1];

  wire [AW-1:0] word_idx = addr[AW+1:2];
  wire [1:0]    byte_off = addr[1:0];

  // ── Write strobe / aligned write data ────────────────────────────────────
  wire [3:0] wstrb = (width == MEM_BYTE) ? (4'b0001 << byte_off)          :
                     (width == MEM_HALF) ? (byte_off[1] ? 4'b1100 : 4'b0011) :
                     4'b1111;
  wire [31:0] wdata_aligned = (width == MEM_BYTE) ? {4{wdata[7:0]}}  :
                              (width == MEM_HALF) ? {2{wdata[15:0]}} :
                              wdata;

  // ── Single-cycle-latency handshake ───────────────────────────────────────
  // ready is high on the second cycle of each access (request held stable).
  wire req      = rd_en | wr_en;
  wire ready_d  = req & ~ready;
  hiriscy_dff #(.WIDTH(1)) u_ready (
    .clk (clk), .rst_n (rst_n), .rst_val (1'b0), .d (ready_d), .q (ready)
  );

  // ── Synchronous write (commit on the first cycle of a write access) ───────
  // Storage array = SRAM macro, kept behavioural (see header note).
  integer b;
  always @(posedge clk) begin
    if (wr_en & ~ready) begin
      for (b = 0; b < 4; b = b + 1)
        if (wstrb[b])
          mem[word_idx][b*8 +: 8] <= wdata_aligned[b*8 +: 8];
    end
  end

  // ── Synchronous read (data available next cycle) ─────────────────────────
  wire [31:0] rword;
  hiriscy_dff #(.WIDTH(32)) u_rword (
    .clk (clk), .rst_n (rst_n), .rst_val (32'b0), .d (mem[word_idx]), .q (rword)
  );

  // ── Sub-word extraction + sign extension (inputs stable during stall) ─────
  wire [7:0] byte_val = (byte_off == 2'd0) ? rword[7:0]   :
                        (byte_off == 2'd1) ? rword[15:8]  :
                        (byte_off == 2'd2) ? rword[23:16] : rword[31:24];
  wire [15:0] half_val = byte_off[1] ? rword[31:16] : rword[15:0];

  assign rdata =
    (width == MEM_BYTE) ? (sign_ext ? {{24{byte_val[7]}},  byte_val} : {24'b0, byte_val}) :
    (width == MEM_HALF) ? (sign_ext ? {{16{half_val[15]}}, half_val} : {16'b0, half_val}) :
    rword;

endmodule
