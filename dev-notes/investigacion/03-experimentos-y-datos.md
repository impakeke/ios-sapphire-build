# 03 — Experimentos y datos medidos en el teléfono

Solo se registran mediciones, con fecha, imagen y ruta de arranque. Las interpretaciones van
marcadas como tales. Los logs crudos están en `~/sapphire-angel/research/logs-telefono/`,
fuera de git (AGENTS.md).

Imagen común salvo que se indique otra: **expG**, es decir `boot_a-expG-20261113-223928.img`
(sha256 `4c27d009…bf8f`), con kernel Apple LLVM 21 / SDK 26.5, parches hasta 0328, shim zig y
boot-args en `../angel.cmdline` (incluye `sweetusb=2`).

## E0 — Acceso (2026-11-13)

- Ruta: fastboot → `set_active a` + `continue`.
- Resultado: enumera como 1209:0001 "Sweet iOS (USB Ethernet)" y aparece `en5`.
- Con 192.168.7.1/24 en la Mac, el ping responde en 1-2 ms.
- La shell del puerto 2323 da `uid=0`.
- SSH funciona por clave tras `ssh-keygen -A` y lanzar sshd a mano.
- Detalle en `../acceso-al-telefono.md`.

## E-carga-1 — Copia de 4 MiB por SSH (2026-11-13 22:44)

- Ruta: la de E0.
- Comando: `ssh sapphire 'dd if=/dev/rufsroot0 bs=4096 skip=67107839 count=1025' > ring-good.bin`.

Resultados:

- El enlace murió a los **196 608 B**. El dispositivo siguió enumerado, pero no respondía ni a ARP.
- `kern.sweet_usb_stats`:
  - antes: `events 372 resets 1; rx 190 tx 76; without event: rx 0 tx 0, late rx 1; rx rearms 10; halt clears 2`;
  - tras reconectar: `events 1705 resets 2; rx 837 tx 2688980; late rx 16; rx rearms 57; halt clears 4`.
- En el ring, `SWEET USB: ep3 cmd 0x6 status 1` aparece **130 538** veces. También aparecen "ep2 cmd 0x6 status 1" (×2) y `ue0 rx/tx` con tx de unos 2,69 M.
- Al desconectar y reconectar el cable (bus reset) el enlace volvió sin reiniciar iOS. En la Mac hay que tener la IP fija con `networksetup -setmanual "Sweet iOS (USB Ethernet)" 192.168.7.1 255.255.255.0`.

Interpretación (auditoría, 01 §1): regresión de 0327 por doble consumo de la finalización, más un bucle `printf` → log UDP → TX. Falta discriminar entre α y β.

## E1 — Ruta de arranque con VBUS controlado (2026-11-14)

| Ensayo | Hora | Ruta | PMIC | Resultado |
|---|---|---|---|---|
| R1 | 00:14 | `fbusb set_active:a reboot`, cable puesto | `usb 0x10`, cargando, `apsd 0x1` (SDP) durante todo el arranque | **no enumera** en 150 s; ring: `ep0 cmd 0x1 timeout`, `endpoint 0 setup failed` |
| C1 | 00:2x | `fbusb set_active:a continue` | `usb 0x10` | **enumera** (ping 1,5 ms) |

Estado del DWC3 cuando el driver toma el control (primeras líneas `SWEET USB:` del ring):

| Registro | R1 | C1 |
|---|---|---|
| GCTL | 0x00102000 | 0x00112000 |
| GSTS | 0x7e800000 | 0x7e800000 |
| GUSB2PHYCFG | **0x00002500** (ENBLSLPM=1) | **0x00002400** |
| DCFG | 0x00080804 | 0x004808dc |
| DCTL | 0x00f00000 | 0x10f00000 |
| DEVTEN | 0 | 0x277 |
| DSTS | 0x00520004 | 0x00d3c034 |
| DALEPENA | 0 | 0xf |
| GEVNTADR / SIZ | 0 / 0 | 0x9ac22000 / 0x80001000 (del ABL) |
| GDSC + 7 relojes | encendidos | encendidos |
| QSCRATCH (antes del override de VBUS) | nunca se lee (aborta antes) | HS_PHY_CTRL 0, SS_PHY_CTRL 0, GENERAL_CFG 0x4 |

- R1 coincide **byte a byte** con el arranque malo del 13 nov.

Interpretación:

- El confusor de VBUS que señaló la auditoría queda **descartado**: en R1 había VBUS y falló igual.
- La ruta normal deja el DWC3 en reset. Esto coincide con el código de ABL (02 §P4): en arranque normal no arranca el USB device.
- ENBLSLPM=1 en R1. 0328 lo limpia y aun así se produce el timeout, así que **no basta**.
- Falta saber qué deja el ABL en el PHY femto y en QSCRATCH. → E2.

Tamaño de muestra: n=1 por ruta. Las repeticiones R2, R3, C2 y C3 están pendientes; R1 reproduce un arranque malo anterior, lo que sugiere un patrón estable.

## E2 — Kernel 0329 de diagnóstico (en curso)

- Parche: `xnu/patches/0329-sapphire-usb-boot-diag.patch`.
  - Antes de escribir nada, vuelca (solo lectura) GCC 0x1a000-0x1a0a0, 0x1c000 y 0x1d000; DWC3 0xc100-0xc160, 0xc200, 0xc2c0, 0xc300-0xc320, 0xc380, 0xc600-0xc640 y 0xc700-0xc730; QSCRATCH 0x00-0x80; y el PHY 0x000-0x120.
  - Las líneas tienen el formato `SWEET USBDIAG <bloque> +off w0 w1 w2 w3`.
  - El boot-arg `sweetusb_reclaim=0` desactiva 0327, para el A/B de carga. Por defecto vale 1, igual que expG.
- CI: `xnu-4k` en macos-15 (macos-14 está retirado), ejecución 43561459873.
- Empaquetado: `../repack-boot.py`, que reutiliza el shim, el ADT y el cmdline de expG.
- Plan:
  1. Arrancar por R y por C, y comparar los bloques USBDIAG.
  2. Prueba de carga A/B con reclaim=1 y reclaim=0.
