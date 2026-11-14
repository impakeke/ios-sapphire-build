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

## E4 — Ruta R automática con la ruta de datos nueva (`sweetusb_dp=2`), 2026-11-14

**Configuración**
- Imagen `boot_a-0331-carga-B.img`: kernel 0331 de CI (incluye 0329+0330+0331); boot-args `sweetusb_utmipipe=1 sweet_reboot=2 sweetusb_dp=2`.
- Bucle `~/adb-bridge/exp-loop.sh` sin intervención humana: vuelta a fastboot por `kern.sweet_reboot_mode=2` + `reboot` desde la shell 2323, luego `fbusb set_active:a reboot`.

**Resultado: 3/3 arranques normales ENUMERAN, en 44, 41 y 42 s**
- En todos, GCTL `0x00102000` (controlador en reset al tomar el control, ruta R).
- Acumulado con `utmipipe=1` por la ruta R: **5/5 enumeran** (E3 ×2 + E4 ×3).

**"Panics" del 1.er arranque de E3 y del ensayo 1 de e3-n3: reinterpretación (hipótesis fuerte)**
- El usuario vio fondo negro con el log temprano de XNU (`mig_table_max_displ`, `mach_kobj_count`, `debug_log_init… gPanicBase`, `kdp_core zlib`). Son líneas normales de arranque, no texto de panic.
- Con cmdline > 575 el shim no pasa `sweet_splash`, así que xnu no pinta la imagen de arranque y queda el log visible.
- El ring del ensayo 1 muestra un arranque completo (USB `address 38`, SpringBoard, Wi-Fi) sin panic. El teléfono terminó en la pantalla de bloqueo.
- Pendiente: volver a cmdline ≤ 575 (o hacer los valores por defecto en el kernel) y comprobar que la pantalla vuelve a ser la normal.

## Carga-1 con `dp=2` (2026-11-14 ~01:40, mismo arranque que E4-3)

| Prueba | Resultado |
|---|---|
| 1×30 MB Mac→tel (SSH, `sha256sum` en el tel) | 4,9 s, SHA-256 igual |
| 1×30 MB tel→Mac | 6,1 s, sin corte |
| 10×30 MB Mac→tel | **10/10 SHA-256 iguales**, 107 s |
| 10×30 MB tel→Mac (archivo en el tel, hash ambos lados + tamaño) | **10/10 hash igual y 31 457 280 B**. Un "fallo" del script fue un artefacto de zsh (`set -- $r` no separa palabras) |

`kern.sweet_usb_dp` tras unos 660 MB:
- `start ok 1 099 317`; `refused 0`, `timeout 0`, `cmd_busy 0`.
- `noevt(alpha) 0`, `evt not_started 0`, `hwo_set 0`, `buserr 0`, `evcount over 0`.
- `bus_resets 1` (solo el inicial).
- `tx done 590 930`, `rx done 508 384`.
- `qdrop 10 348`: cola TX llena devuelve ENOBUFS; TCP lo recupera. Se puede afinar.
- **`hwo0_noevt_polls 82 696`**: medición directa de la ventana en que HWO=0 y el evento aún no ha llegado (la premisa de la auditoría sobre 0327).
- `poll_max_us 3090`.

**Comparación:** con la ruta vieja (E-carga-1, 13 nov) el enlace murió a los 192 KiB, con 130 538 rechazos de Start Transfer.
**Conclusión (n=1 arranque, 20 transferencias):** la ruta 0330 resuelve la muerte bajo carga.

## E5 — kernel 0332 (valores por defecto) y el "cuelgue" (2026-11-14 ~01:50)

- **Ensayo 1:** arranque normal; enumera a los 44 s. Después el enlace y el teléfono quedan muertos.
- **Panic real** en el ring (cabecera `seq=PANIC`, caja negra 0146), tras `exec dd / exec tr / exec grep / exec tail`, es decir, el `dd if=/dev/rufsroot0` que el bucle ejecutaba en el teléfono para leer el ring:
  ```
  Kernel data abort. at pc 0xfffffff007be90b8, lr 0xfffffff0074e904c
  x0 0x00000001006f4000 x2 0xfe0 x12 0x474f4c5445455753 ("SWEETLOG") esr 0x9600004f far 0x00000001006f4000
  ```
- **Simbolizado** con `xcrun atos` sobre el kernel 0332: `pc = memcpy+72`, `lr = sweet_ufs_strategy+604`.
- **Causa** (código, parches 0028/0030):
  - `sweet_ufs_read`/`write` (dispositivo crudo) usan `physio()`, cuyo buffer lleva la **dirección de usuario** del proceso.
  - `sweet_ufs_strategy` hace `buf_map()` → `memcpy(vaddr + done, bounce, …)`. Para buffers de physio, `buf_map` devuelve esa dirección de usuario.
  - El kernel escribe en memoria de usuario: fallo de permiso por **PAN** (DFSC 0x0f, WnR=1).
  - Es intermitente: muchas lecturas anteriores del ring por `/dev/rufsroot0` funcionaron.
- **No tiene relación con el USB ni con 0332.** La hipótesis que hice antes ("`static int ud_dp = 2` deja correr la ruta v2 antes de inicializarla", que motivó 0333) **queda descartada** por esta evidencia. 0333 es inocuo y se conserva.
- **"Panics" anteriores:** el del ensayo 1 de e3-n3 también ocurrió con el bucle leyendo `rufsroot0` (allí no quedó caja negra). El del 1.er arranque de E3 no tiene datos.
- **Acciones:**
  - El bucle lee ahora el ring por el dispositivo **de bloques** `/dev/ufsroot0`, que usa buffers del kernel.
  - Arreglo pendiente en el driver: E/S cruda con búfer intermedio del kernel y `uiomove`, sin tocar memoria de usuario desde `strategy`.

## E6 — kernel 0333 (UTMI y dp=2 por defecto, sin boot-args extra salvo `sweet_reboot=2`), 2026-11-14 02:14

| Ensayo | Ruta | Resultado | dp |
|---|---|---|---|
| 1 | R | ENUMERA en 44 s | 2 |
| 2 | R | ENUMERA en 44 s | 2 |
| 3 | R | ENUMERA en 44 s | 2 |
| 4 | C | ENUMERA en 40 s | 2 |

- Sin panics: el bucle lee el ring por `/dev/ufsroot0` (dispositivo de bloques), no por `rufsroot0`.
- **Acumulado de arranques normales que enumeran con la corrección UTMI: 8/8** (E3 ×2, E4 ×3, E6 ×3). Sin ella: 0/3 (13 nov, R1, E2-R1).
- **SSH persistente:**
  - El job `com.sapphire.sshd-usb` (`/redwood/launchd`, lo carga `/redwood/boot.d/70-sshd-usb.sh`) arranca solo y escucha en `192.168.7.2:22`.
  - `ssh_auto=NO` en el CSV era un artefacto de tiempos: `firstboot` ejecuta `boot.d` unos segundos después de que el bucle lo comprobara. Verificado con `ssh sapphire` después.
  - El bucle ahora reintenta durante 60 s.
- Cmdline de 562 caracteres: el shim vuelve a pasar `sweet_splash`. Pendiente: el usuario confirmará si reaparece la imagen de arranque.

## E7 — Parche 0334 (E/S cruda de UFS sin memcpy a memoria de usuario), 2026-11-14 ~02:30

Kernel de CI, run 43570770230, sha `ffcc981f…`, con 0334 aplicado. Imagen `boot_a-0334.img` con boot-args de expG más `sweet_reboot=2`. Se arrancó por la ruta R, iOS respondía a los 27 s, y todo el ciclo fue automático: SSH a fastboot, flash, arranque y prueba.

| Prueba (como root, por SSH) | Resultado |
|---|---|
| `dd if=/dev/rufsroot0 bs=4096 skip=67107839 count=1025` (la que paniqueaba en E5) | **30/30 completas** (4 198 400 B), sin panic |
| `bs=4194304 count=4` | **10/10 completas** (16 MiB) |
| `bs=1048576 count=64` | 67 108 864 B exactos |
| `bs=100 count=1 skip=1` (offset no alineado) | `Invalid argument`: EINVAL limpio, tal como lo diseñó 0334 |

Nota: un primer intento devolvió "0/10" porque el `dd` del teléfono no acepta el sufijo `4m` ("invalid number"). Fue un artefacto de la prueba.
Conclusión: el panic de E5 queda corregido por 0334. El bucle podría volver a usar `rufsroot0`, pero sigue usando `ufsroot0`.
