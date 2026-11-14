#!/bin/sh
# bundle.sh NOMBRE: instala en el teléfono el HakiosMetal de rebuild/out/NOMBRE.
# Instala por renombrado (archivo nuevo + mv): copiar encima del archivo ya cargado conserva en el vnode la firma del
# primer binario y dyld rechaza cualquier binario mayor; Metal se queda sin driver y CoreAnimation compone por software.
# No reinicia backboardd (lo hace ab.sh o `killall backboardd`). Tras reiniciarlo, comprobar con driver-en-uso.sh que
# backboardd es cliente de SapphireGPU.
B=/System/Library/Extensions/HakiosMetal.bundle
scp -q ~/sapphire-angel/research/metal/rebuild/out/$1/HakiosMetal sapphire:/var/tmp/HakiosMetal.new &&
ssh sapphire "export PATH=/var/jb/usr/bin:/var/jb/bin:\$PATH; cp /var/tmp/HakiosMetal.new $B/HakiosMetal.tmp && chmod 755 $B/HakiosMetal.tmp && mv -f $B/HakiosMetal.tmp $B/HakiosMetal && rm /var/tmp/HakiosMetal.new && sha256sum $B/HakiosMetal | cut -c1-16"
