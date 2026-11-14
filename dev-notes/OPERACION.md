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

Imágenes de `boot_a` ya construidas: `~/sapphire-angel/boot_a-*.img`. Kernels de CI:
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

El parche que se comprueba es la variable `PATCH`, por defecto el último del fork
(`0334-sapphire-ufs-raw-io-no-user-memcpy.patch`). Al añadir un parche nuevo, pasarlo:

```sh
PATCH=0335-sapphire-loquesea.patch dev-notes/fetch-ci-kernel.sh <run>
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
