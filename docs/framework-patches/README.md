# Framework patches

Patches to the MiSTer framework (`sys/`, from
[MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer)).
`sys/` is kept unmodified except for the patches marked **Applied** below
(THIRD_PARTY.md). A patch here is applied only when the room it frees is
actually needed. Each one is small and switchable by
a macro, so after a framework update it can be re-applied with one command.

**Applied:** `audio-filter-disable.patch`, since 2026-10-10 (study R788), with
`MISTER_DISABLE_AUDIO_FILTER=1` in `Model2.qsf`. After a framework update,
re-apply it before building.

## audio-filter-disable.patch

**What it does.** It adds a `MISTER_DISABLE_AUDIO_FILTER` switch to
`sys/audio_out.sv`. With the macro defined, the framework's audio IIR filter is
not built. Its input passes straight through to the DC blocker and mixer that
follow it, in the same signed 16-bit format. Without the macro, the patched
file builds exactly as upstream does.

**Why.** It frees about **430 ALM**. In s927's fit by entity (study R786),
`audio_out` uses 920 ALM, and its `IIR_filter` uses 432 of them. Upstream has
no switch for the filter: `Template_MiSTer` master instantiates it
unconditionally (checked 2026-10-10). The other framework switches
(`MISTER_DISABLE_ALSA`, `MISTER_DISABLE_YC`, ...) do not cover it.

**What is lost.** The MiSTer menu's audio filter presets (`audio_filter` /
`filter` options) stop having any effect on this core. Sound still plays,
unfiltered.

**Temporary by intent.** The filter is off only because the FPGA is full.
If room is freed elsewhere, switch it back on: remove
`MISTER_DISABLE_AUDIO_FILTER` from `Model2.qsf`. The patched file then builds
exactly as upstream does. Update the release README and THIRD_PARTY.md to
match.

**How to apply** (from the repository root):

```
git apply docs/framework-patches/audio-filter-disable.patch
```

Then switch it on in `Model2.qsf`:

```
set_global_assignment -name VERILOG_MACRO "MISTER_DISABLE_AUDIO_FILTER=1"
```

**After a framework update:** run `git apply --check` first. If the
`IIR_filter` instantiation in `sys/audio_out.sv` has moved or changed, the
patch is three hunks and easy to redo by hand:

- `` `ifdef MISTER_DISABLE_AUDIO_FILTER `` around two `assign`s for `acl`/`acr`
  (the filter's `input_l`/`input_r` expressions);
- `` `else ``, then the unchanged `IIR_filter` instance;
- `` `endif `` after it.

**Checked:**

- applies cleanly to the current `sys/`;
- Verilator lint of `audio_out` both with and without the macro.

**Not checked:**

- a Quartus build with the macro set;
- the sound on the board.

Both are due before it ships in a release.
