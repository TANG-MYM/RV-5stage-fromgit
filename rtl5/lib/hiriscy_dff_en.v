// ============================================================================
// hiriscy_dff_en.v — D flip-flop primitive (async reset + clock enable)
// ----------------------------------------------------------------------------
// Same contract as hiriscy_dff, but the register only samples `d` when `en` is
// high; otherwise it holds. Used for every register that can stall/flush/hold:
// the enable expresses "advance", and flush/bubble values are selected on `d`.
//
//   en=1 : q <= d      (advance)
//   en=0 : q <= q      (hold)
//   async low rst_n : q <= rst_val
// ============================================================================

module hiriscy_dff_en #(
  parameter WIDTH = 1
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire             en,
  input  wire [WIDTH-1:0] rst_val,
  input  wire [WIDTH-1:0] d,
  output reg  [WIDTH-1:0] q
);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)  q <= rst_val;
    else if (en) q <= d;
  end

endmodule
