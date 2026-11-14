#!/bin/zsh
# Bucle experimental automático para sapphire/iOS (Hackintosh: fastboot vía fbusb, shell vía nc 2323).
# Uso: exp-loop.sh <etiqueta> <rutas> [timeout_s]
#   rutas: secuencia de R (set_active a + reboot normal) y C (set_active a + fastboot continue), p.ej. "RCRCRC"
# Requisito: boot_a ya flasheado con la imagen a probar, con sweet_reboot=2 (todo reinicio vuelve a fastboot).
# Salida: ~/sapphire-angel/logs/<etiqueta>-<fecha>/{resultados.csv, ensayo-N.txt}
TAG=${1:?etiqueta}; SEQ=${2:?rutas}; TMO=${3:-180}
D=~/sapphire-angel/logs/$TAG-$(date +%Y%m%d-%H%M%S); mkdir -p $D
CSV=$D/resultados.csv; echo "ensayo,ruta,inicio,resultado,segundos,detalle" > $CSV
FB=~/adb-bridge/fbusb

fb_up()   { ioreg -r -c IOUSBHostInterface -w0 | grep -q 'fastboot@0'; }
ios_up()  { ioreg -r -c IOUSBHostDevice -l -w0 | grep -q '"idVendor" = 4617' && ping -c1 -t2 192.168.7.2 >/dev/null 2>&1; }
sh2323()  { print -r -- "$1; exit" | nc -w ${2:-40} 192.168.7.2 2323 2>&1 | grep -vE 'job control|process group|tcsetattr|^bash-[0-9.]+# exit$'; }

to_fastboot() {   # deja el teléfono en fastboot; 0 si lo logra
	fb_up && return 0
	if ios_up; then
		sh2323 'sysctl -w kern.sweet_reboot_mode=2 >/dev/null; sync; reboot' 10 >/dev/null
	fi
	for i in $(seq 1 60); do fb_up && { sleep 2; return 0; }; sleep 3; done
	return 1
}

n=0
for r in ${(s::)SEQ}; do
	n=$((n+1))
	if ! to_fastboot; then echo "$n,$r,$(date +%H:%M:%S),SIN_FASTBOOT,0,necesita al usuario" >> $CSV; echo "ensayo $n: no pude llegar a fastboot"; break; fi
	t0=$(date +%s); hora=$(date +%H:%M:%S)
	case $r in
		R) $FB set_active:a reboot > $D/ensayo-$n-fb.txt 2>&1 ;;
		C) $FB set_active:a continue > $D/ensayo-$n-fb.txt 2>&1 ;;
		*) echo "ruta desconocida $r"; continue ;;
	esac
	sleep 15   # dejar que el teléfono salga de fastboot
	res=TIMEOUT; det=""
	while (( $(date +%s) - t0 < TMO )); do
		if ios_up; then res=ENUMERA; break; fi
		if fb_up; then res=VOLVIO_A_FASTBOOT; det="panic o reinicio (sweet_reboot=2)"; break; fi
		sleep 3
	done
	secs=$(( $(date +%s) - t0 ))
	if [[ $res == ENUMERA ]]; then
		sleep 20   # que el ring tenga el arranque volcado (ufslogsecs=1) y la shell esté estable
		sh2323 'uname -v; sysctl -n kern.boottime; sysctl kern.sweet_usb_stats; dd if=/dev/ufsroot0 bs=4096 skip=67107839 count=1025 2>/dev/null | tr -c "[:print:]" "\n" | grep -E "utmipipe|SWEET USB: (DWC3 GSNP|DWC3 DCFG|soft|ep0|endpoint|VBUS|address)|Darwin Kernel Version" | tail -12' 60 > $D/ensayo-$n.txt
		sh2323 'sysctl kern.sweet_usb_dp | head -1' 20 >> $D/ensayo-$n.txt
		det="ssh_auto=NO"; for k in $(seq 1 12); do ssh -o ConnectTimeout=5 -o BatchMode=yes sapphire true 2>/dev/null && { det="ssh_auto=si(${k}x5s)"; break; }; sleep 5; done
		det="$det $(grep -o 'dp [0-9]' $D/ensayo-$n.txt | head -1 | tr ' ' '=')"
		grep -q 'ep0 cmd' $D/ensayo-$n.txt && det="$det ep0-timeout"
		det="$det $(grep -o 'GCTL 0x[0-9a-f]*' $D/ensayo-$n.txt | head -1)"
	fi
	echo "$n,$r,$hora,$res,$secs,$det" >> $CSV
	echo "ensayo $n ruta $r: $res en ${secs}s $det"
	[[ $res == TIMEOUT ]] && { echo "timeout sin USB ni fastboot: se detiene (necesita al usuario)"; break; }
done
echo "== $CSV"; cat $CSV
