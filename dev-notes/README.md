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
| [investigacion/INDICE.md](investigacion/INDICE.md) | **Estado actual del USB y auditorías** (2026-11-14): mediciones, fuentes primarias, parches 0329-0334, auditoría de la documentación heredada. |
| [usb-status.md](usb-status.md) | Estado del USB al 2026-11-13 (histórico; superado por investigacion/). |
| [usb-diagnostico.md](usb-diagnostico.md) | Diagnóstico profundo del USB polled (culpables, diseño del fix, refs Linux dwc3). |
| [toolchain-findings.md](toolchain-findings.md) | Hallazgos del toolchain en macOS (zig y Apple clang 21 / SDK 26.x; las conclusiones "toolchain roto" quedaron contradichas, ver la nota al inicio). |
| [qemu-findings.md](qemu-findings.md) | Investigación de QEMU para emular/depurar sin hardware. Qué funciona, qué no, camino recomendado. |
| [gps-plan.md](gps-plan.md) | Plan GPS (QMI LOC 0x10 sobre QRTR, 3 tramos) — pendiente, necesita shell por USB. |
| [coarseloc-outofscope.md](coarseloc-outofscope.md) | "Out of scope": posición aproximada por celda/wifi sin cielo abierto. |

## Parches propios (en `xnu/patches/`)
- **0327** `0327-sapphire-usb-fast-reclaim.patch`: reclama por HWO en cada poll. No es un ring de
  TRBs (sigue siendo un TRB por endpoint) y su doble reclamación causó la muerte bajo carga
  (investigacion/01). La ruta 0330 la sustituye por defecto.
- **0328** `0328-sapphire-usb-phy-wake-ep0-timeout.patch`: limpia SUSPHY/ENBLSLPM y sube el timeout
  de ep0. Por sí solo no basta (investigacion/03, E1).
- **0329**: diagnóstico de solo lectura (PHY/QSCRATCH/GCC/DWC3) y gate `sweetusb_reclaim`.
- **0330**: ruta de datos v2 (`sweetusb_dp=2`): un dueño por endpoint, sin reclamar por HWO, sin
  `printf`, DMA no cacheable (investigacion/05).
- **0331**: UTMI como reloj PIPE (`sweetusb_utmipipe=1`, como `dwc3_qcom_select_utmi_clk` de Linux).
- **0332/0333**: 0331 y 0330 activos por defecto (desactivables por boot-arg); 0333 elige `dp=2` en
  `gadget_start`.
- **0334**: E/S cruda de `sweet_ufs` sin `memcpy` a memoria de usuario (investigacion/06).

## Estado (2026-11-14)
Medido en el teléfono del fork (detalle en [investigacion/03](investigacion/03-experimentos-y-datos.md)):
- iOS arranca desde fuente (kernel propio + shim zig) hasta el lock screen.
- **El USB de iOS enumera en arranque normal** (`set_active a` + reboot) con 0331-0333: 8/8
  arranques normales; antes solo enumeraba saliendo de fastboot con `continue` (0/3 sin el parche).
- **Bajo carga**, la ruta 0330 pasó 20 × 30 MB con SHA-256 iguales, sin rechazos de Start Transfer
  (n=1 arranque).
- Acceso: 192.168.7.2 (Mac 192.168.7.1), shell root sin autenticación en :2323, SSH solo por clave
  (job `com.sapphire.sshd-usb`, fuentes en `userland/sshd-usb/`). Ver [acceso-al-telefono.md](acceso-al-telefono.md).
- Muestras pequeñas: faltan repeticiones, y el panic de E/S cruda de `sweet_ufs` se arregló en 0334
  sin medición registrada todavía.
