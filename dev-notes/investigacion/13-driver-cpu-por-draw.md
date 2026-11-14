# 13 — Driver Metal: coste de CPU por draw (etapas A y B de 10 §2.7), 2026-11-14

Informe fechado de implementación. Alcance: el núcleo C++ de `hakios-metal` y lo que el plug-in ObjC hace en cada
draw, sobre la base upstream de HackiOS `63fc2b4` + parches A610 propios + opcionales (08 §5), y la fusión de la rama
`gpu-pass` (14) en esta. El diagnóstico de partida es 10 §2; los datos del teléfono, 03 M1, M2, M6 y M11.

Convención de evidencia, la de 10: **[O]** observación propia (código con `archivo:línea` o medida reproducible),
**[M]** medida del teléfono tomada por el coordinador (archivo citado), **[H]** hipótesis sin medir.

Árbol de trabajo: `~/sapphire-angel/research/metal/rebuild/wt-cpu` (worktree de `hakios-upstream`), rama `cpu-draw`,
creada desde `opcional-puerto` (`620950c`). Las rutas `src/…`, `include/…`, `tests/…`, `tools/…` son de
`wt-cpu/hakios-metal/`; `CA.m` es `wt-cpu/userland/src/HakiosMetalCA.m`. Los números de línea son los de la punta de
la rama que §7 nombra. Herramientas y resultados fuera de git: `rebuild/cpu-tools/`.

## Resumen

| | Base (`propio-args`, `620950c`) | Rama `cpu-draw` |
|---|---|---|
| Teléfono, CPU por draw en el hilo que llama [M] | 142 µs (130-172) | 59 µs con `cpu-A-wip`; 17-20 µs con `merge-2` y el kernel 0350 (§6) |
| Teléfono, buffer hecho → commit [M] | 24,9 ms | 13,6 ms (`cpu-A-wip`); 4,0-6,0 ms (`merge-2`, kernel 0350) |
| Host, escena T (interfaz C, stages del teléfono, sysmem), µs por draw [O] | 10,88 | 3,40 (mínimo 2,82) |
| Host, asignaciones de heap por draw, escena T [O] | 38,3 | 0,2 |
| Palabras PM4 que recibe el procesador de comandos | — | las mismas, palabra por palabra, en todo lo que la rama `gpu-pass` no cambia a propósito (§4) |

- El objetivo de < 10 µs por draw en el teléfono **no se alcanza**: 17-20 µs [M]. Qué queda y por qué: §6 y §9.
- La etapa B tal como la describe 10 §2.7 (cargas de estado elididas cuando no cambian) **no está hecha**: choca con
  cómo `gpu-pass` convierte los draws de un pase en grupos de estado (§9.1). Lo que sí cambia el stream está en §3.9.
- Bundles en `rebuild/out/`: `cpu-A-wip`, `merge-1`, `merge-2` medidos en el teléfono; el de la punta, §7.

## 1. Punto de partida medido

### 1.1 En el teléfono (base `propio-args`, la misma fuente que `620950c`)

[M] `medicion/ab/ab-real-propio-args.txt` (kernel 0342, GPU a 820 MHz; resumido con `ab-sum.py`): 142 µs de CPU
por draw en el hilo que llama («of ours each», 130-172 según el periodo), de ellos 124-161 dentro de
`hakios_metal_cb_draw_indexed`/`_draw3` («the core's», cronometrado en `-hakiosDrawOnce:`, `CA.m:8385`); 129 draws
por command buffer; del buffer hecho al commit, 24,9 ms. Las medidas anteriores de la misma base
(`ab-v1260-base-1.txt`, `ab-propio-args-{1,2}.txt`) dan 141-164 µs.

[M] Perfil de muestreo del binario heredado (`medicion/perfil-1.txt`, 17 958 muestras del hilo de render): el 57,8 %
del tiempo de usuario bajo `-hakiosDraw:…`; dentro, `CommandBuffer::draw` 45,4 % (`encodeDraw` 24,1 %,
`appendDeduped` 10,1 %), `bindArgumentBuffers` 3,4 % (un tercio en `malloc`), `drawCommon` propio 2,1 %,
`-hakiosDrawOnce:` propio 1,9 %; `libsystem_malloc` 9,4 % del total.

### 1.2 En el host (fake GPU)

`tools/drawbench.cpp` graba frames sintéticos y cronometra solo las llamadas de draw. Escenas A-H, P, Q, R: las de
`framecount` de la auditoría 10 (interfaz del núcleo, programas hechos a mano). Escenas J, K, L: la interfaz C que
usa el plug-in (`hakios_metal_cb_draw3`/`_draw_indexed`) con programas enlazados, buffers de vértices e índices,
uniformes ligados a múltiplos de 8, un stage que declara diez slots de textura y liga uno, framebuffer fetch y dos
salidas de color. Escenas S, T, U (`--stages DIR`): lo mismo con los 202 stages reales de la caché del teléfono
(`auditoria-userland/stage-cache/files`, fuera de git), que dan 184 programas enlazables; S es una pasada principal de
110 draws en tiles, T la misma en sysmem, U los 110 draws en cinco pasadas de 22 (tres superficies y la pantalla dos
veces), que es la forma de los buffers del teléfono (4,9-8,3 pasadas y 125-165 draws por buffer [M]). `--cold KB` toca KB
kilobytes antes de cada draw para que el draw empiece con las cachés del procesador vacías del driver.

La tabla de la base y de cada paso está en §5.

## 2. Suite de host en la base

[O] Con las constantes del A635 (lo que compila `make test`), upstream + A610 pasa 261/261. El informe 10 habla de
44 comprobaciones en 8 tests en el árbol del port; en upstream + A610 no falla ninguna con esas constantes.

[O] Pero `make test` no define `HAKIOS_CHIP_A610`, que es con lo que se compila el bundle del teléfono
(`make ios CHIP=a610`). Compilada con esa definición (`make -f tools/dev.mk CHIP=a610 tests`), la suite de la base
falla 42 comprobaciones en 19 tests. Ninguna es un fallo del camino de draw:

| Causa | Qué era | Qué se hizo (commit `397c4d4`) |
|---|---|---|
| Tests que enuncian el chip como número | caché de instrucciones, fibras por SP, `RB_CCU_CNTL` en sysmem, registros mágicos, chip id, bins del plan GMEM, tope de un preload: los del A635 | Cada test enuncia el valor del A610 bajo `HAKIOS_CHIP_A610`, sacado de la fila de `GPUId(610)` de Mesa 25.0.7 (`freedreno_devices.py`: `a6xx_gen1_low`, líneas 353-369, y la entrada 445-478) y de `tu_device.cc:1426-1457`, no del código que se prueba |
| Tests de lo que solo tiene un chip con LPAC o con filtro cúbico | `HLSQ_CS_CTRL_REG1`, copias SP de los registros de id (`fd6_compute.cc:119-127`), filtro cúbico (gen3/gen4) | Dicen lo que hace un chip sin ellos: registro no escrito, sampler rechazado por nombre |
| Modelo del fake GPU | Juzgaba el descriptor de un framebuffer fetch en un tile como si GMEM empezase en la dirección 0; empieza en `kGmemBase` (0x100000 en el A610) | El fake resta `kGmemBase` (la rama `gpu-pass` hace lo mismo; en la fusión quedan sus líneas) |
| Modelo del fake GPU | Ataba cada carga de constantes de un envío al `constlen` de cualquier draw posterior, fuese cual fuese el programa para el que se cargaron | Las constantes de un stage quedan atadas al programa tras el que se cargaron |
| `-Werror` en macOS | `chipKnown` sin usar en un host sin la GPU del kernel: `make test` no compilaba con Apple clang 21 | `[[maybe_unused]]` |

[O] Un fallo real aparece por el camino y se arregla aparte (`b935418`): `CommandQueue::checkVsc` (`src/command.cpp:281`)
leía la palabra de desbordamiento de los streams de visibilidad en la posición de 32 pipes; `render::encodeGmem` la
escribe según `a6xx::kNumVscPipes`, que en el A610 es 16. En el A610 la palabra leída estaba en el stream de
primitivas del pipe 1 (a 0x1f7f0 de sus 0x20000 bytes): un desbordamiento real pasaba sin verse y un stream de
primitivas casi lleno habría apagado el binning por sí solo. `render::vscOverflowWordAt()` (`include/…/render.hpp`) es
el único sitio que dice dónde está la palabra. En funcionamiento normal (sin desbordamiento) las dos lecturas dan 0 y
el binning sigue encendido igual.

Con esto, 261/261 con las constantes de los dos chips en la base; la punta de la rama pasa 280 (269 propios + 11 de
`gpu-pass`) con las dos.

## 3. Qué se cambió, por función

El camino de un draw en la base: `hakiosDrawOnce` (ObjC) → `drawCommon` (`src/c_api.cpp`) → `CommandBuffer::draw` →
`render::encodeInPass` valida todo y genera ~590 palabras en un stream temporal → `appendDeduped` lo relee paquete a
paquete y descarta, contra una sombra de registros (`RegShadow`), las ~9 de cada 10 palabras que ya valían.

### 3.1 Un draw en dos mitades: hechos y emisión (`6f2e4e0`)

`render::encodeDraw` queda partido en `drawFacts` (`src/render.cpp:1364`), que juzga el draw en el orden de siempre
y deja lo que decide el stream (`ProgramFacts`: lo que deciden el programa y el pase; `DrawFacts`: lo que añaden los
enlaces y números del draw), y `emitDraw<S>` (`:1698`), que escribe el stream grupo a grupo según una máscara
(`kG…`, 29 grupos). `encodeDraw` es el envoltorio de los dos. De paso desaparecen las asignaciones que no eran del
draw: la copia del stage de fragmento para borrar regids, vectores por stage para rangos y UBOs, un vector por carga
(`pm4::Stream::open` escribe las palabras donde quedan), los `std::string` de nombres construidos al entrar.

### 3.2 El estado de un programa se guarda (`afc2eca`)

- `ProgramState` (`:3262`): para un programa en un tipo de pase (`StateKey`, `:3145`: formato de cada attachment,
  si hay depth, todas las opciones), los veredictos de `checkStage`, `link` y las palabras de blend (`ProgramFacts`),
  lo que cada stage necesita ligado (`StagePlan`, `:3162`), los atributos de vértice como los lee `vertexFetch`, y las
  palabras de los grupos que son solo del programa tal como las escribió `emitDraw` (`buildState`, `:3483`). Vive en
  la cola (`StateCache`, `:3298`, por `Program::uid`) para un programa con uid; en el command buffer, junto a una copia
  del `Program` comparada byte a byte, para uno hecho a mano.
- `Program::uid` (`include/…/render.hpp`): lo da `linkProgram` y lo renueva cada setter de la interfaz C que cambia el
  programa después (descriptor de vértices, blend, muestras; `src/c_api.cpp`): un programa cambiado es otro programa.
- `PassCache` (`:3410`, en `OpenPass::cache`): ventana y muestras que `checkTarget` calculó, los grupos propios del
  pase por lo que dibuja cada programa, los descriptores de fetch de los attachments y, por cada stream del pase, un
  `Cursor` (`:3341`): las palabras que el stream tuvo por última vez de cada grupo guardado y los números con que se
  hicieron los grupos propios del último draw (viewport, raster, blend dinámico, fetch de vértices).
- Un draw con estado guardado: `fastFacts` (`:3633`) y `fastTables` (`:3819`) son las reglas de `drawFacts` para lo
  que trae el draw —enlaces, cuentas, viewport, scissor, depth/stencil, índices— y escriben los descriptores de
  textura, sampler e IBO directamente en la tabla del draw (`Texture::sampledWords`, `src/texture.cpp:851`, guarda las
  16 palabras de una textura). Lo que no pueden asegurar va por el camino largo, donde `drawFacts` lo juzga y lo
  rechaza con la frase de siempre. `emitFast` (`:3890`) recorre los grupos en el orden de un draw: un grupo guardado
  cuyas palabras son las últimas que tuvo el stream se salta; uno hecho de números del draw se hace cuando los números
  no son los del draw anterior; las cargas de los stages y `HLSQ_INVALIDATE_CMD`, que ninguna sombra descarta, se
  añaden tal cual en cada draw.
- `DedupSink` (`:3092`): la regla de `appendDeduped` aplicada mientras se generan las palabras, sin stream intermedio.
- `keep()`/`use()` (`include/…/command.hpp:125`, `:268`) reciben una referencia y recuerdan lo último que se les dio
  (`recently`, `:274`): un draw nombra los mismos buffers y texturas que el anterior. La lista de buffers del envío es
  la misma (§4).
- El primer draw con un programa, un draw con memoria privada, uno indirecto, uno que cuenta muestras y todo pase sin
  deduplicación van por el camino largo (`drawFacts` + `emitDraw` a través de `DedupSink`).

### 3.3 Un grupo guardado que cambia se compara con el anterior (`343cc35`)

Cuando el programa de un draw no es el del anterior, sus grupos guardados pasaban enteros por la sombra: unas 350
consultas a una tabla hash para encontrar las pocas decenas de registros que difieren. El `Cursor` sabe qué palabras
tuvo el stream de cada grupo; para un grupo *plano* (solo paquetes de registros, ningún registro dos veces, sin
`HLSQ_INVALIDATE_CMD`; `packetsOf`, `:3233`) esas palabras son lo que valen sus registros, así que el grupo nuevo se
compara con ellas (`emitFast`, lambda `kept`): un registro que escriben los dos se emite si difiere, sin preguntar a
la sombra; uno que el anterior no escribía lo decide (y lo aprende) la sombra; uno que el anterior escribía y este no,
vuelve a la sombra. `Cursor::settle` pone la sombra al día antes de un draw por el camino largo. Lo que esto supone
—que los registros de un grupo guardado no los escribe ningún otro grupo— se comprueba para cada programa al hacer su
estado (`buildState`): si no se cumple, ese programa va siempre por el camino largo.

### 3.4 Interfaz C (`25ad496`)

`drawCommon` (`src/c_api.cpp:1399`) creaba dos `Bindings` por draw (seis vectores) y llamaba a `bindArgumentBuffers`
por stage, que copia la tabla de buffers antes de mirar si hay algún miembro de argument buffer. Las dos tablas son
del `hakios_metal_cb` y se rellenan en sitio; `CompiledProgram::argumentBuffers` (`include/…/compiler.hpp`) dice una
vez por programa si hay miembros, y sin ellos no se llama.

### 3.5 La tabla de un draw no se pone a cero entera (`1eedf93`)

Cada slab reutilizado (256 KiB por cada 32 draws) se ponía a cero al tomarlo. De su tabla, el trabajo de GPU de un
draw lee lo que el draw escribe: los descriptores que nombran sus cargas (tantos como nombran), las copias de
constantes que hace el propio stream, y las palabras que el stream direcciona una a una, todas por debajo de los
colores de borde. `CommandQueue::takeSlab` (`src/command.cpp:155`) entrega el slab como está;
`CommandBuffer::piece` (`:80`) pone a cero cada pieza al cortarla salvo para quien pide `asIs`; `CommandBuffer::draw`
pide así su tabla y pone a cero sus primeros 128 bytes. `CommandQueue::poisonReused` (tests y golden) rellena de 0xa5
el slab reutilizado: las sumas de lo que nombran las cargas no cambian.

### 3.6 Reciclado entre command buffers y entre pases (`99279c0`, `01ca4f6`)

- `CommandQueue::Spare` (`include/…/command.hpp:494`): un command buffer que termina entrega a la cola su stream y
  sus listas, vacíos, y su `DrawCache` (`src/render.cpp:3431`); el siguiente los toma (`CommandQueue::commandBuffer`,
  `src/command.cpp:569`; `CommandBuffer::finish`, `:429`). Los 256 slots del `DrawCache` siguen valiendo —un estado es
  de un programa mientras tenga ese uid—, así que el frame siguiente encuentra los estados sin el cerrojo de la cola;
  `DrawCache::epoch` cuenta command buffers y el de cada slot dice si este ya ha nombrado y retenido los buffers de
  los dos programas del estado.
- `CommandBuffer::PassReturn` (`include/…/command.hpp:363`, `src/render.cpp:4213`): un pase abierto que se suelta
  (`open_.reset()` en `closePass`, sin tocar) vuelve a la cola como nuevo en todos sus campos (`*p = OpenPass{}`)
  salvo la memoria de sus streams, sombras y caché; `draw()` toma de ahí su pase.

### 3.7 `appendStream` (`316d077`)

Copiaba el stream de un pase paquete a paquete (decodificar, volver a hacer, un `insert` por paquete) para llegar a
las mismas palabras. Es un NOP y un `append` (`src/render.cpp:4158`).

### 3.8 Plug-in ObjC (`6c42baf`)

- `-hakiosProgramFor:offsets:count:` (`CA.m:7526`) buscaba la variante de un über-shader con un `NSData` nuevo, un
  `NSDictionary` y `@synchronized` en cada draw. Los contenidos vistos son arrays en el pipeline (bytes, hash,
  programa; 64 como antes) bajo un `os_unfair_lock` que solo dura la búsqueda; los bytes se leen una vez, a la pila.
- `hakios_metal_cb_set_vertex_textures` se llamaba antes de cada draw; se llama en el primer draw de un encoder y
  cuando cambia una textura o sampler de vértices (`_vsTexturesTold`, `CA.m:8451`).
- Interruptores (boot-args o `/var/tmp/metal.args`, leídos con la primera cola, `CA.m:5038`): `metal_keep=0` (ningún
  draw desde estado guardado: mismo stream, es el A/B del estado guardado con un solo binario) y `metal_verify=1` (§4).
- `passes:` (con `metal_fps=passes`) separa, por pasada en tiles, `wrote` (attachments con salida del stage de
  fragmento) y `read` (leídos por fetch), y añade el motivo de las que quedan en sysmem.

### 3.9 Cierre de pase y fusión con `gpu-pass` (`98d2c3c`, `2ee78db`, `db05cce`, `6867870`)

La rama `gpu-pass` (14) cambia de qué está hecho un pase en tiles al cerrarse (bins de turnip, bins solo para los
attachments tocados, draws como grupos de estado, barrera del fetch como grupo, tiles o sysmem según lo que contiene
el pase). Está fusionada entera (hasta `fa8d36c`). Conflictos y cómo quedan: la llamada a `gmemPlan` en
`CommandBuffer::draw` (su flag, mi `whyNotTiled()`); el fake GPU (las dos ramas corregían `kGmemBase`: sus líneas; las
adiciones de las dos a `fake_gpu.hpp`); cuatro tests de bins (los suyos, que ya son por chip); `tools/dev.mk`
(`gmem.cpp`). Lo que las une: `closePass` lee los draws grabados (`render::drawStates`, `src/gmem.cpp:158`) y un draw
desde estado guardado deja las mismas palabras que uno por el camino largo, así que los grupos salen iguales.

Sobre lo fusionado:
- `drawStates` trabaja en un `Work` por hilo (`src/gmem.cpp:107`) y escribe cada fragmento donde queda; `closePass`
  (`src/render.cpp:5049`) usa el scratch del command buffer para tiles, cola, copia de draws y grupos (`db05cce`):
  mismas palabras, 5,6 → 1,1 asignaciones por draw en la escena U.
- Un pase grabado de las dos formas se graba solo para tiles desde el draw en que `gmemWorth` ya no puede elegir
  sysmem (`6867870`, `CommandBuffer::draw`): hay un draw con fetch y el pase tiene `kGmemFewDraws` draws, o
  draws × bytes tocados ≥ listón × bytes de todos los attachments (cota de la regla de `gmemWorth`), o, con
  `kGmemByDrawsAlone`, los draws llegan al listón. Cambia dos cosas y nada más: los draws con fetch dejan de pedir una
  segunda tabla para el lado sysmem (cambian direcciones de tablas posteriores, no el contenido de ninguna carga), y
  un draw que no se puede dibujar en tiles, si llega después de esa decisión, cierra el pase en tiles y abre uno
  sysmem (antes el pase entero caía a su grabación sysmem).

## 4. Cómo se sostiene que el stream es el mismo

1. **Golden streams** (`397bd3e`, `68e8725`; `tests/golden.hpp`, `tests/golden/`): `FakeGpu::submitHook` entrega cada
   envío y se suman (a) las palabras que lee el procesador de comandos, incluidos los cuerpos de cada
   `CP_INDIRECT_BUFFER` y los fragmentos de cada `CP_SET_DRAW_STATE`; (b) los bytes que nombra cada carga indirecta
   (tablas de un draw, programas), resolviendo los `CP_MEMCPY`; (c) los buffers que el envío nombra al kernel con sus
   flags, en cualquier orden. Una línea por test y por escena de `drawbench`, para los dos chips.
   `make -f tools/dev.mk check` compara.
2. **Tres vías** del mismo binario, comparadas por `check`: estado guardado con cada draw comprobado; sin comprobar
   (`tests --unchecked`, como corre en el teléfono); y todo por el camino largo (`CommandBuffer::keepStates(false)`,
   `tests --long`, `drawbench --long`).
3. **`CommandBuffer::verifyDraws`** (`include/…/command.hpp:221`; `metal_verify=1` en el teléfono): cada draw tomado
   de un estado guardado se escribe además entero, a través de una copia de la sombra puesta al día, y se comparan
   las palabras y los bytes de la tabla (`verifyDraw`, `src/render.cpp:4111`). Una diferencia falla el command buffer
   y dice cuál: «a draw of X from its kept state: word 12 of 85 is 0x…, 0x… the long way».
4. **`tests/draw_state_test.cpp`**: los casos en que un estado guardado sería falso si se guardase mal (programa
   cambiado tras dibujar con él, otro tipo de pase, enlaces que el estado no puede tomar, más programas que slots) y
   **frames aleatorios** grabados de las dos formas —la mitad de los draws nuevos, la mitad el anterior con una cosa
   cambiada, uno de cada cuatro mal en una cosa—: los mismos draws tomados, los mismos rechazos con las mismas frases,
   los mismos pases, los mismos envíos (39 692 draws tomados, 26 778 desde estado guardado, 6 388 rechazados, por chip).
5. **Mutaciones**: 16 defectos sembrados uno a uno en el camino corto (una comprobación quitada de `fastFacts`, un
   campo fuera de la comparación de un `Cursor`, un buffer sin nombrar, un slot rancio, el formato fuera de la clave…):
   los 16 hacen fallar la suite. Cuatro de ellos no la hacían fallar antes de los frames aleatorios; por eso existen.
6. **Contra el camino de draw de la base** (`drawbench --each`, `5307915`): cada uno de los 184 programas de la caché
   del teléfono, solo, en una cadena como la de un blur (1/16 de pantalla RGBA16Float con Clear → 1/4 BGRA8 muestreando
   el anterior → pantalla con dos attachments), en sysmem, como graba el plug-in y en tiles forzados. Las 552 líneas
   son idénticas entre `b935418` (camino de draw de la base) y esta rama antes de la fusión; después de la fusión,
   idénticas en sysmem y en el modo del plug-in (368 de 368) y distintas en tiles forzados, que es lo que `gpu-pass`
   cambia. Referencia: `cpu-tools/each-base-a610.txt`.
7. **El procedimiento de build**: `out/cpu-bis-base` (`620950c` compilado con el procedimiento de §7) tiene todas las
   secciones Mach-O idénticas byte a byte a `out/propio-args` (`__text` 2 509 412 bytes, `__const`, `__cstring`,
   metadatos ObjC, datos); difieren las rutas del mapa de depuración y la firma.

Lo que cambia el stream a propósito, y cómo se valida: la fusión de `gpu-pass` (sus tests y el fake GPU; golden
regenerados, sysmem sin cambio) y el corte de la grabación doble de §3.9 (cuentas de palabras y de cargas y suma del
contenido de las cargas iguales; solo cambia la suma de direcciones).

## 5. Tabla antes/después en host

i5-7500, constantes del A610, `cpu-tools/measure.sh` (3 ejecuciones × 5 frames medidos por escena; «1 MiB» y «16 MiB»:
kilobytes tocados antes de cada draw). µs por draw: mediana de las medianas (mínimo de todos los frames).
`base` = `b935418` (camino de draw de `620950c`); `A1` = `afc2eca`; `merge2` = `6d3f273`.

| Escena | draws | base caliente | base 1 MiB | base 16 MiB | A1 caliente | merge2 caliente | merge2 1 MiB | merge2 16 MiB | asign./draw base → A1 → merge2 |
|---|---|---|---|---|---|---|---|---|---|
| D (núcleo, sysmem) | 143 | 5,48 (5,03) | 6,51 | 19,00 | 1,94 | 1,84 (1,54) | 2,79 | 9,38 | 18,9 → 1,2 → 0,6 |
| R (núcleo, sysmem) | 108 | 5,26 (4,89) | 6,99 | 14,02 | 1,78 | 1,63 (1,26) | 2,25 | 10,10 | 19,5 → 0,8 → 0,4 |
| P (núcleo, tiles) | 108 | 9,14 (8,79) | 10,91 | 18,36 | 2,64 | 2,38 (2,03) | 2,98 | 10,29 | 33,8 → 1,1 → 0,5 |
| J (interfaz C, 20 draws) | 20 | 10,58 (8,26) | 12,18 | 18,89 | 5,49 | 3,42 (2,62) | 3,78 | 9,35 | 28,6 → 6,4 → 0,7 |
| K (interfaz C, tiles) | 110 | 12,45 (11,90) | 14,41 | 24,59 | 3,91 | 3,09 (2,81) | 3,72 | 13,58 | 42,1 → 4,0 → 0,3 |
| L (interfaz C, sysmem) | 110 | 7,02 (6,92) | 8,99 | 18,99 | 2,55 | 1,97 (1,79) | 2,84 | 13,30 | 25,7 → 3,7 → 0,2 |
| S (stages del teléfono, tiles) | 110 | 18,97 (17,74) | 20,53 | 35,21 | 6,78 | 5,13 (4,67) | 7,80 | 17,37 | 64,7 → 6,2 → 0,4 |
| T (stages del teléfono, sysmem) | 110 | 10,88 (10,02) | 12,39 | 41,90 | 3,71 | 3,40 (2,82) | 4,53 | 12,10 | 38,3 → 5,8 → 0,2 |
| U (5 pasadas de 22) | 110 | 10,17 (9,70) | 12,26 | 27,09 | — | 7,72 (7,07) | 8,92 | 16,63 | 36,6 → — → 1,1 |

- Las escenas en tiles y U incluyen, en `merge2`, el cierre de pase de `gpu-pass` dentro del primer draw del pase
  siguiente (U: `closePass` 38 % del tiempo de grabación antes de `db05cce`; `drawStates` 21 %, `encodeGmem` 11 %).
- Tras `6867870` (corte de la grabación doble), mínimo de 12 frames: S 4,75 → 3,21; K 2,78 → 2,04; Q 3,47 → 2,55;
  U 7,1 → 6,7.
- B (20 draws, 5 con fetch) sube de 9,06 a 9,33: desde `gpu-pass` un pase con fetch va a tiles y se graba doble hasta
  el quinto draw.
- La máquina estuvo cargada por otros trabajos durante parte de las medidas: el mínimo es el número fiable; las
  diferencias por debajo del 5 % no lo son.

## 6. Teléfono

[M] Medidas del coordinador (`medicion/ab/`, `homeswipe 8`, GPU a 820 MHz, resumidas con `ab-sum.py`; n=1 por fila
salvo donde hay dos archivos):

| Archivo | Bundle | Kernel | buffers/s | draws/buffer | CPU/draw | hecho→commit |
|---|---|---|---|---|---|---|
| `ab-real-propio-args` | `propio-args` (base) | 0342 | 22,3 | 129 | 142 µs | 24,9 ms |
| `ab-real-cpu-A-wip` | `cpu-A-wip` (`99279c0` + plug-in) | 0342 | 29,4 | 126 | 59 µs | 13,6 ms |
| `ab-real-gpu-G4` | `gpu-G4` (solo `gpu-pass`) | 0342 | 23,1 | 125 | 171 µs | 28,6 ms |
| `ab-k347-merge-1-{a,b}` | `merge-1` (`98d2c3c`) | 0347 | 30,5 / 25,8 | 123 / 133 | 69 / 61 µs | 13,9 / 13,6 ms |
| `ab-k350-idle1-10354` | `merge-1` | 0350, vaciado de L2 en reposo activo | 29,6 | 127 | 62 µs | 15,0 ms |
| `ab-k350-idle0-10354` | `merge-1` | 0350, `kern.sweet_idle_cache=0` | 44,0 | 122 | 26 µs | 5,6 ms |
| `ab-k350-merge2-b` | `merge-2` (`6d3f273`) | 0350, `idle_cache=0` | 47,8 | 143 | 20 µs | 6,0 ms |
| `ab-k350-merge2-passes` | `merge-2`, `metal_fps=passes` | 0350, `idle_cache=0` | 51,6 | 126 | 17 µs | 4,0 ms |

### 6.1 Por qué el teléfono iba ~13× más lento por draw que el host

- [O] Con programas reales por la interfaz C, el host no cuesta 3-9 µs sino 10,9 (T) a 19,0 (S) µs por draw en la
  base, y 12-42 con las cachés frías.
- [O] En bucles de CPU puros (gawk, bash, n=3) el teléfono es 5-10× más lento que el i5-7500.
- [M] El resto era el kernel: XNU vaciaba la L2 del clúster A73 en cada entrada en reposo (03 M11). Con
  `kern.sweet_idle_cache=0` el mismo bundle `merge-1` pasa de 62 a 26 µs por draw. Es lo que predecía el host: el
  camino corto cuesta 3,4 µs caliente y 12,1 µs con 16 MiB tocados antes de cada draw (T), y el teléfono se comportaba
  como el caso frío × la diferencia de CPU.
- [M] Perfil del hilo de render con `merge-1` y la L2 viva (`medicion/perfil-merge1-l2.txt`): 61,8 % en usuario; de
  ese tiempo QuartzCore 52,7 %, el driver 24,7 % (`-hakiosDraw:` 27,1 % inclusive: `CommandBuffer::draw` 23,8 %,
  `emitFast` 10,5 %, `DedupSink::registers` 5,2 %, `closePass` 6,4 %, `drawStates` 3,0 %, commit 2,1 %, liberar el
  command buffer 2,0 %), `malloc` 9,3 % (6,1 % llamado por QuartzCore). El hilo ya no está saturado; el límite es la GPU.
- De lo que ese perfil señala, `merge-2` quita: la redecodificación de `appendStream` (1,4 %), las consultas a la
  sombra por cambio de programa, las asignaciones del cierre de pase y de liberar el command buffer.

### 6.2 Qué dice `metal_fps=passes` con `merge-2`

[M] `ab-k350-merge2-passes.txt` (39 líneas `passes:`; cada bloque es un buffer: la cabecera es la suma de sus líneas,
y cada ms es tiempo de GPU entre el inicio de la pasada y el final de su cola, por el contador always-on del CP):
6 pasadas `750x1624 tiles 78 touched 0x103`, media 10,46 ms con 102 draws; 1 `tiles 78 touched 0x303`, 9,75 ms con
39 draws; `tiles 42 touched 0x101`, 3,34 ms con 73 draws; `tiles 42 touched 0x301`, 2,39 ms con 52 draws; 3 sysmem de
20 draws, 0,56 ms. El byte bajo 0x03 dice que en las pasadas de 78 tiles algún draw escribe o lee de verdad el segundo
attachment; cuando solo se toca el primero salen 42 tiles. Esas pasadas cuestan ~0,10 ms por draw frente a ~0,046.
[H] Qué draws tocan el segundo attachment y si lo escriben o solo lo leen no está medido (el campo `wrote`/`read` de
§3.8 lo separa en la siguiente captura).

## 7. Cómo construir y medir

```sh
R=~/sapphire-angel/research/metal/rebuild
# host: tests y golden por las tres vías, los dos chips, y las escenas con los stages del teléfono
$R/cpu-tools/check.sh
make -C $R/wt-cpu/hakios-metal -f tools/dev.mk -j4 CHIP=a610 tests drawbench     # un chip, sin golden
make -C $R/wt-cpu/hakios-metal -f tools/dev.mk CHIP=a610 golden                  # reescribir golden (decirlo en el commit)
# medir: 3 ejecuciones × caliente/1 MiB/16 MiB, y tabla
$R/cpu-tools/measure.sh ETIQUETA && python3 $R/cpu-tools/table.py base A1-kept merge2 ETIQUETA
$R/cpu-tools/ab-host.sh "ETIQUETA1 ETIQUETA2" KLSTU      # A/B de binarios en cpu-tools/bin/drawbench-ETIQUETA
# perfil: un proceso que solo graba
$R/wt-cpu/hakios-metal/out/dev-a610/drawbench --runs 1 --record 30000 --scene U --stages DIR &  sample $! 8
# bundle para iOS (clang 18.1.8, SDK de theos; firma ad hoc; con la clave de caché de stages de propio-args)
cd $R && SRC=$R/wt-cpu IOS_EXTRA="-g" CACHE_BUILD=24ed84207640dc54c2b865f7 ./build-bundle.sh $R/out/NOMBRE
```

- La clave de caché de stages se fija a la de `propio-args` porque el compilador no cambia: de `620950c` a la punta,
  `src/compiler.cpp` gana tres líneas (el uid) y ni `kernel.hpp` ni `Stage` cambian; la caché del teléfono sigue
  valiendo.
- El build de iOS usa la libc++ 15 del SDK: compilar el bundle después de cada cambio de cabeceras (un
  `unique_ptr` con deleter anidado compilaba en el host y no ahí, `6d3f273`).
- Los bundles son mayores que `propio-args`: instalar por renombrado, no copiando encima (el instalador que copiaba
  sobre el vnode hacía que dyld rechazase el binario y CoreAnimation compusiera por software: fondo de la Biblioteca
  de Apps sin blur, 434 % de CPU en backboardd, consola vacía).
- Punta de la rama y bundle: ver «Estado al cerrar».

## 8. Interfaces compartidas y riesgos

### 8.1 Qué cambia en interfaces que usan otros

| Interfaz | Cambio | Para qué |
|---|---|---|
| `CommandBuffer::keep`, `keepAlive`, `use` | Por referencia y con filtro de recientes (`recently`) | Sin copias de `shared_ptr` ni listas del tamaño del frame |
| `OpenPass` | Campos `cache` (`PassCache`) y `tiledEarly`; se recicla (`PassReturn`), `open_` es `OpenPassPtr` | §3.2, §3.6, §3.9 |
| `CommandBuffer::Counts` | `keptDraws` | Tests |
| `CommandBuffer::PassTime` | `wrote`, `read` | `passes:` |
| `CommandBuffer::piece` | Parámetro `asIs` | §3.5 |
| `CommandQueue` | `states()`, `Spare`, `takePass`/`givePass`, `takeSlab(…, usedBefore)`, `poisonReused` | §3.2, §3.5, §3.6 |
| `Program` | `uid` | §3.2 |
| `FakeGpu` | `submitHook`, `peek`, `named()`; constantes atadas a su programa | Golden; §2 |
| `render::vscOverflowWordAt()` | Nueva; `checkVsc` la usa | §2 |
| `appendStream` | Copia en bloque | §3.7 |
| `render::drawStates` | Almacenamiento por hilo; mismo resultado | §3.9 |
| Interfaz C | `hakios_metal_draw_states`, `hakios_metal_cb_pass_access`, `hakios_metal_program_from_stages` (tests) | §3.8, §4 |

`RegShadow` no cambia. Una sombra por páginas de registros (en vez de la tabla hash) se probó y se descartó: sin
ganancia caliente y peor con cachés frías [O].

### 8.2 Riesgos

- **`Texture::sampledWords`** supone que el descriptor de una textura no cambia tras crearla. Hoy es así: los campos
  que lee `sampledDescriptor` se fijan en las funciones que crean la textura (`src/texture.cpp`). Una textura cuyo
  buffer o swizzle se cambiase después dejaría el descriptor guardado rancio.
- **Programas cambiados sin renovar el uid**: quien cambie un `Program` enlazado sin pasar por los setters de la
  interfaz C debe darle otro `uid`; si no, se dibuja con el estado antiguo. `metal_verify=1` lo detecta.
- **Tabla de draw sin poner a cero**: si el hardware leyese descriptores más allá de los que nombran las cargas (los
  registros `SP_xS_TEX_CONST/SAMP` apuntan a la tabla), leería restos de otro frame. En el camino corto solo se
  escriben los descriptores que el stage declara. No verificado en el teléfono más allá de que pinta bien; `metal_keep=0`
  hace escribir las tablas completas.
- **Vida de los estados**: un `ProgramState` retiene los buffers de sus dos programas; la cola borra todos al pasar de
  4096 y un `DrawCache` los suelta al pasar de 1024.
- **Decisión de tiles adelantada** (§3.9): un draw no tileable tras la decisión parte el pase en dos (tiles + sysmem).
  Correcto en el fake; no medido en el teléfono.
- **Plug-in**: `-hakiosProgramFor:` y `_vsTexturesTold` no tienen test de host (el plug-in no se compila en el host);
  están verificados en el teléfono solo por que `cpu-A-wip`, `merge-1` y `merge-2` pintan bien home, widgets y
  Biblioteca de Apps [M].
- **Grabación diferida (`metal_defer=1`)**: el camino `DrawCopy` de la interfaz C no está optimizado ni medido aquí.

## 9. Qué falta

### 9.1 Etapa B (estado incremental)

No está hecha como la describe 10 §2.7, por una razón de diseño que la fusión hace visible: `render::drawStates`
construye, para los pases en tiles con binning, un fragmento por grupo y draw con *todas* las cargas del draw, porque
un tile puede saltarse el draw anterior. Si un draw dejase de emitir las cargas que no cambian respecto al anterior,
el conversor tendría que llevar las cargas vigentes como lleva los registros. En sysmem (donde el stream se ejecuta tal
cual) sí cabe: no repetir preload, inmediatos y `HLSQ_INVALIDATE_CMD` cuando el programa es el del draw anterior, y
las cargas de constantes y texturas cuando no cambian, con la regla de turnip (al reemitir el grupo de programa se
reemiten todas). Requiere que el fake GPU modele la invalidación (hoy `HLSQ_INVALIDATE_CMD` es un registro más para
él). Otra parte de B que sí es compatible con todo: tablas de draw compactas y reutilizadas cuando texturas y samplers
son los del draw anterior (hoy cada draw toma 8 KiB alineados a página y toca 4-6 líneas frías).

### 9.2 CPU del driver que queda (por el perfil de §6.1 y el de host)

- `emitFast`/`emitDraw<DedupSink>` para los grupos que se hacen de nuevo en cada draw (viewport y scissor en un solo
  grupo: el viewport se recalcula cuando solo cambia el scissor; cargas de constantes; fetch de vértices).
- `drawStates` y `encodeGmem` en el cierre de un pase en tiles: sin asignaciones ya, pero O(draws × registros del
  grupo) y ~60 llamadas por tile; una plantilla de tile y fragmentos por diferencia los abaratarían.
- La primera emisión de cada programa en cada pase pasa entera por la sombra (la cabecera del pase puede haber
  escrito esos registros).
- `StateCache::find` bajo cerrojo en el primer draw de cada programa de un command buffer cuyo `DrawCache` no lo
  tenga.

### 9.3 Lo que el driver induce en QuartzCore

[M] QuartzCore es el 52,7 % del hilo de render y pide el 6,1 % en `malloc`. No está analizado qué parte provoca el
plug-in: candidatos a medir son `-hakiosRefreshShadow` en cada `setFragmentTexture` (1,1 %), `-hakiosConvertYCbCr`
(0,9 %), `newTextureWithDescriptor:iosurface:` por frame (0,9 %), `setRenderPipelineState:` (0,7 %) y las respuestas
a consultas de capacidades.

### 9.4 Tiempo de GPU

La pasada principal en 78 tiles cuando se toca el segundo attachment (§6.2) es lo que domina el envío. Saber si se
escribe o solo se lee, y qué draws, es el siguiente dato a capturar (`metal_fps=passes` con el bundle de la punta;
`metal_fps=draws` sin `metal_gmem` para el desglose por draw).

## Estado al cerrar

(se completa al final de la sesión)
