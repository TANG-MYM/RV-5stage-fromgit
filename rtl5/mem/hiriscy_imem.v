// ============================================================================
// hiriscy_imem.v — Instruction Memory (register-file style, read-only)
// ----------------------------------------------------------------------------
// Unified interface: clk, addr, we, ce, we_data, rd_data
// 32-bit data width, combinational (same-cycle) read
// ============================================================================

module hiriscy_imem #(
  parameter DEPTH     = 1024,
  parameter INIT_FILE = "firmware.hex"
)(
  input  wire        clk,
  input  wire        rst_n,

  input  wire [31:0] addr,
  input  wire        ce,
  input  wire        we,
  input  wire [31:0] we_data,
  output wire [31:0] rd_data
);

  localparam AW = $clog2(DEPTH);

  reg [31:0] mem [0:DEPTH-1];

  integer i;
  initial begin
    for (i = 0; i < DEPTH; i = i + 1)
      mem[i] = 32'h0000_0013;
    if (INIT_FILE != "")
      $readmemh(INIT_FILE, mem);
  end

  always @(posedge clk) begin
    if (ce & we)
      mem[addr[AW+1:2]] <= we_data;
  end

  assign rd_data = mem[addr[AW+1:2]];

endmodule
