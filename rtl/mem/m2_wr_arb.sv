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
// acknowledge of its own transaction.
//
// A PULSED REQUEST IS REMEMBERED. Four owners hold their request until it is
// acknowledged; the ROM loader PULSES its for one cycle and waits (its note:
// "req pulsed so the controller sees a rising edge"). The first version
// granted on the pulse, found the request gone the next cycle, released
// without issuing the write, and the loader waited forever -- the ROM load
// hung on the board and ioctl_wait held the HPS with it. So a request is
// latched per owner until that owner's acknowledge, the port is held from
// grant to acknowledge whatever the owner's line does meanwhile, and the
// owner's address and data are what it presents at the time of the write,
// which every owner holds stable while it waits.
//
// AND A SERVED OWNER IS NOT GRANTED AGAIN UNTIL ITS LINE HAS FALLEN. The
// coprocessor's request and acknowledge are each registered once in
// Model2.sv, so its line stays up for three cycles after the acknowledge;
// the version with only the latch above re-granted that stale level after
// the dead cycle, wrote the low half twice, and the TGP took the duplicate's
// acknowledge as its high half's -- the mailbox clear never landed and the
// board froze on its first job (build/wrarb2 s15, TGP at 0x4C9). Four-phase,
// then: request up, acknowledge, request down, and only then a new grant.
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
  logic [N-1:0]  pend;     // a request seen and not yet acknowledged
  logic [N-1:0]  served;   // acknowledged, and the line has not fallen since
  wire  [N-1:0]  want = (req & ~served) | pend;

  // The first requester after the one last served; the last assignment in
  // the loop (the smallest k) wins.
  logic [OW-1:0] last;
  logic          any;
  logic [OW-1:0] pick;
  always_comb begin
    any  = 1'b0;
    pick = '0;
    for (int k = N; k >= 1; k--) begin
      if (want[(int'(last) + k) % N]) begin any = 1'b1; pick = OW'((int'(last) + k) % N); end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend <= '0; served <= '0;
    end else begin
      for (int i = 0; i < N; i++) begin
        if (ack[i]) begin
          pend[i] <= 1'b0; served[i] <= 1'b1;
        end else begin
          if (!req[i])                served[i] <= 1'b0;
          if (req[i] && !served[i])   pend[i]   <= 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      held <= 1'b0; own <= '0; gap <= 1'b0; last <= OW'(N - 1);
    end else if (held) begin
      // Released on the acknowledge only: the write is in flight from the
      // moment the port is held, and its acknowledge must reach its owner.
      if (s_ack) begin held <= 1'b0; gap <= 1'b1; last <= own; end
    end else begin
      gap <= 1'b0;
      if (!gap && any) begin held <= 1'b1; own <= pick; end
    end
  end

  assign s_req  = held;
  assign s_addr = addr[own];
  assign s_din  = din[own];

  always_comb begin
    ack = '0;
    if (held && s_ack) ack[own] = 1'b1;
  end

endmodule
