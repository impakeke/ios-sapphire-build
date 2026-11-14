# dev-notes — ios-sapphire (fork giovannipodesta)

Notas de desarrollo del port iOS 16.7.16 (iPhone10,3 userland + XNU) sobre el
**Redmi Note 13 4G "sapphire"** (Qualcomm SM6225 / Snapdragon 685). Objetivo del
fork: **arreglar el USB de una vez** (es el cuello que frena todo), **implementar
GPS**, y hacerlo todo **limpio: compilado desde fuente, sin reusar binarios de
Angel**.

Estas notas existen para **continuar en otra computadora**. Léelas en orden:

| Doc | Qué cubre |
|---|---|
| [continuar-en-otra-maquina.md](continuar-en-otra-maquina.md) | **EMPIEZA AQUÍ.** Qué instalar, qué descargar (IPSW/KDK/zig), cómo reconstruir el entorno de build. |
| [build-recipes.md](build-recipes.md) | Recetas exactas: kernel XNU (DXB), shim (zig Recipe C), empaquetado (mkadt/mkpayload), flasheo. |
| [usb-status.md](usb-status.md) | **Estado vivo del USB.** Causa raíz, qué se probó (0327/0328), resultado de expG, siguiente paso. |
| [usb-diagnostico.md](usb-diagnostico.md) | Diagnóstico profundo del USB polled (culpables, diseño del fix, refs Linux dwc3). |
| [toolchain-findings.md](toolchain-findings.md) | Hallazgos del toolchain en macOS (por qué zig/Xcode21 rompían shim/kernel y cómo se arregló). |
| [qemu-findings.md](qemu-findings.md) | Investigación de QEMU para emular/depurar sin hardware. Qué funciona, qué no, camino recomendado. |
| [gps-plan.md](gps-plan.md) | Plan GPS (QMI LOC 0x10 sobre QRTR, 3 tramos) — pendiente, necesita shell por USB. |
| [coarseloc-outofscope.md](coarseloc-outofscope.md) | "Out of scope": posición aproximada por celda/wifi sin cielo abierto. |

## Parches propios (en `xnu/patches/`)
- **0327** `0327-sapphire-usb-fast-reclaim.patch` — ring de TRBs reclamado por HWO en cada poll
  (no depende del evento que se pierde bajo carga). *Commiteado.*
- **0328** `0328-sapphire-usb-phy-wake-ep0-timeout.patch` — despierta la UTMI PHY
  (GUSB2PHYCFG SUSPHY/ENBLSLPM) antes de los ep commands + sube el timeout de ep0.
  *Compila y bootea; USB aún no enumera — ver usb-status.md.*

## Estado en una línea (2026-11-13)
iOS **bootea limpio** desde fuente (nuestro kernel + nuestro shim zig) hasta el
**lock screen**. El USB (CDC-ECM gadget, idVendor 0x1209) **todavía no enumera**
en el host. El kernel está vivo, así que el **ring-log persistente** (cola de la
partición) ya debería tener los `printf` de `sweet_usb` — ese es el próximo dato
decisivo (leer desde OrangeFox recovery). Ver `usb-status.md`.
