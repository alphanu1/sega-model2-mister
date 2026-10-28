// R968: the Test button into m2_vcop_state, old against new.
//
// Old: hps_io's joystick_0[8] (a rising-edge clk_sys register) straight into
// t_q on clk_i960. New: through a register on clk_sys's falling edge. clk_sys
// 80 MHz and clk_i960 40 MHz from one PLL, rising edges aligned, as built.
// The button and the bus are random every clk_sys / clk_i960 cycle (presses as
// short as one clk_sys cycle); t_q, tl and play of the two copies are compared
// at every clk_i960 edge. MUT=1 builds the new path from a RISING-edge
// clk_sys register instead, which must differ (a press on the clk_sys edge
// between two clk_i960 edges then arrives one clk_i960 edge late).
//
//   iverilog -g2012 -o x sim/io/tb_r968_test_cdc.sv rtl/io/m2_vcop_state.sv && vvp x +n=2000000
`timescale 1ns/1ps
module tb_r968_test_cdc;
  parameter bit MUT = 1'b0;
  // clk_sys starts high so that its rising edges (12.5, 25, ...) fall on
  // clk_i960's (12.5, 37.5, ...) every other cycle, as the PLL has them
  logic clk_sys = 1'b1, clk_i960 = 1'b0, rst_n = 1'b0;
  always #6.25 clk_sys  = ~clk_sys;
  always #12.5 clk_i960 = ~clk_i960;

  // hps_io's joystick_0[8]: a rising-edge clk_sys register
  logic joy8 = 1'b0;
  int unsigned rs = 32'h1234_5678;
  function automatic int unsigned rnd();
    rs = rs ^ (rs << 13); rs = rs ^ (rs >> 17); rs = rs ^ (rs << 5);
    return rs;
  endfunction
  always @(posedge clk_sys) begin
    // runs of random length: mostly held, sometimes a one-cycle press
    if (rnd() % 8 == 0) joy8 <= ~joy8;
  end

  // the new crossing, as Model2.sv has it (or the mutation)
  logic test_n;
  generate if (MUT) begin : g_mut
    always @(posedge clk_sys) test_n <= joy8;
  end else begin : g_new
    always @(negedge clk_sys) test_n <= joy8;
  end endgenerate

  // the i960 bus, random, on clk_i960 (writes to the three watched words often)
  logic        bus_req, bus_we, bus_ack;
  logic [31:0] bus_addr, bus_wdata;
  logic  [3:0] bus_be;
  int unsigned r;
  always @(posedge clk_i960) begin
    r = rnd();
    bus_req   <= r[0];
    bus_we    <= r[1];
    bus_ack   <= r[2];
    bus_be    <= {3'b000, r[3]};
    case (r[6:4])
      3'd0: bus_addr <= 32'h0050ee34;
      3'd1: bus_addr <= 32'h0050ee30;
      3'd2: bus_addr <= 32'h005016d4;
      default: bus_addr <= {16'h0050, r[31:16]};
    endcase
    bus_wdata <= (r[9:8] == 2'd0) ? 32'd7 : (r[9:8] == 2'd1) ? 32'd1 : {24'd0, r[31:24]};
  end

  logic [1:0] play_o, play_n;
  m2_vcop_state u_old (.clk(clk_i960), .rst_n(rst_n), .en(1'b1), .test(joy8),
    .bus_req(bus_req), .bus_we(bus_we), .bus_ack(bus_ack), .bus_addr(bus_addr),
    .bus_wdata(bus_wdata), .bus_be(bus_be), .play(play_o));
  m2_vcop_state u_new (.clk(clk_i960), .rst_n(rst_n), .en(1'b1), .test(test_n),
    .bus_req(bus_req), .bus_we(bus_we), .bus_ack(bus_ack), .bus_addr(bus_addr),
    .bus_wdata(bus_wdata), .bus_be(bus_be), .play(play_n));

  longint unsigned n = 2000000, cyc = 0, bad = 0, tq1 = 0, tl1 = 0, pl = 0;
  initial begin
    void'($value$plusargs("n=%d", n));
    bus_req = 0; bus_we = 0; bus_ack = 0; bus_addr = 0; bus_wdata = 0; bus_be = 0;
    repeat (4) @(posedge clk_i960);
    rst_n = 1'b1;
  end
  always @(posedge clk_i960) if (rst_n) begin
    #1;
    cyc++;
    if (u_old.t_q) tq1++;
    if (u_old.tl) tl1++;
    if (play_o != 2'b00) pl++;
    if (u_old.t_q != u_new.t_q || u_old.tl != u_new.tl || play_o != play_n) begin
      bad++;
      if (bad <= 5) $display("differ at clk_i960 cycle %0d: t_q %b/%b tl %b/%b play %b/%b", cyc,
                             u_old.t_q, u_new.t_q, u_old.tl, u_new.tl, play_o, play_n);
    end
    if (cyc == n) begin
      $display("r968 test crossing%s: %0d clk_i960 cycles, %0d differing (t_q high %0d, tl high %0d, play nonzero %0d) %s",
               MUT ? " (MUTATION)" : "", cyc, bad, tq1, tl1, pl, bad == 0 ? "PASS" : "FAIL");
      $finish;
    end
  end
endmodule
