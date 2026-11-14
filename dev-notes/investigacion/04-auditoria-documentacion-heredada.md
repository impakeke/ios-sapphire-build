# 04 — Auditoría zero-trust de la documentación heredada (sin el driver USB) — 2026-11-14

**Autor:** agente Claude Opus 5.5 (98 herramientas, unos 13 min). Trabajó solo en lectura.

**Método:**
- Leyó todos los documentos del repo. De NOTES.md leyó a fondo las líneas 1-500 (2026-10-19 a 11-08) y el resto por temas.
- Descargó en solo lectura los assets de la release v0.1.8: `sapphire-kernel.img`, `sapphire-recovery.zip` y `sapphire-overlay.tar.gz`.
- Revisó los logs de CI y el `build.sh` de darwin-xnu-build en el SHA fijado.

**Aviso:** lo que está por debajo de NOTES.md:451/798 es de la época *sweet* (otro teléfono y otro autor). No vale como evidencia para sapphire.

Los archivos descargados (incluido el overlay con `master.passwd`/`spwd.db`) quedaron en el scratchpad de la sesión. Se movieron a `~/sapphire-angel/research/auditoria-docs/`, fuera de git, porque **contienen un hash de contraseña**.

## Lo más importante

1. **El script que reparticiona y escribe `boot_X` no está en git.** El `.gitignore:4` (`recovery/`) excluye en silencio `installer/recovery/` (`git check-ignore -v installer/recovery/sapphire.sh`). Se leyó desde `sapphire-recovery.zip` de la release.
2. **Hay un hash de contraseña real en el overlay público.** `scrub.py` pone `*` solo en `/var/jb/etc/master.passwd`. Pero el overlay v0.1.8 trae `private/var/jb/etc/spwd.db` (del 22 oct) con **`mobile` = hash `$6$` (SHA-512 crypt)** y `root` = `!`. libiosexec busca usuarios **solo** en pwd.db/spwd.db (NOTES.md:482-483). Por tanto, "mobile/root sin contraseña" es falso, y la contraseña efectiva de `mobile` es la de Angel. Además, eso filtra su hash.
3. **Se ejecuta código root sin firmar al arrancar.** `sapphire-update.sh` (está en el zip) ejecuta como root, en cada arranque, cualquier `*.supdate` del inbox de `iosroot`. Solo comprueba un sha256 que viene en la propia cabecera, sin firma; lo lanza `com.sapphire.firstboot` (root). El inbox se puede escribir desde Android con root.
4. **El kernel de la release no se puede reproducir desde el árbol.**
   - Firma interna: `Darwin Kernel Version 22.6.0: Fri Nov 13 17:37:11 CET 2026; angel:xnu.obj/DEVELOPMENT_ARM64_SWEET`. Es un build local en WSL (clang 18 parcheado + iig-lite).
   - Se compiló **7 min antes** del commit de los parches 0323-0325 que contiene (1cdcbfb, 17:44:34) y 51 min antes del tag (be9c5aa).
   - Se reempaquetó sobre un `BASE.img` local (`/mnt/c/adb/...`) que no está en el repo.
   - Se anuncia un `SHA256SUMS` que no existe.
5. **La imagen de la release redistribuye firmware de Qualcomm de un teléfono concreto** dentro del ADT: `gpu-sqe-firmware` (32 504 B), `gpu-zap-segment` (2096 B, firmado) e `ipa-fws-image` (ELF, 29 120 B). También incluye un FV de UEFI (`_FVH` @0x10d8) con DXE de tapas y el DTB del teléfono de Angel. README.md:196 y HANDOFF.md:63 dicen que no se debe redistribuir; installer/MANIFEST.md:18 dice que sí.
6. **Las reglas de arranque se contradicen entre sí.**
   - AGENTS.md, HANDOFF.md, README.md y RECOVERY.md dicen "solo `fastboot boot`, nunca flashear iOS en `boot`".
   - Los dev-notes del fork dicen "`fastboot boot` BRICKEA, flashea `boot_a`".
   - El instalador **flashea** `boot_<slot iOS>`.
   - Ninguna de las dos reglas es correcta tal como está escrita.
7. **RECOVERY.md es peligroso en dual-boot.** Su "Fix" (`set_active a` + `flash boot_a ROM-boot.img`) pisa el kernel de iOS (`boot_a` = iOS) y deja la heurística de slots del instalador apuntando al slot equivocado.
8. **README.md está muy desactualizado** (4 núcleos, sin GPU, sin datos, Wi-Fi sin asociar, "SSH Invalid user root", raíz en `userdata`, cadena sin UEFI). NOTES.md se corta el 2026-11-08: **nada de lo de 0.1.7/0.1.8 tiene una medición registrada.**

## 1. Rutas de arranque y seguridad del flasheo

| Afirmación | Ubicación | Veredicto | Evidencia | Impacto |
|---|---|---|---|---|
| "kernel started from RAM with `fastboot boot`; boot partitions do not need to be flashed" | README.md:9,15,102,107 | OBSOLETA | Era el bring-up de Angel (NOTES.md:194,383). La ruta instalada flashea: `sapphire.sh:583-603` hace `dd` a `boot_$slot`; installer/README.md:19 | Alto |
| "never flash iOS into `boot`" | AGENTS.md:10-11; HANDOFF.md:84-86; README.md:107 | CONTRADICHA por el diseño | El instalador escribe en `boot_<no-Android>` (`sapphire.sh:92-97`, `583-603`) | Alto |
| "`fastboot boot` BRICKEA" | acceso-al-telefono.md:40; build-recipes.md:78,81; continuar-en-otra-maquina.md:41; toolchain-findings.md:29,56 | CONTRADICHA | 01 y 02 §P4 (`CmdBoot`=`CmdContinue`, solo RAM). NOTES.md:466: el ABL exige v4 **con cabecera ARM64**, y la imagen v1 del fork no la tenía. uefi/README.md:45: la pantalla negra se recupera con `fastboot reboot bootloader` | Alto |
| `fastboot boot` es solo RAM y seguro | RECOVERY.md:42; README.md:107 | RESPALDADA (con matiz) | 02 §P4. El riesgo real de no arrancar nada es la incoherencia del GPT A/B | Medio |
| Un GPT A/B incoherente impide que el ABL cargue nada ("Device Error, every slot, even fastboot boot") | android/dualboot/src/com/sapphire/dualboot/Gpt.java:124-133 | SIN VERIFICAR | La app y `userland/dualboot/sweet_slot.*` reescriben el GPT del LUN A/B (sde) desde Android **y desde iOS**. Si es cierto, este es el verdadero brick blando | Alto |
| `boot_a` = iOS, `boot_b` = Android | continuar-en-otra-maquina.md:40; build-recipes.md:83 | RESPALDADA para este teléfono | HANDOFF.md:65; `ios_slot()` lo decide en cada instalación | Medio |
| "the Android slot is `a` on most phones… `fastboot set_active a`" | docs/INSTALL.md:108-110 | CONTRADICHA en este layout | Aquí Android está en `b` | Alto |
| El instalador toma como slot de iOS el opuesto a `ro.boot.slot_suffix` del recovery | sapphire.sh:92-97; sapphire-install.sh:346; Installer.cs:518 | RESPALDADA (código), con riesgo | Si alguien restaura Android en `boot_a`, la siguiente instalación escribe iOS en `boot_b`, que es el Android real | Alto |
| "In recovery mode ABL boots the kernel in `boot` of the active slot" | RECOVERY.md:8-13 | SIN VERIFICAR (n=1, teléfono de Angel) | Coherente con `sapphire.sh:122`, pero choca con "OrangeFox en `recovery_b`" y con que exista `recovery_a`. Sin fuente en ABL | Alto |
| "Fix: `set_active a` / `flash boot_a ROM-boot.img`" | RECOVERY.md:29-33 | OBSOLETA y peligrosa | Escrita antes del dual-boot | Alto |
| "userdata is the iOS root" | RECOVERY.md:38; AGENTS.md:11; README.md:9,44 | OBSOLETA | Es la partición `iosroot` (`sapphire.sh:38`, `ufsroot=iosroot`) | Medio |
| "Every failed boot marks the slot unbootable" | RECOVERY.md:14-15 | SIN VERIFICAR / imprecisa | Contador de 7 reintentos (Gpt.java:129-131; sweet_slot.h:28-30); iOS nunca se marca como bueno | Medio |
| "never writes persist, the modem, RPMB or the other partitions" | docs/INSTALL.md:35-36; installer/README.md:57 | CONTRADICHA (en parte) | Reescribe ambas copias del GPT del LUN 0 (sapphire-part.c:10-11,224); **pone a cero 64 MiB de `metadata`** (claves de cifrado de Android) al reparticionar (`sapphire.sh:164-180`); `set_active` cambia GUIDs y atributos | Medio |
| "The first install ERASES ANDROID" | docs/INSTALL.md:30-33 | RESPALDADA | sapphire-install.sh:211-218,298-316; hay borrado diferido si quedó `format-pending` | Alto |
| Requiere "OrangeFox installed" | INSTALL.md:19 | RESPALDADA | `twrp install`, `/dev/fuse`. No dice **dónde** va OrangeFox | Medio |
| Cadena "ABL → fastboot boot → shim → XNU" | README.md:15,34-42 | OBSOLETA | Ahora es ABL → BootShim → UEFI Mu-Silicium → SapphireXnuBoot → shim → XNU (uefi/README.md:7) | Medio |
| "No USB link… (only when booted with fastboot boot)" | notas de la release | RESPALDADA (n=1 por ruta) | 03 E1, 02 §P4 | Medio |

## 2. Seguridad

| Afirmación | Ubicación | Veredicto | Evidencia | Impacto |
|---|---|---|---|---|
| "mobile and root have no password" | INSTALL.md:89; release | CONTRADICHA | `spwd.db` del overlay: root=`!`, **mobile=`$6$` real**; libiosexec solo lee pwd.db/spwd.db | Alto |
| scrub.py quita los "secrets (master.passwd hashes)" | scrub.py:4-5; make-overlay.sh:34 | CONTRADICHA (incompleto) | No toca `spwd.db`, `pwd.db` ni `passwd` | Alto |
| "set one with `passwd` for SSH" | INSTALL.md:89; release | CONTRADICHA | Medido el 13 nov: sin job, sin claves de host, sin authorized_keys; `PermitRootLogin yes`, `UsePAM yes` | Medio |
| "Invalid user root" | README.md:27 | OBSOLETA | NOTES.md:481-483 | Bajo |
| Shell root sin autenticación en 192.168.7.2:2323 | acceso-al-telefono.md; 03 | RESPALDADA y **se instala en todos los teléfonos** | `org.sapphire.usbshell.plist` (UserName root, bash, `SockNodeName 192.168.7.2`), sin documentar. No se verificó si se alcanza por Wi-Fi | Alto |
| `wifi_pass` "never logged and wiped" | 0144:8-10,24-34 | CONTRADICHA en la práctica | Solo se borra la copia en la pila; sigue en el cmdline, el ADT, `kern.bootargs` y el log de launchd (NOTES.md:774). La release no lo lleva | Medio |
| Los logs contienen SSIDs e identificadores | .gitignore:1,19-20 | RESPALDADA | Pero INSTALL.md:105,117-118 pide pegar el log en issues públicos | Medio |
| `.supdate` | installer/update/*; `sapphire-update.sh` | Riesgo no documentado | `bash update.sh` como root sin firma; firstboot ejecuta `/redwood/boot.d/*.sh` en cada arranque | Alto |
| Keychain y passcode | NOTES.md:73-88,473 | RESPALDADA ("protects nothing") | Pad fijo; el boot-arg `sweetaks_nopass=1` salta el passcode | Medio |
| Integridad de las descargas del instalador | Tools.cs:28-29,80 | Riesgo | Baja la release más nueva, **prereleases incluidas**, de `Angelpro09xd` con el repo fijo, y `platform-tools-latest`. Sin hash ni firma | Medio |
| Datos que salen del teléfono | código | — | Tienda→itunes.apple.com y `armconverter.com/store`; Sileo con 6 repos; log UDP al host USB | Bajo |
| Dirección Bluetooth | sapphire.sh:539-546 | Riesgo menor | `md5("sapphire-bt-"+serial)`: el serial de 32 bits se recupera por fuerza bruta. El `bdaddr` del overlay es fijo (`f5:41:db:d2:5f:df`) | Bajo |
| Caché de shaders Metal con permisos 1777 | 40-hakios-metal.sh | Riesgo menor | backboardd carga shaders desde un directorio escribible por cualquiera | Bajo |
| Lateral + volumen → Emergency SOS | release | RESPALDADA | Riesgo real si hay red celular | Medio |

## 3. "Qué funciona"

No hay entradas en NOTES.md después del 2026-11-08 (0299). Todo lo de 0.1.7/0.1.8 se apoya solo en mensajes de commit.

| Afirmación | Ubicación | Veredicto | Evidencia | Impacto |
|---|---|---|---|---|
| Wi-Fi "no association" | README.md:21,25 | OBSOLETA | NOTES.md:774 (WPA2, 10-20); :31-34 (auto-join, 0297, 11-04) | Medio |
| "Wi-Fi works seconds after boot" | release | SIN VERIFICAR | Solo commits | Bajo |
| "Bluetooth… headphones tested" | release | SIN VERIFICAR | NOTES.md:70 (11-04): "to be tried with headphones" | Medio |
| Datos LTE | HANDOFF.md:16-17 / README.md:28 | RESPALDADA en HANDOFF / OBSOLETA en README | NOTES.md:318-320 ("user confirmed on 0234"). "Other carriers via APN": sin verificar | Medio |
| GPU "rendered by the CPU" | README.md:17,26 | OBSOLETA | NOTES.md:509-529, 279-316 | Bajo |
| "Real Metal on the GPU" | release | SIN VERIFICAR | NOTES.md:246: "Metal games still cannot draw". HakiosMetal (8,6 MB) está en git **sin código fuente** | Medio |
| Touch FT3519T 54:52 | README.md:18 | RESPALDADA | NOTES.md:432, 67-69 | Bajo |
| Audio | HANDOFF.md:13 / README.md:28 | RESPALDADA / OBSOLETA | NOTES.md:128-150 | Bajo |
| Cámara | README.md:28 | OBSOLETA / SIN VERIFICAR | Solo commits | Bajo |
| Batería "real charge counting" | release | SIN VERIFICAR | NOTES.md:176-184 solo trata el cargador | Bajo |
| GPS no funciona | release | RESPALDADA | gps-plan.md:9-13 | Bajo |
| gps-plan: `q_srv[64]` sin de-dup | gps-plan.md:23-27 | RESPALDADA en parte | 0263:421-430 añade de-dup **y** los servicios del ADSP a la misma tabla, así que el desbordamiento es aún más probable | Bajo |
| "Only 4 of 8 cores" | README.md:29 | OBSOLETA | NOTES.md:463; `cpus=8` | Bajo |
| "no RTC" | README.md:28 | OBSOLETA | NOTES.md:36 | Bajo |
| HANDOFF "What works today" | HANDOFF.md:10-19 | OBSOLETA | NOTES.md:3-110 | Bajo |
| dev-notes/README "USB no enumera", "0327 ring… evento perdido" | dev-notes/README.md:23-34 | OBSOLETA / CONTRADICHA | investigacion/ | Medio |

## 4. Build, toolchain y reproducibilidad

| Afirmación | Ubicación | Veredicto | Evidencia | Impacto |
|---|---|---|---|---|
| Codemagic usa Xcode 16 y el parche 0141 | README.md:54 | RESPALDADA | codemagic.yaml:14 | Bajo |
| "patch 0128 adds IORPC.kernelContent" | codemagic.yaml:12-13 | CONTRADICHA | Es el 0141 (el 0128 es otro parche) | Bajo |
| "GitHub Actions xnu.yml macos-14 / Xcode 15" | README.md:55-60 | OBSOLETA | macos-14 está retirado; xnu.yml compila el kernel de 16K y se dispara con `branches: [main]`, pero la rama es `sapphire` | Medio |
| Duración del build | README.md:54; HANDOFF.md:27; codemagic.yaml:3 | Inconsistente | Medido en el fork: 8m40s (run 43562358335) | Bajo |
| "Kernels build on Codemagic or GitHub Actions" | AGENTS.md:8-9 | OBSOLETA para Angel / RESPALDADA en el fork | NOTES.md:186-189: Angel compila en WSL desde 0241. Fork: run 43562358335 OK, Xcode 16.0 (16A242d), 327 parches aplicados | Medio |
| darwin-xnu-build salta parches sin avisar | fetch-ci-kernel.sh:7-10 | RESPALDADA | dxb `build.sh` l.472-478; también tools/xnu-linux/xprep.sh:27-30; `MAKEFLAGS -k`; `|| true` en Collect (codemagic.yaml:77-78) | Alto |
| 03: "ejecución 43561459873" | investigacion/03:76 | CONTRADICHA (menor) | Esa terminó en failure; la buena es 43562358335 | Bajo |
| "Xcode 21" | build-recipes.md; continuar-en-otra-maquina.md; toolchain-findings.md | CONTRADICHA (nombre) | Esa versión no existe: es Apple clang 21.0.0 de CommandLineTools / SDK 26.x | Bajo |
| "toolchain roto" / "probado correcto" | toolchain-findings.md:23-38 | CONTRADICHA | investigacion/01 | Medio |
| El shim necesita `aarch64-linux-gnu-gcc` | README.md:75 | RESPALDADA | shim/build.sh. build-recipes.md:42 cita `shim/build-mac.sh`, que no existe; el real es dev-notes/shim-build-mac.sh | Bajo |
| Kernel de la release = árbol en el tag | implícito | CONTRADICHA / no demostrable | Ver el punto 4 del resumen; kernel.sh:9,16,19; tools/xnu-linux/README.md:35-50 | Alto |
| "xnu-linux… only for fastboot boot" | tools/xnu-linux/README.md:33 | CONTRADICHA por el uso | Esa imagen es la que el instalador flashea | Medio |
| exe y script de Linux = tag | — | RESPALDADA | Mismo sha256 | Bajo |
| La release incluye `SHA256SUMS` | release | CONTRADICHA | No existe el asset | Medio |
| "v0.1-test" | INSTALL.md:7; sapphire-install.sh:58 | OBSOLETA | Es 0.1.8 | Bajo |
| Build del APK | android/dualboot/build.sh:21 | No reproducible | `BOOTCTL` apunta al scratchpad de Claude de Angel | Bajo |

## 5. Licencias y procedencia

- **Firmware de Qualcomm redistribuido:**
  - en el ADT de la release: SQE, el zap firmado y el GSI de la IPA;
  - en el overlay: `btfw/apbtfw11.tlv`, `apnv11.bin` y los `.arp` de audio;
  - la política se contradice entre MANIFEST.md:18 y README.md:196.
- **DXE binarios de UEFI** (`Binaries/tapas`, vía Project-Silicium) dentro del FV.
- **Binarios sin código fuente en git:**
  - HakiosMetal (8,6 MB) y SapphireInstaller.exe;
  - Huella, btshim, fpstub, plistop y qmitool.
- **El overlay es un volcado del teléfono de Angel** (make-overlay.sh:2-4): `/redwood` (118 MB), `/var/jb`, `/bin/sh`, `/bin/bash` y un LocalStorageFileProvider que reemplaza al de Apple. MANIFEST.md:41 dice "TO CHECK".
- **Créditos y licencia:** CREDITS.md:16 cita los parches 0900-0947, que no existen (el código de HackiOS está en 0149, 0150, 0200, 0243, 0319…). No hay LICENSE en la raíz.
- **Magisk `libbootctl` (GPLv3)** va en el APK sin una oferta de código fuente visible.
- **Tienda** abre "the decrypted-IPA page" (f81e9d4; Tienda.m:906), un riesgo legal.
- **Paquetes:** scrub.py sí quita los paquetes de terceros. MANIFEST.md:21-29 dice "installed by apt on first boot", pero firstboot no ejecuta apt: **CONTRADICHA**.

## Documentos que hay que corregir y cómo

1. **RECOVERY.md**:
   - adaptarlo al dual-boot (Android = slot del ROM, aquí `b`; `boot_a` = iOS);
   - quitar o condicionar el "Fix";
   - cambiar `userdata` por `iosroot`;
   - marcar la observación como n=1;
   - añadir que antes de tocar nada hay que respaldar `boot_a/b` y el GPT de sda/sde.
2. **AGENTS.md:10-11, HANDOFF.md:84-86 y README.md:9,15,107**: cambiar la regla por "el instalador flashea `boot_<slot iOS>`; para probar kernels se usa `fastboot boot` (solo RAM) o `set_active` + `continue`; nunca se escribe `boot_<slot Android>`".
3. **acceso-al-telefono.md:40, build-recipes.md:78-81, continuar-en-otra-maquina.md:41 y toolchain-findings.md:29,56**: quitar "brickea" y explicar lo de la cabecera ARM64 y `fastboot reboot bootloader`.
4. **docs/INSTALL.md**:
   - versión 0.1.8;
   - listar el GPT, `metadata` y `set_active`;
   - corregir lo de las contraseñas y documentar 2323 y sshd;
   - explicar cómo saber el slot de Android (`getvar current-slot` desde Android);
   - avisar de que los logs contienen datos privados.
5. **Notas de la release**: contraseñas; `SHA256SUMS`; aclarar que el kernel es un build local y de qué commit.
6. **scrub.py**: añadir `pwd.db`, `spwd.db`, `passwd` y `/redwood/share/btshim/bdaddr`, y regenerar el overlay.
7. **.gitignore:4**: cambiar `recovery/` por `/recovery/` para que `installer/recovery/` entre en git.
8. **README.md**: tabla de qué funciona y qué no, la cadena con UEFI, el ring en `iosroot` y la sección de build (xnu-4k en macos-15/Xcode 16.0; la release se compila en local con tools/xnu-linux).
9. **codemagic.yaml:12** (0128 → 0141), **xnu.yml** (macos-14 y `main`) y **03:76** (run 43562358335).
10. **"Xcode 21" → "Apple clang 21 / SDK 26.x"**; corregir la ruta de shim-build-mac.sh.
11. **dev-notes/README.md:23-34**: que remita a investigacion/INDICE.md.
12. **NOTES.md**: añadir las entradas de 0300-0329 y de 0.1.7/0.1.8 (separando lo medido de lo que dicen los commits) y avisar de que lo anterior a L451 es de sweet.
13. **Política de firmware** (MANIFEST.md frente a README.md); MANIFEST.md:21 (apt); CREDITS.md:16.

## Riesgos antes del próximo flash o arranque

1. **No seguir RECOVERY.md tal como está.**
2. **La heurística de slots del instalador** puede escribir iOS sobre el Android real.
3. **El brick blando real es el GPT A/B.** Antes, desde OrangeFox y en solo lectura, respaldar `boot_a/b`, `abl_a/b` y la cabecera y entradas del GPT (primario y de respaldo) de sda y sde.
4. **`set_active` también cambia el LUN de arranque y el firmware** (Installer.cs:513). iOS podría arrancar con el XBL/ABL/TZ del slot `a`.
5. **Con `sweetusb=2` hay una shell root sin contraseña en :2323.** No conectar el teléfono a hosts ajenos. No se sabe si se alcanza por Wi-Fi.
6. **Credencial efectiva:** el `spwd.db` con el hash de Angel está en todos los teléfonos con v0.1.8.
7. **Cualquier `.supdate` en el inbox de `iosroot` se ejecuta como root.**
8. **No poner `wifi_pass` en los boot-args.**
9. **Emergency SOS** con el atajo de botones.
10. **El `boot_a` de Angel no sirve como "control limpio"**, porque no se sabe qué código lleva.

## Preguntas abiertas (solo lectura en el teléfono)

- **Slots:**
  - `getvar` de `current-slot`, `slot-successful/retry-count/unbootable:a|b`, `has-slot:recovery` y `partition-size:recovery_a`;
  - desde OrangeFox: `getprop ro.boot.slot_suffix; uname -a; /proc/cmdline` (¿de qué kernel corre OrangeFox?);
  - el sha256 de `recovery_a/b`, `boot_a/b` y `abl_a/b`.
- **¿El `boot_a` instalado es el de la release?** Compararlo con `sapphire-kernel.img` rellenado y parcheado; `uname -v` en iOS.
- **Credenciales (desde 2323):** `ls -l /var/jb/etc/spwd.db`; longitudes de los hashes de root/mobile en ambos `master.passwd` (sin imprimirlos); `su mobile`.
- **¿El 2323 responde por Wi-Fi?** Mirar `sysctl net.inet.ip.check_interface`, `netstat`, `launchctl print system/org.sapphire.usbshell`, y hacer una prueba con una ruta estática **solo en una red propia**.
- `sysctl kern.bootargs | grep -c wifi_pass`.
- **Inbox:** `/var/root/.sapphire-updates`, `/redwood/boot.d`, la caché de Metal.
- **BT:** comparar `bdaddr` con `BT_DEVICE_ADDRESS`.
- **Verificar lo que dice que funciona:** `hw.ncpu`, Wi-Fi, PDP, BT, batería, double-tap.
- **Módem:** comparar el sha256 de `modem_a` y `modem_b` (¿iOS lee el `modem_a` que no está actualizado?).
