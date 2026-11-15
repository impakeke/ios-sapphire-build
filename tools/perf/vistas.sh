#!/bin/sh
# vistas.sh NOMBRE: captura home, vista de widgets, Centro de Control y selector de apps (buffer 0 de cada una)
# y hace una hoja de contacto shots/hoja-vistas-NOMBRE.png. No reinicia nada.
D=~/sapphire-angel/research/metal/medicion
S() { ssh sapphire "H=/var/root/hidtouch; $*"; }
S '/var/root/scr2 | grep -q "^off" && { $H press 0; sleep 1; $H swipe 0.5 0.995 0.5 0.3 250; sleep 1.5; }; $H press 3; sleep 1.2; $H press 3; sleep 2.5'
$D/shot.sh v-$1-home
S '$H swipe 0.15 0.5 0.85 0.5 250; sleep 3'
$D/shot.sh v-$1-hoy
S '$H press 3; sleep 1.5; $H swipe 0.92 0.003 0.92 0.65 300; sleep 3'
$D/shot.sh v-$1-cc
S '$H tap 0.5 0.92; sleep 1.5; $H press 3; sleep 1.5; $H swipe 0.5 0.995 0.5 0.55 700; sleep 3'
$D/shot.sh v-$1-rec
S '$H press 3; sleep 1'
python3 $D/sheet.py $D/shots/hoja-vistas-$1.png v-$1-home v-$1-hoy v-$1-cc v-$1-rec
sips -Z 1100 $D/shots/hoja-vistas-$1.png --out $D/shots/hoja-vistas-$1-m.png >/dev/null
