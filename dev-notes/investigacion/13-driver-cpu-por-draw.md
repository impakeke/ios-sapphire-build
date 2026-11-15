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

[M] La fila de `merge-7` no es comparable con las de `todo`: es otro arranque y las líneas `SWEET FB` del kernel
difieren (`ab-k353-merge7.fb`: «248 by the GPU» de 248 swaps en un periodo de 5 s; `ab-k353-todo-1.fb`: «10 by the
GPU» de 630), es decir, las opciones de presentación del kernel no eran las mismas (qué cuenta cada contador: 18; no
verificado aquí). En el ensayo de `merge-7` commit→fin es 16,0 ms y la GPU va al 81 %, frente a 7,6 ms y 43-46 % en
`todo`. El ensayo que se le parece es `ab-k353-dirty-a` (49,9 buffers/s, 19 µs por draw, commit→fin 14,3 ms, GPU
71 %; por la hora, `merge-5`: no verificado). En `ab-k353-merge7.txt` los pipelines se hacen en 0,5-0,8 ms («2 of 2
stages from the cache») y no hay ninguna línea `refused`, `stands in for it` ni `specialise:`.

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

[O] `render::gmemWorth` (`src/render.cpp:2532`, `include/hakios-metal/render.hpp:574-580`) usa la misma desigualdad
con D supuesto proporcional al número de draws y calibrado por `metal_gmem_draws=56`: supone ~1/23 de pantalla por
draw, cierto para un home de iconos y 20 veces corto para capas a pantalla completa. Además la regla de apertura deja
en sysmem, sin grabar para tiles, todo pase cuyo «semejante» tuvo menos de 28 draws en sus últimas 16 veces, sin saber
si lleva un draw con fetch. Consecuencias medidas: las pasadas de 23-25 draws de §10.1 (8-11,7 ms en sysmem; por la
fórmula de turnip con sus ~4 pantallas de muestras irían a tiles) y el pase final sobre la pantalla, que desde que se
dibuja `luma_boost` lleva un fetch a pantalla completa y sale unas veces en 42 tiles y otras en sysmem según la
historia de draws (`ab-k353-merge4-a.txt`: `draws 7 tiles 42 … touched 0x301` y
`draws 11 … sysmem: its like had 11 draws`).

Lo que corresponde, y no está hecho: medir las muestras de cada pase como turnip (el contador ya se usa para las
consultas de oclusión, `src/render.cpp:2280-2323`, con la espera que el A610 necesita), guardar la historia por clase
de pase en la cola y decidir con D medido tanto al cerrar como al abrir. El diseño, en §11.6 c.

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

### 10.6 El tirón de la primera vez: la espera por el compilador y la clave de especialización

[M] Con `merge-5`, recién arrancado backboardd, la primera vez que se abre el selector de apps o el Centro de Control
hay command buffers cuya codificación (creado → commit) dura cientos de milisegundos: 228,5 ms
(`capturas-recientes/metal-trace-891-1.txt`, cb 13), 470,0 ms (`capturas-recientes-bocache/metal-trace-951-1.txt`,
cb 15), 1 318,2 y 539,8 ms (`capturas-blur/metal-trace-800-1.txt`, cb 7 y 8) y 507,6 ms (`800-3`, cb 12). La segunda
vez el máximo es 38-39 ms (`891-2`, `951-2`).

Qué pasa [M, esas trazas; O, el código]:

1. No es la compilación del pipeline que se crea: es la **espera por el compilador**. `compileStage` tomaba el cerrojo
   del único compilador (`gCompilerLock`, `src/compiler.cpp:55`: ir3 guarda estado en el objeto compilador) antes de
   mirar la caché de stages. Un pipeline con sus dos stages ya en disco —medio milisegundo de lectura— esperaba a lo
   que otro hilo estuviera compilando. En `891-1`, cb 13: los diez encoders empiezan en 34 ms; a los +54 ms se crea
   `PBGRABsovXm_TmuaA2Xhf_Ixrg_Isup` (dos variantes de la library, en caché) y tarda 172,8 ms: 54 + 173 = 227 de los
   228,5 ms. En `800-1`, cb 7: tres esperas seguidas de 415-434 ms de pipelines en caché.
2. Quién tiene el compilador: la cola en serie `hakios.metal.specialise` del plug-in (`CA.m:9234`), que compila el
   shader genérico de CoreAnimation (`fixed_frag_lph_cpf`, 32 064 palabras de instrucciones) para cada contenido de
   su `FragmentShaderConfig` de 52 B (N-17), 0,43-1,1 s cada vez (`specialise: … in 1104 ms`, `ab-k353-todo-1.txt`).
3. Por qué compila con la caché caliente: de los 52 B la compilación lee 34. De los otros 18 —relleno entre campos,
   campos que el shader no consulta y los cuatro últimos bytes— al menos los últimos no los escribe CoreAnimation y
   traen restos del pool de buffers (`…003c003c`, `…0000803f`, `…d5e143`). La misma configuración llega con otra
   basura, la clave (un hash de los 52 B) es otra y se compila otra vez: 25 contenidos distintos para 19
   configuraciones en las trazas, y en la caché del teléfono (leída por ssh con `merge-5`) 1 313 ficheros, 377 de
   ellos de exactamente 3 124 B, 153 de 3 252 y 142 de 2 988.
4. Agravante [O]: cada pipeline genérico tenía 64 ranuras de especialización sin desalojo; llenas, todo contenido
   nuevo se dibuja con el genérico sin especializar hasta reiniciar backboardd.

Lo hecho:

| Commit | Qué | Evidencia |
|---|---|---|
| `6594789` | `compileStage` (`src/compiler.cpp:1404`) mira la caché y sus semillas sin cerrojo; solo una compilación toma el compilador, y al tenerlo vuelve a mirar. `CompileTimes`/`takeCompileTimes` dicen por hilo cuántos stages salieron de la caché, cuántos se compilaron y cuánto se esperó. La consola lo imprime siempre (`linked …; made in X ms (N of M stages from the cache in A ms, K compiled in B ms after C ms waiting for the compiler)`) y la traza también (`pipe … stages cached compiled wait_ms load_ms cc_ms`; `commit … textures= surfaces= buffers= uploads= pipelines= copies=`, cada uno cuenta/ms/MB de lo hecho mientras se codificaba ese buffer) | [M] `merge-6`, `capturas-merge6/`: la codificación máxima al abrir recientes es 51,9 ms y en el Centro de Control 69,8 ms (n=1); ningún pipeline espera (`wait_ms` 0) ni compila |
| `059f85d` | El plegado del buffer conocido (`foldKnownLoad`, `:264`) anota qué bytes leyó. El stage se archiva además en un índice por función (`<hash>.known` junto a los `.stage`: un registro por compilación con la máscara, los valores bajo la máscara y el nombre del fichero) y un buffer que coincide en los bytes leídos **es** ese stage (`knownIndexFind`, `:1338`; `knownIndexNote`, `:1381`). `CompiledStage::knownReads` lleva la máscara al llamante | [O] host, `stagecc` (§11.2): una configuración compila en 176 ms, la misma con otros bytes finales sale de la caché en 0,4 ms, otra configuración compila; quedan 2 `.stage` y un `.known` de dos registros. [O] teléfono, leído por ssh con `merge-7` instalado: un `.known` de 1 584 B = 11 registros de 144 B, los 11 con la misma máscara de 34 bytes, que es la que da el host |
| `96d9bac` | Plug-in, `-hakiosProgramFor:offsets:count:` (`CA.m:9163`): cada ranura guarda la máscara de su programa (`hakios_metal_program_known_reads`) y un contenido que coincide con una ranura en esos bytes es esa ranura. 128 ranuras (`HM_SPEC_MOST`) y una línea de consola si se llenan. `metal_spec_mask=0` vuelve a comparar los 52 B | [M] `ab-k353-merge7.txt`: ninguna línea `specialise:` en 34 s de páginas del home, frente a 2 a 19 en cada una de las diez consolas anteriores del mismo ensayo (n=1). Sin prueba de host: el plug-in no se construye ahí |

Los bytes que la compilación lee, de los 52 (host y teléfono): 0-2, 4-6, 8-10, 12, 16-18, 20-22, 24-26, 28, 32-37, 39 y
41-47. No lee 3, 7, 11, 13-15, 19, 23, 27, 29-31, 38, 40 ni 48-51.

Lo que queda en esos frames con `merge-6` [M, líneas `commit` de `capturas-merge6/`]. El modo de traza encarece la
codificación (la mediana de un buffer con la traza puesta es 23-41 ms, frente a 2-6 ms sin ella en §6): los números
valen para comparar buffers de una misma traza.

| Traza, buffer | Codificación | Texturas (n / ms / MB) | Buffers (n / ms / MB) | Pipelines (n / ms) | Subidas, copias por CPU, superficies |
|---|---|---|---|---|---|
| `1093-1` (recientes, 1.ª vez), cb 11 | 51,9 ms, 103 draws | 0 | 1 / 0,60 / 2,41 | 2 / 1,00 | 0 |
| `1093-1`, cb 15 | 43,0 ms, 107 draws | 2 / 10,77 / 0,13 | 0 | 3 / 1,19 | 0 |
| `1093-2` (recientes, 2.ª vez), cb 69 | 46,8 ms, 136 draws | 2 / 8,30 / 0,20 | 0 | 1 / 0,44 | 0 |
| `1093-2`, cb 39 | 41,0 ms, 125 draws | 2 / 19,54 / 0,13 | 0 | 0 | 0 |
| `1093-3` (Centro de Control), cb 7 | 69,8 ms, 162 draws | 8 / 15,07 / 15,07 | 11 / 4,14 / 0,23 | 10 / 7,05 | 0 |
| `1093-3`, cb 8 | 66,9 ms, 264 draws | 12 / 1,20 / 0,46 | 12 / 1,20 / 0,25 | 6 / 2,51 | 0 |

Los pipelines salen de la caché en 0,3-3 ms cada uno. Lo que queda de «primera vez» es **crear texturas**: hasta
10,8-19,5 ms en un buffer, y no en proporción al tamaño (dos texturas de 0,13 MB en 19,5 ms; ocho de 15 MB en 15,1 ms;
en total 0,65, 1,29 y 5,43 ms por MB según la traza). Causa sin establecer: no hay medida de qué parte es la llamada
al kernel que da la memoria, su mapeo o el resto de `-hakiosNewTextureWithDescriptor:` (`CA.m:4772`).

[M] En las trazas de `merge-5` cuatro pipelines de módulo propio (N-01) tardan 433 a 891 ms en hacerse la primera vez
(`TimgA2Xhfn_IsrcN3Oc3mtc4` 891, `TcimBpldA2Xhf_Isup` 455, `Tc33A2Xhf_IsrcM1` 435, `TcimBvcmA2Xhf_Icir` 433). Esas
trazas no separan compilar de esperar al compilador, y con `merge-6` esos stages ya están en la caché de disco: cuánto
cuesta compilar un módulo propio en el teléfono **no está medido**.

Por qué una especialización cuesta 0,5-1 s [O, host i5-7500, `tools/stagecc.cpp` con el compilador nativo]:

| Qué se compila | Resultado | Tiempo en host |
|---|---|---|
| El genérico (`frag.A2Xghfc`, función `fixed_frag_lph_cpf`, 81 768 B de bitcode) sin especializar | 32 064 palabras de instrucciones, las mismas que dice la consola del teléfono | 1,98-2,00 s (frontal 64-85 ms) |
| El genérico para una configuración de 52 B | 128-256 palabras | 172-193 ms: 55-66 el frontal AIR→NIR, 7-12 el plegado de los bytes conocidos, 106-118 el resto (lowering e ir3) |
| Una variante de la library (`frag.A2Xhf`, 3 844 B) | 32 palabras | 0,6-1,4 ms |

El frontal recorre el módulo entero y el lowering también, antes de que la poda deje las 128-256 palabras: el coste
no depende de la configuración. El teléfono tarda 0,43-1,1 s en lo mismo [M]: entre 2 y 6 veces el host. El uber crudo de
`default.metallib` con las constantes de CoreAnimation ni siquiera compila en host («reads its render targets through
slots past the 16 the table holds»): [H] en el teléfono Metal entrega en `bitcodeData` un módulo ya especializado.

La caché del teléfono no hace falta vaciarla: los ~1 250 ficheros duplicados por la basura de relleno son inertes
(4-5 MB) y vaciarla tiraría también los stages buenos (variantes y módulos propios), que se recompilarían en uso. Con
la clave por bytes leídos cada configuración se compila una vez más, para crear su registro de índice, y no vuelve a
compilarse.

Lo que esto no resuelve: una configuración o un pipeline que no se ha visto nunca se sigue compilando en uso (en la
cola de fondo, dibujando mientras tanto con el genérico de 32 064 palabras; o en el hilo de render, para un módulo
propio). El requisito del usuario es que no se compile en uso; el diseño para cumplirlo, sin implementar, está en
§11.6.

### 10.7 La alineación declarada, las imágenes en client storage y N-12

[M, coordinador] Con `merge-6` el widget de Calendario del home sale invisible y en la vista de widgets solo se ve el
de Tiempo (`medicion/shots/hoja-r6.png`). Con `merge-5` y con `merge-7` se ven todos
(`medicion/shots/hoja-vistas-m5-m.png`, `hoja-vistas-m7-m.png`: home, vista de widgets, Centro de Control y selector).

[M, trazas] Lo que cambia entre `merge-5` y `merge-6` en los recursos que crea CoreAnimation, contando las texturas
que nombran los command buffers de una traza del selector de apps (`891-1` frente a `1093-1`; una textura cuenta una
vez por cada command buffer que la nombra):

| | `merge-5` | `merge-6` |
|---|---|---|
| `label=com.apple.coreanimation.image` (memoria propia, subida con `replaceRegion`) | 2 941 | 0 |
| `label=com.apple.coreanimation.image-client-storage` (`origin=buffer`: una textura sobre un buffer) | 1 539 | 4 345 |
| Texturas con swizzle (`swizzled=1`) | 0 | 0 |

[O] Lo único de `merge-6` que cambia lo que CoreAnimation pide son las respuestas de alineación de N-07 (`e22b881`);
N-14 no interviene (ninguna textura pide swizzle). Y en este driver un buffer hecho con
`-newBufferWithBytesNoCopy:` no es la memoria del llamante sino una copia hecha al crearlo (`CA.m:3817`; N-12): lo
que esa memoria reciba después no llega a la GPU.

[H] La cadena que explica el síntoma: con la alineación declarada CoreAnimation toma todas las imágenes como client
storage; las que se rellenan después de crear el buffer —los bitmaps que dibuja otro proceso— se dibujan de la copia
vacía. No está demostrado que los buffers bajo esas texturas sean *no-copy* (la traza no registra con qué llamada se
hizo cada buffer; lo dice el nombre de la etiqueta), ni cuál de las respuestas lo dispara: QuartzCore solo pregunta
`iosurfaceReadOnlyTextureAlignmentBytes` (19 §2.8); las lineales las usa Metal.

Lo hecho (`96d9bac`): las respuestas van detrás de `metal_align` (`hm_align`, `CA.m:3659`), **apagadas**. Bit 1:
`iosurfaceTextureAlignmentBytes` e `iosurfaceReadOnlyTextureAlignmentBytes`. Bit 2: `linearTextureAlignmentBytes`,
`deviceLinearTextureAlignmentBytes`, `deviceLinearReadOnlyTextureAlignmentBytes` y
`minimumLinearTextureAlignmentForPixelFormat:`. `metal_align=3` es `merge-6`. Sin el bit contesta la clase base
(`-hakiosBaseAlignment:`, `CA.m:3677`). La primera cola de cada proceso imprime en consola las respuestas en vigor y
la de la clase base para `iosurfaceReadOnlyTextureAlignmentBytes` (`CA.m:3736-3752`); `ab.sh` empieza a capturar
después, así que esa línea no está en `medicion/ab/`.

Lo que lo decide: `merge-7` con `metal_align=1`, `=2` y `=3`, mirando los widgets (`medicion/vistas.sh`). Lo que
corresponde antes de volver a declarar la alineación: que un buffer *no-copy* comparta de verdad la memoria (el
kernel tiene que mapear páginas del proceso en el espacio de direcciones de la GPU), que es N-12.

Con las respuestas de la clase base un tercio de las imágenes ya llegan como client storage (la columna de
`merge-5`): N-12 les aplica igual, y es candidata para cualquier defecto de imágenes que no se actualizan (§11.7, H5).

### 10.8 Qué queda

- **Parpadeo del widget de Tiempo cuando algo se le superpone** [M, observación del usuario con `merge-4`]. Sin causa
  establecida. Hipótesis y pasos que la deciden, ninguno ejecutado: §11.7.
- **Destellos de colores al abrir apps**: la traza no tiene nada mal formado; candidatos a la vista son los pipelines
  sustituidos (corregido), la imagen de lanzamiento en ASTC 4×4 de 750×1624 y un relleno blanco opaco del 90 % bajo
  una textura de 752×1626 mezclada durante 20 frames. Hace falta una captura de pantalla del frame del destello.
- **No compilar en uso** (requisito del usuario): preparar antes de que aparezca la interfaz todo lo que deba
  compilarse. Diseño en §11.6; nada implementado más allá de la clave correcta, que es su condición.
- **N-12** (§10.7), y con ella N-07.
- **Crear texturas en uso**: 10-20 ms en un buffer (§10.6); sin causa medida.
- **Elección tiles/sysmem por muestras medidas** (§10.4, §11.6). No se toca hasta saber la causa del parpadeo, para
  no taparla.
- **Trabajo del procesador de comandos por bin** (§10.3, §11.6).
- **N-02** (command buffer `Completed` con trabajo omitido): con N-03 servido no queda ningún rechazo en uso normal
  (0 líneas `refused` en las consolas desde `merge-4`); marcar `Error` por defecto pide saber antes qué hace
  CoreAnimation con un command buffer en error. **N-09** (un estado rechazado envenena el encoder): no aparece en
  ninguna consola.
- **N-05, N-06** (YCbCr y superficies no alineadas por copia de CPU al enlazar): activas en uso normal (las dos líneas
  de aviso salen en todas las consolas; filas de 2 848 B). Lo conforme es leerlas en la GPU al ejecutar, con una
  pasada propia antes del pase que las muestrea; no está hecho.
- **Memoria de las texturas memoryless**: siguen teniendo filas (4,9 MB cada una a pantalla completa) para los pases
  en sysmem; asignarlas solo cuando un pase en sysmem las necesita no está hecho.

## 11. Relevo

Esta sección basta para continuar el trabajo: el resto del informe es la justificación y las medidas. Reglas que
siguen en vigor, del usuario y del coordinador:

- El agente no instala nada en el teléfono ni lo reinicia: lo hace el coordinador con
  `~/sapphire-angel/research/metal/medicion/bundle.sh` y mide con `ab.sh`. `ssh sapphire` se usa en solo lectura.
- Equivalencia de streams en verde en cada commit; commits pequeños, comentados, que compilan y pasan las pruebas;
  medir antes y después.
- Nada de rodeos: se arregla lo que el driver incumple.
- No cambiar la elección tiles/sysmem hasta saber la causa del parpadeo (§11.7).
- Requisito de diseño del usuario sobre la compilación: «esto es un sistema operativo, no un juego: es aceptable y
  normal que el encendido tarde, y no es aceptable compilar en uso. Todo lo que deba compilarse … se prepara antes de
  que aparezca la interfaz: en la instalación o en el primer arranque (y tras cada actualización del driver), con la
  pantalla de arranque puesta, fuera del hilo de render; en uso normal el driver solo lee su caché … Primero la clave
  de especialización correcta (sin bytes de relleno), que es condición para que la caché sea finita.»

### 11.1 Estado de la rama, los bundles y el teléfono

- **Árbol**: `~/sapphire-angel/research/metal/rebuild/wt-cpu`, worktree del repositorio
  `~/sapphire-angel/research/metal/hakios-xnu-kernel`. Rama `cpu-draw`, punta **`f58c688`**, árbol limpio: no hay
  nada sin commit. `f58c688` es `96d9bac` más dos comentarios del plug-in, línea por línea: el código y los números
  de línea son los de `96d9bac`. Base: `opcional-puerto` (`620950c`, worktree `rebuild/hakios-upstream`). Contiene
  entera la rama `gpu-pass` (`fa8d36c`, worktree `rebuild/wt-gpu`, informe 14).
- **Suite de host en la punta**: 284 pruebas sin fallos con las constantes de los dos chips, golden por las tres vías
  y golden de las escenas con los stages del teléfono (`cpu-tools/tmp/final/check-tip.txt`, sobre `96d9bac`).
- **Commits**: con la identidad genérica de los commits de la rama (`git log -1 --format='%an %ae'`, pasada con
  `git -c user.name=… -c user.email=… commit`); mensaje en inglés: una frase que dice qué hace el driver, el porqué
  con sus cifras y, si cambia el stream, qué líneas de golden cambian.
- **Este informe** no tiene commit en el repositorio ios-sapphire y `INDICE.md` no lo recoge: lo hace el
  coordinador.

Bundles, en `~/sapphire-angel/research/metal/rebuild/out/NOMBRE/` (`HakiosMetal`, `Info.plist`, `COMMIT`):

| Bundle | Commit | Bytes | sha256 | Qué añade | En el teléfono [M] |
|---|---|---|---|---|---|
| `cpu-A-wip` | `99279c0` + plug-in | 8 643 152 | `e992c97d409cc33f…` | Estado guardado por programa (§3.1-3.6, §3.8) | 142 → 59 µs por draw |
| `merge-1` | `98d2c3c` | 8 685 328 | `ab3d6e8ec030f8db…` | Fusión con `gpu-pass` | 61-69 µs; 26 µs con la L2 viva |
| `merge-2` | `6d3f273` | 8 708 032 | `e695290ca2247388…` | Reciclado, `appendStream`, cierre de pase sin asignaciones | 17-20 µs por draw |
| `merge-3` | `4e0a51a` | 8 708 176 | `c8839e2ef6261c24…` | Corte de la grabación doble; `wrote`/`read` en `passes:` | 16 µs |
| `merge-4` | `81dd364` | 8 767 408 | `27a9c4799a4ccaf6…` | Traza de frame, memoryless, N-03, N-01, N-24/N-08 | 0 `stands in for it`, 0 `refused`; c1 sin guardar |
| `merge-5` | `4cf8232` | 8 767 408 | `7be356c2568827b3…` | N-18, N-04 | 55,1 / 58,3 buffers/s en la configuración «todo» |
| `merge-6` | `6594789` | 8 770 800 | `42de530ce34d2a12…` | Caché sin cerrojo e instrumentación; N-07 con todas las respuestas a 64; N-14 | Tirón de primera vez 228-1 318 → 52-70 ms; **widgets de fondo opaco invisibles** (§10.7) |
| `merge-7` | `96d9bac` | 8 774 448 | `b44a31f13264bae9…` | Índice por bytes leídos, ranuras por máscara, N-07 detrás de `metal_align` (apagado), `metal_swizzle=0` | Instalado. Pinta como `merge-5`; 0 `specialise:` en el ensayo del home |

**Teléfono** [O, leído por ssh]: binario instalado con sha256 `b44a31f13264bae9…` y 8 774 448 B (`merge-7`);
`/var/tmp/metal.args` vacío; caché `/private/var/db/hakios-metal-cache` con 1 348 `.stage` y un `.known` de 11
registros. [M, coordinador] Capturas de `merge-7`: `medicion/shots/hoja-vistas-m7-m.png` (home, vista de widgets,
Centro de Control, selector: como `merge-5`) y consola `medicion/ab/ab-k353-merge7.txt`.

Lo que está hecho y **sin verificar en el teléfono**, y qué lo verifica:

| Qué | Lo que se sabe | Lo que lo verifica |
|---|---|---|
| Ranuras por máscara del plug-in (`96d9bac`) | Sin prueba de host (el plug-in no se construye ahí). En el teléfono el índice del núcleo se escribe (11 registros), `merge-7` pinta bien las cuatro vistas y no hay líneas `specialise:` en 34 s de home (n=1) | Tras reiniciar backboardd, abrir cada vista dos veces con `metal_fps=1` y la consola desde el arranque: `specialise:` solo la primera vez de cada configuración. A/B con `metal_spec_mask=0` |
| N-14, swizzle del descriptor (`e22d7bf`) | Ninguna textura lo pide en las trazas: el camino no ha corrido en el teléfono. El núcleo (`Texture::swizzled`) tiene sus pruebas de vistas con swizzle | Contenido que pida `MTLTextureDescriptor.swizzle`: la consola dice una vez `a texture was asked for with a swizzle of …` |
| N-07 (`e22b881`, detrás de `metal_align`) | Apagado. Qué bit trae el client storage, sin establecer; que los widgets invisibles vengan de N-12 es [H] | `metal_align=1`, `2` y `3` con `merge-7` y `medicion/vistas.sh` |
| N-18 (`4c3a83d`), N-04 (`4cf8232`) | Prueba de host. Van en el teléfono desde `merge-5` sin defecto atribuido; no hay caso conocido que los ejercite | N-18: un path con solapes propios dibujado con fetch en sysmem, con y sin `metal_gmem_off=8192` |
| N-08 (`edr_scale` compilado tal cual, `81dd364`) | Ninguna traza trae un pipeline `edr_scale` | Contenido EDR |
| Red de seguridad de N-01 (`hm_bitcode_nearest`) | No ha saltado: 0 `stand in for it` desde `merge-4` | `grep 'stand in'` en cada consola |
| Coste de compilar un módulo propio en el teléfono | Sin medir (§10.6) | Vaciar un stage de módulo propio de la caché y leer `cc_ms` de su línea `pipe`, o la línea `linked … compiled in` |
| Coste de crear texturas (10-20 ms en un buffer) | Medido el total por buffer, no el reparto | Cronometrar dentro de `-hakiosNewTextureWithDescriptor:` |
| Rendimiento de `merge-7` frente a `merge-5` | Un ensayo, con otras opciones del kernel (§6) | n≥3 con las mismas opciones |

### 11.2 Cómo construir y probar

```sh
R=~/sapphire-angel/research/metal/rebuild
T=$R/wt-cpu/hakios-metal
STAGES=~/sapphire-angel/research/metal/auditoria-userland/stage-cache/files   # 202 stages de la caché del teléfono

# 1. Suite de host y golden, los dos chips. Verde = por chip: «284 tests, 0 failed checks» dos veces,
#    «golden streams: the same -- from kept states (each draw checked, and unchecked) and written whole» y
#    «golden streams of the phone's stages: the same, from kept states and written whole».
$R/cpu-tools/check.sh 2>&1 | grep -v 'left out'
make -C $T -f tools/dev.mk -j4 CHIP=a610 tests drawbench && $T/out/dev-a610/tests | tail -1      # un chip, sin golden

# 2. Golden: comparar y, cuando el stream cambia a propósito, reescribir (decirlo en el commit)
make -C $T -f tools/dev.mk -j4 CHIP=a610 check
make -C $T -f tools/dev.mk -j4 CHIP=a610 golden && make -C $T -f tools/dev.mk -j4 CHIP=a635 golden
$R/cpu-tools/check.sh --write                 # golden de las escenas S, T, U: cpu-tools/golden-stages-<chip>.txt

# 3. drawbench: CPU por draw, y lo que recibe la GPU del fake
$T/out/dev-a610/drawbench --scene STU --stages $STAGES 2>&1 | grep -v 'left out'
$T/out/dev-a610/drawbench --gpu --scene SPQUV --stages $STAGES 2>&1 | grep -v 'left out'
#    … --gpu admite --gmem-off BITS, --gmem-draws N y --no-memoryless
$R/cpu-tools/measure.sh ETIQUETA && python3 $R/cpu-tools/table.py base A1-kept merge2 ETIQUETA
$R/cpu-tools/ab-host.sh "ETIQUETA1 ETIQUETA2" KLSTU     # A/B de binarios en cpu-tools/bin/drawbench-ETIQUETA

# 4. Bundle para el teléfono (unos 3 minutos; clang 18.1.8 y SDK de theos por $R/env.sh; firma ad hoc)
cd $R && SRC=$R/wt-cpu IOS_EXTRA="-g" CACHE_BUILD=24ed84207640dc54c2b865f7 ./build-bundle.sh $R/out/NOMBRE \
    > $R/cpu-tools/tmp/build-NOMBRE.log 2>&1; grep -c ' error' $R/cpu-tools/tmp/build-NOMBRE.log     # 0
git -C $R/wt-cpu rev-parse --short HEAD > $R/out/NOMBRE/COMMIT
D=$(mktemp -d); cp $R/out/NOMBRE/HakiosMetal $D/ && codesign -v $D/HakiosMetal && shasum -a 256 $D/HakiosMetal

# 5. Solo comprobar que el plug-in compila (segundos, sin bundle)
bash -c "source $R/env.sh; \"\$LLVM/clang\" -target arm64-apple-ios16.0 -isysroot \"\$SDK\" -O1 -fsyntax-only \
    -DHAKIOS_METAL_GPU -I $T/include $R/wt-cpu/userland/src/HakiosMetalCA.m"

# 6. El compilador del driver en host: Mesa nativo en $R/mesa/build-host, y tools/stagecc.cpp
$R/cpu-tools/build-hostcc.sh                  # deja $T/out/host-cc/stagecc
S=$T/out/host-cc/stagecc; V=$R/cpu-tools/variants
$S $V/frag.A2Xghfc.metallib --list
$S $V/frag.A2Xghfc.metallib fixed_frag_lph_cpf --runs 2          # el genérico sin especializar: 32 064 palabras
A=000000000501060003000101ff000000000000000000000000000000ff00000000013600010100200000000000000000003c003c
B=000000000501060003000101ff000000000000000000000000000000ff000000000136000101002000000000000000000000803f
E=000000000501060003000101ff000000000000000000000000000000ff00000000013700010100200000000000000000003c003c
$S $V/frag.A2Xghfc.metallib fixed_frag_lph_cpf --known 0 $A --runs 3   # especializado; imprime los bytes leídos
export HAKIOS_METAL_CACHE=$(mktemp -d)        # con caché: A compila, B (otra basura en 49-51) sale de la caché,
for k in $A $B $E $B; do $S $V/frag.A2Xghfc.metallib fixed_frag_lph_cpf --known 0 $k; done   # E (byte 34) compila
ls -l $HAKIOS_METAL_CACHE; unset HAKIOS_METAL_CACHE              # 2 .stage y un .known de 288 B

# 7. Trazas de frame y lectura del teléfono (solo lectura)
python3 ~/sapphire-angel/research/metal/ios-graficos/trace/trace-frame.py TRAZA.txt [--draws] [--cb N] [--max-filas N]
ssh sapphire 'ls /private/var/db/hakios-metal-cache | grep -c "\.known$"; cat /var/tmp/metal.args'
```

- **La clave de caché** (`CACHE_BUILD=24ed84207640dc54c2b865f7`, la de `propio-args`) se mantiene mientras lo que
  `compileStage` produce para una misma entrada no cambie: `translate`, el lowering, los archivos de Mesa y el
  tamaño de `Stage` y de `Kernel`. Si algo de eso cambia hay que construir **sin** `CACHE_BUILD` (el `Makefile` pone
  entonces el hash de `src/compiler.cpp`, las cabeceras y Mesa): con la clave fija el teléfono cargaría stages
  compilados de otra manera. A cambio, la primera sesión recompila todo en uso.
- **El Mesa nativo** (`rebuild/mesa/build-host`, 84 MB) está configurado con las opciones de `build-mesa.sh` sin el
  fichero de cross y con `rebuild/mesa/native-host.ini` (el clang del sistema); `build-host/meson-private/cmd_line.txt`
  tiene la lista. Se reconstruye con `ninja -C $R/mesa/build-host` seguido de las 13 rutas de archivo que lista
  `build-hostcc.sh`.
- **Un `.known`**: registros de `2·L + 40` bytes para un buffer conocido de `L` bytes (144 B para los 52 de
  CoreAnimation): la máscara (`0xff` donde la compilación leyó), los valores bajo la máscara y el nombre del fichero
  del stage (`/` + 32 dígitos hex + `.stage`, relleno con ceros).
- **Instalar y medir** es del coordinador: `medicion/bundle.sh NOMBRE` (instala por renombrado),
  `medicion/ab.sh ETIQUETA "ARGS"` (escribe `/var/tmp/metal.args` con `metal_fps=1 ARGS`, reinicia backboardd, espera
  28 s, calienta con una ronda y captura 34 s de consola durante `homeswipe 8`), `medicion/ab-sum.py`,
  `medicion/vistas.sh NOMBRE`
  (cuatro capturas de pantalla y hoja de contacto).

### 11.3 Interruptores

Se leen de los boot-args y, después, de `/var/tmp/metal.args` (`hm_bootargs`, `CA.m:130`), una vez por proceso.

| Interruptor | Por defecto | Qué hace |
|---|---|---|
| `metal_fps=1`, `=passes`, `=draws` | apagado | Resumen cada 2 s; `passes` añade una línea por pasada (`CA.m:7264-7274`); `draws`, tiempo por programa en sysmem |
| `metal_trace=frame` (`metal_trace_cbs=K`, `metal_trace_every=S`, `metal_trace_dir=DIR`) | apagado | `echo K > /var/tmp/metal.trace` vuelca K command buffers a `/var/tmp/metal-trace-PID-N.txt` (`CA.m:1438-1600`) |
| `metal_skip=PALABRA` | — | Omite los draws cuya línea de traza contiene la palabra (`metal_skip=luma_boost`) |
| `metal_keep=0` | 1 | Ningún draw desde estado guardado: mismo stream por el camino largo |
| `metal_verify=1` | 0 | Cada draw de estado guardado se comprueba contra sí mismo escrito entero |
| `metal_gmem_draws=N` | 56 | Listón de draws de `gmemWorth`. `0`: todo en sysmem. `1`: todo lo que puede, a tiles |
| `metal_gmem=1` | 0 | Tiles también con `metal_gmem_draws=0`, eligiendo por tiempo de GPU medido. `metal_gmem=0` no existe: no hace nada |
| `metal_gmem_off=BITS` | 0 | Refinamientos de los tiles fuera, por bits (`include/…/command.hpp:186-201`): 1 área entera, 2 todos los attachments, 4 fetch por barrera, 8 sin elección medida, 16 sin binning, 32 texturas nulas, 64 cuerpo sin grupos de estado, 128 sin salida temprana, 256 bins antiguos, 512 un bin por attachment, 1024 barreras en línea, 2048 todo ordenado, 4096 elegir solo por draws, 8192 fetch en sysmem sin orden entre primitivas (N-18 apagado) |
| `metal_strict` | apagado | Un rechazo acaba el buffer en error; un módulo propio rechazado no se sustituye |
| `metal_nospec` | apagado | Sin especialización del shader genérico |
| `metal_spec_mask=0` | máscara | Las ranuras de especialización se comparan por los 52 B |
| `metal_align=N` | 0 | Bit 1: respuestas de alineación de IOSurface a 64. Bit 2: las lineales. `3` es `merge-6` (§10.7) |
| `metal_swizzle=0` | aplica | No aplica el swizzle del descriptor |
| `metal_all=1` | solo backboardd | El dispositivo para todo proceso. No activar (§10.5) |
| `metal_defer=1` | 0 | Grabación diferida en un hilo del núcleo; no optimizada ni medida aquí |

### 11.4 Mapa del código tocado, por función

Núcleo, el camino de un draw y el cierre de un pase (`src/render.cpp` salvo donde se dice; detalle en §3):

| Función | Línea | Qué hace | Commit |
|---|---|---|---|
| `drawFacts`, `emitDraw<S>` | 1383, 1719 | Un draw en dos mitades: lo que decide el stream, y su emisión por grupos | `6f2e4e0` |
| `buildState`, `ProgramState`, `StateCache` | 3513, 3292, 3328 | El estado de un programa en un tipo de pase, guardado por `Program::uid` | `afc2eca` |
| `fastFacts`, `fastTables`, `emitFast` | 3663, 3851, 3922 | El draw desde estado guardado: reglas del draw, tablas escritas en sitio, grupos comparados con el `Cursor` | `afc2eca`, `343cc35` |
| `DedupSink`, `Cursor`, `PassCache`, `DrawCache`, `packetsOf` | 3122, 3371, 3440, 3461, 3263 | Deduplicación al generar; lo último que tuvo el stream de cada grupo; cachés del pase y del command buffer | `afc2eca`, `343cc35`, `99279c0` |
| `verifyDraw` | 4144 | `metal_verify=1`: el draw corto contra el largo | `afc2eca` |
| `CommandBuffer::draw` | 4303 | Elige tiles/sysmem al abrir (regla «its like had N draws», 4517-4532), graba de las dos formas y adelanta la decisión (4880-4903); aplica `kSysmemFetchUnordered` (4587) | `6867870`, `4c3a83d` |
| `CommandBuffer::closePass(next, kept)` | 5120 | Cierra el pase: `keptFor` (5133) y `loadStore` (5139) deciden qué attachment se carga y se guarda; un memoryless solo se guarda cuando el pase de Metal sigue en otro del núcleo | `db05cce`, `050c059` |
| `gmemWorth` | 2532 | La desigualdad de turnip con D proporcional a los draws (§10.4) | `92ed3e7` (de `gpu-pass`) |
| `pushedRanges` | 260 | N-03: un rango que pasa de las páginas del buffer se carga directo. En dispatch, `src/compute.cpp:373-400` | `c571fcd` |
| `kEmptyScissor`; `drawFacts` 1673, `fastFacts` 3740, `drawArea` 2624 | 323 | N-04: scissor vacío (1,1)-(0,0); el draw no toca ningún bin | `4cf8232` |
| `emitDraw` 1789, `emitFast` 4091 | — | N-18: `SINGLE_PRIM_MODE` para un draw con fetch en sysmem (`Options::fbReadOverlap`) | `4c3a83d` |
| `appendStream` | 4191 | NOP y `append` | `316d077` |
| `render::drawStates` | `src/gmem.cpp:158` | Los draws de un pase como grupos de estado; almacenamiento por hilo (`Work`, 107) | `db05cce` |
| `Texture::setMemoryless`, `Texture::swizzled` | `include/…/texture.hpp:309`, `src/texture.cpp:890` | Marca memoryless; la vista con swizzle la conserva | `050c059`, `e22d7bf` |
| `CommandQueue::checkVsc`, `takeSlab`, `commandBuffer`; `CommandBuffer::piece`, `finish` | `src/command.cpp:281`, `155`, `569`, `80`, `429` | Palabra de desbordamiento del VSC por chip; slabs sin poner a cero; reciclado entre command buffers | `b935418`, `1eedf93`, `99279c0`, `01ca4f6` |

Núcleo, compilador y caché de stages (`src/compiler.cpp`; `include/…/compiler.hpp:83-160`):

| Función | Línea | Qué hace | Commit |
|---|---|---|---|
| `compileStage` | 1404 | Caché y semillas sin cerrojo (`found`, 1417); `gCompilerLock` (55) solo para compilar; con y sin preámbulo; guarda el stage y su registro de índice | `6594789`, `059f85d` |
| `stageCacheName` | 1180 | Nombre del fichero: hash de `kCacheBuild`, tamaños de `Stage` y `Kernel`, `iboBase`, bitcode, cada constante suministrada y el buffer conocido | heredado |
| `stageCacheSave`, `stageCacheLoad`, `stageCacheFind` | 1216, 1254, 1305 | Formato del `.stage`; búsqueda en el directorio escribible y en las semillas | heredado, `6594789` |
| `knownIndexName`, `knownIndexFind`, `knownIndexFindAnywhere`, `knownIndexNote` | 1327, 1338, 1365, 1381 | El índice `<hash>.known` por función y forma del buffer; búsqueda por máscara; alta de un registro en un solo `append` | `059f85d` |
| `foldKnownLoad`, `KnownFold`, `translate` | 264, 260, 286 | El plegado anota los bytes leídos; `translate` cronometra frontal y plegado | `059f85d` |
| `compileStageOnce` | 1472 | Una compilación (frontal, plegado, lowering, ir3) | heredado |
| `takeCompileTimes`, `CompileTimes` | 1398; `compiler.hpp:153` | Tiempos por hilo desde la última consulta | `6594789`, `059f85d` |

Interfaz C (`src/c_api.cpp`, declarada en `include/hakios-metal/hakios_metal.h`):

| Función | Línea | Commit |
|---|---|---|
| `hakios_metal_texture_set_memoryless`, `hakios_metal_texture_memoryless` | 549, 553 | `050c059` |
| `hakios_metal_cb_pass_access`, `hakios_metal_cb_pass_moved` | 987, 996 | `4e0a51a`, `050c059` |
| `hakios_metal_program_specialize` | 1189 | heredado |
| `hakios_metal_program_known_reads`, `hakios_metal_compile_times`, `hakios_metal_program_fs_traits` | 1271, 1278, 1293 | `059f85d`, `6594789`, `8707158` |
| `drawCommon` (scissor vacío en 1566) | 1452 | `25ad496`, `4cf8232` |
| `hakios_metal_draw_states`, `hakios_metal_cb_set_gmem_off` | 938, 913 | `afc2eca`, `gpu-pass` |

Plug-in (`userland/src/HakiosMetalCA.m`, 10 724 líneas; no se construye en host):

| Función | Línea | Qué hace | Commit |
|---|---|---|---|
| `hm_bootargs` | 130 | Boot-args y `/var/tmp/metal.args` | heredado |
| Traza de frame: `hm_ft_mode`, `hm_ft_watch`, `hm_ft_take`, `hm_ft_pass`, `-hakiosFtFinish` | 1568, 1965, 2014, 2244, 6613 | `metal_trace=frame`; líneas `cb enc att tex pipe pblend draw dtex dsamp dbuf gpass commit` | `8707158` |
| `hm_ft_work_began`, `hm_ft_worked` | 1518, 1524 | Cuenta/ms/MB de texturas, superficies, buffers, subidas, pipelines y copias para la línea `commit` (7805) | `6594789` |
| `hm_bitcode_for_how`, `hm_bitcode_nearest` | 2821, 2861 | N-01: la variante exacta por la etiqueta de la función o del pipeline, si no el módulo propio con las constantes de CoreAnimation; la cercana solo si el compilador rechaza | `81dd364` |
| `-newRenderPipelineStateWithDescriptor:error:` | 4367 | Las dos etapas del mismo origen (4394-4432); línea `linked … made in` con los tiempos del compilador (4534) | `81dd364`, `6594789` |
| `hm_align`, `-hakiosBaseAlignment:`, las seis respuestas | 3659, 3677, 3687-3700 | N-07 detrás de `metal_align`; línea de consola en 3736-3752 | `e22b881`, `96d9bac` |
| `-newBufferWithBytesNoCopy:…` | 3817 | N-12: copia al crear | heredado |
| `-hakiosNewTextureWithDescriptor:`, `…iosurface:plane:` | 4772, 4909 | Creación de texturas; `hakios_metal_texture_set_memoryless` (4900); los puntos de entrada públicos (5096, 5105) aplican el swizzle | `81dd364`, `e22d7bf` |
| `-hakiosConvertYCbCr`, `-hakiosRefreshShadow` | 5697, 5743 | N-05 y N-06: copias por CPU | heredado |
| `-hakiosSwizzledBy:` | 5883 | N-14; `metal_swizzle=0` | `e22d7bf` |
| Interruptores de los tiles: `hm_gmem_on`, `hm_gmem_off`, `hm_gmem_draws` | 7122, 7155, 7177 | Se aplican al crear el command buffer (6538-6549) | `gpu-pass` |
| Línea `passes:` | 7264-7274 | `wrote read loaded stored` y el motivo de sysmem | `4e0a51a`, `81dd364` |
| `-hakiosKeepFragment:constants:count:` | 9098 | Qué pipeline es «genérico» (fragmento de 4 096 palabras o más con un buffer de constantes de 256 B o menos); reserva de las ranuras | heredado, `96d9bac` |
| `hm_spec_exact`, `-hakiosProgramFor:offsets:count:` | 9150, 9163 | Ranuras de especialización: coincidencia exacta, alias recientes, máscara; cola `hakios.metal.specialise` (9234) | `6c42baf`, `96d9bac` |
| `hm_skip_word` | 9914 | `metal_skip` | heredado |
| `-hakiosDraw:…`, `-hakiosDrawOnce:…` | 9868, 10176 | El draw; `_vsTexturesTold` (10252) | `6c42baf` |

Herramientas y pruebas dentro de git (`hakios-metal/`): `tools/drawbench.cpp` (escenas A-H, J-L, P-R, V, W y, con
`--stages`, S, T, U; `--gpu`, `--each`, `--golden`, `--long`, `--record`, `--cold`, `--no-memoryless`: opciones en
1043-1057), `tools/stagecc.cpp`,
`tools/dev.mk`, `tests/golden.hpp` y `tests/golden/{tests,drawbench}-{a635,a610}.txt`. Pruebas de §10.2:
`tests/render_test.cpp:631` (scissor vacío), `:2161` (N-03), `:4460` (N-18), `:6507` (memoryless);
`tests/draw_state_test.cpp:209` (scissor por la interfaz C) y los frames aleatorios de §4. Fake GPU:
`include/…/fake_gpu.hpp:162` (`Stats::loadedPixels`), `src/fake_gpu.cpp:2012` (`reaches`).

### 11.5 No conformidades de 19 §2.9: estado

| N.º | Estado | Commit | Nota |
|---|---|---|---|
| N-01 | Hecha | `81dd364` | [M] 0 sustituciones desde `merge-4` |
| N-02 | Pendiente, a propósito | — | Sin rechazos en uso normal; falta saber qué hace CoreAnimation con un buffer en `Error` |
| N-03 | Hecha | `c571fcd` | [M] 0 `refused` desde `merge-4` |
| N-04 | Hecha | `4cf8232` | Prueba de host; sin caso en el teléfono |
| N-05, N-16 | Pendientes | — | YCbCr por copia de CPU: activa en uso normal. Diseño: convertir en la GPU, en una pasada propia, al ejecutar |
| N-06 | Pendiente | — | Superficies de filas no alineadas (2 848 B) por copia de CPU: activa en uso normal. Mismo diseño |
| N-07 | Hecha y apagada | `e22b881`, `96d9bac` | Depende de N-12 (§10.7); `metal_align` |
| N-08 | Hecha | `81dd364` | `edr_scale` se compila como se pide; sin ejercitar |
| N-09 | Sin tocar | — | No aparece en ninguna consola |
| N-10, N-11, N-13, N-15, N-19, N-20, N-26 | Sin tocar | — | Fuera de lo que mostraron las trazas |
| N-12 | Pendiente; es la causa probable de la regresión de `merge-6` | — | Buffers *no-copy* y texturas sobre buffer son copias al crear (§10.7, §11.6) |
| N-14 | Hecha | `e22d7bf` | Sin ejercitar en el teléfono; `metal_swizzle=0` |
| N-17 | Abierta; su coste está corregido | `059f85d`, `96d9bac` | La especialización sigue leyendo el buffer al codificar; lo corregido es la clave (bytes leídos) y la espera (§10.6) |
| N-18 | Hecha | `4c3a83d` | `metal_gmem_off=8192` lo apaga |
| N-22, N-35 | Sin tocar | — | Del kernel |
| N-24 | Hecha | `81dd364` | `luma_boost` se dibuja en todos los frames |
| Memoryless guardada (no numerada en 19) | Hecha | `050c059` | [M] `loaded 0x1 stored 0x1` |
| Cerrojo del compilador antes de la caché (rendimiento) | Hecha | `6594789` | [M] §10.6 |

### 11.6 Diseño pensado y no implementado

Todo lo de esta sección es propuesta: [H] salvo los datos que se citan.

**a) La clave de especialización.** Hecho: la clave son los bytes que la compilación lee, con índice por función
(§10.6). Lo que falta de la clave:

- `stageCacheName` (`src/compiler.cpp:1196-1199`) mezcla en el hash todas las constantes de función que se le
  suministran, también las que el módulo no declara. `translate` (`:289-298`) solo aplica las que el módulo declara:
  las demás no cambian el resultado y sí el nombre, y CoreAnimation suministra a cada función el juego entero de su
  pipeline. Normalizar: mezclar solo las constantes que `air_module_function_constants` devuelve para el módulo, con
  su valor final. Cambia los nombres de fichero: o se busca por el nombre nuevo y luego por el antiguo, o la caché
  del teléfono deja de valer. Cuántos duplicados produce hoy en el teléfono no está medido.
- Las 128 ranuras del plug-in no tienen desalojo: llenas, lo nuevo se dibuja con el genérico sin especializar hasta
  reiniciar backboardd (la consola lo dice una vez). Corresponde desalojar la menos usada, cuidando que su programa
  no se libere mientras un draw lo tiene entre manos: `-hakiosProgramFor:` devuelve el puntero sin retenerlo.
- Mientras una configuración compila, cada variante de basura suya que llega toma una ranura propia y encola su
  propia llamada, que sale del índice sin compilar cuando la primera acaba (0,4 ms en host). No cuesta
  compilaciones; gasta ranuras.
- El índice no tiene recogida: los `.stage` duplicados de antes siguen en el directorio, inertes.

**b) No compilar en uso (el requisito del usuario).** Qué se compila hoy en uso: (1) cada configuración nueva del
shader genérico, 0,43-1,1 s en la cola de fondo, dibujando mientras con el genérico de 32 064 palabras; (2) el módulo
propio de cada pipeline que CoreAnimation crea en ejecución, la primera vez, en el hilo de render (coste sin medir);
(3) las variantes de la library la primera vez, milisegundos cada una. Con la clave correcta el conjunto es finito:
19 configuraciones en todas las trazas, 11 en el índice del teléfono tras los primeros minutos de `merge-7`. Diseño:

1. *Guardar las entradas, no solo los resultados.* Al compilar un stage por primera vez se archiva lo que lo produjo
   (bitcode, constantes, `iboBase`, binding y bytes conocidos bajo la máscara) junto al `.stage`. El bitcode de un
   módulo propio solo existe cuando Metal lo entrega: sin guardarlo no se puede volver a compilar sin CoreAnimation.
2. *Un paso de precompilación en el núcleo* que recorre las entradas y compila las que no tienen stage con la clave de
   esta build (tras una actualización del driver, todas). Corre antes de que aparezca la interfaz, con la pantalla de
   arranque puesta y fuera del hilo de render: de forma síncrona al crear el dispositivo en backboardd, antes de la
   primera cola, o en un proceso lanzado antes de backboardd. Coste estimado con los tiempos medidos: 20-30
   compilaciones de 0,5-1 s.
3. *Semilla de instalación.* El driver ya lee `HAKIOS_METAL_CACHE_SEED` (`/redwood/share/hakios-metal-cache`, solo
   lectura, `CA.m:608-609`, `:3419-3425`) después del directorio escribible, también para los `.known`. La semilla es
   la caché (entradas y stages) de un teléfono tras un recorrido de la interfaz. Compilarla en host con `stagecc` es
   posible si el stage sale idéntico byte a byte al del teléfono: `Stage` tiene la misma disposición LP64 en los dos,
   pero la igualdad del resultado **no está verificada** (compilar las mismas entradas en los dos y comparar ficheros).
4. *Abaratar cada especialización.* De los 172-193 ms de host, 55-66 son el frontal sobre el módulo entero y 106-118
   el lowering sobre el shader entero. Guardar el NIR del genérico tras el frontal (una vez por módulo) y podar el
   código muerto justo después del plegado, antes del lowering, dejaría cada configuración en el plegado más el
   lowering de 128-256 palabras.
5. *Lo que quede fuera.* Una configuración que ninguna semilla trae se compila en uso una vez y queda en las
   entradas para el siguiente arranque. Cerrar el conjunto del todo pediría enumerar las configuraciones desde
   CoreAnimation, que no está estudiado.

**c) Tiles o sysmem por muestras medidas** (§10.4). No tocar hasta resolver §11.7. turnip toma dos instantáneas
`ZPASS_DONE` del contador de muestras, al abrir y al cerrar el pase (`tu_autotune.cc:642-733`), y decide con las del
mismo pase la vez anterior (`:541-640`). Aquí el contador ya se usa para las consultas de oclusión
(`src/render.cpp:2280-2323`, con la espera que el A610 necesita) y la cola ya guarda historia por clase de pase
(`CommandQueue::preferGmem`, `noteDraws`, `peakDraws`, `src/command.cpp:291-326`; `render::tuneKeyOf`). Falta: emitir
las dos instantáneas en cada pase, leerlas al completarse el buffer, guardarlas por clase y dar a `gmemWorth`
D = muestras × bytes por muestra de los attachments escritos (doble si mezcla), al cerrar y también al abrir, en
lugar de «its like had N draws». Cambia el stream (tres paquetes al abrir y al cerrar): interruptor en
`metal_gmem_off`, el fake tiene que modelar el contador, y los golden de todo pase cambian. Efecto esperado: las
pasadas de 23-25 draws con capas a pantalla completa (8-11,7 ms en sysmem) pasan a tiles, y el pase final sobre la
pantalla deja de alternar de modo.

**d) Trabajo del procesador de comandos por bin** (§10.3; [M] pesa: con `metal_gmem_off=64` los buffers/s bajan de
38,7-46,3 a 35,3 y commit→fin sube de ~28 a 43,8 ms, §6). En la escena S, de 897 K palabras: grupo de programa 2 661
ejecuciones × 136 palabras, cargas 3 232 × 51, viewport 3 232 × 21, rasterizador 1 841 × 28, vértices 1 185 × 34,
mezcla 873 × 33, pase 237 × 69, y 160 K fuera de grupos (cada tile lee los `CP_SET_DRAW_STATE` y el paquete de draw de
los 110 draws aunque se salte 70).
Caminos, sin medir ninguno: grupos idénticos entre draws consecutivos compartidos por dirección, para que el
procesador no los repita (hoy todos van marcados `DIRTY`, `0a65a5b`; el porqué está en 14 §3.1); viewport y
scissor en grupos separados; una lista de draws por bin hecha en la CPU con el área de cada draw (`render::drawArea`),
que quita las 160 K. `drawbench --gpu` da las palabras por grupo de cada variante antes de ir al teléfono.

**e) N-12: memoria compartida de verdad.** Un buffer *no-copy* tiene que ser las páginas del llamante: el servicio del
kernel tendría que mapear memoria del proceso en el espacio de direcciones de la GPU (base y longitud alineadas a
página, que es lo que Metal exige a quien llama) y mantenerla fijada hasta el deallocator. Refrescar la copia en cada
uso no es viable con miles de imágenes por frame. Hasta entonces `metal_align` queda en 0.

**f) Crear texturas en uso** (§10.6): medir primero dentro de `-hakiosNewTextureWithDescriptor:`; si es la llamada al
kernel, reciclar la memoria de texturas liberadas como ya se reciclan los buffers (la línea
`buffers: N made, M taken again from the pool` de la consola).

**g) Memoria de las texturas memoryless**: asignar sus filas solo cuando un pase en sysmem las necesita.

**h) `metal_all`**: análisis completo en §10.5; nada que hacer en el driver antes del aislamiento de direcciones en
el kernel.

### 11.7 Parpadeo del widget de Tiempo y destellos al abrir apps

[M, usuario, con `merge-4`] El widget de Tiempo parpadea cuando algo se le superpone (un menú, un panel). No se sabe
si ocurre con `merge-3`, `merge-5` o `merge-7`. El informe 20 (§4, «Parpadeo») aporta el contexto del lado de
SpringBoard: al superponerse algo al home, SpringBoard cambia la vista viva del widget por su instantánea
(«Requested mode changed to static») y al volver hace lo contrario («changed to live», «Create caar snapshot view»),
sin relanzar el widget; el parpadeo estaría en cómo se dibuja ese cambio. Eso pone delante las hipótesis de imágenes
y superficies leídas por copia (H4, H5). Hipótesis, todas [H]:

- **H1. El mismo pase sale unas veces en tiles y otras en sysmem**, y los dos modos no dan lo mismo. [M] El pase
  final sobre la pantalla sale `draws 7 tiles 42 … touched 0x301` y otras veces
  `draws 11 … sysmem: its like had 11 draws` (`ab-k353-merge4-a.txt`); con `merge-7`,
  `draws 5 in sysmem (its like had 5 draws at most lately)`. La regla de apertura decide sin saber que el pase lleva
  un fetch. N-18 era un candidato de la diferencia entre modos.
- **H2. El degradado del widget** es `PBGRAXm_TimgA2Xhfn_IsrcN3Oc3mtc4`, uno de los pipelines que desde `merge-4` se
  compilan del módulo propio (antes, la variante sin ruido). [M] Su buffer 5 (`noise_scale`, un `half` de 2 B) va
  seguido de bytes viejos del pool, distintos en cada buffer de frame (`8b3a…`, `d040…`): si el shader leyera más de
  esos 2 B, el ruido cambiaría de un frame a otro. El fondo usa el mismo camino (`TimgA2Xhfn_Isrc`, de la library)
  sin que nadie lo vea parpadear.
- **H3. `luma_boost`** (se dibuja desde `merge-4`) con resultado distinto en sysmem y en tiles.
- **H4. La copia por CPU de superficies de filas no múltiplo de 64 B** (N-06): 2 848 B = 712 px, el ancho de un
  widget mediano. La traza lo dice en la línea `tex` (`shadow=1`).
- **H5. N-12**: la imagen del widget como client storage, creada de nuevo en cada frame con una copia de memoria que
  otro proceso está escribiendo. En una traza se ve si el `id` de la textura del widget (`origin=buffer`) cambia de
  un frame al siguiente.

Los pasos que lo deciden, **ninguno ejecutado** (los ejecuta el coordinador; un cambio cada vez en
`/var/tmp/metal.args`):

1. ¿Parpadea con `merge-3` instalado? Si no, es H2, H3 o lo de memoryless; si sí, H1, H4 o H5.
2. Con `merge-4`: `metal_skip=luma_boost` (quita H3); `metal_gmem_draws=1` (todo lo que puede va a tiles: si deja de
   parpadear es H1 con el lado sysmem malo); `metal_gmem_draws=0` (todo en sysmem: si el widget sale mal de forma
   fija, confirma el lado sysmem).
3. `merge-5` (o `merge-7`) tal cual y con `metal_gmem_off=8192`: si sin el interruptor no parpadea y con él sí, era
   N-18.
4. Una traza durante el parpadeo (`metal_trace=frame`; `echo 40 > /var/tmp/metal.trace` con el menú ya encima del
   widget, sin tocar nada más) con la consola de ese rato y dos capturas de pantalla, una de cada estado. Con 40
   buffers seguidos se ve si lo que CoreAnimation pide es igual frame a frame (entonces lo pone el driver: el modo del
   pase, qué pipeline dibuja el widget, de qué textura) o si cambia.

**Destellos de colores al abrir apps**: la traza de abrir Tiempo (`capturas/metal-trace-2079-2.txt`) no tiene nada
mal formado. Candidatos a la vista: los pipelines sustituidos (corregido en `merge-4`), la imagen de lanzamiento en
ASTC 4×4 de 750×1624 (`TimgA2Xhf_Ixrg`, solo en el primer frame) y un relleno blanco opaco del 90 % de la pantalla
bajo una textura de 752×1626 mezclada durante 20 frames (cb 18-38). Hace falta una captura de pantalla del frame del
destello, o `echo 90 > /var/tmp/metal.trace` con captura de pantalla a la vez, para casar el color con un draw. No se
sabe si siguen ocurriendo con `merge-7`.

### 11.8 Trampas

- **`check.sh`**: su código de salida no es fiable; se miran las líneas. Las escenas con los stages del teléfono
  imprimen cientos de líneas `left out`: `grep -v 'left out'`.
- **El plug-in no se construye en host.** No tiene pruebas; solo la comprobación de sintaxis de §11.2 y el teléfono.
  El build de iOS usa la libc++ 15 del SDK: lo que compila en host puede no compilar ahí.
- **`CACHE_BUILD`**: sin él, cualquier cambio de cabecera cambia la clave y el teléfono recompila todo en uso; con
  él, un cambio de lo que el compilador produce cargaría stages viejos (§11.2).
- **Instalar por renombrado** (lo hace `bundle.sh`): copiar encima del binario cargado hace que dyld lo rechace y
  CoreAnimation componga por software.
- **`codesign -v` sobre `out/NOMBRE/HakiosMetal`** falla («code has no resources but signature indicates they must be
  present») porque toma el directorio por un bundle: verificar una copia en un directorio vacío.
- **`metal_gmem=0` no existe.** Todo en sysmem es `metal_gmem_draws=0`. El protocolo del parpadeo que tiene el
  coordinador nombra `metal_gmem=0` en su paso 2: el interruptor correcto es el de §11.7.
- **`ab.sh` reescribe `/var/tmp/metal.args`** en cada ensayo y empieza a capturar la consola unos 30 s después de
  reiniciar backboardd: las líneas `HM_ONCE` y las de la primera cola (respuestas de alineación, interruptores en
  vigor, primeras compilaciones) no están en `medicion/ab/`.
- **El modo de traza encarece la codificación** (mediana de 15-41 ms por buffer frente a 2-6 ms): no comparar
  tiempos de codificación de una traza con los de una consola.
- **Variabilidad**: ensayos idénticos dan 38,7-46,3 buffers/s, y entre ensayos con opciones de presentación del
  kernel distintas commit→fin va de 7,6 a 14-16 ms (§6). Comparar solo lo igual, con n≥3.
- **El reloj del teléfono no es el de la Mac** (los ficheros de la caché del teléfono llevan otra hora): no casar por
  hora de pared.
- **Las cuentas de texturas de una traza** son por command buffer que las nombra, no texturas distintas.
- **El fake GPU no rasteriza**: fragmentos, mezcla y tiempo de GPU no salen del host; palabras del CP, cargas, tiles y
  megabytes movidos, sí.
- **El uber crudo de `default.metallib` no compila en host** con las constantes de CoreAnimation; para medir se usan
  los 451 módulos de variante de `cpu-tools/variants/` (sacados de `default.pipelinelib`).
- **Mesa nativo**: con el clang 18 de conda no enlaza (LTO) ni compila contra la libc++ del SDK de macOS (pide
  `__builtin_ctzg`); va con el clang del sistema. El `ld` de Apple no tiene `--start-group`: `build-hostcc.sh` enlaza
  los archivos uno a uno.
- **Scripts en bash**: zsh no parte en palabras las variables sin comillas.
- **`Texture::sampledWords`** guarda el descriptor de una textura: quien cambie su buffer o su swizzle después de
  crearla deja el descriptor rancio (`Texture::swizzled` crea otra textura, y por eso no lo sufre).
- **Disco**: 14 GB libres en la Mac al escribir esto; `mesa/build-host` ocupa 84 MB y `wt-cpu/hakios-metal/out` 131 MB.

### 11.9 Dónde está cada cosa

Todo bajo `~/sapphire-angel/research/metal/` salvo este informe. Nada de esto está en git de ios-sapphire.

| Ruta | Qué es |
|---|---|
| `rebuild/wt-cpu/` | El árbol de trabajo (rama `cpu-draw`): `hakios-metal/` (núcleo, pruebas, herramientas), `userland/src/HakiosMetalCA.m` (plug-in) |
| `rebuild/build-bundle.sh`, `env.sh`, `build-mesa.sh` | Receta del bundle de iOS, entorno (clang 18.1.8, SDK), Mesa para iOS |
| `rebuild/out/` | Bundles construidos (§11.1) |
| `rebuild/mesa/build-host/`, `rebuild/mesa/native-host.ini` | Mesa nativo para el compilador en host |
| `rebuild/cpu-tools/check.sh`, `measure.sh`, `table.py`, `ab-host.sh`, `build-hostcc.sh` | Suite completa; medidas de host y su tabla; A/B de binarios; `stagecc` |
| `rebuild/cpu-tools/golden-stages-{a635,a610}.txt`, `each-base-a610.txt` | Golden de las escenas S, T, U; referencia de `drawbench --each` con el camino de draw de la base |
| `rebuild/cpu-tools/variants/` | 451 módulos de variante de CoreAnimation (`frag.*.metallib`, `vert.*.metallib`): código de Apple, fuera de git |
| `rebuild/cpu-tools/results/`, `bin/` | CSV de `measure.sh` (`base`, `A1-kept`, `merge2`); binarios de `drawbench` para A/B |
| `rebuild/cpu-tools/stage-info.txt` | Qué hace cada stage de fragmento de la caché del teléfono con los attachments |
| `rebuild/cpu-tools/tmp/` | Logs: `build-merge{4,5,6,7}.log`, `check-*.log`, `final/check-tip.txt`, `host-mesa-flags.txt`, `phone-known/phone.known` (el índice leído del teléfono) |
| `auditoria-userland/stage-cache/files/` | 202 stages de la caché del teléfono, entrada de las escenas S, T, U |
| `ios-graficos/qc-20H392/extract/System/Library/Frameworks/QuartzCore.framework/` | `default.metallib` y `default.pipelinelib/` (`functions`, `pipelines.desc`) del teléfono |
| `ios-graficos/trace/trace-frame.py`, `LEEME.md` | Lector de trazas y formato |
| `ios-graficos/trace/capturas/` | `merge-1` con el bundle de traza: home (`metal-trace-2079-1.txt`) y abrir Tiempo (`-2.txt`), con sus informes |
| `ios-graficos/trace/capturas-blur/` | `merge-5`: Centro de Control y vistas con blur, recién arrancado (`metal-trace-800-{1,2,3}.txt`) |
| `ios-graficos/trace/capturas-recientes/`, `capturas-recientes-bocache/` | `merge-5`: selector de apps, primera y segunda vez (`891-{1,2}`, `951-{1,2}`) |
| `ios-graficos/trace/capturas-merge6/` | `merge-6`: recientes primera y segunda vez y Centro de Control (`metal-trace-1093-{1,2,3}.txt`), con los tiempos de pipelines y las líneas `commit` |
| `medicion/ab/` | Consolas de cada ensayo (`ab-ETIQUETA.txt`), líneas del kernel (`.fb`) y CPU por proceso (`.cpu`): `ab-k352-merge3-b`, `ab-k353-merge4-a`, `ab-k353-todo-{1,2}`, `ab-k353-merge7`… |
| `medicion/shots/` | Capturas de pantalla: `hoja-r5.png`, `hoja-r6.png` (la regresión de `merge-6`), `hoja-vistas-m5-m.png`, `hoja-vistas-m7-m.png` |
| `medicion/bundle.sh`, `ab.sh`, `ab-phone.sh`, `ab-sum.py`, `vistas.sh`, `homeswipe.sh` | Instalar, ensayar, resumir y capturar: del coordinador |
| `display/work/xnu-0350/` | El kernel leído para §10.5 (`SapphireGpu.cpp`) |
| `~/Documents/ios-sapphire/dev-notes/investigacion/` | Este informe; 10 (auditoría de partida), 14 (`gpu-pass`), 19 (cómo dibuja iOS y la lista de no conformidades) |
