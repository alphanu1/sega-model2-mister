# Old-against-new miters for the area pass R984-R988 on main

model2c's pass (R984-R988, model2c 720160a9..62dfe3e9) ported to this
branch's own files, which differ from model2c's (R899's key_hi in the store;
one remap in the loader; no R940 / R948 in the fill). The proofs, re-runnable
from the history:

    sim/miter/area_r984/prove.sh d458e662 HEAD      # the parent against the pass
    sim/miter/area_r984/prove.sh <rev>^ <rev> qs    # one step

- `fill_miter.sh`: m2_raster_fill (with m2_raster_div) under the fill's own
  benches, and tb_m2_raster_fill at the Model 2 build's parameters, with and
  without MIP, with and without a random in_frac on every quad (`m2r`).
- `qs/`: m2_quad_store at the Model 2 parameters (KW 20, TEXLUT): key_hi
  random a frame.
- `rl/`: m2_rom_loader at the Model 2 parameters (SDR_AW 25, R725's remap).
- `prove.sh`: all three, then the planted faults (sed on the new rev's files;
  2,000 frames each -- the study's counts for the store's were taken at 300).
- `smap.sh`: the standalone quartus_map (Quartus 17.0) used for the area
  figures: `smap.sh <name> <top> "<P=V ...>" "" <files...>`.

Scratch goes under `${AREA_DIR:-/tmp/m2-area}`; every Verilator build runs
under `systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0`, -j 2.
