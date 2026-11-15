#!/var/jb/bin/bash
# homeswipe.sh N (en el teléfono): despierta y desbloquea si hace falta, va a la primera página del home y hace N rondas de
# (página a la izquierda, página a la derecha) con hidtouch. Verificado con capturas (tools/perf/shot.sh).
H=/var/root/hidtouch
N=${1:-8}
if /var/root/scr2 | grep -q '^off'; then $H press 0; sleep 1; fi
$H swipe 0.5 0.995 0.5 0.3 250; sleep 1.5        # desbloquea (o va al home si ya estaba dentro)
$H swipe 0.5 0.995 0.5 0.3 250; sleep 1.2
$H press 3; sleep 1.0; $H press 3; sleep 1.2      # botón home dos veces: primera página del home
echo START
for i in $(seq $N); do
	$H swipe 0.85 0.5 0.15 0.5 200; sleep 0.7
	$H swipe 0.15 0.5 0.85 0.5 200; sleep 0.7
done
echo END
