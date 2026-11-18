// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- R1044: the clock for tb_m2_lutw.sv
#include "Vtb_m2_lutw.h"
#include "verilated.h"
double sc_time_stamp() { return 0; }
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_m2_lutw *t = new Vtb_m2_lutw;
    while (!Verilated::gotFinish()) { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
    t->final(); delete t; return 0;
}
