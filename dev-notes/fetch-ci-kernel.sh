#!/bin/bash
# Baja el kernel de una ejecución del workflow xnu-4k y comprueba que es de fiar.
#
#   dev-notes/fetch-ci-kernel.sh <run-id|latest> [dir-salida]
#
# 1. espera a que la ejecución termine (gh run watch) y exige conclusion=success;
# 2. guarda el log y exige "Applying patch: …0334-sapphire-ufs-raw-io-no-user-memcpy.patch".
#    darwin-xnu-build se salta EN SILENCIO (solo un [warning]) los parches que no
#    aplican, así que un "Skipping patch …$PATCH…" o la ausencia de la línea es un fallo;
#    los demás "Skipping patch" se listan como aviso (STRICT=1 los convierte en fallo);
# 3. gh run download del artefacto xnu-kernel-4k en un directorio nuevo y vacío;
# 4. shasum -a 256 -c SHA256SUMS, e imprime el LC_UUID del kernel.
#
# Variables: REPO (por defecto giovannipodesta/ios-sapphire), PATCH (0334-sapphire-ufs-raw-io-no-user-memcpy.patch),
#            STRICT=1, INTERVAL (segundos entre sondeos, 30).
# Salida por defecto: ~/sapphire-angel/ci-kernels/<run-id>/{artifact/,run.log}
# Después: dev-notes/repack-boot.py --base <buena> --kernel <dir>/artifact/kernel.development.sweet -o …
set -euo pipefail

REPO=${REPO:-giovannipodesta/ios-sapphire}
WORKFLOW=xnu-4k
ARTIFACT=xnu-kernel-4k
KERNEL=kernel.development.sweet
PATCH=${PATCH:-0338-sapphire-fb-hold-swap-experiment.patch}
INTERVAL=${INTERVAL:-30}

fail() { printf '\n\033[1;31m*** FALLO: %s ***\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\033[1m== %s\033[0m\n' "$*"; }

[ $# -ge 1 ] || { sed -n '2,20p' "$0"; exit 2; }
command -v gh >/dev/null || fail "falta gh"

RUN=$1
if [ "$RUN" = latest ]; then
	RUN=$(gh run list -R "$REPO" -w "$WORKFLOW" -L 1 --json databaseId -q '.[0].databaseId')
	[ -n "$RUN" ] || fail "no hay ejecuciones de $WORKFLOW en $REPO"
fi
[[ "$RUN" =~ ^[0-9]+$ ]] || fail "run id no válido: $RUN"

OUT=${2:-$HOME/sapphire-angel/ci-kernels/$RUN}
ART="$OUT/artifact"
LOG="$OUT/run.log"
if [ -e "$ART" ] && [ -n "$(ls -A "$ART" 2>/dev/null)" ]; then
	fail "$ART ya existe y no está vacío (bórralo o usa otro dir-salida)"
fi
mkdir -p "$OUT"

info() { gh run view "$RUN" -R "$REPO" --json "$1" -q ".$1"; }
WF=$(info workflowName)
[ "$WF" = "$WORKFLOW" ] || fail "la ejecución $RUN es del workflow '$WF', no de $WORKFLOW"
say "run $RUN ($REPO) rama $(info headBranch) commit $(info headSha)  $(info url)"

# 1. esperar
if [ "$(info status)" != completed ]; then
	say "esperando a que termine (sondeo cada ${INTERVAL}s)…"
	gh run watch "$RUN" -R "$REPO" --interval "$INTERVAL" --exit-status >/dev/null || true
fi
while [ "$(info status)" != completed ]; do sleep "$INTERVAL"; done
CONC=$(info conclusion)
[ "$CONC" = success ] || fail "la ejecución $RUN terminó con conclusion=$CONC (¿cancelada por otro dispatch? concurrency cancel-in-progress)"
say "terminada: success"

# 2. log y parche esperado ($PATCH)
gh run view "$RUN" -R "$REPO" --log > "$LOG.raw" || fail "no se pudo bajar el log"
# quitar los colores de darwin-xnu-build (running/warning usan echo -e con ESC[..m)
sed $'s/\x1b\\[[0-9;]*m//g' "$LOG.raw" > "$LOG" && rm -f "$LOG.raw"
say "log en $LOG ($(wc -l < "$LOG" | tr -d ' ') líneas)"

if grep -F "Skipping patch" "$LOG" | grep -qF "$PATCH"; then
	grep -F "Skipping patch" "$LOG" | grep -F "$PATCH" >&2
	fail "darwin-xnu-build SE SALTÓ $PATCH: el kernel NO lleva ese parche. No lo flashees."
fi
APPLIED=$(grep -F "Applying patch:" "$LOG" | grep -F "/$PATCH" || true)
[ -n "$APPLIED" ] || fail "el log no dice 'Applying patch: …/$PATCH' (¿el parche no está en xnu/patches de ese commit?)"
say "OK parche aplicado: $(printf '%s' "$APPLIED" | sed 's/.*Applying patch: //' | head -1)"
NAPPLIED=$(grep -cF "Applying patch:" "$LOG" || true)
SKIPPED=$(grep -F "Skipping patch" "$LOG" | sed 's/.*Skipping patch /  /; s/ (already upstream.*//' || true)
say "parches aplicados: $NAPPLIED"
if [ -n "$SKIPPED" ]; then
	printf '\033[1;33mAVISO: parches saltados por darwin-xnu-build:\n%s\033[0m\n' "$SKIPPED" >&2
	[ "${STRICT:-0}" = 1 ] && fail "STRICT=1 y hay parches saltados"
fi

# 3. artefacto
mkdir -p "$ART"
gh run download "$RUN" -R "$REPO" -n "$ARTIFACT" -D "$ART" || fail "gh run download falló"
[ -f "$ART/$KERNEL" ] || fail "el artefacto no trae $KERNEL ($(ls "$ART" | tr '\n' ' '))"
[ -f "$ART/SHA256SUMS" ] || fail "el artefacto no trae SHA256SUMS"

# 4. sumas
grep -qE "[[:space:]]\*?(\./)?$KERNEL\$" "$ART/SHA256SUMS" || fail "SHA256SUMS no lista $KERNEL"
(cd "$ART" && shasum -a 256 -c SHA256SUMS) || fail "SHA256SUMS no cuadra"
UUID=$(python3 -I - "$ART/$KERNEL" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
assert struct.unpack_from('<I', b, 0)[0] == 0xfeedfacf, 'no es Mach-O 64'
off = 32
for _ in range(struct.unpack_from('<I', b, 16)[0]):
    cmd, size = struct.unpack_from('<II', b, off)
    if cmd == 0x1b:
        h = b[off + 8:off + 24].hex().upper()
        print(f'{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}')
        break
    off += size
PY
) || fail "$KERNEL no es un Mach-O válido"

say "OK $ART/$KERNEL"
echo "   sha256 $(shasum -a 256 "$ART/$KERNEL" | cut -d' ' -f1)"
echo "   LC_UUID $UUID"
echo
echo "siguiente paso:"
echo "  python3 $(cd "$(dirname "$0")" && pwd)/repack-boot.py --base <boot_a buena> --kernel $ART/$KERNEL -o <salida.img>"
