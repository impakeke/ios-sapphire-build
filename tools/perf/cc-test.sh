#!/bin/sh
# cc-test.sh BUNDLE DIRDESTINO NOMBRE="args" [NOMBRE="args"...]: instala BUNDLE y, por cada condición, pone
# /var/tmp/metal.args, reinicia backboardd, abre y cierra el Centro de Control una vez y captura 3 trazas de 45
# command buffers de aperturas; deja las trazas en ios-graficos/trace/DIRDESTINO/NOMBRE/ y una captura de pantalla.
D=~/sapphire-angel/research/metal/medicion; T=~/sapphire-angel/research/metal/ios-graficos/trace
S() { ssh -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=6 sapphire "export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:\$PATH; $*"; }
B=$1; DIR=$2; shift 2
$D/bundle.sh $B | head -1
S 'sysctl -w kern.sweet_gpu_khz=820000 >/dev/null; sysctl kern.sweet_thermal | grep -o "gpu [0-9]*"'
for kv in "$@"; do
  c=${kv%%=*}; a=${kv#*=}
  S "printf '%s\n' '$a' > /var/tmp/metal.args; rm -f /var/tmp/metal-trace-*.txt; killall backboardd; sleep 38; H=/var/root/hidtouch; /var/root/scr2 | grep -q '^off' && { \$H press 0; sleep 1; }; \$H swipe 0.5 0.995 0.5 0.3 250; sleep 1.5; \$H press 3; sleep 1.5; \$H press 3; sleep 2; \$H swipe 0.92 0.003 0.92 0.65 300; sleep 3; \$H tap 0.5 0.92; sleep 2.5; for n in 1 2 3; do echo 45 > /var/tmp/metal.trace; sleep 0.3; \$H swipe 0.92 0.003 0.92 0.65 300; sleep 3; \$H tap 0.5 0.92; sleep 2.5; done; \$H swipe 0.92 0.003 0.92 0.65 300; sleep 3; /var/root/fbshot /var/tmp/fb >/dev/null; \$H tap 0.5 0.92; sleep 1"
  mkdir -p $T/$DIR/$c
  for f in $(S 'ls /var/tmp/metal-trace-*.txt' 2>/dev/null); do $D/traer.sh $f $T/$DIR/$c/$(basename $f); done
  $D/traer.sh /var/tmp/fb-0.raw $D/shots/cc-$DIR-$c.raw && python3 $D/raw2png.py $D/shots/cc-$DIR-$c.raw $D/shots/cc-$DIR-$c.png 750 1624 && rm $D/shots/cc-$DIR-$c.raw
  echo "$c: $(ls $T/$DIR/$c | wc -l | tr -d ' ') trazas"
done
S 'rm -f /var/tmp/metal-trace-*.txt /var/tmp/metal.trace; printf "" > /var/tmp/metal.args; sysctl kern.sweet_thermal | grep -o "gpu [0-9]*"'
echo FIN
