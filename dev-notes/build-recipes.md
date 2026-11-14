# Build recipes — kernel, shim, empaquetado, flasheo

Todo **desde fuente, limpio**, para compilar en local. Probado en macOS 26 / x86_64 con Apple clang 21 /
SDK 26.x de las Command Line Tools. El kernel que corre el teléfono se compila normalmente en CI
(`OPERACION.md` §4); estas recetas son para iterar en local. En otra máquina ajusta rutas. Lo que no va
al repo (pesado o de terceros: IPSW, KDK, zig, binarios de Angel) está en `continuar-en-otra-maquina.md`.

## 1) Kernel XNU (dev) con nuestros parches — vía darwin-xnu-build (DXB)

DXB = `blacktop/darwin-xnu-build`: clona el XNU de Apple, aplica `xnu/patches/*.patch`
(toda la serie del port), compila `arm64/cortex-a53`,
`DEVELOPMENT/SWEET`, `TOPAZ_4K=1`.

Requisitos:
- **Apple clang 21 / SDK 26.x** (Command Line Tools) o Xcode 16; el proyecto nació con 16 y el CI
  (`xnu-4k.yml`, macos-15) usa Xcode 16.0 (16A242d). Un kernel compilado en local con Apple clang 21 /
  SDK 26.5 (el de la imagen expG) arranca iOS y enumera el USB.
  Observación sin repetir (n=1, octubre): el shim de Angel con un kernel local anterior llegó a
  `xnu jumping` y terminó en pantalla roja; no se sabe si fue el compilador o el kernel.
- **KDK 13.5** → `/Library/Developer/KDKs/KDK_13.5_22G74.kdk`
  (instalar con `sudo installer -pkg KDK_13.5_22G74.dmg/*.pkg -target /` en Terminal).
- **ccache** (rebuilds incrementales rápidos): cableado con `base_dir` + sloppiness.

Primera compilación (limpia, aplica todos los parches):
```sh
cd ~/sapphire-build/dxb
./build.sh           # aplica patches/*.sh + *.patch, compila kernel.development.sweet
```

**Rebuild tras editar un .c** (p.ej. `bsd/dev/sweet_usb.c`):
```sh
# 1) saltar 'patches' en build.sh (los *.sh de patch NO son idempotentes):
#    comenta la llamada a `patches` en main() de ~/sapphire-build/dxb/build.sh
# 2) forzar recompilar: borrar el kernel y el .o cambiado (guard "already built"):
rm -f build/xnu.obj/DEVELOPMENT_ARM64_SWEET/bsd/DEVELOPMENT/sweet_usb.o \
      fakeroot/System/Library/Kernels/kernel.development.sweet
# 3) compilar:
CC="ccache clang" CXX="ccache clang++" ./build.sh
```
Resultado: `fakeroot/System/Library/Kernels/kernel.development.sweet`. Verifica que
el SHA cambió (`shasum -a 256`) y que `sweet_usb.o` se recompiló.

> Editar directamente `~/sapphire-build/dxb/xnu/bsd/dev/sweet_usb.c` **persiste** entre
> rebuilds mientras no vuelvas a correr `patches`. Para generar un patch limpio de tus
> cambios: revertir las ediciones en una copia y `diff -u` (así se hizo 0328).

## 2) Shim en macOS — zig "Recipe C"  (`dev-notes/shim-build-mac.sh`)

El shim arranca XNU (ABL → BootShim → XNU). El build original de Angel usa
`aarch64-linux-gnu-gcc`. En macOS lo portamos a **zig cc** (clang+lld 0.13.0).

**Las claves que lo hacen bootear:**
- `-target aarch64-freestanding-none`, `-mcpu=generic+el3-neon-fp_armv8`
  (sin NEON, con el3), `-mgeneral-regs-only -mstrict-align -fno-jump-tables`.
- Enlazar con **`-Wl,-e,_head -Wl,--no-gc-sections`**: si no, la GC tira
  `.text.head`/`_head` y se pierde el **magic ARM\x64 @ offset 56** y el
  `image_size @ 16` → el ABL no arranca la imagen o el handoff a XNU se rompe.
- `out/compat.c` con `strcmp/strncmp/strlen/memcmp` (gcc los daba, zig no).
- `zig objcopy -O binary`, truncar a `_end`, padding 4K, **append del payload**,
  escribir `image_size` (u64 @ 16) = tamaño final, y `mkbootimg.py` v4.

Correr:
```sh
# el script hace `cd "$(dirname "$0")"` y espera las fuentes del shim al lado: copiarlo a shim/
cp dev-notes/shim-build-mac.sh shim/build-mac.sh
cd shim
bash build-mac.sh out/payload.bin   # payload = salida de mkpayload (paso 3)
# GATES deben dar OK: magic@56 == 41524d64 (ARM\x64) y image_size@16 == filesize
```
El script está en `dev-notes/shim-build-mac.sh` (no existe `shim/build-mac.sh` en el repo).

## 3) Empaquetado — ADT + payload (tools del repo)

```sh
# ADT (una vez): lee /product de research/ipsw-x/d22ap.adt (extraído del IPSW con pyimg4)
python3 tools/mkadt.py --highmem --amp  -o angel.adt      # 8 cores / TOPAZ_4K
# payload SWEETXNU = header + ADT + cmdline + segmentos del kernel
python3 tools/mkpayload.py \
   ~/sapphire-build/dxb/fakeroot/System/Library/Kernels/kernel.development.sweet \
   angel.adt  shim/out/payload.bin  --cmdline "$(cat angel.cmdline)"
```
`angel.cmdline` lleva los boot-args correctos (incluye `sweetusb=…`, `sweetlog=1`, etc.).
Guárdalo junto al ADT.

## 4) Flasheo + boot

`fastboot boot img` es solo RAM (`CmdBoot` = `CmdContinue`, investigacion/02 §P4) y sirve para probar
un kernel sin tocar flash. Este ABL solo arranca imágenes v4 con la cabecera ARM64 (magic `ARM\x64`
@56, ver las puertas de la receta 2); sin ella la pantalla queda negra y `fastboot reboot bootloader`
la recupera (uefi/README.md). Para dejarlo instalado, respaldar y flashear `boot_a`. Nunca escribir
`boot_b` (Android). Para cambiar solo el kernel de una imagen buena, `repack-boot.py`
(OPERACION.md §4.3) es más corto que estas recetas.

```sh
# el teléfono en fastboot; respaldar boot_a antes. En la Hackintosh: ~/adb-bridge/fbusb (OPERACION.md §1).
fastboot flash boot_a shim/out/shim-boot.img
fastboot set_active a        # slot a = iOS ; slot b = Android
fastboot reboot
```
Restaurar Android usable: `fastboot set_active b` + reboot.
Restaurar iOS original de Angel: `fastboot flash boot_a <backup> && fastboot set_active a`.

## 5) Verificar enumeración USB en el Mac
`system_profiler SPUSBDataType` no devuelve nada en la Hackintosh del fork.
Usa **`ioreg`**:
```sh
ioreg -rc IOUSBHostDevice -l -w 0 | grep -A3 '"idVendor" = 4617'   # 4617 = 0x1209
ifconfig -l | tr ' ' '\n' | grep '^en'                             # enX nueva = CDC-ECM
```
