// ============================================================================
// hiriscy_lsu.v — Load/Store Unit (MEM datapath, combinational)
// ============================================================================
// Drives the data-memory request from the EX/MEM register contents and selects
// the MEM-stage result (load data vs. ALU/PC result). Sub-word alignment and
// sign extension are performed inside the data memory (hiriscy_dmem). All MEM
// pipeline state (the EX/MEM register) lives in the core top.
//
// dmem_rd/dmem_wr are gated by `run` so a paused/halted/WFI core issues no
// memory transactions.
// ============================================================================

module hiriscy_lsu (
  // EX/MEM register contents
  input  wire [43:0]          ctrl_mem,      // CTRL_W = 44
  input  wire [31:0]          ex_result_mem, // address / ALU result
  input  wire [31:0]          rs2_data_mem,  // store data

  input  wire                 run,           // pipeline running

  // Data memory interface
  output wire [31:0]          dmem_addr,
  output wire                 dmem_rd,
  output wire                 dmem_wr,
  output wire [1:0]           dmem_width,
  output wire                 dmem_sign_ext,
  output wire [31:0]          dmem_wdata,
  input  wire [31:0]          dmem_rdata,

  // MEM-stage result (to MEM/WB register)
  output wire [31:0]          mem_result
);

  `include "hiriscy_defs.vh"

  assign dmem_addr     = ex_result_mem;
  assign dmem_rd       = ctrl_mem[`CTRL_MEM_RD] & run;
  assign dmem_wr       = ctrl_mem[`CTRL_MEM_WR] & run;
  assign dmem_width    = ctrl_mem[`CTRL_MEM_WIDTH];
  assign dmem_sign_ext = ctrl_mem[`CTRL_MEM_SIGN];
  assign dmem_wdata    = rs2_data_mem;

  assign mem_result    = ctrl_mem[`CTRL_MEM_RD] ? dmem_rdata : ex_result_mem;

endmodule
