#!/var/jb/bin/bash
# ab-phone.sh ETIQUETA "ARGS" ["PROCESOS A CONGELAR"]: escribe /var/tmp/metal.args (metal_fps=1 + ARGS), reinicia
# backboardd, espera, captura la consola durante homeswipe.sh 8 y deja /var/tmp/ab-ETIQUETA.txt (consola), .fb (lineas
# SWEET FB) y .cpu (CPU por proceso y por nucleo durante la prueba). Los procesos del tercer argumento reciben SIGSTOP
# durante la prueba y SIGCONT al acabar.
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
L=$1; A=$2; STOP=$3
printf 'metal_fps=1 %s\n' "$A" > /var/tmp/metal.args
killall backboardd; sleep 28
/var/jb/bin/bash /var/root/homeswipe.sh 1 >/dev/null; sleep 2   # desbloquea y calienta
for p in $STOP; do killall -STOP $p 2>/dev/null; done
rm -f /var/tmp/ab-$L.txt
/var/root/conscat /var/tmp/ab-$L.txt 34 &
sleep 1
( /var/root/cpuload > /var/tmp/ab-$L.load 2>&1 & )
/var/jb/bin/bash /var/root/cpuacct.sh 20 home > /var/tmp/ab-$L.cpu
wait
for p in $STOP; do killall -CONT $p 2>/dev/null; done
cat /var/tmp/ab-$L.load >> /var/tmp/ab-$L.cpu
dmesg | grep -a "SWEET FB: 5 s" | tail -8 > /var/tmp/ab-$L.fb
