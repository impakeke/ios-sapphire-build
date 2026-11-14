#!/var/jb/bin/bash
# ab-phone.sh ETIQUETA "ARGS": escribe /var/tmp/metal.args (metal_fps=1 + ARGS), reinicia backboardd, espera,
# captura la consola durante swipetest.sh 5 y deja /var/tmp/ab-ETIQUETA.txt (consola) y .fb (lineas SWEET FB).
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
L=$1; A=$2
printf 'metal_fps=1 %s\n' "$A" > /var/tmp/metal.args
killall backboardd; sleep 28
/var/root/swipetest.sh 1 >/dev/null; sleep 3          # desbloquea y calienta
rm -f /var/tmp/ab-$L.txt
/var/root/conscat /var/tmp/ab-$L.txt 34 & 
sleep 1
T0=$(dmesg | tail -1 | sed -E 's/^\[ *([0-9]+)\..*/\1/')
/var/root/swipetest.sh 5 >/dev/null
T1=$(dmesg | tail -1 | sed -E 's/^\[ *([0-9]+)\..*/\1/')
wait
echo "T0=$T0 T1=$T1" > /var/tmp/ab-$L.fb
dmesg | grep -a "SWEET FB: 5 s" | tail -8 >> /var/tmp/ab-$L.fb
