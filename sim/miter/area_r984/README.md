# Old-against-new miters for the area pass R984-R988 (2C)

Kept from the scratch area the pass ran in, so the proofs can be re-run.

- `fill_miter.sh`, `fill_fault_frac.sv`: m2_raster_fill before / after R984
  (every output, every cycle; a planted fraction fault).
- `qs/`: m2_quad_store before / after R985-R987 (`tb_qs_miter.cpp`, `run.sh`;
  `stage1.sv` / `stage2.sv` / `r986.sv` are the intermediate steps; `fault*.sv`
  the planted faults).
- `rl/`: m2_rom_loader before / after R988.
- `smap.sh`: the standalone quartus_map used for the area figures.

The scripts were written against a scratch directory; their paths need
pointing at a checkout before they run again. Every Verilator run goes under
`systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0`.
