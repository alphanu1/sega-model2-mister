`timescale 1ns/1ps
// R989 bench: what MiSTer's video_calc (sys/hps_io.sv) measures from the native 24 kHz picture, which is what Main
// puts in Direct Video's DV1 info frame (width, pixel repetition, DE start). The source is the core's own native
// timing (m2_video_timing, 656 x 424 at 16/100 of clk_mem); CE_PIXEL is either the native 16/100 enable (the old
// output, sel 0) or R989's steady 1 in 5 (sel 1). Every phase of both enables against the line is swept: 25 for
// the native accumulator (it only holds multiples of 4) and 5 for the 1-in-5 counter, 125 runs a mode.
//
// PASS needs, at every phase with sel 1: repetition 5, width 620, 384 lines, 3,100 DE clocks a line (repetition x
// width = the clocks the picture really spans). sel 0 is the reproduction: there repetition x 496 != 3,100.
module tb_dv24_vcalc;
  logic clk = 0;
  always #5 clk = ~clk;

  logic       rst_n = 0;
  logic       sel = 0;
  logic [6:0] acc = 0;
  logic       ce_nat = 0;
  logic [2:0] c5 = 0;
  logic       ce5 = 0;
  always @(posedge clk) begin
    if (acc + 7'd16 >= 7'd100) begin acc <= acc + 7'd16 - 7'd100; ce_nat <= 1'b1; end
    else begin acc <= acc + 7'd16; ce_nat <= 1'b0; end
    c5  <= (c5 >= 3'd4) ? 3'd0 : c5 + 3'd1;
    ce5 <= (c5 == 3'd4);
  end

  logic [9:0] thc, tvc;
  logic       thb, tvb, ths, tvs;
  m2_video_timing tm (.clk(clk), .ce_pix(ce_nat), .rst_n(rst_n), .interlace(1'b0), .ntsc_lines(1'b0),
                      .mid_lines(1'b0), .narrow(1'b0), .hcnt(thc), .vcnt(tvc), .hblank(thb), .vblank(tvb),
                      .hsync(ths), .vsync(tvs), .visible(), .line_start(), .line_number(), .vblank_start(), .field(),
                      .ypos(), .vtotal());

  wire ce = sel ? ce5 : ce_nat;
  wire de = ~(thb | tvb);
  logic [15:0] dout;
  video_calc vc (.clk_100(clk), .clk_vid(clk), .clk_sys(clk), .ce_pix(ce), .de(de), .hs(ths), .vs(tvs),
                 .vs_hdmi(tvs), .f1(1'b0), .new_vmode(1'b0), .video_rotated(1'b0), .par_num(5'd0), .dout(dout));

  localparam int FRAME = 1738400;
  int fails = 0, runs = 0;
  int hist [16];

  task automatic run(input bit s, input int pa, input int p5);
    rst_n = 0; sel = s;
    @(posedge clk); acc = 7'(pa); c5 = 3'(p5);
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (4 * FRAME) @(posedge clk);
    runs++;
    if (vc.vid_pixrep < 16) hist[vc.vid_pixrep]++;
    if (s) begin
      if (vc.vid_pixrep != 5 || vc.vid_hcnt != 620 || vc.vid_vcnt != 384 || vc.vid_pix != 3100 || vc.vid_ccnt != 3100) begin
        fails++;
        $display("FAIL sel1 acc=%0d c5=%0d: rep %0d width %0d lines %0d DE clocks %0d / %0d", pa, p5,
                 vc.vid_pixrep, vc.vid_hcnt, vc.vid_vcnt, vc.vid_pix, vc.vid_ccnt);
      end
    end else if (vc.vid_pixrep * vc.vid_hcnt == vc.vid_pix) begin
      $display("note sel0 acc=%0d: rep %0d x width %0d = %0d (matches)", pa, vc.vid_pixrep, vc.vid_hcnt, vc.vid_pix);
    end
  endtask

  initial begin
    for (int s = 0; s < 2; s++) begin
      foreach (hist[i]) hist[i] = 0;
      for (int pa = 0; pa < 100; pa += 4)
        for (int p5 = 0; p5 < (s ? 5 : 1); p5++) run(s[0], pa, p5);
      $display("sel %0d (%s): %0d runs; repetition seen: 5 x%0d, 6 x%0d, 7 x%0d; last width %0d, lines %0d, DE clocks %0d, de_h %0d",
               s, s ? "R989 1-in-5" : "native 16/100", runs, hist[5], hist[6], hist[7], vc.vid_hcnt, vc.vid_vcnt,
               vc.vid_pix, vc.vid_de_h);
      if (!s) $display("  native: repetition x 496 = %0d / %0d clocks the picture spans", 6 * 496, 7 * 496);
      runs = 0;
    end
    $display("%s: %0d failures", fails ? "FAIL" : "PASS", fails);
    $finish;
  end
endmodule
