# Framework patches

Patches to the MiSTer framework (`sys/`, from
[MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer)).
`sys/` is kept unmodified except for the patches marked **Applied** below
(THIRD_PARTY.md). A patch here is applied only when the room it frees is
actually needed. Each one is small and switchable by
a macro, so after a framework update it can be re-applied with one command.

**Applied:**

- `audio-filter-disable.patch`, since 2026-10-10 (study R788), with
  `MISTER_DISABLE_AUDIO_FILTER=1` in `Model2.qsf`.
- `hps-io-video-cfg.patch`, since 2026-10-10 (study R793).

After a framework update, re-apply both before building:

```
git apply docs/framework-patches/audio-filter-disable.patch
git apply docs/framework-patches/hps-io-video-cfg.patch
```

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

## hps-io-video-cfg.patch

**What it does.** It adds three outputs to `sys/hps_io.sv`: `cfg_csync`,
`cfg_ypbpr` and `cfg_vga_scaler`. They carry the MiSTer.ini settings
`composite_sync`, `ypbpr` and `vga_scaler`. `hps_io` already receives all
three in its `cfg` word but exported only `forced_scandoubler` and
`direct_video`. Nothing else changes, and a core that leaves the new outputs
unconnected builds exactly as before. It costs no logic.

**Why.** The core's OSD `Video` option defaults to **Auto**. Auto starts the
core in 15 kHz interlaced when the setup looks like a CRT: `direct_video`,
`composite_sync` or `ypbpr` set, and neither `forced_scandoubler` nor
`vga_scaler` (study R793). Without this patch only `direct_video` users
could be detected. A SCART or component user on the analog board would boot
at 24 kHz, which their TV cannot show, and so could not see the OSD to
change it.

**How to apply** (from the repository root):

```
git apply docs/framework-patches/hps-io-video-cfg.patch
```

No macro is needed, because `Model2.sv` connects the outputs.

**After a framework update:** if it no longer applies, the change is three
`output` lines after `direct_video` in the port list and three `assign`s
(`cfg[3]`, `cfg[5]`, `cfg[2]`) after `assign direct_video = cfg[10];`. If
upstream ever exports these itself, drop the patch and connect upstream's
ports.

**Checked:** applies cleanly to the current `sys/`; Verilator lint of the
whole core and the Quartus parse of both files.

**Not checked:** a CRT on the board.
