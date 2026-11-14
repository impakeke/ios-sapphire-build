# 21 — Lo que el port quita o sustituye de iOS 16.7.16: auditoría y qué restaurar, 2026-11-14

Informe fechado. Pregunta: de todo lo que el instalador, `tools/sapphire-clean-base.sh` y los pasos de
actualización eliminan, desactivan o sustituyen del sistema de 20H392, ¿qué usa iOS, qué se rompe sin ello y qué hay
que devolver? Nace de 20 §2: el widget de Calendario salía en blanco porque el instalador quitaba la extensión de
intents que publica su configuración.

Convención: **[O]** observación propia (archivo, log o binario citado), **[M]** medida en el teléfono, **[H]**
hipótesis sin demostrar. Fuente primaria del sistema original: el dmg raíz del IPSW (`087-86698-044.dmg`, montado en
`~/sapphire-angel/research/widgets/ipsw/mnt`), su manifiesto (`mtree.txt`, extraído del `.mtree` del IPSW con
`research/widgets/scripts/pbzx.py`) y el `launchd.plist` original (`ipsw-launchd.plist`). Logs del teléfono: los de 20
(`research/widgets/log-*.txt.gz`, ~15 min de log unificado del 14 nov). Herramientas en `research/widgets/tools/`:
`lsplug` (consulta o registra una extensión en LaunchServices), `cstr`, `pstack`, `addrsym`, `tevents` (20 §1).

## Resultado en breve

1. **Cuatro mecanismos** (§1): bundles excluidos al extraer el sistema (`installer/recipes/appex-remove.txt`, y los
   mismos en `tools/sapphire-clean-base.sh`); jobs borrados de `launchd.plist` (`installer/recipes/launchd-remove.txt`)
   o desactivados con `launchctl` (paso de actualización 20); plug-ins de audio HAL apartados; y programas sustituidos
   o envueltos en los jobs de launchd (fairplayd.H2 → `fpstub`, bluetoothd y BlueTool → `btshim`, locationd y
   abm-helper → `bbstart`, FileProvider → `fpstart`).
2. **[M] Comparado con el IPSW, al teléfono le faltaban 25 bundles** (de 5135 bundles `.appex/.app/.framework/.bundle/
   .driver/.plugin/.xpc` del manifiesto): 16 extensiones y los 9 plug-ins HAL (que están apartados, no borrados); y 8
   jobs de `launchd.plist`. La extensión de intents de Calendario era una de ellas y ya está repuesta y verificada (20 §6).
   Siete de las rutas `/Applications/…` de `appex-remove.txt` no quitan nada: en el IPSW esas apps vienen en
   `/private/var/staged_system_apps/` y el instalador las mueve a `/Applications` con sus extensiones (§2.2).
3. **Lo que conviene devolver primero:**
   - **`dasd`** (§2.1). Es el planificador de actividades en segundo plano de iOS y el que guarda los presupuestos de
     recarga de los widgets (`_DASWidgetRefreshBudgetManager` en el binario). Sin él, chronod falla al pedir los presupuestos (16
     «Error obtaining all budgets: … Code=4099» en el log) y las actividades que programa
     (`com.apple.chronod.nextScheduledTimelineRefresh`) se envían a un demonio que no existe. Se quitó porque giraba
     tras el salto de reloj de 1970 a 2026; hoy `rtcd` pone la hora en el arranque.
   - **`MobileTimerIntents.appex`** (§2.2). Es el mismo caso que Calendario: `WorldClockWidget.appex` declara
     `INIntentsExtensionBundleIdentifier = com.apple.mobiletimer-framework.MobileTimerIntents`, y esa extensión publica
     `ClocksIntent` y `ClocksSingleIntent`, que configuran el widget de Reloj mundial.
   - **`coreduetd`** (§2.1), después de `dasd` y por separado. Es el almacén de conocimiento de Duet; SpringBoard falla
     14 veces al registrar en él («ATXAppDirectoryClient: log to duet failed … 4099») [H: el destino exacto no aparece
     en el log].
4. **Bien quitados por hardware o por función** (§2.3-2.5): los plug-ins HAL de AOP, CarPlay, AirPlay, banda base,
   Octavia y USB; el software update (prepara una OTA que no puede aplicar); `wifip2pd` (AWDL, sin ese modo de radio);
   los pósters que exigen Metal en su proceso (Aegir, Emoji) mientras solo el servidor de ventanas tenga Metal.
5. **Lo que se queda a medio camino:** `fpstub` evita los cuelgues, pero sin FairPlay no hay firma Mescal y el Tiempo
   no obtiene datos (20 §4). Qué mirar para que fairplayd arranque: §3.

## 1. Inventario

**Extracción del sistema** (`installer/recovery/sapphire.sh` L325-L383): copia `launchd.plist` y le aplica las recetas
(renombra `_PanicOnCrash`, sustituye los jobs de `installer/recipes/launchd/*.plist`, añade los `com.sapphire.*`, borra
las etiquetas de `launchd-remove.txt`); mueve los plug-ins HAL de Apple a `HAL.apple/` (y `BTAudioHALPlugin` a
`HAL.disabled/`); excluye las rutas de `appex-remove.txt` («widgets and speech extensions that crash-loop without
Metal, the modem's data or speech assets»); pasa las apps de `staged_system_apps` a `/Applications`.

**Pasos de actualización** (`installer/update/steps.d/`): 10 devuelve `VirtualAudio.plugin` a HAL; 20 desactiva el
software update; 50 cambia el programa de `com.apple.fairplayd.H2` a `/redwood/bin/fpstub` y pone
`CA_DISABLE_DIRTY_REGIONS=1` a backboardd.

**[O] `launchd.plist` del teléfono frente al del IPSW:** mismas `AppExtensions` (421) y `SystemLibraryTreeState`
(1998). Faltan 8 jobs: `com.apple.dasd`, `com.apple.coreduetd`, `com.apple.aggregated`, `com.apple.wifip2pd`,
`com.apple.mobile.softwareupdated`, `com.apple.softwareupdateservicesd`, `com.apple.OTATaskingAgent`,
`com.apple.OTACrashCopier`; sobran los 11 `com.sapphire.*`/`org.sapphire.*`. Desactivados con `launchctl`
(`print-disabled system`): los de software update (`MobileSoftwareUpdate.CleanupPreparePathService` y los anteriores) y
`magicswitchd.companion`, `security.otpaird`, `relevanced`, `dhcp6d`, `bootpd`. Estos cinco no aparecen en el repo;
`dhcp6d` y `bootpd` ya vienen con `Disabled = true` en el `launchd.plist` del IPSW.

## 2. Tabla

Columnas: **Quién lo usa** en 16.7 (del binario o su `Info.plist`, salvo [H]); **Sin él** (con evidencia del log del
teléfono cuando la hay); **Por qué se quitó** (lo que dice el repo); **Restaurar**.

### 2.1 Demonios borrados de `launchd.plist`

| Job | Quién lo usa | Sin él | Por qué se quitó | Restaurar |
|---|---|---|---|---|
| `com.apple.dasd` (`/usr/libexec/dasd`; servicios `com.apple.duetactivityscheduler`, `com.apple.dasd.end-prewarm`) | Todo `xpc_activity` y BGTaskScheduler, prewarm de apps, presupuestos de recarga de widgets (`_DASWidgetRefreshBudgetManager`, `_DASWidgetBudget`, `maxWidgetRefreshBudgetForSystemDaily` en el binario) | **[M]** chronod: 16× «Error obtaining all budgets: … 4099»; UserEventAgent envía `DASActivity` (en el log: `chronod.nextScheduledTimelineRefresh`, `springboard.posterboardupdate.prewarm`, `duetexpertd.heuristicactionproducer-refresh`…) a un demonio que no existe [H: no se ejecutan nunca]. Recargas programadas de widgets y mantenimiento en segundo plano | «spun the same way» que coreduetd tras el salto de reloj 1970 → 2026 (`sapphire-clean-base.sh` L47-49) | **Sí, primero.** Con `rtcd` la hora es correcta desde el arranque; medir CPU de dasd 10 min y comprobar que la actividad `chronod.nextScheduledTimelineRefresh` se ejecuta |
| `com.apple.coreduetd` (servicios `coreduetd.knowledge`, `coreduetd.people`, sugerencias proactivas) | Almacén `_DKKnowledgeStore` de Duet: uso de apps, sugerencias de Siri, App Library, Spotlight | **[M]** SpringBoard: 14× «ATXAppDirectoryClient: log to duet failed … 4099» [H: el destino es coreduetd] | Igual que dasd | Sí, después de dasd y por separado |
| `com.apple.aggregated` (AggregateDictionary; servicios `com.apple.powerlog*`) | Contadores de ADClient y registro de energía (PowerLog) | Sin evidencia en el log | «spun a whole core after the clock jumped» | Opcional; no aporta función visible |
| `com.apple.wifip2pd` | AWDL / Wi-Fi Direct (AirDrop, AirPlay entre dispositivos) | Sin evidencia; el chip no tiene ese modo | «no such radio mode here» | No |
| `mobile.softwareupdated`, `softwareupdateservicesd`, `OTATaskingAgent`, `OTACrashCopier`, `CleanupPreparePathService` | Actualizaciones OTA | Ajustes > General > Actualización no funciona | «prepares an OTA it can never apply: restore error 60» (paso 20) | No |

### 2.2 Extensiones excluidas al instalar

| Bundle | Punto de extensión | Quién lo usa | Sin él | Por qué se quitó | Restaurar |
|---|---|---|---|---|---|
| `CalendarWidget.framework/PlugIns/IntentsExtension.appex` (repuesta) | `intents-service` | `CalendarWidgetExtension` (`INIntentsExtensionBundleIdentifier`); publica `CalendarWidgetIntents.intentdefinition` | **[M]** widget de Calendario en blanco (20 §2) | lista de octubre «crash-loop without Metal»; no es UI ni usa Metal | **Repuesto en el teléfono** (20); el repo ya no lo excluye |
| `MobileTimer.framework/PlugIns/MobileTimerIntents.appex` | `intents-service` | `WorldClockWidget.appex` (`INIntentsExtensionBundleIdentifier`); intents `ClocksIntent`, `ClocksSingleIntent`, alarmas y temporizadores de Siri y Atajos | [H] el widget de Reloj mundial falla igual que el de Calendario; Atajos sin acciones de Reloj | misma lista | **Sí** |
| `Applications/AppStore.app/PlugIns/AppStoreWidgetsExtension.appex` | `widgetkit-extension` | Widget de App Store | No hay widget de App Store | misma lista | Sí, cuando el render de widgets quepa en los plazos (20 §3) |
| `AppPlaceholders/{AppleTV,Books,Home,Music,Passbook,Stocks,Weather}.app/PlugIns/*` (8) | widgets e intents | Copias de los marcadores de apps borrables; las apps reales van en `/Applications` | Nada visible: **[M]** las 102 extensiones de las apps de `staged_system_apps` están en `/Applications` del teléfono, incluidos los widgets de Música, Casa, Libros, TV, Bolsa, Wallet y Tiempo | misma lista | Indiferente mientras las apps reales estén instaladas |
| `AegirProxyApp.app/PlugIns/AegirPoster.appex` | `posterkit.provider` | Póster «Astronomía» | No se puede elegir ese fondo | se reiniciaba en bucle (10 veces en un arranque, NOTES 2026-10-23) | Cuando los procesos de póster tengan Metal (`metal_all`) |
| `EmojiPoster.framework/PlugIns/EmojiPosterExtension.appex` | `posterkit.provider` | Póster de emoji | No hay fondo de emoji | misma lista | Igual que Aegir |
| `MacinTalkAUSP.appex`, `SiriTTSSynthesizerAU.appex`, `KonaSynthesizer.appex` | `AudioUnit` (`ausp`) | Voces de Leer pantalla, VoiceOver, Siri | Sin síntesis de voz | ~30 caídas cada uno sin assets de voz (NOTES 2026-10-23) | Después, con los assets de voz descargados por `mobileassetd` |

### 2.3 Plug-ins de audio HAL apartados

| Plug-in | Para qué | Restaurar |
|---|---|---|
| `BTAudioHALPlugin.driver` (en `HAL.disabled/`) | Audio Bluetooth (A2DP/HFP) | Cuando el audio Bluetooth funcione: con bluetoothd ausente reintentaba ~110 veces por segundo (NOTES 2026-10-23); hoy bluetoothd arranca vía `btshim` [H: comprobar antes los reintentos] |
| `AppleAOPAudioPlugin`, `BasebandVoice`, `NetworkUplinkClock` | Procesador siempre encendido de Apple; voz y reloj de la banda base de Apple | No: no existe ese hardware (el audio de llamadas va por `RedwoodAudio.driver`) |
| `AirPlayHalogen`, `AppleTimeSyncAudioClock`, `CarPlayHalogen`, `OctaviaHalogen`, `AppleUSBAudio` | AirPlay, CarPlay, audífonos, audio USB | No por ahora (sin AWDL ni USB host); revisar AirPlay cuando haya Wi-Fi estable |

### 2.4 Programas sustituidos o envueltos

| Job | Qué corre | Qué espera iOS | Estado |
|---|---|---|---|
| `com.apple.fairplayd.H2` | `/redwood/bin/fpstub`: registra `com.apple.fairplayd`, `.versioned`, `com.apple.unfreed` y contesta MIG_SERVER_DIED | fairplayd.H2 con su user client del kernel (§3) | Sin FairPlay: Mescal falla (Tiempo sin datos, 20 §4), y lo mismo todo lo que firme con Mescal o FairPlay [H: App Store, iTunes, ADI de `adid`] |
| `com.apple.bluetoothd`, `com.apple.BlueTool` | `/redwood/bin/btshim` (`bdstart`, `bluetool`) | bluetoothd con el chip de Apple | Fuera de esta auditoría |
| `com.apple.locationd`, `com.apple.abm-helper` | `/redwood/bin/bbstart` + banda base falsa (`fakebb`, ceros) | AppleBaseband | locationd no tiene posición; el Tiempo usa la ciudad por defecto (20 §4) |
| `com.apple.FileProvider` | `/redwood/bin/fpstart` | — | Fuera de esta auditoría |
| `com.apple.backboardd` | `CA_DISABLE_DIRTY_REGIONS=1` | regiones sucias de CoreAnimation | Ver 19 |

### 2.5 Otros

`magicswitchd.companion`, `security.otpaird` y `relevanced` están desactivados en el teléfono sin rastro en el repo ni en
el `launchd.plist` del IPSW (sin `Disabled`). Son funciones de Apple Watch, emparejamiento de Octagon y el motor de
relevancia del reloj; su efecto en el teléfono no está medido. Origen pendiente.

## 3. fairplayd.H2: qué habría que mirar

- **[O] Entitlements del binario** (`/usr/sbin/fairplayd.H2`, 19 MB, del IPSW): `com.apple.private.FairPlayIOKitUserClient.access`
  y `com.apple.security.iokit-user-client-class = com_apple_driver_FairPlayIOKitUserClient`, además de `adi-client`,
  `lskd-client` y el almacenamiento `fpsd`. Es decir, abre el user client del kext FairPlayIOKit.
- **[O]** El repo no tiene nada de FairPlayIOKit en el kernel (`xnu/patches`, `shim`), y **[M]** `ioreg -l` en el
  teléfono no tiene ninguna entrada con «fairplay»: el servicio que fairplayd abre no existe en este XNU [H: que por
  eso sale con código 0 antes de registrar sus servicios].
- Pasos: (1) lanzar
  `/usr/sbin/fairplayd.H2` a mano con `oslog -p fairplayd.H2` en paralelo y con la traza de IOKit del port
  (`sweetiolog=fairplayd.H2`) para ver qué `IOServiceGetMatchingService`/`IOServiceOpen` falla antes de salir;
  (2) leer en FairPlayIOKit de un kernelcache de iPhone X qué selectores usa el user client; (3) decidir con eso si un
  `FairPlayIOKit` del port puede contestar lo que fairplayd necesita para arrancar (servicio registrado) aunque no
  descifre nada. La firma Mescal y el ADI de `adid` dependen de claves por dispositivo de Apple: que funcionen de
  verdad no es esperable; lo que sí se puede conseguir es que fallen rápido y con error en vez de colgarse.

## 4. Orden propuesto

1. `MobileTimerIntents.appex`: el mismo procedimiento que la extensión de Calendario (20 §6): copiarla del dmg raíz con
   `root:wheel`, quitar su línea de `appex-remove.txt` y de `sapphire-clean-base.sh`, y dejar que lsd la registre en
   el siguiente arranque (`registerPlugin:` en caliente se queda esperando a lsd). Verificación: un widget de Reloj
   mundial en el home y `lsplug query com.apple.mobiletimer-framework.MobileTimerIntents` con sus
   `intentDefinitionURLs`.
2. `dasd`: devolver su job al `launchd.plist` (desde `/var/root/launchd.plist.pre-0.1.8` o el del IPSW) y quitarlo de
   `launchd-remove.txt` y de `DAEMONS` en `sapphire-clean-base.sh`; medir 10 min su CPU y que chronod ya no registre
   «Error obtaining all budgets».
3. `coreduetd`, por separado y con la misma medida.
4. `AppStoreWidgetsExtension` y los pósters con Metal, cuando haya Metal por proceso y el render de widgets quepa en
   los plazos de chronod.
5. Voces: con los assets descargados.
