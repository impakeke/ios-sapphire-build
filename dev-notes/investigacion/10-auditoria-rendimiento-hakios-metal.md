# 10 — Auditoría de rendimiento y arquitectura de hakios-metal (userland), 2026-11-14

Informe fechado. Alcance: la parte userland del driver Metal que dibuja la pantalla con `sweetmetal=2`
(`hakios-metal` + el plug-in ObjC que sirve a CoreAnimation), leída como revisor de un driver gráfico de producción.
El lado kernel está en el informe 09, los relojes de la GPU en el 11 y la identidad binario↔fuente en el 08.

Convención de evidencia:
**[O]** observación propia (código con `archivo:línea`, o medida propia reproducible);
**[M]** medida en el teléfono tomada por el agente de medición (archivo crudo citado);
**[H]** hipótesis razonada, sin medir;
**[HEREDADO]** afirmación de README, comentarios o notas de HackiOS o del autor del port que no se ha vuelto a medir.

## Resultado en breve

Ordenado por ganancia esperada. Las cifras en ms son por frame en movimiento (~150 draws) salvo que se diga otra cosa.

1. **El hilo de render de CoreAnimation gasta ~19 ms por frame dentro del driver, en CPU** [M]: 111-139 µs por draw
   × 115-223 draws. La causa es de arquitectura: cada draw se valida entero, genera de nuevo 300-600 palabras de
   estado en un stream temporal y después las filtra registro a registro (§2.1-2.2). El mismo código cuesta 3,4-6,4 µs
   por draw en el host [O]; Mesa cuesta ~1,5 µs por draw en este mismo teléfono [HEREDADO, `NOTES.md:312-313`].
   Diseño propuesto: encoder con estado, objetos de estado precalculados por (pipeline, pase), emisión incremental
   (§2.6); plan por función en tres etapas (§2.7). Objetivo: < 5 µs por draw, < 1 ms por frame.
2. **La pasada principal tarda 20-24 ms de GPU** [M] (18 ms en reposo) **y el driver hace que la GPU ejecute el
   estado de todos los draws en cada tile**: 102 tiles de 768 × 16 píxeles, sin grupos `CP_SET_DRAW_STATE` y sin
   retorno anticipado del cuerpo. Un frame de 108 draws son 490 035 palabras para el procesador de comandos, con
   55 620 cargas de estado, frente a 4 938 palabras de los mismos draws en sysmem [O, §3.1-3.2]. Con el dibujo fuera
   del hilo de render (`metal_defer=1`) los buffers suben de 23,7 a 28 por segundo y las pasadas del driver ocupan ya
   el 70-79 % del tiempo de la GPU [M, §1.1].
3. **El reparto de tiles es peor que el de la referencia**: el algoritmo de turnip da 78-84 tiles para el mismo pase
   (dos attachments) y 39-42 si solo se toca uno; el del port, 102 y 51. Un pase con tres attachments de 4 bytes no
   cabe y cae a sysmem (§3.1).
4. **Las pasadas a tamaño completo que quedan en sysmem tardan 20,7-26,0 ms con 30-53 draws** [M, n = 22]. La regla
   que las deja ahí cuenta draws; turnip fuerza GMEM cuando hay framebuffer fetch, y 98 de las 170 variantes del
   shader de CoreAnimation en la caché del teléfono lo usan [O, §3.3, §3.5].
5. **Grabación doble**: todo pase candidato a GMEM se codifica dos veces (tiles y sysmem) y se decide al cerrarlo.
   En host cuesta ×1,9 por draw [O, §2.4].
6. **Un `usleep(2000)` en el hilo de render**, hasta 1 500 veces, cuando un draw llega antes de que su variante
   especializada esté compilada (§3.7, §4.3).
7. **Sin caché de buffers**: cada `MTLBuffer` y cada textura es un `GEM_NEW`; [M] 34-68 nuevos cada 2 s en scroll.
   `setVertexBytes:`/`setFragmentBytes:` crean un buffer por llamada (§4.2).
8. **Cada pase paga un arranque completo de estado, 3 `CP_WAIT_FOR_IDLE` y 2 esperas en stream** que turnip no
   emite; hasta 11 pases por buffer [M] (§4.1).
9. **`metal_gmem=0` no desactiva GMEM en este binario** [O + M]: el interruptor es `metal_gmem_draws=0` (§3.9).

Lo que esta auditoría no separa: cuánto de los 20-24 ms de la pasada principal es procesador de comandos, cuánto
coste fijo por tile y cuánto píxeles. §3.9 lista los ensayos con boot-args existentes que lo separan.

## 0. Qué se auditó y con qué referencia

| Cosa | Dónde | Identificación |
|---|---|---|
| Fuente del port al A610 (la que se cita por defecto) | `~/sapphire-angel/research/metal/rebuild/hakios-angel/` | `Angelpro09xd/hakios-xnu-kernel`, rama `sapphire-a610`, `5c3bd9a`; 6 commits sobre HackiOS `63fc2b4` |
| Fuente de HackiOS (base) | `~/sapphire-angel/research/metal/hakios-xnu-kernel/` | `oosexgang/hakios-xnu-kernel` @ `63fc2b4` (2026-11-06) |
| Núcleo C++ | `hakios-metal/src/{render,command,texture,c_api,compiler,gpu,link}.cpp`, `include/hakios-metal/*.hpp` | — |
| Plug-in que sirve a CoreAnimation | `userland/src/HakiosMetalCA.m` (9 370 líneas en el port) | — |
| Referencia primaria | `~/sapphire-angel/research/metal/auditoria-userland/mesa/` | Mesa upstream @ `767fbf7c6492f64549c90e9a080ab5417895a9ec` (2026-11-13) |
| Catálogo KGSL de Qualcomm | `~/sapphire-angel/research/metal/relojes/ref/downstream/kgsl-5.x/adreno-gpulist.h` | árbol del agente de relojes |
| Binario que corre | `/System/Library/Extensions/HakiosMetal.bundle/HakiosMetal` | 8 630 976 bytes; su relación con `5c3bd9a` es materia de 08 |

Abreviaturas de cita: `render.cpp:N`, `command.cpp:N`, `c_api.cpp:N`, `compiler.cpp:N`, `gpu.cpp:N`, `texture.cpp:N`,
`link.cpp:N`, `fake_gpu.cpp:N` son `hakios-metal/src/` del port; `command.hpp:N`, `a6xx.hpp:N`, `render.hpp:N`,
`fake_gpu.hpp:N` son `hakios-metal/include/hakios-metal/`; `CA.m:N` es `userland/src/HakiosMetalCA.m` del port;
`mesa:ruta:N` es el clon de Mesa en el commit de la tabla.

**[O] El README de hakios-metal no describe el código.** Lista «GMEM (tiled) rendering … several colour attachments»
entre lo rechazado (`hakios-metal/README.md:94-100`) y dice «every draw here is a pass of its own» (`:135-136`). El
código tiene pases compartidos entre draws (`render.cpp:2865-2874`), GMEM por tiles con binning por hardware
(`render.cpp:2176-2537`), elección GMEM/sysmem por historial (`render.cpp:2902-2931`), grabación diferida
(`c_api.cpp:45`) y caché de stages en disco (`compiler.cpp:1194-1314`). Nada de lo que sigue se apoya en el README.

**Material propio (fuera de git), `~/sapphire-angel/research/metal/auditoria-userland/`:**

- `framecount.cpp`: graba frames sintéticos con `CommandBuffer::draw` configurado como lo configura el plug-in y
  cuenta peticiones al kernel, paquetes PM4 (siguiendo los `CP_INDIRECT_BUFFER`) y asignaciones de heap. Binarios
  `framecount-a610` (constantes del A610) y `framecount-port`; salidas `framecount-a610*.out`.
- `hm/`, `hm-port/`: copias de trabajo de la base y del port, compiladas en este Mac (Apple clang 21, x86_64, sin
  Mesa). [O] La base pasa sus 261 tests con 0 comprobaciones fallidas. El árbol del port da 262 tests con **44
  comprobaciones fallidas en 8 tests**: el port regeneró los fixtures de stages para el A610 (sin prefetch del FS,
  otros registros; 109 archivos de `tests/fixtures/` cambian respecto de `63fc2b4`) y `link_test.cpp` y
  `render_test.cpp` siguen esperando los del A635. La suite es la red de seguridad de todo lo que se propone aquí:
  lo primero es dejarla en verde en el árbol del port.
- `stage-cache/`: copia de solo lectura de la caché de stages del teléfono (derivada de shaders de Apple: fuera de git).
- `disasm/`: desensamblador ir3 de host (el `ir3-isa.c` generado por Mesa 25.0.7), `parse_stage.py`, `stages.txt`.

## 1. Datos medidos

### 1.1 En el teléfono

**[M] Perfil de pila del hilo de render** (`com.apple.coreanimation.display.primary` de backboardd, 17 958 muestras a
0,5 ms durante el swipetest; `~/sapphire-angel/research/metal/medicion/perfil-1.txt`):

- 90,3 % de las muestras en modo usuario; 5,05 % en traps de IOKit.
- Del tiempo de usuario: HakiosMetal 47,2 % (self), QuartzCore 26,8 %, `libsystem_malloc` 9,4 %,
  `libsystem_platform` (memmove/memset) 8,2 %, `libobjc` 3,9 %.
- Inclusivo por la ruta de draw: `hakiosDraw` 57,8 % → `drawCommon` 52,9 % → `CommandBuffer::draw` 45,4 % →
  `encodeDraw` 24,1 % (8,8 % self) y `appendDeduped` 10,1 % (7,1 % self); `bindArgumentBuffers` 3,4 %;
  `programAddress` 2,3 %; `stageTextures` 2,2 %; `checkTarget` 1,2 %; `link` 1,0 %; `vertexFetch` 0,9 %;
  `checkStage` 0,9 %; `pushedRanges` 0,8 %.

**[M] Contadores del propio binario** (`metal_fps` en `/var/tmp/metal.args`, que `hm_bootargs` añade a los boot-args,
`CA.m:114-139`; `medicion/cons-fps1-a.txt`):

| Magnitud | Reposo | Durante swipes |
|---|---|---|
| command buffers por segundo | 10 | 16-31 |
| draws por command buffer | 108 | 115-223 |
| pasadas por command buffer | 1,0 | 3,0-11,4 |
| CPU del driver por draw («of ours» / «the core's») | 99 / 93 µs | 111-139 / 104-130 µs |
| «a buffer made to committed» (media) | 14,9 ms | 21,9-43,7 ms |
| `-commit` en el hilo que llama, por buffer | 2,4 ms | 2,3-3,2 ms |
| «commit to completion» (media) | 21,0 ms | 21,9-35,4 ms |
| pasada principal `750x1624`, 108-132 draws, **102 tiles** | 18,0-18,2 ms | 20,4-24,2 ms |
| otra pasada: `752x1626`, 35 draws, sysmem | — | 31,96 ms |
| GEM nuevos por periodo de 2 s | 0 | 34-68 (0,8-35,7 MB) |

Además: `0 presented` (backboardd no usa `presentDrawable:`), `0 waits for completion`, y los draws se ejecutan en
los procesadores lógicos 0-3.

**[M] Ensayos A/B** (`medicion/ab/ab-*.txt`, tres capturas por condición durante `swipetest.sh 5`, resumidas con
`medicion/ab-sum.py` sobre los periodos con movimiento; los argumentos de cada etiqueta son los que indica el agente
de medición, las capturas no los registran):

| Condición | buffers/s | CPU por draw en el hilo que llama | hecho→commit | commit→fin | pasada principal, 97 / 112 draws (mediana) |
|---|---|---|---|---|---|
| base | 23,5-23,8 | 126-128 µs | 28,9-29,7 ms | 31,2-33,0 ms | 21,0 / 23,5 ms |
| `metal_gmem=0` | 23,7-24,3 | 126-127 µs | 28,9-29,0 ms | 30,9-32,4 ms | 20,8 / 23,6 ms (sigue en 102 tiles) |
| `metal_gmem_off=16` (sin binning) | 22,7-23,1 | 124-126 µs | 30,5-30,8 ms | 41,9-44,2 ms | 25,1 / 29,1 ms |
| `metal_defer=1` | 27,6-28,4 | 46-47 µs | 22,9-24,5 ms | 59,9-61,9 ms | 21,3 / 24,1 ms |
| `metal_defer=1 metal_gmem_off=8` | 26,0-27,5 | 44-46 µs | 23,3-26,8 ms | 54,8-63,4 ms | 21,6 / 24,4 ms |

Lecturas [O sobre esas capturas]:

- La suma de las pasadas cronometradas por la GPU es 23,5-26,9 ms por command buffer (mediana por captura) en base y
  23,7-25,3 ms con `metal_defer=1`; ocupa el 58-60 % del tiempo en base y el 70 % (hasta el 79 %) con `metal_defer=1`.
  A eso se suma la copia a panel del kernel (informe 09 §2.2), que estos contadores no ven.
- `metal_gmem=0` no cambia nada: las 191 pasadas principales listadas siguen «in 102 tiles» (§3.9).
- Sin binning la pasada principal sube 4,1 ms con 97 draws y 5,6 ms con 112.
- Con `metal_defer=1` el hilo que llama paga 46-63 µs por draw, de ellos 22-31 «the core's» (la copia del draw a una
  clausura, `c_api.cpp:1538-1546`).
- Entre las cuatro pasadas más lentas de cada periodo aparecen 22 pasadas sysmem a `750x1624` con 30-53 draws:
  20,7-26,0 ms cada una, con motivo «N draws, fewer than metal_gmem_draws=56».
- «GPU busy» suma `completedAt − committedAt` de cada buffer (`command.hpp:81`): por encima del 100 % significa
  buffers en cola, no una GPU al 150 %.

**[O] Lecturas ligeras propias en el teléfono (2026-11-14):**

- `kern.bootargs` no lleva ningún `metal_*`. La caché `/private/var/db/hakios-metal-cache` tiene 194 `.stage` y 8
  `.keys`; el directorio semilla `/redwood/share/hakios-metal-cache` (`CA.m:619`) no existe.
- Árbol de dispositivos (`ioreg -p IODeviceTree -n cpus`): `logical-cpu-id` 0-3 son `cpu0@100`…`cpu3@103` con
  `cluster-type` `P`; 4-7 son `cpu4@0`…`cpu7@3` con `cluster-type` `E`. Los draws corren en el clúster P.

**Otros informes del mismo día:** el 11 concluye por código que el núcleo de la GPU corre a 630 MHz, la mitad del
nivel máximo de Android; todos los tiempos de GPU de aquí están tomados en esa condición. El 09 describe la copia a
panel por frame, las fences por sondeo y el coste de `GEM_NEW`.

### 1.2 En el host (fake GPU)

`framecount-a610` configura el `CommandBuffer` como el plug-in sin boot-args (`CA.m:5321-5331`: GMEM permitido,
`gmemMinDraws` 56, binning y `tuned` activos) y descodifica el stream que llega al submit. Port `5c3bd9a`,
`-DHAKIOS_CHIP_A610`, `-O2`, x86_64; tiempos de 6 ejecuciones.

| Escena (blanco 750 × 1624 BGRA8) | palabras que lee el CP | `CP_WAIT_FOR_IDLE` | esperas en stream sobre una palabra | `CP_LOAD_STATE6*` | asignaciones de heap por draw | µs por draw (mín-máx; mediana) |
|---|---|---|---|---|---|---|
| G. 1 draw, 1 pase, 1 buffer | 601 (302 registros) | 4 | 2 | 5 | 30 | 23-35; 34 |
| H. G con Clear | 653 | 5 | 3 | 5 | 31 | — |
| A. 20 draws con blending, sysmem | 1 414 | 4 | 2 | 94 | 7,2 | 4,2-7,2; 4,7 |
| B. A con 5 draws de framebuffer fetch | 1 561 | 14 | 7 | 99 | 7,3 | 4,4-6,3; 4,4 |
| D. 143 draws en 4 pases, todo sysmem | 8 071 | 13 | 8 | 669 | 5,9 | 3,4-4,4; 3,5 |
| C. D con el pase principal (1 attachment) en GMEM: 51 tiles | 316 800 | 68 | 10 | 36 415 | 10,6 | 6,3-7,6; 6,6 |
| **P. pase principal del teléfono**: 108 draws, 2 attachments, grabado doble, GMEM: **102 tiles** | **490 035** (92 928 registros) | 110 | 4 | **55 620** | 10,4 | 6,1-8,9; 6,4 |
| Q. P con cada 4.º draw de framebuffer fetch | **768 853** | **5 568** | 4 | 58 298 | 12,9 | 7,6-10,7; 8,4 |
| R. los 108 draws de P grabados una vez, en sysmem | 4 938 (974 registros) | 4 | 2 | 540 | 6,3 | 3,25-3,57; 3,4 |

[O] La escena P reproduce el recuento del teléfono (102 tiles). Lleva 11 124 `CP_DRAW_INDX_OFFSET` (108 × 103: el
paso de binning y 102 tiles) y 204 eventos `BLIT` (102 cargas y 102 guardados del attachment 0).
[O] En la base de HackiOS (`63fc2b4`) las mismas escenas dan 20-34 asignaciones de heap por draw.

Límite del modelo [O]: el fake GPU acumula las cargas de constantes de todo un submit y las compara con el `constlen`
de cada draw posterior (`fake_gpu.cpp:832-860`), así que una escena que mezcla programas con y sin constantes da un
fallo que no es del stream (la escena Q informa de 2). Los recuentos se toman antes de ejecutar y no dependen de eso.
El fake modela 512 KiB de GMEM sea cual sea el chip (`fake_gpu.hpp:193`).

### 1.3 Caché de stages del teléfono (`disasm/stages.txt`)

[O] 194 stages: 170 variantes especializadas del shader de fragmento «uber» de CoreAnimation (`fixed_frag_lph_cph`
117, `fixed_frag_lph_cpf` 53) y 24 más (blur, downsample, vértices).

- **98 de las 170 variantes leen el blanco** (`fbRead`): las 53 `_cpf` y 45 `_cph`. En el desensamblado es un `isaml`
  del slot del blanco seguido de la mezcla en el propio shader: blending programable.
- Salidas de color: 1 en 94 variantes, 2 en 23, 3 en las 53 `_cpf`.
- Tamaño: 32-576 palabras, es decir 1-18 unidades de 16 instrucciones, relleno de `nop` incluido; mediana 96. La
  entrada genérica sin especializar tiene 32 064.
- `numTextureSlots`: 15 en las 53 `_cpf`, 10 en 16, 4-5 en 60, 0-2 en 41; el código muestrea 1-3.
- Ninguna usa prefetch (el A610 no lo tiene), `kill` ni memoria privada.

### 1.4 Lectura conjunta

Dos cuellos, cada uno suficiente para dejar la interfaz por debajo de 30 fps:

- **A, CPU del hilo de render:** 126 µs × ~152 draws ≈ 19 ms de driver por buffer, más 2,3-3,2 ms de `-commit`; el
  buffer tarda 29 ms de creado a enviado [M].
- **B, GPU:** 23,5-26,9 ms de pasadas por buffer, de ellos 20-24 la principal [M]. Con el cuello A apartado
  (`metal_defer=1`) la cadencia sube solo a 28 buffers/s.

## 2. Cuello A — CPU por draw

### 2.1 Qué hace hoy un draw

| Capa | Función | Trabajo por draw | % inclusivo [M] |
|---|---|---|---|
| ObjC | `-hakiosDrawOnce:` (`CA.m:8806`) | reúne los handles de cada slot; `hakiosProgramFor:` (`CA.m:7821`): hash FNV byte a byte de 48 bytes del buffer de uniformes y un `memcmp` de los mismos 48, leídos de memoria write-combined (`CA.m:7751-7756`, `:7831-7836`); `strstr` sobre el nombre del programa (`CA.m:8724-8728`, llamado en `:8934`) | 57,8 − 52,9 = 4,9 |
| API C | `drawCommon` (`c_api.cpp:1334-1471`) | rellena dos `Bindings`, `bindArgumentBuffers` × 2 (`:1387-1388`), `passOf` (`:1394`), construye `Draw`, `keep`/`keepAlive` por recurso (`:1457-1469`) | 52,9 − 45,4 = 7,5 |
| Núcleo | `CommandBuffer::draw` (`render.cpp:2794-3122`) | `freshen` × 2, textura nula, `programAddress` × 2, pieza de tabla de 8 KiB, comparación de pase, `gmemDrawOk`, clave estática, `encodeInPass` (× 2 si `dual`), `appendDeduped` (× 2 si `dual`), `use` por recurso | 45,4 |
| Núcleo | `encodeDraw` (`render.cpp:1252`) | valida todo y genera todo el estado del draw en un stream temporal | 24,1 |
| Núcleo | `appendDeduped` (`render.cpp:2741-2792`) | descodifica ese stream paquete a paquete y consulta cada registro en una tabla de 512 KiB (`command.hpp:247-274`) | 10,1 |

El defecto es de arquitectura: **cada draw vuelve a validar, vuelve a generar su estado completo y después lo
filtra**, cuando entre dos capas de un compositor cambian una textura, unas constantes y a veces el programa.
[HEREDADO] El propio código lo dice: «519 of a lone draw's 588 words are register writes» (`render.cpp:2735-2736`).

### 2.2 Trabajo que se repite por draw y es función de un objeto

| Trabajo | Dónde | Depende solo de | Coste [M] |
|---|---|---|---|
| `checkStage` × 2 | `render.cpp:154` | el programa | 0,9 % |
| `render::link` (port de `ir3_link_shaders`) | `render.cpp:1548`; `link.cpp:94` | el programa; `linkProgram` ya lo guarda | 1,0 % |
| `checkTarget`, `windowOf`, `mrtWords` | `render.cpp:991`, `:603`, `:128` | el pase | 1,2 % + lo suyo en `encodeDraw` |
| `blendWords` por attachment | `render.cpp:850` | pipeline + formato | en `encodeDraw` |
| `vertexFetch` | `render.cpp:362` | descriptor de vértices + buffers ligados | 0,9 % |
| config de programa, `OBJ_START`, memoria privada, **precarga `ST6_SHADER`**, inmediatos | `render.cpp:1711-1774`; precarga en `:1759` | el programa | en `encodeDraw` y `appendDeduped` |
| VPC, entradas y salidas del FS, MSAA, LRZ, MRT | `render.cpp:1700-1710`, `:1961-1965` y alrededores | (programa, pase); solo se saltan cuando el draw anterior usó el mismo programa (`render.cpp:2976-2979`) | ídem |
| descriptor muestreado de cada textura | dentro de `stageTextures` (`render.cpp:634`) | la textura | 2,2 % `stageTextures` |
| `programAddress`: compara cada 64.ª palabra del binario y guarda una copia de sus palabras por command buffer | `command.cpp:113-133` | identidad del programa | 2,3 % |
| `bindArgumentBuffers`: copia el vector de buffers antes de mirar si el stage tiene argument buffers | `compiler.cpp:1591-1595` | el stage | 3,4 % |
| `gmemDrawOk` | `render.cpp:2320` | (programa, pase) salvo las texturas | 0,5 % |

[O] La precarga del shader se emite en cada draw de cada etapa aunque el programa no cambie: escena A, 40
`CP_LOAD_STATE6_GEOM` y 54 `CP_LOAD_STATE6_FRAG` para 20 draws. `appendDeduped` filtra registros, no cargas
(`render.cpp:2773-2778`).

### 2.3 Asignaciones de heap, copias y memoria write-combined

[O] 6-13 asignaciones de heap por draw en el núcleo del port (tabla 1.2). Orígenes:

- `loadDirect` crea un `std::vector` por carga (`render.cpp:100`); los inmediatos, otro (`render.cpp:1761`).
- `StageTextures::used` y `GfxIbos::used` (`render.cpp:584`, `:793`); `vsUbos`/`fsUbos` (`render.cpp:1425`).
- el vector de salidas del FS (`render.cpp:1963`).
- `std::string name = stageName(...)` al entrar en `vertexFetch` y `stageTextures` (`render.cpp:363`, `:636`).
- `bindArgumentBuffers`: `const std::vector<Binding> sets = b->buffers` × 2 (`compiler.cpp:1595`).
- `Bindings vsWithNull, fsWithNull` copiados cuando el stage declara la textura nula o deja un slot sin ligar
  (`render.cpp:2805-2831`).
- `keep`/`keepAlive` reciben el `shared_ptr` por valor y miran después si ya estaba (`command.hpp:122-141`): dos
  operaciones atómicas por llamada aunque no se guarde.
- `uses_` crece con cada buffer y textura de cada draw; `Gpu::submit` lo deduplica con un bucle cuadrático
  (`gpu.cpp:146-162`).

Memoria write-combined: la tabla de cada draw es una pieza de 8 KiB (`render.cpp:2859`) en la que se escriben
~3,8 KiB fijos (`render.cpp:1559-1566`: ceros y copias de 15 slots de 64 + 16 bytes por etapa) para llevar 1-3
descriptores; cada slab de 256 KiB que se reutiliza se pone a cero entero (`command.cpp:161`), otros 8 KiB por draw.
[HEREDADO, autor del port] Las lecturas de esa memoria «go to memory one by one»: copiar por CPU los uniformes de
CoreAnimation costaba 50-160 µs por draw (`render.cpp:213-216`); por eso el port los copia con `CP_MEMCPY`. Queda una
lectura por draw: los 96 bytes de `hakiosProgramFor:` (§2.1).

### 2.4 Grabación doble

[O] Con los valores por defecto del plug-in (`hm_gmem_draws()` = 56, `CA.m:5890-5899`; `CA.m:5325-5326`), un pase que
puede ir en GMEM y cuyo historial no es de menos de 28 draws se graba **dos veces**: `encodeInPass` para tiles y otra
vez para sysmem, y `appendDeduped` dos veces (`render.cpp:2913-2919`, `:2984-3003`, `:3085-3086`). `closePass` elige
al final por el número de draws (`render.cpp:3280-3293`). Los pases con más draws son los que se graban doble.
[O] En host: 6,4 µs por draw grabado doble (escena P) frente a 3,4 grabado una vez (escena R): **×1,9**.
[HEREDADO] El comentario del código da 7,5 µs por draw para la segunda grabación «on the phone» (`render.cpp:2907-2908`).

### 2.5 Teléfono frente a host

`CommandBuffer::draw` cuesta ~99 µs por draw en el teléfono (45,4/57,8 de 126 µs [M]) y 3,4-6,4 µs en el host [O]:
×16-30. Los draws corren en el clúster P [O, §1.1]; la diferencia de procesador sola no explica ese factor.
Contribuyentes identificados que el host no tiene: escrituras y lecturas de memoria write-combined (memmove/memset
8,2 % [M]) y draws reales más pesados que los sintéticos (hasta 15 slots de textura, 2-3 salidas de color, 3 rangos
de uniformes por variante, §1.3). [H] El resto está sin atribuir; la frecuencia real del clúster es materia del plan
07. El plan de §2.7 se apoya en el reparto del perfil, no en los tiempos absolutos del host.

### 2.6 Diseño objetivo del camino de draw

Referencia: `tu6_draw_common` (`mesa:src/freedreno/vulkan/tu_cmd_buffer.cc:8632`). En un draw incremental turnip
emite un `CP_SET_DRAW_STATE` con 3 palabras por grupo cambiado (`:8890-8919`) y el paquete de draw de 3 o 7 palabras
(`:9262`, `:9336`): 14-21 palabras cuando cambian texturas, constantes y vértices. La documentación de Mesa da el
porqué: «Since the SQE is not a fast processor, and tiled rendering means that many draws won't even be used in many
bins … state updates can be batched up into "draw states" … At draw time, if the draw call is going to actually
execute (some primitive is visible in the current tile), the SQE goes through the GROUP_IDs and for any with an update
since the last time they were executed, it executes the corresponding fragment» (`mesa:docs/drivers/freedreno.rst:161-166`).

Un draw en el diseño objetivo:

1. **Sin marshalling.** El encoder del plug-in escribe cada `set*` en un `RenderEncoder` del núcleo (slots + bits de
   sucio). `drawCommon`, `passOf`, los `Bindings` y los arrays de handles desaparecen del camino.
2. **Objetos de estado precalculados**, cada uno un fragmento PM4 ya codificado:
   - `ProgramState`, por (pipeline, firma del pase = formatos de attachment + nº de muestras): todo lo de la tabla 2.2
     que depende de programa y pase, validaciones incluidas. Se construye una vez con el código de emisión actual.
   - `TexState`, por combinación (texturas, samplers): los descriptores (N × 64 + M × 16 bytes) y sus dos cargas.
     Caché por command buffer primero y persistente después, como el estado de texturas de gallium
     (`mesa:src/gallium/drivers/freedreno/a6xx/fd6_texture.cc`).
   - estado del pase (MRT, `RB_RENDER_CNTL`, profundidad): una vez por pase.
3. **Estado dinámico por bits de sucio**: viewport/scissor, raster, profundidad/stencil, color de blend, buffers de
   vértices. Sin `RegShadow` ni `appendDeduped`.
4. **Constantes**: una carga por rango, escrita directamente en el stream.
5. **El draw.**

Resultado: 15-25 palabras y cero asignaciones por draw.

### 2.7 Plan por etapas y por función

Cada etapa compila y se valida sola. El orden dentro de cada etapa es el de la tabla (por peso medido). La etapa A no
cambia las palabras que se emiten para un draw en un modo dado; A1 cambia además qué modo recibe un pase cuyo número
de draws cruza el umbral en ese frame.

**Etapa A — quitar trabajo repetido y asignaciones.**

| # | Función | Cambio | Ataca [M] |
|---|---|---|---|
| A1 | `CommandBuffer::draw` (`render.cpp:2902-2919`), `closePass` (`:3280-3293`) | grabar una sola vez: el modo se decide al abrir el pase con `peakDraws`; desaparecen `dual`, `sysStream`, `headGmem` y la segunda tabla | la mitad de `encodeDraw` + `appendDeduped` en los pases pesados: ~14 % del hilo |
| A2 | `bindArgumentBuffers` (`compiler.cpp:1591`), `drawCommon` (`c_api.cpp:1387`) | bandera `hasArgumentBuffers` por `CompiledStage`, calculada al compilar; sin ella no se llama | 3,4 % |
| A3 | tabla del draw (`render.cpp:1559-1566`, `:2859`), `piece` (`command.cpp:80`), `takeBuffer` (`:161`) | pieza del tamaño que el draw usa (de 64 bytes a ~1,3 KiB según los slots declarados); escribir solo esos slots; no poner a cero el slab | parte de memmove/memset (8,2 %) |
| A4 | `loadDirect` (`render.cpp:99`), `stageTextures`, `gfxIbos`, `uboDescriptors`, salidas del FS (`:1963`), inmediatos (`:1761`), `vertexFetch` (`:363`) | arrays fijos y escritura directa en el stream; inmediatos ya alineados en el stage; el nombre solo al rechazar | malloc vía libc++abi 4,0 % + `encodeDraw` 1,0 % |
| A5 | `programAddress` (`command.cpp:113`), `programBuffer` (`:181`) | identidad por id del stage compilado; sin comparar palabras ni copiar el binario por command buffer | 2,3 % |
| A6 | `encodeDraw` (`render.cpp:1548`, `:154`, `:991`) | usar `program.link` (recalcular solo en programas hechos a mano); `checkStage` una vez por programa; `checkTarget`, `windowOf`, `mrtWords` una vez por pase, guardados en `OpenPass` | ~3,5 % |
| A7 | `CommandBuffer::draw` (`render.cpp:2805-2831`) | la textura nula se resuelve en `stageTextures`, sin copiar `Bindings` | en el self de `draw` |
| A8 | `Texture` | descriptor muestreado calculado al crear la textura | en `stageTextures` |
| A9 | `keep`/`keepAlive` (`command.hpp:122-141`), `use`, `Gpu::submit` (`gpu.cpp:146`) | pasar por referencia y copiar solo al guardar; marca «visto en este buffer» por `Bo` | ~1 % |
| A10 | `hakiosProgramFor:` (`CA.m:7826-7836`) | copiar los 48 bytes una vez a la pila con cargas de 16 bytes y trabajar sobre la copia | lecturas de memoria sin caché |

Ganancia esperada [H, suma de las cuotas medidas sin contar dos veces]: ~29 % del tiempo del hilo, la mitad de lo que
gasta hoy el driver por draw (de ~126 a ~65-75 µs; −8 a −9 ms por frame).

**Etapa B — objetos de estado y emisión incremental (sysmem primero).**

| # | Función | Cambio |
|---|---|---|
| B1 | `OpenPass` (`command.hpp:306`) | `PassSig` calculada al abrir el pase |
| B2 | `CompiledProgram` | `stateFor(PassSig)`: construye el `ProgramState` llamando a las secciones actuales de `encodeDraw` con las máscaras de `render::Options` que ya existen y guarda las palabras |
| B3 | `CommandBuffer::draw` | si el `ProgramState` no es el último emitido en el pase, se copian sus palabras; el estado dinámico se compara y emite por bloques; los draws dejan de pasar por `appendDeduped` |
| B4 | nuevo `TexState` | caché por command buffer indexada por (punteros de textura, punteros de sampler) |
| B5 | `encodeDraw` | queda como constructor de objetos y camino de pruebas |

Ganancia esperada [H]: `encodeDraw` y `appendDeduped` (34 % del hilo) salen del camino; quedan las capas ObjC y API C
(12,4 % del hilo, ~27 µs por draw) y unos µs de núcleo.

**Etapa C — encoder con estado en la API C.** `hakios_metal_enc_set_*` y `hakios_metal_enc_draw`; los setters del
plug-in (`CA.m:8225-8421`) escriben directamente y `hakiosDrawOnce` deja de construir arrays. `hm_panel_scale`
(`CA.m:8076`) se resuelve al crear la textura, no en cada `setFragmentTexture:`. Objetivo: < 5 µs por draw.

**Validación.** (1) La suite de host, en verde en el árbol del port (§0). (2) `framecount`: mismo hash del stream antes y después en A2-A10; en A1, el
stream de la escena P igual al de hoy en GMEM y el de R igual en sysmem; en B, el fake GPU comprueba el estado
completo en cada `CP_DRAW_INDX_OFFSET`, con el arreglo previo de §1.2 (reiniciar las cargas de constantes al cargar
un programa). (3) Contador de `operator new` en un test: 0 asignaciones por draw en régimen. (4) En el teléfono,
`metal_fps`: «us of ours each» y «a buffer made to committed», n ≥ 3 capturas por condición con `medicion/ab.sh`.

**Sobre `metal_defer=1`.** [M] Sube la cadencia un 17-20 % hoy (23,7 → 27,6-28,4 buffers/s) porque saca el núcleo del
hilo de render. Está apagado por defecto en el port: [HEREDADO] «an app opening stays black until touched»
(`CA.m:5152`). Con draws de pocos µs deja de hacer falta.

## 3. Cuello B — tiempo de GPU de la pasada principal

### 3.1 Por qué 102 tiles

[O] `gmemPlan` reparte la GMEM entre todos los attachments de color del pase y alinea cada parte a 16 KiB
(`render.cpp:2210-2221`); `gmemTiles` pone una sola columna si el ancho cabe en 1 024 y el alto que quepa
(`render.cpp:2236-2247`). Constantes del port: `kGmemBytes` 128 KiB (`a6xx.hpp:1429`) menos 4 KiB de caché de color de
la CCU (`a6xx.hpp:4112`) = 124 KiB. Con **dos attachments de 4 bytes** («CoreAnimation's main pass draws into two
screens at once», `render.hpp:508`) al primero le tocan 48 KiB: 12 288 píxeles por tile, tiles de **768 × 16**, 102
filas. Los tiles son tiras de ancho completo y 16 píxeles de alto, no de 96 × 128.

El algoritmo de turnip (`mesa:src/freedreno/vulkan/tu_pass.cc:793-877`: bloques de 8 × 32 × 16 = 4 096 bytes;
`mesa:src/freedreno/vulkan/tu_util.cc:286-343`: prueba todos los anchos, se queda con el menor número de bins y, a
igualdad, con el más cuadrado) para 750 × 1624 en el A610 (`tile_align` 32 × 16, máximo 1 024,
`mesa:src/freedreno/common/freedreno_devices.py:282-301`):

| Attachments de 4 bytes | port (16 KiB, una columna, 124 KiB) | turnip con 124 KiB | turnip con 128 KiB |
|---|---|---|---|
| 1 | 51 tiles de 768 × 32 | 42 de 128 × 240 | 39 de 256 × 128 |
| 2 | **102 de 768 × 16** | 84 de 192 × 80 | 78 de 128 × 128 |
| 3 | no cabe: «a bin too wide for GMEM» (`render.cpp:2223`), el pase va a sysmem | 126 de 128 × 80 | 126 de 128 × 80 |

128 KiB útiles son los del hardware: KGSL da al A610 `gmem_size = SZ_128K + SZ_4K`
(`relojes/ref/downstream/kgsl-5.x/adreno-gpulist.h:1507`) y turnip reserva la caché de la CCU al final
(`mesa:src/freedreno/common/fd6_gmem_cache.h:63-123`, `tu_pass.cc:855-856`); el kernel de iOS anuncia 128 KiB
(informe 09).

[O] Las 53 variantes `_cpf` escriben 3 salidas de color (§1.3): si su pase liga tres attachments de 4 bytes a este
ancho, no puede ir en GMEM con el reparto del port.

### 3.2 Qué ejecuta el procesador de comandos en cada tile

[O] Los draws de un pase GMEM van a un cuerpo que cada tile llama con `CP_INDIRECT_BUFFER` (`render.cpp:2514`); el
paso de binning lo llama una vez más (`render.cpp:2415`). El cuerpo lleva el estado como escrituras de registro y
cargas en línea. No hay grupos `CP_SET_DRAW_STATE`: el único paquete de ese tipo es el «disable all» del arranque
(`render.cpp:1161-1164`).

Con binning, el CP salta los `CP_DRAW_INDX_OFFSET` que el stream de visibilidad marca como no visibles, pero **lee y
ejecuta en cada tile los registros y las cargas de todos los draws**. Escena P: 490 035 palabras por frame; por draw
y por tile, ~8 escrituras de registro, 2 precargas de shader, la carga de constantes y las dos de texturas.

[O] **El retorno anticipado del cuerpo no está armado.** La documentación del paquete: «Enables IB2 skipping. If both
GLOBAL and LOCAL are 1 and nothing is left in the visibility stream, then CP_INDIRECT_BUFFER will be skipped, and
draws will early return from their IB» (`mesa:src/freedreno/registers/adreno/adreno_pm4.xml:493-500`). fd6 pone
`LOCAL` a 1 al empezar el lote (`mesa:src/gallium/drivers/freedreno/a6xx/fd6_gmem.cc:1323-1325`) y turnip pone los dos
(`mesa:src/freedreno/vulkan/tu_cmd_buffer.cc:3687-3691`). El port emite `CP_SKIP_IB2_ENABLE_GLOBAL` por tile
(`render.cpp:2488`, `:2520`) y nunca `CP_SKIP_IB2_ENABLE_LOCAL` (`a6xx.hpp:357` lo define; ningún emisor lo usa).

Lo medido [M, §1.1]:

- Quitar el binning añade 4,1-5,6 ms: ejecutar de verdad ~10 000 draws más por frame cuesta ~0,4-0,5 µs por draw y tile.
- En las listas de pasadas más lentas, el tiempo de la principal depende poco del número de draws: 97 draws 21,0 ms,
  112 draws 23,5 ms, 114 draws 21,3 ms (medianas); el ajuste lineal da ~11 ms + 0,10 ms por draw con R² 0,2-0,4.
- En reposo, 108 draws: 18,0-18,2 ms.

[H] Lectura: hay un coste por tile, con o sin draws visibles (preparación, carga, guardado, `CP_WAIT_FOR_IDLE`,
lectura del cuerpo entero), del orden de 0,1 ms por tile, más un coste por draw y tile del orden de 1 µs. Los dos
escalan con el número de tiles. Cota superior para el CP: 18,2 ms / 490 035 palabras = 37 ns por palabra;
[HEREDADO] HackiOS midió 12,4 µs del CP para un draw de 588 palabras en su A635 (`render.cpp:2734-2737`), 21 ns por
palabra. La parte de píxeles no está medida aquí.

### 3.3 Framebuffer fetch: barreras

[O] En un pase GMEM, cada draw que lee el blanco y viene detrás de uno que no lo lee emite
`CP_WAIT_FOR_IDLE` + `CACHE_INVALIDATE` + `CP_WAIT_FOR_IDLE` dentro del cuerpo (`render.cpp:1616-1622`), y cada tile
añade `CP_WAIT_FOR_IDLE` + `CACHE_INVALIDATE` si algún draw del pase lee (`render.cpp:2510-2513`). Como el cuerpo se
repite por tile, la escena Q (27 transiciones) lleva **5 568 `CP_WAIT_FOR_IDLE` y 2 781 `CACHE_INVALIDATE` por frame**.
En sysmem cada draw que lee lleva 2 `CP_WAIT_FOR_IDLE`, un flush de la CCU con espera sobre una palabra y un
`CACHE_INVALIDATE` (`render.cpp:1623-1629`; escena B).

Las fuentes primarias:

- fd6 no emite barreras para el fetch coherente: por draw, `GRAS_SC_CNTL.SINGLE_PRIM_MODE` = `FLUSH_PER_OVERLAP` en
  GMEM y `FLUSH_PER_OVERLAP_AND_OVERWRITE` en sysmem (`mesa:src/gallium/drivers/freedreno/a6xx/fd6_emit.cc:533-555`).
  El XML: «Invalidate UCHE and wait for any pending work to finish if there was possibly an overlapping primitive
  prior to the current one» (`mesa:src/freedreno/registers/adreno/a6xx.xml:1707-1731`).
- turnip hace lo mismo (`mesa:src/freedreno/vulkan/tu_pipeline.cc:3811-3845`, `:4468-4498`) y **fuerza GMEM** en un
  pase que usa el modo de primitiva única en sysmem: «that should cause significantly increased SYSMEM bandwidth
  (though we haven't quantified it)» (`mesa:src/freedreno/vulkan/tu_autotune.cc:1815-1820`).

[HEREDADO] El port pone `FLUSH_PER_OVERLAP` en los draws que leen y mantiene la barrera en la transición porque sin
ella HackiOS vio artefactos («a widget's text cut by a band and the App Library's blur in blocks»,
`render.cpp:1610-1613`): el rasterizador no ordenaría la lectura respecto de draws anteriores emitidos sin el modo.
En sysmem conserva la barrera en cada draw porque el modo «bought nothing measurable … SpringBoard's heaviest passes
took some 50 ms either way» (`render.cpp:1614-1615`).

[H] Alternativa a probar: en un pase con algún draw que lee, **todos** los draws en `FLUSH_PER_OVERLAP` como estado
del pase, sin barreras. Si reaparecen los artefactos, la barrera se limita a las transiciones cuyo rectángulo
(`render::drawArea`, `render.cpp:2288`) solapa algún draw anterior emitido sin el modo.

[HEREDADO] HackiOS anota que el fetch desde GMEM va «at a quarter of its rate from memory» (`CA.m:5829-5833`).

### 3.4 Load y store por tile

[O] `closePass` carga un attachment tocado salvo que su load action sea DontCare y guarda el que se escribió si su
store action no es DontCare (`render.cpp:3321-3334`); un Clear se hace en el tile, sin carga (`render.cpp:2497-2506`).
Los tiles se limitan a la unión de las áreas de los draws (`render.cpp:3313-3315`). Un attachment sin tocar no se
carga ni se guarda, pero sí ocupa su parte de GMEM (§3.1). Al final hay un `PC_CCU_RESOLVE_TS` con espera
(`render.cpp:2532-2534`). Cada tile lleva su `CP_WAIT_FOR_IDLE` (`render.cpp:2525`), como en turnip
(`mesa:src/freedreno/vulkan/tu_cmd_buffer.cc:3839`).

Lo que turnip tiene y aquí falta: carga y guardado condicionados a que el tile tenga geometría
(`mesa:src/freedreno/vulkan/tu_cmd_buffer.cc:1497-1525`). En la pasada principal todos los tiles la tienen.

No se sabe qué load action usa CoreAnimation en la pasada principal: `metal_fps=timeline` imprime el recuento de
pasadas a pantalla completa por load action (`CA.m:5630`).

### 3.5 Pasadas en sysmem

[M] 22 pasadas sysmem a `750x1624` con 30-53 draws tardan 20,7-26,0 ms; una a `752x1626` con 35 draws, 31,96 ms.
En sysmem no hay repetición por tile: 108 draws son 4 938 palabras (escena R). [H] Ese tiempo es de píxeles y de
barreras de fetch.

[O] La regla que las deja en sysmem solo cuenta draws (`render.cpp:2913-2916`, `:3282`); no mira si el pase lee el
blanco ni cuánta superficie cubre. [O] Todos los blancos de color son lineales (`render.cpp:134`, salvo texturas UBWC
de solo lectura). Mesa usa `TILE6_3` por defecto y UBWC cuando el formato lo admite, también en el A610: solo excluye
el A702 (`mesa:src/freedreno/vulkan/tu_image.cc:325-338`, `:703`;
`mesa:src/gallium/drivers/freedreno/a6xx/fd6_resource.cc:25-33`).
[HEREDADO, `NOTES.md:312-316`, Mesa GL en este teléfono a 1125 × 2436] Una capa a pantalla completa con blending cuesta
6 ms en un blanco lineal, 2,4 ms en uno tiled y 1,3 ms en GMEM.
[HEREDADO, HackiOS en su A635, `render.cpp:2923-2924`] Pases de 80 draws: 13,8-16 ms en GMEM frente a 18,6-30,7 en
sysmem; pases ligeros: 5 ms en GMEM frente a 0,13 en sysmem.

### 3.6 Overdraw, profundidad y LRZ

[O] El pase principal no tiene attachment de profundidad, `gmemPlan` rechaza los pases que lo tienen
(`render.cpp:2177-2179`) y LRZ está apagado (`render.cpp:1704-1710`). LRZ necesita un buffer de profundidad. Un
esquema de profundidad sintética (capas opacas de delante hacia atrás con escritura de profundidad, después las
translúcidas con test) exige que el driver sepa qué draw es opaco, reordenar draws y un attachment más en GMEM, que
sube el número de tiles. [H] Ganancia baja en SpringBoard: iconos y etiquetas no son opacos. Queda fuera de la lista.

### 3.7 Calidad del shader de fragmento especializado

[O] Desensamblado con el descodificador de Mesa (listados fuera de git):

- El tamaño que imprime el driver cuenta unidades de 16 instrucciones con su relleno: «128 instruction words» son
  hasta 64 instrucciones, `nop` de espera incluidos. Una variante simple (textura con tinte) son 14 instrucciones en
  una unidad: 5 `bary.f`, 4 `cov.f32f16`, 1 `mov`, 1 `samb`, 1 `mul.f` repetido; trabaja en registros de media
  precisión.
- Las variantes de 128-576 palabras son las de fetch con matriz de color y varias texturas: 40-90 instrucciones, con
  un preámbulo (`shps`/`getone`…`shpe`) que prepara uniformes una vez por draw.
- La especialización pliega el uber shader: 32-576 palabras frente a 32 064.

Defectos observados:

1. La tabla de texturas no se compacta: `numTextureSlots` es el índice muestreado más alto más uno
   (`compiler.cpp:221-223`), así que las 53 `_cpf` declaran 15 slots y otras 16 declaran 10 para muestrear 1-3; el
   draw escribe y carga todos los descriptores declarados (960 bytes con 15), en cada tile.
2. Cada varying se interpola a 32 bits y se convierte a 16 con un `cov` aparte (4 de las 14 instrucciones de la
   variante simple). ir3 interpola directamente a media precisión cuando la E/S llega marcada así.
3. Dos variantes (`_cph`, 1 y 2 salidas) son 9 instrucciones que leen el blanco y lo escriben tal cual: draws sin
   efecto en ese attachment que pagan lectura, escritura y barrera. No se sabe cuántos hay por frame.

[O] Mientras una especialización no está lista, el draw **espera en el hilo de render** con `usleep(2000)` hasta
1 500 veces (`CA.m:7859-7872`); [HEREDADO] el motivo es que el uber shader entero sobre un área grande agota los 2 s
del kernel (`CA.m:7856-7858`). Las claves conocidas de cada pipeline se guardan en `spec-<hash>.keys` y se compilan
al crearlo, en una cola serie (`CA.m:7722-7738`, `:7760`); un draw que llega antes espera.

### 3.8 Plan para la GPU

| # | Cambio | Dónde | Efecto esperado | Riesgo |
|---|---|---|---|---|
| G0 | Armar el retorno anticipado: `CP_SKIP_IB2_ENABLE_LOCAL 1` al empezar un pase con binning | `encodeGmem` (`render.cpp:2343`) | [H] cada tile deja de leer el cuerpo tras su último draw visible | bajo; un paquete |
| G1 | Reparto de tiles como turnip: partes a 4 KiB, búsqueda del menor número de bins, 132 KiB de GMEM | `gmemPlan` (`render.cpp:2210-2225`), `gmemTiles` (`:2228-2252`), `a6xx.hpp:1429`; el kernel anuncia 128 | 102 → 78-84 tiles; los pases de 3 attachments entran en GMEM | bajo-medio |
| G2 | Elegir el modo por contenido y por medida, no por número de draws: pase con fetch y área grande → GMEM; el resto, por el tiempo medido de su clase (`preferGmem`, que hoy queda sin usar, §3.9); sin grabación doble (A1) | `render.cpp:2902-2931`, `:3280-3293` | [H] las pasadas sysmem de 21-26 ms pasan a costar como una pasada en tiles | medio: Mesa advierte que errar hacia GMEM cuesta más que errar hacia sysmem (`mesa:src/freedreno/vulkan/tu_autotune.cc:1836-1839`) |
| G3 | Grupos `CP_SET_DRAW_STATE` reales con máscaras `BINNING`/`GMEM`/`SYSMEM` (`mesa:src/freedreno/registers/adreno/adreno_pm4.xml:1099-1112`); un cuerpo único para los tres modos | `CommandBuffer::draw`, `encodeGmem`; sobre la etapa B | [H] el CP ejecuta estado solo de draws visibles; el modo se decide en `closePass` sin grabar dos veces | medio-alto |
| G4 | Dar GMEM solo a los attachments que el pase toca | `gmemPlan` en `closePass`; sobre G3 (el estado del pase y el descriptor del fetch dejan de ir en cada draw) | 78-84 → 39-42 tiles cuando solo se toca el attachment 0 | medio |
| G5 | Fetch sin barreras explícitas (§3.3) | `render.cpp:1616-1629`, `:2510-2513` | escena Q: de 5 568 a ~110 `CP_WAIT_FOR_IDLE` por frame | medio: se valida mirando la pantalla |
| G6 | Compactar slots de textura por variante; E/S en media precisión; descartar draws cuya variante solo copia el blanco | `compiler.cpp:131` (`walkTextures`), `:221-223`, `:771` (`fillKernel`); front-end de AIR a NIR | 15 → 1-3 descriptores por draw; −4 instrucciones en la variante simple | bajo-medio |
| G7 | Especialización: carga síncrona desde la caché de disco al primer uso; compilar solo en fallo real | `CA.m:7821-7873` | quita esperas de 2 ms a 3 s del hilo de render | bajo |
| G8 | Blancos propios en `TILE6_3`, con UBWC cuando proceda | `Texture::make`, `mrtWords` (`render.cpp:128-140`), `gmemPlan` | [HEREDADO] ×2,5 en relleno con blending en sysmem | medio; el kernel anuncia `HIGHEST_BANK_BIT` 14 y Mesa da 13 (informe 09) |
| G9 | Carga y guardado condicionados a visibilidad | `encodeGmem` (`render.cpp:2494-2523`) | menos tráfico en pases parciales | bajo |

Efecto conjunto esperado [H]: con G0 + G1 la parte de la pasada que escala con tiles baja un 18-24 % más lo que
ahorre el retorno anticipado; con G3 + G4, 39-42 tiles y estado solo de draws visibles, la pasada principal queda en
el orden de un tercio de la actual. Ninguna cifra de este párrafo está medida.

**Validación.** Fake GPU: test de reparto (bins dentro de la GMEM del chip; hoy el fake usa 512 KiB fijos,
`fake_gpu.hpp:193`), test de equivalencia de píxeles entre el cuerpo actual y el de grupos, `framecount` escena P
(palabras, cargas y `CP_WAIT_FOR_IDLE` por frame). Teléfono: `metal_fps` (ms de la pasada principal por número de
draws, n ≥ 3 capturas) y captura de pantalla para G0, G1 y G5.

### 3.9 Ensayos que separan las causas, con boot-args que ya existen

Van en `/var/tmp/metal.args` junto a `metal_fps=1` (`medicion/ab.sh`):

| Argumentos | Qué hace (código) | Qué responde |
|---|---|---|
| `metal_gmem_draws=0` (sin `metal_gmem=1`) | GMEM apagado: `hm_gmem_on() \|\| hm_gmem_draws() != 0` (`CA.m:5325`), «0 turns it off» (`CA.m:5886`) | la pasada principal en sysmem. `metal_gmem=0` no lo consigue: el valor por defecto de `metal_gmem_draws` es 56 |
| `metal_gmem=1 metal_gmem_draws=0` | elige GMEM o sysmem por el tiempo de GPU medido de cada clase de pase (`preferGmem`, `command.cpp:279`; rama `render.cpp:2920-2931`). Con el valor por defecto de `metal_gmem_draws` esa rama no se alcanza (`render.cpp:2905`), y por eso `metal_gmem_off=8` no cambia nada en los A/B | qué elige el selector por medida que el port ya tiene |
| `metal_gmem_draws=1` | toda pasada admisible en GMEM (`render.cpp:2913-2919`, `:3282`) | si las pasadas sysmem de 21-26 ms bajan en tiles |
| `metal_gmem_off=2` | carga y guarda todos los attachments (`command.hpp:181-183`, `render.cpp:3323-3329`) | el coste de 102 cargas más: la parte de load/store |
| `metal_gmem_off=4` | barrera en cada draw con fetch dentro de GMEM (`render.cpp:2981`) | el coste de las barreras |
| `metal_gmem_off=32` | todas las texturas de fragmento son la nula (`CA.m:5328`) | la parte de lectura de texturas |
| `metal_fps=passes` | imprime cada pasada de un buffer de cada 200 con `attached`/`touched` (`CA.m:5959-5984`) | cuántos attachments tiene la pasada principal y si toca el segundo (decide G4) |
| `metal_fps=timeline` | recuento de pasadas a pantalla completa por load action (`CA.m:5630`) | si hay carga por tile en la principal |
| `metal_fps=draws metal_gmem_draws=0` | cronometra cada draw de las pasadas sysmem, por programa (`CA.m:5848`) | qué draws cuestan los 21-32 ms en sysmem |

## 4. Respuestas a las preguntas de la auditoría

### 4.1 Modelo de pasadas

[O] Un pase se comparte entre draws con los mismos attachments, acciones y opciones (`render.cpp:2865-2874`).

- Por **pase sysmem**: arranque completo (invalidaciones, tabla estática de registros, «disable all»,
  `VFD_FETCH`; `render.cpp:1153-1170`), 3 `CP_WAIT_FOR_IDLE` (`:1159`, `:1175`, `:1219`), `PC_CCU_FLUSH_COLOR_TS` con
  `CP_WAIT_REG_MEM` y `CACHE_FLUSH_TS` con `CP_WAIT_MEM_GTE` (`:1222-1241`). Un Clear añade un flush con espera y otro
  `CP_WAIT_FOR_IDLE` (`:922-928`). Escena G: 601 palabras y 302 registros para un draw.
- Por **pase GMEM**: lo anterior más el paso de binning con su espera (`:2415-2421`) y, por tile, preparación, cargas,
  cuerpo, guardados y un `CP_WAIT_FOR_IDLE` (`:2446-2529`).
- Por **command buffer**: 1 submit, 1 `CP_WAIT_FOR_IDLE` final (`command.cpp:642`), 2 `GET_PARAM` (`command.cpp:655`,
  `:684`) y 1 `WAIT_FENCE` en el hilo de la cola (`:678`). Ninguna espera síncrona de CPU por pase ni por draw.
- Por **draw**: tabla 2.2; ~43 palabras por draw adicional en sysmem (escenas G y R).

turnip emite el estado estático una vez por command buffer (`tu_init_hw`,
`mesa:src/freedreno/vulkan/tu_cmd_buffer.cc:2466`), hace `CP_WAIT_FOR_IDLE` solo al cambiar la CCU entre sysmem y GMEM
(`:751-800`), no espera a ningún flush (`tu6_emit_flushes`, `:359-467`) y limpia la CCU al final del command buffer
(`:5453-5483`). Su autotune elige sysmem o GMEM por pase con un modelo de ancho de banda y deja en sysmem los pases de
menos de 5 draws (`mesa:src/freedreno/vulkan/tu_autotune.cc:1795-1870`).

### 4.2 Memoria

- [O] Cada `MTLBuffer` y cada textura es un GEM propio: `GEM_NEW` + `GEM_INFO` + map, y unmap + `GEM_CLOSE` al morir
  (`gpu.cpp:43`, `:109`; `CA.m:2678`). Solo hay pool para slabs, sellos y streams (`command.cpp:143-175`).
- [O] `setVertexBytes:`/`setFragmentBytes:` crean un `MTLBuffer` por llamada (`CA.m:8266-8297`).
- [O] El stream se construye en un `std::vector` y se copia al BO de comandos en el commit (`command.cpp:652`); el BO
  se recicla (`command.cpp:619`).
- [O] `replaceRegion` es un `memcpy` fila a fila (`texture.cpp:648`). Las texturas UBWC (solo lectura, RGBA8/BGRA8,
  ≥ 65 536 píxeles; `CA.m:3612`) pasan por una copia lineal y un blit de la GPU que **cierra el pase abierto**
  (`render.cpp:3139-3150`).
- [O] Blancos y texturas muestreadas normales son `TILE6_LINEAR` (§3.5).
- [O] IOSurface: sin copia si las filas son múltiplo de 64 bytes (`texture.cpp:926`); si no, copia por CPU a la ida y
  comparación byte a byte a la vuelta en el hilo de la cola (`CA.m:4429`, `:4575`). YCbCr se convierte por CPU a RGBA8
  (`CA.m:4504`).
- [O] Todo el mapeo es write-combined (`CA.m:4183`, `command.cpp:63`). Las constantes ligadas a un offset que no es
  múltiplo de 16 —CoreAnimation liga a múltiplos de 8— se copian con `CP_MEMCPY` + `CP_WAIT_MEM_WRITES` +
  `CP_WAIT_FOR_ME` por rango (`render.cpp:1766-1772`).

### 4.3 Sincronización

Todas las esperas del port [O]:

| Dónde | Qué | Valor | En ruta caliente |
|---|---|---|---|
| `CA.m:7870` | `usleep` en `hakiosProgramFor:`, hilo de render | 2 000 µs × ≤ 1 500 | sí |
| `CA.m:6627`, `:6643` | `dispatch_semaphore_wait` de un commit retenido por un evento | sin límite | [M] 0 retenidos |
| `CA.m:796` | `waitUntilDate:` de `MTLSharedEvent` | el plazo del llamante | no |
| `CA.m:2078` | `usleep(ca_prof_us)`, hilo del perfilador `ca_prof` | boot-arg | diagnóstico |
| `CA.m:2315` | `sleep(5)`, hilo de estado de `metal_m2v=1` | 5 s | diagnóstico |
| `CA.m:6272` | `usleep(200)`, muestreador de `metal_fps=sample` | 200 µs | diagnóstico |
| `command.cpp:678` | `WAIT_FENCE` en el hilo de la cola | plazo de 5 s (`command.cpp:15`) | una por buffer; el kernel sondea (informe 09) |
| `command.cpp:405`, `:672`; `c_api.cpp:68`, `:74`, `:83` | variables de condición (`waitUntilCompleted`, cola, grabación diferida) | — | [M] 0 esperas de completado |

- [O] `presentDrawable:` presenta en el handler de completado (`CA.m:6745`); backboardd no lo usa [M].
- [O] `hakios_metal_cb_free` espera a que el buffer termine si está en vuelo (`c_api.cpp:803-813`); lo llama
  `-dealloc` (`CA.m:5369`).
- [O] Un hilo por cola espera cada fence y ejecuta los handlers en orden (`command.cpp:669-704`): un handler lento o
  una vuelta de copia de superficie retrasa las finalizaciones siguientes.
- [M] `-commit` cuesta 2,3-3,2 ms en el hilo de render. [H] La mayor parte es kernel: los traps de IOKit son el 5 %
  de las muestras del hilo, ~2 ms por frame de 42 ms.

### 4.4 Shaders

[O] La creación de pipeline compila en el hilo que llama, también en las variantes con completion handler
(`CA.m:3253`, `:3433-3452`), bajo un mutex global (`compiler.cpp:52`, `:1283`). Hay caché en disco por stage
(`compiler.cpp:1281-1314`). No hay precompilación del `default.metallib`. Especialización del uber shader por 48
bytes del buffer de configuración (`CA.m:7705`), con sus claves recordadas por pipeline; espera en caliente en §3.7.
No hay enlace por draw salvo la llamada repetida a `render::link` (§2.2).

### 4.5 Lo no implementado que empuja a rutas lentas

- Blancos lineales (§3.5).
- Memoryless tratado como memoria normal (`CA.m:3700-3707`): los attachments auxiliares de CoreAnimation ocupan
  memoria y parte de GMEM.
- GMEM rechaza pases con profundidad o stencil, MSAA, blancos UBWC, formatos que no sean de 4 u 8 bytes
  (`render.cpp:2177-2196`) y, a este ancho, tres attachments (§3.1).
- Superficies con filas no alineadas y YCbCr por copia de CPU (§4.2).
- `luma_boost` se sustituye por una copia (`CA.m:8724`).

### 4.6 Comparación con turnip/fd6 para un frame de compositor

N quads con textura y blending sobre un blanco:

| | turnip / fd6 | hakios-metal (port) |
|---|---|---|
| estado estático de la GPU | una vez por command buffer | una vez por pase (~300 registros) |
| `CP_WAIT_FOR_IDLE` por pase sysmem | 0 (1 si cambia el modo de la CCU) | 3, más 1 por command buffer |
| esperas a flush dentro del stream | 0 | 2 por pase, 1 más por Clear |
| palabras por draw adicional en el stream | 14-21 [O, `tu_cmd_buffer.cc:8890-8919`] | ~43 en sysmem [O] |
| precarga de shader | en el grupo de programa: al cambiar de programa y solo si el draw es visible | 2 por draw y por tile |
| draw con framebuffer fetch | modo de primitiva única, sin barrera | 2 WFI + flush con espera (sysmem); WFI + invalidate + WFI por transición y por tile (GMEM) |
| pase principal en GMEM, A610, 2 attachments | 78-84 tiles; estado de draws visibles; retorno anticipado | 102 tiles; 490 035 palabras |
| elección sysmem/GMEM | modelo de ancho de banda; GMEM forzado con primitiva única | número de draws |
| CPU por draw | comparar bits de sucio y emitir punteros | validar, generar 300-600 palabras y filtrarlas: 111-139 µs [M] |

### 4.7 Diseño «un frame = un submit»

CoreAnimation ya entrega un command buffer por frame y el driver hace un submit por buffer [M, O]. Lo que falta es
que ese buffer sea barato para la CPU y para el CP:

- un arranque de estado por buffer;
- cada pase con su prólogo (MRT, ventana, modo) y sin cola con esperas;
- draws como grupos + paquete de draw en un cuerpo único, válido para sysmem, binning y tiles;
- modo decidido al cerrar el pase, con el cuerpo ya grabado;
- flush de CCU y de caché solo cuando un pase posterior lee lo escrito (`tu_flush_for_access`,
  `mesa:src/freedreno/vulkan/tu_cmd_buffer.cc:5788`) y una vez al final;
- pool de BOs por tamaño para buffers, texturas y `set*Bytes`, con reutilización al completar.

## 5. Lista priorizada

| # | Cambio | Ganancia esperada | Riesgo | Sección |
|---|---|---|---|---|
| 1 | Etapa A (A1-A10) | [H] −8 a −9 ms de CPU por frame | bajo | 2.7 |
| 2 | G0 + G1: retorno anticipado y reparto de tiles | [H] −18 a −24 % de la parte de la pasada principal que escala con tiles, más el retorno anticipado | bajo-medio | 3.8 |
| 3 | G2: GMEM por contenido | [H] las pasadas sysmem de 21-26 ms dejan de existir en esa forma | medio | 3.8 |
| 4 | Etapa B | [H] −5 a −6 ms más de CPU (draws a ~30 µs) | medio | 2.7 |
| 5 | G3 + G4: grupos de estado y GMEM solo para lo tocado | [H] pasada principal al orden de un tercio | medio-alto | 3.8 |
| 6 | Etapa C | [H] draws a < 5 µs (< 1 ms por frame) | medio | 2.7 |
| 7 | G5: fetch sin barreras | hasta −5 458 `CP_WAIT_FOR_IDLE` por frame en la escena Q | medio | 3.8 |
| 8 | G7: sin `usleep` en el hilo de render | quita tirones de 2 ms a 3 s | bajo | 3.7 |
| 9 | Pool de BOs; `set*Bytes` en el stream | quita 17-34 `GEM_NEW` por segundo [M] | bajo | 4.2 |
| 10 | Pase sin cola con esperas; estado estático por buffer | por pase: 3 WFI, 2 esperas y ~300 registros menos | medio | 4.1 |
| 11 | G6, G8, G9 | menos carga por draw; relleno más barato en sysmem | G8 medio | 3.8 |

Los puntos 1, 2, 3 y 8 son independientes entre sí y de tamaño contenido.

## 6. Instrumentación

`metal_fps` existe (`CA.m:5923-6205`). Contadores a añadir por command buffer:

- palabras del stream principal y de los cuerpos × llamadas; `CP_WAIT_FOR_IDLE`, eventos y cargas `ST6_SHADER`;
- draws grabados doble; aciertos y fallos de `ProgramState`/`TexState`; bytes escritos en tablas;
- por pase: attachments ligados y tocados, load/store, tiles, draws con fetch y transiciones con barrera;
- ms esperando una especialización; ms de `-commit` desglosados (cerrar pase, copiar stream, ioctl);
- asignaciones de heap por draw (contador de `operator new` en compilaciones de diagnóstico).

En host, `framecount` da las mismas cifras sobre el fake GPU y sirve de prueba de regresión.

## 7. No verificado

- El reparto de los 20-24 ms de la pasada principal entre procesador de comandos, coste fijo por tile y píxeles (§3.9).
- Cuántos attachments tiene la pasada principal y de qué formato (102 tiles salen de dos de 4 bytes o de uno de 8), y
  si toca el segundo.
- Qué load action usa y cuántos draws por frame leen el blanco en SpringBoard.
- Si `CP_SKIP_IB2_ENABLE_LOCAL` produce en el A610 el retorno anticipado que describe el XML, y su valor por defecto.
- Si `FLUSH_PER_OVERLAP` en todos los draws del pase evita los artefactos que HackiOS vio.
- Qué hace que un draw cueste en el teléfono 16-30 veces lo que en el host (§2.5).
- El reparto de los 2,3-3,2 ms de `-commit`.
- Todas las cifras marcadas [HEREDADO].

## 8. Estado al cerrar

**Terminado.**

- Lectura de la ruta de draw, de pases, de memoria, de sincronización y de shaders del port `5c3bd9a`, con cada cita
  comprobada contra el árbol (`rebuild/hakios-angel`) y contra Mesa `767fbf7c`.
- Medidas de host con `framecount-a610` (escenas A-H y P, Q, R; 6 ejecuciones) y análisis de la caché de stages del
  teléfono (194 stages, desensamblado ir3).
- Lectura de los datos del agente de medición: perfil, contadores `metal_fps` y los cinco A/B (n = 3 cada uno).
- Diagnóstico de los dos cuellos (§2, §3), plan de CPU por función en etapas A, B y C (§2.7), plan de GPU G0-G9
  (§3.8) y lista priorizada (§5).

**A medias o sin hacer.**

- Ningún cambio está implementado ni probado: todo §2.7 y §3.8 es diseño. Las ganancias marcadas [H] no están medidas.
- El reparto de los 20-24 ms de la pasada principal (procesador de comandos, coste fijo por tile, píxeles) no está
  separado; tampoco se sabe cuántos attachments tiene esa pasada, si toca el segundo ni qué load action usa (§7).
- La suite de host del árbol del port no está en verde (44 comprobaciones fallidas en 8 tests, §0); no se ha arreglado.
- El factor ×16-30 entre el coste por draw del teléfono y el del host está sin atribuir (§2.5).

**Siguiente paso concreto.**

1. En el teléfono, con `medicion/ab.sh` y n = 3: `metal_fps=passes`, `metal_fps=timeline`, `metal_gmem_draws=0`,
   `metal_gmem_draws=1` y `metal_gmem=1 metal_gmem_draws=0` (§3.9). Deciden G2 y G4 y separan las causas de §3.2.
2. En el árbol del port: dejar la suite en verde; después G0 (un paquete) y G1 (reparto de tiles) en
   `render.cpp:2210-2252` y `:2343`, validados con la escena P de `framecount` y con la pasada principal en `metal_fps`.
3. Etapa A en el orden A1, A2, A3 (§2.7), validada por igualdad de stream en `framecount` y por «us of ours each».

Material para retomar: `~/sapphire-angel/research/metal/auditoria-userland/` (`framecount.cpp`, `framecount-a610`,
`hm-port/`, `disasm/`, `stage-cache/`, `mesa/`).
