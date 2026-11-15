#!/bin/zsh
# Observa el arranque de iOS en sapphire desde esta Mac: ¿enumera el gadget CDC-ECM (1209:0001)?
# Uso: watch-ios-usb.sh <etiqueta> [segundos]   -> deja todo en ~/sapphire-angel/logs/<etiqueta>-*/
TAG=${1:-run}; SECS=${2:-600}
D=~/sapphire-angel/logs/$TAG-$(date +%Y%m%d-%H%M%S); mkdir -p $D
echo "logs en $D"
# 1) eventos USB del kernel (enumeraciones fallidas incluidas)
log stream --level debug --style compact \
  --predicate 'sender CONTAINS[c] "usb" OR subsystem CONTAINS[c] "usb" OR eventMessage CONTAINS[c] "1209" OR eventMessage CONTAINS[c] "ECM"' \
  > $D/kernel-usb.log 2>&1 &
LP=$!
IFS0=$(ifconfig -l)
found=0
for ((t=0; t<SECS; t+=2)); do
  if ioreg -r -c IOUSBHostDevice -l -w0 | grep -q '"idVendor" = 4617'; then
    [ $found = 0 ] && { echo "t=${t}s ENUMERA 1209"; ioreg -r -c IOUSBHostDevice -l -w0 | awk '/"idVendor" = 4617/{p=1} p' | head -60 > $D/ioreg-1209.txt; found=1; }
    NEW=$(comm -13 <(echo $IFS0 | tr ' ' '\n' | sort) <(ifconfig -l | tr ' ' '\n' | sort) | grep '^en' | head -1)
    if [ -n "$NEW" ]; then
      echo "t=${t}s interfaz nueva $NEW"; ifconfig $NEW > $D/ifconfig.txt
      echo "configurando 192.168.7.1 en $NEW (pide sudo)"
      sudo -n ifconfig $NEW inet 192.168.7.1/24 up 2>&1 || echo "sin sudo -n: ejecutar a mano: sudo ifconfig $NEW inet 192.168.7.1/24 up"
      sleep 2
      ping -c 5 -t 8 192.168.7.2 | tee $D/ping.txt
      (nc -u -l 5140 > $D/udp5140.log &) ; sleep 6
      echo 'uname -a; id; sysctl kern.sweet_usb_stats 2>/dev/null; ifconfig; exit' | nc -w 8 192.168.7.2 2323 | tee $D/shell2323.txt
      break
    fi
  fi
  sleep 2
done
[ $found = 0 ] && echo "no enumeró en ${SECS}s"
kill $LP 2>/dev/null
grep -iE 'enumerat|1209|ECM|port.*(fail|error)|not respond|overcurrent|reset' $D/kernel-usb.log | head -40
