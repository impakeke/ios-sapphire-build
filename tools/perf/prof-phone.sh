#!/var/jb/bin/bash
# prof-phone.sh: perfil psamp del hilo de render de backboardd durante homeswipe.sh 8 -> /tmp/ps.txt
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
BB=$(ps -axo pid,comm | grep libexec/backboardd | head -1 | awk '{print $1}')
/var/jb/bin/bash /var/root/homeswipe.sh 1 >/dev/null
/var/root/psamp $BB 20 display.primary /tmp/ps.txt 500 &
sleep 1
/var/jb/bin/bash /var/root/homeswipe.sh 8 >/dev/null
wait
