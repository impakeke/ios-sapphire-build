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
repo). Carga: `swipetest.sh 5` (páginas del home a izquierda y derecha, abrir y cerrar el Centro de Control).
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
