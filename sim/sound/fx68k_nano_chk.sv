// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
// R1048 bench: the two-cycle exception nanoLatch -> aluLatch / ccrCore / pswCcr.
// A multicycle of 2 is safe iff no destination loads on the clock right after the
// source changed. Destinations load only under enT3 (pswCcr also under pwrUp, a constant);
// the source changes under extReset, rstUrom or enT3. Checked every clock, both by the
// enables and by the values.
module fx68k_nano_chk(input logic clk, input logic enT3, rstUrom, extReset, pwrUp, enPhi1, enPhi2,
                input logic [67:0] nl, input logic [15:0] al, input logic [4:0] cc, input logic [4:0] ps);
  logic [67:0] nl_q; logic [15:0] al_q; logic [4:0] cc_q; logic [4:0] ps_q;
  logic nl_chg_q = 0, src_en_q = 0, e1_q = 0;
  longint unsigned n_t3 = 0, n_chg = 0, n_clk = 0, n_e1 = 0;
  always_ff @(posedge clk) begin
    n_clk <= n_clk + 1;
    nl_q <= nl; al_q <= al; cc_q <= cc; ps_q <= ps;
    nl_chg_q <= (nl != nl_q);
    src_en_q <= enT3 || rstUrom || extReset;
    e1_q <= enPhi1;
    if (enPhi1) n_e1 <= n_e1 + 1;
    if (enT3) n_t3 <= n_t3 + 1;
    if (nl != nl_q) n_chg <= n_chg + 1;
    // a destination load enabled (enT3) on the clock after a source change / source enable
    if (enT3 && src_en_q) $fatal(1, "nano_chk: enT3 the clock after a nanoLatch load enable");
    if (enT3 && nl != nl_q) $fatal(1, "nano_chk: enT3 the clock after nanoLatch changed");
    if (enPhi1 && e1_q) $fatal(1, "nano_chk: enPhi1 on two consecutive clocks");
    if (!$past(pwrUp) && (al != al_q || cc != cc_q || ps != ps_q) && !$past(enT3))
      $fatal(1, "nano_chk: an ALU latch changed without enT3");
  end
  final $display("nano_chk: %0d clocks, %0d enPhi1, %0d enT3, %0d nanoLatch changes, 0 violations", n_clk, n_e1, n_t3, n_chg);
endmodule
bind fx68k fx68k_nano_chk u_nano_chk(.clk(Clks.clk), .enT3(enT3), .rstUrom(rstUrom), .extReset(Clks.extReset), .pwrUp(Clks.pwrUp),
  .enPhi1(Clks.enPhi1), .enPhi2(Clks.enPhi2), .nl(nanoLatch), .al(excUnit.alu.aluLatch), .cc(excUnit.alu.ccrCore), .ps(excUnit.alu.pswCcr));
