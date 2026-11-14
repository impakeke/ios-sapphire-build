# Seguridad de Sapphire: amenazas y mitigaciones

Fecha: 14 nov 2026. Parte de la auditoría `investigacion/04-auditoria-documentacion-heredada.md` (§2 y los
puntos 1-3 de "Lo más importante"). Las rutas son del repo salvo que se indique otra cosa. Nada de lo que
aquí se llama "propuesta" está aplicado.

Ya corregido en el repo (sin regenerar todavía el overlay de la release):
- `installer/overlay/scrub.py` vuelve a generar `pwd.db`/`spwd.db` desde el `master.passwd` limpio, con todas
  las cuentas en `*`. También limpia `passwd`, cambia todos los `bdaddr` por `@BDADDR@` y se detiene si queda
  algún hash crypt en cualquier archivo del overlay.
- `.gitignore`: `/recovery/`. `installer/recovery/` ya se versiona (ver su README).
- `userland/sshd-usb/`: SSH solo con clave en 192.168.7.2.

**Pendiente urgente fuera del repo.** El `sapphire-overlay.tar.gz` de v0.1.8 sigue publicado con un
`spwd.db` que lleva el hash `$6$` de `mobile` del teléfono de referencia. Para que eso deje de ser una
credencial y una filtración hay que hacer dos cosas: regenerar el overlay con el nuevo `scrub.py` y retirar
el asset. Los teléfonos ya instalados conservan el `spwd.db` antiguo. Para cambiarlo hace falta una
`.supdate` que deje `pwd.db`/`spwd.db` nuevos. `mkpwdb` no está compilado para iOS, así que tendrían que
generarse en el host. Esa `.supdate` solo debería reemplazarlos si el hash de `mobile` sigue siendo el de
referencia, para no borrar una contraseña que el usuario haya puesto con `passwd`. Mientras tanto, el
usuario puede cambiar la contraseña de `mobile` con `passwd mobile`, o bloquearla.

---

## 1. Actualizaciones `.supdate`: código root sin firmar en cada arranque

### Cómo funciona hoy

- `installer/recovery/sapphire.sh update NAME SIZE` (modo actualización del instalador) recibe un `.tar.gz`
  por adb y lo escribe en el *inbox* de la partición `iosroot` con `sapphire-inbox put`. La app Android
  *Sapphire Dual Boot* (`Calibration.java`, `IpaInbox.java`) escribe en el mismo inbox, como root.
- En cada arranque, `com.sapphire.firstboot` (launchd, root) ejecuta `firstboot.sh`, que llama a
  `/redwood/bin/sapphire-update.sh` (`userland/update/sapphire-update.sh`).
- `sapphire-update.sh` recorre las entradas `*.supdate`. Para cada una lee el sha256 **de la cabecera del
  propio inbox**, comprueba que coincide con los bytes, descomprime y ejecuta `bash update.sh DIR` como root.
  El sha256 queda en `/var/root/.sapphire-updates` para no repetirla.
- Las `.supdate` de la release (`installer/update/make-update.sh`) instalan archivos en `/` con
  `tar -xpf` y dejan scripts en `/redwood/boot.d/*.sh`, que `firstboot.sh` vuelve a ejecutar como root
  **en cada arranque**. Es decir, una sola `.supdate` deja persistencia permanente.

### La amenaza

- **Sin autenticación.** El sha256 viene del mismo sitio que los datos, así que solo protege contra la
  corrupción, no contra quien escribe en el inbox. Cualquiera que pueda escribir en el inbox consigue
  ejecución de código como root en iOS en el siguiente arranque, con persistencia.
- **Quién puede escribir en el inbox:**
  1. Cualquier proceso con root en Android: Magisk/KernelSU y cualquier app a la que se le haya concedido
     `su`. El inbox es una zona documentada de la partición y no hace falta entender HFS+.
  2. Quien tenga el teléfono en OrangeFox o recovery con adb (acceso físico, sin PIN si el recovery no lo
     pide).
  3. El instalador de Windows/Linux, que baja los assets sin verificarlos (§5). Quien controle la release o
     la red controla la `.supdate`.
  4. A futuro, la cabecera de `sapphire-update.sh` dice "later, downloaded from GitHub". Si se descargan
     por red sin firma, cualquiera en la ruta consigue root en iOS.
- **Límite honesto.** Contra (1) y (2) la firma no lo resuelve todo: con root en Android también se puede
  escribir el volumen HFS+ de `iosroot` directamente (la app ya incluye un lector HFS) y plantar un
  `boot.d`. La firma sube el coste de "dejar un archivo en un buzón documentado" a "modificar un sistema de
  archivos a mano" y cierra del todo los vectores (3) y (4). Para (1), la protección real es no dar `su` a
  apps en las que no se confía.

### Mitigaciones, de menor a mayor esfuerzo

| # | Mitigación | Esfuerzo | Qué cierra | Coste |
|---|---|---|---|---|
| 1 | **Documentar el riesgo** en INSTALL.md y en la release: "cualquier app con root en Android puede ejecutar código root en iOS" | minutos | nada técnico; consentimiento informado | ninguno |
| 2 | **Proceso solo con un archivo de permiso de un solo uso.** `sapphire-update.sh` no toca el inbox salvo que exista `/var/root/.sapphire-allow-updates` (de root, no symlink). Lo borra al usarlo. Diff A | 10 líneas | aplicación silenciosa desde Android, recovery o instalador. Hace falta un paso del dueño desde iOS (SSH, o un botón futuro en Android.app de iOS) | rompe el flujo de "actualizar sin entrar a iOS"; la calibración también necesita el permiso |
| 3 | **No ejecutar `/redwood/boot.d` en cada arranque**, o solo los scripts listados en un manifiesto con sus sha256 dentro de `/redwood` | pequeño | la persistencia barata de una `.supdate` maliciosa | las actualizaciones legítimas tienen que mantener el manifiesto |
| 4 | **Firma ed25519 con clave pública fijada.** La release firma cada `.supdate` (`NAME.supdate.sig`, 64 bytes, en el inbox junto a ella). La clave pública se instala en `/redwood/share/sapphire-update.pub.pem` (receta del instalador). `sapphire-update.sh` verifica con `openssl pkeyutl -verify -rawin`. La calibración, que se genera en el teléfono y no se puede firmar, pasa a ser solo datos: su `update.sh` no se ejecuta y la copia un manejador fijo. Diff B | medio día + gestión de la clave | (3) y (4) por completo; (1) y (2) en la vía fácil | custodia de la clave privada (fuera de CI, offline). El instalador debe enviar el `.sig`. Hay que comprobar que el `openssl` de Procursus es 3.x |
| 5 | Firma verificada **por el kernel** (`kern.sweet_inbox` solo entrega entradas firmadas) o un inbox cifrado o autenticado con una clave en el Secure Enclave | alto | lo mismo que 4, sin depender de un `openssl` en userland modificable | demasiado para el estado actual |

**Recomendación.** Aplicar 1 y 2 ya: son de bajo riesgo y reversibles. Planear 4 antes de cualquier
"actualizar desde GitHub" dentro de iOS. 2 y 4 son compatibles: con 4 aplicado, 2 puede quedar solo para
las entradas sin firma, como la calibración.

### Diff A (propuesto, NO aplicado): permiso de un solo uso

Comprobado con `bash -n` y `patch --dry-run` sobre el archivo actual. No se ha probado en el teléfono.

```diff
--- a/userland/update/sapphire-update.sh
+++ b/userland/update/sapphire-update.sh
@@ -15,6 +15,13 @@
 log() { echo "$(date '+%F %T') $*" >> $LOG; echo "sapphire-update: $*" > /dev/console 2>/dev/null; }
 
 [ -x $CAT ] || exit 0
+# Updates run as root: only after this phone's owner allowed them, once (as root: touch the file, reboot)
+ALLOW=/var/root/.sapphire-allow-updates
+if [ ! -f $ALLOW ] || [ -L $ALLOW ] || [ ! -O $ALLOW ]; then
+	$CAT start >/dev/null 2>&1 && log "inbox left alone: $ALLOW missing"
+	exit 0
+fi
+rm -f $ALLOW
 S=$($CAT start) || exit 0
 hdr=$(mktemp)
 $CAT "$S" 4096 > "$hdr" 2>/dev/null || { rm -f "$hdr"; exit 0; }
```

Uso: `ssh root@192.168.7.2 touch /var/root/.sapphire-allow-updates` y reiniciar. Cada arranque sin el
archivo deja una línea en `/var/root/sapphire-update.log`. Las entradas no se pierden y se aplican la
próxima vez que haya permiso.

### Diff B (propuesto, NO aplicado): firma ed25519

Comprobado con `bash -n` y `patch --dry-run`. Las órdenes `openssl pkeyutl -sign/-verify -rawin` se
probaron en el Mac (OpenSSL 4.1): la firma válida pasa y basta con añadir 1 byte para que falle. No se ha
probado en el teléfono. Antes, ejecutar `/var/jb/usr/bin/openssl version` allí: necesita ≥ 3.0.

```diff
--- a/userland/update/sapphire-update.sh
+++ b/userland/update/sapphire-update.sh
@@ -12,6 +12,7 @@
 TRIES=/var/root/.sapphire-update-tries
 LOG=/var/root/sapphire-update.log
 W=/var/tmp/sapphire-update
+PUB=/redwood/share/sapphire-update.pub.pem    # the release key (ed25519), pinned at install
 log() { echo "$(date '+%F %T') $*" >> $LOG; echo "sapphire-update: $*" > /dev/console 2>/dev/null; }
 
 [ -x $CAT ] || exit 0
@@ -22,6 +23,36 @@
 le() { od -An -t u$2 -j $1 -N $2 "$hdr" | tr -d ' '; }   # OFF SIZE (4 or 8), little-endian
 count=$(le 12 4)
 touch $DONE $TRIES
+entry() { # entry NAME: that inbox entry's bytes on stdout
+	local j f
+	for j in $(seq 0 $(( count - 1 ))); do
+		f=$(( 24 + 256 * j ))
+		[ "$(dd if="$hdr" bs=1 skip=$(( f + 56 )) count=192 2>/dev/null | tr -d '\0')" = "$1" ] || continue
+		$CAT $(( S + $(le $f 8) )) "$(le $(( f + 8 )) 8)"
+		return
+	done
+	return 1
+}
+# this phone's factory calibration (made on the phone, so never signed): data only, its update.sh is not run
+calibration() {
+	local D=$1 f b n=0
+	[ -z "$(find $D -type l)" ] || { log "calibration: links in it, ignored"; return 1; }
+	mkdir -p /var/root/fp && chmod 700 /var/root/fp
+	for f in $D/fp/gf_*.so; do
+		[ -f "$f" ] || continue
+		b=${f##*/}
+		case $b in gf_cali*) ;; *) [ -e /var/root/fp/$b ] && continue ;; esac
+		cp "$f" /var/root/fp/$b && chmod 600 /var/root/fp/$b && n=$((n + 1))
+	done
+	log "calibration: $n fingerprint files"
+	if [ -d $D/sensors ]; then
+		mkdir -p /var/root/sensfiles/mnt/vendor/persist
+		rm -rf /var/root/sensfiles/mnt/vendor/persist/sensors
+		cp -R $D/sensors /var/root/sensfiles/mnt/vendor/persist/ && chown -R 0:0 /var/root/sensfiles
+	fi
+	launchctl kickstart -k system/com.sapphire.fpd 2>/dev/null
+	return 0
+}
 for i in $(seq 0 $(( count - 1 ))); do
 	e=$(( 24 + 256 * i ))
 	name=$(dd if="$hdr" bs=1 skip=$(( e + 56 )) count=192 2>/dev/null | tr -d '\0')
@@ -48,11 +79,28 @@
 		log "update $name: sha256 mismatch ($got)"
 		continue
 	fi
+	# the signature: inbox entry NAME.sig, ed25519 over the .supdate's bytes (make-update.sh, the release key)
+	signed=0
+	if [ -f $PUB ] && entry "$name.sig" > $W.sig 2>/dev/null && [ -s $W.sig ] && \
+	    openssl pkeyutl -verify -pubin -inkey $PUB -rawin -in $W.tgz -sigfile $W.sig >/dev/null 2>&1; then
+		signed=1
+	fi
+	rm -f $W.sig
+	if [ $signed = 0 ] && [ "$name" != sapphire-calibration.supdate ]; then
+		log "update $name: not signed by the release key, not run"
+		rm -f $W.tgz
+		continue
+	fi
 	if ! tar -xzpf $W.tgz -C $W 2>>$LOG || [ ! -f $W/update.sh ]; then
 		log "update $name: not an update (no update.sh)"
 		continue
 	fi
-	if bash $W/update.sh $W >> $LOG 2>&1; then
+	if [ $signed = 0 ]; then
+		run=calibration
+	else
+		run="bash $W/update.sh"
+	fi
+	if $run $W >> $LOG 2>&1; then
 		echo "$sha $name $(date +%s)" >> $DONE
 		log "update $name: applied"
 	else
```

Para completarlo, otros cambios (aquí descritos, sin diff):
- `installer/update/make-update.sh`, al final:
  `openssl pkeyutl -sign -inkey "$SAPPHIRE_UPDATE_KEY" -rawin -in $F -out $F.sig`. La clave privada se
  guarda fuera del repo y de CI. La pública va en `installer/recipes/` (o `userland/update/`) como
  `sapphire-update.pub.pem`.
- `installer/recovery/sapphire.sh`: en `cmd_update`, aceptar `*.supdate|*.supdate.sig`. En `build`, copiar
  la clave pública a `$S/mod/redwood/share/`, que es lo que la fija en la instalación.
- Instalador de Windows/Linux: enviar `NAME.supdate.sig` después de `NAME.supdate`.
- Android `Calibration.java` y `sapphire.sh` (calibración): sin cambios. Su `update.sh` se ignora y lo
  sustituye `calibration()`, que no sigue symlinks y solo copia `fp/gf_*.so` y `sensors/`.
- **Transición.** Los teléfonos con el `sapphire-update.sh` antiguo ejecutan cualquier cosa. La primera
  `.supdate` firmada que instale el script nuevo y la clave sigue pasando por la vía antigua. A partir de
  ahí ya no.

Riesgo residual de B: `tar -xzpf` de una entrada sin firma (calibración) como root. `tar` descarta `..` y
`/` iniciales, pero conviene extraerla con `--no-same-owner` y sin `-p`, o con un `tar -t` previo que
rechace symlinks.

---

## 2. Shell root sin autenticación en 192.168.7.2:2323 (`org.sapphire.usbshell`)

**Qué es.** Una receta del instalador (`installer/recipes/launchd/org.sapphire.usbshell.plist`) que se
instala en **todos** los teléfonos. Es un job de launchd con `inetdCompatibility`, `UserName root` y
`SessionCreate`. Cada conexión TCP a `192.168.7.2:2323` recibe `bash -i` como root, sin contraseña ni
clave. Se creó para el bring-up (`dev-notes/acceso-al-telefono.md`) y no está documentado para usuarios.

**Riesgo.**
- Cualquier host USB al que se conecte el teléfono con la red USB activa (`sweetusb=2`) tiene root
  inmediato: un PC ajeno, un cargador "inteligente" o un kiosco. No hace falta ningún secreto.
- **Wi-Fi: sin verificar.** `SockNodeName 192.168.7.2` hace `bind` a esa dirección, pero el
  "weak host model" de XNU (`net.inet.ip.check_interface=0` por defecto) acepta paquetes dirigidos a
  192.168.7.2 que lleguen por **cualquier** interfaz. Un atacante en la misma Wi-Fi que añada una ruta
  estática `192.168.7.2 via <IP del teléfono>` podría llegar al puerto. Hay que medirlo solo en una red
  propia: `sysctl net.inet.ip.check_interface`, y `nc` desde otro equipo de la Wi-Fi con la ruta.
- Está en la caché de launchd vía receta: no se puede quitar sin reinstalar o sin una actualización.

**Opciones, de más a menos recomendable.**
1. **Retirarla de las recetas** y usar `sshd-usb` (§3) como acceso por defecto. Para recuperar un teléfono
   sin claves queda OrangeFox (adb) para escribir `authorized_keys` en el volumen.
2. Dejarla solo en compilaciones de desarrollo: que el instalador la aplique solo con un flag de
   desarrollador, no en las releases.
3. Activarla bajo demanda con un boot-arg (p. ej. `sweet_usbshell=1`): un `boot.d` hace `launchctl load`
   solo si `sysctl kern.bootargs` lo contiene. Cambiar boot-args exige acceso a fastboot, así que el riesgo
   pasa a ser físico y explícito.
4. Como mínimo: `sysctl -w net.inet.ip.check_interface=1` en un `boot.d`. Eso cierra la vía Wi-Fi si el
   punto anterior se confirma. Hay que comprobar antes que no rompe la red USB.

En cualquier caso, documentar en INSTALL.md que **no se conecte el teléfono a hosts USB ajenos** mientras
exista.

---

## 3. SSH solo con clave por la red USB (`userland/sshd-usb/`)

Ya desplegado en el teléfono de pruebas del fork (E6 en `investigacion/03`). Se añade ahora al repo:

- `userland/sshd-usb/com.sapphire.sshd-usb.plist`: va en `/redwood/launchd/`. Ejecuta `sshd -D` como root
  con `ListenAddress=192.168.7.2`, `UsePAM=no`, `PasswordAuthentication=no`,
  `KbdInteractiveAuthentication=no` y `PermitRootLogin=prohibit-password`. Log en
  `/var/jb/var/log/sshd-usb.log`. `RunAtLoad` y `KeepAlive`.
- `userland/sshd-usb/70-sshd-usb.sh`: va en `/redwood/boot.d/` y carga el job en cada arranque.
- `userland/sshd-usb/README.md`: requisitos (claves de host, `authorized_keys`, `pwd.db`) e instalación.

Ventajas frente a 2323: autenticación por clave, canal cifrado y log. Comparte la duda del weak host model
(§2) para el acceso por Wi-Fi, aunque aquí sin clave no se entra. Pendiente: integrarlo en
`make-update.sh` o en las recetas y retirar 2323. También dejar en el `sshd_config` distribuido
`UsePAM no` y `PermitRootLogin prohibit-password`, para que un `sshd` lanzado a mano no herede
`PermitRootLogin yes`.

---

## 4. `wifi_pass` en los boot-args

`xnu/patches/0144-sapphire-wlan-bootarg-join.patch` permite unirse a una red con `wifi_ssid=`/`wifi_pass=`
en los boot-args. El comentario dice "the passphrase is never logged and is wiped after the join", pero
solo se borra **la copia en la pila** (`bzero(pass)`). La contraseña sigue en:
- la cmdline del kernel y el ADT (`/chosen`), que se pueden leer desde userland;
- `sysctl kern.bootargs`, legible por cualquier proceso, incluidas las apps;
- el log de launchd, que imprime los boot-args (NOTES.md:774);
- la imagen `boot_X` si se empaquetó con ellos, y cualquier copia de esa imagen (CI, releases, backups);
- el SSID, además, sale en el log del kernel (`LOG(... '%s' ...)`), que la app Android comparte con
  *iOS log → Share*.

**Recomendación.** No usar nunca `wifi_pass` fuera de una red de pruebas desechable. Quitar el soporte del
kernel de release (con `#if DEVELOPMENT` o eliminando 0144) ahora que wifid se asocia solo. Si se mantiene,
documentarlo como "la contraseña queda legible por cualquier app y en los logs". Comprobación en el
teléfono: `sysctl kern.bootargs | grep -c wifi_pass` debe dar 0.

---

## 5. Datos privados en logs

- `.gitignore` excluye `logs/` porque los logs de arranque llevan SSIDs cercanos e identificadores. Sin
  embargo, `docs/INSTALL.md` pide pegar el log del instalador en un issue público y compartir el log del
  kernel de iOS desde la app.
- Lo que puede salir en esos logs: SSIDs (el del boot-arg y los escaneos), seriales y `ro.serialno` (la
  dirección BT se deriva de él con `md5` y un serial de 32 bits se recupera por fuerza bruta), boot-args
  (con `wifi_pass` si se usó), MACs e IMEI si se registra el modem, y rutas de usuario del PC en el log del
  instalador de Windows.
- `/var/root/sapphire-update.log` guarda la salida completa de cada `update.sh`.
- El log UDP al host USB (puerto 5140) va en claro a quien esté al otro lado del cable.

**Recomendaciones.**
1. Añadir a INSTALL.md: "revisa y tapa SSIDs, seriales y boot-args antes de publicar un log", o mejor,
2. que la app y el instalador redacten al exportar: `wifi_pass=…` → `wifi_pass=<oculto>`, SSIDs → hash
   corto, `serialno`/IMEI → `<serial>`, y MACs con el último octeto enmascarado.
3. El kernel no debería imprimir el SSID del boot-arg.

---

## 6. El instalador descarga prereleases sin fijar y sin hash

`installer/windows/src/Tools.cs`:
- `ReleaseAssets()` (l. 76-100) toma la **primera release de las 10 más recientes, prereleases incluidas**,
  que tenga `sapphire-recovery.zip`, del repo fijo `Angelpro09xd/ios-sapphire`. No fija tag ni versión y no
  hay hash ni firma de los assets: kernel, recovery zip (que se ejecuta como root en OrangeFox y
  reparticiona), overlay y `.supdate`.
- `EnsurePlatformTools()` baja `platform-tools-latest-windows.zip` de Google y ejecuta su `adb.exe`, sin
  hash.
- HTTPS protege el transporte, pero no frente a: una cuenta de GitHub comprometida, un colaborador que
  publique una prerelease rota o maliciosa (la toma **automáticamente** todo usuario nuevo) o un asset
  reemplazado después de publicarse. Además, la release anuncia un `SHA256SUMS` que no existe.
- Para el fork, `Repo` apunta al original: un instalador compilado desde el fork instala lo de Angel.

**Mitigaciones, de menor a mayor esfuerzo.**
1. Ignorar prereleases por defecto (`/releases/latest`). Ofrecerlas con un flag explícito (`--prerelease`).
2. **Fijar en el binario** el tag esperado y el sha256 de cada asset (una tabla en `Tools.cs` generada por
   `windows/build.sh` a partir de los archivos que se publican). Rechazar si no coincide. Un instalador
   nuevo trae los hashes nuevos.
3. Publicar `SHA256SUMS` y su firma (minisign o ed25519, con la misma clave que §1-B) y verificarlos en el
   instalador con la clave pública incluida.
4. platform-tools: fijar una versión concreta (`platform-tools_rXX-windows.zip`) con su sha256, en vez de
   `-latest`.
5. Hacer configurable `Repo` en el build (el fork no debería instalar binarios de otro repo sin decirlo).

---

## Anexo: comprobaciones de solo lectura en el teléfono (no hechas aquí)

- `ls -l /var/jb/etc/spwd.db /var/jb/etc/pwd.db` y la longitud del campo 2 de `mobile` en `spwd.db`, sin
  imprimirlo.
- `/var/jb/usr/bin/openssl version` (Diff B).
- `sysctl net.inet.ip.check_interface` y `launchctl print system/org.sapphire.usbshell`.
- `sysctl kern.bootargs | grep -c wifi_pass`.
- `cat /var/root/.sapphire-updates; ls -l /redwood/boot.d`.
