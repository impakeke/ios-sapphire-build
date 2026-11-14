# 23 — GPU para todos los procesos: cómo lo hace iOS, qué espera su userland y diseño para el port

Informe fechado (2026-11-14). Pregunta: en iOS las apps, sus extensiones y los demonios que dibujan tienen
dispositivo Metal; en el port solo backboardd lo recibe. ¿Cómo reparte y aísla la GPU iOS 16 entre procesos, qué espera
el userland de iOS del sistema (más allá de cómo lo implemente Apple) y cómo se construye eso en `SapphireGPU` y en el
driver Metal del port, sobre un Adreno 610 sin GMU? Es un estudio con diseño; no toca el kernel ni el driver.

Convención de evidencia: **[O]** observado en un binario de Apple (dirección o símbolo de 20H392), en código
(archivo:línea) o en un fichero; **[M]** medido en el teléfono (fichero crudo citado); **[D]** documentado por Apple
(URL en §7); **[R]** tercero fiable (URL o commit en §7); **[H]** hipótesis. Lo que no se ha podido comprobar se dice.

Material de trabajo, fuera de git: `~/sapphire-angel/research/metal/multiproceso/` (kernelcache y cryptex de 20H392,
informes de trabajo `A`-`D`, scripts, lecturas del teléfono en `telefono/`).

## Resultado en breve

1. **Hoy la GPU del port no aísla nada, y eso pesa más que la puerta del driver** (§1.2): un banco del SMMU, una tabla,
   sin `CP_PROTECT`, y las tablas de páginas, el ring y las fences dentro de una ventana de identidad que cualquier IB
   puede escribir. Quien abre la GPU puede alcanzar toda la memoria física [H, de lo observado]. Además el driver se
   configura para todos los procesos desde `/var/tmp/metal.args`, guarda código de GPU en una caché que escribe
   cualquier proceso `mobile`, y su bundle es `0777` (§1.3).
2. **En iOS cada proceso tiene su GPU lógica** (§2.1-§2.4): una conexión propia, un `IOGPUTask`, un espacio de
   direcciones de GPU por contexto que construye el kernel y hace cumplir la MMU de la GPU, nombres de recursos por
   conexión e IOSurfaces que solo se comparten por puerto (la búsqueda por ID global está desactivada en producción).
   El kernel no interpreta el trabajo de la GPU: la frontera es la MMU.
3. **Quién puede usar la GPU en cada momento lo decide RunningBoard** (§2.5), con concesiones por estado del proceso
   escritas en el sistema (`LifecyclePolicy/DomainAttributes`): app con foco, visible, en segundo plano activo, póster
   mientras pinta; los widgets nunca. Lo aplica con `setpriority(PRIO_DARWIN_GPU)` (`TF_GPU_DENIED` en XNU) y con un
   rol por pid en IOGPU; una cola sin prioridad de fondo ve fallar sus command buffers con `NotPermitted`. **En el
   teléfono runningboardd ya lo hace** (157 cambios en los logs del 14 nov) y el kernel del port no lo mira (§1.4).
4. **Fallos** (§2.6): el culpable recibe `Timeout`/`PageFault`, el trabajo ajeno perdido «Discarded (victim of GPU
   error/recovery)» (`Internal`), y al segundo fallo culpable la cola queda denegada para siempre (`AccessRevoked`),
   salvo con `graphics-restart-no-kill`, que solo tiene backboardd. El kernel no mata procesos. QuartzCore solo registra
   los errores de sus command buffers.
5. **Memoria y prioridad** (§2.5, §2.7): IOGPU carga cada recurso al ledger de gráficos de su tarea, que cuenta en el
   límite de jetsam; sacarlo o cargarlo a otro exige `memory.ownership_transfer`, comprobado por XNU. El servidor de
   ventanas pide la prioridad más alta (0); el tiempo real exige `agx.rt-priority-spi`.
6. **Caché y configuración son del proceso** (§2.9-§2.10): `Caches/<bundle>/com.apple.metal`, un `MTLCompilerService`
   por cliente (en el teléfono, uno en el dominio XPC de backboardd) y binarios del sistema precompilados de solo
   lectura; las opciones vienen del entorno del propio proceso.
7. **El userland espera** (§3): dispositivo en todo proceso que el sistema deja abrir la GPU, aislamiento, errores
   con su causa, `NotPermitted` en segundo plano, memoria en su footprint. Los procesos que hoy piden Metal en el
   teléfono (SpringBoard por la esfera de Siri, chronod, MapKit) son de los que iOS deja, y ningún framework del sistema
   depende solo de binarios de GPU de Apple: todos traen AIR, lo que deja sin base el motivo de la puerta.
8. **El Adreno 610 del teléfono puede hacerlo** (§4.1.2-§4.1.3; `D`): su microcódigo SQE (`016ee206`) cambia la tabla
   de páginas desde el ring con `CP_SMMU_TABLE_UPDATE` (dentro de un IB es un NOP), kgsl ya usa tablas por proceso en
   este mismo teléfono, `CP_PROTECT` con la tabla `a630` funciona en este SQE y los paquetes privilegiados se ignoran en
   los IB. Hay que dejar TTBR1 en una tabla válida, abrir la apertura del SMMU por SCM y programar `CP_PROTECT` antes.
9. **Diseño** (§4): en el kernel, tarea, cola y trabajo como objetos; una tabla por tarea con globales compartidos y
   privilegiados; `CP_PROTECT`; fences por cola; `TF_GPU_DENIED` y prioridades con los entitlements de iOS; un
   planificador sin expulsión que da paso al servidor de ventanas; recuperación con culpable que reejecuta a los
   inocentes y castiga con las reglas de iOS; memoria en el ledger de la tarea y reparto del pool. En el driver,
   dispositivo para todos, errores con la tabla de IOGPU, caché por proceso con semilla del sistema y configuración sin
   ficheros públicos. Para backboardd no cambia nada visible.
10. **Orden** (§4.4): medir; política sin aislamiento; tablas por tarea (los ensayos E0-E2 deciden la viabilidad en
    arranques de prueba); protección; fallos; planificación; y solo entonces abrir el driver a todos.

## 1. Punto de partida en el port

### 1.1 Quién pide Metal hoy y qué recibe

- **[M] Procesos con el plug-in cargado** (`multiproceso/tools/mtlusers`, recorre las regiones de cada proceso con
  `proc_pidinfo(PROC_PIDREGIONPATHINFO)` sin tocar las tareas; Metal carga el bundle del acelerador al enumerar
  dispositivos, así que tenerlo mapeado significa haber llamado a `MTLCreateSystemDefaultDevice`): backboardd,
  SpringBoard, chronod y `com.apple.MapKit.SnapshotService`, en tres lecturas (13:56, 13:58 y 14:07 del 14 nov, la
  última con backboardd y SpringBoard relanzados; `telefono/mtlusers-*.txt`). Solo backboardd recibe dispositivo; a
  los otros tres el plug-in les devuelve nil. En la tercera lectura hay además un `MTLCompilerService` de Apple
  (§2.9).
- **[M]** En el log unificado del 14 nov (`research/widgets/log-*`): `SpringBoard: -[SUICOrbView
  _commonInitWithFrame:] Failed to get Metal device for GPU rendering` (6 veces): la esfera de Siri de SiriUICore pide
  Metal dentro de SpringBoard, registra el fallo y sigue.
- **[M] 03 M13:** con la puerta abierta (`metal_all=1`) `mtlprobe` recibe el dispositivo y SpringBoard pasa a ser
  cliente de `SapphireGPU`; `CalendarWidgetExtension` no lo es ni así.
- **[O] La puerta** está en el plug-in, `-[HakiosMetalDevice initWithAcceleratorPort:]`
  (`userland/src/HakiosMetalCA.m:3181-3198` en el árbol `rebuild/hakios-upstream`, commit `4cf8232`, el `merge-5`
  instalado): si el nombre del proceso no es `backboardd` y no está `metal_all=1`, devuelve nil. Su comentario da como
  motivo que los demás clientes «find pipeline libraries made for Apple's GPUs with no default.metallib beside them
  and abort» [H heredado; 19 §2.2 lo desmiente para QuartzCore, §3 de este informe para el resto].

### 1.2 El kernel: un solo dominio para todos

Código del árbol con la serie hasta 0353 (`~/sapphire-angel/research/metal/display/work/check-0353`,
`iokit/Kernel/arm/SapphireGpu.cpp`, sha256 `05fa4982…`; líneas `G`).

| Pieza | Cómo está [O] | Consecuencia con varios procesos |
|---|---|---|
| Espacio de direcciones | Un banco de contexto (CB0), un TTBR0 con ASID 0, TTBR1 a 0, SMR0 con SID 0 y máscara 1 (G1958-1974). El pool entero de 1 GB y el framebuffer de la consola están mapeados **en identidad** con bloques de 2 MB (G1947-1951); los buffers de cliente van además en 0x6000_0000-0xE000_0000 (G2982-2983) | Cualquier IB de cualquier proceso alcanza por la ventana de identidad todo buffer de todo proceso, el ring y las fences |
| Envío | Se valida la entrada de comando (tipo, que el buffer sea del cliente, alineación y límites) y se emite `CP_INDIRECT_BUFFER` a la VA del usuario; el contenido no se mira (G6418-6436) | Un IB puede escribir registros y memoria de GPU a voluntad |
| Protección de registros | Ninguna línea del archivo programa `CP_PROTECT`; la cabecera del cliente lo dice: «one address space for all clients, no register protection» (G4166-4189) | Un IB puede reprogramar el SMMU, el CP o el RBBM |
| Colas y fences | Un ring, un candado (`service_lock`), una secuencia `msm_seq` para todos (G2379, G6440-6445); `SUBMITQUEUE_NEW` devuelve un número y descarta la prioridad (G6606-6608); `PRIORITIES` = 1 (G6497) | Sin prioridad del servidor de ventanas ni reparto; cualquier cliente puede esperar la fence de otro |
| Fallos | `msm_hung` (G5548-5577): si alguien espera 2 s o el ring está lleno 2 s, reinicio global y las fences saltan al último número (todo lo pendiente de todos se da por hecho); `gpu_faults` es un contador global (G6498, `GET_PARAM` FAULTS) | Sin culpable: los inocentes pierden su trabajo y lo ven como completado; el culpable no recibe error |
| Superficies | `SapphireGPUClient::surface` importa cualquier IOSurface por su ID global sin comprobar nada (G6263-6325); `IOSurfaceRootUserClient` busca por ID para cualquier tarea y acepta e ignora la propiedad (`SweetSurface.cpp:1479-1488`, `1526`) | Cualquier proceso lee y escribe con la GPU las superficies de otro, incluida la pantalla |
| Memoria | BOs en un pool físico fuera de la VM de XNU (09 §4.1); sin cuenta por tarea ni límite | Jetsam no ve la memoria de GPU de nadie |
| Acceso | `SapphireGPUClient::initWithTask` no comprueba nada (G5761-5797) | Cualquier proceso abre la GPU |
| Fondo | Nada consulta `task_is_gpu_denied` | Una app en segundo plano dibuja igual |
| Memoria del kernel | Ring, microcódigo, fences y **las propias tablas de páginas** de la GPU están en el bloque de identidad de 2 MB de `0xE1000000`, mapeado de lectura y escritura sin privilegio (`PTE_RW_NC`, G1747; G1947; `D` §2.3, §3) | Un IB que escriba ahí cambia la traducción de toda la GPU: quien abre la GPU puede leer y escribir toda la memoria física [H, consecuencia directa de lo observado] |

Por lo último, abrir hoy la GPU a otro proceso (`metal_all=1`) equivale a darle acceso a toda la memoria: ningún paso
de §4 que dé Metal a más procesos puede ir antes de las tablas por tarea y de `CP_PROTECT`.

### 1.3 El driver: configuración y caché compartidas

- **[O]** Todo proceso con el plug-in lee `kern.bootargs` y, detrás, `/var/tmp/metal.args`
  (`HakiosMetalCA.m:121-158`, `hm_bootargs` en 128-158); el disparador de trazas es `/var/tmp/metal.trace` y
  `metal_trace_dir=DIR` elige dónde se escriben (`HakiosMetalCA.m:1433-1475`). **[M]** `/private/var/tmp` es `1777`.
- **[O]** La caché de etapas compiladas es `/private/var/db/hakios-metal-cache`, creada con `mkdir(…, 01777)`
  (`HakiosMetalCA.m:3356-3366`; la ruta, en 607); cada fichero lleva el `CompiledStage` tal como está en memoria más el código de GPU,
  con un nombre que es un hash de entradas conocidas (bitcode, constantes, build) (`hakios-metal/src/compiler.cpp:1109-1200`).
  **[M]** En el teléfono el directorio es `0755 mobile:mobile` con 1319 entradas: lo escribe cualquier proceso que corra
  como `mobile` (todas las apps, SpringBoard, backboardd).
- **[M]** `/System/Library/Extensions/HakiosMetal.bundle` es `drwxrwxrwx root wheel` (lectura del 14 nov, 13:57), y el
  kernel del port no exige firmas (`xnu/patches/0156-sapphire-amfi.patch`): cualquier proceso puede cambiar el driver que
  carga el servidor de ventanas.
- **[O]** El port no tiene sandbox: la política «Sandbox» es un sustituto que permite todo (`0050`, `0245`); los
  entitlements sí se leen del blob XML de la firma (`0035`, `SweetEntitlements.cpp`).

### 1.4 Lo que iOS ya hace en el teléfono y el kernel no escucha

**[M]** En los logs del 14 nov (`research/widgets/log-*`, ~824 000 líneas; `multiproceso/scripts/rb_gpu.py`)
runningboardd registra 157 `Set Darwin GPU to "allow"/"deny"` y 156 `setGPURole:pid: failed due to nil IOGPU device ref`:

| Proceso | allow | deny |
|---|---|---|
| `CollectionsPoster` (extensión de póster, servicio XPC de SpringBoard) | 62 | 35 |
| `PosterBoard` | 7 | 11 |
| `CalendarWidgetExtension`, `weather.widget`, `FitnessWidget`, `LockScreenPeopleWidget`, widgets de Game Center | 0 | 4-7 cada uno |
| `AccessibilityUIServer` | 0 | 4 |
| `GradientPoster`, `CollectionsPoster` de PosterBoard, `ExtragalacticPoster` | 0 | 1-2 |

Con un aserto de dominio `com.apple.posterkit.provider:Rendering-Entitled`, la extensión de póster pasa a «allow»
mientras pinta. Los widgets solo reciben «deny». chronod y SpringBoard aparecen como «not GPU managed». Qué hace
RunningBoard con eso, en §2.5.

## 2. Cómo lo hace iOS 16

Fuentes: kernelcache de 20H392 para iPhone X (`kernelcache.release.iphone10b`, kexts `com.apple.iokit.IOGPUFamily`
65.60.1 y `com.apple.AGXG10P` 227.6.5; direcciones `0xfffffff0…`; informe de trabajo `multiproceso/A-kernelcache-ios.md`),
la dyld shared cache del cryptex SystemOS de 20H392 (direcciones `0x1…`; `multiproceso/B1-…`, `B2-…`), el dmg raíz,
el XNU abierto del port, y Asahi Linux como única descripción pública detallada de una GPU de Apple
(`multiproceso/C-fuentes-externas.md`). Asahi documenta G13/G14 (M1/M2), no el A11: lo que se extrapola va como [H].

### 2.1 Qué abre un proceso al crear un `MTLDevice`

- **[O] Una conexión por dispositivo.** `IOGPUDeviceCreateWithAPIProperty` (IOGPU 0x1ece1ce38) hace
  `IOServiceOpen(acelerador, mach_task_self(), 1 | (opciones << 16))` (las opciones solo las fuerza una herramienta
  de depuración; en un proceso normal el tipo es 1), manda el nombre del API («Metal», 16 bytes, selector 6) y lee la
  memoria compartida del dispositivo (salida de 0x218 bytes, selector 2). En el kernel la conexión es un
  `IOGPUDeviceUserClient` (en el A11, `AGXDeviceUserClient`; vtables 0xfffffff006fc6a18 y 0xfffffff006fcf600) con
  despacho clásico por tabla: 50 selectores, entre ellos 7 `s_new_command_queue`, 8 `s_delete_command_queue`, 9
  `s_new_resource`, 26 `s_submit_command_buffers`, 29-32 eventos de evaluación tardía y 40-49 las colas de E/S de
  Metal (tabla 0xfffffff006fc6a90; comprobada con `A/disp.py`: el selector 2 sale con 536 bytes y el 6 entra con 16).
  Un byte de la conexión, que depende del API, elige esa tabla u otra (0xfffffff006fc6f40) que anula los
  selectores 28-49 (`IOGPUDeviceUserClient::externalMethod`, 0xfffffff006b2eeb4).
- **[O] Abrir no pide entitlement.** `IOGPUDeviceUserClient::deviceUserClientStart` (0xfffffff006b2ec80) solo lee
  `com.apple.private.gpu-restricted` a una bandera y publica la propiedad `AppUsage`. Quién puede abrir qué clase lo
  decide el sandbox (§2.8). El cliente de información de memoria de todos los procesos (`IOGPUMemoryInfoUserClient`)
  sí exige `com.apple.private.ioaccelmemoryinfo` (0xfffffff006b4d580).
- **[O] Estado por tarea:** `IOGPUTask` (464 bytes), en una lista del acelerador (`fGPUTaskList`); titular de los
  mapeos de GPU de la tarea («active mapping list not empty» al liberarlo). [H] Uno por tarea, compartido por las
  conexiones de la misma tarea.
- **[O] Todo va por esa conexión** (IOGPU.framework; tabla de selectores en `B1` §3.2): colas (selector 7, con la ruta
  del ejecutable, la QoS y un flag; devuelve el id), cada una con su cola de notificación (`IODataQueue` de 256
  entradas de 0x20 B mapeada por el kernel, selector 0x0f, y un puerto de notificación); recursos (selector 9: el kernel
  devuelve la dirección de GPU, la de CPU ya mapeada en la tarea, el id y el tamaño residente); memorias compartidas
  para comandos del kernel, lista de segmentos, canal lateral y depuración (selector 0x0d); envío por lotes (selector
  0x1a: id de cola y n registros que nombran esas memorias por id y llevan los bloques «planificado» y «completado»
  que el kernel devuelve en las notificaciones). No hay conexión por cola ni `IOConnectMapMemory`. Cada command
  buffer lleva su lista de recursos (ids de 24 bits, tamaño y flags de uso). Caben 128 command buffers en vuelo por
  cola; *scheduled* y *completed* llegan como notificaciones separadas.
- **[O] Un dispositivo por proceso:** `MTLCreateSystemDefaultDevice` (Metal 0x181a37760) enumera una vez los servicios
  `IOAcceleratorES`, carga `/System/Library/Extensions/<MetalPluginName>.bundle`, crea la clase con
  `initWithAcceleratorPort:` y devuelve siempre el mismo objeto; si no hay servicio o el plug-in devuelve nil, devuelve
  nil sin mensaje. `_MTLAddDevice` aborta si el objeto no declara `MTLDevice` y `MTLDeviceSPI`. `MTLCopyAllDevices` no
  existe en el Metal de iOS 16.

### 2.2 Un espacio de direcciones de GPU por contexto

- **[O, A11]** El kernel construye las tablas de páginas de la GPU (`AGXGart`/`AGXGartG10`, `AGXMemoryMap::
  updateGPUPageTable` 0xfffffff0055547ea, `AGXGart::initSharedAllocator` 0xfffffff006b56560) con páginas de 16 KiB,
  y reparte la VA en zonas privadas del firmware y zonas compartidas driver-firmware con identificador de contexto
  («Firmware/Driver Shared (ctx ID inval)», «Cached Firmware Private»). Un recurso se mapea en la VA de **su** tarea
  (`IOGPUMemory::createGPUMappingInTaskAtAddressLengthAlignment(IOGPUTask*, …)`). Las violaciones las detecta la MMU
  de la GPU y las informa el firmware («protection violation: %016llx -> %016llx -> %016llx», «BIF%d page fault»,
  «Page Invalid», «Read-Only»), y los mapeos nuevos se notifican al firmware
  (`AGXArmFirmware::notifyNewMapping`, 0xfffffff005551882). [H] Una tabla por contexto y el firmware conmuta.
- **[R, G13/G14]** Asahi documenta el mismo modelo en las GPU de los M1/M2: el UAT (MMU de la GPU) tiene 64 ranuras
  de contexto, la 0 para el kernel y 63 de usuario; cada contexto lleva su TTB0 (mitad de usuario, «User VA space is
  unique per context») y comparte la TTB1 del kernel; el ASID es el índice de ranura, y un VM ocupa ranura solo
  mientras tiene trabajo en vuelo (AsahiLinux/linux `6ba0637`, `drivers/gpu/drm/asahi/mmu.rs:115-136, 1541-1597`;
  AsahiLinux/docs `agx.md:38`).
- **Contrato que se deriva:** el trabajo de GPU de un proceso no alcanza la memoria de otro; un acceso fuera de lo
  suyo es un fallo de página que se le atribuye a él (§2.6).

### 2.3 Recursos, nombres e IOSurface

- **[O]** `IOGPUResource` se crea por la conexión del dispositivo (`newResourceWithOptions`, `newResourceWithClientBuffer`,
  `newResourceWithParentResourceID`, `newResourceWithIOSurface`), con tipos `SysMemPrivate`, `SysMemShared`,
  `SysMemShared(IOSurface)` e `IOSurface`; la memoria de sistema puede ser memoria aportada por el cliente
  (`IOGPUSysMemory::withClientBuffer(…, task_t, …, mach_vm_address_t, len)`). Los identificadores de recursos y colas
  son índices en espacios de nombres de cada conexión (`IOGPUNamespace`, `fDeviceNamespace`, `fWorkQueueNamespace`),
  no globales; cada envío lleva su lista de recursos (`IOGPUSegmentResourceList`, `IOGPUResourceSet`).
- **[O] Una IOSurface entra en la GPU ya resuelta, no por número:** `IOGPUResource::newResourceWithIOSurface(IOGPU*,
  IOGPUDevice*, IOSurface*, …)` (0xfffffff006b36280) recibe el objeto. Y la búsqueda por ID global está
  **desactivada** en producción: `IOSurfaceRoot` (0xfffffff005a58cc0) solo la permite con el bit 2 del boot-arg
  `iosurface_debug`; sin él registra «IOSurface disallowing global lookups» (cadena en 0xfffffff004ed414f), y con él
  avisa «Security: Process %s (%d) relying on global (insecure) IOSurface lookups». Entre procesos una superficie se
  comparte por derecho de puerto (XPC, `IOSurfaceCreateMachPort`), que es una capacidad: tenerla es poder usarla.
  Las superficies protegidas exigen `com.apple.private.IOSurface.protected-access`.

### 2.4 El kernel no interpreta el trabajo de la GPU

- **[O]** IOGPUFamily valida con detalle solo el canal lateral de «comandos del kernel» de cada command buffer
  (`IOGPUCommandQueue::processSegmentKernelCommands`, enum `eIOGPUKernelCommands`: `DebugLog`, `CollectTimeStamp`,
  `SignalSharedEvent`, `WaitSharedEvent`, `PurgeResources`, `SetProtectionOptions`; «Invalid resourceID»,
  «Invalid command_size»…). El contenido para la GPU lo codifica el driver de userland y el kernel lo pasa al firmware
  sin mirarlo (`AGXAcceleratorRing::submitEntry`, `AGXArmFirmware::kickFirmware`); los rangos de VA no se comprueban:
  los hace cumplir la MMU por contexto.
- **[R]** Asahi, por el mismo motivo: el usuario nunca escribe estructuras del firmware («they are not isolated between
  different processes using the GPU! So we can’t give apps direct access to them», Asahi Lina, *Tales of the M1 GPU*);
  el kernel las construye a partir de un búfer de comandos sin punteros de CPU y no valida shaders ni punteros dentro
  de la VA del usuario (`queue/render.rs:3-6, 641-721`). La frontera es la VA por contexto.
- En el Adreno la pieza equivalente a «lo que el usuario no debe tocar» son los registros de la GPU y el ring, que
  un IB puede escribir: de ahí `CP_PROTECT` en el diseño (§4.1.3).

### 2.5 Quién puede usar la GPU en cada momento: RunningBoard decide, el kernel aplica

**La política está en datos del sistema [O].** Las `DomainAttributes` de RunningBoard
(`/System/Library/LifecyclePolicy/DomainAttributes/*.plist` del dmg raíz de 20H392; tabla completa en
`multiproceso/rb-domains-gpu.txt`, `scripts/rb_domains_gpu.py`) dan a cada aserto un `RBSGPUAccessGrant` con un rol.
Los roles de `RBSGPURole` son 0 «(unknown)», 1 «None», 2 «Background», 3 «UserInteractive», 4
«UserInteractiveFocal» (`NSStringFromRBSGPURole`, RunningBoardServices 0x19379d3d8, y sus cinco cadenas); el
`+[RBSGPUAccessGrant grant]` sin rol vale 2 (0x19379ea5c).

| Aserto (dominio) | Rol de GPU | Rol de CPU | Banda de jetsam |
|---|---|---|---|
| App en primer plano con foco (`frontboard` `Workspace-ForegroundFocal`), `SystemShell`, `Bootstrap-Foreground` | UserInteractiveFocal | UserInteractiveFocal | 100 |
| App visible sin foco (`Workspace-ForegroundActive`, `-ForegroundUtility`) | UserInteractive | UserInteractiveNonFocal | 100 |
| App activa en segundo plano, instantánea de escena, terminación ordenada (`Workspace-BackgroundActive`, `SceneSnapshotAction`, `GracefulTermination`) | Background | NonUserInteractive | 40 |
| Extensión de póster mientras pinta (`PosterKit` `FinishRender`, restringido al punto de extensión `com.apple.posterkit.provider`) | UserInteractive | UserInteractiveNonFocal | 40 |
| WebKit en primer plano (`webkit` `Foreground`) / reproducción de medios | UserInteractive / Background | | 100 |
| Ejecución de una extensión de widget (`chronod` `WidgetExtensionRun`) | **ninguno** (con `RBSCPUMaximumUsageLimitation`) | NonUserInteractive | |

**Cómo se aplica [O].** `-[RBProcess _lock_applyGPU]` (RunningBoard 0x1f5e9ff90), solo para procesos «GPU
managed» (si no, registra «Ignoring GPU update because this process is not GPU managed»):

1. `setpriority(PRIO_DARWIN_GPU, pid, rol > None ? PRIO_DARWIN_GPU_ALLOW : PRIO_DARWIN_GPU_DENY)` y registra
   «%d Set Darwin GPU to "allow"/"deny"» (0x1f5ea0038-0x1f5ea0100);
2. `-[RBXNUWrapper setGPURole:forPid:]` (0x1f5ea1770) → `IOGPUDeviceSetAppGPURole(dispositivo, pid, r)` con
   r = 0 para Focal, 1 para UserInteractive y 2 para el resto. El dispositivo lo crea `-[RBXNUWrapper init]`
   (0x1f5ed6f34) con `IOServiceGetMatchingService(IOServiceMatching("IOGPU"))` + `IOGPUDeviceCreate`; sin un
   servicio de clase `IOGPU` registra «IOGPU not present» y cada cambio de rol falla.

En XNU (fuente abierta, árbol del port): `PRIO_DARWIN_GPU` llega a `set_gpudeny_proc` (`bsd/kern/kern_resource.c:477-490,
577-620`; exige que el que llama no sea el destino y pasa por `mac_proc_check_sched`), que pone o quita `TF_GPU_DENIED`
en la tarea (`osfmk/kern/task.c:7973-7991`). IOKit lo consulta en dos sitios: `IOUserClient::clientHasPrivilege(…,
kIOClientPrivilegeForeground)` devuelve `kIOReturnNotPrivileged` a una tarea denegada
(`iokit/Kernel/IOUserClient.cpp:1363-1381`), y todo método externo marcado `kIOUCForegroundOnly` devuelve
`kIOReturnNotPermitted` (`IOUserClient.cpp:6589-6592`, `6636-6639`).

**Prioridad por cola y trabajo en segundo plano [O].** Cada cola de comandos tiene una prioridad y una prioridad «de
fondo» (`-[IOGPUMetalCommandQueue _setGPUPriority:backgroundPriority:]`, IOGPU 0x1ece20eec → selector 0x1b): valores
0..5, el 3 solo es válido como prioridad de fondo, y una cola nueva tiene 1 y 3 (0x1ece15b50-0x1ece15b6c). En el
kernel, una función de la cola de IOGPUFamily (0xfffffff006b48f70) hace una llamada con la cadena «foreground»
(0xfffffff005547ccd, el `kIOClientPrivilegeForeground` de XNU) cuyo resultado compara con `kIOReturnNotPrivileged`,
que es lo que devuelve `clientHasPrivilege` a una tarea denegada; en ese caso toma la prioridad de fondo de la cola en
lugar de la normal; si esa prioridad de fondo es 3 guarda en la cola el valor 6, que es el código
`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted` de la tabla de §2.6 [H la correspondencia]. Es
decir: una app sin concesión ve fallar sus command buffers con `MTLCommandBufferErrorNotPermitted`, salvo en colas a
las que el proceso dio una prioridad de fondo, que siguen a esa prioridad. Si el envío mismo falla con
`kIOReturnNotPermitted` (métodos `kIOUCForegroundOnly`), IOGPU completa cada command buffer con el código 7
(0x1ece1836c-0x1ece18390), también `NotPermitted`.

**Lo que pide el servidor de ventanas [O].** `CA::OGL::new_metal_context` traduce su prioridad interna con la tabla de
QuartzCore 0x1885652b8 (1→2, 2→1, 3→4, 4→0): el contexto de la pantalla (`EAGLServer::renderer`,
`IOMFBDisplay::get_ctx`) pide **0**, el despachador asíncrono 1 y el renderizador acelerado de CoreGraphics 4; con un
flag fija además la prioridad de fondo a 2. AGXMetalA11 fuerza 0 cuando una variable interna pide «prioridad alta»
(`resolveAndUpdateQueuePriority:`, 0x209e55064): 0 es la más alta [H, fuerte]. En el kernel, la prioridad de tiempo
real exige `com.apple.private.agx.rt-priority-spi`; sin él se rebaja a alta y se registra «Process %s (%d) does not
have the entitlement to use MTLGPUPriorityRealTime, using MTLGPUPriorityHigh instead» (0xfffffff00554ac25). El
firmware del A11 planifica las colas con estados Idle/Ready/Blocked/Preempted (`IOGPUWorkQueueState`) y prioridad por
cola (`AGXWorkQueue::setPriority`).

Qué procesos son «GPU managed» lo dice su job de launchd [O, `ipsw-launchd.plist`]: PosterBoard y
AccessibilityUIServer llevan `RunningBoard = {Managed = true}` y `ProcessType = App`, igual que las apps y sus
extensiones; SpringBoard, backboardd y chronod no, y RunningBoard nunca les niega la GPU.

**En el teléfono [M]** (§1.4): runningboardd ya pone y quita `TF_GPU_DENIED` en pósters, widgets y
AccessibilityUIServer, y cada `setGPURole` falla por falta de servicio `IOGPU`. Los widgets solo reciben «deny»:
en iOS 16 una extensión de widget no tiene GPU, y lo que dibuja lo convierte en píxeles otro proceso.

### 2.6 Cuelgues y fallos: culpable, víctimas y castigo

**Lo que ve un proceso [O].** IOGPU traduce el estado de cada command buffer con
`-[NSError(IOGPUMetalErrors) initWithIOGPUError:]` (0x1ece2430c) y tres tablas indexadas por el código del kernel
(nombres 0x20d65fd30, descripciones 0x20d65fca0, código Metal 0x1ece365d8; `B1` §6.1):

| Código del kernel | Descripción (la que sale en el `NSError`) | `MTLCommandBufferError` |
|---|---|---|
| 2 Timeout / 3 Hang | Caused GPU Timeout Error / Caused GPU Hang Error | Timeout |
| 11 PageFault | Caused GPU Address Fault Error | PageFault |
| 16 ProtectionViolation | Protection Violation | 16 (fuera del enum público) |
| 5 InnocentVictim | Discarded (victim of GPU error/recovery) | Internal |
| 4 SubmissionsIgnored | Ignored (for causing prior/excessive GPU errors) | AccessRevoked |
| 6 BackgroundExecutionNotPermitted / 7 NotPermitted | Insufficient Permission (to submit GPU work from background) / Insufficient Permission | NotPermitted |
| 8 OutOfMemory / 9 InvalidResource | Insufficient Memory / Invalid Resource | OutOfMemory / InvalidResource |
| 12, 13 | límites de memoryless | Memoryless |
| 17 StackOverflow | … Stack Overflow Exception | StackOverflow |

Metal pone el estado `Error`, añade, si el command buffer lo pidió, la información por encoder
(`MTLCommandEncoderErrorState`: `Faulted` solo puede salir del driver, que lee lo que la GPU dejó en un buffer de
depuración por envío; `Affected`, `Completed` y `Pending` salen de marcas de progreso) y ejecuta los completed handlers
(`-[_MTLCommandBuffer didCompleteWithStartTime:endTime:error:]`, 0x181a212b4; `processEncoderInfos`, 0x181b2090c). El
userland no tiene estado de «dispositivo perdido»: que un proceso deje de poder enviar lo decide el kernel. El servidor
de ventanas se limita a registrar el error: el completed handler de `CA::OGL::MetalContext::prepare_new_command_buffer`
(QuartzCore 0x1882c83a0) lee `error` y escribe «MTLCommandBuffer %p, protection 0x%llx, label %s, error = %s» en el log,
sin reintentar ni abortar.

**Lo que hace el kernel [O, A11].** El firmware RTKit de la GPU detecta el cuelgue o el fallo e inicia la recuperación
(`AGXFirmware::processFirmwareInitiatedRecovery`; motivos de `AGXRestartReport`: «progress timeout», «firmware-detected
lockup», «firmware assert», «timestamp timeout», «blocked by IOFence»…), y el kernel rehace el estado
(`IOGPUWorkQueue::restart`, «Trying to restart GPU (%s)...», 0xfffffff005546b9b). El informe de reinicio lleva el
culpable (`guilty_dm`, `process_name`, `command_buffer_trace_id`, `restart_reason`). Al retirar el command buffer
culpable, `IOGPUCommandQueue::retireCommandBuffer` (0xfffffff006b4aa64) lleva la cuenta **por cola**: un command
buffer que termina en Timeout, Hang o PageFault (códigos 2, 3 y 11) suma un reinicio; al segundo, si la tarea no
tiene `com.apple.private.graphics-restart-no-kill` (accesor 0xfffffff006b40f94), la cola queda denegada para siempre
(«Deny submissions/ignore app[%s] with %d GPURestarts in %d submissions»; con el entitlement solo registra «Immunity
for…»), y desde entonces cada command buffer de esa cola termina con el código 4, `AccessRevoked` (0xfffffff006b48df8,
0xfffffff006b49108). 1001 command buffers buenos en una cola no denegada borran la cuenta («Clean slate for
app[%s]…»). El kernel **no mata** al culpable: ni IOGPUFamily ni AGXG10P importan primitivas de terminación
(`task_terminate`, `psignal`, `exit_with_reason`, jetsam); pese a su nombre, el entitlement evita la denegación de la
cola (`A` §6).

**[R] Asahi** (G13/G14) hace lo mismo con sus nombres: cada trabajo termina en `Timeout`, `Fault` o `Killed` («Work
failed due to an error caused by other concurrent GPU work»); al llegar un fallo con información de la MMU, el trabajo
cuyo contexto no es el del fallo pasa a `Killed`; si el firmware se cae, todo trabajo falla con `NoDevice` y la GPU no
vuelve sin reiniciar la máquina (`workqueue.rs:66-94, 217-222`; `gpu.rs:380-390, 1009-1045`).

**Contrato que se deriva:** el error va al command buffer culpable con su causa; el trabajo ajeno perdido en la
recuperación termina con error de víctima (`Internal`), no como completado; quien reincide deja de poder enviar
(`AccessRevoked`); el servidor de ventanas sobrevive a un command buffer con error.

### 2.7 Memoria de GPU: cuenta en el footprint de la tarea

En XNU [O]: cada tarea tiene ledgers `graphics_footprint` y `graphics_nofootprint` (y sus variantes comprimidas)
(`osfmk/kern/task.c:1143-1146`). Un driver asigna la memoria a una tarea con `IOMemoryDescriptor::setOwnership(tarea,
kIOMemoryLedgerTagGraphics, opciones)` (`iokit/IOKit/IOMemoryDescriptor.h:141, 366-376`;
`IOMemoryDescriptor.cpp:3725-3783`), que acaba en `vm_object_ownership_change` (`osfmk/vm/vm_object.c:8061`): la
memoria no volátil cuenta en `graphics_footprint` y en `phys_footprint` salvo con `kIOMemoryLedgerFlagNoFootprint`
(`vm_object.c:8022-8036`, `8350-8383`); la volátil (purgeable) no cuenta. `phys_footprint` es lo que mira jetsam: el
límite por proceso es un límite del ledger (`task_set_phys_footprint_limit_internal`, `task.c:6926-6990`;
`kern_memorystatus.c:560, 876-877`). Es decir, en iOS la memoria de GPU de una app cuenta contra su límite de
memoria, y un informe de fallo lleva `graphics_footprint` (`bsd/kern/kern_exit.c:748-755`).

**[O] Lo que hace IOGPUFamily** (`A` §7): la ruta por defecto de un recurso (`IOGPUSysMemory::withOptions`,
0xfffffff006b4e9d0) crea la memoria en la tarea cliente y la asigna con `setOwnership(md, tarea, GRAPHICS, 0)`: **cuenta
en `graphics_footprint` y por tanto contra el límite de jetsam de la app**; un recurso marcado volátil deja de contar.
Sacarlo del footprint (`kIOMemoryLedgerFlagNoFootprint`, bit de la petición en `IOGPUDevice::new_resource`,
0xfffffff006b420ac-e4) o cargarlo a otra tarea (selector 0x24, `IOGPUResourceSetOwnerIdentity`, con un token de
identidad de tarea) exige `com.apple.private.memory.ownership_transfer`, y no lo comprueba el kext sino XNU en
`mach_memory_entry_ownership` (`osfmk/vm/vm_user.c:3687-3734`). Es lo que usa el proceso GPU de WebKit para cargar a
cada WebContent sus superficies (`IOSurfaceSetOwnershipIdentity(…, kIOSurfaceMemoryLedgerTagGraphics, 0)`,
`Source/WebCore/platform/graphics/cocoa/IOSurface.mm:566-578`; `C` §3.5). El tiempo de GPU se factura a la coalición
de la tarea (`ml_gpu_stat_update` → `task_coalition_update_gpu_stats`, `osfmk/arm64/machine_routines.c:2403-2409`).
Límites propios del kext: memoria cableada (`wired_limit`, `wired_lwm_mb`), número de recursos (`rsrc_limit`) y un aviso
de fuga por proceso («PID %d likely leaking IOGPUResource (count=%d)»).

### 2.8 Entitlements y sandbox

**Quién abre la GPU lo decide el sandbox, no el kext** (§2.1). En iOS 16 los perfiles están compilados en el kext
`com.apple.security.sandbox` y no se pueden leer como texto; el kernelcache solo muestra las operaciones
`iokit-open*` y la colección de perfiles incorporados [O, `A` §8], y en el sistema de ficheros no hay ningún SBPL que
nombre clases de GPU [O, `B2` §4]. Lo que sí se ve:

- **[O, entitlements de 2784 binarios de 20H392, `B2` §3]** Las apps, sus extensiones, los widgets y casi todos los
  pósters no llevan ninguna clave de GPU: la GPU les llega del perfil de contenedor. Los demonios con perfil propio o con
  el genérico `temporary-sandbox` la reciben del perfil o de claves explícitas: `com.apple.security.iokit-user-client-class`
  (79 binarios incluyen `AGXDeviceUserClient`; SpringBoard lista 24 clases, entre ellas `IOGPUDeviceUserClient`,
  `IOMobileFramebufferUserClient` e `IOSurfaceRootUserClient`) o `com.apple.security.ts.opengl-or-metal` (21 binarios,
  entre ellos chronod, MapKit `SnapshotService`, AegirPoster, ExtragalacticPoster, InputUI e iconservicesagent: justo los
  que fuera del servidor de ventanas piden Metal en el teléfono, §1.1).
- **[R, WebKit `f1404ac4`, la etiqueta más cercana a la 615.8.1 de 20H392]** El perfil del proceso GPU de WebKit para
  iOS permite `iokit-open* (iokit-connection "IOGPU")`, `AGXDeviceUserClient`, `IOSurfaceRootUserClient`,
  `IOSurfaceAcceleratorClient`, el servicio `com.apple.MTLCompilerService`, `kern.bootsessionuuid` y las preferencias
  `com.apple.Metal` (`com.apple.WebKit.GPU.sb.in:214-236, 295-298`); el de WebContent deniega `IOMobileFramebufferUserClient`
  y deja la GPU solo con una extensión de sandbox que la UI emite cuando alguna función no está en el proceso GPU
  (`com.apple.WebKit.WebContent.sb.in:38-40, 159-168`; `C` §4.1).
- **[R?]** El perfil de contenedor decompilado más cercano (iOS 17 beta, SandBlaster, con la advertencia de su autor)
  permite a toda app `AGXDevice`, `AGXSharedUserClient`, `IOGPUDeviceUserClient`, `IOSurfaceRootUserClient` e incluso
  `IOMobileFramebufferUserClient` (`C` §4.2).

| Entitlement | Quién lo lleva en 20H392 [O, `B2`] | Qué hace en el kernel [O, `A`] |
|---|---|---|
| `com.apple.private.graphics-restart-no-kill` | solo backboardd | evita que la cola se deniegue tras dos fallos culpables (§2.6) |
| `com.apple.private.allow-explicit-graphics-priority` | 17: backboardd, mediaserverd, Cámara, Fotos, Mapas, WebKit GPU y WebContent… | (la cadena está en el kernelcache; su uso exacto no está localizado) |
| `com.apple.private.agx.rt-priority-spi` | ninguno | sin él, `RealTime` se rebaja a `High` (§2.5) |
| `com.apple.private.gpu-restricted` | WebKit GPU y los tres WebContent | `deviceUserClientStart` lo anota en la conexión y en `AppUsage` |
| `com.apple.private.memory.ownership_transfer` | WebKit GPU | XNU exige esto para cargar memoria a otra tarea o fuera del footprint (§2.7) |
| `com.apple.private.ioaccelmemoryinfo` | 4 herramientas de memoria y energía | abrir `IOGPUMemoryInfoUserClient` |
| `com.apple.private.IOSurface.protected-access` | backboardd | superficies protegidas |
| `com.apple.private.iomfb.set-block` (+ perfil de cliente) | backboardd, thermalmonitord y dos demonios de IOMFB | operaciones de bloque del framebuffer |
| `com.apple.agx.gpurole`, `com.apple.private.kernel.setpriority-darwin-role` | runningboardd | el segundo, para fijar el rol Darwin; la cadena del primero no aparece en el kernelcache [O] |

En el port el sandbox es un sustituto que lo permite todo (§1.3): un `IOServiceOpen` de cualquier proceso llega a
cualquier servicio. Lo que en iOS hace el perfil, en el port solo lo puede hacer el propio servicio.

### 2.9 Caché de shaders: por proceso, con binarios del sistema de solo lectura

- **[O] Dónde** (`getCacheMainFolder`, Metal 0x181a63fbc): `NSCachesDirectory` del usuario + `/<CFBundleIdentifier>`
  (si el proceso tiene bundle) + `/com.apple.metal`, con `functions.data`/`.list` y
  `libraryCache/libraries.data`/`.list` (libCoreFSCache, cerrojo `flock` sobre el `.list`, tamaño máximo 256 MiB por
  defecto, invalidación por sesión de arranque salvo `FS_CACHE_REUSE_ON_REBOOT`). En una app eso cae en el `Library/Caches`
  de su contenedor [H, comportamiento de CoreFoundation]. `MTLSetShaderCachePath` y
  `MTLMakeShaderCacheWritableByAllUsers` existen, solo valen antes del primer uso y ninguna imagen de la caché las llama.
- **[O] Lo del sistema viene hecho y es de solo lectura:** una pipeline library es un directorio con
  `pipelines.desc`, `pipelines.<target>` y `functions` (`MTLPipelineLibraryBuilder::newLibraryWithFile`, 0x181a3f31c),
  abiertos con `readOnly:YES`; la de QuartzCore trae `pipelines.g10p` (1043 entradas) y `functions` (451), con una
  cabecera que exige la versión exacta del compilador del dispositivo.
- **[O] Quién compila:** el servicio XPC `com.apple.MTLCompilerService` del propio Metal.framework
  (`XPCCompilerConnection::setupConnection`, 0x181a41908). **[M]** En el teléfono hay uno en el dominio XPC de
  backboardd (`launchctl procinfo`: `domain = pid/1235 [backboardd]`, 14 nov, 14:08): una instancia por proceso cliente.
- **Por qué por proceso [H]:** el compilador procesa shaders arbitrarios del cliente; en un proceso aparte, con la
  identidad y el sandbox del cliente, un fallo o un exploit del compilador no compromete a nadie más, y una caché en el
  contenedor de cada app no deja que una app ponga código de GPU en otra.

### 2.10 Configuración y depuración: del propio proceso

**[O]** Metal, IOGPU y AGX leen su configuración del **entorno del proceso** (`getenv` y `MTLGetEnvDefault`,
0x181a41664) y de las preferencias `com.apple.Metal` del propio proceso: `MTL_DEBUG_LAYER`, `MTL_SHADER_VALIDATION`,
`METAL_DEVICE_WRAPPER_TYPE`, modos de error, captura y HUD (la captura por `Info.plist` solo con recibo de TestFlight o
build interno), tamaño de caché, compilador en proceso (`MTL_MONOLITHIC_COMPILER`)…; los volcados de pipelines y de
estadísticas del compilador solo con `os_variant_has_internal_diagnostics("com.apple.Metal")`, y `AGX_FORCE_GPU_PRIORITY`
y las `AGC_*` solo en instalaciones internas (tabla completa en `B1` §8). **[M]** SpringBoard consulta en el teléfono
`METAL_DEVICE_WRAPPER_TYPE`, `UseMetalTelemetry` (`com.apple.Metal`) y `MetalForceHudEnabled`/`MetalForceCaptureEnabled`
(`com.apple.springboard`) (`research/widgets/log-*`). Nada de eso vale para otro proceso: no hay un fichero del sistema
que cambie el driver de todos.

### 2.11 Qué es del A11 y qué es contrato

| Pertenece a | Qué |
|---|---|
| **Contrato de Metal** (público o común a toda GPU con iOS 16) | un dispositivo por proceso; errores de `MTLCommandBufferErrorDomain` y su significado; `encoderExecutionStatus`; `NotPermitted` en segundo plano; memoria en el footprint; `setPurgeableState`; caché por app; variables `MTL_*` por proceso; compartir por IOSurface/XPC |
| **Sistema iOS** (RunningBoard, XNU, IOGPUFamily, independientes de la GPU) | concesiones de GPU por estado del proceso y `PRIO_DARWIN_GPU`; rol de GPU por pid; prioridad y prioridad de fondo por cola (0..5); tabla de 18 códigos de IOGPU; cuenta de reinicios por cola (2 → denegada; 1001 → borrón); entitlements de prioridad, de inmunidad y de transferencia de memoria; IOSurface sin búsqueda global por ID |
| **Propio del A11 / AGX G10** | firmware RTKit que planifica, conmuta contextos y detecta cuelgues; tablas GART de 16 KiB con zonas privadas del firmware; canales TA/3D/CL; motivos de `AGXRestartReport`; `pipelines.g10p` y el compilador de AGX; selectores 0x100-0x10c; buffer de depuración que da `Faulted` |

El port tiene que cumplir las dos primeras filas; la tercera es una forma de hacerlo que el Adreno no tiene y que
§4 sustituye por el kernel.

## 3. Qué espera el userland de iOS

### 3.1 El contrato, independiente de cómo lo implemente Apple

Lo que un proceso de iOS 16 puede dar por hecho, con la fuente que lo fija:

1. **Hay dispositivo en todo proceso que el sistema deja abrir la GPU.** `MTLCreateSystemDefaultDevice` devuelve el
   mismo objeto en todas las llamadas del proceso (§2.1). Las apps y sus extensiones la abren por el perfil de
   contenedor; los demonios, por su perfil o por sus entitlements (§2.8). Nil queda para el proceso cuyo sandbox no le
   deja abrirla [H, de §2.8], y Apple lo trata como posible («Failed to get the system's default Metal device», [D]).
   Que un proceso no pueda usarla *ahora* no se expresa con nil sino con errores al enviar (punto 3). **[M+O]** Los
   procesos que hoy piden dispositivo en el teléfono (SpringBoard, chronod, MapKit `SnapshotService`, §1.1) son de los
   que iOS deja abrir la GPU: SpringBoard por `iokit-user-client-class`, los otros dos por `ts.opengl-or-metal`.
2. **El trabajo de un proceso no ve ni toca el de otro** (§2.2, §2.4): un acceso fuera de su memoria es un error de su
   command buffer (`PageFault`), no daño ajeno; los recursos solo se comparten por capacidades (puertos de IOSurface,
   `MTLSharedEvent`/`MTLSharedTextureHandle` por XPC, [D]).
3. **El sistema decide cuándo puede trabajar** (§2.5): sin concesión de RunningBoard, los command buffers terminan con
   `NotPermitted` («Insufficient Permission (to submit GPU work from background)»), salvo en colas con prioridad de
   fondo. Apple lo documenta para apps en segundo plano: «if Metal sees a new command buffer from your app, it returns an
   error, rather than scheduling the command buffer» [D]. Las extensiones de widget no reciben concesión nunca.
4. **Los fallos se atribuyen** (§2.6): el culpable recibe `Timeout`/`PageFault`; el trabajo ajeno perdido, un error de
   víctima (`Internal`); con `encoderExecutionStatus`, `Faulted` frente a `Affected`/`Pending` por encoder [D]; la cola
   que reincide pasa a `AccessRevoked`. Nadie recibe «Completed» por trabajo que no se hizo.
5. **La memoria de GPU es memoria del proceso** (§2.7): cuenta en su footprint y en su límite de jetsam; volátil no
   cuenta; `currentAllocatedSize` es del proceso; una asignación puede fallar (nil) [D].
6. **La compilación y su caché son del proceso** (§2.9): compilar puede tardar la primera vez tras arrancar; lo del
   sistema viene precompilado y de solo lectura.
7. **La configuración de depuración es del proceso** (§2.10): variables de entorno y preferencias propias, nunca un
   ajuste global que cambie a los demás.
8. **El servidor de ventanas va primero** (§2.5): su cola pide la prioridad más alta y su trabajo no depende de que
   otras apps se porten bien; un error en uno de sus command buffers le cuesta un frame, no la sesión (QuartzCore solo lo
   registra, §2.6).

### 3.2 Por cliente

(En redacción.)

## 4. Diseño para el port

### 4.0 Qué se toma de iOS y qué cambia por el hardware

El diseño reproduce el **contrato** de §3 y la **división de responsabilidades** de iOS (§2): la política la decide el
sistema (RunningBoard, entitlements), el kernel la aplica en un solo sitio y el driver de userland traduce. Cambia la
implementación donde el Adreno no es una GPU de Apple: no hay firmware que planifique, conmute contextos y detecte
cuelgues, así que eso lo hace el kernel; y el procesador de comandos (CP) puede escribir registros de la GPU, así que
además de la MMU por contexto hace falta protección de registros.

| Pieza | iOS 16 (§2) | Port |
|---|---|---|
| Abrir la GPU | Cualquier proceso; sin entitlement | Cualquier proceso |
| Estado por tarea | `IOGPUTask` | `SapphireGpuTask` |
| Memoria de GPU de un proceso | Su propia VA de GPU (GART por contexto, MMU de la GPU) | Su propia tabla del SMMU, cambiada desde el ring |
| Trabajo enviado | Opaco para el kernel | Opaco para el kernel, con `CP_PROTECT` |
| Quién puede enviar ahora | RunningBoard → `TF_GPU_DENIED` + rol | Igual: el kernel lee `TF_GPU_DENIED` y el rol |
| Prioridad | Por cola, 0..5; tiempo real con entitlement; el firmware planifica y expulsa | Por cola con los mismos permisos; el kernel ordena la entrada al ring (sin expulsión) |
| Cuelgue o fallo | El firmware lo detecta; culpable con error y castigo; víctimas | El kernel lo detecta; culpable con error y castigo; víctimas reejecutadas |
| Memoria | En el footprint de la tarea (jetsam) | Crédito explícito al footprint de la tarea; reparto del pool |
| IOSurface entre procesos | Por puerto; búsqueda global por ID desactivada | Importar exige tener la superficie |
| Caché de shaders | Por proceso; compilador XPC por cliente | Por proceso; semilla del sistema de solo lectura |
| Configuración | Entorno del proceso | Boot-args y entorno del proceso; ningún fichero que escriba cualquiera |

### 4.1 Kernel: `SapphireGPU`

#### 4.1.1 Objetos

- **`SapphireGpuTask`** (como `IOGPUTask`): se crea con la primera conexión de una tarea y muere con la última.
  Lleva la tabla de páginas de GPU y su ASID, el asignador de VA, las cuentas de memoria, el historial de fallos y el
  estado de revocación, y la clase de la tarea (entitlements leídos una vez al crearla).
- **`SapphireGpuQueue`** (una por `SUBMITQUEUE_NEW`, que el driver ya crea con prioridad: `hakios-metal/src/gpu.cpp:124-131`):
  prioridad pedida y concedida, numeración de fences propia, cola de trabajos pendientes, último trabajo terminado y su
  estado.
- **`SapphireGpuJob`** (un `GEM_SUBMIT`): IB, buffers con lectura o escritura (el driver ya lo dice:
  `gpu.cpp:146-160`; hoy el kernel lo ignora), cola, número en la cola, número global en el ring, marcas de tiempo,
  estado final.

Invariantes: (I1) un buffer pertenece a una tarea y solo está mapeado en su tabla; una superficie importada está
mapeada en la tabla de cada tarea que la importó. (I2) Handles e identificadores de cola valen solo en su conexión,
como los espacios de nombres de iOS (§2.3). (I3) Una tarea solo espera fences de sus colas. (I4) Ningún trabajo de
una tarea con `TF_GPU_DENIED` llega al ring salvo en una cola cuya prioridad de fondo lo permita (§2.6).

#### 4.1.2 Un espacio de direcciones por tarea

Lo hace el hardware del teléfono [O, `D` §1]: el SQE que carga el port (`a630_sqe.fw` de `/vendor/firmware`, versión
`016ee206`, leído de `/chosen/gpu-sqe-firmware`, G1558-1588, G2287-2298) tiene manejador de `CP_SMMU_TABLE_UPDATE`,
que **solo ejecuta desde el ring** (dentro de un IB es un NOP); drm/msm acepta esa versión (`a6xx_ucode_check_version`
pide ≥ 1.90 para `a630_sqe.fw`) y kgsl usa tablas por proceso en este mismo teléfono (su árbol de dispositivo no tiene
`qcom,global_pt`). El manejador vacía e invalida cachés, detiene el bus, invalida la TLB del banco, escribe TTBR0 y
CONTEXTIDR y, al terminar, **deja activos los recorridos de TTBR0 y de TTBR1** (borra `EPD0` y `EPD1`).

- **Una tabla del SMMU por tarea**, en el formato que el kernel ya usa (LPAE de etapa 1, páginas de 4 KiB, T0SZ 32).
  En las tablas de usuario no hay ventanas de identidad: solo los buffers de la tarea, sus superficies importadas y los
  mapeos globales.
- **Mapeos globales al estilo de kgsl 4.19** (que copia los globales en cada tabla; `kgsl_iommu.c:129-146, 1320-1387`):
  un hueco de 1 GB de la tabla L1 reservado para ellos, con la misma tabla L2 enlazada desde todas las L1, de modo que
  «copiarlos» es una entrada (`D` §2.3). Ahí van el ring, la página de fences y scratch, todos privilegiados o de solo
  lectura (§4.1.3). Las **tablas de páginas salen de la vista de la GPU** (hoy están en el bloque de identidad).
- **TTBR1 apuntando a una tabla vacía** propia, como hace el io-pgtable de Qualcomm (`io-pgtable-arm.c:1186-1188,
  1214-1224` de msm-4.19): el SQE activa su recorrido y hoy vale 0, es decir, una tabla en la dirección física 0.
- **Contexto del kernel** (tabla 0): conserva las ventanas de identidad del pool y del framebuffer para lo que el
  kernel envía por su cuenta (copia al panel, limpiezas).
- **Cambio de tabla en el ring:** antes del primer trabajo de una tarea distinta de la anterior, la secuencia de
  `a6xx_set_pagetable` (`drivers/gpu/drm/msm/adreno/a6xx_gpu.c:103-196`, v6.12): `CP_SET_PROTECTED_MODE 0`,
  `CP_SMMU_TABLE_UPDATE` (TTBR0, ASID, CONTEXTIDR, banco 0), `CACHE_INVALIDATE`, `CP_SET_PROTECTED_MODE 1`; kgsl
  sube además el bit de privilegio `CP_MISC_CNTL[0]` alrededor para escribir su registro privilegiado
  (`adreno_iommu.c:146-186, 281-355`). Con una sola tarea dibujando (backboardd sola, el caso de hoy) no se emite nada.
- **ASID:** drm/msm usa el 0 para todas las tablas y este SMMU lleva `qcom,no-dynamic-asid`; el SQE invalida la TLB
  entera del banco en cada cambio (`TLBIALL`). El port puede seguir con ASID 0; liberar un buffer invalida lo de su
  tarea (hoy `TLBIASID 0`).
- **Apertura del SMMU para el CP:** kgsl en este teléfono y Linux ≥ 6.13 hacen antes una llamada SCM (servicio `0x0c`,
  comando `0x1b`, cuatro argumentos: `0xffff0000 | banco` y tres `0xffffffff`; `kgsl_iommu.c:1213-1234`,
  `qcom_scm.c:1196-1220` de v7.3). El `scm()` del port pasa tres (G546-563). Si en khaje hace falta no está verificado:
  se hace igual que kgsl, que la hace siempre.
- **Espacio de usuario:** el comentario del port que deriva `T0SZ = 32` del `ADRENO_QUIRK_4GB_VA` de Linux
  (G1733-1736) lo interpreta mal: el quirk limita el tamaño a 4 GB por un problema de aritmética de 32 bits en
  microcódigos antiguos, pero el espacio empieza en `0x1_0000_0000` (`dda72ac390bf`, `adreno_gpu.h:611` de v7.3);
  mantener T0SZ 32 es válido, no obligatorio.

#### 4.1.3 Protección del hardware

En iOS el usuario no toca el estado privilegiado porque solo el firmware lo maneja (§2.4). En el Adreno el CP ejecuta
lo que el IB le pide, también escrituras de registros; las tres piezas que lo acotan existen en este SQE [O, `D` §3-§4]:

- **`CP_PROTECT`:** las escrituras de registro que vienen del flujo de comandos (`PKT4`, `CP_REG_WRITE`,
  `CP_MEM_TO_REG`) usan `$usraddr`, que el hardware compara con la tabla, y las lecturas pasan por una prueba de lectura
  protegida. drm/msm y kgsl dan al A610 la tabla `a630` (32 rangos, el último infinito, que cubre la ventana del SMMU,
  el bloque del CP con su ring y `CP_PROTECT_*`, el RBBM, GBIF y el modo seguro) con `CP_PROTECT_CNTL = ACCESS_PROT_EN |
  ACCESS_FAULT_ON_VIOL_EN | LAST_SPAN_INF_RANGE` (`a6xx_catalog.c:510-544`, `a6xx_gpu.c:479-502` de v6.12; kgsl
  `adreno-gpulist.h:745-779`). El port no escribe ni la tabla ni el control: se programan desde la CPU en
  `hw_init_regs`, antes de la primera apertura.
- **Paquetes que solo valen en el ring:** `CP_ME_INIT`, `CP_SET_PROTECTED_MODE`, `CP_SET_SECURE_MODE`,
  `CP_CONTEXT_SWITCH(_YIELD)`, `CP_WHERE_AM_I`, `CP_SMMU_TABLE_UPDATE`, el `CP_SET_AMBLE` del kernel: dentro de un IB el
  SQE los convierte en NOP. El `CP_ME_INIT` del port ya enciende el modo protegido.
- **Mapeos privilegiados:** una entrada sin `AP_UNPRIV` solo la alcanzan los accesos que el CP marca privilegiados. El
  A610 no tiene `CP_APRIV_CNTL`; el privilegio lo da `CP_MISC_CNTL[0]`, que kgsl sube y baja alrededor del cambio de
  tabla y el SQE sube solo dentro de `CP_WHERE_AM_I` (para la sombra del rptr). Ring y microcódigo van de solo lectura
  para la GPU y la sombra del rptr privilegiada. **Las fences no las protege ninguno de los dos drivers en el A610**: un
  IB de usuario puede escribir `memptrs`/`memstore`, la fence común del ring (`D` §3). Si un `CP_EVENT_WRITE` desde el
  ring escribe en un mapeo privilegiado con `CP_MISC_CNTL[0]` a 1 no está verificado (lo decide el ensayo de la etapa 3
  de §4.4). Mientras no se sepa, el diseño no hace depender la seguridad de las fences [H, razonado]: (1) cada tarea
  escribe sus fences en una página suya (mapeada en su tabla y en la del kernel), así que solo puede falsear las suyas;
  (2) la memoria de un buffer liberado no se reutiliza hasta haberlo quitado de la tabla de su tarea e invalidado la TLB
  (ya es así hoy), de modo que un trabajo que siga corriendo tras una fence falsa falla en lugar de tocar memoria ajena;
  (3) el sitio libre del ring sale de `CP_RB_RPTR`, un registro que `CP_PROTECT` protege, no de una fence. Lo que una
  tarea gana falseando sus fences es entregar antes de tiempo lo que escribe, que equivale a entregar basura.

Con esto no se interpreta el PM4 del usuario (como iOS y como drm/msm): la frontera son la tabla por tarea, los
mapeos privilegiados y `CP_PROTECT`. Una violación de protección detiene el CP y es un fallo culpable (§4.1.6).

#### 4.1.4 Colas, fences y orden entre procesos

- Cada cola numera sus trabajos; al final de cada trabajo el ring escribe su número en la página de fences de su tarea
  (§4.1.3) y el kernel, que sabe en qué orden los puso en el ring, retira en orden y avanza el número de cada cola.
- `WAIT_FENCE` y `CPU_PREP` solo sobre colas y buffers propios; el estado de un trabajo (en espera, en el ring,
  terminado, error y su causa) es consultable, lo que da a `waitUntilScheduled` y a los handlers lo que piden (19 N-11,
  N-22).
- **Orden entre procesos por recurso:** el kernel anota en cada superficie el último trabajo que la escribe y los que
  la leen; el planificador no adelanta un trabajo sobre otro anterior con el que comparte una superficie escrita. En un
  ring que ejecuta en orden eso basta para que «programado» (escrito en el ring) sea el punto a partir del cual otro
  proceso puede usar la superficie, que es lo que asume el software de Apple (19 §2.7).

#### 4.1.5 Planificación y prioridad

- **Clase efectiva de una cola** = prioridad pedida (escala de Metal 0..5) limitada por los entitlements de la tarea
  (tiempo real y alta solo con los de iOS, §2.6) y combinada con el rol de la tarea (Focal, UserInteractive,
  Background, §2.5). El servidor de ventanas pide prioridad alta desde QuartzCore (`setGPUPriority:` en
  `CA::OGL::new_metal_context`, 19 §2.7).
- **Sin expulsión** (el A610 no la tiene en este port: §4.1.3), la prioridad actúa al decidir qué entra en el ring:
  los trabajos de la clase del servidor de ventanas entran siempre; de las clases inferiores puede haber como mucho uno
  en el ring mientras el servidor tenga trabajo reciente; dentro de una clase, turno rotatorio por tarea con déficit
  por tiempo de GPU (las marcas de tiempo por envío ya existen desde 0336, `gpu_marks`).
- **Peor caso:** un trabajo de una app que ya está en el ring retrasa el frame del servidor hasta que termina. Lo acota
  el plazo del vigilante de la app (§4.1.6) y lo suaviza el presupuesto: si los trabajos de una tarea pasan de un
  tiempo de GPU dado, sus envíos se espacian a uno por intervalo de frame.

#### 4.1.6 Fallos: culpable, recuperación y castigo

- **Detección** sin interrupciones (el port no atiende IRQ de dispositivo, 09 §3.2), en el mismo sondeo de fences:
  (a) fallo del SMMU del banco de la GPU (registro FSR distinto de 0); (b) error del CP (violación de protección,
  opcode ilegal); (c) vigilante: el trabajo en cabeza no avanza en su plazo (por clase: menos para apps que para el
  servidor de ventanas, que hoy tiene 2 s).
- **Culpable:** el trabajo en cabeza del ring (el CP ejecuta en orden) o, en un fallo del SMMU, la tarea de la tabla
  activa en el banco.
- **Recuperación:** el reinicio que ya existe (`msm_hung` → `gpu_recover`, G5548-5577), reponer tablas y contextos,
  y **volver a emitir** los trabajos posteriores al culpable, que no habían empezado; el culpable termina con su error
  (vencimiento, fallo de página con su VA, protección). Si el reinicio no basta, los demás terminan con el error de
  víctima, como en iOS (§2.6) y en Asahi (`Killed`).
- **Castigo, con las reglas de iOS (§2.6):** la cuenta es por cola; el segundo fallo culpable (vencimiento, cuelgue o
  fallo de página) deja la cola denegada y sus command buffers terminan con `AccessRevoked`; 1001 buenos
  borran la cuenta; con `com.apple.private.graphics-restart-no-kill` (backboardd, §2.8) solo se registra. El kernel no
  mata procesos.
- **Informe:** una línea con proceso, cola, causa, VA y registros, el equivalente de `AGXRestartReport`
  (`process_name`, `restart_reason`, `guilty_dm`).

#### 4.1.7 Memoria por tarea

- **Cuenta en el footprint de la tarea:** al crear y liberar cada buffer del pool, crédito y débito en
  `graphics_footprint` y `phys_footprint` de la tarea dueña con un ayudante pequeño en osfmk (el pool está fuera de la
  VM y no le sirve `setOwnership`). Los buffers volátiles (un `GEM_MADVISE` que haga algo) van a
  `graphics_nofootprint`. Las IOSurfaces, con `setOwnership(creador, kIOMemoryLedgerTagGraphics, …)` en
  `SweetSurface` (hoy la propiedad se ignora, `SweetSurface.cpp:1526`). Jetsam aplica sus límites a esa cuenta sin
  cambios (§2.7).
- **El pool, que iOS no tiene:** es 1 GB físico aparte; un límite de jetsam por app no lo protege. Reserva para el
  servidor de ventanas (hoy ocupa ~99 MB de pool más ~86 MB de superficies, [M] `SWEET MEM` del 14 nov, 14:12), tope
  por tarea sin privilegio, y al agotarse falla la asignación de quien pide (nil en `newBuffer…`, `OutOfMemory` si
  ocurre en un envío), después de purgar los volátiles.
- **Consultas:** bytes de la tarea (para `currentAllocatedSize`) y tamaño recomendado (`recommendedMaxWorkingSetSize`);
  el uso de otras tareas solo con `com.apple.private.ioaccelmemoryinfo`, como en iOS.

#### 4.1.8 Acceso y política

- Abre cualquier proceso. Lo que iOS reserva, con sus mismos entitlements: prioridad explícita y tiempo real,
  información de memoria ajena, inmunidad al castigo (§2.8).
- `task_is_gpu_denied` en cada envío; el error es el de iOS para segundo plano (§2.6).
- **Rol de GPU para RunningBoard:** un servicio de clase `IOGPU` que responda lo que usa `IOGPUDeviceCreate` y
  `IOGPUDeviceSetAppGPURole` (§2.1, §2.6) para que `-[RBXNUWrapper init]` encuentre dispositivo; hasta entonces, el rol
  Darwin de la tarea, que RunningBoard sí escribe («Set darwin role to …», §1.4), como aproximación.
- **IOSurface:** importar exige que la tarea tenga la superficie (creada o recibida por puerto en su
  `IOSurfaceRootUserClient`); la búsqueda por ID en `SweetSurface` deja de ser global salvo para superficies marcadas
  como globales y con un boot-arg de depuración, como `iosurface_debug` en iOS (§2.3).

### 4.2 Driver de userland

1. **Dispositivo para todo proceso.** Fuera la puerta por nombre (`HakiosMetalCA.m:3181-3198`): el dispositivo
   existe en cualquier proceso y el kernel decide si puede enviar trabajo ahora (§2.5). En iOS lo que deja sin
   dispositivo a un proceso es su sandbox (§3.1, punto 1); el port no tiene sandbox, y una lista de procesos en el driver
   sería resolver caso por caso. Los que piden Metal en el teléfono son de los que iOS deja (§3.1), así que el
   comportamiento coincide; cuando el port tenga sandbox, será él quien lo restrinja, como en iOS. La conexión al kernel
   se abre al crear el dispositivo; el compilador y las cachés, al primer pipeline. La clase sigue declarando
   `MTLDevice` y `MTLDeviceSPI` (sin ellos Metal aborta, §2.1).
2. **Prioridad:** `setGPUPriority:` y `setBackgroundGPUPriority:` llegan al kernel con la validación de Apple (0..5; el
   3 solo de fondo; por defecto 1 y 3). Hoy se guardan y no se aplican (`HakiosMetalCA.m:6206-6249`) y la cola se crea
   con prioridad 0 (`command.cpp:543`).
3. **Errores con el contrato de §2.6:** el estado que da el kernel por trabajo se traduce con la misma tabla y el mismo
   texto que IOGPU («Caused GPU Hang Error (00000003:kIOGPUCommandBufferCallbackErrorHang)»…), para que clientes y logs
   vean lo mismo que en iOS. Con `errorOptions = .encoderExecutionStatus`, el driver sabe qué IB es de qué encoder y el
   kernel cuál falló: `Faulted` para ese, `Affected`, `Pending` o `Completed` para el resto. Nada de trabajo omitido con
   estado `Completed` (19 N-02, N-22).
4. **Memoria:** `currentAllocatedSize` y `recommendedMaxWorkingSetSize` del kernel; `setPurgeableState:` → un
   `GEM_MADVISE` que haga algo; `newBuffer…` devuelve nil si el kernel niega la asignación.
5. **Caché por proceso**, con la regla de Metal (§2.9): `<NSCachesDirectory>/<CFBundleIdentifier>/` + un directorio
   propio del driver, creado 0700. Delante, una **semilla del sistema de solo lectura** (las variantes de QuartzCore
   y de los frameworks del sistema ya compiladas para el A610, instalada con la imagen, `root:wheel`, sin escritura para
   nadie), que es el papel de las `pipelines.g10p` de iOS. Formato con cabecera, versión del compilador (como la
   cabecera `LPPM`) y longitudes comprobadas al leer, sin estructuras en memoria con punteros: una entrada mala da un
   fallo de caché, no un fallo del proceso. Sin sandbox (§1.3), otro proceso del mismo usuario puede escribir esa
   carpeta; la ubicación es la de iOS para que la protección llegue con el sandbox (§4.6).
6. **Configuración:** boot-args (solo root) y el entorno del propio proceso, como `MTL_*` en Metal (§2.10); para
   cambiar algo sin reiniciar, un sysctl o un fichero de root en un directorio de root, con dueño y permisos comprobados
   al leer. Fuera `/var/tmp/metal.args`, `/var/tmp/metal.trace` y `metal_trace_dir`, que hoy gobiernan el driver de
   todos los procesos. El bundle se instala `root:wheel` sin escritura para otros (hoy `0777`, §1.3).
7. **Compilación desde MSL:** WebKit/ANGLE y SpriteKit generan MSL en ejecución (§3); el driver la compila o devuelve
   el error de Metal, nunca aborta. Un servicio de compilación por cliente, como `MTLCompilerService`, queda como mejora
   posterior: el contrato no lo exige, pero aísla al cliente de los fallos del compilador y saca su memoria del límite
   de jetsam del cliente.

### 4.3 backboardd y la migración

**Para backboardd no cambia nada visible.** Recibe su dispositivo como hoy; su cola pide prioridad 0 y lleva
`allow-explicit-graphics-priority`, así que va en la clase más alta; con `graphics-restart-no-kill` nunca se le
deniega la cola; tiene su tabla y, mientras sea el único que dibuja, no hay cambios de tabla en el ring; la copia al
panel y el scanout siguen en el contexto del kernel. Su coste nuevo es la tabla `CP_PROTECT` (registros que se
escriben una vez) y la contabilidad de memoria (una suma por buffer).

**Migración:** cada pieza del kernel entra tras su sysctl o boot-arg con 0 = «como hoy», en el orden de §4.4; la puerta
del driver se abre la última, cuando el aislamiento ya está medido. Mientras tanto, `metal_all=1` sigue siendo solo
para ensayos (y, por §1.2, nunca con la GPU de hoy en un uso real).

### 4.4 Plan por etapas

Cada etapa es un arranque de prueba en `boot_a` con su interruptor a 0 por defecto; lo que mide es comparable con 03
(carga `homeswipe.sh`, n ≥ 3 por condición). Los ensayos E0-E4 son los de `D` §8.2.

| Etapa | Qué entra | Cómo se valida | Si falla |
|---|---|---|---|
| 0. Medida | Contadores por tarea y cola (envíos, tiempo de GPU con las marcas de 0336, fallos, bytes) en un sysctl | Coinciden con `SWEET MEM`; homeswipe sin cambio (n ≥ 3) | Nada que deshacer |
| 1. Objetos y política sin aislamiento | `SapphireGpuTask`/`Queue`/`Job`, fences por cola, rechazo con `TF_GPU_DENIED` y prioridad de fondo, prioridades con sus entitlements, cuenta en los ledgers, importación de superficies por posesión, `SweetSurface` sin búsqueda global | homeswipe igual (n ≥ 3); `mtlprobe` en segundo plano recibe `NotPermitted`; el footprint de `mtlprobe` crece con lo que asigna; una superficie ajena no se importa | Interruptor a 0 |
| 2. Tablas por tarea | E0 (lectura de `SMMU_IDR*`, `TCR`/`TTBR1`, `CP_PROTECT*`, apertura disponible), E1 (apertura y cambio a la misma tabla), E2 (dos tablas que difieren en una página; coste del cambio), después tablas por tarea con globales en su hueco, TTBR1 vacío y tablas fuera de la vista de la GPU | E1/E2 con n ≥ 3 arranques; una prueba que lee una VA de backboardd recibe fallo de página y backboardd sigue; coste por cambio medido | Cambio desde la CPU con la GPU ociosa (§4.1.2) |
| 3. Protección | Tabla `CP_PROTECT` y su control; ring y microcódigo de solo lectura; E3 (uso normal sin violaciones; un IB que escribe `RBBM_SW_RESET_CMD` para el CP) y E4 (¿escribe `CP_EVENT_WRITE` en un mapeo privilegiado?) | E3 n ≥ 3 sesiones sin violaciones; la negativa detiene el CP y se recupera | Tabla con menos rangos y la lista de la violación |
| 4. Fallos con culpable | Vigilante por clase, lectura de FSR y del estado del CP, reinicio, reemisión de inocentes, cuenta por cola (2 fallos → cola denegada; 1001 buenos → borrón) | Una prueba que se cuelga recibe Timeout y, a la segunda, `AccessRevoked`; backboardd sigue dibujando (frames perdidos contados); una que lee fuera de su VA recibe PageFault | Recuperación de hoy |
| 5. Planificación | Clases, límite de trabajo en vuelo de clases bajas, presupuesto por tiempo de GPU | homeswipe con y sin una prueba que satura la GPU (n ≥ 3): retraso de commit a fin del servidor acotado | Orden de llegada (hoy) |
| 6. Driver | Dispositivo para todos, prioridades al kernel, errores de §2.6, cachés por proceso y semilla, configuración sin ficheros públicos | `mtlusers` (§1.1) con SpringBoard, chronod y MapKit con dispositivo; sin «Failed to get Metal device» en el log; ningún proceso relanzado en bucle en 30 min | Puerta cerrada (hoy) |
| 7. Lo quitado por falta de Metal | Pósters Astronomía y Emoji, widgets de App Store (21 §4) | Se eligen y pintan; CPU y memoria de sus procesos | Volver a quitarlos |

El servicio `IOGPU` para el rol de RunningBoard (§4.1.8), la interrupción de la GPU para detectar antes (09 P11) y un
servicio de compilación por cliente van detrás, cada uno con su medida.

### 4.5 Segunda opinión por pieza

| Pieza | Contrato (iOS) | drm/msm (Linux) | kgsl (Qualcomm, este SoC) | drm/asahi (GPU de Apple) |
|---|---|---|---|---|
| VA por proceso | `IOGPUTask`, GART por contexto (§2.2) | tabla por proceso, `CP_SMMU_TABLE_UPDATE`, globales en TTBR1 | tabla por proceso, globales copiados, apertura SCM | 63 contextos de usuario con TTB0 propio y TTB1 común |
| Qué valida el kernel | solo el canal de comandos del kernel (§2.4) | nada del PM4; `CP_PROTECT` | nada del PM4; `CP_PROTECT` | campos del comando; nada de shaders ni punteros |
| Memoria del kernel en la VA del usuario | zonas privadas del firmware | ring/microcódigo de solo lectura, rptr privilegiado; fences no en el A610 | igual | TTB1 sin mapear en contextos de usuario (G13/G14) |
| Prioridad | 0..5 por cola, tiempo real con entitlement; el firmware expulsa | (§4.1.5; `D` §6) | (`D` §6) | 4 colas del firmware; HIGH/REALTIME rechazadas hoy |
| Segundo plano | `TF_GPU_DENIED` + prioridad de fondo | — | — | — |
| Cuelgue | culpable con error, víctimas `Internal`, cola denegada al segundo | (`D` §5) | (`D` §5) | culpable `ETIMEDOUT`/`EIO`, otros `ECANCELED`; firmware caído = reiniciar |
| Memoria | ledger de gráficos → jetsam | (`D` §7) | (`D` §7) | sin cuentas ni límites |
| Compartir | puerto de IOSurface | dma-buf | dma-buf | dma-buf |

### 4.6 Riesgos

- **La apertura SCM** (servicio `0x0c`, comando `0x1b`) no está probada en khaje; mal hecha puede bloquear el arranque
  de la GPU. E0 pregunta antes si existe; sin ella, cambio de tabla desde la CPU.
- **TTBR1 y `EPD1`:** el SQE activa el recorrido de TTBR1 tras el primer cambio; con TTBR1 a 0 una dirección de la
  mitad alta recorre memoria física 0 (`D` §1.2). E1 lo descarta antes de usar dos tablas.
- **Coste del cambio de tabla** (halt de bus y dos `TLBIALL` por cambio): irrelevante con backboardd solo; con una app
  que dibuja a la vez puede haber dos cambios por frame. Se mide en E2 y, si pesa, se agrupan los trabajos por tarea.
- **Sin expulsión**, un trabajo largo de una app retrasa al servidor de ventanas hasta su vigilante. El árbol de
  dispositivo de Android no tiene ninguna propiedad de preempción para esta GPU (`D`): kgsl tampoco expulsa aquí.
- **Detección por sondeo:** sin IRQ un fallo se ve en el siguiente sondeo o al vencer el vigilante.
- **Fences escribibles por los IB** (como en drm/msm y kgsl en el A610): el diseño no confía en ellas para la seguridad
  (§4.1.3), pero un error en esa disciplina es un fallo de aislamiento; E4 puede quitar el riesgo.
- **Pool de 1 GB** compartido: con muchos procesos dibujando, asignaciones que fallan antes que en iOS; los clientes
  tienen que aceptar nil (es el contrato de Metal), y el reparto evita que eso le pase al servidor de ventanas.
- **Jetsam:** con la memoria de GPU en el footprint, una app que la use mucho pasa a ser candidata a jetsam, como en
  iOS.
- **Rutas del driver nunca ejercitadas:** procesos que hoy reciben nil (SiriUICore, chronod, MapKit, pósters) entrarán
  en el driver por caminos que backboardd no usa (compilación desde MSL, CoreImage, SceneKit). Un fallo del driver ahí
  es un fallo en ese proceso, no en el servidor de ventanas; la etapa 6 mide relanzamientos en bucle.
- **Sin sandbox en el port**, la caché y la configuración por proceso no protegen de otro proceso del mismo usuario,
  y cualquier proceso abre cualquier servicio. La GPU queda aislada por el kernel; lo demás es un problema general del
  port (04, `seguridad.md`).

## 5. Sin verificar y experimentos que lo deciden

(En redacción.)

## 6. Material

Todo fuera de git, en `~/sapphire-angel/research/metal/multiproceso/`:

| Ruta | Qué es |
|---|---|
| `ipsw/kernelcache.release.iphone10b{,.decompressed}` | Kernelcache de 20H392 para iPhone10,3/10,6 (im4p sha256 `2d6a13d0…`), leído del IPSW por rangos (`ios-graficos/ios-20H392/scripts/catmember.py`) |
| `ipsw/087-86593-047.dmg`, `ipsw/mnt-systemos/` | Cryptex SystemOS de 20H392 (APFS crudo, 2,74 GB) y su montaje de solo lectura |
| `dsc/` | dyld shared cache con la cabecera corregida (`objcOptsSize = 0x38`) y la caché de símbolos de ipsw (`dsc.a2s`) |
| `A-kernelcache-ios.md`, `A/` | Informe de trabajo del kernelcache (IOGPUFamily, AGXG10P, IOSurface, Sandbox) y sus guiones (`kc.py`, `xref.py`, `ana.py`, `disp.py`) |
| `B1-userland-metal-iogpu.md`, `B1/` | Informe de trabajo de Metal, IOGPU, AGXMetalA11, RunningBoard y libCoreFSCache; desensamblados y guiones |
| `B2-clientes-y-entitlements.md`, `B2/` | Informe de trabajo de clientes de Metal, `.metallib` del sistema y entitlements de 2784 binarios (`raw/`) |
| `C-fuentes-externas.md`, `C/` | Informe de trabajo de fuentes externas (Apple, Asahi, WebKit) con copias fijadas |
| `D-adreno-multicontexto.md`, `D/` | Informe de trabajo del hardware Adreno (SQE, SMMU, drm/msm, kgsl) con referencias fijadas |
| `rb-domains-gpu.txt`, `scripts/rb_domains_gpu.py`, `scripts/rb_gpu.py` | Concesiones de GPU de RunningBoard por dominio; mapeo de las líneas «Set Darwin GPU» a procesos |
| `tools/mtlusers.c` | Lista, sin tocar las tareas, los procesos con un fichero mapeado (el plug-in de Metal) |
| `telefono/` | Lecturas del teléfono del 14 nov: `mtlusers-*.txt`, `oslog-45s-1711.txt`, informes de fallo copiados |

## 7. Bibliografía

**Binarios y datos de Apple (fuente primaria, [O]):** IPSW `iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw`
(`updates.cdn-apple.com/2025FallFCS/fullrestores/122-77006/…`): `kernelcache.release.iphone10b`, cryptex SystemOS
`087-86593-047.dmg` (dyld shared cache), sistema raíz `087-86698-044.dmg` (`launchd.plist`,
`/System/Library/LifecyclePolicy/DomainAttributes/*.plist`, entitlements de los binarios).

**Código abierto ([O] en código):**

| Fuente | Versión | Para qué |
|---|---|---|
| XNU del port (`display/work/check-0353`) | xnu-8796.141.3 + serie hasta 0353 | `PRIO_DARWIN_GPU`, `TF_GPU_DENIED`, `kIOUCForegroundOnly`, ledgers, `setOwnership`, `mach_memory_entry_ownership`, jetsam; `SapphireGpu.cpp` (sha256 `05fa4982…`), `SweetSurface.cpp` |
| hakios-metal (`rebuild/hakios-upstream`) | `4cf8232` (`merge-5`) | puerta, `metal.args`, caché de etapas, prioridades, interfaz con el kernel |
| Linux, drm/msm y arm-smmu | v6.12 `adc218676eef`; v7.3 `c03c1a14507d` | `a6xx_set_pagetable`, `a6xx_ucode_check_version`, `a630_protect`, TTBR1, apertura SCM |
| kgsl de Qualcomm para khaje | MiCode `spes-r-oss` `88afd3256421`; graphics-kernel `f900d903` | tablas por proceso, globales copiados, apertura, `CP_PROTECT`, privilegio |
| Asahi Linux | `AsahiLinux/linux` `6ba0637`; `AsahiLinux/docs` `ed6f9d6`; UAPI `asahi_drm.h` en Linux `23c62304` | UAT, contextos, validación, prioridades, fallos de G13/G14 [R] |
| WebKit | `f1404ac4` (WebKit-7615.3.12.11.5, la etiqueta más cercana a la 615.8.1 de 20H392) | perfiles de sandbox del proceso GPU y de WebContent en iOS; `IOSurfaceSetOwnershipIdentity` [R] |

**Apple ([D], consulta del 14 nov 2026):** referencia de `MTLCommandBufferError`, `MTLCommandEncoderErrorState` y
`MTLCommandBufferErrorOption`; «Preparing your Metal app to run in the background»; `MTLCreateSystemDefaultDevice`,
`recommendedMaxWorkingSetSize`, `currentAllocatedSize`, `setPurgeableState(_:)`, `setOwner(with:)`; WWDC20 10615
(*Build GPU binaries with Metal*), WWDC22 10106 (memoria y footprint) y 10102; «Keeping a widget up to date» y WWDC23
10028 (*Bring widgets to life*: los widgets se pintan en un proceso del sistema a partir de vistas archivadas); Apple
Platform Security, «Runtime process security». URLs y citas en `C-fuentes-externas.md` §3 y §5.

**Terceros:** Asahi Lina, *Tales of the M1 GPU* (2022-11-29) y su correo a dri-devel de 2023-03-10 [R]; WebKit blog,
*WebKit Features in Safari 17.0* (2023-09) [R]; perfil de contenedor de iOS 17 beta decompilado con SandBlaster
(`blacktop/yardens-sb-profs` `e03ae303`) [R?]; base de entitlements de J. Levin (newosxbook.com) [R?]; flutter#155538
(iPhone X con iOS 16.7.10: «Address Fault» → «Hang» → «Ignored (for causing prior/excessive GPU errors)») [R?].
