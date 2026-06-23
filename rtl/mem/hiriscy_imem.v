// ============================================================================
// hiriscy_imem.v — Instruction Memory (register-file style, read-only)
// ----------------------------------------------------------------------------
// DEPTH x 32-bit storage array, combinational (same-cycle) read, always ready.
// Initialised from a hex image via $readmemh. Word-addressed by addr[*:2].
// ============================================================================

module hiriscy_imem #(
  parameter DEPTH     = 1024,            // number of 32-bit instruction words
  parameter INIT_FILE = "firmware.hex"
)(
  input  wire [31:0] addr,
  input  wire        rd_en,              // ignored: ROM always returns data
  output wire [31:0] rdata,
  output wire        ready
);

  localparam AW = $clog2(DEPTH);

  reg [31:0] mem [0:DEPTH-1];

  integer i;
  initial begin
    for (i = 0; i < DEPTH; i = i + 1)
      mem[i] = 32'h0000_0013;  // NOP (addi x0,x0,0)
    if (INIT_FILE != "")
      $readmemh(INIT_FILE, mem);
  end

  // Combinational (same-cycle) read, like a register file.
  assign rdata = mem[addr[AW+1:2]];
  assign ready = 1'b1;

endmodule
