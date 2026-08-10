// ============================================================================
// hiriscy_alu.v — 32-bit ALU (pure combinational, assign-based)
// ============================================================================

module hiriscy_alu (
  input  wire [31:0] a,
  input  wire [31:0] b,
  input  wire [3:0]  op,
  output wire [31:0] result,
  output wire        zero
);

  `include "hiriscy_defs.vh"

  assign result = (op == ALU_ADD)    ? (a + b)                              :
                  (op == ALU_SUB)    ? (a - b)                              :
                  (op == ALU_SLL)    ? (a << b[4:0])                        :
                  (op == ALU_SLT)    ? {31'b0, $signed(a) < $signed(b)}     :
                  (op == ALU_SLTU)   ? {31'b0, a < b}                       :
                  (op == ALU_XOR)    ? (a ^ b)                              :
                  (op == ALU_SRL)    ? (a >> b[4:0])                        :
                  (op == ALU_SRA)    ? $unsigned($signed(a) >>> b[4:0])     :
                  (op == ALU_OR)     ? (a | b)                              :
                  (op == ALU_AND)    ? (a & b)                              :
                  (op == ALU_PASS_B) ? b                                    :
                  32'b0;

  assign zero = (result == 32'b0);

endmodule
