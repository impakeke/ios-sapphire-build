# 23 — GPU para todos los procesos: cómo lo hace iOS, qué espera su userland y diseño para el port

Informe fechado (2026-11-14). Pregunta: en iOS toda app, extensión y widget cuenta con Metal; en el port solo
backboardd recibe el dispositivo. ¿Cómo reparte y aísla la GPU iOS 16 entre procesos, qué espera el userland de iOS
del sistema (más allá de cómo lo implemente Apple) y cómo se construye eso en `SapphireGPU` y en el driver Metal del
port, sobre un Adreno 610 sin GMU? Es un estudio con diseño; no toca el kernel ni el driver.

Convención de evidencia: **[O]** observado en un binario de Apple (dirección o símbolo de 20H392), en código
(archivo:línea) o en un fichero; **[M]** medido en el teléfono (fichero crudo citado); **[D]** documentado por Apple
(URL en §7); **[R]** tercero fiable (URL o commit en §7); **[H]** hipótesis. Lo que no se ha podido comprobar se dice.

Material de trabajo, fuera de git: `~/sapphire-angel/research/metal/multiproceso/` (kernelcache y cryptex de 20H392,
informes de trabajo `A`-`D`, scripts, lecturas del teléfono en `telefono/`).

## Resultado en breve

(En redacción.)

## 1. Punto de partida en el port

### 1.1 Quién pide Metal hoy y qué recibe

- **[M] Procesos con el plug-in cargado** (`multiproceso/tools/mtlusers`, recorre las regiones de cada proceso con
  `proc_pidinfo(PROC_PIDREGIONPATHINFO)` sin tocar las tareas; Metal carga el bundle del acelerador al enumerar
  dispositivos, así que tenerlo mapeado significa haber llamado a `MTLCreateSystemDefaultDevice`/`MTLCopyAllDevices`):
  backboardd, SpringBoard, chronod y `com.apple.MapKit.SnapshotService`, en dos lecturas (13:56 y 13:58 del 14 nov,
  `telefono/mtlusers-*.txt`). Solo backboardd recibe dispositivo; a los otros tres el plug-in les devuelve nil.
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

(En redacción: §2.1 apertura del dispositivo; §2.2 estado por tarea y espacio de direcciones; §2.3 recursos e
IOSurface; §2.4 validación; §2.6 fallos; §2.8 entitlements y sandbox; §2.9 caché de shaders; §2.10 configuración;
§2.11 qué es del A11 y qué es contrato de Metal.)

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
`kIOReturnNotPermitted` (`IOUserClient.cpp:6589-6592`, `6636-6639`). Lo que haga IOGPUFamily con ello y con el rol: §2.6.

Qué procesos son «GPU managed» lo dice su job de launchd [O, `ipsw-launchd.plist`]: PosterBoard y
AccessibilityUIServer llevan `RunningBoard = {Managed = true}` y `ProcessType = App`, igual que las apps y sus
extensiones; SpringBoard, backboardd y chronod no, y RunningBoard nunca les niega la GPU.

**En el teléfono [M]** (§1.4): runningboardd ya pone y quita `TF_GPU_DENIED` en pósters, widgets y
AccessibilityUIServer, y cada `setGPURole` falla por falta de servicio `IOGPU`. Los widgets solo reciben «deny»:
en iOS 16 una extensión de widget no tiene GPU, y lo que dibuja lo convierte en píxeles otro proceso.

### 2.7 Memoria de GPU: cuenta en el footprint de la tarea

En XNU [O]: cada tarea tiene ledgers `graphics_footprint` y `graphics_nofootprint` (y sus variantes comprimidas)
(`osfmk/kern/task.c:1143-1146`). Un driver asigna la memoria a una tarea con `IOMemoryDescriptor::setOwnership(tarea,
kIOMemoryLedgerTagGraphics, opciones)` (`iokit/IOKit/IOMemoryDescriptor.h:141, 366-376`;
`IOMemoryDescriptor.cpp:3725-3783`), que acaba en `vm_object_ownership_change` (`osfmk/vm/vm_object.c:8061`): la
memoria no volátil cuenta en `graphics_footprint` y en `phys_footprint` salvo con `kIOMemoryLedgerFlagNoFootprint`
(`vm_object.c:8022-8036`, `8350-8383`); la volátil (purgeable) no cuenta. `phys_footprint` es lo que mira jetsam: el
límite por proceso es un límite del ledger (`task_set_phys_footprint_limit_internal`, `task.c:6926-6990`;
`kern_memorystatus.c:560, 876-877`). Es decir, en iOS la memoria de GPU de una app cuenta contra su límite de
memoria, y un informe de fallo lleva `graphics_footprint` (`bsd/kern/kern_exit.c:748-755`). Lo que hace IOGPUFamily
con estas llamadas: (en redacción).

## 3. Qué espera el userland de iOS

(En redacción.)

## 4. Diseño para el port

(En redacción.)

## 5. Sin verificar y experimentos que lo deciden

(En redacción.)

## 6. Material

(En redacción.)

## 7. Bibliografía

(En redacción.)
