module hiriscy_ifu (
  input  wire [31:0] pc_if,

  input  wire        branch_mispredict_ex,
  input  wire [31:0] branch_target_ex,

  input  wire        wfi_active,
  input  wire        wfi_idle,

  input  wire        stop_fetch_exc,

  output wire [31:0] pc_next,
  output wire [31:0] imem_addr,
  output wire        imem_ce,
  output wire        fetch_misalign
);

  assign pc_next   = branch_mispredict_ex ? branch_target_ex : (pc_if + 32'd4);

  assign imem_addr = pc_if;
  assign imem_ce   = ~(wfi_active | wfi_idle | stop_fetch_exc);

  assign fetch_misalign = (pc_if[1:0] != 2'b00);

endmodule
