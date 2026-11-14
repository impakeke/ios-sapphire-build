#!/var/jb/bin/bash
# cpuacct.sh SEGUNDOS [swipe]: CPU por proceso (delta de ps time) durante el intervalo, en reposo o con swipetest.
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
S=$1
snap() { ps -axo pid=,time=,comm= | awk '{split($2,t,":"); n=length(t); s=t[n]+60*t[n-1]+(n>2?3600*t[n-2]:0); c=$3; for(i=4;i<=NF;i++)c=c" "$i; print $1"\t"s"\t"c}'; }
snap > /tmp/ca.a
if [ "$2" = swipe ]; then /var/root/swipetest.sh 5 >/dev/null; elif [ "$2" = home ]; then /var/jb/bin/bash /var/root/homeswipe.sh 8 >/dev/null; else sleep $S; fi
snap > /tmp/ca.b
awk -F'\t' -v S=$S 'NR==FNR{a[$1]=$2;next} {d=$2-(($1 in a)?a[$1]:0); if(d>=0.05){n=$3; sub(/.*\//,"",n); printf "%7.2f s %5.1f%%  %s (%s)\n", d, 100*d/S, n, $1}; tot+=d} END{printf "TOTAL %.2f s = %.1f%% de un nucleo\n", tot, 100*tot/S}' /tmp/ca.a /tmp/ca.b | sort -k1 -nr | head -28
