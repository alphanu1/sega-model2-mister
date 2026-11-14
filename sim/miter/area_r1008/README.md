# Old-against-new miters for the area pass R1008 (2C)

- `../geo.sh` (extended for R1008): m2_geometry with the clipper, engine,
  projector and transform old against new, under tb_m2_geometry (plain and
  MIPZ) and the geodiff MAME walks. R1008 ran it as
  `DROP_OLD_PARAMS=M10K_ROOM GEOMZ_G=-GM10K_ROOM=1 GD2A="<r5701> <r6601>"
  GD="<w4000> <w9000>" sim/miter/geo.sh <tree at 6f1fc392>`.
- `clip.sh`: tb_clip_top (2,003 random quads against the C transcription of
  MAME's clipper) on an m2_geo_clip miter -- the only bench that reaches
  the "0,2 out" case (four created points).
- `tb_m2_tile_fetch_rep.cpp`: tb_m2_tile_fetch with `d->final()` (for the
  miter's count) and, with TF_REP=1, the MASK_SKIP cases on repeated tiles
  (the glyph cache's hits) instead of distinct ones.

Every Verilator run goes under
`systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0`.
