# 13 — Driver Metal: coste de CPU por draw (etapas A y B de 10 §2.7) y conformidad con lo que pide CoreAnimation, 2026-11-14

Informe fechado de implementación. Alcance: el núcleo C++ de `hakios-metal` y lo que el plug-in ObjC hace en cada
draw, sobre la base upstream de HackiOS `63fc2b4` + parches A610 propios + opcionales (08 §5), y la fusión de la rama
`gpu-pass` (14) en esta. El diagnóstico de partida es 10 §2; los datos del teléfono, 03 M1, M2, M6 y M11. Desde la
fusión la rama lleva también las correcciones de lo que el driver hacía distinto de lo que Metal exige y CoreAnimation
pide (lista de 19 §2.9), guiadas por trazas de frames reales: §10.

Convención de evidencia, la de 10: **[O]** observación propia (código con `archivo:línea` o medida reproducible),
**[M]** medida del teléfono tomada por el coordinador (archivo citado), **[H]** hipótesis sin medir.

Árbol de trabajo: `~/sapphire-angel/research/metal/rebuild/wt-cpu` (worktree de `hakios-upstream`), rama `cpu-draw`,
creada desde `opcional-puerto` (`620950c`). Las rutas `src/…`, `include/…`, `tests/…`, `tools/…` son de
`wt-cpu/hakios-metal/`; `CA.m` es `wt-cpu/userland/src/HakiosMetalCA.m`. Los números de línea son los de la punta de
la rama, `f58c688` (§11.1). Herramientas y resultados fuera de git: `rebuild/cpu-tools/`. Quien continúe este trabajo
empieza por §11 (Relevo).

## Resumen

| | Base (`propio-args`, `620950c`) | Rama `cpu-draw` |
|---|---|---|
| Teléfono, CPU por draw en el hilo que llama [M] | 142 µs (130-172) | 59 µs con `cpu-A-wip`; 16-20 µs de `merge-2` a `merge-7` con el kernel 0350 en adelante (§6) |
| Teléfono, buffer hecho → commit [M] | 24,9 ms | 13,6 ms (`cpu-A-wip`); 2,4-6,0 ms (`merge-2` a `merge-7`, kernel 0350 en adelante) |
| Teléfono, pasada principal del home en la GPU [M] | — | 10,5-11,4 ms guardando el segundo attachment (`merge-2`, `merge-3`); 9,6-11,2 ms sin guardarlo (`merge-4`, §10.2) |
| Teléfono, codificación más larga de un buffer la primera vez que se abre el selector de apps · el Centro de Control [M, n=1 o 2] | — | 228 y 470 ms · 1 318 ms con `merge-5`; 51,9 · 69,8 ms con `merge-6` (§10.6) |
| Host, escena T (interfaz C, stages del teléfono, sysmem), µs por draw [O] | 10,88 | 3,40 (mínimo 2,82) |
| Host, asignaciones de heap por draw, escena T [O] | 38,3 | 0,2 |
| Palabras PM4 que recibe el procesador de comandos | — | las mismas, palabra por palabra, en todo lo que la rama `gpu-pass` y las correcciones de §10.2 no cambian a propósito (§4) |

- El objetivo de < 10 µs por draw en el teléfono **no se alcanza**: 16-20 µs [M]. Qué queda y por qué: §6 y §9.
- La etapa B tal como la describe 10 §2.7 (cargas de estado elididas cuando no cambian) **no está hecha**: choca con
  cómo `gpu-pass` convierte los draws de un pase en grupos de estado (§9.1). Lo que sí cambia el stream está en §3.9
  y §10.2.
- Con la CPU en 16 µs por draw el límite es la GPU. §10 recoge lo que las trazas de frames reales muestran que el
  driver hacía de más o distinto de lo pedido y lo corregido: siete filas de §10.2 (cada una con su prueba de host
  donde el código es del núcleo) y una octava, N-07, hecha y apagada porque depende de otra que no lo está (N-12,
  §10.7).
- El tirón de la primera vez que se abre una vista era la espera por el compilador de shaders, no la compilación del
  pipeline que se crea; la causa de fondo, que la clave de especialización incluía bytes de relleno (§10.6).
- Bundles en `rebuild/out/`: `cpu-A-wip` y `merge-1` a `merge-7`, todos probados en el teléfono por el coordinador;
  el instalado es `merge-7` (`96d9bac`). Estado exacto de la rama, comandos, mapa del código, pendientes, diseño sin
  implementar y trampas: §11.

## 1. Punto de partida medido

### 1.1 En el teléfono (base `propio-args`, la misma fuente que `620950c`)

[M] `medicion/ab/ab-real-propio-args.txt` (kernel 0342, GPU a 820 MHz; resumido con `ab-sum.py`): 142 µs de CPU
por draw en el hilo que llama («of ours each», 130-172 según el periodo), de ellos 124-161 dentro de
`hakios_metal_cb_draw_indexed`/`_draw3` («the core's», cronometrado en `-hakiosDrawOnce:`, `CA.m:10176`); 129 draws
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

Con esto, 261/261 con las constantes de los dos chips en la base; la punta de la rama pasa 284 con las dos (269
propios y 11 de `gpu-pass` en la fusión, más las cuatro pruebas de §10.2).

## 3. Qué se cambió, por función

El camino de un draw en la base: `hakiosDrawOnce` (ObjC) → `drawCommon` (`src/c_api.cpp`) → `CommandBuffer::draw` →
`render::encodeInPass` valida todo y genera ~590 palabras en un stream temporal → `appendDeduped` lo relee paquete a
paquete y descarta, contra una sombra de registros (`RegShadow`), las ~9 de cada 10 palabras que ya valían.

### 3.1 Un draw en dos mitades: hechos y emisión (`6f2e4e0`)

`render::encodeDraw` queda partido en `drawFacts` (`src/render.cpp:1383`), que juzga el draw en el orden de siempre
y deja lo que decide el stream (`ProgramFacts`: lo que deciden el programa y el pase; `DrawFacts`: lo que añaden los
enlaces y números del draw), y `emitDraw<S>` (`:1719`), que escribe el stream grupo a grupo según una máscara
(`kG…`, 29 grupos). `encodeDraw` es el envoltorio de los dos. De paso desaparecen las asignaciones que no eran del
draw: la copia del stage de fragmento para borrar regids, vectores por stage para rangos y UBOs, un vector por carga
(`pm4::Stream::open` escribe las palabras donde quedan), los `std::string` de nombres construidos al entrar.

### 3.2 El estado de un programa se guarda (`afc2eca`)

- `ProgramState` (`:3292`): para un programa en un tipo de pase (`StateKey`, `:3175`: formato de cada attachment,
  si hay depth, todas las opciones), los veredictos de `checkStage`, `link` y las palabras de blend (`ProgramFacts`),
  lo que cada stage necesita ligado (`StagePlan`, `:3192`), los atributos de vértice como los lee `vertexFetch`, y las
  palabras de los grupos que son solo del programa tal como las escribió `emitDraw` (`buildState`, `:3513`). Vive en
  la cola (`StateCache`, `:3328`, por `Program::uid`) para un programa con uid; en el command buffer, junto a una copia
  del `Program` comparada byte a byte, para uno hecho a mano.
- `Program::uid` (`include/…/render.hpp`): lo da `linkProgram` y lo renueva cada setter de la interfaz C que cambia el
  programa después (descriptor de vértices, blend, muestras; `src/c_api.cpp`): un programa cambiado es otro programa.
- `PassCache` (`:3440`, en `OpenPass::cache`): ventana y muestras que `checkTarget` calculó, los grupos propios del
  pase por lo que dibuja cada programa, los descriptores de fetch de los attachments y, por cada stream del pase, un
  `Cursor` (`:3371`): las palabras que el stream tuvo por última vez de cada grupo guardado y los números con que se
  hicieron los grupos propios del último draw (viewport, raster, blend dinámico, fetch de vértices).
- Un draw con estado guardado: `fastFacts` (`:3663`) y `fastTables` (`:3851`) son las reglas de `drawFacts` para lo
  que trae el draw —enlaces, cuentas, viewport, scissor, depth/stencil, índices— y escriben los descriptores de
  textura, sampler e IBO directamente en la tabla del draw (`Texture::sampledWords`, `src/texture.cpp:851`, guarda las
  16 palabras de una textura). Lo que no pueden asegurar va por el camino largo, donde `drawFacts` lo juzga y lo
  rechaza con la frase de siempre. `emitFast` (`:3922`) recorre los grupos en el orden de un draw: un grupo guardado
  cuyas palabras son las últimas que tuvo el stream se salta; uno hecho de números del draw se hace cuando los números
  no son los del draw anterior; las cargas de los stages y `HLSQ_INVALIDATE_CMD`, que ninguna sombra descarta, se
  añaden tal cual en cada draw.
- `DedupSink` (`:3122`): la regla de `appendDeduped` aplicada mientras se generan las palabras, sin stream intermedio.
- `keep()`/`use()` (`include/…/command.hpp:125`, `:271`) reciben una referencia y recuerdan lo último que se les dio
  (`recently`, `:277`): un draw nombra los mismos buffers y texturas que el anterior. La lista de buffers del envío es
  la misma (§4).
- El primer draw con un programa, un draw con memoria privada, uno indirecto, uno que cuenta muestras y todo pase sin
  deduplicación van por el camino largo (`drawFacts` + `emitDraw` a través de `DedupSink`).

### 3.3 Un grupo guardado que cambia se compara con el anterior (`343cc35`)

Cuando el programa de un draw no es el del anterior, sus grupos guardados pasaban enteros por la sombra: unas 350
consultas a una tabla hash para encontrar las pocas decenas de registros que difieren. El `Cursor` sabe qué palabras
tuvo el stream de cada grupo; para un grupo *plano* (solo paquetes de registros, ningún registro dos veces, sin
`HLSQ_INVALIDATE_CMD`; `packetsOf`, `:3263`) esas palabras son lo que valen sus registros, así que el grupo nuevo se
compara con ellas (`emitFast`, lambda `kept`): un registro que escriben los dos se emite si difiere, sin preguntar a
la sombra; uno que el anterior no escribía lo decide (y lo aprende) la sombra; uno que el anterior escribía y este no,
vuelve a la sombra. `Cursor::settle` pone la sombra al día antes de un draw por el camino largo. Lo que esto supone
—que los registros de un grupo guardado no los escribe ningún otro grupo— se comprueba para cada programa al hacer su
estado (`buildState`): si no se cumple, ese programa va siempre por el camino largo.

### 3.4 Interfaz C (`25ad496`)

`drawCommon` (`src/c_api.cpp:1452`) creaba dos `Bindings` por draw (seis vectores) y llamaba a `bindArgumentBuffers`
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

- `CommandQueue::Spare` (`include/…/command.hpp:504`): un command buffer que termina entrega a la cola su stream y
  sus listas, vacíos, y su `DrawCache` (`src/render.cpp:3461`); el siguiente los toma (`CommandQueue::commandBuffer`,
  `src/command.cpp:569`; `CommandBuffer::finish`, `:429`). Los 256 slots del `DrawCache` siguen valiendo —un estado es
  de un programa mientras tenga ese uid—, así que el frame siguiente encuentra los estados sin el cerrojo de la cola;
  `DrawCache::epoch` cuenta command buffers y el de cada slot dice si este ya ha nombrado y retenido los buffers de
  los dos programas del estado.
- `CommandBuffer::PassReturn` (`include/…/command.hpp:373`, `src/render.cpp:4246`): un pase abierto que se suelta
  (`open_.reset()` en `closePass`, sin tocar) vuelve a la cola como nuevo en todos sus campos (`*p = OpenPass{}`)
  salvo la memoria de sus streams, sombras y caché; `draw()` toma de ahí su pase.

### 3.7 `appendStream` (`316d077`)

Copiaba el stream de un pase paquete a paquete (decodificar, volver a hacer, un `insert` por paquete) para llegar a
las mismas palabras. Es un NOP y un `append` (`src/render.cpp:4191`).

### 3.8 Plug-in ObjC (`6c42baf`)

- `-hakiosProgramFor:offsets:count:` (`CA.m:9163`) buscaba la variante de un über-shader con un `NSData` nuevo, un
  `NSDictionary` y `@synchronized` en cada draw. Los contenidos vistos son arrays en el pipeline (bytes, hash,
  programa y la máscara de los bytes que decidieron su compilación; 128 ranuras, §10.6) bajo un `os_unfair_lock` que
  solo dura la búsqueda; los bytes se leen una vez, a la pila.
- `hakios_metal_cb_set_vertex_textures` se llamaba antes de cada draw; se llama en el primer draw de un encoder y
  cuando cambia una textura o sampler de vértices (`_vsTexturesTold`, `CA.m:10252`).
- Interruptores (boot-args o `/var/tmp/metal.args`, leídos con la primera cola, `CA.m:6352-6367`): `metal_keep=0` (ningún
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
  (`src/render.cpp:5120`) usa el scratch del command buffer para tiles, cola, copia de draws y grupos (`db05cce`):
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
3. **`CommandBuffer::verifyDraws`** (`include/…/command.hpp:224`; `metal_verify=1` en el teléfono): cada draw tomado
   de un estado guardado se escribe además entero, a través de una copia de la sombra puesta al día, y se comparan
   las palabras y los bytes de la tabla (`verifyDraw`, `src/render.cpp:4144`). Una diferencia falla el command buffer
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
| `ab-k352-merge3-a` | `merge-3` (`4e0a51a`) | 0352 | 49,0 | — | 16 µs | 4,8 ms |
| `ab-k353-merge4-a` | `merge-4` (`81dd364`), `metal_fps=passes` | 0353, escalado directo por el DPU | 48,9 | — | 16 µs | — |
| `ab-k353-todo-{1,2}` | `merge-5` (`4cf8232`) | 0353, escalado directo y actualizaciones parciales de CoreAnimation (la configuración «todo» del coordinador) | 55,1 / 58,3 | 75 / 74 | 16 µs | 6,0 / 2,4 ms |
| `ab-k353-merge7` | `merge-7` (`96d9bac`) | 0353, otro arranque | 50,7 | 75 | 19 µs | 3,0 ms |

[M] Entre ensayos idénticos de `merge-3` la base varía de 38,7 a 46,3 buffers/s (`ab-k352-m3b-*`): las diferencias
entre filas de menos de ~15 % no dicen nada con n=1. Dos A/B del coordinador sobre `merge-3` que sí separan:
`metal_gmem_off=64` (el cuerpo del pase sin grupos de estado, cada tile repite el estado de todos los draws) baja a
35,3 buffers/s y sube commit→fin de ~28 a 43,8 ms: el trabajo del procesador de comandos por bin pesa;
`metal_gmem_draws=6` no cambia nada medible en el home (44,2 y 48,2 buffers/s).

[M] La fila de `merge-7` no es comparable con las de `todo`: es otro arranque, y las líneas `SWEET FB` del kernel
(`ab-k353-merge7.fb`) dicen que ahí todos los frames pasan por la composición de GPU del kernel (248 a 326 de 248 a
326 swaps por periodo), mientras que en `todo` casi ninguno (10 de 630). Con ello commit→fin es 16,0 ms y la GPU va
al 81 % (7,6 ms y 43-46 % en `todo`). El ensayo que se le parece es `ab-k353-dirty-a` (49,9 buffers/s, 19 µs por
draw, commit→fin 14,3 ms, GPU 71 %; por la hora, `merge-5`: no verificado). Qué opciones del kernel llevaba cada
arranque no está verificado aquí. En `ab-k353-merge7.txt` los pipelines se hacen en 0,5-0,8 ms («2 of 2 stages from
the cache») y no hay ninguna línea `refused`, `stands in for it` ni `specialise:`.

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
[M] Con `merge-3` la pasada principal sale `wrote 0x3 read 0x3` (`ab-k352-merge3-b.txt`): el segundo attachment se
escribe y se lee. Qué es y qué draws lo usan: §10.1.

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

- La clave de caché de stages se fija a la de `propio-args` (`CACHE_BUILD`) porque lo que `compileStage` produce
  para una misma entrada no cambia de `620950c` a la punta: los cambios de `src/compiler.cpp` son el uid, el orden
  entre caché y cerrojo, los tiempos y el índice de buffers conocidos (§10.6), y ni `kernel.hpp` ni `Stage` cambian.
  La caché del teléfono sigue valiendo [M: con `merge-7` los pipelines salen «2 of 2 stages from the cache»]. Sin
  `CACHE_BUILD` la clave es el hash de `src/compiler.cpp`, las cabeceras y los archivos de Mesa (`Makefile:113`):
  cualquier cambio de cabecera vacía la caché del teléfono.
- El build de iOS usa la libc++ 15 del SDK: compilar el bundle después de cada cambio de cabeceras (un
  `unique_ptr` con deleter anidado compilaba en el host y no ahí, `6d3f273`).
- Los bundles son mayores que `propio-args`: instalar por renombrado, no copiando encima (el instalador que copiaba
  sobre el vnode hacía que dyld rechazase el binario y CoreAnimation compusiera por software: fondo de la Biblioteca
  de Apps sin blur, 434 % de CPU en backboardd, consola vacía).
- Punta de la rama, bundles y el resto de comandos (compilador en host, trazas, sintaxis del plug-in): §11.1 y §11.2.

## 8. Interfaces compartidas y riesgos

### 8.1 Qué cambia en interfaces que usan otros

| Interfaz | Cambio | Para qué |
|---|---|---|
| `CommandBuffer::keep`, `keepAlive`, `use` | Por referencia y con filtro de recientes (`recently`) | Sin copias de `shared_ptr` ni listas del tamaño del frame |
| `OpenPass` | Campos `cache` (`PassCache`) y `tiledEarly`; se recicla (`PassReturn`), `open_` es `OpenPassPtr` | §3.2, §3.6, §3.9 |
| `CommandBuffer::Counts` | `keptDraws` | Tests |
| `CommandBuffer::PassTime` | `wrote`, `read`, `loaded`, `stored` | `passes:` |
| `CommandBuffer::closePass` | Parámetros `next` (el pase del draw que lo cierra) y `kept` | Qué guarda un pase con un attachment memoryless (§10.2) |
| `Texture` | `setMemoryless`/`memoryless`; `swizzled` conserva la marca | §10.2 |
| `Draw` | `scissorEmpty` | N-04 |
| `render::Options` | `fbReadOverlap` | N-18 |
| `compileStage` | Mira la caché sin el cerrojo del compilador; `CompileTimes`, `takeCompileTimes()`; `CompiledStage::knownReads` | §10.6 |
| Directorio de la caché de stages | Ficheros `<hash>.known` junto a los `.stage` (`src/compiler.cpp:1323-1395`) | §10.6 |
| `CommandBuffer::piece` | Parámetro `asIs` | §3.5 |
| `CommandQueue` | `states()`, `Spare`, `takePass`/`givePass`, `takeSlab(…, usedBefore)`, `poisonReused` | §3.2, §3.5, §3.6 |
| `Program` | `uid` | §3.2 |
| `FakeGpu` | `submitHook`, `peek`, `named()`; constantes atadas a su programa; `Stats::loadedPixels`; acepta el scissor vacío (1,1)-(0,0) | Golden; §2; §10.2, §10.3 |
| `render::vscOverflowWordAt()` | Nueva; `checkVsc` la usa | §2 |
| `appendStream` | Copia en bloque | §3.7 |
| `render::drawStates` | Almacenamiento por hilo; mismo resultado | §3.9 |
| Interfaz C | `hakios_metal_draw_states`, `hakios_metal_cb_pass_access`, `hakios_metal_program_from_stages` (tests) | §3.8, §4 |
| Interfaz C | `hakios_metal_texture_set_memoryless`, `hakios_metal_texture_memoryless`, `hakios_metal_cb_pass_moved`, `hakios_metal_program_fs_traits`, `hakios_metal_compile_times`, `hakios_metal_program_known_reads`; un scissor de anchura o altura 0 es un scissor vacío | §10 |

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
- **Máscara de bytes leídos** (§10.6): un stage compilado para un buffer conocido vale para todo buffer que coincida
  en los bytes que `foldKnownLoad` plegó. Es correcto mientras lo único que la compilación tome del buffer pase por
  ese plegado: una optimización nueva que lea el buffer conocido por otra vía tiene que anotar sus lecturas.
  `metal_spec_mask=0` devuelve al plug-in la comparación de todos los bytes; el índice del núcleo no tiene interruptor.
- **Buffers *no-copy* y texturas sobre buffer** (N-12, §10.7): son copias hechas al crear. Con las respuestas de
  alineación de la clase base, un tercio de las imágenes de un frame ya llegan así.
- **Red de seguridad de N-01**: si el compilador rechaza un módulo propio se compila la variante cercana y la consola
  lo dice (`refused: … stand in for it`). No ha saltado en ninguna consola desde `merge-4`; si salta, es un defecto del
  compilador que hay que arreglar, no un estado aceptable.

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

La pasada principal en 78 tiles (§6.2) domina el envío del home, y en las transiciones dominan las pasadas a
pantalla completa que quedan en sysmem. Qué las compone, qué se ha quitado y qué falta: §10.

## 10. Lo que pide un frame real y lo que el driver hacía distinto

Con la CPU fuera del camino, lo que queda se ve en trazas de frames reales. El modo `metal_trace=frame` del estudio
19 §5.3 está portado a la rama (`8707158`): al tocar `/var/tmp/metal.trace` el plug-in vuelca K command buffers
enteros (attachments con sus acciones, texturas con su memoria, pipelines con el origen del código de cada etapa,
draws con área, vértices transformados y enlaces, y cada pasada del núcleo con su modo, tiles y tiempo de GPU).
Capturas del coordinador con el bundle de traza sobre `merge-1`, kernel 0352 a 820 MHz, en
`~/sapphire-angel/research/metal/ios-graficos/trace/capturas/`: `metal-trace-2079-1.txt` (home, 12 command buffers) y
`metal-trace-2079-2.txt` (abrir la app Tiempo, 90). Lector: `../trace-frame.py`. Capturas posteriores, ya con bundles
de esta rama, en el mismo directorio `trace/`: `capturas-blur/` y `capturas-recientes/` (`merge-5`: Centro de Control
y selector de apps recién arrancado backboardd) y `capturas-merge6/` (`merge-6`: las mismas vistas, con los tiempos
de §10.6).

### 10.1 Qué muestran las trazas [M]

- **La pasada principal del home** (`cb1/enc0`): 106 draws más uno que no se dibujaba, 100 % de la pantalla, c0 la
  superficie de pantalla con `load`/`store`, y c1 una textura `storage=memoryless`
  (`com.apple.coreanimation.memoryless-texture`) con `load=dontcare store=store`. Empieza con cuatro rellenos opacos a
  pantalla completa (`PBGRAXm_A2Xhf`) y el fondo en capas mezcladas casi completas; el resto son iconos (tres
  pipelines por icono: sombra de la etiqueta con mezcla en el shader `TcimBdsoA2Xhf_Ialp`, etiqueta, imagen).
- **Para qué sirve c1.** CoreAnimation lo usa como memoria de trabajo dentro del pase: un draw con `S1`
  (`fc_dest_index` 1) escribe en c1 — `TimgA2S1Xhf_IsrcM0` copia a c1 el fondo que hay en c0, leyéndolo por
  framebuffer fetch — y un draw posterior lo lee por fetch como imagen (`TbdsA2Xhf_Isup_IsrcM1`: devuelve el fondo
  guardado fuera de la máscara de esquinas continuas de un widget; `TcimA2Xhf_IsrcM1`: compone un grupo). Nada lee lo
  que queda en c1 después del pase: cada pase lo sobrescribe (tabla «Resultados que nadie lee» del lector).
- **El draw que no se dibujaba** es el último de cada frame: `std_vert1_lph+luma_boost_lph` a pantalla completa,
  `res="left out: luma_boost"`, en 12 de 12 y 90 de 90 command buffers. Lee `[[color(0)]]` y suma
  `edr·scale·LUT(luma)`; con los uniformes de la traza, scale = 0,05.
- **El home quieto se redibuja cada 100,0 ms** por el segundero del icono del Reloj: entre frames solo cambia la
  geometría de un draw de una textura de 6×85 dentro del icono (411,37; 770,69 → 411,41; 769,63 → 411,44; 769,10).
- **Al abrir una app**, de 906 ms de GPU en pasadas, 450 ms son de 244 pasadas a 750×1624 en sysmem (8,4 draws de
  media, 1,85 ms cada una). Las más caras tienen 23-25 draws y cuestan 8-11,7 ms: dos rellenos opacos completos, otro
  del 90 % y una imagen mezclada completa, es decir ~2,7 ms por capa completa a través de memoria. Quedan en sysmem
  porque la regla de apertura mira el número de draws (§10.4).
- **Pipelines sustituidos**: ocho en esas trazas, todos creados por CoreAnimation en ejecución (los que su pipeline
  library no nombra; llegan con sus funciones etiquetadas `com.apple.coreanimation.frag.<constantes>`), cada uno
  compilado de «la variante más cercana»: `TimgA2S1Xhf_Ixrg` como `…Xhfcx_Ixrg`, `TmuaA2S1Xhf_Ixrg_Isqr` como
  `…Xhfcx_Isrc_Isqr`, `TimgBdsoA2Xhfn_Isrc` como `…Xhfcn_Isrc`, `TimgA2Xhfn_IsrcN3Oc3mtc4` sin el ruido.
- En la consola (`medicion/ab/`), los únicos draws rechazados en uso normal son rangos de constantes: «reads 64 bytes
  at 0 of constant buffer 2; 16 are bound and 16 mapped behind the offset» y el equivalente de
  `downsample_blur_vert_lph` con 48.
- No hay en esas trazas texturas YCbCr, ni superficies distintas de las de pantalla, ni targets muestreados antes de
  escribirse, ni command buffers en error.

### 10.2 Lo corregido

Cada fila es un commit de `cpu-draw`. «Prueba» es la de host que falla sin el cambio; donde el código es solo del
plug-in no hay prueba de host (no se construye en host) y se dice. Los golden cambian solo en las líneas que cada
commit nombra.

| No conformidad (19 §2.9) | Qué hacía | Qué hace | Commit · prueba | En el teléfono [M] o a la vista |
|---|---|---|---|---|
| Memoryless guardada | La textura memoryless de c1 tenía memoria como cualquiera y se obedecía su `store` (el valor por defecto de un colour attachment): cada tile de la pasada principal guardaba 128×128 píxeles que nadie lee | `Texture::setMemoryless`: los tiles ni la cargan ni la guardan; solo cuando un pase de Metal queda en dos del núcleo (un draw que no puede unirse, con Load en todos los attachments) la primera mitad la guarda y la segunda la carga (`closePass` recibe el pase del draw que lo cierra). Conserva filas para los pases en sysmem | `050c059` · `a_memoryless_attachment_is_neither_loaded_nor_stored_by_the_tiles` | `merge-4`: la pasada principal sale `loaded 0x1 stored 0x1` |
| N-03 | Un rango de constantes que ir3 rellena a vec4 enteros (16 B de color → 64) y pasa de las páginas del buffer: draw rechazado y omitido | Se carga directo: los bytes que hay, leídos al codificar, y ceros detrás. El procesador de comandos sigue sin leer fuera de las páginas. Igual en dispatch | `c571fcd` · `a_constant_range_running_past_its_buffers_pages_is_loaded_with_what_is_there` | `merge-4`: 0 líneas `refused` |
| N-01 | Pipeline creado en ejecución → variante «cercana» de la library, con otras constantes | Se compilan los módulos propios de las funciones con las constantes de CoreAnimation; las variantes de la library solo cuando son la misma función por los nombres de CoreAnimation (etiqueta de la función, o pipeline de la library por su etiqueta), y las dos etapas del mismo origen. Si el compilador rechaza lo pedido, y solo entonces, compila la variante cercana y lo dice con el motivo (backboardd aborta al segundo fallo de un pipeline); `metal_strict` da el rechazo | `81dd364` · sin prueba de host | `merge-4`: 0 `stands in for it`, 4 pipelines «its own module» |
| N-24, N-08 | `luma_boost` omitido en todos los frames; `luma_boost`/`edr_scale` sustituidos por `inplace_copy` | Se dibuja; las funciones pedidas son las que se compilan | `81dd364` · sin prueba de host | El `(+1 no)` desaparece; un draw más a pantalla completa con fetch por frame |
| N-18 | Un draw que lee su target en sysmem se ordenaba solo con la barrera previa: entre las primitivas del propio draw, nada | `GRAS_SC_CNTL.SINGLE_PRIM_MODE = FLUSH_PER_OVERLAP_AND_OVERWRITE`, como los dos drivers de Mesa (`fd6_emit.cc:564-570`, `tu_pipeline.cc:3373-3376`); la barrera se queda. Se apaga con `metal_gmem_off=8192` | `4c3a83d` · `a_draw_that_reads_its_target_gets_the_target_as_a_texture_and_a_barrier_before_it` | Va desde `merge-5`; sin comprobación a la vista de un caso que lo ejercite |
| N-04 | Scissor de anchura 0 = «sin scissor» (el draw cubría el target); de altura 0, draw rechazado | No deja pasar nada: se escribe como turnip un scissor vacío, (1,1)-(0,0) (`tu_pipeline.cc:2669-2672`); el draw abre su pase y no toca ningún bin | `4cf8232` · `an_empty_scissor_passes_no_fragment_and_is_no_refusal`, `a_scissor_of_no_area_through_the_c_interface_is_drawn_as_one` | Va desde `merge-5`; sin comprobación a la vista de un caso que lo ejercite |
| N-07 | El dispositivo no declaraba la alineación de 64 B que necesitan las filas de una textura sobre IOSurface o buffer | Hecho y **apagado**: `iosurfaceTextureAlignmentBytes`, `iosurfaceReadOnlyTextureAlignmentBytes` (bit 1 de `metal_align`) y `linearTextureAlignmentBytes`, `deviceLinear(ReadOnly)TextureAlignmentBytes`, `minimumLinearTextureAlignmentForPixelFormat:` (bit 2) contestan 64 solo con su bit; sin él contesta la clase base, como antes. Declararlas hace invisibles los widgets mientras N-12 no esté resuelta (§10.7) | `e22b881`, `96d9bac` · sin prueba de host | `merge-6` (todas a 64): widgets de fondo opaco invisibles. `merge-7` (apagadas): como `merge-5` |
| N-14 | Swizzle del descriptor: nil en texturas propias, ignorado sobre IOSurface | La textura se crea igual y se lee a través del swizzle, como una vista con swizzle. Se apaga con `metal_swizzle=0` | `e22d7bf` · sin prueba de host del plug-in | Va desde `merge-6`; ninguna textura lo pide en las trazas (`swizzled=1`: 0): sin ejercitar |

Qué mide el host del cambio de memoryless (escena S de `drawbench`: los programas del teléfono, 110 draws, dos
attachments, 78 tiles): 78 cargas y 156 guardados (4,88 MB leídos, 9,77 MB escritos) pasan a 78 y 78 (4,88 y
4,88 MB). Los 78 tiles no cambian: la pasada escribe y lee c1, y 128 KiB de GMEM entre 8 B por píxel son bins de
128×128.

### 10.3 Medidas de host del trabajo que recibe la GPU

`drawbench --gpu [--gmem-off BITS] [--gmem-draws N] [--no-memoryless]` (`c2c2b24`) imprime, del último frame medido
de cada escena, lo que el procesador de comandos del fake leyó y ejecutó y lo que movieron los tiles. El fake no
rasteriza: fragmentos y mezcla no salen de aquí. A610, la punta frente a `--gmem-off 6080` (el pase como antes de
`gpu-pass`):

| Escena | tiles | palabras del CP | registros | `CP_LOAD_STATE6` | MB cargados + guardados |
|---|---|---|---|---|---|
| S, programas del teléfono, 2 attachments | 78 (antes 102) | 897 K (1 275 K) | 413 K | 29,0 K (102,9 K) | 4,88 + 4,88 |
| P, 108 draws, c1 sin tocar | 42 (102) | 76 K (490 K) | 18 K | 1,3 K (55,6 K) | 4,88 + 4,88 |
| Q, P con fetch cada 4 draws | 42 (102) | 159 K (780 K) | 58 K | 2,1 K (58,3 K) | 4,88 + 4,88 |
| U, 5 pasadas de 22 draws | 234 (sysmem) | 531 K (13,6 K) | 249 K | 13,9 K | 19,5 + 19,5 |
| V, 7 capas a pantalla completa | sysmem; 39 con `--gmem-draws 6` | 812; 26 K | 321; 11 K | 35; 920 | 0; 4,88 + 4,88 |

De las 897 K palabras de S, 737 K están en grupos de estado: programa 2 661 ejecuciones × 136 palabras, cargas
3 232 × 51, viewport 3 232 × 21, rasterizador 1 841 × 28, vértices 1 185 × 34, mezcla 873 × 33, pase 237 × 69. Fuera
de grupos, 160 K: cada tile lee los `CP_SET_DRAW_STATE` y el paquete de draw de los 110 draws aunque se salte 70 de
ellos por visibilidad. CoreAnimation cambia de pipeline en casi cada draw (tres por icono), así que el grupo de
programa corre casi en cada draw ejecutado. [M] Que ese trabajo pesa lo dice el A/B de §6 con `metal_gmem_off=64`.

### 10.4 Tiles o sysmem: lo que hace turnip y lo que hace el driver

[O] turnip (Mesa 25.0.7, `tu_autotune.cc:541-640`, `tu_pass.cc:673-699`, `tu_pipeline.cc:2850-2886`) elige sysmem si
`cleared·px + D ≤ (11·(loaded + stored)·px + D)/10`, con D = muestras del pase × bytes por muestra (el cpp de cada
attachment escrito, doble si mezcla). Las muestras son las que ese pase pasó la última vez, medidas con dos
instantáneas `ZPASS_DONE` del contador de muestras, al empezar y al acabar (`:642-733`). Sin historia, sysmem solo con
5 draws o menos (`:504-517`); con un draw que lee su target, GMEM siempre (`:548-554`).

[O] `render::gmemWorth` (`src/render.cpp:2532`, `include/hakios-metal/render.hpp:574-580`) usa la misma desigualdad con D supuesto
proporcional al número de draws y calibrado por `metal_gmem_draws=56`: supone ~1/23 de pantalla por draw, cierto para
un home de iconos y 20 veces corto para capas a pantalla completa. Además la regla de apertura deja en sysmem, sin
grabar para tiles, todo pase cuyo «semejante» tuvo menos de 28 draws en sus últimas 16 veces, sin saber si lleva un
draw con fetch. Consecuencias medidas: las pasadas de 23-25 draws de §10.1 (8-11,7 ms en sysmem; por la fórmula de
turnip con sus ~4 pantallas de muestras irían a tiles) y el pase final sobre la pantalla, que desde que se dibuja
`luma_boost` lleva un fetch a pantalla completa y sale unas veces en 42 tiles y otras en sysmem según la historia de
draws (`ab-k353-merge4-a.txt`: `draws 7 tiles 42 … touched 0x301` y `draws 11 … sysmem: its like had 11 draws`).

Lo que corresponde, y no está hecho: medir las muestras de cada pase como turnip (el contador ya se usa para las
consultas de oclusión, `src/render.cpp`, con la espera que el A610 necesita), guardar la historia por clase de pase en
la cola y decidir con D medido tanto al cerrar como al abrir.

### 10.5 `metal_all=1`: por qué no se puede dar Metal a todo proceso por defecto

Solo backboardd recibe el dispositivo; `metal_all=1` lo da a todos. La puerta es del plug-in
(`-initWithAcceleratorPort:`) y su razón escrita (abortos por pipeline libraries sin `default.metallib`) no está
confirmada. Lo que lo impide está en el servicio del kernel (`SapphireGpu.cpp`, árbol `xnu-0350` de
`~/sapphire-angel/research/metal/display/work/`, igual a aplicar la serie de `xnu/patches`), leído sin probar nada:

- [O] Un solo espacio de direcciones de GPU para todos los clientes (un banco SMMU, un TTBR0 con ASID 0, `:1965`; el
  comentario de `:4188` lo dice: «one address space for all clients, no register protection»). Un envío es un
  `CP_INDIRECT_BUFFER` al buffer del cliente sin validar (`:6431-6434`) y no hay tabla `CP_PROTECT`. [H] Un cliente
  puede leer y escribir por dirección la memoria de GPU de otro, y el pool con el ring, las fences y las tablas de
  páginas está en ese mismo espacio.
- [O] La recuperación es global (una espera de 2 s reinicia la GPU y da por terminado lo de todos), hay una sola
  secuencia de fences sin prioridades, no hay cuotas (pool de 1 GB compartido) ni comprobación al abrir el servicio.
  El borrado de memoria nueva sí es correcto por defecto (`gpu_zero=1`).
- [O] En usuario: `/var/tmp/metal.args` gobierna el driver de cualquier proceso; la caché de stages es un directorio
  compartido y escribible, con clave no criptográfica y carga sin validar; cada proceso compila sus shaders y guarda
  hasta 32 MB de buffers libres y 64 MB de programas.

Para que sea seguro hace falta, por este orden: tabla de páginas por cliente con cambio de TTBR0 por envío y
`CP_PROTECT` (como el driver msm de Linux: `a6xx_gpu.c:103-147`, `:479-502`); recuperación con culpa por envío;
fences y colas por cliente con prioridad al servidor de ventanas; cuotas; caché de stages privada por proceso con una
semilla del sistema de solo lectura. No determinado: qué procesos abrieron el dispositivo en la tanda de prueba, si
alguno aborta con él, y el coste real por proceso.

