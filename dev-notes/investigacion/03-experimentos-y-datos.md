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
- CI: `xnu-4k` en macos-15 con Xcode 16.0 (16A242d). La ejecución 43561459873 falló en Collect (bug del workflow); la buena es **43562358335** (0329 aplicado, 327 parches). Kernel sha `fd991ef7…`, LC_UUID FAEA5217-…; imagen `boot_a-0329-diag.img` sha `fa0cf8cb…` (boot-args idénticos a expG).
- **Variable extra:** el kernel 0329 sale de Xcode 16 (CI) y expG de Apple clang 21 local. No afecta a la comparación R frente a C con el mismo kernel.
- E2-R1 (00:5x): el kernel 0329 arranca iOS por la ruta R y no enumera (esperado). Lectura del ring pendiente.
- Empaquetado: `../repack-boot.py`, que reutiliza el shim, el ADT y el cmdline de expG.
- Plan:
  1. Arrancar por R y por C, y comparar los bloques USBDIAG.
  2. Prueba de carga A/B con reclaim=1 y reclaim=0.

### E2 — resultados (2026-11-14, kernel 0329 de CI, misma imagen en ambas rutas)

Datos crudos: `~/sapphire-angel/research/logs-telefono/E2-R1-usbdiag.txt` y `E2-C1-usbdiag.txt`.

| Bloque | R1 (reboot; no enumera) | C1 (continue; enumera) |
|---|---|---|
| PHY femto 0x000-0x110 | overrides del DT `a6/85/16` presentes (0x6c-0x74), CTRL5 POR=0, COMMON0 0x88 (SIDDQ=0), PWRDOWN 0x01 | **idéntico** salvo +0x20: 0x03 frente a 0x0e (probable estado de línea) |
| GCC CBCR 0x1a058 (`gcc_usb3_prim_phy_pipe_clk`, gcc-sm6115) | **0x80000001 (habilitado, APAGADO)** | 0x00000001 (corre) |
| GCC 0x1a020 (master RCG CFG) | 0x00100105 | 0x00000105 |
| GCC 0x1a038 (mock_utmi RCG CFG) | 0x00100000 | 0x00000001 |
| GCC 0x1a064 | 0 | 1 |
| QSCRATCH GENERAL_CFG (+0x08) | 0x4 | 0x4 |
| QSCRATCH HS_PHY_CTRL (+0x10), antes del override | 0x10000000 | 0x00000000 |
| QSCRATCH +0x28 / +0x58 | 0 / 0x00040000 | 2 / 0x00240000 |
| GSBUSCFG1 0xc104 | 0x1700 | 0x1e00 |
| GUCTL1 0xc11c | 0x000c1802 | 0x810c1802 (bits 31, 24) |
| GUSB2PHYCFG 0xc200 | 0x2500 | 0x2400 |
| GUSB3PIPECTL 0xc2c0 | 0x030c0002 (DEPOCHANGE) | 0x0b080002 (UX_EXIT_PX) |
| GTXFIFOSIZ 2-7 | tamaños por defecto | redistribuidos por el ABL |
| DCFG/DCTL/DEVTEN/DALEPENA/GEVNT* | valores de reset | configurados por el ABL |

**Interpretación (hipótesis, con fuente):**

- El PHY HS queda inicializado en ambas rutas, así que no es la causa. La diferencia relevante es el reloj PIPE del PHY USB3 (QMP): en la ruta normal está apagado.
- Linux, para un dwc3 que solo usa HS, selecciona el UTMI como reloj PIPE (`dwc3_qcom_select_utmi_clk`, `qcom,select-utmi-as-pipe-clk`). Aquí nunca se hizo: GENERAL_CFG vale 0x4 en ambas rutas.
- Predicción para E3 (parche 0331, `sweetusb_utmipipe=1`): enumera también con la ruta R.

**Hallazgo lateral del respaldo** (`backups/particiones-20261114-0110`, sha256 verificado): `abl_a` = `abl_b`, pero `xbl_a` ≠ `xbl_b`. iOS (slot a) arranca con otro XBL. Queda como variable a tener en cuenta.

### Compilaciones

- 0330: run 43564692243, éxito (compila y enlaza). Kernel sha `ce2a717a…`, UUID D12E0D3D-…
- 0331: run 43565315944, en curso.

## E3 — UTMI como reloj PIPE (parche 0331, `sweetusb_utmipipe=1`), 2026-11-14

- Imagen: `boot_a-0331-utmipipe1.img` (sha `949bb257…`). Kernel de CI, run 43565315944, sha `5af8886f…`, UUID D205180C-…
- Cmdline: el de expG más `sweetusb_utmipipe=1`. Con más de 575 caracteres el shim no pasa `sweet_splash`, lo que solo afecta a lo visual.
- Ruta: `fbusb flash boot_a … set_active:a reboot`, es decir, **arranque normal**.

**1.er arranque:** el usuario informa de un **panic**. En el ring no quedó rastro: solo aparece un arranque del kernel 0331. Se desconoce la etapa del fallo; pendiente de que el usuario describa la pantalla. Después el teléfono se reinició solo, con `sweet_reboot=0`, es decir, otra vez un arranque normal.

**2.º arranque (ruta R, sin pasar por fastboot): ENUMERA.**
- Al tomar el control, el controlador está en estado de reset, igual que en R1 y E2-R1: GCTL `0x00102000`, DCFG `0x00080804`, GUSB2PHYCFG `0x2500`.
- `SWEET USBDIAG utmipipe=1 GENERAL_CFG 0x00000004 -> 0x0000000d`, es decir, SEL, PHYSTATUS_SW y bit 2.
- `soft reset done`, **sin** `ep0 cmd 0x1 timeout`. Después `VBUS override on` y `address 36`.
- En la Mac: ping de unos 2,6 ms y shell en el puerto 2323. `kern.sweet_usb_stats: configured 1 … rx 233 tx 625`.
- Bootargs confirmados con `sysctl kern.bootargs`: `sweetusb_utmipipe=1`, `sweet_reboot=0`.

**Conclusión (n=1):** en un arranque normal el controlador DWC3, que solo usa HS, necesita UTMI como reloj PIPE, porque el reloj PIPE del PHY USB3 está apagado. Con la secuencia de Linux `dwc3_qcom_select_utmi_clk` el USB de iOS funciona **sin fastboot**.

**Pendiente:**
- Repetir hasta n=3 en la ruta R.
- Control en la ruta C con `utmipipe=1`.
- Aclarar el panic del 1.er arranque.
- Decidir si `utmipipe` pasa a ser el valor por defecto.
