`timescale 1 ps / 1 ps
// Two-state, Verilator-friendly models of the Cyclone V atoms that Quartus 17.0
// writes into a post-synthesis functional netlist (m2s.vo). Written from the
// vendor models in quartus/eda/sim_lib (altera_primitives.v dffeas / GDFF UDP,
// cyclonev_atoms.v lcell_comb, altera_lnsim.sv's RAM behaviour); the encrypted
// cyclonev_mac is a plain multiply from its parameters.
//
// RAM read-during-write is modelled as the parameters say, and every
// same-address collision is COUNTED (rdw_* below), so a bench can tell whether
// the design ever depends on the mode at all.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off PINMISSING */

package atoms_stat;
  // collisions: an M10K read of the address its port A writes on the same edge
  // (mode "old" -> old data), an MLAB async read of an address written that edge
  longint m10k_rdw = 0, m10k_rdw_diff = 0, mlab_rdw = 0, mlab_rdw_diff = 0;
  int     mlab_x_mode = 0;   // 1: a "dont care" MLAB collision returns garbage (inverted new data)
  bit     printed = 0;
endpackage

module dffeas (input d, clk, ena, clrn, prn, aload, asdata, sclr, sload, devclrn, devpor, output reg q);
  parameter power_up = "low";
  parameter is_wysiwyg = "false";
  parameter dont_touch = "false";
  parameter x_on_violation = "on";
  parameter sclr_over_ena = "false";
  parameter lpm_type = "dffeas";
  initial q = (power_up == "high");
  always @(posedge clk or negedge clrn or negedge prn) begin
    if (!clrn) q <= 1'b0;
    else if (!prn) q <= 1'b1;
    else if (ena) q <= sclr ? 1'b0 : sload ? asdata : d;
  end
endmodule

module cyclonev_io_ibuf (input i, ibar, dynamicterminationcontrol, output o);
  parameter bus_hold = "false";
  parameter simulate_z_as = "z";
  parameter differential_mode = "false";
  parameter lpm_type = "cyclonev_io_ibuf";
  assign o = i;
endmodule

module cyclonev_io_obuf (input i, oe, dynamicterminationcontrol, input [15:0] seriesterminationcontrol,
                         input [15:0] parallelterminationcontrol, input devoe, output o, obar);
  parameter bus_hold = "false";
  parameter open_drain_output = "false";
  parameter shift_series_termination_control = "false";
  parameter sim_dynamic_termination_control_is_connected = "false";
  parameter lpm_type = "cyclonev_io_obuf";
  assign o = i;
  assign obar = !i;
endmodule

module cyclonev_lcell_comb (input dataa, datab, datac, datad, datae, dataf, datag, cin, sharein,
                            output combout, sumout, cout, shareout);
  parameter [63:0] lut_mask = 64'hFFFFFFFFFFFFFFFF;
  parameter shared_arith = "off";
  parameter extended_lut = "off";
  parameter dont_touch = "off";
  parameter lpm_type = "cyclonev_lcell_comb";
  function automatic logic lut4(input logic [15:0] m, input logic a, b, c, d);
    return m[{d, c, b, a}];
  endfunction
  wire ext = (extended_lut == "on");
  wire f2i3 = ext ? datag : datac;
  wire f0 = lut4(lut_mask[15:0],  dataa, datab, datac, datad);
  wire f1 = lut4(lut_mask[31:16], dataa, datab, f2i3,  datad);
  wire f2 = lut4(lut_mask[47:32], dataa, datab, datac, datad);
  wire f3 = lut4(lut_mask[63:48], dataa, datab, f2i3,  datad);
  wire g0 = datae ? f1 : f0;
  wire g1 = datae ? f3 : f2;
  assign combout = ext ? (dataf ? g1 : g0) : lut_mask[{dataf, datae, datad, datac, datab, dataa}];
  wire f2f = lut4(lut_mask[47:32], dataa, datab, datac, dataf);
  wire ai2 = (shared_arith == "on") ? sharein : !f2f;
  assign sumout = cin ^ f0 ^ ai2;
  assign cout = (cin & f0) | (cin & ai2) | (f0 & ai2);
  assign shareout = f2;
endmodule

module cyclonev_mac (input sub, negate, accumulate, loadconst, input [ax_width-1:0] ax,
                     input [ay_scan_in_width-1:0] ay, input [az_width-1:0] az, input [bx_width-1:0] bx,
                     input [by_width-1:0] by, input [bz_width-1:0] bz, input [2:0] coefsela, coefselb,
                     input [ay_scan_in_width-1:0] scanin, input [63:0] chainin, input [2:0] clk, ena,
                     input [1:0] aclr, output [result_a_width-1:0] resulta, output [result_b_width-1:0] resultb,
                     output [scan_out_width-1:0] scanout, output [63:0] chainout, output dftout);
  parameter ax_width = 16, ay_scan_in_width = 16, az_width = 1, bx_width = 16, by_width = 16, bz_width = 1;
  parameter scan_out_width = 1, result_a_width = 33, result_b_width = 1;
  parameter operation_mode = "m18x18_sumof2";
  parameter mode_sub_location = 0;
  parameter operand_source_max = "input", operand_source_may = "input", operand_source_mbx = "input", operand_source_mby = "input";
  parameter preadder_subtract_a = "false", preadder_subtract_b = "false";
  parameter signed_max = "false", signed_may = "false", signed_mbx = "false", signed_mby = "false";
  parameter ay_use_scan_in = "false", by_use_scan_in = "false", delay_scan_out_ay = "false", delay_scan_out_by = "false";
  parameter use_chainadder = "false", enable_double_accum = "false";
  parameter [5:0] load_const_value = 6'b0;
  parameter signed [26:0] coef_a_0 = 0, coef_a_1 = 0, coef_a_2 = 0, coef_a_3 = 0, coef_a_4 = 0, coef_a_5 = 0, coef_a_6 = 0, coef_a_7 = 0;
  parameter signed [17:0] coef_b_0 = 0, coef_b_1 = 0, coef_b_2 = 0, coef_b_3 = 0, coef_b_4 = 0, coef_b_5 = 0, coef_b_6 = 0, coef_b_7 = 0;
  parameter ax_clock = "none", ay_scan_in_clock = "none", az_clock = "none", bx_clock = "none", by_clock = "none", bz_clock = "none";
  parameter coef_sel_a_clock = "none", coef_sel_b_clock = "none", sub_clock = "none", negate_clock = "none";
  parameter accumulate_clock = "none", load_const_clock = "none", output_clock = "none";
  parameter lpm_type = "cyclonev_mac";
  // only what this netlist uses: m27x27, operands and result unregistered
  initial if (operation_mode != "m27x27" || ax_clock != "none" || ay_scan_in_clock != "none" || output_clock != "none") begin
    $display("cyclonev_mac: unsupported configuration %s", operation_mode); $finish;
  end
  wire signed [63:0] xa = (signed_max == "true") ? 64'($signed(ax)) : 64'($unsigned(ax));
  wire signed [63:0] ya = (signed_may == "true") ? 64'($signed(ay)) : 64'($unsigned(ay));
  wire signed [63:0] pr = xa * ya;
  assign resulta = pr[result_a_width-1:0];
  assign resultb = '0; assign scanout = '0; assign chainout = '0; assign dftout = 1'b0;
  final if (!atoms_stat::printed) begin
    atoms_stat::printed = 1;
    $display("ATOMS: M10K read-during-write collisions %0d (value changed by the write %0d); MLAB collisions %0d (changed %0d)",
             atoms_stat::m10k_rdw, atoms_stat::m10k_rdw_diff, atoms_stat::mlab_rdw, atoms_stat::mlab_rdw_diff);
  end
endmodule

// mem_init<k> is a hex string, its value's bit i = bit i of the RAM (port A order)
module cyclonev_ram_block (portadatain, portaaddr, portawe, portare, portbdatain, portbaddr, portbwe, portbre,
                           clk0, clk1, ena0, ena1, ena2, ena3, clr0, clr1, nerror, portabyteenamasks, portbbyteenamasks,
                           portaaddrstall, portbaddrstall, devclrn, devpor, eccstatus, portadataout, portbdataout, dftout);
  parameter operation_mode = "single_port";
  parameter mixed_port_feed_through_mode = "dont_care";
  parameter ram_block_type = "auto";
  parameter logical_ram_name = "ram_name";
  parameter init_file = "init_file.hex";
  parameter init_file_layout = "none";
  parameter ecc_pipeline_stage_enabled = "false";
  parameter enable_ecc = "false";
  parameter width_eccstatus = 2;
  parameter data_interleave_width_in_bits = 1;
  parameter data_interleave_offset_in_bits = 1;
  parameter port_a_logical_ram_depth = 0, port_a_logical_ram_width = 0;
  parameter port_a_first_address = 0, port_a_last_address = 0, port_a_first_bit_number = 0;
  parameter port_a_address_clear = "none", port_a_data_out_clear = "none", port_a_data_in_clock = "clock0";
  parameter port_a_address_clock = "clock0", port_a_write_enable_clock = "clock0", port_a_read_enable_clock = "clock0";
  parameter port_a_byte_enable_clock = "clock0", port_a_data_out_clock = "none";
  parameter port_a_data_width = 1, port_a_address_width = 1, port_a_byte_enable_mask_width = 1;
  parameter port_a_read_during_write_mode = "new_data_no_nbe_read";
  parameter port_b_logical_ram_depth = 0, port_b_logical_ram_width = 0;
  parameter port_b_first_address = 0, port_b_last_address = 0, port_b_first_bit_number = 0;
  parameter port_b_address_clear = "none", port_b_data_out_clear = "none", port_b_data_in_clock = "clock1";
  parameter port_b_address_clock = "clock1", port_b_write_enable_clock = "clock1", port_b_read_enable_clock = "clock1";
  parameter port_b_byte_enable_clock = "clock1", port_b_data_out_clock = "none";
  parameter port_b_data_width = 1, port_b_address_width = 1, port_b_byte_enable_mask_width = 1;
  parameter port_b_read_during_write_mode = "new_data_no_nbe_read";
  parameter power_up_uninitialized = "false";
  parameter lpm_type = "cyclonev_ram_block";
  parameter lpm_hint = "true";
  parameter connectivity_checking = "off";
  parameter mem_init0 = "", mem_init1 = "", mem_init2 = "", mem_init3 = "", mem_init4 = "";
  parameter port_a_byte_size = 0, port_b_byte_size = 0;
  parameter clk0_input_clock_enable = "none", clk0_core_clock_enable = "none", clk0_output_clock_enable = "none";
  parameter clk1_input_clock_enable = "none", clk1_core_clock_enable = "none", clk1_output_clock_enable = "none";
  parameter bist_ena = "false";

  input [port_a_data_width-1:0] portadatain;
  input [port_a_address_width-1:0] portaaddr;
  input portawe, portare;
  input [port_b_data_width-1:0] portbdatain;
  input [port_b_address_width-1:0] portbaddr;
  input portbwe, portbre;
  input clk0, clk1, ena0, ena1, ena2, ena3, clr0, clr1, nerror;
  input [port_a_byte_enable_mask_width-1:0] portabyteenamasks;
  input [port_b_byte_enable_mask_width-1:0] portbbyteenamasks;
  input portaaddrstall, portbaddrstall, devclrn, devpor;
  output [width_eccstatus-1:0] eccstatus;
  output [port_a_data_width-1:0] portadataout;
  output [port_b_data_width-1:0] portbdataout;
  output [8:0] dftout;

  localparam int NB = (1 << port_a_address_width) * port_a_data_width;
  localparam int BEA = (port_a_byte_enable_mask_width > 0) ? port_a_data_width / port_a_byte_enable_mask_width : port_a_data_width;
  logic [NB-1:0] mem;
  logic [port_a_data_width-1:0] qa;
  logic [port_b_data_width-1:0] qb;
  assign portadataout = qa;
  assign portbdataout = qb;
  assign eccstatus = '0;
  assign dftout = '0;

  // the init strings as one number (a string parameter is 8 bits a character)
  function automatic logic [3:0] hexv(input logic [7:0] c);
    if (c >= "0" && c <= "9") return 4'(c - "0");
    if (c >= "A" && c <= "F") return 4'(c - "A" + 10);
    if (c >= "a" && c <= "f") return 4'(c - "a" + 10);
    return 4'd0;
  endfunction
  localparam int L0 = $bits(mem_init0) / 8;
  initial begin
    mem = '0;
    // the last character is the lowest nibble
    for (int k = 0; k < L0; k++) begin
      logic [3:0] v;
      v = hexv(8'(mem_init0 >> (8 * k)));
      for (int b = 0; b < 4; b++) if (4 * k + b < NB) mem[4 * k + b] = v[b];
    end
    if ($bits(mem_init1) > 8) begin $display("ram_block %s: mem_init1 unsupported", logical_ram_name); $finish; end
    qa = '0; qb = '0;
  end

  // ena0 gates clock 0's core when clk0_core_clock_enable says so (the LFO ROM's halves)
  wire core_en = (clk0_core_clock_enable == "ena0") ? ena0 : 1'b1;
  wire in_en   = (clk0_input_clock_enable == "ena0") ? ena0 : 1'b1;

  generate
    if (operation_mode == "rom") begin : g_rom
      always @(posedge clk0) if (core_en && in_en && portare && !portaaddrstall)
        for (int b = 0; b < port_a_data_width; b++) qa[b] <= mem[int'(portaaddr) * port_a_data_width + b];
    end else if (operation_mode == "dual_port") begin : g_dp
      // simple dual port: A writes, B reads, both on clock 0 (as this netlist has them)
      initial if (port_b_address_clock != "clock0" || port_b_data_out_clock != "none" || port_a_data_out_clock != "none") begin
        $display("ram_block %s: unsupported clocks", logical_ram_name); $finish;
      end
      wire we = core_en && in_en && portawe;
      always @(posedge clk0) begin
        logic hit, chg;
        hit = 1'b0; chg = 1'b0;
        if (core_en && in_en && portbre && !portbaddrstall) begin
          for (int b = 0; b < port_b_data_width; b++) begin
            int ix;
            logic nv;
            ix = int'(portbaddr) * port_b_data_width + b;
            nv = mem[ix];
            if (we && ix / port_a_data_width == int'(portaaddr)) begin
              hit = 1'b1;
              if (portabyteenamasks[(ix % port_a_data_width) / BEA]) nv = portadatain[ix % port_a_data_width];
              if (nv != mem[ix]) chg = 1'b1;
            end
            // "old": the read sees the array before this edge's write
            qb[b] <= (mixed_port_feed_through_mode == "old") ? mem[ix] : nv;
          end
          if (hit) begin atoms_stat::m10k_rdw++; if (chg) begin atoms_stat::m10k_rdw_diff++;
            if (atoms_stat::m10k_rdw_diff < 40) $display("M10K-RDW %s bit %0d t=%0t", logical_ram_name, port_a_first_bit_number, $time); end end
        end
        if (we)
          for (int b = 0; b < port_a_data_width; b++)
            if (portabyteenamasks[b / BEA]) mem[int'(portaaddr) * port_a_data_width + b] <= portadatain[b];
      end
    end else begin : g_bad
      initial begin $display("ram_block %s: mode %s unsupported", logical_ram_name, operation_mode); $finish; end
    end
  endgenerate
endmodule

// MLAB: write address / data / enable taken at clk0's rising edge; the read is
// asynchronous (this netlist registers it in a dffeas outside)
module cyclonev_mlab_cell (portadatain, portaaddr, portabyteenamasks, portbaddr, clk0, clk1, ena0, ena1, ena2, clr,
                           devclrn, devpor, portbdataout);
  parameter logical_ram_name = "lutram";
  parameter logical_ram_depth = 0;
  parameter logical_ram_width = 0;
  parameter first_address = 0;
  parameter last_address = 0;
  parameter first_bit_number = 0;
  parameter mixed_port_feed_through_mode = "new";
  parameter init_file = "NONE";
  parameter data_width = 20;
  parameter address_width = 5;
  parameter byte_enable_mask_width = 1;
  parameter byte_size = 1;
  parameter port_b_data_out_clock = "none";
  parameter port_b_data_out_clear = "none";
  parameter lpm_type = "cyclonev_mlab_cell";
  parameter lpm_hint = "true";
  parameter mem_init0 = "";
  input [data_width-1:0] portadatain;
  input [address_width-1:0] portaaddr;
  input [byte_enable_mask_width-1:0] portabyteenamasks;
  input [address_width-1:0] portbaddr;
  input clk0, clk1, ena0, ena1, ena2, clr, devclrn, devpor;
  output [data_width-1:0] portbdataout;
  logic [data_width-1:0] mem [1 << address_width];
  initial begin
    for (int i = 0; i < (1 << address_width); i++) mem[i] = '0;
    if (port_b_data_out_clock != "none") begin $display("mlab %s: registered output unsupported", logical_ram_name); $finish; end
  end
  // a collision: the async read's address is the one written at this edge
  logic coll;
  always @(posedge clk0) begin
    coll <= 1'b0;
    if (ena0 && portabyteenamasks[0]) begin
      if (portbaddr == portaaddr) begin
        atoms_stat::mlab_rdw++;
        if (mem[portaaddr] != portadatain) begin atoms_stat::mlab_rdw_diff++;
          if (atoms_stat::mlab_rdw_diff < 40) $display("MLAB-RDW %s bit %0d a %0d", logical_ram_name, first_bit_number, portaaddr); end
      end
      mem[portaaddr] <= portadatain;
    end
  end
  assign portbdataout = mem[portbaddr];
endmodule
