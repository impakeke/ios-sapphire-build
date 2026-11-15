#!/bin/sh
# Read the SWEET console log (kernel patch 0047) from a phone booted into
# OrangeFox recovery (fastboot boot recovery/recovery.img; adb root shell).
#   tools/sweet-log-pull.sh OUT.txt
# Only reads: the last 1025 blocks (4 KiB) of the userdata partition. That is
# the ring only when the iOS root is userdata (no ufsroot= boot-arg). On the
# dual-boot layout the ring is at the end of iosroot (ufsroot=iosroot), and
# userdata is Android's: this script then reads the wrong partition.
set -eu
out=${1:?usage: sweet-log-pull.sh OUT.txt}
dev=$(adb shell 'for d in /dev/block/by-name/userdata /dev/block/bootdevice/by-name/userdata; do [ -e $d ] && readlink -f $d && break; done' | tr -d '\r')
[ -n "$dev" ] || { echo "userdata block device not found" >&2; exit 1; }
bytes=$(adb shell blockdev --getsize64 "$dev" | tr -d '\r')
skip=$((bytes / 4096 - 1025))
adb exec-out "dd if=$dev bs=4096 skip=$skip count=1025 2>/dev/null" > "$out.bin"
echo "$dev: $bytes bytes, read blocks $skip.. ($(stat -c %s "$out.bin") bytes)" >&2
python3 "$(dirname "$0")/sweet-log.py" "$out.bin" "$out"
