#!/bin/sh
# watch-new.sh: termina (y así despierta al coordinador) cuando hay un HakiosMetal nuevo o cambiado en rebuild/out,
# un parche nuevo de los agentes del kernel, o el teléfono aparece (iOS, fastboot o adb).
O=~/sapphire-angel/research/metal
snap() { ls -l $O/rebuild/out/*/HakiosMetal $O/relojes/parches-nuevos/*.patch $O/display/parches-nuevos/*.patch ~/sapphire-angel/research/metal/hilos/*.patch 2>/dev/null | awk '{print $5,$6,$7,$8,$9}'; }
B=$(snap)
P0=$1
while :; do
  [ "$(snap)" != "$B" ] && { echo NUEVO; snap | tail -5; exit 0; }
  if [ "$P0" = phone ]; then
    ping -c1 -t1 192.168.7.2 >/dev/null 2>&1 && { echo TELEFONO_IOS; exit 0; }
    adb devices 2>/dev/null | grep -q "device$" && { echo TELEFONO_ADB; exit 0; }
    ioreg -r -c IOUSBHostInterface -w0 | grep -q 'fastboot@0' && { echo TELEFONO_FASTBOOT; exit 0; }
    ioreg -r -c IOUSBHostDevice -l -w0 | grep -q -i -E '"idVendor" = (10007|6353|1478|8921)' && { echo TELEFONO_USB_ANDROID; exit 0; }
  fi
  sleep 15
done
