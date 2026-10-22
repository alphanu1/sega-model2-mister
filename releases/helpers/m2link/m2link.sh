#!/bin/bash
# m2link -- link play for the Sega Model 2 core. Put this file in
# /media/fat/Scripts/ and run it from the MiSTer menu (Scripts): the first
# run starts m2link, the next one stops it. m2link itself is
# /media/fat/linux/m2link and reads /media/fat/linux/m2link.ini.
#
# To start it at every boot instead, add this line to
# /media/fat/linux/user-startup.sh:
#   /media/fat/linux/m2link -c /media/fat/linux/m2link.ini > /tmp/m2link.log 2>&1 &
# It waits quietly until the Model 2 core is loaded with Link board On.

BIN=/media/fat/linux/m2link
INI=/media/fat/linux/m2link.ini
LOG=/tmp/m2link.log

if pidof m2link > /dev/null; then
    killall m2link
    echo "m2link stopped."
    exit 0
fi
if [ ! -x "$BIN" ]; then
    echo "$BIN is missing (or not executable): copy m2link there first."
    exit 1
fi
if command -v setsid > /dev/null; then
    setsid "$BIN" -c "$INI" < /dev/null > "$LOG" 2>&1 &
else
    nohup "$BIN" -c "$INI" < /dev/null > "$LOG" 2>&1 &
fi
sleep 1
cat "$LOG"
echo
echo "m2link is running (its messages: $LOG). Run this script again to stop it."
