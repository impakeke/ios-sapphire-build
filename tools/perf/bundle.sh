#!/bin/sh
# bundle.sh NOMBRE: instala en el teléfono el HakiosMetal de rebuild/out/NOMBRE.
# Instala por renombrado (archivo nuevo + mv): copiar encima del archivo ya cargado conserva en el vnode la firma del
# primer binario y dyld rechaza cualquier binario mayor; Metal se queda sin driver y CoreAnimation compone por software.
# No reinicia backboardd (lo hace ab.sh o `killall backboardd`). Tras reiniciarlo, comprobar con driver-en-uso.sh que
# backboardd es cliente de SapphireGPU.
B=/System/Library/Extensions/HakiosMetal.bundle
gzip -1 -c ~/sapphire-angel/research/metal/rebuild/out/$1/HakiosMetal | ssh -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=4 sapphire "/var/jb/usr/bin/gunzip -c > /var/tmp/HakiosMetal.new" &&
[ "$(shasum -a 256 ~/sapphire-angel/research/metal/rebuild/out/$1/HakiosMetal | cut -c1-16)" = "$(ssh sapphire "/var/jb/usr/bin/sha256sum /var/tmp/HakiosMetal.new" | cut -c1-16)" ] &&
ssh sapphire "export PATH=/var/jb/usr/bin:/var/jb/bin:\$PATH; cp /var/tmp/HakiosMetal.new $B/HakiosMetal.tmp && chmod 755 $B/HakiosMetal.tmp && mv -f $B/HakiosMetal.tmp $B/HakiosMetal && rm /var/tmp/HakiosMetal.new && sha256sum $B/HakiosMetal | cut -c1-16"
