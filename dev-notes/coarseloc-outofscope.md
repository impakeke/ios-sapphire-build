# 13 — coarseloc: ubicación instantánea sin GNSS (fuera de scope)

Idea que Angel no haría (está en bring-up de kernel): posición **aproximada al instante y sin cielo
despejado**, usando lo que YA funciona (celda LTE + escaneo Wi-Fi) contra bases de datos abiertas,
alimentando `locationd` por el mismo `CLSimulationManager` del plan de GNSS. Complemento/fallback del
GPS real. Verificado contra libqmi `qmi-service-nas.json` y el código de beaconDB. **Nadie en el scene
iOS-on-Android lo ha hecho.**

## Entradas en el dispositivo

**Celda (QMI NAS sobre QRTR):**
- `Get Cell Location Info 0x0043` → TLV `0x13` LTE Intrafreq v2: PLMN (3B BCD), TAC (u16), **Global Cell ID
  = ECI** (u32), EARFCN, **PCI** (u16 "Serving Cell ID"), RSRP/RSRQ.
- `Get System Info 0x004D` → TLV `0x19` LTE: MCC/MNC (strings 3 char), TAC, CID.
- `Get Signal Info 0x004F` → `0x14`: RSSI/RSRQ/RSRP/SNR.
- `Register Indications 0x0003` (TLV `0x18` System Info) → re-consultar `0x0043` en cada `System Info ind
  0x004E`. Sin polling.
- **Límite real:** los vecinos LTE solo traen PCI/señal (sin Global Cell ID) → **no se pueden buscar en
  BD**. Posicionamiento por celda = **solo serving cell**. (Timing Advance 0x1E solo en connected mode.)

**Wi-Fi:** BSSID+RSSI del escaneo que ya funciona (consumir la salida del passive-scan existente). Filtrar:
quitar SSID ocultos y los que terminan en `_nomap`, mínimo 2 APs.

## Bases de datos abiertas

- **beaconDB (la mejor):** sin cuenta ni key, API Ichnaea. `POST https://api.beacondb.net/v1/geolocate`.
  Autohospedable (Rust+Postgres) pero sin dumps aún → vacío. Pide User-Agent identificable.
- **OpenCellID:** CC BY-SA, token gratis. CSV offline (~105 MB gz; columnas `radio,mcc,net,area,cell,unit,
  lon,lat,range,...` → `area`=TAC, `cell`=ECI, `unit`=PCI). Ideal para lookup **offline** (sin red).
- Unwired Labs (fallback, ~100 req/día). MLS **muerta** (2024).

**Request (Ichnaea):**
```json
{"considerIp":false,
 "cellTowers":[{"radioType":"lte","mobileCountryCode":M,"mobileNetworkCode":N,
   "locationAreaCode":TAC,"cellId":ECI,"psc":PCI,"signalStrength":-95}],
 "wifiAccessPoints":[{"macAddress":"aa:bb:..","signalStrength":-60,"frequency":2437,"age":1200}]}
```
Gotchas: **incluir `psc`=PCI** en LTE (si no, 404 en beaconDB); **`considerIp:false`** (descartar respuestas
con `fallback:ipf`); User-Agent `coarseloc/0.1`.

## Matemática y precisión
- beaconDB: Wi-Fi = centroide ponderado `10^(dBm/30)` (≥2 APs); celda = primer match, accuracy = radio
  guardado (piso 50 m). `accuracy` = círculo de confianza 95%.
- Esperado: Wi-Fi 20–100 m; **serving-cell** 300 m–1.5 km urbano, 2–10 km rural.
- **Offline:** filtrar CSV a tu MCC + LTE → SQLite `(mcc,net,area,cell)`→`lat,lon,range,samples` (pocos MB/país).
  Lookup serving cell → `(lat,lon)`, `hAccuracy=max(range,500)`. Miss → centroide de la TAC (5–15 km).

## Diseño `coarseloc`
```
QMI NAS 0x0043 (en ind 0x004E) ─┐
Wi-Fi scan existente ───────────┤→ resolver(beaconDB | SQLite OpenCellID) → arbiter → CLSimulationManager
QMI-LOC fix (GNSS, luego) ──────┘
```
- Triggers: boot/registro (offline, instantáneo), cambio de serving cell, cambio de Wi-Fi, refresco 60–120 s.
- Cache por cell-key y por hash del set de BSSIDs. Rechazar online a >20 km del centroide offline.
- CLLocation: `verticalAccuracy=-1, speed=-1, course=-1`. Piso ~30 m (Wi-Fi) / ~300 m (celda).
- **Un solo dueño del CLSimulationManager** (GNSS y coarse por el mismo canal: un arbiter). Regla: si hay fix
  GNSS <10 s y accuracy válida → solo GNSS; GNSS stale (indoor) → coarse tras hold-off ~30 s con accuracy inflada.
- Seed opcional: inyectar la coarse a QMI-LOC (Inject Position) para acortar TTFF.

## Prior art / novedad
- `locsim` = la vía de inyección (y su header declara `setSimulatedCell:`/`startCellSimulation`/
  `setSimulatedWifiPower:` — semántica sin documentar, **vale la pena experimentar**).
- geoclue (default beaconDB tras morir MLS), Sailfish (oFono+OpenCellID), microG Local GSM Backend (offline
  CSV, = diseño offline de arriba). **Ningún tweak iOS** deriva ubicación de celda/Wi-Fi contra BD abierta.

## Riesgos
- locationd en iOS 16.7 solo probado indirecto (locsim fue iOS 14.3): ¿mantiene una location apendeada fresca
  o hay que re-push? Verificar.
- Fixes marcados `isSimulatedBySoftware` (apps lo pueden ver). CC BY-SA de OpenCellID exige atribución si se
  embebe la BD.
- Realista ya: serving-cell offline + beaconDB online + refinamiento Wi-Fi. Aspiracional: trilateración (vecinos
  sin ID), timing-advance, aprender celdas de fixes GNSS (fase 2), `setSimulatedCell:`.

Descargas de refs del agente: `scratchpad/dl/` (incl. libqmi NAS JSON).
