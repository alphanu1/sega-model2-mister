#!/bin/sh
# Force feedback test for any steering wheel MiSTer has force feedback for
# (Logitech G25/G27/G29, Fanatec, Thrustmaster..., or the HORI FFB Racing
# Wheel with hori-ffb). Shows the wheel it found, then plays weak effects
# (20% at most) and reports each one: PASS, FAIL or SKIP (not supported).
# Let go of the wheel: it will swing to its stops.
#
# Copy this script and ffb-wheel-test to /media/fat/Scripts, then run it from
# the Scripts menu. ffb-wheel-test comes from github.com/alphanu1/linux-hori.

T="$(dirname "$0")/ffb-wheel-test"
[ -x "$T" ] || T=/media/fat/linux/ffb-wheel-test
if [ ! -x "$T" ]; then
	echo "ffb-wheel-test not found: copy it next to this script."
	sleep 5
	exit 1
fi
echo "Force feedback test in 5 seconds. Let go of the wheel."
sleep 5
"$T"
echo
echo "Done."
sleep 15
