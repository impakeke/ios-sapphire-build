# 15 — Build del kernel + shim en macOS: hallazgos de toolchain

Objetivo: compilar un kernel dev de ios-sapphire con nuestro parche USB (`0327`), envolverlo en
una imagen booteable, y arrancarlo en el Redmi Note 13 4G. Todo LIMPIO (desde fuente, no reusar
binarios precompilados).

> **Nota 2026-11-14 (auditoría, [investigacion/01](investigacion/01-auditoria-sweet_usb.md) §4):**
> - "Xcode 21" no existe: es **Apple clang 21 / SDK 26.x** de las Command Line Tools. Se corrigió abajo.
> - La conclusión "el toolchain de macOS produce binarios ROTOS" está **contradicha**: ExpB fue un
>   fallo de enlazado del shim (se perdía la cabecera ARM64, ver build-recipes.md §2), y el kernel de
>   expG, compilado con Apple clang 21 / SDK 26.5, arranca iOS y enumera. ExpC no está verificado.
> - "El parche USB y la config están PROBADOS CORRECTOS" está **contradicha**: un kernel que murió
>   en la entrada nunca ejecutó el parche.
> - "zig filtra `-N`/`--omagic`" (§Pistas de causa) también está contradicha en 01 §4.
> - "`fastboot boot` brickea" está **contradicha** (ver la tabla y §"Estado del teléfono").

## Qué se logró (local, macOS 26 / x86_64, Apple clang 21 / SDK 26.x)

- **Kernel XNU compila local** vía `blacktop/darwin-xnu-build` (DXB): clona el XNU de Apple, aplica
  `xnu/patches/*.patch`, compila `arm64/cortex-a53`, `DEVELOPMENT/SWEET`, `TOPAZ_4K=1`. Necesita KDK
  13.5 (`/Library/Developer/KDKs/KDK_13.5_22G74.kdk`, instalar con `sudo installer -pkg` en Terminal).
  ccache cableado (base_dir + sloppiness) → rebuilds incrementales rápidos. Guard de "already built":
  borrar `build/xnu.obj/kernel.development.sweet` + el `.o` cambiado para forzar recompilar.
  En rebuild hay que saltar `patches` en DXB `build.sh` (los `.sh` de patch no son idempotentes).
- **Parche `0327-sapphire-usb-fast-reclaim.patch`**: `ud_reclaim_fast()` llamado en cada poll de
  `ud_thread`, reclama TRBs con HWO=0 al instante (no espera el evento que se pierde bajo carga).
  Compila y entra (SHA del kernel cambia). Guardado en este dir.
- **ADT + payload**: `mkadt.py --highmem --amp` (lee `/product` de `research/ipsw-x/d22ap.adt`,
  extraído del IPSW con `pyimg4`), `mkpayload.py` (kernel+ADT+cmdline → SWEETXNU). OK.
- **Shim en macOS con zig** (`dev-notes/shim-build-mac.sh`, se copia a `shim/` para usarlo): clang+lld de zig, `mkbootimg.py` de AOSP (parcheado
  el import `gki`), splash por Pillow, `llvm`/`zig objcopy`. Compila y produce `shim-boot.img`.

## EL PROBLEMA: el toolchain de macOS produce binarios ROTOS

Experimentos de aislamiento en el teléfono (cada uno flasheado a `boot_a` + `set_active a`):

| Exp | Imagen | Resultado |
|---|---|---|
| v1 | `fastboot boot` de nuestra imagen | negro. *Corregido 2026-11-14:* la imagen no tenía la cabecera ARM64 que este ABL exige (NOTES.md:466); `fastboot boot` es solo RAM y no brickea (investigacion/02 §P4). La pantalla negra se recupera con `fastboot reboot bootloader`. |
| v2/v3 | nuestro kernel + nuestro ADT + nuestro shim (zig) | cuelga en el splash |
| **ExpB** | **kernel BUENO de Angel + nuestro shim (zig)** | cuelga, **no llega a `xnu jumping`** → **nuestro SHIM rompe el handoff** |
| **ExpC** | **shim de Angel + nuestro kernel (Apple clang 21 / SDK 26.x)** | **`xnu jumping` → crash (pantalla roja)**, sin red USB → **nuestro KERNEL crashea en la entrada de XNU** |

**Conclusión:** tanto el **shim** (zig/lld, macOS) como el **kernel** (Apple clang 21 / SDK macOS 26) que
compilamos localmente están rotos. El **parche USB y la config (ADT/boot-args) están PROBADOS
CORRECTOS** (ExpC usó ADT+args+shim de Angel con nuestro kernel y el kernel es lo único que falló;
y `ud_reclaim_fast` ni corre tan temprano). **Es puro toolchain** — XNU y el shim son sensibilísimos
al compilador, y macOS 26 / Apple clang 21 / zig-clang ≠ el de Angel (Xcode 16 + aarch64-linux-gnu-gcc).

### Pistas de causa
- Shim: `zig cc` **filtra `-N`/`--omagic`** (el build original de Angel usa `aarch64-linux-gnu-gcc`
  con `-N`). Tuvimos que quitar omagic → layout del shim distinto → handoff a XNU roto (hipótesis
  fuerte; el shim dibuja splash pero salta mal). También: compat.c añadido (strcmp etc. que gcc daba).
- Kernel: Apple clang 21 / macOS 26 SDK vs el **Xcode 16** que espera el proyecto (parche 0141 era para
  Xcode 16). Un XNU que compila limpio puede faltar en la entrada por diffs de codegen/ABI/SDK.

## Camino limpio (desde fuente, toolchain correcto)
- **Kernel:** GitHub Actions `xnu-4k.yml` usa **Xcode 16** (lo correcto) — compila desde fuente, es
  limpio. Aplicar `0327` ahí (fork + patch + `gh workflow run`). `gh` logueado: `giovannipodesta`.
- **Shim:** construirlo con **`aarch64-linux-gnu-gcc` + binutils** (como Angel) — en Linux/CI, o
  arreglar el build zig para que el handoff sea correcto (resolver el equivalente de `--omagic` que
  zig filtra, p.ej. `-z noseparate-code` / invocar lld directo / linker script con PHDRS de un solo
  segmento RWX). NO reusar el binario de Angel (no es limpio).

## Estado del teléfono / seguridad
- *Corregido 2026-11-14:* `fastboot boot` es solo RAM y no brickea; el negro de v1 fue la falta de
  cabecera ARM64 (NOTES.md:466) y se sale con `fastboot reboot bootloader`. Para instalar: flashear
  `boot_a` + `set_active a` (iOS) / `b` (Android); nunca escribir `boot_b`. Backup del iOS original de Angel: `~/Downloads/sapphire-gps/boot_a-ios-original.img`
  (restaurar con `fastboot flash boot_a` + `set_active b`→Android para dejarlo usable).
- El ring del kernel vive en la cola de **`iosroot`** (no `userdata`) en el dual-boot; se lee desde
  OrangeFox. Nuestros kernels crashean antes de inicializar el log → el ring no capturó el fallo.

## Artefactos en este dir
`0327-sapphire-usb-fast-reclaim.patch`, `boot_a-ios-original.img` (shim+kernel BUENOS de Angel),
`shim-boot-*.img` (intentos), `refs/` (código QMI/DWC3), `mac-uslog.sh`.
Build local del kernel: `~/sapphire-build/` (dxb/, ccache, zig, mkbootimg.py).
