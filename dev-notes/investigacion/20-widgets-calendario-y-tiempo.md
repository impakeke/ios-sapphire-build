# 20 — Widgets de Calendario y Tiempo: por qué no se muestran y por qué la extensión de Calendario gira, 2026-11-14

Informe fechado. Síntomas: en el home el widget de Calendario sale en blanco y el de Tiempo muestra «No weather data»
y parpadea; `CalendarWidgetExtension` consume 57-100 % de un núcleo en todas las mediciones del día (03 M5; 17 §4.2)
y deja informes `cpu_resource` («90 seconds cpu time over 96 seconds»). La extensión no es cliente de la GPU (03),
así que Metal no interviene.

Convención: **[O]** observación propia (log, archivo o código citado), **[M]** medida en el teléfono de esta
investigación (archivo crudo citado), **[H]** hipótesis sin demostrar. Material crudo, fuera de git, en
`~/sapphire-angel/research/widgets/`: logs unificados `log-{a..f}.txt.gz` y `w20-log1.txt.gz`, muestreo `ps-c.*`,
traza `kd-e.*`, `thrsched-*`, pilas `wx-e-*`, `adid.*`, `weatherd.*`, base de chronod `chronod/`, binario y
`Info.plist` de la extensión `bin/`, scripts de cada ensayo y herramientas nuevas en `tools/`.

## Resultado en breve

1. **Calendario en blanco: el widget no tiene intent.** El widget del home es `CalendarUpNextWidget`, configurable
   con `EKUICalendarsIntent`. SpringBoard pide el intent por defecto y `INCWidgetIntentProvider` responde «No intent
   definitions found in extensions»; la extensión recibe el timeline sin intent, registra «No intent in
   timeline(for:with:completion:)» y devuelve el error CHS 1101 («Returned view collection was either nil or
   empty»). chronod reintenta una vez, marca el timeline como fallido y lo pinta vacío (§2). La definición del intent
   la publica `CalendarWidget.framework/PlugIns/IntentsExtension.appex`, la extensión que nombra el
   `INIntentsExtensionBundleIdentifier` del widget, y el port la quita al instalar (`installer/recipes/appex-remove.txt`)
   y en `tools/sapphire-clean-base.sh`. Causa demostrada en el log; que reponerla lo arregle es [H] hasta probarlo.
2. **El giro de la extensión de Calendario es trabajo real repetido, no un bucle infinito.** chronod pide los
   placeholders de las 10 combinaciones de widget y tamaño (`getPlaceholders`) con un watchdog de ~15 s. La extensión
   tarda 25-30 s en renderizarlos y archivarlos; chronod cancela la sesión a los ~15 s, descarta el resultado y vuelve
   a pedirlo enseguida (`initialReloadFailureRetry`), 3-4 veces. Cada lanzamiento cuesta 44,7-48,5 s de CPU (n=3) y
   después la extensión queda parada sin consumir (§3).
3. **La extensión trabaja en un A53.** Su hilo principal es de QoS por defecto (prioridad 31) en 4/4 instancias, y con
   `sweetsched=15` esos hilos van al cluster E: el 99,0 % de su tiempo en los A53 a ~1,9 GHz (n=1, `kdsched`). En un
   A73 el mismo trabajo cabría en el watchdog [H, sin medir] (§3.3).
4. **«Permanente» porque se relanza a cada rato:** cada respawn de backboardd (los ensayos A/B lo hacen con
   `killall backboardd`) termina todas las extensiones y chronod las relanza. Entre las 12:36 y las 12:51 hubo 9
   respawns, uno cada 1-1,5 min (§3.4). Sin respawns la extensión queda parada tras ~50 s (n=3).
5. **Tiempo sin datos: falla la firma Mescal (FairPlay).** El widget obtiene el tiempo del servicio WDS con un token
   JWT que WeatherDaemon firma con Mescal (`WDSJWTMescalSigner`). En el teléfono, `AMSMescalFairPlay: Init failed` →
   «Mescal Failed», «Failed to fetch hardware info» (n=1); en otros 4 intentos el log se corta tras «Starting to
   generate JWT token request». chronod corta cada `getTimelines` a los ~30 s y reintenta. En este port fairplayd.H2
   no corre: lo sustituye `fpstub`, que contesta MIG_SERVER_DIED a todo (§4).

## 1. Cómo se observa

**Log unificado.** No hay `log` de Apple en el teléfono, pero sí `/var/jb/usr/bin/oslog` (Procursus): `oslog
[--info|--debug] [-p PID|nombre]` sigue el log en vivo, con los valores privados como `<private>`. El log persistente
está en `/var/db/diagnostics` (448 MB) y `/var/db/uuidtext` (141 MB); leerlo exigiría copiarlo a la Mac (no hay
sitio) o un lector de tracev3 en el teléfono, así que los ensayos provocan el evento con el log en vivo. Con
`--debug` el propio streaming activa los mensajes de depuración de todos los procesos y encarece la extensión; los
ensayos `d`, `e` y `f` van a nivel por defecto.

**Disparadores.** Matar solo `CalendarWidgetExtension` no la relanza: chronod tiene el timeline «already in a
failed state» y no vuelve a pedirlo (ensayo `a`). Reiniciar chronod (`kill -9`; launchd lo relanza y SpringBoard
reconecta) sí provoca la recarga completa (ensayos `c`-`f`). `appopen com.apple.mobilecal` con la pantalla bloqueada
no abre la app (ensayo `b`).

**Herramientas nuevas** (fuentes en `research/widgets/tools/`, compiladas como las de `tools/perf/`):
`pstack PID SALIDA` (una pila por hilo, con la lista de imágenes), `addrsym SALIDA` (simboliza en el teléfono con
`dladdr`: la caché compartida tiene el mismo slide en todos los procesos de un arranque; los símbolos no exportados
salen como imagen+desplazamiento), `cstr IMAGEN SUBCADENA...` (cadenas de `__cstring`/`__oslogstring` de una imagen de
la caché), `tevents PID...` (mensajes Mach enviados y recibidos por tarea).

## 2. Calendario: por qué no se muestra

**[O] La cadena en el log** (`log-c`, repetida en cada arranque de SpringBoard: 12:38:13, 12:38:51, 12:40:06):

```
SpringBoard: Begin loading default intent for [com.apple.mobilecal.CalendarWidgetExtension - EKUICalendarsIntent]
SpringBoard: -[INCWidgetIntentProvider provideIntentWithOptions:completionHandler:] Providing intent for chrono with
             options: extensionBundleIdentifier = com.apple.mobilecal.CalendarWidgetExtension, intentType = EKUICalendarsIntent
SpringBoard: Got values for keys { INIntentsExtensionBundleIdentifier } from CF SPI (fast path).
SpringBoard: -[INCWidgetIntentProvider provideIntentWithOptions:completionHandler:] No intent definitions found in extensions.
...
CalendarWidgetExtension: No intent in timeline(for:with:completion:)
CalendarWidgetExtension: Request ended for com.apple.CalendarWidget.CalendarUpNextWidget:systemSmall - error:
             Error Domain=CHSErrorDomain Code=1101 "Returned view collection was either nil or empty."
chronod: [...CalendarUpNextWidget:systemSmall...] reload: failed with error ... (CHSErrorDomain error 1101.)
chronod: Task [3] ... Reload failed; 1 retries remaining   → Task [28] ... 0 retries remaining
chronod: [...] reload: No content ... Evaluated inner view with result: EMPTY
chronod: [...] Ignoring staleness check - timeline is already in a failed state.
```

La línea `Error ... Security policy determined view should be empty: ... inSecureMode: false ...` acompaña a cada
evaluación sin contenido; todas sus condiciones de seguridad dan permiso y no es la causa.

**[O] Dónde está la definición del intent.**
- `CalendarWidgetExtension.appex/Info.plist`: `INIntentsExtensionBundleIdentifier =
  com.apple.CalendarWidget.IntentsExtension`, `IntentsSupported = [EKUICalendarsIntent,
  NextEventComplicationConfigurationIntent]`. El bundle de la extensión no contiene ningún `.intentdefinition`.
- La definición está en `CalendarWidget.framework/Base.lproj/CalendarWidgetIntents.intentdefinition`, y la extensión
  de intents que la sirve sería `CalendarWidget.framework/PlugIns/IntentsExtension.appex`: en el teléfono `PlugIns/`
  está vacío.
- El widget de Tiempo, que sí tiene intent, lleva su definición dentro de su propio bundle
  (`WeatherWidget.appex/Base.lproj/WeatherIntents.intentdefinition`), y SpringBoard la resuelve: «Successfully
  unarchived widget intent» para él.
- El port quita esa extensión: `installer/recipes/appex-remove.txt` (la excluye al extraer el sistema;
  `installer/recovery/sapphire.sh` la comenta como «widgets and speech extensions that crash-loop without Metal») y
  `tools/sapphire-clean-base.sh` (lista `EXTENSIONS`). Que esta extensión de intents, sin interfaz, entrara en bucle
  sin Metal no está medido en ningún sitio: es una lista de octubre aplicada en bloque.

**Descartado con medida.**
- EventKit, calaccessd y TCC: la extensión lee los eventos (cientos de «NarrowEventLayout - Building view from
  model», «Accumulating occurrences…»), luego el acceso funciona. Tiene `com.apple.private.tcc.allow.overridable =
  [kTCCServiceCalendar]`.
- Contenedor y escritura del snapshot: el contenedor de datos de la extensión
  (`Containers/Data/PluginKitPlugin/<UUID>/SystemData/com.apple.chrono/{placeholders,timelines}`) es de `mobile`,
  se escribe, y guarda un placeholder de una vez en que la sesión terminó a tiempo.
- La base de chronod (`chronod/chrono.sql`) registra la extensión y sus descriptores con normalidad.

**Interpretación.** La parte que el widget del home necesita, el timeline, falla en 0,1 s por falta del intent; lo
demás (placeholders) es el giro de §3, que tampoco termina. Sin timeline ni placeholder válidos, chronod lo pinta
vacío y no vuelve a intentarlo hasta el día siguiente o hasta otro reinicio.

## 3. Calendario: por qué gira

### 3.1 La secuencia

**[M] Sesiones de chronod con la extensión** (`log-d`, nivel por defecto; `log-c` igual con `--debug`):

```
12:43:10 getTimelines(1) request      12:43:10 getPlaceholders request
12:43:14 getTimelines(1) result (error 1101)                     → reintento inmediato
12:43:24 getPlaceholders error: CHSErrorDomain 1001 "Watchdog provision violated for getPlaceholders"
12:43:24 getPlaceholders request      (initialReloadFailureRetry)
12:43:45 request → 12:44:00 error → 12:44:00 request → 12:44:15 error → 12:44:15 request → 12:44:30 error
```

Watchdog de `getPlaceholders`: 14-15 s, en las 10 sesiones de `log-c` y `log-d` cuya petición y corte quedan en el log. Cada sesión pide el lote completo:
`CalendarUpNextWidget` en systemSmall, Medium, Large y ExtraLarge, `CalendarListWidget` Large,
`CalendarMonthWidget` Small y `CalendarNextEventComplication` en tres tamaños de accesorio.

**[M] Lo que hace la extensión mientras tanto** (pid 3044): un lote va de 12:43:37 a 12:44:07 («Batch ended -
success», 30 s); systemMedium tarda 8-9 s, Large y ExtraLarge 2-3 s cada uno con el log a nivel por defecto (con
`--debug`, hasta 12 s). Los lotes siguen y terminan con éxito aunque chronod ya haya cancelado la sesión que los pidió;
los nuevos se encolan detrás en el mismo hilo principal.

**[M] CPU por lanzamiento** (`ps` cada 2-5 s; ensayos `d` y primera observación):

| pid | CPU acumulada | después |
|---|---|---|
| 1331 | 44,79 s en ≤ 50 s de vida | parada (`S`, sin CPU) más de 5 min, hasta que se mata |
| 3044 | 48,48 s en 53 s | parada hasta el siguiente respawn |
| 3492 | 44,72 s en 44 s | parada hasta el siguiente respawn |
| 2267, 2901 | 29,6 y 26,5 s | terminadas antes de acabar por un respawn de backboardd |

El informe `cpu_resource` (90 s en 96 s) corresponde a dos lanzamientos seguidos.

### 3.2 En qué se va la CPU

**[M] `psamp` del hilo principal** (pid 2267, 40 s cada 2 ms, 1698 muestras, todas en ejecución; con `--debug`
activo; `research/widgets/ps-c.*`). Tiempo propio por imagen: libswiftCore 22,6 %, SwiftUI 19,2 %, CoreFoundation
11,0 %, libsystem_malloc 9,8 %, libobjc 7,6 %, AttributeGraph 6,4 %, libicucore 4,5 %, Foundation 3,4 %, CoreText
3,3 %. Inclusivo: `AGGraphGetValue` 42,7 %, `KeyedEncodingContainer.encode` (Codable de Swift) 20,1 %. `thrtop`: el
hilo principal es el 95,3 % de un núcleo; el resto de hilos, < 0,5 %.

Interpretación: es la evaluación del árbol de vistas de SwiftUI, el formateo de fechas y el archivado de cada entrada
del timeline (`.chrono-timeline`), sin esperas ni reintentos internos. El informe `cpu_resource` da la misma pila más
pesada (XPC → WidgetKit → SwiftUI → AttributeGraph → CalendarWidget → EventKitUI).

### 3.3 Dónde corre

**[M] `thrsched`** de 4 instancias (2901, 3044, 3492, 3861): hilo principal `pol=1 base=31 qos=df`.

**[M] `kdsched` 8 s** con la extensión girando (pid 4029; `kd-e.*`, `kdan.py`): el hilo principal ocupa el 98,7 % de
un núcleo, **99,0 % en los A53**, 1,0 % en los A73, 136 migraciones en 168 tramos. En el mismo intervalo `GCWidgets`
(widgets de Game Center), también de QoS por defecto, ocupa el 51 % de un núcleo, el 98,3 % en los A53.

Contexto (16 §1 punto 3, §3.3): `sweetsched=15` manda a los A53 los hilos de prioridad 21-31 (QoS por defecto), y un
A73 rinde ~2,5 veces un A53 en este teléfono (16 §3.5). El lote de 25-30 s en un A53 serían ~10-12 s en un A73, por
debajo del watchdog de ~15 s [H: estimación, sin medir]. Que iOS en el A11 ejecute la QoS por defecto en los núcleos
de rendimiento no está verificado aquí.

### 3.4 Por qué parece permanente

**[O]** Respawns de backboardd en los logs de este informe: 12:36:07, 12:37:54, 12:38:41, 12:39:57, 12:43:36,
12:45:05, 12:46:20, 12:47:37 y 12:51:25. El anterior sale con SIGTERM («termination reported by launchd (2, 15,
15)»), y a las 12:47:37 corre `/var/root/ab-phone.sh` de otro ensayo, que hace `killall backboardd`. Al arrancar,
backboardd pide a RunningBoard terminar todos los procesos gestionados («clearing the board for
/usr/libexec/backboardd respawn»): mueren las extensiones, SpringBoard rearranca, chronod las relanza y cada una
vuelve a gastar ~45-50 s. Con un respawn cada 1-1,5 minutos la extensión no llega a quedar parada. Esto afecta a toda
medida de CPU o de temperatura tomada en el minuto siguiente a un `killall backboardd` (03 M5, 17 §4.2).

## 4. Tiempo: por qué no hay datos y por qué se recarga

**[O] El widget sí existe y se lanza.** `WeatherWidget.appex` está instalado (la lista de `appex-remove.txt` lo
incluye, pero en el teléfono está) y su intent se resuelve. chronod lo evalúa «LIVE» con la entrada en caché
(«Cache hit; entry count: 1; requiresReload: true»): la vista «No weather data».

**[M] La petición del timeline** (`log-c`, `log-d`, `log-f`):

```
WeatherWidget: Location Permissions - denied / No authorization - returning default location
WeatherWidget: Weather data NOT found in cache ... falling back to server / Fetching from WDS
WeatherWidget: Setting timeout time interval for request <private> to 8.000000
WeatherWidget: Generate new JWT token.
WeatherWidget: Starting to generate JWT token request. bundleIdentifier=com.apple.weather.widget
   (bolsa de AMS cargada con éxito, HTTP 200)
WeatherWidget: AMSMescalFairPlay: [...] Init failed: <private>                                   (log-f, 12:51:11)
WeatherWidget: Error while creating local signature. ... error=Error Domain=AMSErrorDomain Code=12 "Mescal Failed"
             UserInfo={..., NSLocalizedFailureReason=Failed to fetch hardware info}
chronod: [weather.widget-...] Session operation: `getTimelines(1)` ... watchdog fired. Cancelling session.
```

- El error de Mescal aparece en 1 de 5 intentos; en los otros 4 (`log-c`, `log-d`) el log del widget se corta tras
  «Starting to generate JWT token request», sin el siguiente paso («Make new JWT token request»), sin error y sin
  ninguna petición a WDS. En ningún intento aparece «Received new JWT token».
- `getTimelines` se corta a los 29-30 s (12:43:37→12:44:07, 12:44:07→12:44:37, 12:50:54→12:51:23): el proveedor no
  completa el timeline tras el fallo. chronod reintenta (`stale-immediate`, `scheduledRetry(stale)`) y deja el
  siguiente intento para una hora después.
- **[O] Fuente primaria** (`cstr` sobre `WeatherDaemon.framework/WeatherDaemon` del teléfono): clases
  `WDSJWTAuthenticator`, `WDSJWTMescalSigner`, clave `httpHeaderMescalAuthenticationKey`, mensajes «Make new JWT token
  request», «Received new JWT token». La alternativa `WDSHMACJWTAuthenticatorService` existe, sin probar si está
  activa.
- **[O] FairPlay en el port:** `com.apple.fairplayd.H2` lanza `/redwood/bin/fpstub` (`userland/fpstub/fpstub.c`):
  fairplayd.H2 sale antes de registrar sus servicios y el stub contesta MIG_SERVER_DIED a todo. Durante una recarga
  (ensayo `f`), `fpstub` envía 3 mensajes más (134 → 137) y `adid` y `devicecheckd` no cambian (n=1; indicio, no
  prueba de qué llamada los provoca).
- Las pilas de `WeatherWidget`, `weatherd` y `adid` durante la espera están en reposo en su runloop (`pstack`,
  3 instantáneas): no hay un hilo bloqueado en una llamada síncrona; lo que falta es una respuesta asíncrona.

**Interpretación.** El widget no puede obtener datos de tiempo porque no consigue firmar con Mescal la petición del
token, y Mescal depende de FairPlay, que en este port no funciona. Que «Failed to fetch hardware info» venga de la
ausencia de fairplayd o de un identificador del dispositivo que FairPlay no encuentra es [H]. La localización
denegada no es la causa: sin ella el widget usa la ciudad por defecto. Sus placeholders (18 combinaciones, ~14 s) también
superan una vez el watchdog de `getPlaceholders` (`log-f`, 12:50:54→12:51:08).

**Parpadeo [H, sin captura].** Cada recarga y cada respawn hacen que SpringBoard pase el widget a «Content state did
change to preparing» y cambie entre la vista de snapshot y la viva (`Requested mode changed to live` / `static`), con
el mismo contenido «No weather data». Con recargas cada ~30 s durante los reintentos y un respawn cada 1-1,5 min es la
explicación más probable; falta una captura (`fbshot`) sincronizada con el log.

## 5. Otros informes de widgets

`com.apple.mobilenotes.WidgetExtension-2026-11-13-123848.ips`: SIGKILL de RunningBoard con código `0xdead10cc`
(3735883980): un proceso suspendido mientras tenía un archivo o una base SQLite bloqueados. Es uno solo (n=1, 13 nov),
a los 6 min del arranque; no se repite en los logs de hoy.

## 6. Arreglos propuestos

1. **Reponer `IntentsExtension.appex` de CalendarWidget** (causa de la pantalla en blanco). Es lo que iOS espera y el
   port quita:
   - Sacar `/System/Library/PrivateFrameworks/CalendarWidget.framework/PlugIns/IntentsExtension.appex` de
     `installer/recipes/appex-remove.txt` y de la lista `EXTENSIONS` de `tools/sapphire-clean-base.sh`.
   - En el teléfono instalado, el `.appex` no está en ningún sitio (ni en `/private/var/mobile/disabled-extensions`,
     que no existe): hay que extraerlo del IPSW 20H392 leyendo por rangos (`tools/remotezip.py`; el método de
     `research/metal/ios-graficos/binarios-ios-20H392.md` §1), copiarlo con su firma y dueño `root:wheel`, y que
     LaunchServices lo registre (re-escaneo de lsd; 0156 en NOTES.md explica cuándo hace falta reconstruir la base).
   - Verificación: tras un reinicio de chronod, SpringBoard ya no registra «No intent definitions found in extensions»
     para `EKUICalendarsIntent`, la extensión no registra «No intent in timeline» y el timeline de
     `CalendarUpNextWidget` termina con «succeeded with N entries»; captura del home. Vigilar además que la extensión de
     intents no entre en bucle (la razón, sin medir, por la que se quitó).
   Ningún paso es un workaround; ninguno toca el kernel. No se aplica desde aquí: escribe en `/System` y el registro
   en LaunchServices puede requerir reiniciar SpringBoard.
2. **Que el trabajo de QoS por defecto de las extensiones quepa en los plazos de chronod.** El A/B que lo decide, n≥3
   por condición, sin `killall backboardd` durante la medida: con `kern.sweet_sched=15` y `=13` (16 §3.3: 13 devuelve
   la QoS por defecto a los A73 sin diferencia medible en fps), reiniciar chronod y medir con el log a nivel por
   defecto la duración del lote de placeholders frente al watchdog de 15 s, las sesiones `getPlaceholders` hasta
   «result» y la CPU total por lanzamiento. Si con 13 las sesiones terminan, la política de `sweetsched` debe dejar en
   los A73 la QoS por defecto de los procesos de interfaz y extensiones. Es un cambio de sysctl: lo decide el
   coordinador.
3. **Medidas de CPU y temperatura:** no atribuir al reposo los ~45-50 s de CPU por extensión de widget que siguen a
   cada `killall backboardd`. Medir en reposo al menos 90 s después del último respawn o reiniciar chronod antes y
   esperar a que las extensiones queden paradas.
4. **Tiempo:** sin FairPlay no hay token para WDS; el arreglo de raíz es saber por qué fairplayd.H2 sale antes de
   registrar sus servicios (`userland/fpstub/fpstub.c`), una investigación aparte. Ni la localización ni la red son la
   causa.

## 7. Abierto

- Probar el arreglo 1 en el teléfono (requiere sacar el `.appex` del IPSW).
- Medir el lote de placeholders en los A73 (arreglo 2); con eso queda demostrado o descartado que el giro sea efecto
  del reparto de `sweetsched=15`.
- Saber qué llamada concreta de FairPlay falla en «Failed to fetch hardware info» y por qué en 4 de 5 intentos el log
  se corta sin error (¿la primera inicialización de Mescal espera algo que nunca llega?).
- Captura del parpadeo del widget de Tiempo sincronizada con el log de SpringBoard.
