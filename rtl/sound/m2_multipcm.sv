//============================================================================
// Sega 315-5560 MultiPCM (Yamaha YMW-258-F GEW8)
//
// Register, descriptor, pitch and PCM semantics follow MAME multipcm.cpp and
// gew.cpp.  Envelope curves, interpolation and LFO modulation remain bounded
// approximations; the sample-selection/playback path is cycle deterministic.
//============================================================================

module m2_multipcm (
    input             clk,
    input             ce,
    input             rst,

    input             cs,
    input             we,
    input       [1:0] addr,
    input       [7:0] wdata,
    output      [7:0] rdata,

    output reg        rom_req,
    output reg [21:0] rom_addr,
    input       [7:0] rom_data,
    input             rom_ack,

    input       [2:0] bank_lo,
    input       [2:0] bank_hi,

    output reg signed [15:0] out_l,
    output reg signed [15:0] out_r
);

assign rdata = 8'h00;

reg [7:0] sreg [0:27][0:7];
reg [4:0] cur_slot;
reg       cur_slot_valid;
reg [2:0] cur_reg;

reg [21:0] s_start [0:27];
reg [15:0] s_loop  [0:27];
reg [16:0] s_end   [0:27];
reg        s_fmt12 [0:27];
reg        s_active[0:27];
reg [37:0] s_pos   [0:27];
reg  [3:0] s_release [0:27];

// Descriptor work is queued by sample writes and key-on.  key_wait records
// that completion must start/retrigger the voice.
reg [27:0] desc_pending;
reg [27:0] key_wait;
reg [4:0]  df_slot;
reg [8:0]  df_sample;
reg [3:0]  df_idx;
reg        df_busy;
reg [7:0]  df_buf [0:11];

reg [2:0] tick;
reg [4:0] slot;
reg [4:0] play_slot;
reg       rom_is_desc;
reg signed [21:0] acc_l, acc_r;

integer ri;
integer rj;

function automatic [21:0] banked(input [21:0] a);
begin
    if (a < 22'h100000)      banked = a;
    else if (a < 22'h180000) banked = {bank_lo, a[18:0]};
    else                     banked = {bank_hi, a[18:0]};
end
endfunction

// MAME update_step: base=(1+pitch/1024), exponent=(signed octave-1).
// This RTL position uses sixteen fractional bits instead of MAME's TL_SHIFT.
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

function automatic signed [15:0] pan_sample(
    input signed [15:0] sample,
    input [3:0] pan,
    input is_left
);
    reg [3:0] distance;
begin
    if (pan == 4'h8) begin
        pan_sample = 16'sd0;
    end
    else if (pan == 4'h0) begin
        pan_sample = sample;
    end
    else if (!pan[3]) begin
        // 1..7 attenuate left; 7 is hard-left mute.
        if (!is_left) pan_sample = sample;
        else if (pan == 4'h7) pan_sample = 16'sd0;
        else pan_sample = sample >>> ((pan + 1'b1) >> 1);
    end
    else begin
        // 9..15 attenuate right using MAME's inverted distance.
        distance = 4'd0 - pan;
        if (is_left) pan_sample = sample;
        else if (distance == 4'h7) pan_sample = 16'sd0;
        else pan_sample = sample >>> ((distance + 1'b1) >> 1);
    end
end
endfunction

function automatic signed [15:0] clamp16(input signed [21:0] value);
begin
    if (value > 22'sd32767)       clamp16 = 16'sh7fff;
    else if (value < -22'sd32768) clamp16 = -16'sh8000;
    else                          clamp16 = value[15:0];
end
endfunction

always @(posedge clk) begin
    if (rst) begin
        cur_slot <= 0;
        cur_slot_valid <= 1'b1;
        cur_reg <= 0;
        rom_req <= 0;
        rom_addr <= 0;
        rom_is_desc <= 0;
        desc_pending <= 0;
        key_wait <= 0;
        df_slot <= 0;
        df_sample <= 0;
        df_idx <= 0;
        df_busy <= 0;
        tick <= 0;
        slot <= 0;
        play_slot <= 0;
        acc_l <= 0;
        acc_r <= 0;
        out_l <= 0;
        out_r <= 0;
        for (ri = 0; ri < 28; ri = ri + 1) begin
            s_start[ri] <= 0;
            s_loop[ri] <= 0;
            s_end[ri] <= 0;
            s_fmt12[ri] <= 0;
            s_active[ri] <= 0;
            s_pos[ri] <= 0;
            s_release[ri] <= 4'hf;
            for (rj = 0; rj < 8; rj = rj + 1)
                sreg[ri][rj] <= 0;
        end
        for (ri = 0; ri < 12; ri = ri + 1)
            df_buf[ri] <= 0;
    end
    else begin
        // Register writes are on the Z80 clock domain represented by clk and
        // must not be dropped merely because the audio sample CE is low.
        if (cs && we) begin
            case (addr)
                2'd1: begin
                    // VALUE_TO_CHANNEL: every eighth selector is a hole.
                    cur_slot_valid <= (wdata[2:0] != 3'd7);
                    if (wdata[2:0] != 3'd7)
                        cur_slot <= wdata[4:0] - {3'b000, wdata[4:3]};
                end
                2'd2: cur_reg <= (wdata > 8'd7) ? 3'd7 : wdata[2:0];
                2'd0: if (cur_slot_valid) begin
                    sreg[cur_slot][cur_reg] <= wdata;
                    if (cur_reg == 3'd1) begin
                        // Sample index is nine bits; bit 8 lives in pitch reg2.
                        desc_pending[cur_slot] <= 1'b1;
                        if (s_active[cur_slot]) begin
                            s_active[cur_slot] <= 1'b0;
                            key_wait[cur_slot] <= 1'b1;
                        end
                    end
                    if (cur_reg == 3'd4) begin
                        if (wdata[7]) begin
                            // Fetch current metadata before starting so no
                            // uninitialized start/end state can be sampled.
                            s_active[cur_slot] <= 1'b0;
                            key_wait[cur_slot] <= 1'b1;
                            desc_pending[cur_slot] <= 1'b1;
                        end
                        else begin
                            // Release curves are not yet modeled. Immediate
                            // stop is exact for release=F and bounded otherwise.
                            s_active[cur_slot] <= 1'b0;
                            key_wait[cur_slot] <= 1'b0;
                        end
                    end
                end
                default: ;
            endcase
        end

        // ROM acknowledgements are sampled every clk, not only on ce.  The
        // SDRAM/cache response is a clk-domain pulse and may fall between CEs.
        if (rom_req && rom_ack) begin
            rom_req <= 1'b0;
            if (rom_is_desc) begin
                df_buf[df_idx] <= rom_data;
                if (df_idx == 4'd11) begin
                    df_busy <= 1'b0;
                    s_start[df_slot] <= {df_buf[0][5:0], df_buf[1], df_buf[2]};
                    s_fmt12[df_slot] <= df_buf[0][6];
                    s_loop[df_slot] <= {df_buf[3], df_buf[4]};
                    s_end[df_slot] <= 17'h10000 - {1'b0, df_buf[5], df_buf[6]};
                    s_release[df_slot] <= df_buf[10][3:0];
                    // Hardware copies descriptor defaults into LFO registers.
                    sreg[df_slot][6] <= df_buf[7];
                    sreg[df_slot][7] <= {4'b0000, rom_data[3:0]};
                    if (key_wait[df_slot]) begin
                        s_active[df_slot] <= 1'b1;
                        s_pos[df_slot] <= 0;
                        key_wait[df_slot] <= 1'b0;
                    end
                end
                else begin
                    df_idx <= df_idx + 1'b1;
                end
            end
            else begin
                reg signed [15:0] sample;
                reg signed [15:0] attenuated;
                reg signed [15:0] panned_l;
                reg signed [15:0] panned_r;
                reg [6:0] tl;
                // MultiPCM 8-bit samples are signed two's-complement, not
                // unsigned/offset-binary.  Byte 80h therefore means -32768.
                sample = {rom_data, 8'h00};
                tl = sreg[play_slot][5][7:1];
                attenuated = sample >>> (tl >> 4);
                panned_l = pan_sample(attenuated, sreg[play_slot][0][7:4], 1'b1);
                panned_r = pan_sample(attenuated, sreg[play_slot][0][7:4], 1'b0);
                acc_l <= acc_l + {{6{panned_l[15]}}, panned_l};
                acc_r <= acc_r + {{6{panned_r[15]}}, panned_r};
            end
        end

        if (ce) begin
            if (!df_busy && desc_pending != 0) begin
                reg found;
                reg [4:0] picked;
                found = 1'b0;
                picked = 0;
                for (ri = 0; ri < 28; ri = ri + 1) begin
                    if (desc_pending[ri] && !found) begin
                        found = 1'b1;
                        picked = ri[4:0];
                    end
                end
                df_slot <= picked;
                df_sample <= {sreg[picked][2][0], sreg[picked][1]};
                df_idx <= 0;
                df_busy <= 1'b1;
                desc_pending[picked] <= 1'b0;
            end
            else if (df_busy) begin
                if (!rom_req) begin
                    rom_req <= 1'b1;
                    rom_is_desc <= 1'b1;
                    rom_addr <= (df_sample * 22'd12) + {18'd0, df_idx};
                end
            end
            else if (!rom_req) begin
                tick <= tick + 1'b1;
                if (tick == 3'd7) begin
                    tick <= 0;
                    if (slot == 5'd27) begin
                        slot <= 0;
                        out_l <= clamp16(acc_l >>> 2);
                        out_r <= clamp16(acc_r >>> 2);
                        acc_l <= 0;
                        acc_r <= 0;
                    end
                    else slot <= slot + 1'b1;
                end

                if (tick == 0 && s_active[slot]) begin
                    reg [9:0] pitch;
                    reg [24:0] step;
                    reg [37:0] next_pos;
                    reg [33:0] loop_span;
                    pitch = {sreg[slot][3][3:0], sreg[slot][2][7:2]};
                    step = pitch_step(sreg[slot][3][7:4], pitch);
                    next_pos = s_pos[slot] + {13'd0, step};
                    loop_span = ({17'd0, s_end[slot]} - {18'd0, s_loop[slot]}) << 16;
                    if (next_pos >= ({21'd0, s_end[slot]} << 16) && loop_span != 0)
                        next_pos = next_pos - {4'd0, loop_span};
                    s_pos[slot] <= next_pos;
                    play_slot <= slot;
                    rom_req <= 1'b1;
                    rom_is_desc <= 1'b0;
                    // 12-bit packed samples are identified and retained in
                    // state, but the bounded v1 datapath still fetches 8-bit.
                    rom_addr <= banked(s_start[slot] + s_pos[slot][37:16]);
                end
            end
        end
    end
end

endmodule
