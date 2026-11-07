# Old-against-new miters for the area pass R984-R988 on model2a

model2c's pass (R984-R988, model2c 720160a9..62dfe3e9) ported to this
branch's own files, which differ from model2c's (R944 / R957's DIL in the
fill, R962's spill in the store). The proofs, re-runnable from the history:

    sim/miter/area_r984/prove.sh a6cf8262 HEAD      # the parent against the pass
    sim/miter/area_r984/prove.sh <rev>^ <rev> qs    # one step

- `fill_miter.sh`: m2_raster_fill (with m2_raster_div) under the fill's own
  benches, and tb_m2_raster_fill at the 2A build's parameters, with and without
  MIP, with and without a random in_frac / dil_on on every quad (`a2r`).
- `qs/`: m2_quad_store at the 2A parameters (NX 512): `tb_qs_miter.cpp` drives
  ofree / in_stall and lists past 2,048.
- `rl/`: m2_rom_loader at the 2A parameters (SDR_AW 26, three remaps).
- `prove.sh`: all three, then the planted faults (sed on the new rev's files;
  2,000 frames each -- the study's counts for the store's were taken at 300).
- `smap.sh`: the standalone quartus_map (Quartus 17.0) used for the area
  figures: `smap.sh <name> <top> "<P=V ...>" "" <files...>`.

Scratch goes under `${AREA_DIR:-/tmp/m2-area}`; every Verilator build runs
under `systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0`, -j 2.
