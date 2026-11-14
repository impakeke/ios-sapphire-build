# USB — estado vivo

**El USB es el cuello que frena todo** (lleva log UDP:5140 + SSH en 192.168.7.2).
Este doc es el estado *actual* y el siguiente paso. El diagnóstico profundo está en
[usb-diagnostico.md](usb-diagnostico.md).

## Dónde estamos (2026-11-13)

1. **iOS bootea limpio desde fuente** hasta el lock screen: nuestro kernel dev
   (DXB/Xcode) + nuestro shim (zig Recipe C), empaquetado con mkadt/mkpayload.
   Imagen de prueba: `expG` = shim arreglado + kernel con parche **0328**.
2. **El gadget USB NO enumera** en el host. En el Mac, `ioreg -rc IOUSBHostDevice`
   **no muestra idVendor 0x1209** (ni una `enX` nueva). Importante: si enumerara,
   el nodo del dispositivo aparecería en `ioreg` **aunque falte el driver de clase**
   — no aparece ⇒ **no hay pullup de D+ / no hay enumeración**, falla del lado del
   teléfono, no del host.
3. En **fastboot** el mismo teléfono/cable/puerto SÍ enumera (`fastboot devices`
   → `d24dbc87`) ⇒ HW USB del teléfono, cable y puerto del Mac están bien.
4. Cambiar de cable y de puerto **no** lo destrabó.

### Interpretación
El fallo es **más temprano** que el `SETEPCONFIG` timeout que ataca 0328: es la
fase **connect/pullup**. El propio código lo dice (`sweet_usb.c`, comentario 0328):
*"ep0 cmd timeout → bring-up aborted → the gadget never pulled up D+ / enumerated"*.
El clear de `GUSB2PHYCFG` SUSPHY de 0328 apunta justo a eso (PHY suspendida = sin
connect) **pero no bastó** en expG. Hipótesis a descartar con el log:
- el `dwc_wr(0xc200,...)` se ejecuta pero algo vuelve a suspender la PHY, o
- el `SETEPCONFIG` de ep0 sigue expirando aun con la PHY despierta (entonces 0328
  ataca la capa equivocada y hay que mirar DCTL run/stop / GCTL / DCFG antes), o
- el hilo USB ni arranca (orden de init), o
- es un **artefacto del toolchain** (nuestro codegen difiere del de Angel) — ver
  toolchain-findings.md. Control decisivo: flashear el `boot_a` original de Angel
  y ver si ÉL enumera en este Mac. Si Angel tampoco ⇒ es el host/boot-path; si
  Angel sí ⇒ regresión nuestra.

## SIGUIENTE PASO — leer el ring-log persistente (dato decisivo)

El kernel ahora **llega al lock screen vivo**, así que por primera vez el ring de
consola ya se volcó a disco. Sus `printf` dicen exactamente dónde para `sweet_usb`:
busca estas líneas (de `sweet_usb.c`):
- `SWEET USB: DWC3 GSNPSID ... GCTL ... GUSB2PHYCFG ...` (estado del controlador)
- `SWEET USB: soft reset done/STUCK after N ms ...`
- `ep0 cmd 0x6 status 1` / cualquier "cmd timeout" (→ confirma la capa que falla)
- si el hilo `ud_thread` llegó a correr / `RUN_STOP`.

### Formato del ring (de `sweet_ufs.c`)
- Se escribe en la **cola de la partición** que usa `sweet_ufs` (la raíz iOS;
  identifícala por el magic). `base = first_block + nblocks − 1025` bloques de 4 KiB.
- Bloque `base`: header `struct { char magic[8]="SWEETLOG"; u32 version; u32 size(=4MiB);
  u64 total; u64 seq; }`. `seq == ~0` ⇒ el volcado vino de un **panic**.
- Bloques `base+1 … base+1024`: ring circular de **4 MiB**. El texto válido son los
  últimos `min(total, 4MiB)` bytes; si `total ≥ 4MiB` el byte más viejo está en
  offset `total % 4MiB` y envuelve.
- Requiere boot-arg `sweetlog=1` (default on) y partición RW con `nblocks ≥ 2·1025`.
  Volcado cada `ufslogsecs` (default **10 s**) ⇒ deja el teléfono ≥15 s en iOS antes
  de leer.

### Cómo leerlo (desde OrangeFox recovery, que da adb)
```sh
# 1) arranca a OrangeFox recovery (Vol+ + Power). En el Mac:
adb shell 'ls -l /dev/block/by-name' | grep -iE 'iosroot|root'   # localizar la raíz iOS
# 2) saca la cola (~4.2 MB) de la partición candidata:
P=/dev/block/by-name/iosroot
SZ=$(adb shell "blockdev --getsize64 $P" | tr -d '\r')
SKIP=$(( SZ/4096 - 1025 ))
adb shell "dd if=$P bs=4096 skip=$SKIP count=1025 2>/dev/null" > ringtail.bin
# 3) parsea en el Mac:
python3 dev-notes/read-ring.py ringtail.bin
```
Si `iosroot` no trae el magic `SWEETLOG`, prueba otras particiones RW grandes
(`userdata`, etc.) — la que tenga el magic al inicio del tail es la correcta.

## Historial de parches USB
- **0327** (fast-reclaim): reclama TRBs por HWO en cada poll; cura el "muere bajo
  carga / scp grande" descrito en NOTES. Commiteado.
- **0328** (phy-wake + ep0 timeout): este doc. Compila+bootea; USB aún no enumera.
