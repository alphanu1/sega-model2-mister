// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE GEOMETRIZER'S FRONT DOOR: two pointers and a push path.
//
// This is NOT a processor, and believing otherwise cost two study entries
// (R124, R128; corrected by R130). `model2.cpp`:
//
//     void geo_prg_w(u32 data) {
//         if (m_geoctl & 0x80000000) { m_geocnt++; }   // upload: COUNTS, DISCARDS
//         else                       { push_geo_data(data); }
//     }
//     void push_geo_data(u32 d) { m_bufferram[m_geo_write_start_address/4] = d;
//                                 m_geo_write_start_address += 4; }
//
// The microcode upload is thrown away by the reference, which hardcodes the
// pipeline instead. So the 721,831 writes to 0x804000 over 900 attract frames
// are overwhelmingly the game STREAMING ITS DISPLAY LIST into buffer RAM
// through an auto-incrementing pointer. What this block owes the machine is
// therefore small: keep two pointers, and put pushed dwords where they belong.
//
// WHY THE POINTERS MATTER ON THEIR OWN. `geo_r` returns geo_write_start_address
// at 0x2008 and geo_read_start_address at 0x3008. This core returned 0 for both
// -- that region falls into the bridge's T_IO default -- so the game set a
// pointer, read back zero, and derived an address from it. That is the shape of
// the livelock in R129: the i960 walking an unmapped 0x0163FBxx once buffer RAM
// writes started landing.
//
// THE PUSH IS A DMA, NOT A BUS REMAP. Redirecting the CPU write inside
// m2_cpu_bridge would mean rewriting sd_word underneath its S_LO/S_HI walk,
// which splits a dword across two SDRAM words and selects the half from
// r_addr[1]. Instead the write is acknowledged as ordinary I/O and queued here,
// and this block drains the queue into the shared SDRAM write port -- the same
// one the ROM loader, the self-test and the buffer initialiser take turns on.
//
// AND IT NEVER STALLS THE i960. The queue is an M10K FIFO deep enough that
// `dbg_dropped` stays still: the game pushes about 800 dwords a frame, roughly
// 48,000/s, against a drain of millions. If that counter ever moves, the depth
// was wrong -- it is not a reason to add backpressure. Holding the i960 on a
// coprocessor froze this machine once already.

`timescale 1ns/1ps

module m2_geo #(
  parameter int unsigned AW    = 25,
  parameter int unsigned DEPTH = 128
) (
  input  logic          clk,
  input  logic          rst_n,

  // ---- the i960's side, decoded by the top level
  input  logic          wr_ctl,          // 0x00980008  geo_ctl1
  input  logic          wr_setwp,        // 0x00801008  set write pointer
  input  logic          wr_setrp,        // 0x00803008  set read pointer
  input  logic          wr_push,         // 0x00800000-0fff and 0x00804000-7fff
  input  logic [31:0]   wdata,

  output logic [31:0]   rd_wp,           // 0x00802008
  output logic [31:0]   rd_rp,           // 0x00803008

  // ---- where buffer RAM lives, and the shared SDRAM write port
  input  logic [AW:1]   base_buffer,
  output logic          sd_wr_req,
  output logic [AW:1]   sd_wr_addr,
  output logic [15:0]   sd_wr_din,
  input  logic          sd_wr_ack,
  output logic          sd_busy,         // hold the port while a dword is in flight

  output logic [31:0]   dbg_pushes,
  output logic [31:0]   dbg_dropped,
  output logic [15:0]   dbg_geocnt,
  output logic [31:0]   dbg_geoctl,

  // ---- the display-list walk (R135)
  input  logic          frame_start,     // one pulse at vblank
  output logic          rd_req,
  output logic [18:0]   rd_addr,         // dword index into bufferram
  input  logic [31:0]   rd_data,
  input  logic          rd_ack,

  // ---- GEOMETRY STATE, captured rather than skipped (R168)
  //
  // The walk used to step over every operand blind. These three opcodes carry
  // the state the transform needs, and model2_v.cpp reads them straight:
  //
  //   geo_matrix_write   12 words -> matrix[0..11]
  //   geo_focal_distance  2 words -> focus.x, focus.y
  //   geo_object_data     4 words -> tpa, tha, oba, obc
  //
  // Exposed so the bench can check them against a list it built, and because
  // the polygon fetch consumes oba/obc next.
  output logic [31:0]   mtx0, mtx4, mtx8, mtx11,  // corners of the 3x4, enough to prove order
  // THE MATRIX AS A STREAM, not as twelve wires. The capture below already
  // takes one operand per acknowledge in reference order, so the write enable,
  // the index and the word are simply that loop made visible. m2_geo_xform
  // wants exactly this shape (mat_we/mat_idx/mat_data), so nothing is
  // reformatted between here and there -- and a 384-wire bundle never exists.
  output logic          mat_we,
  output logic [3:0]    mat_idx,
  output logic [31:0]   mat_data,
  // THE INTERLOCK. The walk and the geometry engine read the SAME SDRAM port,
  // and two owners on one port is what cost this project four days (study
  // R167). Rather than arbitrate, they take turns: the walk stops at an
  // object_data until the engine has drained that object. It is what the
  // reference does anyway -- geo_object_data does not return until geo_parse
  // has walked every polygon -- so the serialisation is not a concession.
  input  logic          eng_busy,
  output logic [31:0]   foc_x, foc_y,
  output logic [31:0]   obj_tpa, obj_tha, obj_oba, obj_obc,
  output logic          obj_valid,       // one pulse when an object_data is complete
  output logic [15:0]   dbg_mtx_n,       // matrices captured
  output logic [15:0]   dbg_foc_n,       // focal writes captured

  output logic [15:0]   dbg_walk_ops,    // opcodes retired this frame
  output logic [15:0]   dbg_walk_objs,   // object_data commands seen
  output logic [15:0]   dbg_walk_frames, // walks completed
  output logic [7:0]    dbg_walk_unknown // an opcode the table does not cover
);

  // ---------------------------------------------------------------- registers
  logic [31:0] geoctl;
  logic [19:0] geo_wp, geo_rp;
  logic [15:0] geocnt;

  wire uploading = geoctl[31];

  assign rd_wp      = {12'd0, geo_wp};
  assign rd_rp      = {12'd0, geo_rp};
  assign dbg_geocnt = geocnt;
  assign dbg_geoctl = geoctl;

  // A push only queues when the reference would have queued it: in upload mode
  // the data is counted and discarded, exactly as geo_prg_w does.
  wire push_now = wr_push && !uploading;

  // THE DESTINATION TRAVELS WITH THE DWORD. The queue decouples the push from
  // the drain, so a drain-side counter would be wrong the moment the game sets
  // the write pointer with 0x801008 -- the queued words would land where the
  // pointer USED to be. 52 bits wide: {byte pointer, dword}.
  logic        q_valid;
  logic [51:0] q_data;
  logic        q_pop;
  logic [15:0] q_count;
  logic        q_full;

  m2_fifo_m10k #(.DW(52), .DEPTH(DEPTH)) u_pushq (
    .clk(clk), .rst_n(rst_n),
    .push(push_now), .din({geo_wp, wdata}),
    .pop(q_pop), .q(q_data), .q_valid(q_valid),
    .full(q_full), .count(q_count), .dropped(dbg_dropped)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      geoctl <= 32'd0; geo_wp <= 20'd0; geo_rp <= 20'd0;
      geocnt <= 16'd0; dbg_pushes <= 32'd0;
    end else begin
      // geo_ctl1_w: the hi bit CHANGING starts or ends an upload, and starting
      // one resets the count. The reference watches the transition, not the level.
      if (wr_ctl) begin
        if ((wdata ^ geoctl) == 32'h8000_0000 && wdata[31]) geocnt <= 16'd0;
        geoctl <= wdata;
      end
      if (wr_setwp) geo_wp <= wdata[19:0];
      if (wr_setrp) geo_rp <= wdata[19:0];

      // Upload mode counts and drops on the floor, as the reference does.
      if (wr_push && uploading && !(&geocnt)) geocnt <= geocnt + 16'd1;

      // The pointer advances when the dword is ACCEPTED, not when it lands --
      // the game reads it back to find where it is, and it is four ahead of the
      // last word it wrote. A drop must not advance it, or the list gains a hole
      // AND a wrong pointer.
      if (push_now && !q_full) begin
        geo_wp <= geo_wp + 20'd4;
        if (!(&dbg_pushes)) dbg_pushes <= dbg_pushes + 32'd1;
      end
    end
  end

  // ------------------------------------------------------ the drain, one dword
  // Two 16-bit writes, low half first: the bridge reads back the half selected
  // by r_addr[1], so an EVEN word index must hold bits 15:0.
  typedef enum logic [1:0] { D_IDLE, D_LO, D_HI, D_NEXT } dstate_t;
  dstate_t dst;
  logic [19:0] wr_ptr;
  logic [15:0] dw_hi;

  // Deliberately unread, and named so lint does not have to guess: the queue's
  // occupancy is covered by `dropped`, the walk only needs an opcode's top and
  // jump fields out of rd_data, and wr_ptr's high bits and bit 0 fall outside
  // bufferram's 128 KB.
  wire _unused_geo = &{1'b0, q_count, rd_data[30:28], rd_data[22:17],
                       wr_ptr[19:17], wr_ptr[0], 1'b0};

  assign sd_busy = (dst != D_IDLE);
  assign q_pop   = (dst == D_IDLE) && q_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dst <= D_IDLE; sd_wr_req <= 1'b0; sd_wr_addr <= '0; sd_wr_din <= 16'd0;
      wr_ptr <= 20'd0; dw_hi <= 16'd0;
    end else begin
      case (dst)
        D_IDLE: if (q_valid) begin
          wr_ptr     <= q_data[51:32];
          dw_hi      <= q_data[31:16];
          sd_wr_addr <= base_buffer + AW'(q_data[48:33]);   // (ptr & 0x1ffff) >> 1
          sd_wr_din  <= q_data[15:0];
          sd_wr_req  <= 1'b1;
          dst        <= D_LO;
        end
        D_LO: if (sd_wr_ack) begin
          sd_wr_req  <= 1'b0;
          sd_wr_addr <= base_buffer + AW'(wr_ptr[16:1]) + AW'(1);
          sd_wr_din  <= dw_hi;
          dst        <= D_HI;
        end
        D_HI: begin
          sd_wr_req <= 1'b1;
          dst       <= D_NEXT;
        end
        D_NEXT: if (sd_wr_ack) begin
          sd_wr_req <= 1'b0;
          dst       <= D_IDLE;
        end
        default: dst <= D_IDLE;
      endcase
    end
  end

  // ======================================================================
  // THE DISPLAY-LIST WALK
  //
  //     input = &bufferram[geo_read_start_address/4]
  //     op = *input++
  //     if (op & 0x80000000) input = &bufferram[(op & 0x1ffff)/4]   -- jump
  //     else consume the operand words this opcode takes
  //     bounded by 0x8000 opcodes and the end of bufferram
  //
  // EIGHT OPCODES, NOT TWENTY-ONE. Walking the real list dumped out of MAME
  // retires 101 commands and reaches `end` cleanly using only:
  //
  //     object_data 60   matrix_write 33   focal 2   light 2
  //     zsort 1          window_data 1     texture_data 1   end 1
  //
  // None of the six handlers whose length could not be confirmed appear at all.
  // The count for the variable ones is READ FROM THE STREAM as the second
  // operand, not decoded out of the opcode -- that was the open question.
  //
  // This walks and counts. It does not yet transform anything: object_data's
  // four words name geometry that lives in the POLYGON ROM, and that is the
  // next stage. Getting the walk right first means the opcode histogram on the
  // UART can be compared against the 101/60/33 above, which is a real oracle.
  typedef enum logic [3:0] { W_IDLE, W_FETCH, W_DECODE, W_SKIP, W_CNT,
                             W_TFIFO, W_DDSKIP, W_DDATTR, W_OPRD, W_OBJW } wstate_t;
  wstate_t wst;
  logic [18:0] w_ip;
  logic [15:0] w_ops, w_skip;
  logic [4:0]  w_op;

  // Operand words per opcode. The upper half mirrors the lower for the ones
  // this game uses, exactly as geo_process_command's switch does.
  // ALL THIRTY-TWO ENTRIES, NOT THE LOW NIBBLE. The upper half mirrors the
  // lower for most commands, but NOT for three pairs, and keying on four bits
  // gets every one of them wrong:
  //
  //     0x0d data_mem_push 2+count   vs  0x1d code_upload  1+3*count
  //     0x0e test          complex   vs  0x1e code_jump    1
  //     0x06 texture_params 2+2*cnt  vs  0x16 lod          1
  //
  // A count-driven command carries its length in the stream. `preop` is how many
  // operands come BEFORE the count word, `mult` how many words each unit takes:
  //
  //     2 + count      preop 1, mult 1   texture_data, polygon_data,
  //                                      data_mem_push, log_data
  //     2 + 2*count    preop 1, mult 2   texture_parameters
  //     1 + 3*count    preop 0, mult 3   code_upload
  //
  // 0x02/0x12 direct_data IS covered. Its length is set by a while loop rather
  // than a count, but a loop is not an unknown: geo_direct_data takes tpa and
  // tha, then two xyz points, then reads an attribute word and continues while
  // its low two bits are nonzero -- 5 more words per vertex, 8 if bit 0 says
  // quad rather than triangle. The terminating attribute is consumed too:
  // `while (((attr = *input++) & 3) != 0)` steps past it on the exit test.
  //
  // ALL THIRTY-TWO OPCODES NOW HAVE A LENGTH. geo_process_command has no
  // default case, so there is no such thing as an opcode the reference cannot
  // measure -- halting was a stopgap, not a limit of what is knowable. The
  // unknown branch below is kept as an assertion that should never fire.
  //
  // 0x0e test IS covered, and it is the reason the walk stopped on the board
  // after 141 frames (dbg_walk_unknown reported 0x0e, which is the opcode, not
  // a count). geo_test is the SELF TEST: it checks a 1,2,4,8... ramp through
  // the FIFO and then checksums blocks of polygon ROM. It writes nothing and
  // changes no geometrizer state -- on failure MAME only logerrors, and the
  // real board lights an LED. So the walk owes it nothing but the right length:
  //
  //     32 words   the FIFO ramp
  //    + 1 word    the block count
  //    + 3*blocks  address, count, checksum per block
  //
  // Note where the count sits: at operand offset 32, not offset 1 like every
  // other count-driven command, which is why it needs its own state rather
  // than another entry in the preop/mult table above.
  function automatic [15:0] oplen(input [4:0] c);
    case (c)
      5'h00, 5'h0f, 5'h1f:               oplen = 16'd0;   // nop, end
      5'h07, 5'h08, 5'h10, 5'h16,
      5'h17, 5'h18, 5'h1e:               oplen = 16'd1;   // mode, zsort, dummy,
                                                          // lod, code_jump
      5'h09, 5'h19:                      oplen = 16'd2;   // focal distance
      5'h0a, 5'h0c, 5'h1a, 5'h1c:        oplen = 16'd3;   // light, translate
      5'h01, 5'h11:                      oplen = 16'd4;   // object_data
      5'h03, 5'h13:                      oplen = 16'd6;   // window_data
      5'h0b, 5'h1b:                      oplen = 16'd12;  // matrix, 3x4
      // 0x02/0x12 direct_data and 0x0e test have their own states, never here.
      default:                           oplen = 16'hffff;
    endcase
  endfunction

  // count-driven forms
  wire is_cnt1 = (w_op == 5'h04) || (w_op == 5'h05) || (w_op == 5'h14)
              || (w_op == 5'h15) || (w_op == 5'h0d);       // 2 + count
  wire is_cnt2 = (w_op == 5'h06);                          // 2 + 2*count
  wire is_cnt3 = (w_op == 5'h1d);                          // 1 + 3*count
  wire is_test = (w_op == 5'h0e);                          // 32 + 1 + 3*blocks
  wire is_dd   = (w_op == 5'h02) || (w_op == 5'h12);       // 8 + attribute loop
  wire is_var  = is_cnt1 || is_cnt2 || is_cnt3;
  wire is_end  = (w_op == 5'h0f) || (w_op == 5'h1f);

  // The captured geometry state. `mtx` is the live matrix the transform will
  // use; only four of its words are brought out, which is enough to prove the
  // order is right without routing 384 wires to the top level.
  logic [31:0] mtx [12];
  logic [1:0]  w_cap;                    // which opcode's operands are being read
  logic [3:0]  w_ci;                     // operand index
  logic        eng_seen;                 // the engine's busy has been observed high
  localparam logic [1:0] CAP_MTX = 2'd1, CAP_FOC = 2'd2, CAP_OBJ = 2'd3;

  assign mtx0 = mtx[0]; assign mtx4 = mtx[4]; assign mtx8 = mtx[8]; assign mtx11 = mtx[11];

  assign mat_we   = (wst == W_OPRD) && rd_ack && (w_cap == CAP_MTX);
  assign mat_idx  = w_ci;
  assign mat_data = rd_data;

  wire is_mtx = (w_op == 5'h0b) || (w_op == 5'h1b);
  wire is_foc = (w_op == 5'h09) || (w_op == 5'h19);
  wire is_obj = (w_op == 5'h01) || (w_op == 5'h11);
  wire [3:0] cap_last = (w_cap == CAP_MTX) ? 4'd11
                      : (w_cap == CAP_FOC) ? 4'd1
                                           : 4'd3;

  assign rd_req  = (wst == W_FETCH) || (wst == W_CNT) || (wst == W_DDATTR)
                || (wst == W_OPRD);
  assign rd_addr = w_ip;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wst <= W_IDLE; w_ip <= 19'd0; w_ops <= 16'd0; w_skip <= 16'd0; w_op <= 5'd0;
      dbg_walk_ops <= 16'd0; dbg_walk_objs <= 16'd0;
      dbg_walk_frames <= 16'd0; dbg_walk_unknown <= 8'd0;
      w_cap <= 2'd0; w_ci <= 4'd0; obj_valid <= 1'b0; eng_seen <= 1'b0;
      dbg_mtx_n <= 16'd0; dbg_foc_n <= 16'd0;
      foc_x <= 32'd0; foc_y <= 32'd0;
      obj_tpa <= 32'd0; obj_tha <= 32'd0; obj_oba <= 32'd0; obj_obc <= 32'd0;
      for (int k = 0; k < 12; k++) mtx[k] <= 32'd0;
    end else begin
      obj_valid <= 1'b0;
      case (wst)
        W_IDLE: if (frame_start) begin
          // MASKED TO 0x1ffff FIRST, THEN /4 -- geo_parse is
          // `(m_geo_read_start_address & 0x1ffff)/4`, and the mask is not
          // decoration: the register holds 20 bits, so an unmasked [19:2] can
          // start the walk at up to 0x3FFFF, past the 0x8000-dword end of
          // bufferram, and the walk bounds out having retired ONE opcode with
          // no unknown to explain it. That is what the board reported --
          // ops=1, objs=0, frames frozen, unknown clear.
          w_ip  <= 19'(geo_rp[16:2]);       // the read pointer is a BYTE address
          w_ops <= 16'd0;
          wst   <= W_FETCH;
        end
        // FETCH AND WAIT ARE ONE STATE. Asserting the request and then moving on
        // unconditionally drops an acknowledge that arrives in the same cycle,
        // which a fast memory does -- the walk then never advances at all.
        W_FETCH: if (rd_ack) begin
          // THE BOUND LIVES HERE, NOT ONLY IN W_SKIP. A jump re-enters W_FETCH
          // without passing through W_SKIP, so a list of nothing but jumps was
          // unbounded -- and unwritten memory is exactly that list: it reads
          // 0xFFFFFFFF, bit 31 is set, so every word is a jump to the same
          // address and the walk never leaves this state. MAME cannot hit this
          // because it fills bufferram with 0x07800f0f (an `end`) at reset.
          if (w_ops >= 16'h7fff) begin
            dbg_walk_ops <= w_ops;
            wst <= W_IDLE;
          end else if (rd_data[31]) begin              // a jump
            w_ip <= 19'(rd_data[16:2]);
            wst  <= W_FETCH;
          end else begin
            w_op  <= rd_data[27:23];
            w_ip  <= w_ip + 19'd1;
            wst   <= W_DECODE;
          end
          w_ops <= w_ops + 16'd1;
        end
        W_DECODE: begin
          if (w_op[3:0] == 4'h1) dbg_walk_objs <= dbg_walk_objs + 16'd1;
          if (is_end) begin
            dbg_walk_ops    <= w_ops;
            dbg_walk_frames <= dbg_walk_frames + 16'd1;
            wst <= W_IDLE;
          end else if (is_dd) begin
            // tpa, tha and two xyz points, then the attribute loop.
            w_skip <= 16'd8;
            wst    <= W_DDSKIP;
          end else if (is_test) begin
            // Step the FIFO ramp first; W_CNT then lands on the block count.
            w_skip <= 16'd32;
            wst    <= W_TFIFO;
          end else if (is_var) begin
            // code_upload's count IS the first operand; the others have one
            // operand before it.
            if (!is_cnt3) w_ip <= w_ip + 19'd1;
            wst  <= W_CNT;
          end else if (is_mtx || is_foc || is_obj) begin
            // READ THESE OPERANDS RATHER THAN STEPPING OVER THEM. They carry
            // the transform's state -- the matrix, the projection, and the
            // object's address and count. Everything else stays a blind skip,
            // which is what kept the walk cheap while it was only counting.
            w_cap <= is_mtx ? CAP_MTX : is_foc ? CAP_FOC : CAP_OBJ;
            w_ci  <= 4'd0;
            wst   <= W_OPRD;
          end else if (oplen(w_op) == 16'hffff) begin
            dbg_walk_unknown <= {3'd0, w_op};   // stop rather than desynchronise
            dbg_walk_ops     <= w_ops;
            wst <= W_IDLE;
          end else begin
            w_skip <= oplen(w_op);
            wst    <= W_SKIP;
          end
        end
        // One operand per acknowledge, straight into its destination. The
        // reference reads each of these as a flat run of words in order
        // (geo_matrix_write, geo_focal_distance, geo_object_data), so there is
        // no reordering to get wrong here -- only the count.
        W_OPRD: if (rd_ack) begin
          case (w_cap)
            CAP_MTX: mtx[w_ci] <= rd_data;
            CAP_FOC: if (w_ci == 4'd0) foc_x <= rd_data; else foc_y <= rd_data;
            default: case (w_ci)
                       4'd0: obj_tpa <= rd_data;
                       4'd1: obj_tha <= rd_data;
                       4'd2: obj_oba <= rd_data;
                       default: obj_obc <= rd_data;
                     endcase
          endcase
          w_ip <= w_ip + 19'd1;
          if (w_ci == cap_last) begin
            if (w_cap == CAP_MTX) dbg_mtx_n <= dbg_mtx_n + 16'd1;
            if (w_cap == CAP_FOC) dbg_foc_n <= dbg_foc_n + 16'd1;
            // The object is announced only once its four words are in, and
            // the walk then STOPS until the engine reports the object drawn.
            if (w_cap == CAP_OBJ) begin
              obj_valid <= 1'b1;
              eng_seen  <= 1'b0;
              wst       <= W_OBJW;
            end else begin
              wst <= W_FETCH;
            end
          end else begin
            w_ci <= w_ci + 4'd1;
          end
        end
        // WAIT FOR THE ENGINE, IN TWO HALVES. busy rises the cycle AFTER
        // start, so "wait until !busy" would fall straight through on the
        // cycle obj_valid was raised and let the walk race ahead onto the
        // port. Watch busy go up first, then come back down.
        W_OBJW: begin
          if (!eng_seen) begin
            if (eng_busy) eng_seen <= 1'b1;
          end else if (!eng_busy) begin
            eng_seen <= 1'b0;
            wst      <= W_FETCH;
          end
        end

        W_CNT: if (rd_ack) begin
          // JUST THE COUNT. This state has already stepped past the count word
          // itself, so adding one for it walks a word too far -- which lands on
          // the operand AFTER the next command and desynchronises the whole
          // list. It read as 1093 opcodes against an expected 101.
          w_skip <= (is_cnt3 || is_test) ? (rd_data[15:0] * 16'd3)
                  :  is_cnt2              ? (rd_data[15:0] * 16'd2)
                                          :  rd_data[15:0];
          w_ip   <= w_ip + 19'd1;
          wst    <= W_SKIP;
        end
        // The FIFO ramp: 32 words stepped without reading them. The ramp's
        // CONTENTS are a hardware self-test the board has already passed by the
        // time we see it; only its length matters here.
        W_TFIFO: begin
          if (w_skip == 16'd0) wst <= W_CNT;
          else begin
            w_ip   <= w_ip + 19'd1;
            w_skip <= w_skip - 16'd1;
          end
          if (w_ip >= 19'h08000) begin
            dbg_walk_ops <= w_ops;
            wst <= W_IDLE;
          end
        end
        // direct_data's loop. W_DDSKIP always returns to W_DDATTR, so the
        // same pair serves both the fixed 8-word preamble and each vertex.
        W_DDSKIP: begin
          if (w_skip == 16'd0) wst <= W_DDATTR;
          else begin
            w_ip   <= w_ip + 19'd1;
            w_skip <= w_skip - 16'd1;
          end
          if (w_ip >= 19'h08000) begin
            dbg_walk_ops <= w_ops;
            wst <= W_IDLE;
          end
        end
        W_DDATTR: if (rd_ack) begin
          w_ip <= w_ip + 19'd1;               // the attribute is consumed either way
          if ((rd_data[1:0] == 2'b00) || (w_ip >= 19'h08000)) begin
            wst <= W_FETCH;                   // low two bits clear: list ends
          end else begin
            w_skip <= rd_data[0] ? 16'd8      // quad: luma, dist, xyz, xyz
                                 : 16'd5;     // tri:  luma, dist, xyz
            wst    <= W_DDSKIP;
          end
        end
        W_SKIP: begin
          if (w_skip == 16'd0) wst <= W_FETCH;
          else begin
            w_ip   <= w_ip + 19'd1;
            w_skip <= w_skip - 16'd1;
          end
          // the walk is bounded: bufferram is 0x8000 dwords, and a runaway list
          // must stop rather than read forever
          if (w_ip >= 19'h08000 || w_ops >= 16'h7fff) begin
            dbg_walk_ops <= w_ops;
            wst <= W_IDLE;
          end
        end
        default: wst <= W_IDLE;
      endcase
    end
  end

endmodule
