// ============================================================================
// hiriscy_dff.v — D flip-flop primitive (async reset, always update)
// ----------------------------------------------------------------------------
// The ONLY place in the datapath where a clocked always-block is allowed. Every
// other module expresses combinational logic with continuous `assign`s and
// realises state by instantiating this (or hiriscy_dff_en).
//
//   q <= d on every rising clk edge; q <= rst_val on async low rst_n.
//
// The reset value is a PORT (not a parameter) so blocks whose reset value is a
// runtime signal (e.g. the PC resetting to start_pc) can use the same cell.
// ============================================================================

module hiriscy_dff #(
  parameter WIDTH = 1
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire [WIDTH-1:0] rst_val,
  input  wire [WIDTH-1:0] d,
  output reg  [WIDTH-1:0] q
);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) q <= rst_val;
    else        q <= d;
  end

endmodule
