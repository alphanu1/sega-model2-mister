//============================================================================
// TWO Sega 315-5560 MultiPCMs (Yamaha YMW-258-F GEW8) ON ONE ENGINE (R821)
//
// m2_multipcm.sv's chip, time-multiplexed: one sequencer walks 56 voice slots
// -- chip 0 slot 0, chip 1 slot 0, chip 0 slot 1, ... -- in the time one chip
// walks 28, and one datapath (step, pitch, level, multiply) serves both. What
// each chip owns stays per chip: its register selection, its accumulators,
// its output, its fetch port. Everything per slot is a RAM indexed by
// {slot, chip}, or a 56-bit vector where it must be scanned or cleared.
//
// Derived from m2_multipcm.sv (itself meathax/s32 s32_multipcm.sv @ 7905361,
// GPL-3.0, changes in THIRD_PARTY.md). The arithmetic -- banked(),
// pitch_step(), step_pos(), att_side(), frac_gain(), clamp16() -- is that
// file's, verbatim. What is new is the schedule, listed here in full because
// each item is a place where the two can differ:
//
//  1. ONE PASS IS 56 SLOTS OF TICKS (4) ENABLES -- 224, as one chip's 28 x 8,
//     so the rate stage's enable and headroom are unchanged. Both chips emit
//     their sample on the same strobe at the end of the pass.
//  2. A FETCH DOES NOT FREEZE THE SEQUENCER. The single chip stops its tick
//     while any fetch is outstanding. Here a slot waits only if it would step
//     while ITS chip's previous fetch (or that sample's multiply) is still in
//     flight, so a fetch has the other chip's slot to complete in -- 8 enables
//     against the single chip's 0 before it costs time. The pass end waits for
//     everything in flight, as the single chip's wrap does.
//  3. LEVEL AND PAN ARE READ AT THE STEP, not at the acknowledge. The single
//     chip reads them at the acknowledge, a few cycles later; a register write
//     landing between the two is the only case that differs.
//  4. ONE DESCRIPTOR FETCH AT A TIME FOR BOTH CHIPS (lowest pending slot
//     first), each on its own chip's port; it freezes the sequencer, as the
//     single chip's does.
//  5. THE SAMPLE NUMBER (reg 1, reg 2 bit 0) IS AN MLAB read at the descriptor
//     pick (taken a cycle later), not 252 flip-flops a chip, and is NOT cleared by
//     reset (the standing rule): a key-on of a slot whose sample was never
//     written since power-up reads 0 in both; after a soft reset this one
//     reads the last value written.
//  6. THE SAMPLE FETCH IS ISSUED ONE EDGE AFTER THE STEP, from the step's
//     registered operands (pv_*), so the 56:1 pos_zero select, the 22-bit
//     add and the bank page are not on the end of the step's path -- the
//     path R738 had to retime in the single chip at 80 MHz. The bank page is
//     therefore the one in force an edge later.
//
// So the two designs compute the same sample from the same register state,
// and differ only in WHEN, relative to their own passes, a register write
// lands. Writes applied between passes give bit-identical outputs; that is
// what tb_m2_mpcm_dual proves. The single chip's own alignment already moves
// with memory latency (R91), so free-running the two are each one draw from
// the same distribution, not one design and an approximation of it.
//============================================================================

module m2_multipcm_dual #(
    parameter int unsigned TICKS = 4      // enables a slot; >= 4 (see the wrap)
) (
    input             clk,
    input             ce,
    input             rst,

    // One 68000 bus, two chip selects -- the board decodes them exclusively.
    input             cs0,
    input             cs1,
    input             we,
    input       [1:0] addr,
    input       [7:0] wdata,

    // Per chip fetch ports, each one request outstanding, as m2_multipcm's.
    output reg        rom_req0,
    output wire [4:0] rom_slot0,
    output reg [21:0] rom_addr0,
    input       [7:0] rom_data0,
    input             rom_ack0,
    output reg        rom_req1,
    output wire [4:0] rom_slot1,
    output reg [21:0] rom_addr1,
    input       [7:0] rom_data1,
    input             rom_ack1,

    input       [1:0] bank_sel0,
    input       [1:0] bank_sel1,

    output reg        sample_stb,         // both chips' samples, one strobe
    output reg signed [15:0] out0_l,
    output reg signed [15:0] out0_r,
    output reg signed [15:0] out1_l,
    output reg signed [15:0] out1_r
);

localparam [5:0] VLAST = 6'd55;           // {slot 27, chip 1}

// ------------------------------------------------------------ CPU interface
// Each chip keeps its own slot and register selection.
reg [4:0] cur_slot0, cur_slot1;
reg       cur_valid0, cur_valid1;
reg [2:0] cur_reg0, cur_reg1;
wire       wc      = cs1;                 // which chip a write names
wire       wcs     = cs0 | cs1;
wire [4:0] w_slot  = wc ? cur_slot1  : cur_slot0;
wire       w_valid = wc ? cur_valid1 : cur_valid0;
wire [2:0] w_reg   = wc ? cur_reg1   : cur_reg0;
wire [5:0] wv      = {w_slot, wc};        // the slot a data write lands in
wire       sreg_we = wcs && we && (addr == 2'd0) && w_valid;

// ------------------------------------------------------------ per-slot RAMs
// 64 deep, {slot, chip}; 56 used. One write port (the CPU, or the stepper /
// descriptor for pos / desc), one read port each, as the single chip's.
(* ramstyle = "MLAB" *) reg [3:0]  pan_ram  [0:63];   // reg 0[7:4]
(* ramstyle = "MLAB" *) reg [6:0]  lvl_ram  [0:63];   // reg 5[7:1]
(* ramstyle = "MLAB" *) reg [5:0]  pit_ram  [0:63];   // reg 2[7:2]
(* ramstyle = "MLAB" *) reg [7:0]  oct_ram  [0:63];   // reg 3
(* ramstyle = "MLAB" *) reg [7:0]  smp_lo   [0:63];   // reg 1, read at the pick
(* ramstyle = "MLAB" *) reg        smp_hi   [0:63];   // reg 2[0], read at the pick
(* ramstyle = "MLAB" *) reg [54:0] desc_ram [0:63];   // {end[16:0], loop[15:0], start[21:0]}
(* ramstyle = "MLAB" *) reg [37:0] pos_ram  [0:63];

reg [63:0] s_active, desc_pending, key_wait, pos_zero;

// ------------------------------------------------------------ sequencer
reg [5:0] v;                              // {slot, chip}
reg [2:0] tick;
wire       vc = v[0];
wire [5:0] v_next = (v == VLAST) ? 6'd0 : v + 6'd1;
// The word for the slot about to step is on the RAM outputs by tick 0: the
// read address moves to the next slot for the last tick of this one, and
// stays on it from tick 0 until it moves again.
wire [5:0] st_rd_addr = (tick == 3'(TICKS - 1)) ? v_next : v;

reg [3:0]  pan_rd, pan_fwd_d;
reg [6:0]  lvl_rd, lvl_fwd_d;
reg [5:0]  pit_rd, pit_fwd_d;
reg [7:0]  oct_rd, oct_fwd_d;
reg        pan_fwd, lvl_fwd, pit_fwd, oct_fwd;
wire [3:0] pan_cur = pan_fwd ? pan_fwd_d : pan_rd;
wire [6:0] lvl_cur = lvl_fwd ? lvl_fwd_d : lvl_rd;
wire [5:0] pit_cur = pit_fwd ? pit_fwd_d : pit_rd;
wire [7:0] oct_cur = oct_fwd ? oct_fwd_d : oct_rd;

reg [54:0] desc_rd;
reg [37:0] pos_rd;
reg        desc_fwd;
reg [54:0] desc_fwd_d;
wire [54:0] desc_cur    = desc_fwd ? desc_fwd_d : desc_rd;
wire [37:0] s_pos_cur   = pos_zero[v] ? 38'd0 : pos_rd;
wire [21:0] s_start_cur = desc_cur[21:0];
wire [15:0] s_loop_cur  = desc_cur[37:22];
wire [16:0] s_end_cur   = desc_cur[54:38];

// ------------------------------------------------------------ descriptor
reg        df_busy;
reg  [5:0] df_v;
reg  [5:0] picked;
reg  [8:0] df_sample;
reg  [3:0] df_idx;
reg  [7:0] df_buf [0:7];                  // bytes 0..7; 7..11 are never read
wire [54:0] desc_word = {17'h10000 - {1'b0, df_buf[5], df_buf[6]},
                         {df_buf[3], df_buf[4]},
                         {df_buf[0][5:0], df_buf[1], df_buf[2]}};
reg        rom_is_desc0, rom_is_desc1;
reg  [4:0] play_slot0, play_slot1;
assign rom_slot0 = rom_is_desc0 ? df_v[5:1] : play_slot0;
assign rom_slot1 = rom_is_desc1 ? df_v[5:1] : play_slot1;

// The pick: lowest pending {slot, chip}, and its sample number read through
// the MLAB's asynchronous port in the same cycle -- as the single chip read
// `sreg[picked]`.
always @* begin
    picked = 6'd0;
    for (int i = 55; i >= 0; i = i - 1)
        if (desc_pending[i]) picked = 6'(i);
end
// Read registered, every cycle, at the pick's address: on the edge after a
// pick it holds the sample number as it was ON the pick's edge -- what the
// single chip's `sreg[picked]` gave -- and df_sample takes it then (df_ld).
// An asynchronous read here is not inferred as an MLAB (Quartus 17:
// "unsupported read-during-write behavior") and costs 504 registers.
reg  [8:0] smp_rd;
reg        df_ld;

// ------------------------------------------------------------ the step
reg        pv_we;
reg  [5:0] pv_v;
reg [37:0] pv_pos;
reg [24:0] pv_step;
reg [16:0] pv_end;
reg [15:0] pv_loop;
reg [21:0] pv_start;

// Each chip's gains, taken at its step (item 3), and its fetched byte.
reg  [8:0] g_l0, g_r0, g_l1, g_r1;
reg  [3:0] g_sl0, g_sr0, g_sl1, g_sr1;
reg        ac_v0, ac_v1;
reg  [7:0] ac_b0, ac_b1;

// One multiply for both (R819's, DSP): chip 0's sample first if both wait.
wire       m_sel  = !ac_v0;
wire [7:0] m_byte = m_sel ? ac_b1 : ac_b0;
wire [8:0] m_gl   = m_sel ? g_l1  : g_l0;
wire [8:0] m_gr   = m_sel ? g_r1  : g_r0;
(* multstyle = "dsp" *) wire signed [17:0] mul_l = $signed(m_byte) * $signed({1'b0, m_gl});
(* multstyle = "dsp" *) wire signed [17:0] mul_r = $signed(m_byte) * $signed({1'b0, m_gr});
reg        pm_v, pm_c;
reg signed [17:0] pm_l, pm_r;
reg  [3:0] pm_sl, pm_sr;
reg signed [21:0] acc0_l, acc0_r, acc1_l, acc1_r;

// ------------------------------------------------------------ arithmetic
// banked(), pitch_step(), step_pos(), att_side(), mute_side(), frac_gain(),
// clamp16(): m2_multipcm.sv's, verbatim (banked takes the page as an argument).
function automatic [21:0] banked(input [21:0] a, input [1:0] bank_sel);
    if (a < 22'h100000) banked = a;
    else                banked = {bank_sel, a[19:0]};
endfunction

function automatic [24:0] pitch_step(input [3:0] oct_bits, input [9:0] pitch);
    reg signed [4:0] oct;
    reg [24:0] base;
begin
    oct = oct_bits[3] ? $signed({1'b1, oct_bits}) : $signed({1'b0, oct_bits});
    base = {8'b0, 1'b1, pitch, 6'b0};
    if (oct >= 1) pitch_step = base << (oct - 1);
    else          pitch_step = base >> (1 - oct);
end
endfunction

function automatic [37:0] step_pos(input [37:0] pos, input [24:0] step,
                                   input [16:0] s_end, input [15:0] s_loop);
    reg [37:0] next_pos;
    reg [33:0] loop_span;
begin
    next_pos = pos + {13'd0, step};
    loop_span = ({17'd0, s_end} - {18'd0, s_loop}) << 16;
    if (next_pos >= ({21'd0, s_end} << 16) && loop_span != 0)
        next_pos = next_pos - {4'd0, loop_span};
    step_pos = next_pos;
end
endfunction

function automatic [7:0] att_side(input [6:0] tl, input [3:0] pan, input is_left);
    reg [2:0] p;
begin
    if (is_left) p = (pan[3] || pan == 4'h0) ? 3'd0 : pan[2:0];        // 1..7
    else         p = (!pan[3] || pan == 4'h8) ? 3'd0 : 3'd0 - pan[2:0]; // 16-pan
    att_side = {1'b0, tl} + {2'b00, p, 3'b000};
end
endfunction

function automatic mute_side(input [3:0] pan, input is_left);
    mute_side = (pan == 4'h8) || (is_left ? (pan == 4'h7) : (pan == 4'h9));
endfunction

function automatic [8:0] frac_gain(input [3:0] k);
begin
    case (k)
        4'd0:  frac_gain = 9'd256;  4'd1:  frac_gain = 9'd245;
        4'd2:  frac_gain = 9'd235;  4'd3:  frac_gain = 9'd225;
        4'd4:  frac_gain = 9'd215;  4'd5:  frac_gain = 9'd206;
        4'd6:  frac_gain = 9'd198;  4'd7:  frac_gain = 9'd189;
        4'd8:  frac_gain = 9'd181;  4'd9:  frac_gain = 9'd174;
        4'd10: frac_gain = 9'd166;  4'd11: frac_gain = 9'd159;
        4'd12: frac_gain = 9'd152;  4'd13: frac_gain = 9'd146;
        4'd14: frac_gain = 9'd140;  default: frac_gain = 9'd134;
    endcase
end
endfunction

function automatic signed [15:0] clamp16(input signed [21:0] value);
begin
    if (value > 22'sd32767)       clamp16 = 16'sh7fff;
    else if (value < -22'sd32768) clamp16 = -16'sh8000;
    else                          clamp16 = value[15:0];
end
endfunction

wire [7:0] att_l = att_side(lvl_cur, pan_cur, 1'b1);
wire [7:0] att_r = att_side(lvl_cur, pan_cur, 1'b0);
wire [8:0] gain_l = mute_side(pan_cur, 1'b1) ? 9'd0 : frac_gain(att_l[3:0]);
wire [8:0] gain_r = mute_side(pan_cur, 1'b0) ? 9'd0 : frac_gain(att_r[3:0]);

// Hold the sequencer: a slot that would step while its chip's last sample is
// still being fetched or multiplied (item 2) -- the gains it would overwrite
// are that sample's -- and the pass end until nothing is in flight, so the
// accumulators are complete when they are read.
wire chip_busy  = vc ? (rom_req1 || ac_v1 || (pv_we &&  pv_v[0]))
                     : (rom_req0 || ac_v0 || (pv_we && !pv_v[0]));
wire pipe_busy  = pv_we || rom_req0 || rom_req1 || ac_v0 || ac_v1 || pm_v;
wire step_now   = (tick == 3'd0) && s_active[v];
wire seq_hold   = (step_now && chip_busy) ||
                  ((v == VLAST) && (tick == 3'(TICKS - 1)) && pipe_busy);

// ------------------------------------------------------------ RAM ports
always @(posedge clk) begin
    if (pv_we) pos_ram[pv_v] <= step_pos(pv_pos, pv_step, pv_end, pv_loop);
    desc_rd <= desc_ram[st_rd_addr];
    pos_rd  <= pos_ram[st_rd_addr];
    pan_rd  <= pan_ram[st_rd_addr];
    lvl_rd  <= lvl_ram[st_rd_addr];
    pit_rd  <= pit_ram[st_rd_addr];
    oct_rd  <= oct_ram[st_rd_addr];
    smp_rd  <= {smp_hi[picked], smp_lo[picked]};
    pan_fwd <= sreg_we && (w_reg == 3'd0) && (wv == st_rd_addr);
    lvl_fwd <= sreg_we && (w_reg == 3'd5) && (wv == st_rd_addr);
    pit_fwd <= sreg_we && (w_reg == 3'd2) && (wv == st_rd_addr);
    oct_fwd <= sreg_we && (w_reg == 3'd3) && (wv == st_rd_addr);
    pan_fwd_d <= wdata[7:4];
    lvl_fwd_d <= wdata[7:1];
    pit_fwd_d <= wdata[7:2];
    oct_fwd_d <= wdata;
    if (sreg_we) case (w_reg)
        3'd0: pan_ram[wv] <= wdata[7:4];
        3'd1: smp_lo[wv]  <= wdata;
        3'd2: begin pit_ram[wv] <= wdata[7:2]; smp_hi[wv] <= wdata[0]; end
        3'd3: oct_ram[wv] <= wdata;
        3'd5: lvl_ram[wv] <= wdata[7:1];
        default: ;
    endcase
end

// ------------------------------------------------------------ control
always @(posedge clk) begin
    if (rst) begin
        cur_slot0 <= 0; cur_slot1 <= 0;
        cur_valid0 <= 1'b1; cur_valid1 <= 1'b1;
        cur_reg0 <= 0; cur_reg1 <= 0;
        rom_req0 <= 0; rom_req1 <= 0;
        rom_addr0 <= 0; rom_addr1 <= 0;
        rom_is_desc0 <= 0; rom_is_desc1 <= 0;
        play_slot0 <= 0; play_slot1 <= 0;
        sample_stb <= 1'b0;
        s_active <= 0; desc_pending <= 0; key_wait <= 0; pos_zero <= 0;
        desc_fwd <= 1'b0;
        df_busy <= 1'b0; df_ld <= 1'b0; df_v <= 0; df_sample <= 0; df_idx <= 0;
        tick <= 0; v <= 0;
        pv_we <= 1'b0;
        ac_v0 <= 1'b0; ac_v1 <= 1'b0; pm_v <= 1'b0;
        acc0_l <= 0; acc0_r <= 0; acc1_l <= 0; acc1_r <= 0;
        out0_l <= 0; out0_r <= 0; out1_l <= 0; out1_r <= 0;
        for (int i = 0; i < 8; i = i + 1) df_buf[i] <= 0;
    end
    else begin
        desc_fwd <= 1'b0;
        pv_we    <= 1'b0;

        // ---- the sample fetch, issued from the step's registered operands
        // one edge after the step (as R738 moved the position write): the
        // pos_zero select, the 22-bit add and the bank page are then one
        // cycle of their own, not the tail of the step's.
        if (pv_we) begin
            // R848: THE FIRST-STEP FLAG CLEARS HERE, A CYCLE AFTER THE STEP
            // THAT READ IT, from the step's own registered slot. Cleared in
            // the step itself it sat behind v -> s_active[v] -> step_now ->
            // seq_hold -> the step's enable -> a 64-way decode of v (s1134:
            // v -> pos_zero -0.418). Nothing reads pos_zero[pv_v] in between
            // -- the slot's next step is a pass away -- and a descriptor that
            // sets it in this same cycle (below, later) still wins, as it did
            // when the clear came a cycle earlier. (A step and a set of the
            // same slot in ONE cycle cannot happen: the set needs key_wait,
            // and key_wait is never set while the slot is active.)
            pos_zero[pv_v] <= 1'b0;
            if (pv_v[0]) begin
                rom_req1 <= 1'b1; rom_is_desc1 <= 1'b0;
                rom_addr1 <= banked(pv_start + pv_pos[37:16], bank_sel1);
            end else begin
                rom_req0 <= 1'b1; rom_is_desc0 <= 1'b0;
                rom_addr0 <= banked(pv_start + pv_pos[37:16], bank_sel0);
            end
        end

        // ---- register writes (any cycle, as the single chip's)
        if (wcs && we) begin
            case (addr)
                2'd1: begin
                    if (wc) begin
                        cur_valid1 <= (wdata[2:0] != 3'd7);
                        if (wdata[2:0] != 3'd7) cur_slot1 <= wdata[4:0] - {3'b000, wdata[4:3]};
                    end else begin
                        cur_valid0 <= (wdata[2:0] != 3'd7);
                        if (wdata[2:0] != 3'd7) cur_slot0 <= wdata[4:0] - {3'b000, wdata[4:3]};
                    end
                end
                2'd2: if (wc) cur_reg1 <= (wdata > 8'd7) ? 3'd7 : wdata[2:0];
                      else    cur_reg0 <= (wdata > 8'd7) ? 3'd7 : wdata[2:0];
                2'd0: if (w_valid) begin
                    if (w_reg == 3'd1) begin
                        desc_pending[wv] <= 1'b1;
                        if (s_active[wv]) begin
                            s_active[wv] <= 1'b0;
                            key_wait[wv] <= 1'b1;
                        end
                    end
                    if (w_reg == 3'd4) begin
                        if (wdata[7]) begin
                            s_active[wv] <= 1'b0;
                            key_wait[wv] <= 1'b1;
                            desc_pending[wv] <= 1'b1;
                        end
                        else begin
                            s_active[wv] <= 1'b0;
                            key_wait[wv] <= 1'b0;
                        end
                    end
                end
                default: ;
            endcase
        end

        // ---- the multiply, then the add (R819's two stages, shared)
        pm_v <= 1'b0;
        if (ac_v0 || ac_v1) begin
            pm_v  <= 1'b1;
            pm_c  <= m_sel;
            pm_l  <= mul_l;
            pm_r  <= mul_r;
            pm_sl <= m_sel ? g_sl1 : g_sl0;
            pm_sr <= m_sel ? g_sr1 : g_sr0;
            if (m_sel) ac_v1 <= 1'b0; else ac_v0 <= 1'b0;
        end
        if (pm_v) begin
            reg signed [17:0] vl, vr;
            vl = pm_l >>> pm_sl;
            vr = pm_r >>> pm_sr;
            if (pm_c) begin
                acc1_l <= acc1_l + {{4{vl[17]}}, vl};
                acc1_r <= acc1_r + {{4{vr[17]}}, vr};
            end else begin
                acc0_l <= acc0_l + {{4{vl[17]}}, vl};
                acc0_r <= acc0_r + {{4{vr[17]}}, vr};
            end
        end

        // ---- acknowledgements, every clk, per port
        if (rom_req0 && rom_ack0) begin
            rom_req0 <= 1'b0;
            if (!rom_is_desc0) begin ac_v0 <= 1'b1; ac_b0 <= rom_data0; end
        end
        if (rom_req1 && rom_ack1) begin
            rom_req1 <= 1'b0;
            if (!rom_is_desc1) begin ac_v1 <= 1'b1; ac_b1 <= rom_data1; end
        end
        // A descriptor byte: only df_v's chip carries one, so one at a time.
        if ((rom_req0 && rom_ack0 && rom_is_desc0) || (rom_req1 && rom_ack1 && rom_is_desc1)) begin
            reg [7:0] db;
            db = df_v[0] ? rom_data1 : rom_data0;    // rom_is_desc stays set after
            if (!df_idx[3]) df_buf[df_idx[2:0]] <= db;
            if (df_idx == 4'd11) begin
                df_busy <= 1'b0;
                desc_ram[df_v] <= desc_word;
                desc_fwd   <= (df_v == st_rd_addr);
                desc_fwd_d <= desc_word;
                if (key_wait[df_v]) begin
                    s_active[df_v] <= 1'b1;
                    pos_zero[df_v] <= 1'b1;
                    key_wait[df_v] <= 1'b0;
                end
            end
            else df_idx <= df_idx + 1'b1;
        end

        // ---- the enable: descriptor work first, then the slots
        sample_stb <= 1'b0;
        if (df_ld) begin
            df_sample <= smp_rd;
            df_ld     <= 1'b0;
        end
        if (ce) begin
            if (!df_busy && desc_pending != 0) begin
                df_v      <= picked;
                df_ld     <= 1'b1;
                df_idx    <= 0;
                df_busy   <= 1'b1;
                desc_pending[picked] <= 1'b0;
            end
            else if (df_busy) begin
                if (!df_ld && (df_v[0] ? !rom_req1 : !rom_req0)) begin
                    if (df_v[0]) begin
                        rom_req1 <= 1'b1; rom_is_desc1 <= 1'b1;
                        rom_addr1 <= (df_sample * 22'd12) + {18'd0, df_idx};
                    end else begin
                        rom_req0 <= 1'b1; rom_is_desc0 <= 1'b1;
                        rom_addr0 <= (df_sample * 22'd12) + {18'd0, df_idx};
                    end
                end
            end
            else if (!seq_hold) begin
                tick <= tick + 1'b1;
                if (tick == 3'(TICKS - 1)) begin
                    tick <= 0;
                    v    <= v_next;
                    if (v == VLAST) begin
                        sample_stb <= 1'b1;
                        out0_l <= clamp16(acc0_l >>> 2);
                        out0_r <= clamp16(acc0_r >>> 2);
                        out1_l <= clamp16(acc1_l >>> 2);
                        out1_r <= clamp16(acc1_r >>> 2);
                        acc0_l <= 0; acc0_r <= 0; acc1_l <= 0; acc1_r <= 0;
                    end
                end

                if (step_now) begin
                    pv_we   <= 1'b1;
                    pv_v    <= v;
                    pv_pos  <= s_pos_cur;
                    pv_step <= pitch_step(oct_cur[7:4], {oct_cur[3:0], pit_cur});
                    pv_end  <= s_end_cur;
                    pv_loop <= s_loop_cur;
                    pv_start <= s_start_cur;
                    if (vc) begin
                        play_slot1 <= v[5:1];
                        g_l1 <= gain_l; g_r1 <= gain_r;
                        g_sl1 <= att_l[7:4]; g_sr1 <= att_r[7:4];
                    end else begin
                        play_slot0 <= v[5:1];
                        g_l0 <= gain_l; g_r0 <= gain_r;
                        g_sl0 <= att_l[7:4]; g_sr0 <= att_r[7:4];
                    end
                end
            end
        end
    end
end

endmodule
