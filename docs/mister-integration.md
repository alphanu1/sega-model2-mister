# Putting a core on MiSTer: what actually bites

Everything here was paid for once, on hardware, with a board that showed a
blank screen or a frozen loading bar and no other output. None of it is
Model 1 specific — it is the framework, the toolchain and the SDRAM. Read it
before wiring up the next core.

The rule that generated most of this list: **assume the screen is the core's
only output channel, but know that it is not the only one available.** The
distinction was wrong here twice and is worth getting right. Plan for that on day one rather than
after the fifth twenty-five minute Quartus build that comes back "still white".

**Stated precisely, because the earlier wording was wrong and would cost
someone a real channel at P6.** The *system* does have a serial console: set
`debug=1` in `mister.ini` and attach USB-mini to the DE10-Nano's UART port, and
`Main_MiSTer` logs to it. That is the **HPS side** — core loading, config
parsing, file I/O, `ioctl_download` progress, OSD state — and it is exactly the
right instrument for the framework deadlocks listed below, `ioctl_wait` among
them, which otherwise present as a blank screen with no information at all.

What HPS logging cannot do is see inside the fabric — it has no knowledge of
your HDL, so there is no "debug info about the running core" to switch on.

**The core can, however, drive the serial port itself.** `sys/emu_ports.vh`
exposes `UART_TXD`/`UART_RXD`/`UART_CTS`/`UART_RTS` to `emu`, and `sys_top.v`
wires them to `cyclonev_hps_interface_peripheral_uart` — the HPS UART, the same
one the Linux console uses. It is there for emulated serial devices (modems,
MIDI), and nothing stops a core putting its own bytes on it. **A minimal
transmitter is tens of LUTs, and that is a genuine printf.**

Two caveats before relying on it: the port is shared with the Linux console, so
a core writing to it collides with whatever else is using the line; and it is
still a *core-authored* channel, so it tells you only what the RTL was written
to say. It does not replace the overlay for always-on state, and it does not
replace SignalTap for watching a signal.

For seeing inside the fabric there are then three tools, and they are not
interchangeable:

- **SignalTap** (in Quartus 17.0): a real logic analyser on the running device.
  Costs M10K and routing, needs a rebuild per probe set, and is the only way to
  watch a signal on hardware.
- **The debug overlay** (`m1_diag`, 307 ALM, measured): always available, costs
  nothing per query, and is why it should be running *before* the first board
  test rather than after the fifth failed one.
- **A core-driven UART**: a serial log from inside the fabric, at tens of LUTs.
  Best for a stream of events over time — a trace — where the overlay shows a
  snapshot and SignalTap needs a rebuild per probe set.

And a third that outranks both while a block is still being built: **the
simulation harness**. For anything reproducible in Verilator, hardware
debugging is strictly worse — the lockstep harness gives every internal signal,
cycle-accurate, diffed against a reference, millions of checks per run. Reach
for the board when the bug needs the board, not before.

---

## The framework will deadlock you three different ways

### 1. `ioctl_wait` is wired straight to the HPS bus

`hps_io.sv` does `assign HPS_BUS[37] = ioctl_wait;`. It is not a private signal
between your loader and `hps_io` — it stalls the HPS itself.

So it must be gated on `ioctl_download`:

```systemverilog
assign ioctl_wait = ioctl_download & (~mem_ready | <buffer nearly full>);
```

Ungated, a `~mem_ready` term holds it from the instant the FPGA is configured
until SDRAM finishes JEDEC bring-up — about 125 µs at 80 MHz. MiSTer reads the
core's `CONF_STR` immediately after enabling the bridge, which lands inside that
window. It gets nothing, the core reports no name, and **the core never appears
to load at all**. The FPGA is running the whole time, which is what makes it
look like a dead bitstream rather than a handshake held low.

### 2. MiSTer holds the core in reset while it streams a ROM

If your SDRAM controller and ROM loader sit inside the game reset, then: the
loader asserts `ioctl_wait` until SDRAM is ready, SDRAM is never ready because
it is held in reset, and the HPS waits forever for a signal only the HPS can
release. On screen that is **"Assembling ROM" frozen partway with no error**.

Split the resets. The memory subsystem comes out of reset on PLL lock and stays
out:

```systemverilog
wire mem_rst_n = pll_locked;
wire rst_n     = pll_locked & ~(RESET | status[0] | buttons[1]);
```

### 3. One signal must not mean two things

This one cost a whole evening. A core port named `rom_loaded` fed both the
loader's `mem_ready` ("SDRAM can accept a write") and the CPU's release ("a ROM
has arrived"). Those are different facts. Gating the CPU by feeding that port
`mem_ready & <the loader's own done flag>` closes a loop:

- the loader holds `ioctl_wait` while `~mem_ready`
- `mem_ready` is now false until the loader finishes
- the loader cannot finish, because the HPS is stalled on `ioctl_wait`

Zero bytes transferred, forever, and the same frozen loading bar as fault 2 —
which is what made it look like a regression of something already fixed.

**Derive the CPU's release inside the core from the loader's own output.** Never
route it out to the top level and back in.

### `ioctl_wait` does not stop the host — it asks it to

Everything already in flight still arrives. `FIFO_DEPTH - WAIT_MARGIN` is
exactly how many of those you can absorb before words start being discarded,
silently.

At depth 8 with margin 6 the buffer tolerated **15 cycles** of host reaction and
dropped words at 16 — 200 ns at 80 MHz, well inside a single HPS bus round trip.
A dropped word is a ROM with holes in it, reported as a *successful* load, that
crashes the CPU much later looking like a core bug.

Two lessons, and the second is the bigger one:

- Size the buffer for microseconds of host latency, not cycles. 512/256 gives
  about 3.2 µs and costs two M10K.
- **The test swept host latency 0..6, which was the margin the parameter was set
  to.** It confirmed the setting instead of testing it. Sweep an order of
  magnitude past what you believe, or the test is decoration.

---

## Clocking

### A side-effecting target acts on the HANDSHAKE, never on the level

**One access is `req & ack`, not one cycle of `req`.**

A master holds its request until acknowledged — ours does: `i960_lsu.sv` drives
`bus_req = (state == S_XFER)` and drops it when `bus_ack` retires the state. That
is correct, and for RAM it is also harmless, because reading the same word twice
returns the same word.

**For anything with a side effect it is not harmless.** A FIFO, a
read-to-clear status register, an auto-incrementing port: each cycle the level is
high looks like another access.

The Model 1 core hit exactly this in its TGP (`b895e6c`, measured not inferred).
Its coprocessor asserts `mem_req` across two states because a registered RAM read
needs the address to stay put, and its FIFO logic was:

```systemverilog
assign fifo_in_pop   = fifo_rd && fifo_in_valid;    // fired EVERY cycle
assign fifo_out_push = fifo_wr && !fifo_out_full;   // likewise
```

So every `mov (x1), b` consumed **two** command words and every `mov p, (bx1)`
pushed its result **twice**. The symptom was a hardware deadlock — the coprocessor
waiting forever for a word the CPU had already sent — and the double push was
found one minute after the double pop was fixed, because the first correct result
printed twice. **Left alone it would have fed a duplicate and gone wrong one
command later, which is far harder to see than the deadlock that was hiding it.**

The fix shape is worth copying: a `popped`/`pushed` flag that clears when the
request drops, so the action happens once however long the access is held; the pop
fires on the first cycle the data is actually present, so an access that arrives at
an empty FIFO still completes when the other side fills it; and the ack accepts
"already done" as complete.

**This applies to every peripheral P1.5 step 3 and beyond attaches to the i960
bus** — the ROM loader, the geometry FIFO, the I/O chip, read-to-clear status. It
is cheap to get right up front and produces a deadlock plus a masked duplicate if
got wrong.

### Use the generated PLL IP, and name it `pll`

`sys_top.sdc` puts every core PLL output into one clock group by matching a
hierarchy pattern:

```tcl
-group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
```

A hand-instantiated `altera_pll` does not produce the `altera_pll_i` level, so
the clocks match nothing, fall outside every group, and get timed against the
audio PLL. Result: **−87 ns of setup slack, a build that reports success, and
nothing running on hardware.**

**Sharpened 2026-08-18, having hit it anyway.** The rule is not only about the
module NAME, and not only about `altera_pll_i`. It is about the **whole instance
path**, and the level that is easiest to lose is `pll_inst`:

```
   pll  ->  <inner module> pll_inst  ->  altera_pll altera_pll_i
```

`rtl/pll/pll.v` was first written with `altera_pll altera_pll_i` directly inside
`pll` — correctly named at both ends, and still missing `pll_inst`. Functionally
identical, constraint-wise fatal. Measured cost on this core: **−36.5 ns of setup
slack on a 31.25 ns clock, plus −45.1 on the HDMI PLL and −13.2 on audio**, all of
which vanished when the level was restored. The framework PLLs were failing only
because the core's unconstrained clocks were being timed against them, so the
symptom points away from the cause.

**This section existed, quoting −87 ns, and did not prevent it.** The durable form
is the guard below, now in `Model2.sdc`: it counts the matched clocks and raises a
Quartus *error* when the count is zero, so the build fails instead of passing
vacuously.

An empty `get_clocks` makes `set_clock_groups` a silent no-op, so check it:

```tcl
set sys_clk [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]
if {[llength $sys_clk] == 0} { post_message -type error "clocks not found" }
```

The IP also brings `PLL_AUTO_RESET ON` and direct compensation mode. Without
auto-reset, a PLL with `rst` tied low that misses lock once never locks again.

### Multiple core clocks land in the same group

Being in one group means they are timed *against each other*, which is wrong if
they are asynchronous by construction. Cut them explicitly, by their real names.

### The framework does not constrain SDRAM at all

`sys_top.sdc` has nothing about SDRAM. `sys/sys.tcl` provides the pin locations
and the I/O settings that matter — `FAST_OUTPUT_REGISTER`,
`FAST_INPUT_REGISTER`, `CURRENT_STRENGTH_NEW "MAXIMUM CURRENT"` — but no timing.
`assign SDRAM_CLK = ~clk_sys;` is the common idiom and works, but nothing in the
tool checks it. Know that this is unconstrained before you spend a day
suspecting it.

---

## Quartus 17.0 will silently build memory out of flip-flops

This is the single most expensive failure mode on this device. Inference fails
*quietly* — the fitter reports success and you lose the device.

Measured, not assumed:

| Idiom | Result |
|---|---|
| `mem[a][7:0] <= d[7:0]` byte enables | zero M10K, built from registers |
| two byte-wide arrays, plain write enables | infers immediately |
| two write ports (true dual port) | zero M10K — 192 ALM became 16,059 |
| same, with `no_rw_check` | still zero M10K |
| reset loop clearing the array | forces registers — it is a second write port |
| dual clock, one write one read | fine: 32768×8 → 32 M10K, 37 ALM |

Rules that follow:

- Split every memory into byte lanes with plain write enables.
- Put an explicit `(* ramstyle = "M10K" *)` on anything that matters, so a
  regression is a build error instead of a resource catastrophe.
- **Never clear an array in reset.** Pointers make the contents unreachable.
- Test a memory idiom at 1024 entries. It answers in thirty seconds what hours
  of full-size builds will not.
- Simulation cannot see any of this. Verilator has no opinion about whether
  storage lands in RAM.

Also: Quartus 17.0 rejects `for (genvar i = ...)` in the loop header, which is
legal SystemVerilog. Declare the genvar outside.

And: when testing a Quartus change, re-run `quartus_map`, not just `quartus_fit`
— a fit-only rerun reuses the previous netlist and will happily report success
for a setting that actually breaks the build.

---

## Make the screen an instrument

**`docs/debug-overlay.md` is this core's implementation**, with what every row
means and what it costs. Measured, on a 5CSEBA6U23I7: **307 ALM, 553 registers,
zero M10K** — under a third of a percent of what the core uses, and it did not
cost timing. Cheap enough to keep in every build, behind a compile-time switch
for the one that ships.

Since the screen is the only channel, put data on it deliberately. `m1_diag`
paints 32-bit words as eight hex digits in a 5x7 font at 2x, which a phone
camera resolves without argument.

It did not start that way. The first version drew 32 blocks per word with a
green rule every four bits, and it worked — but reading it means locating a cell
boundary to a few pixels in a photograph of an LCD, and a camera against a
screen produces moire on exactly an 8-pixel pitch. Three values were misread
that way in one session, twice sending the next experiment after the wrong
subsystem. **An instrument that is hard to read is a source of wrong answers,
not a defence against them.** Render digits.

It works, and it paid for itself immediately: a photo showed `ioctl_wait`
asserted with the buffer empty, nothing pending and the controller reporting
ready, which leaves exactly one term in that expression that can be true. That
is what found deadlock 3 above.

What to show, roughly in order of value:

1. CPU program counter — parked or moving, and where.
2. Words the host sent, against words that reached memory. Equal means the ROM
   arrived intact; a shortfall names a dropped-word bug directly.
3. The first instruction fetch: its address and the word that came back.
   Separates "memory returns nothing" from "the fetch went to the wrong place",
   which are the two ways to end up executing garbage.
4. Status flags: halted, trap, ROM-ready, memory-ready, overflow.
5. Free-running counters for each memory port — whichever one stops moving is
   the subsystem that died.

Lessons on the instrument itself:

- **Tag every row with its own index.** Tagging only some rows made the row
  numbering ambiguous in a photograph and cost a round trip.
- Cells changing during the camera exposure show as stripes rather than solid
  colour. That is free information: it tells you which counters are live.
- Keep it out of the game reset. An overlay held in reset leaves `VGA_DE` low
  and draws nothing during exactly the part of startup worth watching.
- Verify it exhaustively — 761,856 checks here, every cell against the bit it
  claims to show. An instrument that lies sends the next session after the wrong
  subsystem.

---

## Testing against the board

- **Reboot before every load test.** A core that fails to load leaves the MiSTer
  stalled, and any load attempted after that reports whatever the stalled state
  holds. A control experiment run that way proves nothing.
- `/tmp/CORENAME` is the reliable indicator of what is running.
  `/sys/class/fpga_manager/fpga0/state` reads `operating` regardless, and the
  per-core file in `/media/fat/config/` is not written on load, so neither
  distinguishes success from failure.
- Load with `echo "load_core /media/fat/_Arcade/<name>.mra" > /dev/MiSTer_cmd`.
- MiSTer drives the FPGA manager through `/dev/mem`, so the **absence of a
  `dmesg` entry means nothing** about whether configuration was attempted.
- The `screenshot` command produced no file on this build; do not plan on it.

---

## Simulate what hardware actually does

The largest single lesson of the whole exercise.

The frame test poked the ROM image straight into the SDRAM model before the run.
That is fast and it isolates the CPU, but it means memory is **already correct
at the instant the CPU is released** — a condition hardware never provides. A
reset-sequencing fault sat in the top level while every simulation passed.

Fixes that made simulation able to find real bugs:

- Stream the ROM through `ioctl` into the real loader, through the real
  controller, with the video path fetching concurrently.
- Make unwritten memory read `0xFFFF`, not zero. Zero is a legal instruction, a
  legal tile number and a black palette entry, so a core let loose on empty
  memory looks far healthier in simulation than on a board.
- Use the board's real clock frequencies, not round numbers. Asynchronous domain
  cuts mean nothing between domains is ever timed, so a ratio-sensitive crossing
  passes at 4.000 and fails at 4.167.
- **Add a stall detector.** A hang that never returns says only "something is
  wrong". One that prints every signal capable of holding the handshake, then
  fails loudly, is a diagnosis. Make it `$fatal` — a stalled run exiting zero is
  a test reporting success for a core that cannot load a ROM.
- Flush progress output. `$display` to a redirected file is block buffered, so a
  hung run prints nothing and is indistinguishable from a slow one.

---

## Debugging discipline that worked

- **Control experiments split build-flow faults from design faults.** Building
  the stock template and loading it, then the template plus our PLL, localised a
  failure that neither reasoning nor staring at code had.
- **Reproduce off-hardware before fixing.** Every fix in this list that stuck was
  first made to fail in simulation. Every theory that died — refresh deadlock,
  arbiter starvation, double acknowledge, SDRAM read timing — died on contact
  with the code or with a measurement, and would have cost a build each to test
  on the board.
- **Acknowledges must be held, not pulsed**, for anything talking to a `ce`-gated
  requester. A one-cycle pulse is missed and the requester waits forever. This
  bit twice, and both times it looked like a dead CPU rather than a handshake
  fault.
- Check the obvious cheap thing first. Two hypotheses were disproved for free by
  reading `sys.tcl` and `hps_io.sv`, and one by noticing a `grep` had run in the
  wrong directory.
