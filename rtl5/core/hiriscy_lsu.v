// ============================================================================
// hiriscy_lsu.v — Load/Store Unit (MEM datapath: data_sel + result select)
// ============================================================================
// The dmem access (address, ce, we, we_data) is issued in the EX stage.
// By the time the instruction reaches MEM, dmem_rd_data is valid (registered
// in the dmem macro from EX's read). This unit only does:
//   - data_sel: select the correct 32-bit word from 128-bit dmem_rd_data
//   - sub-word extraction + sign extension (for byte/half loads)
//   - select between load data and the EX-stage ALU result
// ============================================================================

module hiriscy_lsu (
  // EX/MEM register contents
  input  wire [43:0]   ctrl_mem,
  input  wire [31:0]   ex_result_mem,  // address bits (for data_sel) / ALU result
  input  wire [127:0]  dmem_rd_data,   // registered read data (from EX's access)

  // MEM-stage result (to MEM/WB register)
  output wire [31:0]   mem_result
);

  `include "hiriscy_defs.vh"

  wire [1:0]  byte_off  = ex_result_mem[1:0];
  wire [1:0]  word_sel  = ex_result_mem[3:2];
  wire        mem_rd    = ctrl_mem[`CTRL_MEM_RD];
  wire [1:0]  mem_width = ctrl_mem[`CTRL_MEM_WIDTH];
  wire        sign_ext  = ctrl_mem[`CTRL_MEM_SIGN];

  // ── data_sel: 128-bit → 32-bit word selection ──────────────────────────
  wire [31:0] rword = dmem_rd_data[32*word_sel +: 32];

  // ── Sub-word extraction + sign extension ───────────────────────────────
  wire [7:0]  byte_val = (byte_off == 2'd0) ? rword[7:0]   :
                         (byte_off == 2'd1) ? rword[15:8]  :
                         (byte_off == 2'd2) ? rword[23:16] : rword[31:24];
  wire [15:0] half_val = byte_off[1] ? rword[31:16] : rword[15:0];

  wire [31:0] load_data =
    (mem_width == MEM_BYTE) ? (sign_ext ? {{24{byte_val[7]}},  byte_val} : {24'b0, byte_val}) :
    (mem_width == MEM_HALF) ? (sign_ext ? {{16{half_val[15]}}, half_val} : {16'b0, half_val}) :
    rword;

  // ── Result select: load data vs ALU result ──────────────────────────────
  assign mem_result = mem_rd ? load_data : ex_result_mem;

endmodule
