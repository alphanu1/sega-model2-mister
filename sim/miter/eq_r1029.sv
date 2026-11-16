// R1029-2C: the rasteriser's rewritten expressions, old form (cf6916e3) against
// new, on random and edge-biased inputs. verilator --binary --top-module eq eq_r1029.sv
module eq;
  // ---- span_tex: the clamp and the mirror bits (UVCL, MIP)
  function automatic logic [19:0] to_tx(input logic signed [31:0] q);
    to_tx = q[31] ? 20'd0 : q[29:10];
  endfunction
  function automatic logic [19:0] uv_cl(input logic [19:0] t, input logic [10:0] lo, input logic [10:0] hm);
    logic [12:0] ti, dl, dh;
    begin
      ti = 13'(t[19:8]); dl = 13'(lo) - ti; dh = ti - 13'(hm);
      if ((dl == 13'd1) || ((dl == 13'd0) && (t[7:0] == 8'd0))) uv_cl = {1'b0, lo, 8'h01};
      else if (dh == 13'd1) uv_cl = {1'b0, hm, 8'hFF};
      else uv_cl = t;
    end
  endfunction
  function automatic logic [1:0] uv_hit(input logic [19:0] t, input logic [10:0] lo, input logic [10:0] hm);
    logic [12:0] ti, dl, dh; logic l;
    begin
      ti = 13'(t[19:8]); dl = 13'(lo) - ti; dh = ti - 13'(hm);
      l  = (dl == 13'd1) || ((dl == 13'd0) && (t[7:0] == 8'd0));
      uv_hit = {!l && (dh == 13'd1), l};
    end
  endfunction
  // ---- span_tex: the mask query
  function automatic logic slt16(input logic signed [15:0] a, input logic signed [15:0] b);
    logic [16:0] d; begin d = {a[15], a} - {b[15], b}; slt16 = d[16]; end
  endfunction
  localparam logic signed [15:0] QXMAX = 16'sd495;
  // ---- fill
  function automatic logic gt8(input logic [7:0] a, input logic [7:0] b);
    logic [8:0] d; begin d = {1'b0, b} - {1'b0, a}; gt8 = d[8]; end
  endfunction

  longint n_cl = 0, n_hit = 0, n_q = 0, n_f1 = 0, n_sh = 0, bad = 0;
  initial begin
    for (int i = 0; i < 200000000; i++) begin
      // the clamp
      logic signed [31:0] du, dv; logic [44:0] ub; logic [23:0] mt; logic [2:0] L;
      logic [19:0] tu_o, tv_o, tu_n, tv_n, tut, tvt; logic fu_o, fv_o, fu_n, fv_n, on;
      logic [4:0] bu, bv; logic [1:0] hu, hv;
      logic [10:0] lo, hm;
      lo = 11'($urandom); hm = 11'($urandom);
      if ($urandom % 4 != 0) begin   // near the box: within two texels of either edge
        logic [11:0] e; e = 12'((($urandom % 2) ? lo : hm)) + 12'($urandom % 5) - 12'd2;
        du = 32'({2'b00, e, 8'($urandom), 10'($urandom)});
      end else du = $urandom;
      if ($urandom % 8 == 0) du[31] = 1'b1;
      dv = $urandom; if ($urandom % 2) dv = {2'b00, 12'(hm + 11'($urandom % 3) - 11'd1), 8'($urandom % 2 ? 0 : $urandom), 10'($urandom)};
      ub = {1'($urandom % 8 == 0), lo, hm, 11'($urandom), 11'($urandom)};
      if ($urandom % 2) ub[21:0] = {lo, hm};
      mt = 24'($urandom); L = 3'($urandom % 8 < 5 ? 0 : $urandom);
      on = !ub[44] && (L == 3'd0);
      // old
      tu_o = on ? uv_cl(to_tx(du), ub[43:33], ub[32:22]) : to_tx(du);
      tv_o = on ? uv_cl(to_tx(dv), ub[21:11], ub[10:0])  : to_tx(dv);
      bu = 5'd13 + {2'd0, mt[3:1]} - {2'd0, L}; bv = 5'd13 + {2'd0, mt[6:4]} - {2'd0, L};
      fu_o = mt[9]  && tu_o_bit(tu_o, bu); fv_o = mt[10] && tu_o_bit(tv_o, bv);
      // new
      tut = to_tx(du); tvt = to_tx(dv);
      hu = uv_hit(tut, ub[43:33], ub[32:22]); hv = uv_hit(tvt, ub[21:11], ub[10:0]);
      tu_n = (on && hu[0]) ? {1'b0, ub[43:33], 8'h01} : (on && hu[1]) ? {1'b0, ub[32:22], 8'hFF} : tut;
      tv_n = (on && hv[0]) ? {1'b0, ub[21:11], 8'h01} : (on && hv[1]) ? {1'b0, ub[10:0], 8'hFF} : tvt;
      fu_n = mt[9]  && ((on && hu[0]) ? tu_o_bit({1'b0, ub[43:33], 8'h01}, bu) : (on && hu[1]) ? tu_o_bit({1'b0, ub[32:22], 8'hFF}, bu) : tu_o_bit(tut, bu));
      fv_n = mt[10] && ((on && hv[0]) ? tu_o_bit({1'b0, ub[21:11], 8'h01}, bv) : (on && hv[1]) ? tu_o_bit({1'b0, ub[10:0], 8'hFF}, bv) : tu_o_bit(tvt, bv));
      if (on && (hu != 0 || hv != 0)) n_hit++;
      if ((on && (hu != 0)) && mt[9] && (tu_o_bit(tut, bu) != fu_n)) n_cl++;   // the clamp changed the mirror bit
      if (tu_o != tu_n || tv_o != tv_n || fu_o != fu_n || fv_o != fv_n) begin
        bad++; if (bad < 5) $display("CLAMP differs: du %h ub %h mt %h L %0d", du, ub, mt, L);
      end
      // the mask query
      begin
        logic signed [15:0] qx, qx1, qsm1, qe, qxe, xa, xb_o, xb_n; logic f1_o, f1_n, cex, cem, cxm, xlt;
        logic [31:0] need_o, need_n; logic f0_o, f0_n;
        if ($urandom % 4 == 0) begin qx = 16'($urandom); qx1 = 16'($urandom); qsm1 = 16'($urandom); end
        else begin qx = 16'(int'($urandom % 1400) - 500); qx1 = 16'(int'($urandom % 1400) - 500); qsm1 = 16'($urandom % 8); end
        qe = qx + qsm1; qxe = (qe > qx1) ? qx1 : qe; xa = (qx < 16'sd0) ? 16'sd0 : qx;
        xb_o = (qxe > QXMAX) ? QXMAX : qxe;
        f1_o = (xb_o < xa); f0_o = !f1_o && (xa[15:5] != xb_o[15:5]);
        need_o = (32'hFFFF_FFFF << xa[4:0]) & (32'hFFFF_FFFF >> (5'd31 - xb_o[4:0]));
        cex = slt16(qx1, qe); cem = slt16(QXMAX, qe); cxm = slt16(QXMAX, qx1);
        xb_n = (cex ? cxm : cem) ? QXMAX : (cex ? qx1 : qe);
        xlt = slt16(qe, qx) || qe[15] || slt16(qx1, qx) || qx1[15] || slt16(QXMAX, qx);
        f1_n = xlt; f0_n = !f1_n && (xa[15:5] != xb_n[15:5]);
        need_n = (32'hFFFF_FFFF << xa[4:0]) & (32'hFFFF_FFFF >> (5'd31 - xb_n[4:0]));
        n_q++; if (f1_o) n_f1++;
        if (xb_o != xb_n || f1_o != f1_n || f0_o != f0_n || need_o != need_n) begin
          bad++; if (bad < 5) $display("QUERY differs: qx %0d qx1 %0d qsm1 %0d", qx, qx1, qsm1);
        end
      end
      // the fill's shift
      begin
        logic signed [31:0] n, mo, s1, mn; logic [5:0] z; logic pass; logic [4:0] zm1;
        n = $urandom; z = 6'($urandom % 70);
        if ($urandom % 2) begin n = n >>> ($urandom % 32); end
        if ($urandom % 64 == 0) n = 32'sh8000_0000;
        if ($urandom % 64 == 0) n = 0;
        mo = ((z >= 6'd32) || (z == 6'd0)) ? n : (n <<< 5'(z - 6'd1));
        pass = (z >= 6'd32) || (z == 6'd0); zm1 = pass ? 5'd0 : 5'(z - 6'd1);
        s1 = n <<< {zm1[4:3], 3'b000}; mn = s1 <<< zm1[2:0];
        n_sh++;
        if (mo != mn) begin bad++; if (bad < 5) $display("SHIFT differs: n %h z %0d", n, z); end
      end
    end
    // gt8, every pair
    for (int a = 0; a < 256; a++) for (int b = 0; b < 256; b++)
      if (gt8(8'(a), 8'(b)) != (a > b)) begin bad++; if (bad < 5) $display("GT8 differs %0d %0d", a, b); end
    $display("EQ: clamp vectors 200000000 (clamp active %0d, mirror bit moved by the clamp %0d), query %0d (f1 %0d), shift %0d, gt8 65536 pairs: %0d differ",
             n_hit, n_cl, n_q, n_f1, n_sh, bad);
    $finish;
  end
  function automatic logic tu_o_bit(input logic [19:0] t, input logic [4:0] b);
    logic [31:0] w; begin w = {12'd0, t}; tu_o_bit = w[b]; end
  endfunction
endmodule
