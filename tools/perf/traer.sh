#!/bin/sh
# traer.sh RUTA_REMOTA DESTINO_LOCAL: trae un archivo del teléfono comprimido por ssh, con tiempo límite y reintento
# (las copias grandes por scp/sftp atascan a veces el enlace USB).
for i in 1 2 3; do
  ssh -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=4 sapphire "/var/jb/usr/bin/gzip -1 -c '$1'" > "$2.gz" 2>/dev/null && gunzip -f "$2.gz" && exit 0
  sleep 2
done
echo "traer.sh: no se pudo traer $1" >&2; exit 1
