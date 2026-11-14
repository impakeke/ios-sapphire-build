#!/bin/sh
# driver-en-uso.sh: (solo lectura) dice si el backboardd del teléfono tiene el driver dentro y cuál es.
# Con el driver cargado, el servicio SapphireGPU tiene un cliente creado por backboardd. Sin él, lo que se ve en la
# pantalla lo compone CoreAnimation por software y ni las capturas ni las medidas dicen nada del driver.
B=/System/Library/Extensions/HakiosMetal.bundle
ssh sapphire "export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/sbin:/usr/bin:/bin:\$PATH
c=\$(ioreg -c SapphireGPU -r -l | grep IOUserClientCreator)
echo \"\$c\" | grep -q backboardd && echo \"DRIVER EN USO: \$c\" || echo \"SIN DRIVER (CoreAnimation por software): clientes de SapphireGPU: \${c:-ninguno}\"
sha256sum $B/HakiosMetal | cut -c1-16"
for d in "$(dirname "$0")"/../out/*/; do
	[ -f "$d/HakiosMetal" ] && printf '   %s  %s\n' "$(shasum -a 256 "$d/HakiosMetal" | cut -c1-16)" "$(basename "$d")"
done
