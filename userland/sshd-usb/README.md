# sshd-usb: SSH solo con clave y solo por la red USB

Esta pieza sustituye a la shell root sin autenticación de `org.sapphire.usbshell` (puerto 2323) como forma
habitual de entrar al teléfono. Ya está desplegada en el teléfono de pruebas del fork y verificada en
`dev-notes/investigacion/03-experimentos-y-datos.md`, E6. Todavía no la instala ni el instalador ni ninguna
`.supdate`.

| Archivo | Va en el teléfono a | Qué hace |
|---|---|---|
| `com.sapphire.sshd-usb.plist` | `/redwood/launchd/com.sapphire.sshd-usb.plist` | Job de launchd (root, `RunAtLoad`, `KeepAlive`). Ejecuta `/var/jb/usr/sbin/sshd -D` escuchando solo en `192.168.7.2`, sin PAM, sin contraseña ni keyboard-interactive, con root solo por clave (`prohibit-password`) y log en `/var/jb/var/log/sshd-usb.log` |
| `70-sshd-usb.sh` | `/redwood/boot.d/70-sshd-usb.sh` | Carga el job en cada arranque si no está cargado. `firstboot.sh` ejecuta `/redwood/boot.d/*.sh` en cada arranque |

**Por qué en `/redwood/launchd` + `boot.d`.** launchd no ejecuta los jobs `RunAtLoad` que están en `/var/jb`
(NOTES.md, 2026-10-23). Los que están en `/System/Library/LaunchDaemons` van en la caché de launchd de la
IPSW y solo los cambia una receta del instalador. Es el mismo mecanismo que usa `make-update.sh` para
`com.sapphire.appwatch`.

## Requisitos en el teléfono

Sin esto, sshd se cierra al arrancar y `KeepAlive` lo relanza cada 10 s.

- **Claves de host** en `/var/jb/etc/ssh/`: `ssh-keygen -A` (ya usa el prefijo `/var/jb`). El overlay no
  las trae, a propósito: `scrub.py` las quita para que cada teléfono tenga las suyas.
- **`/var/root/.ssh/authorized_keys`** con la clave pública: directorio en 700, archivo en 600, dueño root.
- **`/var/jb/etc/pwd.db` y `spwd.db` válidos.** libiosexec solo busca los usuarios ahí. Si faltan, sshd
  responde "Invalid user root". Desde este cambio, `scrub.py` los genera con todas las cuentas bloqueadas
  (`*`). Con clave no hace falta contraseña.
- **La interfaz USB con `192.168.7.2`.** Si aún no existe cuando se carga el job, sshd no puede hacer
  `bind` y sale; `KeepAlive` lo reintenta.

## Instalación manual (lo que se hizo en el teléfono de pruebas)

Se instaló desde la shell 2323 o por scp, como root:

```sh
mkdir -p /redwood/launchd /redwood/boot.d
cp com.sapphire.sshd-usb.plist /redwood/launchd/ && chmod 644 /redwood/launchd/com.sapphire.sshd-usb.plist
cp 70-sshd-usb.sh /redwood/boot.d/ && chmod 755 /redwood/boot.d/70-sshd-usb.sh
chown 0:0 /redwood/launchd/com.sapphire.sshd-usb.plist /redwood/boot.d/70-sshd-usb.sh
bash /redwood/boot.d/70-sshd-usb.sh
```

En el Mac: `ssh -i ~/.ssh/<clave> root@192.168.7.2`.

## Pendiente

- Integrarlo en `installer/update/make-update.sh`, copiando estos dos archivos en `files/redwood/...`, o en
  las recetas del instalador. Al hacerlo, quitar o desactivar `org.sapphire.usbshell`
  (ver `dev-notes/seguridad.md`).
- `UsePAM yes` y `PermitRootLogin yes` siguen en el `sshd_config` distribuido. Este job los anula con `-o`,
  pero un `sshd` lanzado de otra forma no.
- No se verificó si `ListenAddress=192.168.7.2` impide del todo el acceso por Wi-Fi: con un modelo de host
  débil y una ruta estática, un vecino de la misma red podría enviar paquetes a 192.168.7.2. Ver
  `dev-notes/seguridad.md` §2.
