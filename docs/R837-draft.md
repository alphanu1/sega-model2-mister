**R837 -- DESERT TANK'S THIRD ANALOG CHANNEL IS THE CANNON'S ELEVATION, NOT A
BRAKE; THE ONE DRIVE PEDAL GOES WHERE THE SHIFT LEVER SAYS.**
(DRAFT for docs/model2a-design-study.md section 10. Board, s1104: "the cannon
just looks straight and cannot be controlled"; then "half works but keeps
going straight up" -- the right stick reached it, through ADC channel 2.)

*Believed:*
  * R835 7: "Daytona's 0x20..0xe0 ADC values serve unchanged" -- channel 0
    steer, 1 accelerator, 2 brake, both pedals idling at 0x20, the right
    stick's Y split by sign between them.
  * MAME 0.289's INPUT_PORTS(desert) names the ports STEER / ACCEL / BRAKE.
    BRAKE is declared IPT_AD_STICK_Y, and nothing in the driver says why.
  * The cabinet has a brake pedal, as Daytona's does.

*Now known -- VERIFIED (MAME 0.289, sim/io/mame_m2_desert_input.lua: a
timed script of inputs, snapshots and forced DPRAM analog bytes):*
  1. THE GAME NAMES ITS CHANNELS. Service mode (TEST) -> INPUT TEST lists
     CHUTE 1/2, TEST, SERVICE, START, VR3(RED), VR2(GREEN), VR1(BLUE),
     MACHINE GUN, CANNON, SHIFT, and three analog values: HANDLE (channel
     0), ACCEL (1), TURRET (2). Driving each MAME port moved exactly its
     line (0x00, 0x20, 0x80, 0xe0, 0xff all shown as written). Forcing the
     DPRAM bytes of channels 3-7 (0x10..0xc8) showed nothing: the test has
     no line for them. At rest MAME shows HANDLE 80, ACCEL 00, TURRET 80 --
     an AD_STICK with no MINMAX centres at 0x80, so MAME feeds the turret
     its centre and the core fed it a pedal's idle 0x20.
  2. TURRET IS AN ABSOLUTE ELEVATION, 0x80 CENTRE, LOWER = AIM UP. In
     play, tank standing, the gun crosshair's screen y (496x384 snapshot)
     against the value, 2 s per value: 0x20 14.9, 0x28 14.9 (pinned at the
     top from about here), 0x30 19.8, 0x50 62, 0x60 95, 0x70 112, 0x80
     133.8, 0x90 153, 0xa0 172, 0xb0 191, 0xc0 204, 0xd0 / 0xe0 below the
     tank (not visible); 0x00-0x18 the same as 0x20. Back to 0x80 it
     returns to 133.8. The game slews the gun to the value: about 0x60 in
     0.6 s, 0x20 -> 0xc0 settled in about 1.5 s. A value held at 0x20 is
     the gun pinned straight up -- the board's symptom.
  3. THE GUN SERVO BREAKS ON A BIG DOWNWARD JUMP. With the gun up, a jump
     to 0xc8 or beyond (0x20 -> 0xc8, 0xd0, 0xe0; 0x28 -> 0xe0; 0x30 ->
     0xe0) leaves the gun pinned up, ignoring the input for 10-20 s, and
     then for a while it moves the wrong way (0x20 drew the crosshair at
     y 190-198). 0x20 -> 0xc0, 0x30 -> 0xb8, 0x30 -> 0xa8, every upward
     jump (0xe0 -> 0x20) and every jump from 0x80 work. It is the input,
     not the moment: the same sequence 14 s later does the same, and
     0x20 -> 0x80 at the same moment works. Ramps from 0x20 to 0xe0, one
     step a frame: 0.5, 1, 2, 3, 5 s all work; 0x20 a step every 3 frames
     (0.25 s) breaks. Nothing in the input path wraps: 0x30 -> 0xb8 (+0x88,
     -0x78 as a signed byte) goes down correctly.
  4. THERE IS NO BRAKE. ACCEL is the only drive pedal and SHIFT (IN1 bit 0,
     low = ON) is the forward / reverse lever: lever OFF + ACCEL drives
     forward, ON + ACCEL drives backward (the minimap marker: forward y
     +3.3 px/s at 0xff, +1.4 px/s at 0x60 -- ACCEL is analogue; reverse
     -4.5 px/s), and letting go of ACCEL stops the tank within a second.
     Throwing the lever to reverse while driving forward with ACCEL held
     slows the tank and backs it up (no stop needed first).
  5. NO CALIBRATION. The test menu is BOOKKEEPING, GAME SYSTEM, INPUT TEST,
     OUTPUT TEST, SOUND TEST, TGP TEST, MEMORY TEST, BACKUP RAM CLEAR, EXIT;
     GAME SYSTEM holds coin/credit, country, advertise sound and the two
     difficulties. Nothing stores analog limits.
  6. THE CORE (rtl/io/m2_cab_inputs.sv, game ID 2 only):
       - channel 0 HANDLE: Daytona's steering path unchanged (paddle, left
         stick X, right stick X in "Pedals+steer", d-pad left/right ramp,
         Steering scale, Steering smoothing).
       - channel 2 TURRET: target = 0x80 + 3/4 of the right stick's Y
         (exactly 0x20..0xe0; up = aim up), used when the stick is past the
         +-12 dead zone in pad mode; otherwise the d-pad's held aim (up /
         down, one count each 7.8 ms, 0x20..0xe0, 0x80 out of reset, holds
         when released). The output follows the target one count each
         3.9 ms (0x20..0xe0 in 0.75 s, faster than the gun) -- (3).
         "Pedals: Swapped" flips the stick's Y.
       - channel 1 ACCEL: 0xe0 while Forward or Reverse (the J1 Accel /
         Brake buttons) is held; in "Pedals+steer" (a wheel) the right
         stick's Y as Daytona's pedal (0x20 + 3/2 of the magnitude, sign
         chooses the direction, held at 0x20 within +-12); else 0x20.
       - IN1 bit 0, the lever: a latch. Reverse (or a wheel's reverse half)
         sets it, Forward (or the forward half) clears it -- Reverse wins
         if both -- and VR4 ("Shift") still flips it by hand. Reset:
         forward.
     tb_m2_cab_inputs: part A, game ID 0 against the 0f3cbc4 block,
     30,000,000 checks, 0 differences (Daytona bit-identical); part B, game
     ID 2 against a model of this entry at SYS_MHZ 80 and a second copy at
     SYS_MHZ 1 (so the millisecond timers step: 1,518 d-pad steps, 3,922
     slew steps), 320,000,000 checks, 0 differences, 13,450 lever sets,
     2,032 VR4 flips; part C, 24 directed checks (rest 0x80 / 0x20 / 0xff,
     rails, slew, dead zone, d-pad saturation and hold, lever, wheel mode).
     Eight planted faults all caught: turret d-pad rest 0x20 (s1104's
     symptom), Reverse not setting the lever, Daytona's brake routed to the
     turret, Pedals not flipping the turret, the stick aiming in wheel
     mode, the d-pad reversed, no slew limit, slew output reset 0x20.
     lint_top clean; lint_idx the same 147 lines; quartus_map 17.0
     --analyze_file: 0 errors (the -8'sd128 warning is the old line).
     Quartus constant-fold of the turret arithmetic (stick -128, +127,
     both swapped, -50, +13): 0x20, 0xe0, 0xe0, 0x21, 0x5b, 0x8a -- what
     the model computes.
  7. THE MRA. Both Desert Tank MRAs' <buttons names>: Accel / Brake become
     Forward / Reverse; the rest unchanged (VR1 Blue, Shift, Machine Gun,
     Cannon, VR2 Green, VR3 Red). CONF_STR's J1 line, Daytona's names, is
     unchanged.

*INFERRED (each with what settles it):*
  a. The servo break (3) is the game's, not MAME's -- it runs the game's own
     code. A cabinet's lever cannot jump 0xc0 in a frame, so it would never
     have shown. Ben on the board: flick the stick full up to full down
     with the slew limit in; the gun should follow.
  b. 0xe0 is the gun's lowest elevation (the crosshair is hidden under the
     tank from 0xd0). A RAM tap on the game's elevation variable.
  c. Channels 3-7 are unused in play as in the test screen (the i960 reads
     DPRAM bytes 0-7 together, 2,250 times each in 40 s). A play run with
     them forced.
  d. HANDLE has no jump fault like the turret's. A pad flicked lock to
     lock; Steering smoothing already exists if it does.
  e. Area: about +70 ALM (two 8-bit registers, a 20- and a 19-bit counter,
     compares, muxes). A fit.
  f. The turret's direction (stick up = aim up) suits most pads; "Pedals:
     Swapped" is the escape. Ben on the board.

*Decision:* Desert Tank's channel 2 is the turret, centred and slew-limited;
Forward / Reverse buttons drive the one pedal and set the lever. Daytona is
unchanged. README.md line 21 still says Desert Tank "will be a separate core"
-- stale since R835; releases/README.md has no Desert Tank section yet.

*Controls (Desert Tank, game ID 2):*

| Cabinet                  | Pad (default)                       | Wheel ("Right stick: Pedals+steer") |
|--------------------------|-------------------------------------|-------------------------------------|
| Handle (steer the tank)  | Left stick X (d-pad left / right)   | Wheel (right stick X)               |
| Turret (cannon up/down)  | Right stick Y, centred at rest; d-pad up / down move a held aim | D-pad up / down |
| Gas pedal, forward       | Forward button (Accel), a full press -- put it on a trigger | Pedal: the forward half of right stick Y |
| Gas pedal, reverse       | Reverse button (Brake), a full press; sets the lever to reverse | Pedal: the other half |
| Shift lever              | Set by Forward / Reverse; Shift (VR4) flips it by hand | the same |
| Machine gun / Cannon     | Machine Gun / Cannon (Gear Up / Gear Down's slots) | the same |
| VR1 / VR2 / VR3          | VR1 Blue / VR2 Green / VR3 Red (service menu: Red up, Blue down, Start selects; Green + Blue exit the input test) | the same |

MiSTer delivers the Forward / Reverse buttons as digital: on a pad's
triggers they are full presses (ACCEL 0xe0), not analogue. "Pedals:
Swapped" flips the right stick's Y (the turret on a pad; which half is
forward on a wheel). "Steering" and "Steering smoothing" act on the handle
as in Daytona.
