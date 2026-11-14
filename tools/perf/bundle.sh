#!/bin/sh
# bundle.sh NOMBRE|angel: instala en el teléfono el HakiosMetal de rebuild/out/NOMBRE (o restaura el de Angel).
# El original queda una vez en HakiosMetal.angel. No reinicia backboardd (lo hace ab.sh o `killall backboardd`).
B=/System/Library/Extensions/HakiosMetal.bundle
if [ "$1" = angel ]; then
  ssh sapphire "export PATH=/var/jb/usr/bin:/var/jb/bin:\$PATH; cp $B/HakiosMetal.angel $B/HakiosMetal && chmod 755 $B/HakiosMetal && sha256sum $B/HakiosMetal | cut -c1-16"
else
  scp -q ~/sapphire-angel/research/metal/rebuild/out/$1/HakiosMetal sapphire:/var/tmp/HakiosMetal.new &&
  ssh sapphire "export PATH=/var/jb/usr/bin:/var/jb/bin:\$PATH; [ -f $B/HakiosMetal.angel ] || cp $B/HakiosMetal $B/HakiosMetal.angel; cp /var/tmp/HakiosMetal.new $B/HakiosMetal && chmod 755 $B/HakiosMetal && rm /var/tmp/HakiosMetal.new && sha256sum $B/HakiosMetal $B/HakiosMetal.angel | cut -c1-16"
fi
