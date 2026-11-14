#!/bin/sh
# glshot.sh BUNDLE NOMBRE: instala BUNDLE, reinicia backboardd, va a la Biblioteca de Apps y captura shots/NOMBRE-0.png
D=~/sapphire-angel/research/metal/medicion
$D/bundle.sh $1 >/dev/null
ssh sapphire 'export PATH=/var/jb/usr/bin:/var/jb/bin:$PATH; killall backboardd; sleep 26; H=/var/root/hidtouch; /var/root/scr2 | grep -q "^off" && { $H press 0; sleep 1; }; $H swipe 0.5 0.995 0.5 0.3 250; sleep 1.5; for i in 1 2 3 4 5; do $H swipe 0.85 0.5 0.15 0.5 200; sleep 0.9; done; sleep 1'
$D/shot.sh $2
sips -Z 560 $D/shots/$2-0.png --out $D/shots/$2-0-m.png >/dev/null
