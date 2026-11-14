# 16 — Planificador e hilos: dónde corre el trabajo de la interfaz, 2026-11-14

Informe fechado. Pregunta: ¿está bien repartido el trabajo entre núcleos e hilos? El cuello medido de la UI es CPU
de un solo hilo (`com.apple.coreanimation.display.primary` de backboardd, 84-90 %, 126-160 µs por draw del driver
Metal; 03 M1, M2, M6, M7). Árbol de referencia: xnu-8796.141.3 con los parches 0001-0342 aplicados en orden
(`~/sapphire-angel/research/metal/hilos/xnu-0342`, construido desde el árbol a 0338 más 0339-0342 con
`git apply --check`; coincide archivo a archivo en `osfmk/`, `iokit/` y `bsd/` con `relojes/xnu-0342`). Kernel
que corre el teléfono: CI run 43620776409 (`kernel.development.sweet`, configuración **DEVELOPMENT**).

Convención de evidencia: **[O]** observación propia (código con `archivo:línea` o medida propia reproducible),
**[M]** medida del teléfono tomada en esta investigación (archivo crudo citado), **[H]** hipótesis sin medir.
Rutas de código relativas a `xnu-0342/` salvo que se diga otra cosa.

**Estado: en curso.** Este archivo se amplía a medida que avanza.

## 1. Topología

**En XNU las CPU lógicas 0-3 son los cuatro Cortex-A73 y las 4-7 los cuatro Cortex-A53: la numeración es la inversa
de la de Linux.** Los contadores del driver que dicen `cpu0 … cpu3` hablan de CPU lógicas de XNU (la de
`TPIDR_EL0`, que el kernel escribe en cada cambio de contexto: `osfmk/arm64/cswitch.s:182-183`, `locore.s:949-950`).

| CPU lógica XNU | MPIDR (`reg` del ADT) | Núcleo | Linux (Android) | Cluster XNU | `cluster-type` | Perf. state al arrancar | pset |
|---|---|---|---|---|---|---|---|
| 0 (arranque) | 0x100 | Cortex-A73 (part 0xd09) | cpu4 | 0 | `P` | gold 8 = 2803 MHz | pset0, `PSET_AMP_P` |
| 1-3 | 0x101-0x103 | Cortex-A73 | cpu5-7 | 0 | `P` | ídem | pset0 |
| 4-7 | 0x0-0x3 | Kryo «Silver» part 0x801 (Cortex-A53) | cpu0-3 | 1 | `E` | silver 6 = 1900 MHz | `PSET_AMP_E` |

Cómo se llega a esa tabla:

- [O] El ADT lo genera `tools/mkadt.py:138-170` (repo): con `--amp`, nodos `cpu0`-`cpu3` con `reg` = 0x100|n y
  `cluster-type` 'P', y `cpu4`-`cpu7` con `reg` = n y 'E'. [M] El ADT del teléfono es ese (`ioreg -p IODeviceTree`,
  `hilos/datos/ioreg-cpus.txt`): `cpu0@100` … `cpu3@103` con `logical-cpu-id` 0-3, `cluster-type` 'P',
  `logical-cluster-id` 0; `cpu4@0` … `cpu7@3` con 4-7, 'E', 1.
- [O] `ml_parse_cpu_topology` (`osfmk/arm64/machine_routines.c:944-1108`) numera las CPU por orden del ADT
  (`cpu_id = num_cpus++`, :1016), toma el MPIDR de `reg` (:1023) y el tipo de `cluster-type` (:1036-1041). Sin
  `HAS_CLUSTER` (SWEET no lo define, `pexpert/pexpert/arm64/SWEET.h`), el cluster físico es `cluster_type == P`
  (:1053) y el lógico se asigna por orden de aparición (:1056-1057): P = cluster 0, E = cluster 1.
- [O] `SweetCPU::startAll` (`iokit/Kernel/arm/SweetCPU.cpp:126-181`) exige que el arranque sea la CPU lógica 0 con
  MPIDR 0x100 (:151-154) y enciende cada CPU con PSCI `CPU_ON(target = reg)` (:249), es decir, el firmware enciende
  el núcleo físico que tiene ese MPIDR. Después comprueba que una SGI dirigida a ese MPIDR (afinidad del destino,
  :221-226) llega a esa CPU (`sweet_cpu_signal_is_enabled`, :164). [M] Ring de este arranque
  (`hilos/datos/ring-boot.txt`): `cpu=0 mpidr=0x100 came alive`, `cpu=1 CPU_ON target=0x101 … rc=0`, … `cpu=7
  CPU_ON target=0x3 … rc=0 … came alive; SGI1 OK`, y después `SWEET SCHED: mode 0xf (P cluster 0, E cluster 1)`.
- Fuente primaria del lado del hardware: el DT de Android de este teléfono (`relojes/dtb/merged-khaje24a-sapphire.dts`
  :39-259) pone `cpu@0`-`cpu@3` (MPIDR 0x0-0x3) en el dominio de frecuencia 0 con `capacity-dmips-mhz` 1024 y
  `cpu@100`-`cpu@103` en el dominio 1 con 1638; Android en este teléfono (`research/metal/android/estado-reposo.txt`)
  da `CPU part 0x801`, capacidad 433, hasta 1900,8 MHz para cpu0-3 y `0xd09` (Cortex-A73), capacidad 1024, hasta
  2803,2 MHz para cpu4-7.
- [O] Frecuencias: `sweet_cpufreq` escribe el índice máximo del LUT de cada dominio de `qcom,cpufreq-hw`; ring:
  `gold perf state 8 -> 8 (2803 MHz)`, `silver perf state 6 -> 6 (1900 MHz)` (11 §12). Lo que el núcleo corre de
  verdad se mide en §3.1.
- [O] Lo que ve el planificador: `processor_bootstrap` (`osfmk/kern/processor.c:196-221`) hace de pset0 el cluster de
  arranque, de tipo `PSET_AMP_P`; `ml_processor_register` (`machine_routines.c:1433-1449`) crea el pset del cluster E
  como `PSET_AMP_E` en `pset_node1`; `sched_edge_pset_init` (`osfmk/kern/sched_clutch.c:3549-3563`) traduce a
  `CLUSTER_TYPE_P`/`E`. [M] `hw.perflevel0` = Performance, 4 CPU, L2 2 MiB; `hw.perflevel1` = Efficiency, 4 CPU,
  L2 512 KiB. La clasificación es correcta.
- Sin efecto en el planificador, pero falso: el ADT del teléfono da `clock-frequency` = 2 803 200 000 también a los
  A53 (`<007015a7>` en los ocho nodos); `mkadt.py:164` escribe 1 900 800 000 para ellos, así que el ADT instalado
  sale de una versión anterior del generador. El Edge no usa capacidades por núcleo: solo el tipo de cluster.

## 2. Planificador

### 2.1 Cuál corre

[M] `kern.sched` = `edge`. [O] `osfmk/arm64/proc_reg.h:85-99` activa `CONFIG_SCHED_EDGE` solo con `__ARM_AMP__`, y
`SWEET.h` define `__ARM_AMP__` cuando se compila con `TOPAZ_4K` (parche 0217); `MAX_CPU_CLUSTERS` = 2
(`board_config.h:105-109`). El despacho es `sched_edge_dispatch` (`osfmk/kern/sched_prim.h:816-822`). No hay CLPC:
nada llama a `sched_perfcontrol_thread_group_recommend` (`osfmk/kern/thread_group.c:1300-1332`) ni a
`sched_edge_matrix_set` (`sched_clutch.c:3498-3511`), así que las preferencias de cluster son estáticas.

### 2.2 Cómo decide dónde va un hilo

1. **Bucket del hilo** (`sched_clutch.c:296-345`): tiempo real, o modo fijo con prioridad ≥ 47 → `FIXPRI`; si no,
   por prioridad base: > 37 `FG`, 32-37 `IN`, 21-31 `DF`, 5-20 `UT`, ≤ 4 `BG`. La QoS solo entra a través de la
   prioridad que da (UI 47, IN 37, DF 31, UT 20, BG 4).
2. **Cluster preferido** = el que guarda el grupo de hilos (thread group) para ese bucket
   (`sched_edge_thread_preferred_cluster`, :1232-1246). Se fija al crear el grupo (`sched_clutch_bucket_group_init`,
   :1144) y solo lo cambia CLPC… o `kern.sweet_sched` (§2.3). Sin 0303 es `pset0` para todos los buckets, y aquí
   pset0 es el cluster P: la nota heredada «el Edge sin CLPC prefiere pset0 para todo» es correcta para el código.
3. **Elección del cluster** (`sched_edge_migrate_candidate`, :4450-4532, llamado desde
   `sched_edge_choose_processor`, :4535-4566): un hilo de tiempo real se queda siempre en el preferido (:4484-4487);
   si la carga del preferido es 0 también (:4489-4492); si no, se miran las aristas del preferido
   (`sched_edge_migrate_edges_evaluate`, :4285-4355; `sched_edge_migration_check`, :4175-4228): un cluster destino
   con migración permitida y carga 0 gana al momento; con carga, solo si la diferencia supera el peso de la arista.
4. **Carga** (`sched_update_pset_load_average`, `sched_prim.c:8114-8180`): profundidad = (hilos en cola de bucket ≥ b
   + CPUs ejecutando bucket ≥ b + cola RT) / CPUs del cluster, **en división entera**: con 4 CPUs es 0 hasta que hay
   4 hilos de ese nivel o superior; se multiplica por el tiempo medio de ejecución del bucket. «Carga 0» quiere decir
   «menos de 4 hilos de ese nivel en el cluster».
5. **Dentro del cluster** (`choose_processor`, `sched_prim.c:5025-5260`): una CPU ociosa primero; si no, la que corre
   algo de menor prioridad (expulsión inmediata). Los hilos de tiempo real recorren solo los psets de su nodo
   (:5150-5225), y P y E están en nodos distintos (`processor.c:209-221`): **el tiempo real nunca sale del cluster P**.
6. **Al quedarse ociosa una CPU** (`sched_edge_processor_idle`, :4017-4050): primero roba hilos «extranjeros» de su
   tipo que esperan en el otro cluster, luego de su propio tipo, luego expulsa a los extranjeros que corren fuera
   (`sched_edge_balance`, :4127-4166) y por último roba según aristas (`sched_edge_steal_thread`, :3973-4012), lo que
   entre tipos distintos exige carga > 0 en el origen (`sched_edge_steal_possible`, :3954-3971).
7. **Al final de cada quantum**, un hilo que corre en un cluster de tipo distinto al preferido se devuelve
   (`sched_edge_thread_avoid_processor`, :4096-4125).

### 2.3 `sweetsched` / `kern.sweet_sched` (parche 0303), bit a bit

Código: `sched_clutch.c:4869-4930` y :4974-4983, `thread_group.c:1334-1352`, `bsd/kern/kern_sysctl.c:2523-2540`.

| Bit | Efecto en el código | Línea |
|---|---|---|
| 1 | Buckets `UT` y `BG` de cada grupo prefieren el cluster E | `sweet_sched_bucket_cluster`, :4883-4893 |
| 2 | Bucket `DF` (QoS por defecto, prioridad 21-31) también prefiere E | ídem |
| 4 | Aristas P→E: sin migración y sin robo (`sce_migration_allowed = sce_steal_allowed = 0`); sin el bit: peso 64, ambos permitidos (lo de serie) | `sweet_sched_edges`, :4896-4920 |
| 8 | Arista E→P: robo permitido (una CPU P ociosa toma hilos que esperan en E si la carga de E > 0); la migración E→P sigue prohibida | ídem |

Aristas de serie (`sched_edge_cpu_init_completed`, :4933-4972): P→E peso 64 con migración y robo; E→P nada.

Con **15**, lo que vale hoy en el teléfono ([M] `kern.sweet_sched: 15`, boot-arg `sweetsched=15`):

| Bucket | Cluster preferido | ¿Puede ir al otro? |
|---|---|---|
| FIXPRI (fijo ≥ 47, tiempo real), FG, IN | P (A73) | **Nunca** a E, aunque los cuatro A73 estén ocupados (bit 4) |
| DF, UT, BG | E (A53) | A P solo si una CPU P está ociosa **y** E tiene carga > 0, es decir ≥ 4 hilos de ese nivel o superior en E (bit 8) |

**Qué se puede cambiar sin reiniciar: todos los bits.** El sysctl llama a `sweet_sched_set` (:4925-4930): guarda el
modo, reescribe las aristas (bits 4 y 8) y aplica las preferencias (bits 1 y 2) a **todos** los grupos de hilos
existentes con `MIGRATE_RUNNING | MIGRATE_RUNNABLE` (`thread_group.c:1338-1352`), es decir, los hilos que corren o
esperan se mueven al momento. Diferencia con el boot-arg: el boot-arg se aplica en `sched_edge_cpu_init_completed`
(:4974-4983) antes de que exista ningún proceso ([M] ring: `SWEET SCHED: mode 0xf` sale antes del copyright de BSD),
así que los grupos creados antes (`system`, `background`, `VM`, `io storage`, `perf_controller`:
`thread_group.c:130-142`, los del kernel) se quedan con P para todos los buckets; una escritura en caliente los mueve
también. Volver a 15 en caliente deja por tanto un estado ligeramente distinto del de arranque (solo afecta a hilos
del kernel con prioridad < 47 en esos grupos).

## 3. Medidas en el teléfono

(en curso)

## 4. Diagnóstico y propuesta

(en curso)
