// ============================================================================
// dmem_sram.v — Data SRAM (simple handshake, no AXI)
// ----------------------------------------------------------------------------
// DEPTH x 32-bit synchronous SRAM (default 1024 words = 4 KB).
// Access protocol: assert rd_en/wr_en with a stable address; data/ack arrive
// on the NEXT cycle (ready pulses one cycle after the request is presented).
// Supports byte / half / word access with sign extension on reads.
// The CPU holds the request stable while ready is low (pipeline stalls), so a
// single-cycle latency is modelled by a 1-bit ready toggle.
// ============================================================================

module dmem_sram #(
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
  output reg  [31:0] rdata,
  output reg         ready
);

  `include "brv32p_defs.vh"

  localparam AW = $clog2(DEPTH);

  reg [31:0] mem [0:DEPTH-1];

  wire [AW-1:0] word_idx = addr[AW+1:2];
  wire [1:0]    byte_off = addr[1:0];

  // ── Write strobe / aligned write data ────────────────────────────────────
  reg [3:0]  wstrb;
  reg [31:0] wdata_aligned;
  always @(*) begin
    case (width)
      MEM_BYTE: begin wstrb = 4'b0001 << byte_off;          wdata_aligned = {4{wdata[7:0]}};  end
      MEM_HALF: begin wstrb = byte_off[1] ? 4'b1100 : 4'b0011; wdata_aligned = {2{wdata[15:0]}}; end
      MEM_WORD: begin wstrb = 4'b1111;                       wdata_aligned = wdata;            end
      default:  begin wstrb = 4'b1111;                       wdata_aligned = wdata;            end
    endcase
  end

  // ── Single-cycle-latency handshake ───────────────────────────────────────
  // ready is high on the second cycle of each access (request held stable).
  wire req = rd_en | wr_en;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      ready <= 1'b0;
    else
      ready <= req & ~ready;
  end

  // ── Synchronous write (commit on the first cycle of a write access) ───────
  integer b;
  always @(posedge clk) begin
    if (wr_en & ~ready) begin
      for (b = 0; b < 4; b = b + 1)
        if (wstrb[b])
          mem[word_idx][b*8 +: 8] <= wdata_aligned[b*8 +: 8];
    end
  end

  // ── Synchronous read (data available next cycle) ─────────────────────────
  reg [31:0] rword;
  always @(posedge clk) begin
    rword <= mem[word_idx];
  end

  // ── Sub-word extraction + sign extension (inputs stable during stall) ─────
  reg [7:0]  byte_val;
  reg [15:0] half_val;
  always @(*) begin
    rdata    = rword;
    byte_val = 8'b0;
    half_val = 16'b0;
    case (width)
      MEM_BYTE: begin
        case (byte_off)
          2'd0: byte_val = rword[7:0];
          2'd1: byte_val = rword[15:8];
          2'd2: byte_val = rword[23:16];
          2'd3: byte_val = rword[31:24];
        endcase
        rdata = sign_ext ? {{24{byte_val[7]}}, byte_val} : {24'b0, byte_val};
      end
      MEM_HALF: begin
        half_val = byte_off[1] ? rword[31:16] : rword[15:0];
        rdata = sign_ext ? {{16{half_val[15]}}, half_val} : {16'b0, half_val};
      end
      MEM_WORD: rdata = rword;
      default:  rdata = rword;
    endcase
  end

endmodule
