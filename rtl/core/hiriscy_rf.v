module hiriscy_rf (
  input  wire        clk,
  input  wire        rst_n,

  input  wire [4:0]  rs1_addr,
  output wire [31:0] rs1_data,
  input  wire [4:0]  rs2_addr,
  output wire [31:0] rs2_data,

  input  wire        wr_en,
  input  wire [4:0]  rd_addr,
  input  wire [31:0] rd_data
);

  wire [31:0] regs [1:31];

  genvar gi;
  generate
    for (gi = 1; gi < 32; gi = gi + 1) begin : g_reg
      hiriscy_dff_en #(.WIDTH(32)) u_reg (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (wr_en & (rd_addr == gi[4:0])),
        .rst_val (32'b0),
        .d       (rd_data),
        .q       (regs[gi])
      );
    end
  endgenerate

  assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
  assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

endmodule
