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
