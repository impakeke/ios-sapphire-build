#!/bin/sh
# shot.sh NOMBRE: captura la pantalla del teléfono (las dos superficies del doble buffer) en shots/NOMBRE-{0,1}.png
D=~/sapphire-angel/research/metal/medicion
ssh sapphire '/var/root/fbshot /var/tmp/fb >/dev/null' && for n in 0 1; do scp -q sapphire:/var/tmp/fb-$n.raw $D/shots/$1-$n.raw && python3 $D/raw2png.py $D/shots/$1-$n.raw $D/shots/$1-$n.png 750 1624 && sips -Z 500 $D/shots/$1-$n.png --out $D/shots/$1-$n-s.png >/dev/null; rm -f $D/shots/$1-$n.raw; done
