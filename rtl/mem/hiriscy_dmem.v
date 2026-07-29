// ============================================================================
// hiriscy_dmem.v — Data SRAM (256 x 128-bit)
// ----------------------------------------------------------------------------
// Unified interface: clk, addr, we, ce, we_data, rd_data
// we is 128-bit write strobe (mask) for we_data
// Read data available next cycle (synchronous read)
// Write data committed on the same cycle
// ============================================================================

module hiriscy_dmem #(
  parameter DEPTH = 256
)(
  input  wire        clk,
  input  wire        rst_n,

  input  wire [11:0] addr,
  input  wire        ce,
  input  wire [127:0] we,
  input  wire [127:0] we_data,
  output wire [127:0] rd_data
);

  localparam AW = $clog2(DEPTH);

  reg [127:0] mem [0:DEPTH-1];
  reg [127:0] rd_data_r;

  integer b;
  always @(posedge clk) begin
    if (ce) begin
      for (b = 0; b < 128; b = b + 1)
        if (we[b])
          mem[addr[AW+3:4]][b] <= we_data[b];
      rd_data_r <= mem[addr[AW+3:4]];
    end
  end

  assign rd_data = rd_data_r;

endmodule
