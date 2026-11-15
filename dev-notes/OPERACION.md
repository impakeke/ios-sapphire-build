# Operación: el ciclo de desarrollo completo

Runbook del fork para el Redmi Note 13 4G (`sapphire`) con iOS en el slot `a` y Android en el `b`.
Todo lo que sigue está medido en el teléfono del fork y en la Mac de desarrollo; los datos y su
origen están en [investigacion/03](investigacion/03-experimentos-y-datos.md). Las reglas generales
para agentes están en [../AGENTS.md](../AGENTS.md).

## 0. Reglas que no se negocian

- **Nunca escribir `boot_b` ni ninguna partición de Android** (`vendor_boot_b`, `dtbo_b`, `init_boot_b`,
  `vbmeta_b`, `super`, `userdata`, `metadata`) durante el trabajo de iOS. La única excepción es
  restaurar Android con las imágenes de su propia ROM (§8.4), y solo con confirmación del usuario.
- El kernel de iOS va **solo** en `boot_a`. Antes de cambiarlo por algo que no sea una imagen
  generada con `repack-boot.py` sobre una base buena, respaldar `boot_a`.
- No formatear `iosroot` (raíz de iOS y ring del log) ni `userdata` (datos de Android).
- Intactos siempre: bootloaders (`xbl*`, `abl*`), `recovery_*`, modem, `persist`, EFS (`modemst1/2`,
  `fsg`, `fsc`), `metadata`, los GPT.
- Confirmar con el usuario cada paso destructivo antes de ejecutarlo.

## 1. La Mac de desarrollo (Hackintosh) y sus herramientas USB

En esta Mac (Hackintosh con root patch de OCLP) **`fastboot`, `adb` y libusb no pueden abrir
dispositivos USB**: se quedan en "waiting for any device" aunque `ioreg` vea el teléfono. Lo que sí
funciona es `IOUSBHost.framework`. Las herramientas propias están versionadas en
[`tools/hackintosh-usb/`](../tools/hackintosh-usb/README.md); las copias en uso viven en
`~/adb-bridge/` (los scripts las llaman por esa ruta).

Compilar (desde `tools/hackintosh-usb/`, y copiar el binario a `~/adb-bridge/`):

```sh
clang -fobjc-arc -framework Foundation -framework IOKit -framework IOUSBHost fbusb.m -o fbusb
clang -fobjc-arc -framework Foundation -framework IOKit -framework IOUSBHost adbbridge.m -o adbbridge
```

`IOServiceMatching` con propiedades (`bInterfaceClass` etc.) no encuentra nada en esta Mac, así que
ambas herramientas recorren todas las `IOUSBHostInterface` y filtran a mano: fastboot = clase 255,
subclase 66, protocolo 3; ADB = 255/66/1.

**En una Mac o un Linux normales** se usan `fastboot` y `adb` de platform-tools; las equivalencias
están en cada paso.

### fbusb (fastboot)

Cada argumento es un comando del protocolo fastboot, en orden; se detiene en el primer `FAIL`.
`flash <part> <img>` hace `download` + `flash:<part>`.

```sh
F=~/adb-bridge/fbusb
$F getvar:current-slot
$F getvar:slot-unbootable:a getvar:slot-retry-count:a
$F flash boot_a out.img set_active:a reboot     # flashear e iniciar iOS (ruta R)
$F set_active:a continue                         # iniciar lo que hay en boot_a sin reiniciar (ruta C)
$F set_active:b reboot-recovery                  # a OrangeFox
$F reboot-bootloader
```

Equivalente normal: `fastboot getvar current-slot`, `fastboot flash boot_a out.img`,
`fastboot set_active a`, `fastboot reboot`, `fastboot continue`, `fastboot reboot recovery`.

### adbbridge (adb para OrangeFox o Android)

```sh
~/adb-bridge/adbbridge 6555 > ~/adb-bridge/bridge.log 2>&1 &
adb connect 127.0.0.1:6555
adb -s 127.0.0.1:6555 shell
```

Es frágil:
- Tras un cambio de modo (fastboot → recovery, reinicio de recovery) esperar **unos 15 s** antes de
  arrancar el puente.
- Si `adb devices` dice `offline`: `pkill -x adbbridge; adb kill-server`, volver a lanzar el puente
  y `adb connect`.
- Último recurso: desconectar y reconectar el cable.
- No canalizar datos binarios hacia `adb shell`; para leer usar `adb exec-out`.

### Scripts

| Script | Qué hace |
|---|---|
| `exp-loop.sh <etiqueta> <rutas> [timeout]` | Bucle de ensayos sin intervención (§4) |
| `watch-ios-usb.sh <etiqueta> [s]` | Observa un arranque: enumeración de 1209:0001, interfaz nueva, ping, shell 2323 |
| `to-recovery-backup.sh` | Espera el teléfono; si está en fastboot lo manda a OrangeFox (`set_active:b reboot-recovery`) y respalda `boot_a` en `~/sapphire-angel/backups/` |

Logs de los scripts: `~/sapphire-angel/logs/<etiqueta>-<fecha>/`.

## 2. El teléfono

| Qué | Dónde |
|---|---|
| Kernel de iOS | `boot_a` (imagen boot v4: shim + payload SWEETXNU) |
| Android (Infinity-X, GKI) | `boot_b` y el resto del slot `b` |
| Raíz de iOS (HFS+ con journal) | partición `iosroot` (`ufsroot=iosroot`); el ring del log está en sus últimos 1025 bloques de 4 KiB |
| Recovery | OrangeFox, se llega con `set_active:b` + `reboot-recovery` (con `a` activo, el modo recovery arranca el kernel de `boot_a`, es decir iOS) |

Respaldos (fuera de git), en `~/sapphire-angel/backups/`:
- `boot_a-expG-20261113-223928.img` (sha256 `4c27d009…bf8f`): la base de `repack-boot.py`.
- `particiones-20261114-0110/`: `abl_a/b`, `xbl_a/b`, `boot_b`, `vendor_boot_b`, `dtbo_b`, `vbmeta_a/b`,
  `recovery_a/b` y los GPT primario y de respaldo de cada LUN, con `sha256-local.txt` y
  `sha256-telefono.txt`.
- `ring-*.bin/txt`: rings de experimentos.

Imágenes de `boot_a` ya construidas: `~/sapphire-angel/boot_a-*.img`; la que está en el teléfono, en §9.1. Kernels de CI:
`~/sapphire-angel/ci-kernels/<run>/`. El respaldo del `boot_a` original de Angel
(`boot_a-ios-original.img`, sha256 `d5cceea5…`) no está en esta Mac.

## 3. Acceso a iOS

### Red USB

iOS expone un dispositivo CDC-ECM `1209:0001` "Sweet iOS (USB Ethernet)" (MAC `02:00:5e:77:ee:01`).
macOS lo toma con su propio `AppleUserECM.dext`, sin puente. El teléfono es `192.168.7.2`; la Mac,
`192.168.7.1` (en esta Mac la interfaz es `en5`). Dejar la IP fija una vez:

```sh
networksetup -setmanual "Sweet iOS (USB Ethernet)" 192.168.7.1 255.255.255.0
```

(Sin eso: `sudo ifconfig enX inet 192.168.7.1/24 up` en cada arranque. En Linux:
`sudo ip addr add 192.168.7.1/24 dev enx02005e77ee01 && sudo ip link set enx02005e77ee01 up`.)

Con un kernel ≥ 0333 el USB enumera tanto en arranque normal como saliendo de fastboot con
`continue`, entre 27 y 44 s después del `reboot` o el `continue`. Comprobar que enumeró:

```sh
ioreg -r -c IOUSBHostDevice -l -w0 | grep -q '"idVendor" = 4617' && ping -c1 -t2 192.168.7.2
```

Si el teléfono enumera, su nodo aparece en `ioreg` aunque falte un driver de clase; si no aparece, el
fallo está en el teléfono. `system_profiler SPUSBDataType` no sirve en esta Mac (no devuelve nada).

### SSH

```sh
ssh sapphire     # ~/.ssh/config: Host sapphire, HostName 192.168.7.2, User root, IdentityFile ~/.ssh/sapphire_phone
```

- Solo con clave. Lo lanza el job `com.sapphire.sshd-usb` (`/redwood/launchd/`, cargado por
  `/redwood/boot.d/70-sshd-usb.sh`; fuentes, requisitos e instalación en
  [`userland/sshd-usb/`](../userland/sshd-usb/README.md)) y escucha solo en `192.168.7.2:22`.
- `firstboot` ejecuta `boot.d` unos segundos **después** de que la red USB responda: reintentar
  durante hasta 60 s.
- En la sesión hace falta el PATH de Procursus:
  ```sh
  export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
  ```
  `sha256sum`, `sysctl` y la mayoría de utilidades están en `/var/jb`.
- El `dd` del teléfono no acepta sufijos (`bs=4m` da "invalid number"): dar los tamaños en bytes
  (`bs=4194304`).

Lanzar sshd a mano en un teléfono sin el job (desde la shell 2323):

```sh
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:$PATH
ssh-keygen -A                     # ya usa el prefijo /var/jb; no pasar -f
mkdir -p /var/root/.ssh && chmod 700 /var/root/.ssh   # authorized_keys en 600
nohup /var/jb/usr/sbin/sshd -o UsePAM=no -o PasswordAuthentication=no \
      -o PermitRootLogin=prohibit-password -p 22 -E /var/jb/var/log/sshd.log &
```

### Shell 2323

```sh
nc 192.168.7.2 2323
```

Shell root **sin autenticación** (`org.sapphire.usbshell`, la instala el instalador en todos los
teléfonos, escucha en `192.168.7.2`). Útil cuando sshd aún no arrancó; riesgos en
[seguridad.md](seguridad.md) §2. Para un comando no interactivo:
`print -r -- 'uname -a; exit' | nc -w 20 192.168.7.2 2323`.

### Log UDP

Con `sweetusb=2` el kernel manda su consola por UDP al puerto 5140 del host (`nc -ul 5140`). En esta
Mac no está verificado que llegue: para el log, usar el ring (§5).

## 4. El ciclo

### 4.1 Compilar el kernel en CI

Workflow `xnu-4k` (`.github/workflows/xnu-4k.yml`): macos-15, el Xcode 16.x más antiguo del runner
(16.0, 16A242d), darwin-xnu-build fijado. Unos 6-9 min.

```sh
gh workflow run xnu-4k -R giovannipodesta/ios-sapphire --ref sapphire
```

El workflow tiene `cancel-in-progress`: un segundo dispatch en la misma rama cancela el anterior.

### 4.2 Bajar el kernel y comprobar que lleva el parche

```sh
dev-notes/fetch-ci-kernel.sh latest            # o el run id
```

darwin-xnu-build **se salta en silencio** (un `[warning]` en el log) los parches que no aplican, así
que un run verde no garantiza nada. El script exige `conclusion=success`, que el log diga
`Applying patch: …/<PATCH>`, que el artefacto cuadre con `SHA256SUMS`, e imprime el LC_UUID. Lista
como aviso cualquier otro `Skipping patch` (`STRICT=1` lo convierte en fallo).

El parche que se comprueba es la variable `PATCH`, por defecto el último integrado
(`0352-sapphire-fb-scanout-fixes-flush-taken.patch`). Al añadir un parche nuevo, pasarlo:

```sh
PATCH=0353-sapphire-loquesea.patch dev-notes/fetch-ci-kernel.sh <run>
```

(o cambiar el valor por defecto en el script). Salida: `~/sapphire-angel/ci-kernels/<run>/{artifact/,run.log}`.

### 4.3 Empaquetar

```sh
python3 dev-notes/repack-boot.py \
  --base ~/sapphire-angel/backups/boot_a-expG-20261113-223928.img \
  --kernel ~/sapphire-angel/ci-kernels/<run>/artifact/kernel.development.sweet \
  [--set clave=valor ...] [--unset clave ...] [--cmdline-file F] \
  -o ~/sapphire-angel/boot_a-<nombre>.img
```

- Reutiliza de la base, byte a byte, el shim, el ADT, el ramdisk y (salvo `--set/--unset/--cmdline-file`)
  los boot-args; solo cambia el payload del kernel. Se autocomprueba: ida y vuelta idéntica, cabecera
  `ARM\x64` en +56, `image_size` correcto, boot-args leídos con `bootargs.py`, LC_UUID.
- Ver los boot-args de cualquier imagen: `python3 dev-notes/bootargs.py <img>`. Los de la base están
  en [angel.cmdline](angel.cmdline) (562 caracteres; llevan `sweet_reboot=0`).
- **Límite de la cmdline:** con más de **575** caracteres `loader.c` no tiene sitio para añadir
  ` sweet_splash=0x…`, así que xnu no pinta la pantalla de arranque y se ve el log temprano (el
  script avisa). Más de **607** no cabe en el campo de 608 bytes y el script se niega.
- Para el bucle de ensayos: `--set sweet_reboot=2`, así cualquier reinicio o panic vuelve a fastboot.

### 4.4 Mandar el teléfono a fastboot

- Desde iOS (SSH o 2323): `sysctl -w kern.sweet_reboot_mode=2; reboot`
  (`kern.sweet_reboot_mode`: 0 sistema, 1 recovery, 2 bootloader; el valor inicial lo da el boot-arg
  `sweet_reboot`, por defecto 2).
- Con una imagen con `sweet_reboot=2`, cualquier reinicio o panic termina en fastboot.
- A mano: Power + Volumen abajo.

### 4.5 Flashear e iniciar

```sh
~/adb-bridge/fbusb flash boot_a ~/sapphire-angel/boot_a-<nombre>.img set_active:a reboot
```

Rutas de arranque:

| Ruta | Comando | Qué es |
|---|---|---|
| **R** | `set_active:a reboot` | Arranque normal desde `boot_a` |
| **C** | `set_active:a continue` | El ABL sale de fastboot y arranca `boot_a` sin reiniciar; deja el USB del ABL inicializado |
| RAM | `fastboot boot img` | Solo RAM, no escribe flash (`CmdBoot` = `CmdContinue` en ABL, investigacion/02 §P4). Este ABL solo arranca imágenes v4 con la cabecera ARM64 (`ARM\x64` en +56); sin ella, pantalla negra, que se recupera con `fastboot reboot bootloader`. fbusb no implementa `boot` |

### 4.6 Saber dónde quedó el teléfono

| Estado | Comprobación |
|---|---|
| iOS | `ioreg -r -c IOUSBHostDevice -l -w0 \| grep -q '"idVendor" = 4617'` y `ping -c1 -t2 192.168.7.2` |
| fastboot | `ioreg -r -c IOUSBHostInterface -w0 \| grep -q 'fastboot@0'` |
| recovery / Android con adb | una `IOUSBHostInterface` con clase 255, subclase 66, protocolo 1 (la función `have_adb` de `to-recovery-backup.sh`) |

### 4.7 Ensayos automáticos

```sh
~/adb-bridge/exp-loop.sh <etiqueta> RRRC [timeout_s]
```

- Requiere `boot_a` ya flasheado con una imagen con `sweet_reboot=2`.
- Para cada letra: lleva el teléfono a fastboot (por 2323 si está en iOS), arranca por R o C y espera
  a que enumere (o a que vuelva a fastboot = panic o reinicio).
- Si enumera: guarda versión del kernel, `kern.sweet_usb_stats`, las líneas USB del ring (leído por
  `/dev/ufsroot0`), la primera línea de `kern.sweet_usb_dp`, y prueba SSH durante 60 s.
- Se detiene si no llega a fastboot o si vence el timeout sin USB ni fastboot (necesita al usuario).
- Resultado: `~/sapphire-angel/logs/<etiqueta>-<fecha>/resultados.csv`
  (`ensayo,ruta,inicio,resultado,segundos,detalle`; resultado `ENUMERA`, `VOLVIO_A_FASTBOOT`,
  `TIMEOUT` o `SIN_FASTBOOT`) y `ensayo-N.txt`.
- n≥3 por condición.

## 5. El ring persistente del kernel

El kernel copia su consola a los últimos 1025 bloques de 4 KiB de su partición raíz cada
`ufslogsecs` segundos (por defecto 10; `angel.cmdline` usa `ufslogsecs=1`). Se desactiva con
`sweetlog=0`. Tras un panic, la caja negra (parche 0146) escribe el ring con el texto del panic.

Formato: bloque 0 = cabecera `{ char magic[8] = "SWEETLOG"; u32 version; u32 size (4 MiB); u64 total;
u64 seq; }`; bloques 1-1024 = ring circular de 4 MiB. Si `total ≥ 4 MiB` el byte más antiguo está en
`total % 4 MiB`. **`seq = ~0` (read-ring.py lo muestra como `seq=PANIC`) significa que lo escribió un
panic.**

Leer desde iOS (dispositivo **de bloques** `/dev/ufsroot0`; `skip` = bloques de 4 KiB de la partición
− 1025, en el teléfono del fork 67107839):

```sh
ssh sapphire 'dd if=/dev/ufsroot0 bs=4096 skip=67107839 count=1025 2>/dev/null' > ring.bin
```

Desde OrangeFox:

```sh
P=/dev/block/by-name/iosroot
SZ=$(adb -s 127.0.0.1:6555 shell "blockdev --getsize64 $P" | tr -d '\r')
adb -s 127.0.0.1:6555 exec-out "dd if=$P bs=4096 skip=$(( SZ/4096 - 1025 )) count=1025 2>/dev/null" > ring.bin
```

Parsear y simbolizar:

```sh
python3 dev-notes/read-ring.py ring.bin ring.txt     # cabecera por stderr: total, seq o PANIC
xcrun atos -o <kernel.development.sweet> -arch arm64 <pc> <lr>
```

El kernel para `atos` es el Mach-O exacto de esa imagen (`ci-kernels/<run>/artifact/…`, o
`repack-boot.py --base IMG --extract-kernel K.macho`). Para ver un arranque completo, dejar el
teléfono en iOS al menos `ufslogsecs` + 5 s antes de leer.

## 6. Diagnóstico del USB en el kernel en marcha

```sh
sysctl kern.sweet_usb_stats   # configured, events, resets, rx/tx, rearms, halt clears
sysctl kern.sweet_usb_dp      # ruta de datos v2: start ok/refused/timeout/cmd_busy, End, noevt(α),
                              # hwo0_noevt_polls, tx/rx done, qdrop, poll_max_us, fotos
```

Valores sanos bajo carga (03, carga-1): `refused 0`, `timeout 0`, `cmd_busy 0`, `buserr 0`,
`bus_resets 1` (solo el inicial). `qdrop` sube con tráfico TCP intenso (cola TX llena, ENOBUFS; TCP lo
recupera).

Boot-args del driver (`sweet_usb.c`, parches 0329-0333):

| Boot-arg | Por defecto | Efecto |
|---|---|---|
| `sweetusb` | — (las imágenes llevan `2`) | 1 informa del estado del controlador; 2 arranca el dispositivo CDC-ECM |
| `sweetusb_utmipipe` | 1 (0332) | Selecciona UTMI como reloj PIPE en QSCRATCH `GENERAL_CFG` (Linux `dwc3_qcom_select_utmi_clk`). Necesario para enumerar en arranque normal; `0` lo desactiva |
| `sweetusb_dp` | 2 (elegido en `gadget_start`, 0333) | 2 = ruta de datos v2 (0330: un dueño por endpoint, sin reclamar por HWO, sin `printf`, DMA no cacheable); cualquier otro valor = ruta antigua |
| `sweetusb_dpnc` | 1 | Con dp=2: DMA no cacheable; `0` la deja cacheable con clean/invalidate por línea |
| `sweetusb_reclaim` | 1 | Solo ruta antigua: el reclaim por HWO de 0327; `0` lo desactiva. Con dp=2 se ignora |

Líneas del ring:
- `SWEET USB: DWC3 GSNPSID … GCTL … GUSB2PHYCFG …`: estado del controlador al tomarlo. `GCTL 0x00102000`
  y `DCFG 0x00080804` = en reset (ruta R, normal); en la ruta C vienen configurados por el ABL.
- `SWEET USBDIAG <bloque> +off w0 w1 w2 w3`: volcado de solo lectura de GCC, DWC3, QSCRATCH y PHY
  (0329). `SWEET USBDIAG utmipipe=1 GENERAL_CFG 0x00000004 -> 0x0000000d`: el reloj UTMI quedó
  seleccionado. `SWEET USBDIAG reclaim(0327)=N`.
- `ep0 cmd 0x1 timeout` / `endpoint 0 setup failed`: el controlador no tiene reloj PIPE (sin UTMI).
- `soft reset done`, `VBUS override on`, `address N`: enumeró.
- `ep3 cmd 0x6 status 1` repetido: Start Transfer rechazado (ruta antigua bajo carga).
- `SWEET USB: data path v2 (sweetusb_dp=2), DMA non-cacheable`.

El driver funciona por sondeo: la interrupción del DWC3 está enmascarada (`GEVNTSIZ` bit 31) y un
hilo del kernel lee `GEVNTCOUNT`. Detalle en [investigacion/01](investigacion/01-auditoria-sweet_usb.md)
y [05](investigacion/05-parche-0330-ruta-de-datos.md).

## 7. Ver la pantalla negra con texto

Fondo negro con el log temprano de XNU (`mig_table_max_displ`, `mach_kobj_count`,
`debug_log_init … gPanicBase`, `kdp_core zlib`) no es un panic: son líneas normales. Casi siempre
significa que la cmdline pasa de 575 caracteres y el shim no pasó `sweet_splash`. Leer el ring (§5):
si la cabecera no dice `PANIC` y el arranque llega a SpringBoard, es solo visual.

## 8. Fallos y qué hacer

### 8.1 El teléfono no enumera en iOS
1. Esperar 60 s desde el `reboot`.
2. ¿Volvió a fastboot? Con `sweet_reboot=2` eso es un panic o un reinicio: leer el ring desde
   OrangeFox (§5) y buscar `seq=PANIC`.
3. Si sigue en iOS sin USB: comprobar en el ring `utmipipe` y `ep0 cmd`. Volver a fastboot a mano.

### 8.2 Atascado en OrangeFox con adb `offline`
Esperar 15 s, `pkill -x adbbridge; adb kill-server`, relanzar el puente, `adb connect`. Si sigue:
reconectar el cable. Para salir: `adb reboot bootloader` o Power + Volumen abajo.

### 8.3 El slot no arranca y el ABL se queda en fastboot
```sh
~/adb-bridge/fbusb getvar:current-slot getvar:slot-unbootable:a getvar:slot-retry-count:a \
                   getvar:slot-unbootable:b getvar:slot-retry-count:b
```
Cada slot tiene un contador de 7 reintentos (`Gpt.java`, `userland/dualboot/sweet_slot.h`); cuando
se agota en ambos, el ABL va directo a fastboot (`slot-unbootable:a/b: yes`). La app de dual boot
repone 7 reintentos y quita `unbootable` al activar un slot (`Gpt.withActive`); que el `set_active`
del ABL haga lo mismo no está verificado. Si `boot_a` es sospechosa, reflashear una imagen buena
conocida (`~/sapphire-angel/boot_a-0334.img` o la base expG) y `set_active:a reboot`.

### 8.4 Android no arranca
Solo con confirmación del usuario. Restaurar en el slot `b` las imágenes **de la ROM instalada**
(Infinity-X): `boot`, `vendor_boot`, `dtbo`, `init_boot` si la ROM la trae, y `vbmeta`. Hay respaldos
de `boot_b`, `vendor_boot_b`, `dtbo_b` y `vbmeta_b` en `backups/particiones-20261114-0110/`
(comprobar el sha256 contra `sha256-local.txt` antes); si no, extraerlas del `payload.bin` de la ROM
(payload-dumper-go).

```sh
F=~/adb-bridge/fbusb
$F flash boot_b boot_b.img flash vendor_boot_b vendor_boot_b.img flash dtbo_b dtbo_b.img \
   flash vbmeta_b vbmeta_b.img set_active:b reboot
```

Nunca usar imágenes de otra ROM: con el `boot` de otra ROM el recovery no arranca y vuelve a fastboot
([../RECOVERY.md](../RECOVERY.md)). Un kernel Android con Baseband Guard (LSM) bloquea las escrituras
de particiones; por eso el slot `b` lleva el GKI de Infinity-X y OrangeFox oficial.

### 8.5 Un run de CI verde con un kernel que no cambia nada
`fetch-ci-kernel.sh` con el `PATCH` correcto (§4.2). Un parche que no aplica se salta en silencio.

## 9. Gráficos: driver Metal y kernel de la GPU

Estado y plan: [../GPU-ROADMAP.md](../GPU-ROADMAP.md). Mediciones: [investigacion/03](investigacion/03-experimentos-y-datos.md)
M1-M10. Herramientas: [`tools/perf/`](../tools/perf/README.md); sus copias de trabajo y los datos están en
`~/sapphire-angel/research/metal/medicion/`.

### 9.1 Configuración en uso

- Imagen: `~/sapphire-angel/boot_a-0350-vco2-820.img` (kernel de CI run 43632182225, parches hasta 0350). Boot-args:
  los de [angel.cmdline](angel.cmdline) con `gpu_mhz=820`, `sweet_reboot=2` y `gpu_vco2=1`
  (`python3 dev-notes/bootargs.py <img>` los imprime).
- `/redwood/boot.d/80-gfx.sh` (en el teléfono, fuera de git) pone en cada arranque
  `kern.sweet_fb_queue=1 kern.sweet_gpu_flush=1 kern.sweet_idle_cache=0`.
- Driver: el bundle `merge-1` instalado por renombrado (§9.3). Gobernador de la GPU apagado; GPU a 820 MHz fijos.

### 9.2 Compilar el driver

El driver es `hakios-metal` del upstream de HackiOS (`63fc2b4`) con los parches A610 propios; receta, dependencias y
pasos en [investigacion/08](investigacion/08-hakiosmetal-binario-vs-fuente.md) §5-§6. Todo vive fuera de git:

```sh
cd ~/sapphire-angel/research/metal/rebuild
./receta.sh                      # upstream 63fc2b4 + patches/a610 -> out/propio
SRC_KIND=opcional ./receta.sh    # ... + patches/opcional (metal.args) -> out/propio-args
```

Las ramas de trabajo están en `rebuild/hakios-upstream` (worktrees `wt-cpu` = `cpu-draw`, `wt-gpu` = `gpu-pass`);
`build-bundle.sh` construye un árbol cualquiera (`SRC=…`) en `out/<nombre>/`. El binario `HakiosMetal` de
`installer/update/files/` es el heredado: no es el driver en uso.

### 9.3 Instalar y comprobar que está cargado

```sh
tools/perf/bundle.sh NOMBRE          # rebuild/out/NOMBRE/HakiosMetal al teléfono, por renombrado
ssh sapphire 'killall backboardd'    # Metal carga el driver al arrancar backboardd
tools/perf/driver-en-uso.sh          # "DRIVER EN USO" = backboardd es cliente de SapphireGPU
```

- **Por renombrado, nunca copiando encima**: el kernel guarda en el vnode la firma del primer binario cargado en ese
  arranque y dyld rechaza cualquier binario cuya firma empiece más allá; entonces Metal no tiene dispositivo y
  CoreAnimation compone por software (materiales planos, blur oscuro con rayas, backboardd a varios núcleos, ninguna
  línea `fps:`). Investigacion/14, "Lo primero".
- Sin la comprobación, ni una captura ni una medida dicen nada del driver.
- La primera vez que corre un build nuevo recompila sus stages (hasta ~1 s cada uno): el primer ensayo tras instalar
  no es comparable.

### 9.4 Medir: carga, arnés A/B y capturas

- **Carga:** `homeswipe.sh N` (en el teléfono, `/var/root/`): despierta, desbloquea, va al home y hace N rondas de
  cambio de página; verificada con capturas. `userland/tests/swipetest.sh` no desbloquea: sus gestos actúan sobre la
  pantalla de bloqueo.
- **Opciones del driver sin reflashear:** `/var/tmp/metal.args` (se suma a los boot-args que lee el driver; se aplica
  al reiniciar backboardd). `metal_fps=1` saca una línea `fps:` por periodo a la consola.
- **A/B:** `tools/perf/ab.sh ETIQUETA "ARGS"` (Mac) lanza `ab-phone.sh` en el teléfono (escribe `metal.args`, reinicia
  backboardd, captura la consola con `conscat` durante `homeswipe.sh 8`, CPU por proceso y las líneas `SWEET FB`), trae
  los datos y los resume con `ab-sum.py`: buffers/s, a tiempo/tarde/paradas, draws por buffer, CPU por draw,
  hecho→commit, commit→fin. n≥3 por condición; alternar las condiciones.
- **Capturas:** `tools/perf/shot.sh NOMBRE` (vuelca las dos IOSurface de 750×1624 del doble buffer con `fbshot` y las
  pasa a PNG); `glshot.sh BUNDLE NOMBRE` instala un bundle y captura la Biblioteca de Apps (fondo con blur). Con el
  panel apagado la captura es el último frame: despertar antes (`hidtouch press 0`).
- **Frecuencia real de la GPU:** `gxfreq` (`tools/perf/gxfreq.c`): contadores de ciclos del núcleo frente al de 19,2 MHz.
- **Perfil de CPU:** `thrtop`, `psamp` y `symb.py`; `prof-phone.sh` perfila el hilo de render durante `homeswipe.sh 8`
  (`tools/perf/README.md`).
- **Tiempo real de GPU:** `kern.sweet_gpu_marks=1` y `kern.sweet_gpu_diag`: tiempo de cada submit y de cada copia al
  panel con el contador de 19,2 MHz de la GPU (03 M11).
- `SWEET FB: 5 s … N by the GPU` en el log cuenta swaps, no frames mostrados, y con `sweetfb_scale=2` (todas las
  imágenes en uso) sus tiempos salen siempre a 0 (investigacion/09 §1). Los frames que llegan al panel los da
  `kern.sweet_fb_diag`.

### 9.5 Boot-args gráficos

| Boot-arg | Imagen en uso | Efecto |
|---|---|---|
| `gpu=3 gpu_mmu=1 gpu_service=1` | sí | Arranque de la GPU, tablas de páginas propias y servicio que usan la copia al panel, Mesa y el driver Metal (0145-0154) |
| `gpu_vco2=1` | `1` | Programa `gpu_cc_pll0` como Android: `gpu_mhz` es la frecuencia del núcleo (0337). Sin él, `gpu_mhz` fija el VCO y el núcleo va a la mitad (`gpu_mhz=1260` → 630,00 MHz, investigacion/03 M3) |
| `gpu_mhz=N` | `820` | Con `gpu_vco2=1`, una fila de la tabla de stock: 320 465 600 785 820 980 1025 1100 1114 1260, sin pasar del speed bin (`gpu_bin=N`, `gpu_anybin=1`) |
| `gpu_cx=N`, `gpu_mx=N`, `gpu_ipeak=0` | — | Niveles de raíl a votar en lugar de los de stock; sin votos de corriente de pico de CX (0337) |
| `gpu_div=N` | `1` | Ruta antigua del reloj (GPLL0/N), sin efecto cuando `gpu_vco2=1` toma la ruta de stock |
| `sweetmetal=N` | `2` | Driver Metal que nombra el acelerador: 2 `HakiosMetal`, 1 `SapphireMetal` (`metal/`), 0 ninguno (0319; también `kern.sweet_metal`) |
| `sweetfb_scale=2 sweetfb_w=750` | sí | iOS dibuja a 2x (750×1624) y el kernel escala ×1,5 al panel |
| `sweetfb_hz=N` | `120` | Frecuencia que el kernel publica a CoreAnimation y periodo de su temporizador; el panel refresca a 120 Hz siempre (investigacion/09 §2.4) |
| `sweetfb_gpucopy=1` | sí | La GPU hace la copia de cada frame al panel |
| `sweetfb_queue=1`, `sweetfb_queue_hold=N` | — | Como `kern.sweet_fb_queue` y `kern.sweet_fb_queue_hold_ms` desde el arranque (0340) |
| `sweetfb_scanout=1` | — | Como `kern.sweet_fb_scanout` desde el arranque (0350) |
| `sweetfb_hold=N` | — | Como `kern.sweet_fb_hold_ms` (0338) |
| `gpu_flush=N`, `gpu_tlb=N`, `gpu_bocache=N` | — | Como sus sysctl (0339, 0341, 0342) |
| `gpu_gov=1`, `gpu_ddr=1`, `gpu_hwcg=1` | — | Gobernador, voto del DDR y clock gating desde el arranque (0346-0348) |
| `gpu_opp_drain=N`, `gpu_opp_park=1` | — | Espera máxima a la GPU ociosa al cambiar de nivel (100 ms); cambio por la vía larga (0345) |
| `gpu_clkdiag=1` | — | Relojes y temperaturas al log del arranque tras encender la GPU (0343) |
| `sweet_idle_cache=N` | — | Como `kern.sweet_idle_cache` desde el arranque (0344) |
| `sweetgl=1`, `glenv=…`, `glwait=0` | sí | Ruta OpenGL ES (Mesa y el puente EAGL, `userland/src/eagl.c`; `glwait` es la espera del puente a la GPU al final de cada frame). Con `sweetmetal=2` CoreAnimation dibuja por el driver Metal (sus líneas `fps:`, 03 M2-M10) |
| `sweet_glload=1` | sí | Cargador de las apps desde el arranque (0238, 0241), con los tweaks de ElleKit |

### 9.6 Sysctls de 0336-0352

Todos se leen o se escriben en caliente (`sysctl -w`). "Por defecto" es el valor sin boot-arg.

| Sysctl | Parche | Por defecto | Efecto |
|---|---|---|---|
| `kern.sweet_fb_diag` | 0336 | solo lectura | Presentación: intervalos entre swaps y entre flips en refrescos reales del panel, latencia swap→flip, frames pisados (`overwritten`), retraso de los ticks. Acumulado: leer antes y después |
| `kern.sweet_gpu_diag` | 0336 | solo lectura | Submits (tiempo dentro, candado, limpieza de caché), `GEM_NEW`, TLB, esperas de fence, copias al panel. Acumulado |
| `kern.sweet_gpu_marks` | 0336 | 0 | 1: tiempo de GPU de cada submit y cada copia con `CP_ALWAYS_ON_COUNTER` |
| `kern.sweet_gpu_pll` | 0337 | solo lectura | Modo, L, alpha, `USER_CTL`, RCG, votos y speed bin de la GPU, leídos de los registros |
| `kern.sweet_fb_hold_ms` | 0338 | 0 | Retener `SwapEnd` hasta la copia anterior. Sin efecto en este teléfono: actúa en una rama que aquí no se toma (investigacion/15 §0.1) |
| `kern.sweet_gpu_flush` | 0339 | 0 | 1: limpiar de caché una superficie solo si la CPU pudo tocarla desde la última limpieza (1,70 → 0,01 ms por submit, 03 M7); 2: además niega la memoria de cliente de las superficies |
| `kern.sweet_gpu_flush_stats` | 0339 | solo lectura | Superficies nombradas, limpiadas, omitidas |
| `kern.sweet_fb_queue` | 0340 | 0 | 1: cola de presentación: presenta en `SwapEnd`, tres flip buffers, flip en cuanto termina la copia (frames pisados 10,6 % → 0, 03 M7) |
| `kern.sweet_fb_queue_depth`, `_hold_ms`, `_poll_us` | 0340 | 2, 50, 500 | Frames en espera antes de frenar `SwapEnd`, espera máxima, periodo del hilo que hace los flips |
| `kern.sweet_fb_queue_diag` | 0340 | solo lectura | Estado y contadores de la cola |
| `kern.sweet_gpu_tlb` | 0341 | 3 | Bit 0: sin invalidar la TLB del SMMU al solo mapear; bit 1: espera de la sincronización sin dormir. 0 = como antes |
| `kern.sweet_gpu_tlb_stats` | 0341 | solo lectura | Invalidaciones con y sin dormir |
| `kern.sweet_gpu_bocache` | 0342 | 0 | 1: guarda los buffers que un cliente cierra y se los reentrega borrados; 2: sin borrar (Metal promete buffers a cero: con cuidado) |
| `kern.sweet_gpu_bocache_stats` | 0342 | solo lectura | Guardados, reentregados, liberados |
| `kern.sweet_gpu_clocks` | 0343 | solo lectura | Mide GPU, buses, DDR y CPU con el contador de relojes de Qualcomm (~0,2 s) |
| `kern.sweet_ddr_khz` | 0343 | solo lectura | Reloj del DDR (1 555 210 kHz bajo iOS, 03 M10) |
| `kern.sweet_thermal`, `kern.sweet_gpu_temp` | 0343 | solo lectura | Los 16 sensores TSENS por zona de stock, en milésimas de °C; el 15 es la GPU |
| `kern.sweet_idle_cache` | 0344, 0351 | 1 hasta 0350; 0 desde 0351 | Mantenimiento de caché antes de WFI: 1 = L1 y la L2 del cluster (lo de upstream), 2 = solo L1, 0 = nada (la imagen en uso pone 0 por `80-gfx.sh`: 62-68 → 25-26 µs por draw, 03 M10). 0351 además corrige el límite de niveles de los bucles por set/way |
| `kern.sweet_idle_stats`, `kern.sweet_cpuregs` | 0344 | solo lectura | Entradas en reposo y tiempo de mantenimiento por CPU; MIDR, MPIDR, CLIDR, CCSIDR… de cada CPU |
| `kern.sweet_gpu_khz` | 0345 | frecuencia de arranque | Escribir una fila de la tabla en kHz (p. ej. `1260000`) cambia el nivel en caliente con sus votos (312-1344 µs, 03 M10). Requiere `gpu_vco2=1`; con el gobernador activo da EBUSY |
| `kern.sweet_gpu_opp`, `kern.sweet_gpu_opp_park` | 0345 | solo lectura, 0 | Cambios hechos y sus tiempos; 1 = cambio por la vía larga (RCG a GPLL0/2, PLL rearrancado) |
| `kern.sweet_gpu_gov` | 0346 | 0 | 1: gobernador por ocupación (cada 50 ms) con tope térmico; en reposo baja a 320 MHz |
| `kern.sweet_gpu_khz_max`, `_khz_min`, `_temp_max` | 0346 | arranque, 320000, 95000 | Cima y suelo del gobernador; temperatura de la GPU (m°C) a partir de la que baja de nivel |
| `kern.sweet_gpu_gov_ms`, `_gov_up`, `_gov_down`, `_gov_idle_ms` | 0346 | 50, 80, 40, 100 | Periodo, umbrales de subida y bajada (% ocupado) y tiempo ocioso para el nivel mínimo |
| `kern.sweet_gpu_gov_stats` | 0346 | solo lectura | Subidas, bajadas, pasos a reposo, temperatura máxima |
| `kern.sweet_gpu_ddr`, `kern.sweet_gpu_ddr_floor` | 0347 | 0, 0 | 1: vota el DDR según el nivel de la GPU, como kgsl; suelo en kHz. Sin probar en el teléfono (investigacion/17 §8) |
| `kern.sweet_gpu_ddr_stats` | 0347 | solo lectura | Votos, rechazos, DDR antes y 20 ms después |
| `kern.sweet_gpu_hwcg` | 0348 | 0 | 1: clock gating por hardware de los bloques de la GPU (tabla `a612_hwcg`). Sin probar en el teléfono |
| `kern.sweet_fb_regs`, `kern.sweet_fb_latch` | 0349 | solo lectura | Registros del DPU (MDP TOP, CTL0, VIG0 y su escalador, LM0, PP0, INTF1) y cómo toma el MDP cada flush |
| `kern.sweet_fb_scanout` | 0350 | 0 | 1: el VIG0 escanea la superficie de iOS con su escalador, sin copia de la GPU (reiniciar backboardd tras activarlo); 2: solo el pool. Sin probar en el teléfono (investigacion/18) |
| `kern.sweet_fb_scanout_diag` | 0350, 0352 | solo lectura | Estado del scanout, por qué se apagó si lo hizo, y qué regla toma los flips |
| `kern.sweet_fb_flush_taken` | 0352 | 0 | 1: todo flip, también los de copia, se da por tomado cuando los bits de `CTL_FLUSH` se leen limpios (0 = por el contador de frames, como 0340). Boot-arg `sweetfb_flush_taken`. 0352 corrige además tres fallos del scanout de 0350. Sin probar en el teléfono |

Con el gobernador activo y la GPU a 1260 MHz hubo una incidencia sin causa establecida (SIGBUS de SpringBoard y fondo
con bloques descolocados, n=1, 03 M10): la imagen en uso queda a 820 MHz fijos.
