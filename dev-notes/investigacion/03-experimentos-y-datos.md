# 03 — Experimentos y datos medidos en el teléfono

Bitácora fechada: cada entrada da la medición y su interpretación vigente. Los logs crudos están en
`~/sapphire-angel/research/logs-telefono/` y los rings y respaldos en `~/sapphire-angel/backups/`,
fuera de git (AGENTS.md).

**Rutas de arranque.** **R** = arranque normal (`fbusb set_active:a reboot`, o reinicio sin pasar por
fastboot). **C** = `fastboot set_active a` + `continue`.

Imagen común salvo que se indique otra: **expG**, es decir `boot_a-expG-20261113-223928.img`
(sha256 `4c27d009…bf8f`), con kernel Apple LLVM 21 / SDK 26.5, parches hasta 0328, shim zig y
boot-args en `../angel.cmdline` (incluye `sweetusb=2`).

## Resumen

| Id | Fecha | Kernel / parches | Ruta | n | Resultado |
|---|---|---|---|---|---|
| E0 | 13 nov | expG (≤0328) | C | 1 | Enumera; ping, shell 2323 y SSH |
| E-carga-1 | 13 nov 22:44 | expG | C | 1 | El enlace muere a los 196 608 B; 130 538 Start Transfer rechazados en ep3 |
| E1 | 14 nov 00:14-00:2x | expG | R / C | 1 + 1 | R no enumera (con VBUS presente); C enumera |
| E2 | 14 nov 00:5x-01:14 | 0329 diag (CI, Xcode 16) | R / C | 1 + 1 | R no enumera, C sí; en R el reloj PIPE del PHY USB3 está apagado |
| E3 | 14 nov 01:2x-01:34 | 0331, `sweetusb_utmipipe=1` | R | 3 arranques | 2/2 con datos enumeran (el 1.º arranque no dejó datos) |
| E4 | 14 nov 01:34-01:38 | 0331 + `sweetusb_dp=2` | R (automática) | 3 | 3/3 enumeran (41-44 s) |
| Carga-1 dp=2 | 14 nov ~01:40 | igual que E4 | R | 20 copias de 30 MB | 20/20 íntegras; 0 rechazos |
| E5 | 14 nov 01:50 | 0332 (UTMI y dp=2 por defecto) | R | 1 | Enumera; después panic de `sweet_ufs` en E/S cruda (no es USB) |
| E6 | 14 nov 02:14-02:19 | 0333 | R ×3, C ×1 | 4 | 4/4 enumeran; SSH arranca solo |
| E7 | 14 nov ~02:30 | 0334 | R | 30 + 10 + 2 lecturas crudas | Sin panic; EINVAL limpio en desalineado |
| CPU-0334 | 14 nov 02:34 | 0334 | R | 20 muestras / 10 min | Load 1 min 1,1-2,6 en reposo (ver 07) |

**Acumulado USB en arranque normal (R):** con UTMI como reloj PIPE (0331 por boot-arg, 0332/0333 por
defecto) enumeran **8/8** (E3 ×2, E4 ×3, E6 ×3); sin ella, **0/3** (13 nov, E1-R1, E2-R1).

## E0 — Acceso (2026-11-13)

- Ruta: C.
- Resultado: enumera como 1209:0001 "Sweet iOS (USB Ethernet)" y aparece `en5`.
- Con 192.168.7.1/24 en la Mac, el ping responde en 1-2 ms.
- La shell del puerto 2323 da `uid=0`.
- SSH funciona por clave tras `ssh-keygen -A` y lanzar sshd a mano.
- Procedimiento de acceso actual: [../OPERACION.md](../OPERACION.md) §3.

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

Interpretación (01 §1): regresión de 0327 por doble consumo de la finalización, más un bucle
`printf` → log UDP → TX. Entre α y β (01 §1.7) no se discriminó con la ruta vieja; la ruta de datos v2
(0330) elimina el mecanismo y bajo carga no registra ninguna α (Carga-1 dp=2).

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

- R1 coincide **byte a byte** con el arranque malo del 13 nov (aquel sin VBUS: PMIC `usb 0x26`).

Interpretación:

- VBUS no influye: R1 tenía VBUS y falló igual que el arranque sin VBUS del 13 nov.
- La ruta R deja el DWC3 en reset. Coincide con el código de ABL (02 §P4): en arranque normal no arranca el USB device.
- ENBLSLPM=1 en R1. 0328 lo limpia y el timeout sigue, así que no es la causa. La causa es el reloj PIPE apagado (E2, E3).

Tamaño de muestra: n=1 por ruta en este experimento. Sin la corrección UTMI, la ruta R falla 3/3
(13 nov, R1, E2-R1); la ruta C enumera en C1, E2-C1 y E6-4.

## E2 — Kernel 0329 de diagnóstico (2026-11-14)

- Parche: `xnu/patches/0329-sapphire-usb-boot-diag.patch`.
  - Antes de escribir nada, vuelca (solo lectura) GCC 0x1a000-0x1a0a0, 0x1c000 y 0x1d000; DWC3 0xc100-0xc160, 0xc200, 0xc2c0, 0xc300-0xc320, 0xc380, 0xc600-0xc640 y 0xc700-0xc730; QSCRATCH 0x00-0x80; y el PHY 0x000-0x120.
  - Las líneas tienen el formato `SWEET USBDIAG <bloque> +off w0 w1 w2 w3`.
  - El boot-arg `sweetusb_reclaim=0` desactiva 0327. Por defecto vale 1, igual que expG.
- Kernel de CI: `xnu-4k` en macos-15 con Xcode 16.0 (16A242d), run **43562358335** (0329 aplicado, 327 parches). Kernel sha `fd991ef7…`, LC_UUID FAEA5217-…; imagen `boot_a-0329-diag.img` sha `fa0cf8cb…` (boot-args idénticos a expG).
- El kernel 0329 sale de Xcode 16 (CI) y expG de Apple clang 21 local. No afecta a la comparación R frente a C, que usa el mismo kernel.
- Empaquetado: `../repack-boot.py`, que reutiliza el shim, el ADT y el cmdline de expG.
- E2-R1 (00:5x): ruta R, no enumera. E2-C1: ruta C, enumera.
- La prueba de carga A/B con `sweetusb_reclaim=0/1` no se hizo: la ruta 0330 la sustituyó.

Datos crudos: `logs-telefono/E2-R1-usbdiag.txt` y `E2-C1-usbdiag.txt`; ring de R1 en `backups/ring-E2R1.txt`.

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

**Interpretación (confirmada por E3):**

- El PHY HS queda inicializado en ambas rutas, así que no es la causa. La diferencia relevante es el reloj PIPE del PHY USB3 (QMP): en la ruta R está apagado.
- Linux, para un dwc3 que solo usa HS, selecciona el UTMI como reloj PIPE (`dwc3_qcom_select_utmi_clk`, `qcom,select-utmi-as-pipe-clk`). El driver nunca lo hacía: GENERAL_CFG vale 0x4 en ambas rutas.

**Hallazgo lateral del respaldo** (`backups/particiones-20261114-0110`, sha256 verificado): `abl_a` = `abl_b`, pero `xbl_a` ≠ `xbl_b`. iOS (slot a) arranca con otro XBL. Variable a tener en cuenta.

**Compilaciones de CI usadas después:** 0330, run 43564692243 (kernel sha `ce2a717a…`, UUID D12E0D3D-…);
0331, run 43565315944 (sha `5af8886f…`, UUID D205180C-…).

## E3 — UTMI como reloj PIPE (parche 0331, `sweetusb_utmipipe=1`), 2026-11-14

- Imagen: `boot_a-0331-utmipipe1.img` (sha `949bb257…`). Kernel de CI, run 43565315944.
- Cmdline: el de expG más `sweetusb_utmipipe=1`. Mide más de 575 caracteres, así que el shim no pasa `sweet_splash` y xnu no pinta la imagen de arranque: queda visible el log temprano de XNU.
- Ruta: `fbusb flash boot_a … set_active:a reboot`, es decir, **R**.

**1.er arranque:** el usuario informó de un "panic". El ring no conserva ese arranque; no hay datos. El
teléfono se reinició solo con `sweet_reboot=0` (otro arranque R).

**2.º arranque (R): ENUMERA** (`logs-telefono/E3-R-tras-panic.txt`).
- Al tomar el control, el controlador está en reset, igual que en R1 y E2-R1: GCTL `0x00102000`, DCFG `0x00080804`, GUSB2PHYCFG `0x2500`.
- `SWEET USBDIAG utmipipe=1 GENERAL_CFG 0x00000004 -> 0x0000000d`, es decir, SEL, PHYSTATUS_SW y bit 2.
- `soft reset done`, **sin** `ep0 cmd 0x1 timeout`. Después `VBUS override on` y `address 36`.
- En la Mac: ping de unos 2,6 ms y shell en el puerto 2323. `kern.sweet_usb_stats: configured 1 … rx 233 tx 625`.
- Bootargs confirmados con `sysctl kern.bootargs`: `sweetusb_utmipipe=1`, `sweet_reboot=0`.

**e3-n3, ensayo 1 (01:29, bucle automático, mismo kernel; `logs-telefono/e3-n3-20261114-012908/`, ring en `backups/ring-panic2.txt`): ENUMERA.**
- GCTL `0x00102000` al tomar el control, `utmipipe=1 GENERAL_CFG 0x4 -> 0xd`, `address 38`; el ring sigue con SpringBoard y Wi-Fi, sin panic. El teléfono terminó en la pantalla de bloqueo. El CSV del bucle quedó vacío (el bucle no llegó a escribir el resultado).
- Lo que el usuario vio como "panic" fue fondo negro con el log temprano de XNU (`mig_table_max_displ`, `mach_kobj_count`, `debug_log_init… gPanicBase`, `kdp_core zlib`): líneas normales de arranque, visibles por el cmdline > 575.

**Conclusión:** en un arranque normal el DWC3, que solo usa HS, necesita UTMI como reloj PIPE porque el
reloj PIPE del PHY USB3 está apagado. Con la secuencia de Linux `dwc3_qcom_select_utmi_clk` el USB de
iOS funciona **sin fastboot**. Pasó a ser el valor por defecto en 0332/0333 (n acumulado arriba).

## E4 — Ruta R automática con la ruta de datos nueva (`sweetusb_dp=2`), 2026-11-14

**Configuración**
- Imagen `boot_a-0331-carga-B.img`: kernel 0331 de CI (incluye 0329+0330+0331); boot-args `sweetusb_utmipipe=1 sweet_reboot=2 sweetusb_dp=2`.
- Bucle `~/adb-bridge/exp-loop.sh` sin intervención humana: vuelta a fastboot por `kern.sweet_reboot_mode=2` + `reboot` desde la shell 2323, luego `fbusb set_active:a reboot`.

**Resultado: 3/3 arranques R ENUMERAN, en 44, 41 y 42 s** (`logs-telefono/e4-dp2-20261114-013454/`).
- En todos, GCTL `0x00102000` (controlador en reset al tomar el control).

## Carga-1 con `dp=2` (2026-11-14 ~01:40, mismo arranque que E4-3)

Datos: `logs-telefono/carga-dp2-013843/`.

| Prueba | Resultado |
|---|---|
| 1×30 MB Mac→tel (SSH, `sha256sum` en el tel) | 4,9 s, SHA-256 igual |
| 1×30 MB tel→Mac | 6,1 s, sin corte |
| 10×30 MB Mac→tel | **10/10 SHA-256 iguales**, 107 s |
| 10×30 MB tel→Mac (archivo en el tel, hash ambos lados + tamaño) | **10/10 hash igual y 31 457 280 B** |

`kern.sweet_usb_dp` tras unos 660 MB:
- `start ok 1 099 317`; `refused 0`, `timeout 0`, `cmd_busy 0`.
- `noevt(alpha) 0`, `evt not_started 0`, `hwo_set 0`, `buserr 0`, `evcount over 0`.
- `bus_resets 1` (solo el inicial).
- `tx done 590 930`, `rx done 508 384`.
- `qdrop 10 348`: cola TX llena devuelve ENOBUFS; TCP lo recupera. Se puede afinar.
- **`hwo0_noevt_polls 82 696`**: medición directa de la ventana en que HWO=0 y el evento aún no ha llegado (la premisa de la auditoría sobre 0327).
- `poll_max_us 3090`.

**Comparación:** con la ruta vieja (E-carga-1) el enlace murió a los 192 KiB, con 130 538 rechazos de Start Transfer.
**Conclusión (n=1 arranque, 20 transferencias):** la ruta 0330 resuelve la muerte bajo carga. Pasó a ser el valor por defecto en 0332/0333.

## E5 — Kernel 0332 (UTMI y dp=2 por defecto), 2026-11-14 01:50

Datos: `logs-telefono/e5-0332-20261114-015020/`, ring en `logs-telefono/ring-E5.txt`.

- **Ensayo 1:** ruta R; enumera a los 44 s (`address 49`). Después el enlace y el teléfono quedan muertos. **Ensayo 2:** el teléfono no volvió solo a fastboot; el bucle se detuvo.
- **Panic** en el ring (cabecera `seq=PANIC`, caja negra 0146), justo tras `exec dd / exec tr / exec grep / exec tail`, es decir, el `dd if=/dev/rufsroot0` con el que el bucle leía el ring en el teléfono:
  ```
  Kernel data abort. at pc 0xfffffff007be90b8, lr 0xfffffff0074e904c
  x0 0x00000001006f4000 x2 0xfe0 x12 0x474f4c5445455753 ("SWEETLOG") esr 0x9600004f far 0x00000001006f4000
  ```
- **Simbolizado** con `xcrun atos` sobre el kernel 0332: `pc = memcpy+72`, `lr = sweet_ufs_strategy+604`.
- **Causa** (análisis completo en 06):
  - `sweet_ufs_read`/`write` (dispositivo crudo) usan `physio()`, cuyo buffer lleva la **dirección de usuario** del proceso.
  - `sweet_ufs_strategy` hace `buf_map()` → `memcpy(vaddr + done, bounce, …)`; para buffers de physio, `buf_map` devuelve esa dirección de usuario.
  - ESR 0x9600004f: escritura (WnR=1) con permission fault de nivel 3 (DFSC 0x0f). La página de usuario estaba en solo lectura en ese instante (emulación del bit de modificado del pmap), y un `memcpy` del kernel no tiene recuperación de fault como `copyout`: panic. Estos núcleos (Cortex-A53/A73) no tienen PAN.
  - Es intermitente: depende del estado de la página de usuario en ese instante; muchas lecturas anteriores por `/dev/rufsroot0` funcionaron.
- **No tiene relación con el USB ni con 0332.** Corregido por 0334 (E7).
- **Medida operativa:** el bucle lee el ring por el dispositivo **de bloques** `/dev/ufsroot0`, que usa buffers del kernel.

## E6 — Kernel 0333 (UTMI y dp=2 por defecto, sin boot-args extra salvo `sweet_reboot=2`), 2026-11-14 02:14

Datos: `logs-telefono/e6-0333-20261114-021446/`.

| Ensayo | Ruta | Resultado | dp |
|---|---|---|---|
| 1 | R | ENUMERA en 44 s | 2 |
| 2 | R | ENUMERA en 44 s | 2 |
| 3 | R | ENUMERA en 44 s | 2 |
| 4 | C | ENUMERA en 40 s | 2 |

- Sin panics; el bucle lee el ring por `/dev/ufsroot0`.
- **SSH persistente:**
  - El job `com.sapphire.sshd-usb` (`/redwood/launchd`, lo carga `/redwood/boot.d/70-sshd-usb.sh`) arranca solo y escucha en `192.168.7.2:22`; comprobado con `ssh sapphire` tras los ensayos.
  - La columna `ssh_auto=NO` del CSV no mide sshd: el bucle la comprobaba antes de que `firstboot` ejecutara `boot.d`, unos segundos más tarde. El bucle ahora reintenta durante 60 s.
- Cmdline de 562 caracteres (≤ 575): el shim vuelve a pasar `sweet_splash`. Sin confirmar a la vista que reaparece la imagen de arranque.

## E7 — Parche 0334 (E/S cruda de UFS sin memcpy a memoria de usuario), 2026-11-14 ~02:30

Kernel de CI, run 43570770230, sha `ffcc981f…`, con 0334 aplicado. Imagen `boot_a-0334.img` con boot-args
de expG más `sweet_reboot=2`. Ruta R; iOS respondía a los 27 s. Ciclo automático: SSH a fastboot,
flash, arranque y prueba.

| Prueba (como root, por SSH) | Resultado |
|---|---|
| `dd if=/dev/rufsroot0 bs=4096 skip=67107839 count=1025` (la que paniqueaba en E5) | **30/30 completas** (4 198 400 B), sin panic |
| `bs=4194304 count=4` | **10/10 completas** (16 MiB) |
| `bs=1048576 count=64` | 67 108 864 B exactos |
| `bs=100 count=1 skip=1` (offset no alineado) | `Invalid argument`: EINVAL, como diseña 0334 |

- El `dd` del teléfono no acepta sufijos de tamaño (`4m` → "invalid number"): hay que dar el tamaño en bytes.
- Conclusión: el panic de E5 está corregido por 0334. El bucle sigue leyendo por `ufsroot0`.
- No probado: escritura cruda con `ufsrw=1`.

## CPU-0334 — Muestreo en reposo (2026-11-14 02:34)

Datos: `logs-telefono/cpu-0334-023406/muestras.txt` (las horas del archivo son las del reloj del teléfono).
20 muestras de `uptime` + `ps` cada 30 s, unos 10 min, tras arrancar 0334 por la ruta R. Load de 1 min:
4,79 en la primera muestra y **1,13-2,61** en las demás (8 núcleos). Ningún proceso dominante: cfprefsd
6-12 %, notifyd 4-7 %, launchd ~5 %, logd ~2,5 %. Análisis y siguiente paso en 07.

## M1 — Dónde se va el frame: perfil del hilo de render (2026-11-14, tarde)

Kernel 0334 (`boot_a-0334.img`, ruta R), `sweetmetal=2`, `HakiosMetal` sha256 `13bbd782…` (el binario del
repo). Carga: `swipetest.sh 5`. Capturas de pantalla (`tools/perf/fbshot.c`) muestran que el guion no llega al
home: el teléfono sigue en la pantalla de bloqueo y lo que se anima es el Centro de Control abriéndose y
cerrándose sobre ella, más los deslizamientos laterales del bloqueo. La carga es reproducible (M2: 23,5-23,8
buffers/s en seis ensayos), pero no es el home.
Herramientas: `tools/perf/` (`thrtop`, `psamp`, `symb.py`). Datos: `research/metal/medicion/`.

**Observado.**

- `SWEET FB: 5 s`: 105-152 frames por ventana de 5 s durante la prueba (21-30 fps de media; la ventana
  incluye las pausas entre gestos), 3 series.
- `thrtop` 22 s (n=1): en backboardd, `com.apple.coreanimation.display.primary` consume 13 995 ms de usuario
  y 2 930 ms de sistema (76,9 % de un núcleo, pausas incluidas); `render-server` 8,1 %; el proceso entero,
  98,9 % de un núcleo. SpringBoard: hilo principal 34,2 %, proceso 47 %.
- `psamp` del hilo `display.primary`, 20 s a 0,5 ms, n=3 (`psamp-{1,2,3}.txt`, `perfil-{1,2,3}.txt`):

| Serie | Muestras | En modo usuario | HakiosMetal (self) | QuartzCore | malloc | memmove/memset | Ruta de draw de HakiosMetal (inclusive) |
|---|---|---|---|---|---|---|---|
| 1 | 17 958 | 90,3 % | 47,2 % | 26,8 % | 9,4 % | 8,2 % | 57,8 % |
| 2 | 16 673 | 83,6 % | 37,5 % | 36,4 % | 10,4 % | 7,1 % | 45,6 % |
| 3 | 17 636 | 88,1 % | 49,1 % | 27,2 % | 9,4 % | 6,9 % | 60,0 % |

  (porcentajes de las cuatro columnas centrales y de la última: sobre las muestras en modo usuario).
- Serie 1, inclusivo: `-[HakiosMetalRenderCommandEncoder hakiosDraw:…]` 57,8 % → `CommandBuffer::draw`
  45,4 % → `render::encodeDraw` 24,1 % (8,8 % self), `appendDeduped` 10,1 % (7,1 % self),
  `bindArgumentBuffers` 3,4 %, `programAddress` 2,3 %, `stageTextures` 2,2 %; `checkTarget`, `checkStage`,
  `link`, `vertexFetch`, `pushedRanges` en torno al 1 % cada una. `Texture::replace` 1,6 %; `commit` 1,3 %.
- Las muestras detenidas en una llamada al kernel son el 10-16 %; las que entran por IOKit (submit y
  esperas de la GPU), el 5 % (serie 1).

**Interpretación.** Durante la animación el hilo de render de CoreAnimation está saturado de CPU y la GPU
no lo frena: el tiempo de frame lo fija el coste de CPU por draw del driver Metal (codificar el estado
completo de cada draw y deduplicarlo contra una sombra de registros, validaciones, enlace y asignaciones
de memoria por draw). El número de draws por frame no está medido aún.

## M2 — Contadores del driver y A/B de sus opciones (2026-11-14, tarde)

Mismo kernel y binario que M1. Opciones por `/var/tmp/metal.args`, `metal_fps=1` en todas; cada ensayo
reinicia backboardd y ejecuta `swipetest.sh 5` (`tools/perf/ab.sh`). Datos: `research/metal/medicion/ab/`.
Las cifras son los contadores del propio binario (sin verificar contra una medida independiente salvo el
coste de CPU, coherente con M1). "Buffers/s" son command buffers confirmados por segundo en los periodos con
movimiento; "a tiempo / tarde / paradas" son los huecos entre commits de ≤ 20 ms, ≤ 50 ms y > 50 ms.

| Condición | n | Buffers/s | A tiempo | Tarde | Paradas | Draws/buffer | CPU/draw (hilo de render) | Hecho→commit | Commit→fin | GPU ocupada |
|---|---|---|---|---|---|---|---|---|---|---|
| (sin opciones) | 3 | 23,5-23,8 | 31-40 | 397-435 | 173-205 | 151-154 | 126-128 µs | 28,9-29,7 ms | 31,2-33,0 ms | 73-76 % |
| `metal_defer=1` | 3 | 27,6-28,4 | 204-241 | 422-426 | 153-166 | 151-154 | 46-47 µs | 22,9-24,5 ms | 59,9-61,9 ms | 151-161 % |
| `metal_defer=1 metal_gmem_off=8` | 3 | 26,0-27,5 | 153-238 | 367-420 | 155-183 | 151-155 | 44-46 µs | 23,3-26,8 ms | 54,8-63,4 ms | 127-161 % |
| `metal_gmem_off=16` (sin binning) | 3 | 22,7-23,1 | 27-35 | 382-403 | 177-201 | 146-153 | 124-126 µs | 30,5-30,8 ms | 41,9-44,2 ms | 95-101 % |
| `metal_gmem=0` | 3 | 23,7-24,3 | 33-43 | 443-456 | 184-194 | 151-152 | 126-127 µs | 28,9-29,0 ms | 30,9-32,4 ms | 72-78 % |

Otras líneas del driver en la condición sin opciones: la pasada principal es `draw 750x1624 draws 108-132 in
102 tiles` y tarda 20-24 ms de GPU (18 ms con 108 draws y la pantalla quieta); un buffer lleva 3-11 pasadas;
`buffers: 0 made, 120 taken again from the pool`; el sombreador de CoreAnimation `fixed_frag_lph` queda en
128-320 palabras de instrucción por variante tras especializarlo.

**Interpretación.**

- Hay dos límites por frame, los dos por encima de 16,7 ms: la CPU del hilo que codifica (≈ 150 draws ×
  126 µs ≈ 19 ms, más el resto del compositor) y la GPU (20-24 ms la pasada principal).
- La grabación diferida saca la codificación del hilo de render (126 → 46 µs por draw) y sube los buffers por
  segundo un 18 %, pero el tiempo de commit a fin se duplica: el límite pasa al hilo de grabación y a la GPU.
  El contador "GPU ocupada" supera el 100 % en esa condición, así que no mide solo GPU (sin verificar qué suma).
- El binning por hardware reduce el trabajo de GPU (74 % → 97 % al quitarlo).
- `metal_gmem=0` no cambia nada: GMEM está activo sin esa opción y la opción no lo apaga.

## M3 — Frecuencia real del núcleo de la GPU (2026-11-14, tarde)

Kernel 0334, boot-args con `gpu_mhz=1260 gpu_div=1`. Herramienta `tools/perf/gxfreq.c`: por el cliente `SGPU`
del kernel hace que el procesador de comandos de la GPU copie a memoria dos contadores de ciclos del reloj
de núcleo (`PERF_CP_ALWAYS_COUNT`, `PERF_RBBM_ALWAYS_COUNT`) y el contador del cristal de 19,2 MHz
(`CP_ALWAYS_ON_COUNTER`), dos veces separadas 200-300 ms; la frecuencia es el cociente.

**Observado.** 3 ejecuciones de `gxfreq 200 5` (15 muestras): los dos contadores dan **630,00 MHz** en las 15.

**Interpretación.** `gpu_mhz=1260` deja el VCO de `gpu_cc_pll0` a 1260 MHz y el núcleo de la GPU a la mitad.
La comparación con los niveles de Android está en [11](11-gpu-relojes-bus-vs-android.md).

## M4 — Kernel 0338 con el PLL de la GPU como Android (2026-11-14, tarde)

Kernel de CI, run 43612053690 (0336, 0337 y 0338 aplicados; 336 parches). Imagen
`boot_a-0338-vco2-1260.img`: boot-args de expG con `sweet_reboot=2 gpu_vco2=1 gpu_mhz=1260` (575 caracteres).
Ruta R, un arranque (n=1), sin pasar por los escalones intermedios de la escalera de 11 §8. Driver cargado:
`rebuild/out/propio-args` (upstream de HackiOS `63fc2b4` + parches A610 propios + `metal.args`).

**Observado.** El teléfono arranca y responde a los 21 s. `sysctl kern.sweet_gpu_pll`: `gx_gfx3d 1260000 kHz
from gpu_cc_pll0 OUT_MAIN; … l 131 alpha 4000 user_ctl 0100010f …: VCO 2520000 kHz`. `gxfreq 200 3`: **1260,00
MHz** en las 3 muestras, con los dos contadores.

**Sin medir en este arranque:** el tiempo de GPU de la pasada principal, los contadores `kern.sweet_fb_diag` y
`kern.sweet_gpu_diag` de 0336, la temperatura bajo carga y la estabilidad a lo largo del tiempo.

## M5 — Bundle propio y pruebas con los demonios de radio (2026-11-14, tarde)

- **Bundle propio (`propio-args`) con el kernel 0334 a 630 MHz:** carga, pinta el home con colores correctos
  (captura `medicion/shots/propio1-0.png`) y da cifras del orden de las del binario de Angel en el primer
  ensayo, con la caché de stages vacía (cada especialización tarda ~0,8 s la primera vez). Los ensayos 2-4 con
  la caché caliente están en `medicion/ab/ab-propio-args-{2,3,4}.txt`, sin resumir.
- **Demonios de radio y localización:** en reposo (40 s) todo el sistema consume el 18 % de un núcleo; CommCenter,
  wifid y locationd, 0,4 % cada uno. Congelarlos con SIGSTOP durante la prueba no da una comparación válida:
  cambia lo que se dibuja (111 draws por buffer en vez de 151) y SpringBoard deja de trabajar. Las imágenes
  `boot_a-0334-noradio.img` (`modem=0 wifi=0 ipa=0`) y `boot_a-43603985878-radio.img` (control) están
  construidas y sin probar. `CalendarWidgetExtension` consume ~57 % de un núcleo durante la prueba en todas las
  condiciones.

## M6 — Pruebas cortas a 1260 MHz (2026-11-14, tarde)

Mismo arranque que M4 (kernel 43612053690, `gpu_vco2=1 gpu_mhz=1260`). n=1 por condición: orientativo.

**Observado.**

- `kern.sweet_gpu_pll`: `speed bin 0`, `RPM votes of this driver: CX 464 MX 416`. Las líneas `SapphireGpu` del
  arranque ya no estaban en `dmesg` a los 9 min.
- Bundle `propio-args` (`tools/perf/ab.sh`): sin opciones, 19,7 buffers/s, 157 µs de CPU por draw, hecho→commit
  30,4 ms, commit→fin 21,5 ms, GPU ocupada 42 %; pasada principal en GMEM `draws 99-124 in 102 tiles`
  15,6-16,5 ms; pasadas `draws 39 in sysmem` 20,4-23,3 ms. Con `metal_defer=1` solo salió un periodo con
  movimiento (17,5 buffers/s, 81 µs por draw).
- Con el binario heredado a 1260 MHz la consola no recogió ninguna línea `fps:` en dos ensayos: el binario no
  estaba cargado y CoreAnimation componía por software (causa en M8).
- `kern.sweet_fb_diag` acumulado desde el arranque (~15 min): `swaps 6758 flips 5689 … overwritten 931`: el
  13,8 % de los frames entregados se pisó en el buffer trasero sin llegar al panel.
- `kern.sweet_gpu_diag` acumulado: 5 520 submits; 8,91 s dentro de la llamada, de ellos 8,64 s en limpieza de
  caché (28,0 GB en 5 675 limpiezas: 1,5 ms y ~4,9 MB por submit); 6 575 `GEM_NEW` (1,44 s borrando, 0,79 s
  mapeando); 13 358 TLB flush (0,97 s; 13 251 durmieron); 5 501 esperas de fence, 95,6 s dormidas en 405 034
  miradas.

**Interpretación.** Doblar el reloj baja la pasada principal de 20-24 ms (M2, binario heredado) a ~16 ms, no
a la mitad: una parte de esa pasada no va al ritmo del reloj. Los buffers por segundo no suben porque el
límite es ahora la CPU del driver (hecho→commit 30 ms; el bundle propio, sin las tablas del port, gasta 157 µs
por draw frente a 126). En el kernel hay dos costes medidos por primera vez: 1,5 ms de limpieza de caché por
submit dentro del candado, y uno de cada siete frames pisado.

## M7 — Kernel 0342 en el home: cola de presentación y limpieza de caché (2026-11-14)

Kernel de CI, run 43620776409 (0339-0342 aplicados, 340 parches). Imagen `boot_a-0342-vco2-820.img`
(`gpu_vco2=1 gpu_mhz=820 sweet_reboot=2`; `gxfreq`: 820,00 MHz). Driver `rebuild/out/propio-args`. Carga:
`tools/perf/homeswipe.sh 8` (páginas del home, verificada con capturas). n=1 por condición, cambiando los sysctl
en caliente, con el teléfono caliente y en un ambiente caluroso: orientativo.

| Condición | Buffers/s | CPU/draw | Hecho→commit | Commit→fin | Swaps | Flips | Pisados | Submit (media) | de ello, limpieza de caché |
|---|---|---|---|---|---|---|---|---|---|
| Arranque sin tocar (`gpu_tlb=3`) | 22,1 | 161 µs | 26,7 ms | 23,3 ms | 886 | 716 | 94 (10,6 %) | 1,74 ms | 1,70 ms |
| `kern.sweet_fb_queue=1` | 19,2 | 163 µs | 30,1 ms | 25,8 ms | 781 | 781 | 0 | 1,67 ms | 1,63 ms |
| `sweet_fb_queue=1 sweet_gpu_flush=1` | 21,8 | 160 µs | 25,8 ms | 20,9 ms | 1045 | 1045 | 0 | 0,05 ms | 0,01 ms |

- Capturas con las dos opciones activas: la Biblioteca de Apps (blur) y el Centro de Control salen bien
  (`medicion/shots/hoja-kqf.png`).
- Las dos opciones quedan activas en cada arranque por `/redwood/boot.d/80-gfx.sh` (en el teléfono).
- **Bundles del driver en la pantalla de la Biblioteca de Apps** (kernel 0338, 820 MHz, capturas
  `medicion/shots/hoja-blur.png`): `propio-args` pinta bien el fondo difuminado (2 de 2); `gpu-G1`, `gpu-G2`,
  `gpu-G3` y el binario heredado lo pintan oscuro y con rayas, y la barra de búsqueda blanca (1 de 1 cada uno).
- La imagen en uso es de 820 MHz. Los fallos gráficos y el calor vistos a 1260 MHz se dieron con el driver sin
  cargar (M8); el comportamiento a 1260 MHz con el driver cargado está sin medir.

**Interpretación.** Con la cola, todo frame entregado llega al panel (flips = swaps). Con el seguimiento de
suciedad, la limpieza de caché por submit desaparece. Los buffers por segundo no cambian porque el límite sigue
siendo la CPU del driver (160 µs por draw).

## M8 — Bundles de las ramas del driver, y lecturas de Android (2026-11-14)

**Bundles en el teléfono** (kernel 0338 para G1-G3 y 0342 para el resto; GPU a 820 MHz). Pantalla de prueba: la
Biblioteca de Apps, cuyo fondo es un blur del fondo de pantalla (`tools/perf/glshot.sh`; capturas en
`medicion/shots/`: `hoja-blur.png`, `hoja-nuevos.png`, `hoja-cache.png`).

| Bundle | Qué es | Fondo difuminado |
|---|---|---|
| `propio-args` | base: upstream `63fc2b4` + parches A610 + `metal.args` | bien, 4 de 4 (intercalado con los demás) |
| `gpu-G1`, `gpu-G2`, `gpu-G3`, `gpu-G3b` | rama `gpu-pass` (grupos de estado por tile, tiles de turnip, fetch) | mal, 1 de 1 cada uno |
| `cpu-A-wip` | rama `cpu-draw` (estado guardado por programa) | mal, 3 de 3; también con `metal_keep=0` y con la caché de stages llena |
| binario heredado | el del port | mal, 1 de 1 (con este kernel) |

"Mal": el fondo sale oscuro y verdoso con rayas verticales y bloques, y la barra de búsqueda translúcida sale
blanca opaca; los iconos salen bien. Con esos bundles el arnés no recibe ninguna línea `fps:` por la consola y
backboardd consume el 250-590 % de CPU.

**Interpretación.** En todas las filas "mal" el driver no está cargado: lo que se ve es CoreAnimation componiendo
por software. `bundle.sh` copiaba el binario encima del archivo instalado (mismo vnode); el kernel conserva en el
vnode la firma de código del primer binario cargado en ese arranque, y dyld rechaza todo binario cuya firma
empiece más allá de la de aquel ("code signature does not cover entire file up to signature"). Offset de la firma
(`LC_CODE_SIGNATURE dataoff`): `propio` 8 493 120, `propio-args` 8 493 280, `gpu-G1` 8 517 424, `gpu-G3b`
8 518 192, `cpu-A-wip` 8 558 048, heredado 8 564 880 o más. En los arranques con 0338 y 0342 el primero cargado
fue `propio-args`, el menor: por eso es el único que "pinta bien". Evidencia: reproducción en la Mac con la
misma lógica de XNU y dyld (`rebuild/gpu-tools/cs-test/run.sh`, 3 de 3 por orden), y lectura en vivo de
`ioreg -c SapphireGPU`: sin cliente de backboardd con `cpu-A-wip`, con cliente a los 17 s de reinstalar
`propio-args` (informe 14, "Lo primero"). Consecuencias:

- Ningún commit de las ramas `gpu-pass` y `cpu-draw` ha corrido aún en la GPU del teléfono; esta tabla no dice
  nada de ellos.
- Los fallos gráficos y el calor que el usuario vio a 1260 MHz con el binario heredado (M6, M7) coinciden con
  este estado (composición por software a varios núcleos), no con la frecuencia de la GPU: la relación entre
  1260 MHz y esos fallos queda sin medir.
- `bundle.sh` instala ahora por renombrado (archivo nuevo y `mv`), y antes de capturar o medir hay que comprobar
  con `rebuild/gpu-tools/driver-en-uso.sh` que backboardd es cliente de `SapphireGPU`.

**Lecturas de Android en este teléfono** (Infinity-X, kernel 5.15.223, por adb sin root, ambiente caluroso;
`research/metal/android/`): cpu0-3 son los núcleos pequeños (capacidad 433, hasta 1900,8 MHz) y cpu4-7 los A73
(capacidad 1024, tabla hasta 2803,2 MHz, con el máximo en 2400 MHz en esta ROM). Zona térmica `gpu`: trips
pasivos a 95 y 100 °C; CPU a 110-115 °C. En reposo: GPU 41-43 °C, CPU 42-48 °C; con 30 s de uso, hasta 55-56 °C,
sin ningún cooling device activo. kgsl y devfreq no son legibles sin root.

**Topología en XNU** (del agente de 16, por código y `ioreg`): las CPU lógicas 0-3 son los A73 (MPIDR 0x100-0x103,
cluster P) y las 4-7 los pequeños, al revés que en Linux. Los draws que el driver contaba en "cpu0-3" corrían en
los A73. Con `sweetsched=15`, los hilos de QoS por defecto (el hilo principal de backboardd y varios de
SpringBoard) van al cluster pequeño.

## M9 — Las ramas del driver en la GPU del teléfono (2026-11-14)

Kernel 0342 a 820 MHz, `kern.sweet_fb_queue=1`, `kern.sweet_gpu_flush=1`. Bundles instalados por renombrado y
con backboardd como cliente de `SapphireGPU` comprobado en cada uno (`driver-en-uso.sh`). Carga
`homeswipe.sh 8`; captura de la Biblioteca de Apps (`medicion/shots/hoja-real.png`). n=1 por bundle, en la misma
tanda: orientativo.

| Bundle | Blur | Buffers/s | A tiempo / tarde / paradas | CPU/draw | Hecho→commit | Commit→fin | GPU ocupada | Pasada más cara |
|---|---|---|---|---|---|---|---|---|
| `propio-args` (base) | bien | 22,3 | 28 / 218 / 155 | 142 µs | 24,9 ms | 23,0 ms | 51 % | `39 draws in sysmem` 22,8 ms; principal 102 tiles ~22 ms |
| `cpu-A-wip` (rama `cpu-draw`) | bien | 29,4 | 99 / 414 / 75 | 59 µs | 13,6 ms | 27,6 ms | 81 % | principal `102-112 draws in 102 tiles` 21,8-22,7 ms |
| `gpu-G3b` (rama `gpu-pass`, 0a65a5b) | bien | 21,8 | 2 / 413 / 71 | 160 µs | 26,4 ms | 17,1 ms | 37 % | `30 draws in sysmem` 23,5 ms |
| `gpu-G4` (92ed3e7) | bien | 23,1 | 7 / 313 / 98 | 171 µs | 28,6 ms | 16,8 ms | 38 % | principal `104-106 draws in 78 tiles` 13,3-13,5 ms |

**Interpretación.** Las dos ramas hacen lo que buscaban, cada una en su cuello: `cpu-draw` baja la CPU por draw
de ~150 a 59 µs y con ello suben los buffers por segundo y los frames a tiempo, hasta que manda la GPU (81 %);
`gpu-pass` baja la pasada principal de ~22 a ~13 ms y deja la GPU al 38 %, con la CPU como límite. Falta la
fusión de las dos. Las pasadas en sysmem a pantalla completa (30-39 draws, 20-23 ms) son ahora lo más caro de GPU.
Queda instalado `cpu-A-wip`.

## M10 — Bundle fusionado, vaciado de caché antes de WFI y frecuencia de la GPU en caliente (2026-11-14)

Kernels de CI: run 43631168892 (0343, 0345-0347; imagen `boot_a-0347-vco2-820.img`) y run 43632182225 (más 0344 y
0348-0350; `boot_a-0350-vco2-820.img`). `kern.sweet_fb_queue=1`, `kern.sweet_gpu_flush=1`. Driver `merge-1`
(`cpu-draw` + `gpu-pass`, 98d2c3c), instalado por renombrado y con backboardd como cliente de `SapphireGPU`
comprobado. Carga `homeswipe.sh 8`.

**Diagnóstico de 0343 y 0344 al arrancar (lecturas).** `kern.sweet_gpu_clocks`: `gx_gfx3d` 819 998 kHz, DDR
1 555 210 kHz, CPU gold 2 803 196 y silver 1 900 802 kHz. `kern.sweet_thermal` un minuto después de arrancar: 16
sensores entre 65,6 y 70,2 °C. `kern.sweet_idle_stats` con el modo de origen: en las CPU 0-3 (A73) cada entrada en
reposo gasta 439-518 µs en el mantenimiento de caché (10 409 entradas y 4,75 s en cpu0 desde el arranque); en las
CPU 4-7, 24-28 µs. `kern.sweet_cpuregs`: CPU 0-3 MIDR 411fd090 (A73), CCSIDR de L2 70ffe07a; CPU 4-7 MIDR 51af8014.

| Condición | n | Buffers/s | A tiempo / tarde / paradas | CPU/draw | Hecho→commit | Commit→fin |
|---|---|---|---|---|---|---|
| 0347, 820 MHz, `merge-1` | 2 | 30,5 · 25,8 | 103/456/60 · 84/355/51 | 69 · 61 µs | 13,9 · 13,6 ms | 20,0 · 21,7 ms |
| 0350, `kern.sweet_idle_cache=1` (origen) | 2 | 31,6 · 29,6 | 89/526/37 · 106/379/50 | 68 · 62 µs | 14,5 · 15,0 ms | 19,4 · 20,9 ms |
| 0350, `kern.sweet_idle_cache=0` | 2 | 46,9 · 44,0 | 816/270/38 · 492/384/22 | 25 · 26 µs | 5,9 · 5,6 ms | 26,7 · 27,6 ms |
| ídem + `kern.sweet_gpu_khz=1025000` | 1 | 44,8 | 595/367/26 | 26 µs | 5,3 ms | 25,9 ms |
| ídem + `kern.sweet_gpu_khz=1260000` | 1 | 48,0 | 657/377/21 | 27 µs | 5,6 ms | 23,0 ms |

(Las dos filas de `idle_cache` se midieron intercaladas: 1, 0, 1, 0.)

- **Cambio de nivel en caliente (0345):** 820 → 1025 → 1260 MHz sin errores (`kern.sweet_gpu_opp`: 312 y 1 344 µs por
  cambio); `gxfreq` mide 1025,00 y 1260,00 MHz. Temperaturas tras cada ensayo: CPU 62,9 → 64,5 °C, GPU 60,6 → 62,9 °C.
- **Gobernador (0346)** con cima en 1260 MHz: en reposo baja a 320 MHz; durante un ensayo, 25 subidas, 5 bajadas y
  14 pasos a reposo, temperatura máxima de la GPU 71,0 °C, sin recorte térmico. Ese ensayo no es comparable (38
  draws por buffer: la pantalla no era el home).
- **Incidencias con la GPU a 1260 MHz y el gobernador activo (n=1, sin causa establecida):** SpringBoard terminó
  con SIGBUS a las 11:41:57 mientras cargaba la biblioteca de aplicaciones tras un reinicio de backboardd
  (`crash/SpringBoard-2026-11-14-114157.ips`), entró en el modo seguro del cargador de tweaks (barra de estado
  roja), y en una captura del bloqueo el fondo de pantalla sale con bloques descolocados
  (`medicion/shots/hoja-v2.png`). Con el gobernador apagado y 820 MHz fijos, tras salir del modo seguro, el home y
  su segunda página salen bien (`hoja-s.png`).
- **Estado en que queda el teléfono:** `boot_a-0350-vco2-820.img`, `merge-1`, gobernador apagado, 820 MHz, y en
  `/redwood/boot.d/80-gfx.sh`: `kern.sweet_fb_queue=1 kern.sweet_gpu_flush=1 kern.sweet_idle_cache=0`.

**Interpretación.** El vaciado de caché antes de cada WFI (16) era el mayor coste de CPU del sistema en los A73:
quitarlo baja el driver de 62-68 a 25-26 µs por draw y sube los buffers por segundo un 50 %, hasta que manda la
GPU (commit→fin 23-27 ms). Subir la GPU a 1260 MHz da poco más (48 buffers/s). Falta saber qué limita ahora la
GPU, y si las incidencias dependen del gobernador, de 1260 MHz o de `idle_cache=0`.

## M11 — Dónde se va el frame con el driver fusionado y la L2 viva (2026-11-14)

Kernel 0350 a 820 MHz fijos, `sweet_fb_queue=1`, `sweet_gpu_flush=1`, `sweet_idle_cache=0`; driver `merge-1`
cargado. Carga `homeswipe.sh 8` (≈ 45 buffers/s en M10). n=1.

- **Tiempo real de GPU** (`kern.sweet_gpu_marks=1`: marcas del contador always-on de 19,2 MHz antes y después de
  cada trabajo, en una ventana de 1 268 submits y 1 266 copias al panel):
  - submits del driver: media 8,3 ms (874 entre 4 y 8 ms, 198 entre 8 y 12, 166 entre 12 y 16, 30 por encima);
  - copia escalada al panel (kernel): media 4,15 ms (421 entre 3 y 4 ms, 843 entre 4 y 6 ms).
- **Perfil del hilo de render** (`psamp`, 12 890 muestras; `medicion/perfil-merge1-l2.txt`): 61,8 % en modo
  usuario; 23,1 % esperando en el run loop de CoreFoundation; 7,6 % dentro de la llamada de IOMobileFramebuffer
  (la retención de `SwapEnd` de 0340); 3,5 % en llamadas al kernel desde malloc. Del tiempo de usuario: QuartzCore
  52,7 %, HakiosMetal 24,7 % (ruta de draw 27 % inclusive; `closePass` 6,4 %), malloc 9,3 %, memmove/memset 6,5 %.

**Interpretación.** El hilo de render ya no está saturado: pasa casi un cuarto del tiempo esperando su siguiente
tick. Por frame (a 45 buffers/s) gasta unos 13,7 ms de CPU, de ellos ~7,2 de QuartzCore y ~3,4 del driver, y la
GPU gasta 8,3 ms en dibujar más 4,15 ms en la copia escalada del kernel: 12,5 ms, por encima de un intervalo de
120 Hz (8,33 ms) y por debajo de dos. Un tercio del tiempo de GPU por frame es la copia al panel. Lo que fija
ahora los frames por segundo es cómo se encadenan CPU, GPU, copia y presentación (ritmo y esperas), no un único
recurso saturado.

## M12 — Kernel 0352, bundles `merge-2` y `merge-3`, y scanout directo (2026-11-14)

Kernel de CI, run 43635044868 (0351 y 0352 aplicados, 350 parches); imagen `boot_a-0352-vco2-820.img`. Con 0351,
`kern.sweet_idle_cache` vale 0 al arrancar. `kern.sweet_fb_queue=1`, `kern.sweet_gpu_flush=1`, GPU a 820 MHz fijos.
Carga `homeswipe.sh 8`; n=1 por fila salvo donde se dice; driver cargado comprobado en cada bundle.

| Condición | Buffers/s | A tiempo / tarde / paradas | CPU/draw | Hecho→commit | Commit→fin |
|---|---|---|---|---|---|
| 0350, `merge-2` | 47,8 | 552 / 374 / 31 | 20 µs | 6,0 ms | 31,8 ms |
| 0350, `merge-2`, `metal_fps=passes` | 51,6 | 972 / 233 / 39 | 17 µs | 4,0 ms | 25,1 ms |
| 0352, `merge-2`, `kern.sweet_fb_scanout=1` | 47,0 · 38,5 | 1015/221/25 · 318/372/25 | 18 µs | 3,6 · 8,2 ms | 22,1 · 23,2 ms |
| 0352, `merge-2`, `kern.sweet_fb_scanout=0` | 54,8 | 959 / 228 / 19 | 18 µs | 4,1 ms | 26,0 ms |
| 0352, `merge-3` | 49,0 | 648 / 311 / 18 | 16 µs | 4,8 ms | 27,3 ms |

- **Scanout directo (0350 + 0352).** Con `scanout=2` y un reinicio de backboardd las superficies de pantalla
  pasan al pool (2 de 4 huecos) y la imagen es la de siempre. Con `scanout=1`: `plane now scaled`, `showing 13,12
  720x1600 of a surface (rows of 3072 bytes) at 0xe5500000`, CTL_FLUSH devuelve sus bits en 769 de 769 flips,
  `flushes not taken 0`, sin cuelgues. Nadie ha mirado el panel en ese modo. En una tanda: `frames 897 flips 897;
  copied instead: … swapped again while on the panel or waiting 1029`, y al final `plane to scaled 407, to unscaled
  406`. Queda en 0.
- **Pasadas con `merge-3` y `metal_fps=passes`** (tiempo de GPU por pasada): la principal, `750x1624 draws 108
  tiles 78 attached 0x3 touched 0x103 wrote 0x3 read 0x3`, 11,4 ms; pasadas `750x1624 draws 7 … sysmem`, 5,8-7,9 ms.
  Con `merge-2`: principal en 78 tiles 10,5 ms de media (6 pasadas), y en 42 tiles cuando solo toca el primer
  attachment, 2,4-3,3 ms.

**Interpretación.** El driver gasta ya 16-20 µs de CPU por draw; lo que queda por frame es GPU y encadenado. El
scanout directo funciona, pero CoreAnimation usa dos superficies de pantalla: la que está en el panel no se
puede reutilizar, más de la mitad de los frames vuelven a la copia y el plano alterna entre los dos modos; así
no gana. Pasadas de siete draws a pantalla completa cuestan 6-8 ms de GPU: el coste lo fija lo que cubren, no
cuántos draws son.

## M13 — Qué procesos reciben el dispositivo Metal, y los widgets (2026-11-14)

Kernel 0352 a 820 MHz, driver `merge-3` cargado.

- `tools/perf/mtlprobe.m` (un proceso cualquiera que llama a `MTLCreateSystemDefaultDevice`): sin opciones devuelve
  `nil`, y el driver escribe `mtlprobe is not shown the device: the window server alone is (metal_all=1: every
  process)`. Con `metal_all=1` en `/var/tmp/metal.args` devuelve `Adreno (hakios-metal, chip 0x6010001)` y crea una
  cola; tras reiniciar backboardd, SpringBoard pasa a ser cliente de `SapphireGPU` junto a backboardd. Una tanda de
  `homeswipe.sh 8` con `metal_all=1`: 43,6 buffers/s, 16 µs por draw, commit→fin 21,4 ms (n=1). Queda sin la opción.
- El widget de Calendario sale en blanco y `CalendarWidgetExtension` consume el 99 % de un núcleo, con y sin
  `metal_all=1`; la extensión no es cliente de la GPU. Su informe de límite de CPU (`medicion/crash/`): 90 s de CPU
  en 96 s; pila más pesada XPC → WidgetKit → SwiftUI → AttributeGraph → CalendarWidget → EventKitUI.
- La app Tiempo se abre y dibuja (captura `medicion/shots/app1-0.png`).

**Interpretación.** Fuera del servidor de ventanas ningún proceso tiene Metal, cuando en iOS toda aplicación cuenta
con él. El bucle del widget de Calendario no depende de Metal; su causa está sin establecer (20).

## M14 — Traza de frames reales: home y apertura de una app (2026-11-14)

Kernel 0352 a 820 MHz; bundle de traza `rebuild/out/trace-merge` (el driver de `merge-1` con `metal_trace=frame`,
de 19), cargado. Capturas en `research/metal/ios-graficos/trace/capturas/`: `metal-trace-2079-1.txt` (home, 12
command buffers, con un deslizamiento corto) y `metal-trace-2079-2.txt` (abrir Tiempo desde el home, 90), con
`informe-home.md` e `informe-abrir-app.md` (`trace-frame.py`). Después queda instalado `merge-3`.

**Observado en el home.**

- Un frame es un command buffer con una pasada (`assembly-encoder`) de 106-107 draws sobre la superficie de pantalla
  de 750×1624 BGRA8, alternando dos superficies; 11,3-11,7 ms de GPU, en 78 tiles. Los frames con contenido nuevo
  llevan además 5-10 pasadas pequeñas (`offscreen-encoder`, 64×64 y 180×73) y suman 122-150 draws.
- Con la pantalla quieta se dibuja un frame cada 100 ms.
- Toda pasada lleva un segundo colour attachment (`c1`). Lo que queda en él no lo lee ninguna pasada posterior.
- En cada pasada principal hay un draw que el driver no sirve (`106 (+1 no)`).
- Programas más usados: `CA.draw.PBGRABsovXm_TimgA2Xhf_Isrc` (25 draws), `…_Ialp` (19).

**Interpretación.** `c1` es la memoria de trabajo de la pasada (según el agente del driver, memoryless y sin carga
ni almacenamiento: no mueve memoria, pero al ocupar sitio en GMEM deja bins de 128×128 y 78 tiles en vez de 42).
El draw sin servir por frame y la causa del redibujado a 10 Hz en reposo están sin identificar.
