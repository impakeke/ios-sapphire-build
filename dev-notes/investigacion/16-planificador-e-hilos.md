# 16 — Planificador, hilos y caché de los A73: dónde corre el trabajo de la interfaz, 2026-11-14

Informe fechado. Pregunta: ¿está bien repartido el trabajo entre núcleos e hilos? El cuello medido de la UI es CPU de
un solo hilo (`com.apple.coreanimation.display.primary` de backboardd, 126-160 µs por draw del driver Metal; 03 M1,
M2, M6, M7), cuando el mismo código cuesta 3-15 µs por draw en un host x86.

Árbol de referencia: xnu-8796.141.3 con los parches 0001-0342 aplicados en orden
(`~/sapphire-angel/research/metal/hilos/xnu-0342`; coincide archivo a archivo en `osfmk/`, `iokit/` y `bsd/` con
`relojes/xnu-0342`). Rutas de código relativas a ese árbol salvo que se diga otra cosa. Kernel del teléfono en las
medidas: el de 0342 (CI 43620776409, configuración **DEVELOPMENT**), boot-args con `cpus=8 sweetsched=15 gpu_vco2=1
gpu_mhz=820`, `kern.sweet_fb_queue=1`, `kern.sweet_gpu_flush=1`, bundle `propio-args`.

Convención: **[O]** observación propia (código con `archivo:línea` o medida reproducible), **[M]** medida en el
teléfono de esta investigación (archivo crudo citado), **[H]** hipótesis sin medir. Material pesado:
`~/sapphire-angel/research/metal/hilos/` (`datos/tanda1-3`, `tools/`, árboles `xnu-0342` y `xnu-0344`, parches,
notas de los agentes de código `agente-driver.md` y `agente-kernel.md`).

## Resultado en breve

1. **La topología es correcta.** En XNU las CPU lógicas 0-3 son los cuatro Cortex-A73 (MPIDR 0x100-0x103, cluster
   P, pset0) y las 4-7 los cuatro A53 (MPIDR 0x0-0x3, cluster E): al revés que Linux. Frecuencia medida: A73
   2786-2801 MHz, A53 1854-1895 MHz (§1, §3.1).
2. **El hilo de render nunca toca un A53**: es de prioridad fija 54 (bucket FIXPRI), prefiere P y con
   `sweetsched=15` no puede migrar a E. Corre el 61-71 % de un núcleo durante el swipe, el 100 % en los A73 (§3.2).
3. **`sweetsched=15` manda a los A53 los hilos de QoS por defecto** (prioridad 21-31): el hilo de espera de fences
   del driver en backboardd pasa ahí la mitad de su tiempo. El A/B 15 frente a 13 (QoS por defecto de vuelta a P),
   n=3 cada uno, no separa: 22,0 frente a 23,1 buffers/s y 161 frente a 154 µs/draw, con rangos que se solapan (§3.3).
4. **El hallazgo principal no es de planificación: los A73 trabajan sin L2.** XNU limpia e invalida por set/way la L1
   del núcleo **y la L2 compartida del cluster** antes de cada WFI (`cpu_idle` → `platform_cache_idle_enter` →
   `FlushPoU_Dcache`, con un límite de niveles inclusivo que incluye la L2; §4). El cluster P entra en reposo
   2600-3200 veces por segundo durante el swipe (hilos del kernel que sondean, la espera de fences por sondeo), así
   que su L2 de 2 MB casi nunca contiene nada: una cadena de punteros de 128 KB-1,75 MB cuesta 43-142 ns por carga en un
   A73 (DRAM) frente a 7-11 ns cuando otros tres hilos impiden que los demás A73 entren en reposo (§3.4).
5. **Efecto sobre el driver**, mismo código y mismas escenas que en el host (`drawbench`): escena K 54-62 µs/draw en
   un A73 tal cual, 34 µs con los A73 sin reposo, 85 µs en un A53, 15 µs en el i5 del host. Escena L: 35-41, 19-20,
   50 y 9 µs (§3.5). El vaciado de la L2 multiplica por 1,5-2,1 el coste por draw en un bucle cerrado; en
   producción, con el trabajo de CoreAnimation intercalado y el propio núcleo del hilo de render entrando en reposo
   entre frames, el efecto puede ser mayor [H].
6. **Parches**: 0344 (interruptor `kern.sweet_idle_cache` y diagnóstico, ya en la serie) y 0351 (definitivo: nada
   antes de WFI por defecto y límite correcto en el mantenimiento por set/way; §5.1). Experimento decisivo: curva de
   latencia en un A73 sin hilos de relleno y `homeswipe` A/B con CPU por draw (§6).
7. **Segunda causa de calor y latencia**: ~3600-4100 despertares por segundo de hilos del kernel en los A73, todos
   por sondeo (el port no usa ninguna interrupción de dispositivo), más ~980-1480 de la espera de fences por
   sondeo de 50 µs. Cada despertar es una expulsión potencial del hilo de render (61-112 por segundo) y una migración
   entre A73 (66-105 por segundo) (§3.2, §5.2).

## 1. Topología

**En XNU las CPU lógicas 0-3 son los cuatro Cortex-A73 y las 4-7 los cuatro A53: la numeración es la inversa de la
de Linux.** Los contadores del driver `draw calls by processor: cpu0 … cpu3` usan esa numeración: leen `TPIDR_EL0 &
0xfff` (`userland/src/HakiosMetalCA.m:8295`, `:8311` en `hakios-upstream`, rama `opcional-puerto`), que el kernel
escribe con `cpu_number` en cada cambio de contexto y en cada vuelta a usuario (`osfmk/arm64/cswitch.s:182-183`,
`locore.s:949-950`).

| CPU lógica XNU | MPIDR (`reg` del ADT) | Núcleo | Linux (Android) | Cluster XNU | `cluster-type` | Frecuencia | pset |
|---|---|---|---|---|---|---|---|
| 0 (arranque) | 0x100 | Cortex-A73 (part 0xd09) | cpu4 | 0 | `P` | 2803 MHz pedido, 2786-2801 medido | pset0, `PSET_AMP_P` |
| 1-3 | 0x101-0x103 | Cortex-A73 | cpu5-7 | 0 | `P` | ídem | pset0 |
| 4-7 | 0x0-0x3 | Kryo «Silver» part 0x801 (clase A53) | cpu0-3 | 1 | `E` | 1900 MHz pedido, 1854-1895 medido | `PSET_AMP_E` |

- [O] El ADT lo genera `tools/mkadt.py:138-170` (repo). [M] El del teléfono (`ioreg -p IODeviceTree`,
  `hilos/datos/ioreg-cpus.txt`): `cpu0@100` … `cpu3@103` con `logical-cpu-id` 0-3 y `cluster-type` 'P'; `cpu4@0` …
  `cpu7@3` con 4-7 y 'E'.
- [O] `ml_parse_cpu_topology` (`osfmk/arm64/machine_routines.c:944-1108`) numera por orden del ADT (:1016), toma el
  MPIDR de `reg` (:1023) y el tipo de `cluster-type` (:1036-1041); sin `HAS_CLUSTER` el cluster es «P o no» (:1053).
- [O] `SweetCPU::startAll` (`iokit/Kernel/arm/SweetCPU.cpp:126-181`) enciende cada CPU con PSCI `CPU_ON(target = reg)`
  (:249) y comprueba que una SGI dirigida a ese MPIDR llega (:164, :221-226). [M] Ring de un arranque
  (`hilos/datos/ring-boot.txt`): `cpu=1 CPU_ON target=0x101 … rc=0` … `cpu=7 CPU_ON target=0x3 … SGI1 OK`, y después
  `SWEET SCHED: mode 0xf (P cluster 0, E cluster 1)`. El núcleo de arranque es el A73 0x100: el shim arranca en un
  Silver, despierta al 0x100 con PSCI y se apaga (`shim/shim.c:172-178`, `:274-300`).
- Lado hardware: el DT de Android (`relojes/dtb/merged-khaje24a-sapphire.dts:39-259`) pone MPIDR 0x0-0x3 en el
  dominio de frecuencia 0 con `capacity-dmips-mhz` 1024 y 0x100-0x103 en el 1 con 1638; Android
  (`research/metal/android/estado-reposo.txt`) da part 0x801 y capacidad 433 a cpu0-3, part 0xd09 (Cortex-A73) y 1024
  a cpu4-7.
- [O] Lo que ve el planificador: pset0 es el cluster de arranque, `PSET_AMP_P` (`osfmk/kern/processor.c:196-221`); el
  E se crea como `PSET_AMP_E` en `pset_node1` (`machine_routines.c:1433-1449`). [M] `hw.perflevel0` = Performance, 4
  CPU, L1D 64 KB, L2 2 MB; `hw.perflevel1` = Efficiency, 4 CPU, L1D 32 KB, L2 512 KB. Esos tamaños los lee el kernel de
  `CCSIDR` en un núcleo de cada tipo (`osfmk/arm/cpuid.c:290-400`, por tipo de cluster); `hw.l1dcachesize` y
  `hw.l2cachesize` dan los del nivel de eficiencia, como en los Mac con Apple Silicon.
- Sin efecto en el planificador, pero falso: el ADT instalado da `clock-frequency` = 2 803 200 000 también a los A53
  (`<007015a7>` en los ocho nodos); `mkadt.py:164` escribe 1 900 800 000, así que el ADT instalado sale de una versión
  anterior del generador.

## 2. Planificador

### 2.1 Cuál corre

[M] `kern.sched` = `edge`. [O] `osfmk/arm64/proc_reg.h:85-99` activa `CONFIG_SCHED_EDGE` con `__ARM_AMP__`, y
`SWEET.h` define `__ARM_AMP__` cuando se compila con `TOPAZ_4K` (parche 0217); `MAX_CPU_CLUSTERS` = 2
(`board_config.h:105-109`); despacho `sched_edge_dispatch` (`osfmk/kern/sched_prim.h:814-822`). No hay CLPC: nada
llama a `sched_perfcontrol_thread_group_recommend` (`osfmk/kern/thread_group.c:1300-1332`) ni a
`sched_edge_matrix_set` (`osfmk/kern/sched_clutch.c:3498-3511`): las preferencias de cluster son estáticas.

### 2.2 Cómo decide dónde va un hilo

1. **Bucket** (`sched_clutch.c:296-345`): tiempo real, o modo fijo con prioridad ≥ 47 → `FIXPRI`; si no, por
   prioridad base: > 37 `FG`, 32-37 `IN`, 21-31 `DF`, 5-20 `UT`, ≤ 4 `BG`. La QoS entra solo por la prioridad que da
   (UI 47, IN 37, DF 31, UT 20, BG 4); un hilo promovido usa su prioridad efectiva.
2. **Cluster preferido** = el que guarda su grupo de hilos para ese bucket (`sched_edge_thread_preferred_cluster`,
   :1232-1246). Se fija al crear el grupo (`sched_clutch_bucket_group_init`, :1144); sin 0303 es pset0, aquí el
   cluster P (la nota heredada «el Edge sin CLPC prefiere pset0 para todo» es cierta para el código).
3. **Elección del cluster** (`sched_edge_migrate_candidate`, :4450-4532, desde `sched_edge_choose_processor`,
   :4535-4566): el tiempo real se queda en el preferido (:4484-4487), y también cualquier hilo si la carga del
   preferido es 0 (:4489-4492); si no, se miran las aristas (`sched_edge_migration_check`, :4175-4228).
4. **Carga** (`sched_update_pset_load_average`, `sched_prim.c:8114-8180`): (hilos en cola de bucket ≥ b + CPUs
   ejecutando bucket ≥ b + cola RT) / CPUs del cluster, **en división entera**: con 4 CPUs vale 0 hasta que hay 4
   hilos de ese nivel o superior.
5. **Dentro del cluster** (`choose_processor`, `sched_prim.c:5025-5260`): primero una CPU ociosa, si no la que corre
   algo de menos prioridad. El tiempo real solo recorre los psets de su nodo (:5150-5225) y P y E están en nodos
   distintos: **el tiempo real nunca sale del cluster P**.
6. **CPU que se queda ociosa** (`sched_edge_processor_idle`, :4017-4050): roba hilos «extranjeros» de su tipo que
   esperan fuera, luego de su tipo, expulsa a los extranjeros que corren fuera (`sched_edge_balance`, :4127-4166) y
   por último roba según aristas (`sched_edge_steal_thread`, :3973-4012; entre tipos exige carga > 0 en el origen,
   :3954-3971).
7. **Fin de quantum**: un hilo que corre en un cluster de otro tipo que el preferido se devuelve
   (`sched_edge_thread_avoid_processor`, :4096-4125).

### 2.3 `sweetsched` / `kern.sweet_sched` (parche 0303), bit a bit

Código: `sched_clutch.c:4869-4930` y :4974-4983, `thread_group.c:1334-1352`, `bsd/kern/kern_sysctl.c:2523-2540`.

| Bit | Efecto | Línea |
|---|---|---|
| 1 | Buckets `UT` y `BG` de cada grupo prefieren E | `sweet_sched_bucket_cluster`, :4883-4893 |
| 2 | Bucket `DF` también prefiere E | ídem |
| 4 | Aristas P→E: sin migración ni robo (de serie: peso 64, ambas permitidas) | `sweet_sched_edges`, :4896-4920 |
| 8 | Arista E→P: robo permitido (una CPU P ociosa toma hilos que esperan en E si la carga de E > 0); la migración E→P sigue prohibida | ídem |

Con **15** (lo de hoy): FIXPRI, FG e IN viven en P y **nunca** pasan a E aunque los cuatro A73 estén ocupados; DF, UT
y BG viven en E y solo suben a P si una CPU P está ociosa y E tiene al menos 4 hilos de ese nivel o superior.

**Todos los bits se pueden cambiar sin reiniciar**: el sysctl llama a `sweet_sched_set` (:4925-4930), que reescribe
las aristas y aplica las preferencias a todos los grupos existentes moviendo al momento los hilos que corren o
esperan (`MIGRATE_RUNNING | MIGRATE_RUNNABLE`). Diferencia con el boot-arg: el boot-arg se aplica antes de que exista
ningún proceso ([M] `SWEET SCHED` sale antes del copyright de BSD), y los grupos creados antes (`system`,
`background`, `VM`, `io storage`, `perf_controller`: `thread_group.c:130-142`) se quedan en P para todo; una escritura
en caliente los mueve también. [M] Solo tres hilos del kernel tienen prioridad < 47 (`VM_pageout_garbage_collect`,
`VM_pressure`, `thread call user #1`, prioridad 31), así que la diferencia es pequeña.

### 2.4 Dónde caen los hilos del camino de un frame (por prioridad)

[M] `thrsched` (`hilos/datos/tanda1/ab*-m*.threads`; `pol` 2 = fijo o RR):

| Hilo | Política y prioridad | Bucket | Cluster con 15 |
|---|---|---|---|
| backboardd `com.apple.coreanimation.display.primary` (render) | fijo 54 | FIXPRI | P, nunca E |
| backboardd `render-server` | fijo 55 | FIXPRI | P |
| backboardd `IOHIDEvent Server Connection` ×2, `IOHIDService` | fijo 63 | FIXPRI | P |
| backboardd, hilo sin nombre con 980-1480 despertares/s y casi todo su tiempo en el kernel: el de espera de fences del driver, `command.cpp:523` [H, por firma] | timeshare 31 (promovido a 46 al correr) | DF | E; corre en P cuando está promovido o lo roba un A73 |
| SpringBoard hilo principal | fijo 47, QoS UI | FIXPRI | P |
| SpringBoard `UIKit.inProcessAnimationManager` | fijo 53 | FIXPRI | P |
| SpringBoard `eventfetch-thread` y trabajadores UI | timeshare 47 | FG | P |
| SpringBoard trabajadores IN / DF / UT | 37 / 31 / 20 | IN / DF / UT | P / E / E |
| Hilos del kernel (`kernel_thread_start`, IOWorkLoop) | fijo 81 | FIXPRI | P (grupo `system`, de antes del boot-arg) |
| thread_call kernel-high (vsync, `SweetFramebuffer.cpp:681`) / high | fijo 92 / 93 | FIXPRI | P |
| Todo lo lanzado por SSH (`sshd`, la shell, `hidtouch`, `homeswipe`, herramientas) | timeshare 4, máximo 4, QoS BG | BG | E |

Hilos que crea el driver (informe del agente, `agente-driver.md`): un hilo de espera por `MTLCommandQueue`
(`command.cpp:523`), el hilo diferido de `metal_defer=1` (`c_api.cpp:47`) y la cola de especialización de shaders
(`HakiosMetalCA.m:7499`), todos sin QoS ni nombre: heredan la del hilo que crea la cola. La especialización es
asíncrona; la compilación de pipelines es síncrona en el hilo que llama, bajo `gCompilerLock` (`compiler.cpp:52`). En
esta rama no existe el `usleep(2000)` de 10 §3.7 (era del árbol de Angel).

## 3. Medidas en el teléfono

Herramientas (fuentes en `hilos/tools/`, compiladas para iOS con el clang de CommandLineTools y el SDK 16.5, firma ad
hoc): `kdsched` (traza kdebug de planificación: cambios de contexto con su CPU, make-runnable, reposo, eventos del
Edge e interrupciones; drena el búfer cada 50 ms), `kdan.py` y `kdwake.py` (análisis en la Mac), `thrsched` (hilos con
política, prioridad y QoS efectiva), `memlat` (curvas de latencia y retención de caché), `cpubench`, `drawbench`
(del árbol del driver en `397bd3e`, con transporte nulo) y `spawnfg` / `drawbench-in`.

**Aviso sobre cualquier medida lanzada por SSH**: el trabajo de `sshd` es de fondo; todo lo que cuelga de él corre
con prioridad 4, máximo 4 y QoS BG (`hilos/datos/tanda1/bench-*`), es decir en los A53 con `sweetsched=15`, por mucho
que pida QoS UI o prioridad fija. `spawnfg` lanza con `posix_spawnattr_setprocesstype_np(DAEMON_INTERACTIVE)` y deja
pedir QoS IN; así se llega a los A73. `hidtouch` y `homeswipe` corren también en los A53 a prioridad 4.

### 3.1 Frecuencia real

[M] Cadena de 512 sumas dependientes (`cpubench`, una suma por ciclo en los dos núcleos): A53 1854-1895 MHz (16
tramos, tres procesos), A73 2786-2801 MHz (2 tramos, un proceso; n<3). Coinciden con lo pedido (2803 y 1900 MHz): no
hay limitación por LMh en reposo.

### 3.2 Hilo → núcleo durante el swipe

[M] `kdsched` durante `homeswipe.sh 4` (ventana START-END de 8,6-9,1 s), tres ensayos con `sweetsched=15`
(`hilos/datos/tanda1/ab{1,3,5}-m15.an.txt`) y tres con 13 (`ab{2,4,6}-m13`). La traza registra ~180 000 eventos/s y
el propio trazador gasta el 16 % de un núcleo, sobre todo en E.

| Medida | 15 (n=3) | 13 (n=3) |
|---|---|---|
| Ocupación media por CPU, A73 / A53 | 47-49 % / 12-14 % | 50-51 % / 7-12 % |
| Entradas en reposo por segundo, cluster P / E | 3111-3234 / 490-519 | 3025-3090 / 206-312 |
| Hilo de render: % de un núcleo; % en A73 | 61-71 %; 100 % | 67-79 %; 100 % |
| Hilo de render: migraciones entre A73 / expulsiones involuntarias por segundo | 75-81 / 77-88 | 66-105 / 61-112 |
| Hilo de render: latencia de despertar p50 / p95 | 31-42 / 148-224 µs | 28-39 / 111-237 µs |
| Hilo principal de SpringBoard: % de un núcleo; % en A53 | 43-50 %; ≤ 0,2 % | 40-44 %; ≤ 0,5 % |
| Hilo de espera de fences de backboardd: % de un núcleo; % de su tiempo en A53 | 3,9-4,9 %; 47-51 % | 4,2-4,3 %; 0 % |
| Hilos del kernel (los de más CPU): % de un núcleo; despertares/s | 12-14 %; 3600-3900 | 12-15 %; 3660-4010 |

Quién expulsa al hilo de render: hilos del kernel de prioridad 81-93 (~600 de las 764 expulsiones del ensayo 1).
Quién lo despierta: hilos de backboardd, de SpringBoard y la interrupción de temporizador (`ab1-m15.an.txt`).

### 3.3 A/B de `kern.sweet_sched` 15 frente a 13

[M] Mismos ensayos que §3.2 (alternados 15, 13, 15, 13, 15, 13; `metal_fps=1`; consola del driver resumida con
`ab-sum.py`; `hilos/datos/tanda1/ab*.cons`):

| Modo | buffers/s | CPU por draw | hecho → commit | commit → fin |
|---|---|---|---|---|
| 15 | 21,8 / 22,4 / 21,7 | 166 / 161 / 156 µs | 27,4 / 26,9 / 25,9 ms | 21,5 / 20,9 / 19,3 ms |
| 13 | 24,1 / 22,3 / 22,8 | 163 / 136 / 164 µs | 26,8 / 26,3 / 26,8 ms | 20,7 / 27,8 / 20,9 ms |

Interpretación: los rangos se solapan; con n=3 no hay efecto medible de devolver la QoS por defecto a los A73. El
reparto de hilos entre clusters no es el cuello hoy.

### 3.4 Caché: curvas de latencia y retención

[M] `memlat` (`hilos/datos/tanda2/`): cadena de punteros aleatoria (una por línea de 64 B, todas las líneas en cada
vuelta) y secuencial; por punto, dos vueltas de calentamiento y 3 medidas de ≥ 400 000 cargas; mediana en ns por
carga. A73 = proceso lanzado con `spawnfg` (QoS IN); A53 = lanzado por SSH (BG). «A73 con relleno» = mismo proceso con
tres hilos que giran en ALU a la misma QoS, para que los otros tres A73 nunca entren en reposo.

| Conjunto | A73 aleatoria | A73 con relleno, aleatoria | A53 aleatoria | A73 secuencial | A73 con relleno, secuencial | A53 secuencial |
|---|---|---|---|---|---|---|
| 32 KB | 1,07 | 1,07 | 1,60 | 1,07 | 1,07 | 1,58 |
| 64 KB | 1,08 | 1,08 | 7,53 | 1,08 | 1,07 | 3,94 |
| 96 KB | 19,9 | 5,70 | 8,55 | 5,98 | 2,75 | 4,01 |
| 128 KB | 42,9 | 7,06 | 8,80 | 10,0 | 2,98 | 4,05 |
| 256 KB | 118 | 8,92 | 8,96 | 13,5 | 2,97 | 4,31 |
| 512 KB | 132 | 9,81 | 9,50 | 25,7 | 3,05 | 4,55 |
| 1 MB | 141 | 10,5 | 134 | 26,3 | 3,05 | 26,2 |
| 1,75 MB | 142 | 10,8 | 139 | 25,8 | 3,14 | 26,9 |
| 2 MB | 143 | 22,7 | 139 | 25,8 | 3,62 | 27,0 |
| 4 MB | 147 | 121 | 155 | 23,1 | 6,82 | 27,3 |
| 64 MB | 294 | 182 | 210 | 23,2 | 7,27 | 27,9 |

- En los A53 se ven los dos escalones de libro: L1D de 32 KB (3 ciclos) y L2 de 512 KB (~9 ns, 17 ciclos).
- **En los A73 la L2 no existe en la práctica**: tras la L1D de 64 KB (3 ciclos) la latencia salta a la meseta de
  DRAM (~130-145 ns). Con los otros A73 ocupados aparece una L2 de 2 MB con 7-11 ns, coherente con `hw.perflevel0`.
- Retención de 256 KB tras una pausa, una vuelta (`ret-*.txt`, n=3 × 20 vueltas): A73 sin relleno, pausa 0:
  mediana 115-121 ns; A73 con relleno, pausa 0: 8,6 ns; con relleno y pausa de 100 o 1000 µs (el propio núcleo entra
  en reposo): 75-91 ns. A53, pausa 0: 9,0 ns; pausa de 100 o 1000 µs: 136-138 ns.

Lectura: **la L2 se vacía cada vez que un núcleo de su cluster entra en reposo.** En el cluster P eso ocurre miles de
veces por segundo y la L2 no llega a llenarse; en el E, con pocas entradas en reposo, la L2 aguanta mientras el hilo
no se duerme. La causa está en §4.

### 3.5 El driver en cada tipo de núcleo (`drawbench`)

[M] Escenas J (20 draws, sysmem), K (110 draws, GMEM con binning) y L (K en sysmem) del driver en `397bd3e` (la base
de la rama de CPU), con el GPU falso; µs por draw, mediana de 5 frames; tres ensayos por fila
(`hilos/datos/tanda2/drawbench-*`, `tanda3/db-*`). La fila «A73» lleva QoS IN fijada en un constructor
(`drawbench-in`; CPU al salir 0-3).

| Dónde | J | K | L |
|---|---|---|---|
| A53, 1,9 GHz | 57,0-59,0 | 84,9-85,3 | 50,0-50,3 |
| A73, 2,8 GHz, tal cual | 42,5-48,4 (y 178) | 53,7-62,5 | 34,6-41,2 |
| A73 con los otros tres ocupados (L2 viva) | 27,3-29,4 | 34,0-34,1 (y 108,6) | 19,3-20,2 |
| Host i5-7500, 3,3 GHz (n=1, máquina cargada con otras compilaciones) | 9,0 | 15,1 | 9,3 |

Los valores entre paréntesis son de un ensayo a los 2-3 minutos de un arranque (carga 17-21). Con la L2 viva el A73
es 2,5× un A53, lo esperable entre estos dos núcleos (Android usa 1024/433 = 2,4 para su capacidad).

**Descomposición de los «20×» frente al host**, con las cifras de `drawbench` (bucle cerrado): núcleo y reloj ~2,2×
(K: 15 → 34 µs); vaciado de la L2 1,6-1,8× (34 → 54-62 µs). En producción el hilo de render paga 126-160 µs por draw
(03 M2, M7; cronómetro de pared por draw, `HakiosMetalCA.m:5767-5778`), así que queda otro 2-3× que `drawbench` no
reproduce: el trabajo de CoreAnimation entre draws (más conjunto de trabajo), la L1 que se vacía también cada vez que
su propio núcleo entra en reposo, las 61-112 expulsiones y 66-105 migraciones por segundo, la memoria
write-combined y el plug-in ObjC [H, sin separar].

## 4. Por qué se vacía la L2

[O] Cadena exacta (código upstream de xnu-8796.141.3; ningún parche del port la toca: `git show HEAD:` da lo mismo):

1. `cpu_idle()` llama a `platform_cache_idle_enter()` antes de cada WFI en todo núcleo que no es de Apple
   (`osfmk/arm64/cpu.c:570-573`, `#if !defined(APPLE_ARM64_ARCH_FAMILY)`).
2. Sin `__ARM_COHERENT_IO__` (SWEET no lo define), `platform_cache_idle_enter()` hace `FlushPoU_Dcache()`
   (`osfmk/arm/caches.c:336-353`; la variante coherente, :529-532, está vacía). Es código heredado de plataformas que
   pierden la L1 en reposo (`up_style_idle_exit`); en núcleos Apple no se compila.
3. `FlushPoU_Dcache` pasa `CLIDR_EL1.LoUIS` a `DCACHE_SET_WAY` (`osfmk/arm64/caches_asm.s:401-411`). LoUIS es un
   **número de niveles** (los que hay que mantener para llegar al punto de unificación); en estos núcleos vale 1, solo
   la L1.
4. `DCACHE_SET_WAY` toma en x0 **el último nivel, base 0 e inclusivo** (su propio comentario, :142, y el bucle
   `cmp x1, x0` / `b.ls`, :166-168; `Flush_Dcache` le pasa 6 como «Maximum allowable caching level (0-based)»).
   Con LoUIS = 1 recorre el nivel 0 (L1) **y el 1 (L2)**: `dc cisw` sobre toda la L2 del cluster, que comparten los
   cuatro núcleos.
5. Linux recorre los mismos campos con límite exclusivo: `__flush_dcache_all` (arm64 v3.18, `arch/arm64/mm/cache.S:
   33-73`, `cmp x3, x10` / `b.gt` con x3 = LoC×2) y `v7_flush_dcache_louis` (`arch/arm/mm/cache-v7.S:99-116`, :173).
   Copias en `hilos/ref/`. Los caminos PoC (`FlushPoC_Dcache`, `CleanPoC_Dcache`, LoC = 2) recorren un nivel de más
   que no existe y no hacen daño; los PoU vacían la L2 de más.

Por qué no hace falta nada antes de WFI en este port: [O] Linux duerme estos mismos núcleos con `dsb sy; wfi` y nada
más (`arch/arm64/kernel/idle.c:23-33`, `cpu_do_idle`); el port no apaga nunca un núcleo (no hay PSCI `CPU_SUSPEND` ni
`CPU_OFF`: `SweetCPU::haltCPU` y `quiesceCPU` hacen panic, `SweetCPU.cpp`), y donde PSCI apaga un núcleo o un cluster
el firmware hace el mantenimiento (TF-A `psci_do_pwrdown_cache_maintenance`, `lib/psci/psci_common.c:1184`, en
`hilos/ref/`). [M] En el cluster E, con tres núcleos en WFI, la L2 conserva los datos del cuarto (§3.4): WFI no pierde
estado.

Hipótesis descartadas por la medida o el código: L2 apagada o sin habilitar (aparece entera, 2 MB, en cuanto los A73
no entran en reposo); atributos de memoria distintos por CPU (la memoria de usuario es `CACHE_ATTRINDX_WRITEBACK`,
MAIR índice 0 = 0xFF, `osfmk/arm/pmap/pmap.c:5701-5703`, y la misma L2 funciona con el mismo mapeo); escrituras del
port en ACTLR/CPUECTLR (no hay ninguna: `set_aux_control` no tiene llamadas); prefetcher apagado (la cadena aleatoria
no depende de él y la secuencial con relleno da 3 ns hasta 1,75 MB); reloj de la L2 aparte (la latencia de L2 con
relleno, 7-11 ns, es la normal de un A73).

No verificado: el valor exacto de `CLIDR_EL1` en cada tipo de núcleo (lo lee `kern.sweet_cpuregs` de 0344), y el
coste en µs de cada vaciado (`kern.sweet_idle_stats` de 0344).

## 5. Propuesta

### 5.1 Parches

- **0344** (en la serie): `kern.sweet_idle_cache` / boot-arg `sweet_idle_cache` (1 = como upstream, por defecto; 2 =
  solo L1; 0 = nada antes de WFI), `kern.sweet_idle_stats` (entradas en reposo y tiempo de vaciado por CPU) y
  `kern.sweet_cpuregs` (MIDR, MPIDR, CLIDR, CCSIDR de L1D, L1I y L2, CTR, SCTLR, TCR y MAIR leídos en cada CPU por
  llamada cruzada; solo registros arquitectónicos). Verificado: 0343-0347 aplican en orden sobre la base 0342.
- **0351** (`hilos/0351-sapphire-cpu-idle-no-cache-flush.patch`, verificado con `git apply` sobre la serie hasta
  0350, y las rutinas modificadas ensambladas aparte): por defecto nada antes de WFI (`sweet_idle_cache = 0`); los
  modos 1 (L1 + L2, lo de upstream, `sweet_FlushL1L2_Dcache`) y 2 (solo L1) quedan para medir; `CleanPoC_Dcache`,
  `CleanPoU_Dcache`, `FlushPoC_Dcache` y `FlushPoU_Dcache` convierten el número de niveles de CLIDR en el último nivel
  que pide `DCACHE_SET_WAY` (n − 1, nada si es 0).

### 5.2 Lista priorizada

| # | Cambio | Por qué | Experimento decisivo |
|---|---|---|---|
| 1 | 0351 (o `kern.sweet_idle_cache=0` con 0344) | Devuelve la L2 de 2 MB a los A73 y quita miles de vaciados por segundo | `memlat -q ui -n 3 curve` lanzado con `spawnfg`, sin relleno: escalón de L2 en 2 MB con 7-11 ns; `drawbench-in` K ≈ 34 µs; `homeswipe` A/B n≥3 con CPU por draw; `kern.sweet_idle_stats` antes y después |
| 2 | Esperar las fences por interrupción en lugar de sondear cada 50 µs (`msm_wait`, `SapphireGpu.cpp:3966-4000`; la SPI 177 de la GPU está deshabilitada, :593-602, :1196-1203) o, mientras, dormir hasta la hora prevista de fin | Es la primera fuente de entradas en reposo del cluster P (15-21 %; periodo 142-217 µs) | Entradas en reposo/s en P y despertares del hilo de espera con `kdsched`; latencia commit → fin |
| 3 | Los cuatro hilos del kernel de prioridad 81 que despiertan cada ~1,2 ms y el de ~0,7 ms (44-50 % de las entradas en reposo de P; §5.3): pasarlos a interrupción o a periodos adaptativos | Calor y expulsiones del hilo de render | Igual que 2, por hilo; temperatura en reposo frente a Android (informe 17 §4) |
| 4 | Poner nombre a los hilos del kernel (`thread_set_thread_name`) | Hoy no se distinguen en `thrsched` ni en kdebug; el reparto de §5.3 es por firma | Que `thrsched 0` los liste con nombre |
| 5 | Dar QoS y nombre a los hilos del driver (espera y diferido, `command.cpp:523`, `c_api.cpp:47`) | Hoy heredan; con `metal_defer=1` el hilo diferido puede caer en un A53 si se crea desde un hilo DF [H] | `thrsched` del proceso con `metal_defer=1`; CPU por draw del hilo diferido |
| 6 | `sweetsched`: dejar 15 hasta medir con 0351 | A/B 15/13 sin diferencia (§3.3); con la L2 arreglada los A73 rinden más y el balance puede cambiar | Repetir §3.3 con 0351 |

Contención de candados entre el hilo de render y el kernel de la GPU (informe del agente, `agente-kernel.md`):
`service_lock` es un `IOLock` que gira ~12 µs y luego duerme con empuje de prioridad; lo toman `GEM_NEW`, `SUBMIT`,
`GEM_CLOSE`, `CPU_PREP` y la copia al panel del vsync (prioridad 92), con limpiezas de caché, `tlb_flush` (giro ≤ 200
µs) y `IODelay` dentro. El hilo de render puede esperar detrás del vsync o de otro cliente; cuánto, sin medir (lo da
`kern.sweet_gpu_diag`).

### 5.3 Quién hace entrar en reposo al cluster P

[M] `kdwake.py` (`hilos/datos/tanda1/ab{1,3,4}*.wake.txt`, n=3): cada cambio a un hilo de reposo se carga al hilo que
deja la CPU. 2600-2700 entradas en reposo por segundo en P dentro de la ventana del swipe.

| Hilo | % de las entradas en reposo de P | Periodo mediano entre despertares | CPU por despertar | Candidato en el código [H] |
|---|---|---|---|---|
| backboardd, hilo de espera de fences (DF, corre a 46) | 15-21 % | 142-217 µs | 16-17 µs | `WAIT_FENCE` → `msm_wait`, sueños de 50 µs |
| kernel tid 155 (prioridad 81) | 12,5-12,9 % | 1,22-1,25 ms | 40-41 µs | bucles de 1 ms: `modem_watch` (`TopazModem.cpp:9301-9367`), `adsp_thread` (:14121-14210), `ud_dp_thread` en reposo (`sweet_usb.c:1883-1901`) |
| kernel tids 215, 233, 2300 (81) | 10,2-11,8 % cada uno | 1,18-1,23 ms | 22-23 µs | ídem |
| kernel tid 177 (81) | 4-7 % | 0,63-0,71 ms | 20-24 µs | sin identificar |
| kernel tid 213 (81) | 2,4-2,5 % | 68-79 µs | 18 µs | sin identificar |
| kernel tids 212 y 207 (81) | 1,4-2,6 % | 9,5 y 10,9 ms | 16-20 µs | táctil sin dedo (10 ms, `sweet_touch.c:1055-1103`), `net_thread` (10 ms) |
| thread_call kernel-high (92) | 1,1-1,2 % | 8,3 ms | 41-43 µs | vsync a 120 Hz (`SweetFramebuffer.cpp:681`) |
| `kdsched` (la propia traza) | 9-11 % | 17-20 µs | 7 µs | artefacto de la medida |

El port no enruta ninguna SPI de dispositivo (`pe_fiq.c` solo configura el redistribuidor; GPU, USB, táctil y vsync
van por sondeo o temporizador, `agente-kernel.md` §4), y `SweetCPU` registra las CPU sin `powergate_latency`, así que
`delay()`/`IODelay` duermen en lugar de girar (`machine_routines.c:2360-2373`): cada vuelta de un bucle corto es un
bloqueo, una interrupción de temporizador y dos cambios de contexto.

## 6. Protocolo de la siguiente tanda (kernel con 0344, o 0351)

En el teléfono (`/var/root/hilos/`, ya instalado): `memlat`, `spawnfg`, `drawbench`, `drawbench-in`, `kdsched`,
`thrsched`, `tnow`, `traza.sh`, `tanda2.sh`, `tanda3.sh`. Duración ~1 min por bloque.

```sh
# 1. registros y coste del vaciado (0344)
sysctl kern.sweet_cpuregs kern.sweet_idle_cache kern.sweet_idle_stats
# 2. curvas en A73 sin relleno con cada modo (n=3 por punto); 1 = como hoy
for m in 1 2 0; do sysctl -w kern.sweet_idle_cache=$m; sleep 2
  /var/root/hilos/spawnfg /var/root/hilos/memlat -q ui -n 3 curve > /var/tmp/hilos4/curve-P-m$m.txt; done
# 3. driver en A73 con cada modo, n=3
for m in 1 0; do sysctl -w kern.sweet_idle_cache=$m; for i in 1 2 3; do
  /var/root/hilos/spawnfg /var/root/hilos/drawbench-in --runs 5 --scene JKL > /var/tmp/hilos4/db-P-m$m-$i.txt 2>&1; done; done
# 4. A/B en la UI: metal_fps=1 en /var/tmp/metal.args, reiniciar backboardd una vez, y por modo alternado
#    (1 0 1 0 1 0) /var/root/hilos/traza.sh abN-mM 4  (kdebug + consola del driver durante homeswipe.sh 4)
sysctl kern.sweet_idle_stats
```

Predicción si §4 es correcto: con 0 (o 2), curva del A73 con L2 de 2 MB a 7-11 ns sin relleno, `drawbench-in` K ≈ 34
µs, `kern.sweet_idle_stats` con tiempo de vaciado ~0, y CPU por draw de producción por debajo de 126-160 µs. Con 2
debe quedar parecido a 0 en la curva (la L2 sobrevive) y algo peor en el hilo de render (su L1 se vacía en cada
reposo).

**Referencia en Android** (mismo hardware con el kernel de Linux): `hilos/tools/memlat-linux-aarch64` (estático,
`zig cc -target aarch64-linux-musl -static -O2`, zig 0.14.1 en `~/sapphire-angel/toolchain/zig/`). Con el puente
`adbbridge`:

```sh
adb push memlat-linux-aarch64 /data/local/tmp/memlat && adb shell chmod 755 /data/local/tmp/memlat
adb shell /data/local/tmp/memlat -c 6 -n 3 curve      # A73 (cpu6 de Linux)
adb shell /data/local/tmp/memlat -c 2 -n 3 curve      # núcleo pequeño (cpu2)
adb shell /data/local/tmp/memlat -c 6 -n 3 ret ; adb shell /data/local/tmp/memlat -c 2 -n 3 ret
adb shell /data/local/tmp/memlat -c 6 regs            # CTR_EL0 (en Linux se lee desde EL0)
```

`-c` fija la CPU con `sched_setaffinity`; sin root el gobernador `walt` decide la frecuencia (las latencias en ns
cambian con ella, los escalones no).

## 7. Hallazgos laterales

- `CTR_EL0` no se puede leer desde EL0 en iOS aquí (SIGILL en los dos tipos de núcleo) aunque `SCTLR_EL1.UCT` = 1
  (`machdep.cpu.sysreg_SCTLR_EL1` = 0x34d4d93d): [H] lo atrapa el hipervisor de Qualcomm (`HCR_EL2.TID2`).
- El `memcpy` de 1,5 GB/s de 11 §10.3 es compatible con un A53 a prioridad 4 (lanzado por SSH) con la L1 y la L2
  vaciándose al dormir: aquí 1,18-1,47 GB/s de DRAM a DRAM en A53 y 1,59 GB/s en A73; una copia de 96 KB, que cabe
  en L2, da 7,1 GB/s en A53 y 2,8-3,6 GB/s en A73 sin L2.
- La traza kdebug cuesta: ~180 000 eventos/s con este filtro (el sondeo del kernel genera la mayor parte).
