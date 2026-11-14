# 12 — GPS para ios-sapphire (plan + protocolo verificado)

Compilado 2026-11-13. Fuentes: análisis con agentes de los repos
`Angelpro09xd/ios-sapphire` (rama `sapphire`, clon completo 625 commits, parche 0326),
`MakrSas/ios-topaz`, `MakrSas/topaz-woa`, `dipa-studio/ios-sweet`, más libqmi, gpsd,
ModemManager, oFono y docs de postmarketOS/Droidian. IDs de mensajes **verificados a mano**
contra `libqmi/data/qmi-service-loc.json` y `libqmi/src/libqmi-glib/qmi-enums.h`.

## Estado (lo que NADIE ha hecho aún)

GPS no está implementado en **ningún** port iOS-on-Android (sweet/topaz/sapphire, HackiOS).
Esto sería el primero. Angel no lo ha tocado: lo único "location" en el repo es evitar que
`locationd` crashee (fake AppleBaseband, `libsapphire-fakebb`, commit ec8f684).

## El problema = 3 tramos

### Tramo 0 — Hacer que aparezca el servicio LOC  [MUY PROBABLE: bug de 64 entradas]
**El GNSS vive en el MÓDEM** (`gps/gps_service → msm/modem/root_pd` inst 180, verificado en
0166/0121), NO en el ADSP. Y stock Android **no "habilita" LOC** — solo espera a que el módem lo
anuncie (loc_api_v02 usa instancia ANY, sin mcfg/NV). Módems SM/SDM reales anuncian ~45 servicios
incluyendo **LOC = svc 16 (0x10) v2, registrado TARDE**.

Por qué el port no lo ve (hipótesis fuerte, código verificado): el kernel guarda los NEW_SERVER en
`q_srv[64]` y **descarta en silencio lo que pase de 64, sin de-dup ni DEL_SERVER**
(`0118:82,346`). Con ~45 servicios + re-broadcasts (HELLO/WLAN-PD restart) la tabla se llena, y
**LOC, que llega tarde, es justo el que se cae.** La lista "DMS/NAS/..." de NOTES era el subset
*nombrado* por `svc_name()`; el kernel **loguea todos los servicios crudos** (`0118:589`).

**Experimento 1 (el bueno, barato):** leer en el log de arranque las líneas
`service XX:YY node N port P ...` (por el log USB en vivo, o el ring persistente desde recovery).
- ¿Aparece `10:2`? → LOC está; saltar al Tramo A (`SWEET_QMI_LOOKUP(0x10, inst=~0)`).
- ¿`q_srv_count` llega a 64? → overflow; agrandar `q_srv[]`, de-dup + manejar DEL_SERVER, releer.
- ¿Sigue sin aparecer? → `NEW_LOOKUP(service=0, instance=0)` wildcard; y/o arrancar Android una
  vez con Ubicación ON (el engine-lock se guarda en NV del módem).

Engine-lock quirk: `Set Engine Lock 0x3A` con TLV 0x01 u32 `lockType=1` (NONE); enum NONE=1, MI=2,
MT=3, ALL=4. (`Get Engine Lock 0x3B`.) Otros msg útiles: SV Info ind 0x25, Engine State ind 0x2B,
Inject UTC Time 0x38, Inject XTRA 0xA7.

### Tramo A — Cliente QMI LOC  [plomería lista, alta confianza]
Referencia a copiar: **gpsd `driver_pds.c`** (socket QRTR crudo, ~1 archivo C, sin glib).
Encaja con `/dev/redwood-qmi0..31` (patch 0220/0222) + patrón `cli_open`/`m_*`/`request()`
con callback `on_indication` de `userland/telephony/qmitool.c` (plantilla viva: `sms-watch`).

Secuencia mínima (VERIFICADA contra libqmi):

| Paso | Msg | ID | Notas |
|---|---|---|---|
| Set Operation Mode | req | 0x004A | STANDALONE=4 (NMEA sin red) |
| Set Engine Lock | req | 0x003A | NONE=1 (quirk: a veces obligatorio) |
| Register Events | req | 0x0021 | TLV 0x01 máscara u64: NMEA=1<<2 (0x4), POSITION_REPORT=1<<0 |
| Start | req | 0x0022 | TLV 0x01 session id (u8), 0x10 recurrence (PERIODIC=1), 0x13 intervalo ms (1000) |
| Position Report | **ind** | 0x0024 | lat 0x10 / lon 0x11 (float64 deg), alt, speed, DOP, UTC 0x25 |
| NMEA | **ind** | 0x0026 | TLV 0x01 = una sentencia NMEA (string) |
| Stop | req | 0x0023 | TLV 0x01 session id |

Servicio: `QMI_SERVICE_LOC = 0x10`. Validar primero (si se puede desde Linux/QRTR al mismo
módem): `qmicli -d qrtr://0 --loc-set-operation-mode=standalone`, `--loc-set-engine-lock=none`,
`--loc-follow-nmea`.

**Código real guardado en `~/Downloads/sapphire-gps/refs/`** (gpsd 3.17+3.19, libqmi, ModemManager,
oFono, kernel QRTR, qrtr_lib). Qué portar: **gpsd `driver_pds.gpsd-3.19.c` como esqueleto** (socket
+ framing, ~325 líneas, solo libc) + kernel `qmi_interface.c` para lookup/endianness + libqmi
`qmi-service-loc.json` como spec de TLVs + ModemManager `mm-shared-qmi.c` para los params de START.
(oFono `location-reporting.c` NO sirve: usa el servicio PDS legacy, no LOC.)

Flujo QRTR real (de gpsd): `socket(AF_QIPCRTR, SOCK_DGRAM, 0)` → `getsockname` (nodo local) →
enviar `qrtr_ctrl_pkt{cmd=QRTR_TYPE_NEW_LOOKUP(10), server.service=0x10, server.instance=0}` al
puerto control `0xfffffffe` → leer respuestas `NEW_SERVER(4)` hasta el registro todo-ceros →
tomar `node/port`. QMI va directo en el datagrama (sin QMUX, sin CTL, sin client-id sobre QRTR).

Header QMI (7 bytes LE): `type(u8) txn(u16) msg(u16) len(u16)`; TLV: `key(u8) len(u16) value`.
Bytes reales que arma gpsd:
- REG_EVENTS: `00|tt tt|21 00|0B 00| 01 08 00| <máscara u64>` — máscara `0x05` = NMEA(1<<2)+POSITION(1<<0).
- START (forma completa de libqmi/MM): TLV `01` session id(u8), `10` recurrence u32 (1=periodic),
  `12` intermediate u32 (1=on), `13` intervalo u32 (1000 ms).
- STOP: TLV `01` session id(u8). Respuesta (type 2): TLV `02` = {u16 status, u16 code} — **léela** (gpsd no).
- NMEA ind (type 4, msg 0x26): TLV `01` = string de una sentencia.
- POSITION ind (msg 0x24): lat `0x10`/lon `0x11` (double LE), alt `0x1A/0x1B` float, speed `0x18`,
  heading `0x20`, DOP `0x24` (3×float), UTC `0x25` u64. Todo opcional.

⚠️ Bugs a NO copiar de gpsd: (1) hardcodea `node=0, port=14` (Dragonboard) — usar el del lookup
[arreglado en la 3.19, que usa `connect()`]; (2) walk de TLV `offset += tlv->len` debería ser
`offset += 3 + tlv->len` (rompe con el 0x24 multi-TLV); (3) manda `instance=0x2` en el lookup →
puede no matchear; usar `instance=0` (wildcard) y filtrar tú; (4) no lee respuestas ni valida el
peer en 3.19. `AF_QIPCRTR=42` en Linux — **confirmar contra las cabeceras del kernel de Android**.

### Tramo B — Puente a locationd  [RESUELTO: CLSimulationManager]
Hoy `locationd` corre con `fakebb.dylib` que responde ceros (solo no crashea). En iPhone X
real el GPS entra por el baseband (protocolo Apple indocumentado → vía "nativa" cara).

**Vía recomendada (la más simple, sin Mac/DDI/inyección): `CLSimulationManager`.**
Clase privada de CoreLocation; un daemon root la llama y `locationd` entrega la posición a
TODAS las apps. Es lo que usan locsim/Geranium/Locus. Requiere firmar el daemon con la
entitlement `com.apple.locationd.simulation` (+ `platform-application`,
`com.apple.private.security.container-required=false`) — obligatorio **aunque AMFI sea
permisivo**, porque locationd la comprueba en el peer XPC.

Secuencia por fix (de locsim `main.m`): `stopLocationSimulation` → `clearSimulatedLocations`
→ `appendSimulatedLocation:` (un `CLLocation` completo: lat/lon/alt/accuracy/course/speed) →
`flush` → `startLocationSimulation`. (stop+clear ANTES de append+start o los clientes no
reciben la posición nueva.) Ventaja sobre DTSimulateLocation: lleva alt/accuracy/speed/course,
no solo lat/lon.

**PoC más rápido (antes de escribir el daemon):** instalar locsim y por SSH:
`locsim start -x <lat> -y <lon> -h 5 -r 1`  (`-r 1` = reentrega el último fix entre pushes).

**Verificar on-device:** `launchctl print system/com.apple.locationd | grep simulation` (existe
el mach service); Location Services ON y la app autorizada; `log stream --predicate 'process ==
"locationd"' | grep -i simul`; una app `CLLocationManager` debe ver `didUpdateLocations` con
`sourceInformation.isSimulatedBySoftware == YES`.

**Descartado: `DTSimulateLocation`** (`com.apple.dt.simulatelocation`) — necesita DDI firmada +
lockdownd + pair record; no hay atajo on-device. Solo sirve con Mac/Xcode.
**Largo plazo (nativo):** enseñar al fake AppleBaseband a responder GNSS, o hook en locationd
estilo GeoShim. Alto esfuerzo; solo si `isSimulatedBySoftware` molesta a alguna app.

Entitlements, firma (`ldid -S`) y fuentes: ver refs locsim/Geranium/Locus. Riesgo: rechazo por
entitlement/XPC es **silencioso** → el `log stream` es la única forma de saberlo.

## Siguiente paso concreto
Experimento 1 (probar si LOC 0x10 responde) decide todo. Requiere el teléfono en iOS con
SSH/acceso. (Pendiente: iOS no levantó red USB 192.168.7.x al Mac — resolver para el acceso.)

## Referencias (clones/locales)
- `Angelpro09xd/ios-sapphire` — QMI driver en patch 0220 (`bsd/dev/sweet_qmi_dev.c`), `userland/telephony/qmitool.c`.
- `MakrSas/topaz-woa` — `drivers/TopazModem/wwan.c` (mejor patrón multi-cliente QMI/QRTR).
- `MakrSas/ios-topaz` — parches 0118/0121/0122 (transporte QRTR + cliente QMI WLFW de ejemplo).
- libqmi — `data/qmi-service-loc.json`, `src/qmicli/qmicli-loc.c`.
- gpsd `driver_pds.c` — de la patch meta-qcom "Introduce Qualcomm PDS service support".
- ModemManager `mm-shared-qmi.c`; oFono `drivers/qmimodem/location-reporting.c`.
- idevicesetlocation (libimobiledevice) para el formato DTSimulateLocation.

## Preguntas abiertas
1. **[CASI RESUELTA]** GNSS está en el módem (no ADSP); stock no lo habilita. Probable causa de
   no verlo: overflow de `q_srv[64]` sin DEL_SERVER. Confirmar leyendo el log de arranque (¿`10:2`?).
2. **[RESUELTA]** Código real portado: en `~/Downloads/sapphire-gps/refs/` (gpsd 3.19 = esqueleto).
3. **[RESUELTA]** Puente a locationd: `CLSimulationManager` + entitlement `com.apple.locationd.simulation`
   (no DTSimulateLocation, no DDI). PoC: `locsim`.

## Refs extra (en scratchpad/gps_refs/, algunas en ~/Downloads/sapphire-gps/refs/)
- `locapi_v02_moto/` — cliente LOC de referencia de Qualcomm (`LocApiV02.cpp`, `loc_api_v02_client.c`).
- `android_device_xiaomi_sm6225-common` — blobs GPS stock (libloc_api_v02, loc_launcher, izat.conf).
- `HouseOfBalance/ios26-sapphire` — mismo teléfono, iOS 26; `drivers/modem/hakios.mpss.c` parsea los
  `.jsn` para el servreg (sin cliente LOC, pero útil de referencia del lado modem).
- Observabilidad: `~/Downloads/sapphire-gps/mac-uslog.sh` (captura del log kernel en macOS).
