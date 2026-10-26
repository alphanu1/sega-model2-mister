# Force feedback test for steering wheels

A quick check that your MiSTer can drive your wheel's force feedback. It
finds the wheel, plays a few gentle effects, and tells you which ones work.

## What you need

- A steering wheel with force feedback that Linux supports, for example a
  **Logitech G25, G27 or G29**, some **Fanatec** and **Thrustmaster** wheels.
- **HORI FFB Racing Wheel:** it also needs the `hori-ffb` driver from
  [linux-hori](https://github.com/alphanu1/linux-hori) running first.
  Other wheels don't need anything extra.

## Requirements

- **The standard MiSTer Linux.** Nothing to add or rebuild: the test uses
  Linux's standard force feedback interface, and it's a self-contained
  program (statically linked).
- **A force feedback driver for your wheel in MiSTer's kernel.** That's what
  decides whether your wheel works, not the kernel version:

  | Wheel | On MiSTer |
  |---|---|
  | Logitech G25 / G27 / G29 and similar | built in |
  | Fanatec CSL Elite family | built in |
  | Wheels using the standard USB force feedback format (PID) | built in, through the generic driver |
  | Thrustmaster T300RS and similar | basic driver only: full force feedback usually needs an extra driver MiSTer doesn't have, so expect `SKIP`s or "no force feedback" |
  | HORI FFB Racing Wheel | no kernel driver: run `hori-ffb` from [linux-hori](https://github.com/alphanu1/linux-hori) first |

## Install

1. Copy both files from this folder to **`/media/fat/Scripts`** on your SD
   card:
   - `ffb_wheel_test.sh`
   - `ffb-wheel-test`
2. That's it. Nothing is installed or changed on your MiSTer.

## Run

1. Plug in the wheel, and power it if it has its own supply.
2. In the MiSTer menu, open **Scripts** and choose **`ffb_wheel_test`**.
3. **Let go of the wheel** when it says so. It will turn by itself, to its
   end stops in some tests. All forces are gentle (20 % at most), but keep
   hands and anything else clear of the rim.
4. The test takes about half a minute. The results stay on screen for 15
   seconds.

## Reading the results

The top shows the wheel it found and the effects it offers (an example,
your wheel's lines will differ):

```
Wheel: Logitech G29 Driving Force Racing Wheel
USB 046d:c24f
16 effects at once. Supports:
  constant gain autocentre
```

Then one line per test, with the result first (again an example):

```
PASS  push left              moved left
PASS  push right             moved right
SKIP  spring                 not supported
SKIP  damper                 not supported
...
Result: 4 PASS, 0 FAIL, 7 SKIP
```

| Result | Meaning |
|---|---|
| `PASS` | the wheel took the effect and played it |
| `SKIP` | your wheel doesn't offer that effect: normal, many wheels only do some of them |
| `FAIL` | the wheel refused it; the reason is shown under the line |

After `PASS`, you may see:

- `moved left` / `moved right`: the wheel turned the way it should.
- `WENT RIGHT: mirrored?` (or left): it turned the **wrong** way, so forces
  are mirrored on your wheel. Please report it.
- `feel it`: a vibration, too quick to measure; you should feel it in the rim.
- `holds centre`: a centring spring; turn the wheel a little and it should
  push back.
- `check by feel`: the wheel didn't visibly move; feel whether it pushed.

## Good to know

- **"No force feedback wheel found"**: the wheel isn't connected, isn't
  powered, or Linux has no force feedback driver for it. For the HORI, start
  `hori-ffb` first.
- This tests that **MiSTer** can drive your wheel's force feedback. The Model
  2 cores don't send force feedback in games yet.
- Please share your results (wheel name and the result lines) on GitHub, so
  we know which wheels work.

## Source

`ffb-wheel-test` is built from
[github.com/alphanu1/linux-hori](https://github.com/alphanu1/linux-hori)
(GPL-2.0), version 0.1.3.
