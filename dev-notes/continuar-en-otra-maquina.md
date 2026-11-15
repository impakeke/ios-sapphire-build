# Continuar en otra computadora

Qué hace falta para retomar el desarrollo en otra máquina. El código y las notas viven en este
repo; los binarios pesados y de terceros no (ni deben), así que aquí está cómo conseguirlos.

## 0) Clonar
```sh
git clone https://github.com/giovannipodesta/ios-sapphire.git
cd ios-sapphire && git checkout sapphire
```
Leer después [../AGENTS.md](../AGENTS.md) y [OPERACION.md](OPERACION.md).

## 1) Host
- **Kernel:** basta con `gh` autenticado en la cuenta del fork: el kernel que corre el teléfono se
  compila en GitHub Actions (`xnu-4k`, macos-15, Xcode 16.0 16A242d, unos 6-9 min) y se baja con
  `dev-notes/fetch-ci-kernel.sh` (OPERACION.md §4).
- **Compilar en local** (opcional): macOS con Apple clang 21 / SDK 26.x de las Command Line Tools, o
  Xcode 16. `brew install ccache`. Recetas en [build-recipes.md](build-recipes.md).
- **adb/fastboot** de platform-tools. En una Mac donde no puedan abrir el USB (la Hackintosh del fork),
  las herramientas de [`tools/hackintosh-usb/`](../tools/hackintosh-usb/README.md).
- Python 3 para `repack-boot.py`, `read-ring.py` y `bootargs.py`; `xcrun atos` para simbolizar.

## 2) Descargas pesadas (no están en git)
| Qué | De dónde | Dónde ponerlo |
|---|---|---|
| **IPSW** iPhone10,3 16.7.16 (20H392) | `ipsw.me` / Apple | `~/Downloads/iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw` |
| **KDK 13.5** (22G74) | developer.apple.com/download (More) | instalar → `/Library/Developer/KDKs/KDK_13.5_22G74.kdk` |
| **zig 0.13.0** (macos-x86_64) | ziglang.org/download | `~/sapphire-build/zig-macos-x86_64-0.13.0/zig` |
| **darwin-xnu-build** | github.com/blacktop/darwin-xnu-build | `~/sapphire-build/dxb` |
| **mkbootimg.py** (AOSP) | AOSP `system/tools/mkbootimg` | `~/sapphire-build/mkbootimg.py` (parchear el import `gki` con try/except) |

Del IPSW se extrae (con `pyimg4` o `ipsw img4 im4p extract`) `research/ipsw-x/d22ap.adt` para
`mkadt.py`. El IPSW no va al repo.

## 3) Lo que vive fuera de git en la Mac del fork
`~/sapphire-angel/`: `backups/` (base de `repack-boot.py`, particiones y GPT), `ci-kernels/`,
`logs/`, `research/` (material pesado de las auditorías) e imágenes `boot_a-*.img`; `~/adb-bridge/`
(herramientas USB compiladas). Detalle en OPERACION.md §2. Para seguir en otra máquina, copiar como
mínimo `backups/boot_a-expG-20261113-223928.img`.

## 4) Teléfono
- Slots: **`boot_a` = iOS**, **`boot_b` = Android** (Infinity-X, GKI). Nunca escribir `boot_b`.
- Recovery: **OrangeFox R12**, se llega con `set_active b` + `reboot recovery` (con `a` activo, el modo
  recovery arranca el kernel de `boot_a`, es decir iOS; ver [../RECOVERY.md](../RECOVERY.md)).
- Un kernel Android con **Baseband Guard** (LSM) bloquea las escrituras de particiones; por eso el
  slot `b` lleva un GKI limpio de Infinity-X (extraído con payload-dumper-go) y OrangeFox oficial.
- Todo el ciclo de pruebas está en OPERACION.md.

## 5) Qué sigue
[investigacion/INDICE.md](investigacion/INDICE.md), secciones "Gráficos: siguiente trabajo" y "Pendientes".
El driver Metal y sus herramientas viven fuera de git, en `~/sapphire-angel/research/metal/` (receta en
[investigacion/08](investigacion/08-hakiosmetal-binario-vs-fuente.md) §6). Más adelante: GPS
([gps-plan.md](gps-plan.md)) y QEMU ([qemu-findings.md](qemu-findings.md)).
