#!/bin/zsh
# Espera al teléfono; si está en fastboot -> OrangeFox (slot b); en recovery -> respalda boot_a.
cd ~/adb-bridge
OUT=~/sapphire-angel/backups; mkdir -p $OUT
have_fb() { ioreg -r -c IOUSBHostInterface -w0 | grep -q 'fastboot@0'; }
have_adb() { ioreg -r -c IOUSBHostInterface -l -w0 | awk '/"bInterfaceClass" = 255/{c=1} /"bInterfaceSubClass" = 66/{s=c} /"bInterfaceProtocol" = 1/{if(s)f=1} END{exit !f}'; }
for i in $(seq 1 450); do
  if have_fb; then echo "fastboot visto"; ./fbusb set_active:b reboot-recovery; sleep 20; fi
  if have_adb; then echo "adb visto"; break; fi
  sleep 2
done
have_adb || { echo "timeout sin teléfono"; exit 1; }
pkill -f 'adbbridge 6555'; sleep 1; (./adbbridge 6555 > bridge.log 2>&1 &); sleep 2
adb disconnect >/dev/null 2>&1; adb connect 127.0.0.1:6555; sleep 3
adb -s 127.0.0.1:6555 get-state || exit 1
TS=$(date +%Y%m%d-%H%M%S)
adb -s 127.0.0.1:6555 exec-out 'dd if=/dev/block/by-name/boot_a bs=1048576 2>/dev/null' > $OUT/boot_a-expG-$TS.img
ls -la $OUT/boot_a-expG-$TS.img; shasum -a 256 $OUT/boot_a-expG-$TS.img
echo "BACKUP=$OUT/boot_a-expG-$TS.img"
