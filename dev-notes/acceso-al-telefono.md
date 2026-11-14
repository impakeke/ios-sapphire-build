# Acceso al teléfono en iOS: USB, shell, SSH (estado 2026-11-13)

**Observación (n=1 por ruta, 2026-11-13):** con la misma imagen expG (0328 + shim zig), el gadget
USB de iOS **enumeró y pasó tráfico** cuando iOS arrancó saliendo de fastboot
(`fastboot set_active a` + `fastboot continue`). En un arranque anterior por `set_active a` +
reboot normal **no enumeró** (ring: `ep0 cmd 0x1 timeout`).

**Hipótesis (NO verificada):** la diferencia la causa el estado en que el ABL deja el
controlador/PHY según la ruta. Falta: repetir cada ruta varias veces, comparar registros de ambas
rutas en el mismo kernel, y contrastar con lo que dice la evidencia de Angel y la documentación
de DWC3/PHY femto (auditoría en curso).

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
Contexto (sin conclusión todavía): en su etapa temprana Angel arrancaba con `fastboot boot`
(NOTES.md:809), que también sale de fastboot. Su instalador actual termina con `set_active` +
`reboot`; falta comprobar si con esa ruta el USB le enumeraba. `sweet_usb.c` deja el PHY femto
HS (0x01613000) "como lo puso el ABL" (parche 0142). Si la hipótesis se confirma, el arreglo
sería inicializar el PHY nosotros.

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
Observación: el modo de fallo "muere bajo carga" sigue presente con 0327 (nota: 0327 NO es un
ring de TRBs; sigue siendo un TRB por endpoint, solo reclama por HWO en cada poll).
Recuperación: desconectar/reconectar el cable (bus reset) devolvió el enlace sin reiniciar iOS;
después: `tx 2688980 frames`, `rx 837`, `resets 2`. El ring tenía 130538 líneas
`SWEET USB: ep3 cmd 0x6 status 1` (ep3 = bulk IN/TX, 0x6 = Start Transfer rechazado).
Hipótesis en revisión (no compilada): 0327 rearma el endpoint al ver HWO=0 antes de que el
controlador retire la transferencia. Pendiente de contrastar con fuentes primarias (Linux dwc3).

## Experimento 1 (2026-11-14): ruta de arranque con VBUS controlado

| Ensayo | Ruta | PMIC (VBUS) | Resultado | DWC3 al tomar control |
|---|---|---|---|---|
| R1 | `set_active a` + reboot, cable puesto | `usb 0x10`, cargando, apsd 0x1 | NO enumera; `ep0 cmd 0x1 timeout` | GCTL 0x00102000, GUSB2PHYCFG 0x2500, DCFG 0x00080804, DCTL 0x00f00000, DEVTEN 0, GEVNTADR 0 (reset) |
| C1 | fastboot → `set_active a` + `continue` | `usb 0x10` | enumera (1209:0001, ping 1.5 ms) | GCTL 0x00112000, GUSB2PHYCFG 0x2400, DCFG 0x004808dc, DCTL 0x10f00000, DEVTEN 0x277, DALEPENA 0xf, GEVNTADR propio del ABL; QSCRATCH GENERAL_CFG 0x4, HS_PHY_CTRL 0 |

Observación: con VBUS presente en ambas, la diferencia sigue la ruta de arranque (n=1 c/u; R1 idéntico
byte a byte al arranque malo del 13 nov). ENBLSLPM=1 en la ruta mala; 0328 lo limpia y aun así falla
⇒ no basta. Fuente primaria (código de ABL, CodeLinaro `clo/la/abl/tianocore/edk2`,
`LinuxLoader.c`/`FastbootMain.c`/`FastbootCmds.c`): en arranque normal ABL no arranca el USB device;
solo lo hace dentro de fastboot, y `continue` solo libera buffers antes de `BootLinux()`.
Siguiente: kernel 0329 (diagnóstico de solo lectura del PHY femto/QSCRATCH/GCC en ambas rutas).
