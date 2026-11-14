#!/bin/sh
# ab.sh ETIQUETA "ARGS" (en la Mac): un ensayo A/B en el teléfono y su resumen.
D=~/sapphire-angel/research/metal/medicion
ssh sapphire "/var/jb/bin/bash /var/root/ab-phone.sh '$1' '$2'" && scp -q sapphire:/var/tmp/ab-$1.txt sapphire:/var/tmp/ab-$1.fb $D/ab/ && python3 $D/ab-sum.py $D/ab/ab-$1.txt
