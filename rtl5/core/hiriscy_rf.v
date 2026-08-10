// ============================================================================
// hiriscy_rf.v — 32x32 Register File (RF)
// ============================================================================
// Two read ports (combinational assign), one write port. x0 is hardwired to
// zero (no physical register). No internal forwarding (handled by the IDU
// hazard logic). State is realised with hiriscy_dff_en cells, one per x1..x31;
// each register's enable is its own write-select, so no clocked always-block
// lives here.
// ============================================================================

module hiriscy_rf (
  input  wire        clk,
  input  wire        rst_n,

  // Read ports (combinational)
  input  wire [4:0]  rs1_addr,
  output wire [31:0] rs1_data,
  input  wire [4:0]  rs2_addr,
  output wire [31:0] rs2_data,

  // Write port (synchronous, rising edge)
  input  wire        wr_en,
  input  wire [4:0]  rd_addr,
  input  wire [31:0] rd_data
);

  wire [31:0] regs [1:31];

  // ── Write port: one enabled DFF per architectural register ────────────
  // x0 has no register (gi starts at 1); a write to x0 matches no enable and
  // is therefore discarded, satisfying the RISC-V "x0 is constant 0" rule.
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

  // ── Read ports (x0 reads as 0) ────────────────────────────────────────
  assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
  assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

endmodule
