// m2_wr_arb -- one owner at a time on the shared SDRAM write port (R209).
//
// The write port behind m2_sdram_x2 is one req/addr/din/ack, and its `w_done`
// mask clears ONLY when the request line falls. Model2.sv used to MUX five
// owners onto it by fixed priority, combinationally: the coprocessor's
// buffer-RAM writes above the geometrizer's push DMA. Two owners alternating
// keep the composite request high across the change, so the single
// acknowledge pulse retired whichever owner was selected on that cycle -- not
// the one whose write landed -- and with `w_done` still set no later request
// was ever issued again. Measured on the board: TGP parked at 0x46E with the
// mailbox write at 0x46F in flight, the push DMA in its high-half state, the
// i960 in the mailbox poll, every counter frozen (build/ack s14, 2026-09-11).
//
// Model 1 (m1_integrated.sv, t_owner_change) suppresses the request for the
// cycle the owner changes and qualifies each acknowledge by owner. That is
// enough for its two owners, which never preempt one another mid-transaction.
// Here they can, so the owner is GRANTED, held from its request to its
// acknowledge, and released with a dead cycle so the request line is low
// long enough for the adapter's mask to clear. Each owner sees only the
// acknowledge of its own transaction. Every owner must hold its request until
// it is acknowledged; all five do.
//
// ROUND-ROBIN, NOT FIXED PRIORITY. The unit test with the coprocessor's slot
// asking on every cycle showed the push DMA and the loader never served at
// all under the mux's fixed order; the TGP's vertex loop writes buffer RAM
// continuously and would have starved the display-list DMA the same way.
// The grant starts its search one past the owner last served.

module m2_wr_arb #(
  parameter int unsigned N  = 5,
  parameter int unsigned AW = 25
)(
  input  logic              clk,
  input  logic              rst_n,

  input  logic [N-1:0]      req,
  input  logic [AW-1:0]     addr [N],
  input  logic [15:0]       din  [N],
  output logic [N-1:0]      ack,

  output logic              s_req,
  output logic [AW-1:0]     s_addr,
  output logic [15:0]       s_din,
  input  logic              s_ack
);

  localparam int unsigned OW = (N > 1) ? $clog2(N) : 1;

  logic          held;     // an owner holds the port
  logic [OW-1:0] own;
  logic          gap;      // the dead cycle after a release

  // The first requester after the one last served; the last assignment in
  // the loop (the smallest k) wins.
  logic [OW-1:0] last;
  logic          any;
  logic [OW-1:0] pick;
  always_comb begin
    any  = 1'b0;
    pick = '0;
    for (int k = N; k >= 1; k--) begin
      if (req[(int'(last) + k) % N]) begin any = 1'b1; pick = OW'((int'(last) + k) % N); end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      held <= 1'b0; own <= '0; gap <= 1'b0; last <= OW'(N - 1);
    end else if (held) begin
      // Released on the acknowledge, or if the owner withdrew (it must not,
      // but a withdrawn request must not wedge the port for everyone else).
      if (s_ack || !req[own]) begin held <= 1'b0; gap <= 1'b1; last <= own; end
    end else begin
      gap <= 1'b0;
      if (!gap && any) begin held <= 1'b1; own <= pick; end
    end
  end

  assign s_req  = held & req[own];
  assign s_addr = addr[own];
  assign s_din  = din[own];

  always_comb begin
    ack = '0;
    if (held && s_ack) ack[own] = 1'b1;
  end

endmodule
