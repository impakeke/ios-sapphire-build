# Continuar en otra computadora

Qué necesitas para retomar el development del port en otra máquina. El **código y
las notas viven en este repo**; los binarios pesados y de terceros **no** (ni deben),
así que aquí está cómo reconseguirlos.

## 0) Clonar
```sh
git clone https://github.com/giovannipodesta/ios-sapphire.git
cd ios-sapphire && git checkout sapphire
```
Lee `dev-notes/README.md` primero.

## 1) Host de build
- **macOS** con **Xcode 21** (o 16). El port nació con Xcode 16; Xcode 21 también
  compila (con los ajustes de toolchain-findings.md).
- `brew install ccache` (rebuilds rápidos del kernel).
- **adb/fastboot** (platform-tools) para flashear.

## 2) Descargas pesadas (NO están en git)
| Qué | De dónde | Dónde ponerlo |
|---|---|---|
| **IPSW** iPhone10,3 16.7.16 (20H392) | `ipsw.me` / Apple | `~/Downloads/iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw` |
| **KDK 13.5** (22G74) | developer.apple.com/download (More) | instalar → `/Library/Developer/KDKs/KDK_13.5_22G74.kdk` |
| **zig 0.13.0** (macos-x86_64) | ziglang.org/download | `~/sapphire-build/zig-macos-x86_64-0.13.0/zig` |
| **darwin-xnu-build** | github.com/blacktop/darwin-xnu-build | `~/sapphire-build/dxb` |
| **mkbootimg.py** (AOSP) | AOSP `system/tools/mkbootimg` | `~/sapphire-build/mkbootimg.py` (parchear el import `gki` con try/except) |

Del IPSW se extrae (con `pyimg4`) `research/ipsw-x/d22ap.adt` para `mkadt.py` —
ese `.adt` sí puede quedar en el repo si quieres (es pequeño); el IPSW no.

## 3) Reconstruir el entorno
```sh
# DXB: aplicar los patches del port (incluye 0327/0328) y compilar:
cd ~/sapphire-build/dxb && ./build.sh      # ver build-recipes.md para rebuilds
# shim con zig + empaquetado + flasheo: build-recipes.md pasos 2-4
```

## 4) Estado del teléfono (dual-boot) y backups
- Slots: **`boot_a` = iOS**, **`boot_b` = Android (GKI)**. `fastboot set_active a|b`.
- **`fastboot boot img` BRICKEA** este ABL — siempre `flash boot_a` + `set_active`.
- **Backup del iOS original de Angel** (shim+kernel que SÍ funcionan):
  `boot_a-ios-original.img` (sha256 `d5cceea5…`, ~128 MB). **No está en git**
  (es binario de Angel, no limpio). Guárdalo aparte; sirve como control y rescate.
- Recovery: **OrangeFox R12** en `recovery_b` (da adb — úsalo para leer el ring-log).
- **Baseband Guard** (LSM del kernel Android custom) bloquea escrituras de partición:
  se evadió flasheando un GKI boot_b limpio (Infinity-X vía payload-dumper-go) +
  OrangeFox oficial. Documentado por si hay que rehacerlo.

## 5) Qué sigue (orden sugerido)
1. **USB**: leer el ring-log (usb-status.md §"siguiente paso") para ver dónde para
   `sweet_usb`; iterar 0328 o atacar la capa que el log señale. **Es la prioridad.**
2. Control: flashear el `boot_a` de Angel y confirmar si ÉL enumera en tu Mac
   (aísla toolchain vs boot-path/host).
3. Con USB arriba (192.168.7.2): SSH, estresar 0327 con un scp grande, leer
   `kern.sweet_usb_stats`.
4. **GPS** (gps-plan.md) — necesita shell por USB.
5. **QEMU** (qemu-findings.md) — para iterar sin hardware; ver qué camino quedó vivo.
```
```
