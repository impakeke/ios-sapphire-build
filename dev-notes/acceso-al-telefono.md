# Acceso al teléfono en iOS: USB, shell, SSH (estado 2026-11-13)

**Resultado:** el gadget USB de iOS **sí funciona** con nuestro kernel (expG = 0328 + shim zig)
**cuando iOS arranca saliendo de fastboot** (`fastboot set_active a` + `fastboot continue`).
Con `set_active a` + reboot normal **no enumera**. El fallo estaba en la ruta de arranque, no en
el kernel ni en los parches.

## El experimento (misma imagen, dos rutas de arranque)

Imagen: `boot_a` = expG (respaldo `boot_a-expG-20261113-223928.img`, sha256 `4c27d009…bf8f`),
boot-args en [`angel.cmdline`](angel.cmdline) (incluye `sweetusb=2`; ver `bootargs.py`).

| Ruta | Ring-log del kernel | Host (Mac) |
|---|---|---|
| `set_active a` + reboot | `ep0 cmd 0x1 timeout` → `endpoint 0 setup failed` | nada en `ioreg` |
| fastboot → `set_active a` + **`continue`** | gadget configurado (`kern.sweet_usb_stats: configured 1`) | `1209:0001 "Sweet iOS (USB Ethernet)"`, `en5`, ping 1-2 ms |

Estado del DWC3 que deja el ABL en la ruta mala (ring-log):
```
GSNPSID 0x5533330a GCTL 0x00102000 GSTS 0x7e800000 GUSB2PHYCFG 0x00002500
DCFG 0x00080804 DCTL 0x00f00000 DEVTEN 0 DSTS 0x00520004 DALEPENA 0
GEVNTADR 0 GEVNTSIZ 0 GEVNTCOUNT 0
```
Angel siempre arrancó con `fastboot boot` (NOTES.md:809), que también sale de fastboot con el
USB del ABL vivo; por eso a él nunca le pasó. En la ruta de reboot normal el ABL no inicializa
el modo dispositivo ni el PHY femto HS (0x01613000), que `sweet_usb.c` deja "como lo puso el
ABL" (parche 0142). Ese es el arreglo real pendiente: inicializar el PHY nosotros.

## Cómo entrar (receta)

1. Teléfono en fastboot (Power + Vol−). En esta Mac (Hackintosh) el `fastboot` normal no ve USB:
   usar `~/adb-bridge/fbusb set_active:a continue` (cliente fastboot por IOUSBHost).
   En otra máquina: `fastboot set_active a && fastboot continue`.
   **No usar `fastboot boot`: en este ABL brickea.**
2. Esperar ~30 s: aparece `1209:0001` y una interfaz `enX` nueva (MAC 02:00:5e:77:ee:01).
3. `sudo ifconfig enX inet 192.168.7.1/24 up` → `ping 192.168.7.2`.
4. **Shell root sin contraseña:** `nc 192.168.7.2 2323` (launchd `org.sapphire.usbshell`, solo
   escucha en 192.168.7.2).
5. **SSH** (`Host sapphire` en `~/.ssh/config`, clave `~/.ssh/sapphire_phone`): `ssh sapphire`.

## Por qué SSH "habilitado por defecto" nunca funcionó

- sshd (Procursus, `/var/jb/usr/sbin/sshd`) está instalado pero **no tiene job de launchd**,
  **no tiene claves de host** y **no hay `authorized_keys`** (el instalador de Angel las borra:
  `installer/overlay/scrub.py`, `exclude.txt`). Solo existe `org.sapphire.usbshell` (2323).
- `UsePAM yes` en el `sshd_config` distribuido.
- Arranque manual que funcionó (desde la shell 2323):
  ```sh
  export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:$PATH
  ssh-keygen -A                     # ya usa el prefijo /var/jb; NO pasar -f /var/jb
  mkdir -p /var/root/.ssh && echo '<pubkey>' > /var/root/.ssh/authorized_keys  # 700/600
  nohup /var/jb/usr/sbin/sshd -o UsePAM=no -o PasswordAuthentication=no \
        -o PermitRootLogin=prohibit-password -p 22 -E /var/jb/var/log/sshd.log &
  ```
  Las claves de host y `authorized_keys` persisten; **sshd hay que relanzarlo en cada arranque**
  (pendiente: job en `/System/Library/xpc/launchd.plist` como hace `tools/sapphire-ssh-install.sh`;
  launchd no ejecuta RunAtLoad desde `/var/jb`).

## Herramientas en la Hackintosh (USB userspace roto por el root patch de OCLP)

- `~/adb-bridge/fbusb`: fastboot mínimo (getvar, `flash <part> <img>`, set_active, reboot,
  reboot-recovery, continue).
- `~/adb-bridge/adbbridge 6555` + `adb connect 127.0.0.1:6555`: adb por IOUSBHost (OrangeFox/Android).
- `~/adb-bridge/watch-ios-usb.sh <etiqueta>`: observa la enumeración de iOS y prueba ping/2323.
- La red CDC-ECM de iOS **no necesita puente**: la toma `AppleUserECM.dext` del sistema.

## Pendiente / siguiente

- Log UDP 5140: con el enlace arriba `nc -ul 5140` no recibió nada en la primera prueba; revisar.
- Comparar los registros DWC3/QSCRATCH/PHY de la ruta buena contra la mala y portar la
  inicialización del PHY femto (Linux `phy-qcom-snps-femto-v2.c`) para que enumere también con
  reboot normal.
- Estrés de 0327 (scp grande) ahora que hay enlace.

## Prueba de carga 1 (2026-11-13 22:44): el enlace murió con 0327

`ssh sapphire 'dd if=/dev/rufsroot0 bs=4096 count=1025 ...' > ring-good.bin` (4 MiB) se detuvo
en **196608 bytes** (192 KiB) y el enlace quedó muerto: `ping` → "Host is down" (sin ARP), la
shell 2323 y SSH no responden, pero el dispositivo **sigue enumerado** (`1209` en `ioreg`, `en5`
"active"). Antes de la carga: `kern.sweet_usb_stats: configured 1 events 372 resets 1; rx 190
tx 76; without event: rx 0 tx 0, late rx 1; rx rearms 10; halt clears 2`.
⇒ 0327 no basta: el modo de fallo "muere bajo carga" sigue presente con el ring de TRBs.
