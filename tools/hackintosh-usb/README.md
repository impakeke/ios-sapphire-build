# hackintosh-usb: fastboot y adb sin libusb

En la Mac de desarrollo (Hackintosh con root patch de OCLP), `fastboot`, `adb` y libusb no pueden abrir
dispositivos USB. `IOUSBHost.framework` sí. Estas herramientas lo usan. En una Mac o un Linux normales no
hacen falta: usar platform-tools.

Las copias en uso viven en `~/adb-bridge/`; los scripts llaman a `~/adb-bridge/fbusb` y escriben en
`~/sapphire-angel/`. El uso completo, dentro del ciclo de desarrollo, está en
[`dev-notes/OPERACION.md`](../../dev-notes/OPERACION.md).

| Archivo | Qué es |
|---|---|
| `fbusb.m` | Cliente fastboot mínimo. Cada argumento es un comando del protocolo (`getvar:current-slot`, `set_active:a`, `reboot`, `reboot-recovery`, `reboot-bootloader`, `continue`); `flash <part> <img>` hace `download` + `flash`. Para en el primer `FAIL` |
| `adbbridge.m` | Puente USB ↔ TCP para adb: `adbbridge 6555`, luego `adb connect 127.0.0.1:6555`. Hace abort + clearStall de los pipes en cada conexión |
| `exp-loop.sh` | Bucle de ensayos de arranque (`exp-loop.sh <etiqueta> RRRC [timeout]`), con CSV de resultados |
| `watch-ios-usb.sh` | Observa un arranque de iOS: enumeración de 1209:0001, interfaz nueva, ping y shell 2323 |
| `to-recovery-backup.sh` | Lleva el teléfono de fastboot a OrangeFox y respalda `boot_a` |

`IOServiceMatching` con propiedades no encuentra nada en esta Mac, así que las dos herramientas en C recorren
todas las `IOUSBHostInterface` y filtran a mano (fastboot: clase 255/66/3; ADB: 255/66/1).

Compilar e instalar:

```sh
cd tools/hackintosh-usb
for t in fbusb adbbridge; do
  clang -fobjc-arc -framework Foundation -framework IOKit -framework IOUSBHost $t.m -o ~/adb-bridge/$t
done
cp exp-loop.sh watch-ios-usb.sh to-recovery-backup.sh ~/adb-bridge/
```
