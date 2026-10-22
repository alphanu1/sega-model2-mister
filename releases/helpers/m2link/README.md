# m2link: Daytona USA link play for the Sega Model 2 MiSTer core (EXPERIMENTAL)

Needs the Model 2 core `Model2_20261021c.rbf` or later (in the `releases`
folder one level up) and the `Daytona USA (Revision A).mra`.

> **Experimental.** Link play is new and has only been tested on a few
> setups so far (a MiSTer linked to the PC recompilation). Expect rough
> edges, and please report what works and what doesn't: your network, how
> many cabinets, MiSTer or PC, and whether frame sync was on.

Daytona USA (Revision A, the 1994 set) can race other cabinets over your
network, wired or Wi-Fi, like linked arcade machines: two MiSTers, or a
MiSTer and a PC running the
[Daytona USA recompilation](https://github.com/alphanu1/daytona-arcade-recomp),
or more of either. They speak the same protocol, so any mix works.

The MiSTer's network is on its Linux side, so a small program, `m2link`,
carries the link; the core just needs its link board switched on. Everything
is in this folder, ready to copy — nothing to build.

| file in this folder | where it goes on the SD card |
|---|---|
| `m2link` (the program) | `/media/fat/linux/m2link` |
| `m2link.ini` (its settings) | `/media/fat/linux/m2link.ini` |
| `m2link.sh` (start / stop) | `/media/fat/Scripts/m2link.sh` (only if you run it from the Scripts menu) |

`m2link` md5: `adccae3cf26e070dcd205f2045003d01`

**Setting up each MiSTer:**

1. Copy the files as in the table above.
2. Edit `/media/fat/linux/m2link.ini`. Two lines matter:

       link_port = 15112
       link_next = 192.168.1.XXX:15112

   * `link_port`: this cabinet listens here for the cabinet before it in the
     ring. Leave it at 15112 unless something else uses that port.
   * `link_next`: replace `192.168.1.XXX` with the IP address of the **next**
     cabinet, and give that cabinet's `link_port`. The cabinets form a ring:
     with two, each one's next is the other. Use an IP address, not a name.

   The names and defaults are the recomp's (its launcher's Game tab), so a
   MiSTer and a PC set up the same way.
3. Choose how `m2link` runs. Either:
   * **from the Scripts menu**: **Scripts > m2link** starts it; running it
     again stops it. Do this before a linked race; or
   * **at every boot**: add this line to `/media/fat/linux/user-startup.sh`
     and reboot once:

         /media/fat/linux/m2link -c /media/fat/linux/m2link.ini > /tmp/m2link.log 2>&1 &

     `m2link` then waits quietly. It links when Daytona is loaded with Link
     board On, drops the link when you switch it Off or load another core,
     and never touches anything while another core is running.
4. Load **Daytona USA (Revision A)**, open the OSD and set **Link board** to **On**.
5. Test mode (F2, or your mapped Test button) > **GAME SYSTEM**: set **LINK ID**
   to **MASTER** on one cabinet and **SLAVE** on all the others, and give each
   cabinet a different **CAR NUMBER**. Exit test mode (that's saved).

Master, slave and car number are never in the INI: like the arcade and the
recomp, the game decides them from its own settings (step 5).

**Starting a linked race:**

1. **Start the MASTER cabinet first**: load Daytona on it (and start `m2link`
   on it, if it is a MiSTer that doesn't start it at boot).
2. **Then start each SLAVE**, the same way.
3. Each says **NETWORK CHECKING** until every cabinet is there, then the
   linked attract (通信システム). Insert coins and race.

**If a cabinet drops out, or shows CANCELLED:** bring the **master** back up
first (reset Daytona on it, and restart `m2link` on it if you stopped it),
**then** reset each slave. A link that is lost does not come back by itself.

**Reading `/tmp/m2link.log`** (over ssh, or `cat` from a terminal) tells you
what `m2link` is doing:

* `waiting for the Model 2 core with Link board On in its OSD` — load
  Daytona, Link board On.
* `on (the game has not started the link: set LINK ID in test mode)` — LINK
  ID is SINGLE: set MASTER or SLAVE.
* `waiting: next cabinet ... not reached yet` — that cabinet isn't up, its
  `link_port` is different, or a firewall is in the way. `... no cabinet has
  connected to port ...` — the cabinet *before* this one hasn't reached it.
* `link_next is still the example's placeholder` — step 2.
* `linked: cabinet 1 of 2` — working.
* `lost (reset the game to try again)` — see above.

**Keeping the cabinets in step: `link_framesync`.** By default (0, as on the
recomp) each cabinet runs at its own pace and takes the others' cars as they
come; over a long race the cabinets slowly drift apart, exactly as the recomp
does. Set `link_framesync = 1` on **every** cabinet — in each MiSTer's
`m2link.ini`, and on each PC by ticking **Frame sync (every cabinet waits for
the master)** in the recomp's Game tab — and every cabinet waits each frame
for the master, so they stay together. A MiSTer then holds its game for the
moment it waits (picture and sound carry on).

**Example: a MiSTer and a PC.** MiSTer at 192.168.1.62, PC at 192.168.1.20.

* MiSTer `m2link.ini`: `link_port = 15112`, `link_next = 192.168.1.20:15112`.
* PC (recomp launcher, Game tab): **Link to other cabinets** ticked, **This
  cabinet's port** 15112, **Next cabinet** `192.168.1.62:15112`.
* One of them MASTER in test mode, the other SLAVE, different car numbers.
  Start the master first.

Three or more: each cabinet's `link_next` is the next one round the circle,
and the last one's is the first.

**Not linking at all?** A cabinet set to TWIN in test mode with nobody to link
to waits at NETWORK CHECKING for ever — the factory setting does this, with or
without the link board. For one player, set LINK ID to SINGLE. Link board Off
in the OSD is exactly the core without link play.
