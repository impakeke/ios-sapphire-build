# 10 — Auditoría de rendimiento y arquitectura de hakios-metal (userland), 2026-11-14

Informe fechado. Alcance: la parte userland del driver Metal que dibuja la pantalla con `sweetmetal=2`
(`hakios-metal` + el plug-in ObjC de CoreAnimation), leída como revisor de un driver gráfico de producción.
No cubre el kernel (`SapphireGPU` / `sweet_*`), los relojes de la GPU ni la identidad binario↔fuente (informe 08).

Convención: **[O]** observación propia (código con `archivo:línea`, o medida propia reproducible),
**[M]** medida en el teléfono tomada por el coordinador (archivo crudo citado), **[H]** hipótesis razonada sin medir,
**[HEREDADO]** afirmación de README/comentarios/notas de HackiOS o del autor del port que no se ha vuelto a medir.

## 0. Qué se auditó y con qué referencia

| Cosa | Dónde | Identificación |
|---|---|---|
| Fuente del port al A610 (la que se cita por defecto) | `~/sapphire-angel/research/metal/rebuild/hakios-angel/` | `Angelpro09xd/hakios-xnu-kernel`, rama `sapphire-a610`, `5c3bd9a` (2026-11-13); 6 commits sobre HackiOS `63fc2b4` |
| Fuente de HackiOS (base) | `~/sapphire-angel/research/metal/hakios-xnu-kernel/` | `oosexgang/hakios-xnu-kernel` @ `63fc2b4` (2026-11-06) |
| Núcleo C++ | `hakios-metal/src/{render,command,texture,c_api,compiler,gpu}.cpp`, `include/hakios-metal/*.hpp` | — |
| Plug-in que sirve a CoreAnimation | `userland/src/HakiosMetalCA.m` (9370 líneas en el port) | — |
| Referencia primaria | `~/sapphire-angel/research/metal/auditoria-userland/mesa/` | Mesa upstream @ `767fbf7c6492f64549c90e9a080ab5417895a9ec` (2026-11-13) |
| Binario que corre | `/System/Library/Extensions/HakiosMetal.bundle/HakiosMetal` | 8 630 976 bytes; su relación exacta con `5c3bd9a` es materia de 08 |

Abreviaturas de cita: `render.cpp:N`, `command.cpp:N`, `command.hpp:N`, `c_api.cpp:N`, `compiler.cpp:N`, `gpu.cpp:N`
son del árbol del port (`hakios-metal/src/` o `include/hakios-metal/`); `CA.m:N` es `userland/src/HakiosMetalCA.m` del
port; `mesa:ruta:N` es el clon de Mesa en el commit de la tabla.

**[O] El README de hakios-metal no describe el código.** Dice «every draw here is a pass of its own» y «GMEM (tiled)
rendering … refused by name» (`hakios-metal/README.md:97-100,136`); el código tiene pases compartidos entre draws
(`render.cpp:2865-2874`), GMEM por tiles con binning por hardware (`render.cpp:2176-2537`), elección GMEM/sysmem por
historial (`render.cpp:2905-2931`), grabación diferida (`c_api.cpp:40-104`) y caché de stages en disco
(`compiler.cpp`, `stageCacheSave`/`stageCacheLoad`). Nada de lo que sigue se apoya en el README.

**Material propio (fuera de git), `~/sapphire-angel/research/metal/auditoria-userland/`:**
`framecount.cpp` (cuenta peticiones al kernel, paquetes PM4 y asignaciones de heap de un frame sintético sobre el fake
GPU) con sus salidas `framecount*.out`; `hm/` y `hm-port/` (copias de trabajo de la base y del port; los 261 tests de
host pasan en ambas con Apple clang 21); `stage-cache/` (copia de solo lectura de la caché de stages del teléfono);
`disasm/` (desensamblador ir3 de host construido con el `ir3-isa.c` de Mesa 25.0.7 y `parse_stage.py`).

## 1. Datos medidos

### 1.1 En el teléfono

**[M] Perfil de pila del hilo de render** (`com.apple.coreanimation.display.primary` de backboardd, 17 958 muestras a
0,5 ms durante el swipetest; `~/sapphire-angel/research/metal/medicion/perfil-1.txt`):

- 90,3 % de las muestras en modo usuario; 5,05 % en traps de IOKit. El hilo está saturado por CPU.
- Del tiempo de usuario: HakiosMetal 47,2 % (self), QuartzCore 26,8 %, `libsystem_malloc` 9,4 %,
  `libsystem_platform` (memmove/memset) 8,2 %, `libobjc` 3,9 %.
- Inclusivo por la ruta de draw: `hakiosDraw` 57,8 % → `drawCommon` 52,9 % → `CommandBuffer::draw` 45,4 % →
  `encodeDraw` 24,1 % (8,8 % self) y `appendDeduped` 10,1 % (7,1 % self); `bindArgumentBuffers` 3,4 %;
  `programAddress` 2,3 %; `stageTextures` 2,2 %; `checkTarget` 1,2 %; `link` 1,0 %; `vertexFetch` 0,9 %;
  `checkStage` 0,9 %; `pushedRanges` 0,8 %.

**[M] Contadores del propio binario** (`metal_fps` en `/var/tmp/metal.args`, que `hm_bootargs` añade a los boot-args,
`CA.m:117-139`; `~/sapphire-angel/research/metal/medicion/cons-fps1-a.txt`):

| Magnitud | Reposo | Durante swipes |
|---|---|---|
| command buffers por segundo | 10 | 16-31 |
| draws por command buffer | 108 | 115-223 |
| pasadas por command buffer | 1,0 | 3,0-11,4 |
| CPU del driver por draw («of ours» / «the core's») | 99 / 93 µs | 111-139 / 104-130 µs |
| «a buffer made to committed» (media) | 14,9 ms | 21,9-43,7 ms |
| `-commit` en el hilo que llama, por buffer | 2,4 ms | 2,3-3,2 ms |
| «commit to completion» (media) | 21,0 ms | 21,9-35,4 ms |
| GPU ocupada | 21 % | 60-106 % |
| pasada principal `750x1624`, 108-132 draws, **102 tiles** | 18,0-18,2 ms | 20,4-24,2 ms |
| otra pasada: `752x1626`, 35 draws, sysmem | — | 31,96 ms |
| GEM nuevos por periodo de 2 s | 0 | 34-68 (0,8-35,7 MB) |

Además: los draws se ejecutan en los procesadores lógicos 0-3 (`draw calls by processor: cpu0 … cpu3`), ninguno en 4-7;
`0 presented` (backboardd no usa `presentDrawable:`); `0 waits for completion`.

**[O] Lectura ligera propia (2026-11-14):** `kern.bootargs` no lleva ningún `metal_*`; la caché de stages
`/private/var/db/hakios-metal-cache` tiene 194 `.stage` y 8 `.keys`; `/redwood/share/hakios-metal-cache` no existe.

### 1.2 En el host (fake GPU, n ≥ 3 por cifra de tiempo)

`framecount` graba un frame sintético con `CommandBuffer::draw` configurado como lo configura el plug-in sin boot-args
(`CA.m:5321-5331`: GMEM permitido, `gmemMinDraws` 56, binning y `tuned` activos) y descodifica el stream que llega al
submit. Árbol del port, `-O2`, x86_64:

| Escena (blanco 750x1624 BGRA8) | palabras que lee el CP | `CP_WAIT_FOR_IDLE` | esperas en stream sobre una palabra | `CP_LOAD_STATE6*` | asignaciones de heap por draw | µs por draw (host) |
|---|---|---|---|---|---|---|
| G. 1 draw, 1 pase, 1 buffer | 601 (302 registros) | 4 | 2 | 5 | 30 | 55-72 |
| A. 20 draws con blending, sysmem | 1 415 | 4 | 2 | 94 | 7,2 | 5,5-9,6 |
| B. A con 5 draws de framebuffer fetch | 1 562 | 14 | 7 | 99 | 7,3 | 5,1-5,7 |
| D. 143 draws en 4 pases, todo sysmem | 8 066 | 13 | 8 | 669 | 5,9 | 3,7-4,0 |
| C. D con el pase principal en GMEM (constantes A635: 11 tiles) | 74 900 | 28 | 10 | 8 415 | 10,6 | 6,4-8,0 |
| **P. pase principal del teléfono**: 108 draws, 2 attachments, constantes A610 | **490 035** | 110 | 4 | **55 620** | 10,4 | 6,1-8,9 (mediana 6,3) |
| Q. P con cada 4.º draw de framebuffer fetch | **768 853** | **5 568** | 4 | 58 298 | — | — |
| R. los mismos 108 draws de P grabados una vez, en sysmem | 4 938 | 4 | 2 | — | 6,3 | 3,25-3,57 (mediana 3,27) |

[O] La escena P reproduce el recuento del teléfono: **102 tiles**. [O] En la base de HackiOS (`63fc2b4`) las mismas
escenas dan 20-34 asignaciones de heap por draw y 5,4-15 µs; el port las baja a 6-11 y 3,7-8.

### 1.3 Caché de stages del teléfono (`disasm/stages.txt`)

[O] 170 variantes compiladas del shader de fragmento «uber» de CoreAnimation (`fixed_frag_lph_cph` 117,
`fixed_frag_lph_cpf` 53) y 24 stages más (blur, downsample, vértices):

- **98 de 170 variantes leen el framebuffer** (`fbRead`): las 53 `_cpf` y 45 `_cph`. El desensamblado muestra un
  `isaml` del slot del blanco seguido de la mezcla en el propio shader: CoreAnimation hace el blending programable.
- Tamaño: 32-576 palabras (1-18 unidades de 16 instrucciones); mediana 96-128 palabras. Una variante simple (textura
  con tinte) son 14 instrucciones con registros `hr` (media precisión). Hay una entrada genérica de 32 064 palabras.
- `numTextureSlots`: 15 en 53 variantes, 10 en 16, 4 en 54; el shader muestrea 1-3. Ninguna usa prefetch (el A610 no
  lo tiene), ninguna hace `kill`, ninguna usa memoria privada.

### 1.4 Lectura conjunta

Hay dos cuellos independientes y del mismo tamaño, y cada uno basta para fijar ~30 fps:

- **A, CPU:** 111-139 µs × 115-223 draws = 13-31 ms de driver por command buffer en el hilo de render, más 2,3-3,2 ms
  de `-commit` [M]. QuartzCore gasta el 27 % del tiempo de usuario de ese hilo; el driver, el 58 % [M].
- **B, GPU:** la pasada principal tarda 18-24 ms con ~110 quads [M], y es constante entre reposo y movimiento.

## 2. Cuello A — CPU por draw

### 2.1 Qué hace hoy un draw (port `5c3bd9a`)

| Capa | Función | Trabajo por draw | % inclusivo [M] |
|---|---|---|---|
| ObjC | `-hakiosDrawOnce:` (`CA.m:8806`) | copia los handles de cada slot con un `objc_msgSend` por slot; `hakios_metal_cb_set_vertex_textures`; `hakiosProgramFor:` (hash FNV de 48 bytes leídos de memoria write-combined, `CA.m:7830-7838`); `strstr` del nombre del programa | 57,8 − 52,9 = 4,9 |
| API C | `drawCommon` (`c_api.cpp:1334-1471`) | rellena dos `Bindings` (vectores), `bindArgumentBuffers` × 2, `passOf` (copia del pase), construye `Draw`, 10-20 `keep`/`keepAlive` con `shared_ptr` por valor | 52,9 − 45,4 = 7,5 |
| Núcleo | `CommandBuffer::draw` (`render.cpp:2794-3122`) | `freshen` × 2, bucle de textura nula, `programAddress` × 2, `piece` de 8 KiB, comparación de pase, `gmemDrawOk`, clave estática, `encodeInPass` (× 2 si `dual`), `appendDeduped` (× 2 si `dual`), `use` por recurso | 45,4 |
| Núcleo | `encodeDraw` (`render.cpp:1252`) | valida todo y vuelve a generar todo el estado en un stream temporal | 24,1 |
| Núcleo | `appendDeduped` (`render.cpp:2741-2792`) | descodifica ese stream paquete a paquete y consulta cada registro en una tabla de 512 KiB | 10,1 |

El defecto es de arquitectura, no de micro-optimización: **cada draw vuelve a validar, vuelve a generar ~300-600
palabras de estado y después las filtra**, cuando lo único que cambia entre dos capas de un compositor es una textura,
unas constantes y, a veces, el programa.

### 2.2 Trabajo que se repite por draw y es función de un objeto

| Trabajo | Dónde | Depende solo de | Coste [M] |
|---|---|---|---|
| `checkStage` × 2 | `render.cpp:154`, llamada en `encodeDraw` | el programa | 0,9 % |
| `render::link` (port de `ir3_link_shaders`) | `render.cpp:1548`; `link.cpp:94` | el programa (ya se calcula en `linkProgram`) | 1,0 % |
| `checkTarget`, `windowOf`, `mrtWords` | `render.cpp:991`, `:603`, `:128` | el pase | 1,2 % + 0,5 % |
| `blendWords` por attachment | `render.cpp:850` | pipeline + formato | dentro de `encodeDraw` |
| `vertexFetch` (tabla de decode/dest) | `render.cpp:362` | pipeline (descriptor de vértices) + buffers ligados | 0,9 % |
| registros de programa: config, `CTRL_REG0`, `OBJ_START`, **precarga `ST6_SHADER`**, inmediatos | `render.cpp:1715-1803`, precarga en `:1759` | el programa | parte del self de `encodeDraw` y de `appendDeduped` |
| VPC, entradas y salidas del FS, MSAA, LRZ, MRT | `render.cpp:1660-1700`, `:1880-1970` | (programa, pase); solo se saltan si el draw anterior usó el mismo programa (`render.cpp:2976-2979`) | ídem |
| `Texture::sampledDescriptor()` | llamada en `stageTextures` (`render.cpp:634`) | la textura | 0,4 % |
| `programAddress`: compara cada 64.ª palabra del binario del shader | `command.cpp:113-133` | identidad del programa | 2,3 % |
| `bindArgumentBuffers`: copia el vector de buffers antes de mirar si hay argument buffers | `compiler.cpp:1595` | el stage | 3,4 % |
| `gmemDrawOk`: recorre texturas × attachments | `render.cpp:2320` | (programa, pase) salvo las texturas | 0,5 % |

[O] La precarga del shader (`CP_LOAD_STATE6` `ST6_SHADER`) se emite en cada draw de cada etapa aunque el programa no
cambie: en la escena A, 40 `CP_LOAD_STATE6_GEOM` y 54 `CP_LOAD_STATE6_FRAG` para 20 draws. `appendDeduped` no filtra
cargas, solo registros (`render.cpp:2773-2786`).

### 2.3 Asignaciones de heap y copias por draw

[O] 6-11 asignaciones de heap por draw en el port (tabla 1.2), solo en el núcleo. Orígenes:

- `loadDirect` crea un `std::vector` por carga (`render.cpp:100`); los inmediatos, otro (`render.cpp:1761`).
- `StageTextures::used` y `GfxIbos::used` (`render.cpp:584`, `:793`); `vsUbos`/`fsUbos` (`render.cpp:1425`).
- `std::vector<uint32_t> out` de las salidas del FS (`render.cpp:1963`).
- `std::string name = stageName(...)` al entrar en `vertexFetch` y `stageTextures` (`render.cpp:363`, `:636`).
- `bindArgumentBuffers`: `const std::vector<Binding> sets = b->buffers` × 2 (`compiler.cpp:1595`).
- `Bindings vsWithNull, fsWithNull` copiados enteros cuando el stage declara la textura nula (`render.cpp:2805-2831`);
  los uber shaders de CoreAnimation la declaran.
- `keep`/`keepAlive` reciben el `shared_ptr` por valor y comprueban después si ya estaba (`command.hpp:122-141`): dos
  operaciones atómicas por llamada aunque no se guarde.
- `uses_.push_back` por cada buffer y textura de cada draw (`command.hpp`, `use`); `Gpu::submit` los deduplica con un
  bucle cuadrático (`gpu.cpp:148-162`).

Memoria write-combined escrita por draw: la tabla del draw es una pieza de 8 KiB (`render::kTableBytes`,
`render.cpp:2859`) de la que se escriben 3,8 KiB fijos (`render.cpp:1561-1566`) para llevar 1-3 descriptores de 64
bytes; cada slab de 256 KiB reutilizado se pone a cero entero (`command.cpp:161`), otros 8 KiB por draw.

### 2.4 Grabación doble

[O] Con los valores por defecto del plug-in (`hm_gmem_draws()` = 56, `CA.m:5899`; `setGmem(true)`, `CA.m:5325-5326`),
todo pase que puede ir en GMEM y cuyo historial no es de menos de 28 draws se graba **dos veces**: `encodeInPass` para
tiles y otra vez para sysmem, y `appendDeduped` dos veces (`render.cpp:2913-2919`, `:2984-3003`, `:3085-3086`).
`closePass` elige al final (`render.cpp:3282`). Los pases con más draws son justo los que se graban doble.
[O] En host, los mismos 108 draws cuestan 6,3 µs/draw grabados doble y 3,27 grabados una vez (n = 5): **×1,9**.

### 2.5 Diseño objetivo del camino de draw

Referencia: `tu6_draw_common` de turnip (`mesa:src/freedreno/vulkan/tu_cmd_buffer.cc:8632`) y los grupos de fd6
(`mesa:src/gallium/drivers/freedreno/a6xx/fd6_emit.cc:557-600`). La documentación de Mesa explica el porqué: «Since
the SQE is not a fast processor, and tiled rendering means that many draws won't even be used in many bins … state
updates can be batched up into "draw states" that point to a fragment of CP packets. At draw time, if the draw call is
going to actually execute … the SQE goes through the GROUP_IDs and for any with an update since the last time they were
executed, it executes the corresponding fragment» (`mesa:docs/drivers/freedreno.rst`, sección *Draw states*).

Un draw en el diseño objetivo:

1. **Sin marshalling.** El encoder del plug-in escribe cada `set*` directamente en un `RenderEncoder` del núcleo
   (slots + bits de sucio). `drawCommon`, `passOf`, los `Bindings` y los arrays de handles desaparecen.
2. **Objetos de estado precalculados**, cada uno un fragmento PM4 ya codificado:
   - `ProgramState`, por (pipeline, firma del pase = formatos de attachment + nº de muestras): todo lo de la tabla 2.2
     que depende de programa y pase. Se construye una vez con el código de emisión actual (mismas funciones, mismas
     palabras) y se guarda en el pipeline. Las validaciones se hacen ahí.
   - `TexState`, por combinación (texturas, samplers): la tabla de descriptores (N × 64 + M × 16 bytes) y sus dos cargas.
     Caché por command buffer primero y persistente después (como `fd6_texture_state`,
     `mesa:src/gallium/drivers/freedreno/a6xx/fd6_texture.cc`).
   - estado del pase (MRT, profundidad, `RB_RENDER_CNTL`): una vez por pase, no por draw.
3. **Estado dinámico por bits de sucio**: viewport/scissor, raster, profundidad/stencil, color de blend, buffers de
   vértices. Se emite el bloque solo si cambió respecto del último emitido. Sin `RegShadow` ni `appendDeduped`.
4. **Constantes**: una carga por rango, escrita directamente en el stream.
5. **El draw**: `CP_DRAW_INDX_OFFSET` (3 o 7 palabras).

Resultado: ~20-25 palabras y cero asignaciones por draw; el trabajo de CPU es comparar unos bits y copiar esas
palabras. [H] < 1 µs en host; 2-4 µs en el teléfono contando ObjC.

### 2.6 Plan por etapas y por función

Cada etapa compila y se valida sola. La etapa A no cambia ni una palabra del stream, así que se valida por igualdad
de bytes.

**Etapa A — quitar trabajo repetido y asignaciones (mismo stream).**

| # | Función | Cambio | Ataca [M] |
|---|---|---|---|
| A1 | `bindArgumentBuffers` (`compiler.cpp:1591`), `drawCommon` (`c_api.cpp:1387`) | bandera `hasArgumentBuffers` por `CompiledStage`, calculada al compilar; sin ella no se llama | 3,4 % |
| A2 | `CommandBuffer::draw` (`render.cpp:2913-2919`), `closePass` (`:3282`) | grabar una sola vez: el modo se decide al abrir el pase con `peakDraws`; se elimina `dual`, `sysStream`, `headGmem` | ~la mitad de `encodeDraw` + `appendDeduped` en pases pesados (hasta ~15 %) |
| A3 | `programAddress` (`command.cpp:113`), `programBuffer` (`:181`) | identidad por id único del stage compilado; sin comparar palabras ni copiar el binario por command buffer | 2,3 % + 0,7 % |
| A4 | `encodeDraw` (`render.cpp:1548`) | usar `program.link`; recalcular solo si `link.cnt == 0` (programas hechos a mano en tests) | 1,0 % |
| A5 | `encodeDraw` | `checkStage` una vez por programa (bandera en `CompiledProgram`); `checkTarget`, `windowOf`, `mrtWords` una vez por pase (en `OpenPass`) | ~3 % |
| A6 | `loadDirect` (`render.cpp:99`), `stageTextures`, `gfxIbos`, `uboDescriptors`, salidas del FS (`:1963`), inmediatos (`:1761`) | arrays fijos y escritura directa en el stream; inmediatos ya alineados en el stage; `name` solo al rechazar | 9,4 % de malloc → 0 |
| A7 | `Texture` | descriptor muestreado calculado al crear la textura | 0,4 % |
| A8 | `CommandBuffer::draw` (`render.cpp:2805-2831`) | la textura nula se resuelve en `stageTextures`, sin copiar `Bindings` | parte del self |
| A9 | `piece` (`command.cpp:80`), `takeBuffer` (`:161`), tabla del draw (`render.cpp:1561-1566`) | pieza del tamaño real (≤ 512 bytes) y sin poner a cero lo que no se usa | 8-12 KiB de memoria WC por draw |
| A10 | `keep`/`keepAlive` (`command.hpp:122-141`), `use`, `Gpu::submit` (`gpu.cpp:148`) | comprobar antes de copiar el `shared_ptr`; conjunto de `Bo` por command buffer | ~1 % |

Ganancia esperada [H, a partir de los porcentajes medidos]: 35-45 % del coste de driver por draw (de ~125 a ~75 µs).
No alcanza el objetivo; prepara la etapa B.

**Etapa B — objetos de estado y emisión incremental (sysmem primero).**

| # | Función | Cambio |
|---|---|---|
| B1 | nuevo `PassSig` en `OpenPass` | firma del pase al abrirlo |
| B2 | nuevo `ProgramState* stateFor(PassSig)` en `CompiledProgram` | se construye llamando a las secciones actuales de `encodeDraw` (`programConfig`, `programVs`, `programFs`, `vfd`, `vpc`, `fsInputs`, `fsOutputs`, blend, MSAA) con las máscaras de `render::Options` que ya existen; se guarda el vector de palabras |
| B3 | `CommandBuffer::draw` | si `ps != open_->lastProgramState`, se copian sus palabras; el estado dinámico se compara y emite por bloques; se deja de llamar a `appendDeduped` para draws |
| B4 | `TexState` | caché por command buffer indexada por (punteros de textura, punteros de sampler) |
| B5 | `encodeDraw` | queda como constructor de objetos y como camino de pruebas (`Options`) |

Ganancia esperada [H]: el núcleo baja a ~10 % de su coste actual; quedan las capas ObjC y API C (~12 % del camino hoy).

**Etapa C — encoder con estado en la API C.** `hakios_metal_enc_set_*` y `hakios_metal_enc_draw`; el plug-in llama a
los setters desde `setVertexBuffer:`, `setFragmentTexture:`, etc. (`CA.m:8200-8420`) y deja de construir arrays en
`hakiosDrawOnce`. `hm_panel_scale` (`CA.m:8076`) se resuelve al crear la textura, no en cada `setFragmentTexture:`.
Objetivo < 5 µs por draw en el teléfono.

**Validación de A, B y C.** (1) Los 261 tests. (2) `framecount`: mismo hash del stream antes y después en la etapa A;
en B, mismo conjunto final de registros por draw (el fake GPU ya lo comprueba en cada `CP_DRAW_INDX_OFFSET`).
(3) Contador de `operator new` en el binario de tests: 0 asignaciones por draw en régimen. (4) En el teléfono,
`metal_fps`: «us of ours each» y «a buffer made to committed»; n ≥ 3 arranques por condición.

**Limitación del fake GPU a tener en cuenta [O]:** guarda todas las cargas de constantes de un submit y las compara
con el `constlen` de cada draw posterior (`fake_gpu.cpp`, `checkStageProgram`; `vs_`/`fs_` solo se reinician en `run`),
de modo que un draw con `constlen` 0 después de uno con constantes da un fallo que no es del stream. Hay que
reiniciar las cargas al cargar un programa nuevo antes de usar el fake como juez de la etapa B.

## 3. Cuello B — tiempo de GPU de la pasada principal

### 3.1 Por qué 102 tiles

[O] `gmemPlan` reparte la GMEM entre todos los attachments de color del pase y alinea cada base a 16 KiB
(`render.cpp:2218`); `gmemTiles` usa una sola columna si el ancho cabe en `kTileMaxW` y el alto que quepa
(`render.cpp:2237-2238`). Con las constantes del port (`a6xx.hpp`, bloque `HAKIOS_CHIP_A610`: `kGmemBytes` 128 KiB,
caché de color de la CCU 4 KiB → 124 KiB útiles) y **dos attachments de 4 bytes** (el pase principal de CoreAnimation
dibuja «into two screens at once», `render.hpp`, comentario de `gmemPlan`): 48 KiB para el primero → 12 288 píxeles
por tile → tiles de **768 × 16**, 102 filas. `framecount` (escena P) lo reproduce.

Qué da el algoritmo de turnip (`mesa:src/freedreno/vulkan/tu_util.cc:229-343`: prueba todos los anchos y se queda con
el menor número de bins, y a igualdad con el más cuadrado) para 750 × 1624 en el A610 (`tile_align` 32 × 16,
`mesa:src/freedreno/common/freedreno_devices.py:282-301`):

| Caso | píxeles por tile | tiles |
|---|---|---|
| port: 2 attachments, 124 KiB, bases a 16 KiB | 12 288 | 102 (768 × 16) |
| turnip: 2 attachments, 128 KiB, bloques de 4 KiB | 16 384 | 78 (128 × 128) |
| turnip: 1 attachment, 128 KiB | 32 768 | 39 (256 × 128) |

Linux da al A610 `gmem = SZ_128K + SZ_4K` [HEREDADO, `NOTES.md:815`; el catálogo de Linux no está en este equipo]: los
4 KiB de más son la caché de color de la CCU en modo GMEM (`mesa:src/freedreno/common/fd6_gmem_cache.h:118`), y dejan
128 KiB enteros para tiles.

### 3.2 Qué ejecuta el CP en cada tile

[O] Los draws de un pase GMEM van a un cuerpo que cada tile llama con `CP_INDIRECT_BUFFER` (`render.cpp:2514`), y el
paso de binning lo llama una vez más (`render.cpp:2415`). El cuerpo lleva el estado como escrituras de registro y
cargas en línea: no hay grupos `CP_SET_DRAW_STATE` (solo el «disable all» del arranque de lote). El binning hace que
el CP salte los `CP_DRAW_INDX_OFFSET` no visibles, pero **ejecuta en cada tile los registros y las cargas de todos los
draws**. Escena P: 490 035 palabras por frame, de ellas 55 620 cargas `CP_LOAD_STATE6*` (dos precargas de shader por
draw y por tile) y 11 124 paquetes de draw.

[H] Esto explica que la pasada tarde lo mismo en reposo que en movimiento: 18,2 ms / 490 000 palabras = 37 ns por
palabra si todo el tiempo fuera del CP. [HEREDADO] HackiOS midió 12,4 µs del CP para un draw de 588 palabras en el
A635 (comentario de `appendDeduped`, `render.cpp:2733-2737`): 21 ns por palabra.
La escena R (los mismos draws en sysmem) son 4 938 palabras.

Con grupos de estado un tile solo ejecuta el estado de los draws que le tocan, y `CP_SKIP_IB2_ENABLE_GLOBAL` permite
salir del cuerpo cuando se agota el stream de visibilidad (`mesa:src/freedreno/vulkan/tu_cmd_buffer.cc:3676-3690`).

### 3.3 Framebuffer fetch: barreras

[O] En un pase GMEM, cada draw que lee el blanco y viene detrás de uno que no lo lee emite
`CP_WAIT_FOR_IDLE` + `CACHE_INVALIDATE` + `CP_WAIT_FOR_IDLE` dentro del cuerpo (`render.cpp:1616-1622`), y cada tile
añade `CP_WAIT_FOR_IDLE` + `CACHE_INVALIDATE` si algún draw lee (`render.cpp:2510-2513`). Como el cuerpo se repite por
tile, la escena Q (27 transiciones) lleva **5 568 `CP_WAIT_FOR_IDLE` y 2 781 `CACHE_INVALIDATE` por frame**.
En sysmem cada draw que lee lleva 2 `CP_WAIT_FOR_IDLE`, un flush de la CCU con espera sobre una palabra y un
`CACHE_INVALIDATE` (`render.cpp:1623-1629`; escena B).
[O] 98 de las 170 variantes del shader de CoreAnimation en el teléfono leen el blanco (1.3).

Qué hacen las fuentes primarias:

- fd6 no emite barreras para el fetch coherente: pone `GRAS_SC_CNTL.SINGLE_PRIM_MODE` a `FLUSH_PER_OVERLAP` en GMEM y a
  `FLUSH_PER_OVERLAP_AND_OVERWRITE` en sysmem (`mesa:src/gallium/drivers/freedreno/a6xx/fd6_emit.cc:532-555`). El XML
  describe `FLUSH_PER_OVERLAP`: «Invalidate UCHE and wait for any pending work to finish if there was possibly an
  overlapping primitive prior to the current one» (`mesa:src/freedreno/registers/adreno/a6xx.xml:1707-1731`).
- turnip hace lo mismo (`mesa:src/freedreno/vulkan/tu_pipeline.cc:3811-3845`, `:4468-4498`) y **fuerza GMEM** en un pase
  con modo de primitiva única en sysmem: «should cause significantly increased SYSMEM bandwidth»
  (`mesa:src/freedreno/vulkan/tu_autotune.cc:1814-1820`).

[HEREDADO] El port pone `FLUSH_PER_OVERLAP` solo en los draws que leen y mantiene la barrera en la transición porque
sin ella vio artefactos («a widget's text cut by a band», `render.cpp:1606-1613`): el rasterizador no ordena la lectura
respecto de draws anteriores emitidos en `NO_FLUSH`.

[H] Alternativa que elimina las barreras: en un pase con algún draw que lea, **todos** los draws en
`FLUSH_PER_OVERLAP`, como estado del pase. Así el rasterizador conoce todas las primitivas anteriores. Hay que medirlo
y mirarlo en pantalla; si reaparecen artefactos, la barrera se limita a las transiciones cuyo rectángulo
(`render::drawArea`, `render.cpp:2288`) solapa algún draw sin leer pendiente.

### 3.4 Load y store por tile

[O] `closePass` carga un attachment tocado salvo que su load action sea DontCare, y guarda el que se escribió si su
store action no es DontCare (`render.cpp:3321-3330`); un Clear se hace en el tile sin cargar. Los tiles se limitan a
la unión de las áreas de los draws (`render.cpp:3314`). Escena P: 102 cargas y 102 guardados (attachment 0), cada uno
con su `CP_WAIT_FOR_IDLE` de tile (`render.cpp:2525`), igual que turnip
(`mesa:src/freedreno/vulkan/tu_cmd_buffer.cc:3840`).
Lo que turnip tiene y aquí falta: load y store condicionados a que el tile tenga geometría
(`mesa:src/freedreno/vulkan/tu_cmd_buffer.cc:1497-1510`, `tu6_emit_cond_for_load_stores`).
[H] Tráfico: 4,9 MB por carga y 4,9 MB por guardado a 750 × 1624. No se sabe qué load action usa CoreAnimation en ese
pase; `metal_fps=timeline` lo imprime (`CA.m`, `hm_read_render_pass`).

### 3.5 Pasadas en sysmem

[M] Una pasada de 35 draws a 752 × 1626 en sysmem tarda 31,96 ms; quedó en sysmem porque «its like had 4 draws at
most lately» (regla de `render.cpp:2914`). [O] La regla solo mira el número de draws; no mira si el pase lee el
blanco ni cuánta superficie cubre. [O] Todos los blancos de color son lineales (`rbMrtBufInfo(..., TILE6_LINEAR, ...)`,
`render.cpp:134`), salvo las texturas UBWC de solo lectura. [HEREDADO, `NOTES.md:312-316`, medido con Mesa GL en
este teléfono a 1125 × 2436] una capa a pantalla completa con blending cuesta 6 ms en un blanco lineal, 2,4 ms en uno
tiled y 1,3 ms en GMEM. Mesa usa `TILE6_3` por defecto y UBWC cuando el formato lo admite, también en el A610: solo
se excluye el A702 (`mesa:src/freedreno/vulkan/tu_image.cc:325-338`, `:703`;
`mesa:src/gallium/drivers/freedreno/a6xx/fd6_resource.cc:25-33`).

### 3.6 Overdraw, profundidad y LRZ

[O] El pase principal no tiene attachment de profundidad y `gmemPlan` rechaza los pases que lo tienen
(`render.cpp:2177`); LRZ está apagado (`render.cpp:1704-1708`). LRZ necesita un buffer de profundidad, así que no es
aplicable tal cual. Un esquema de profundidad sintética (draws opacos de delante hacia atrás con escritura de
profundidad, después los translúcidos con test) exige reordenar draws y un attachment más en GMEM, que sube el número
de tiles. [H] Ganancia baja en SpringBoard: los iconos no son opacos y CoreAnimation ya descarta capas totalmente
ocultas. No entra en la lista priorizada.

### 3.7 Calidad del shader de fragmento especializado

[O] (desensamblado con el descodificador de Mesa; los listados quedan fuera de git)

- Una variante simple son 14 instrucciones: 5 `bary.f`, 4 `cov.f32f16`, 1 `mov` desde constante, 1 `samb`, 1 `mul.f`
  repetido. Usa media precisión. No hay nada que ganar ahí.
- Las variantes con fetch y matriz de color tienen 40-90 instrucciones, con un preámbulo (`shps`/`getone`…`shpe`) que
  desempaqueta uniformes una vez por draw, un `isaml` del blanco y la mezcla en media precisión.
- La especialización sí pliega el uber shader: 128-576 palabras frente a 32 064.

Defectos observados: (1) la tabla de texturas no se compacta: 53 variantes declaran 15 slots y 16 declaran 10 para
muestrear 1-3, y el draw carga los 15 descriptores (960 bytes) por draw y por tile; (2) cada varying se interpola en
32 bits y se convierte a 16 con un `cov` aparte; (3) el blending estándar se hace en el shader con lectura del blanco,
que es decisión de CoreAnimation pero es lo que arrastra el coste de 3.3.

[O] Mientras una especialización no está lista, el draw **espera en el hilo de render** con `usleep(2000)` hasta
1 500 veces (`CA.m:7860-7871`). Las claves conocidas se precargan al crear el pipeline, de forma asíncrona y en una
cola serie (`CA.m:7720-7741`); un draw que llega antes espera.

### 3.8 Plan para la GPU

| # | Cambio | Dónde | Efecto esperado |
|---|---|---|---|
| G1 | Grupos `CP_SET_DRAW_STATE` reales: los objetos de la etapa B copiados a GPU, con máscaras `BINNING`/`GMEM`/`SYSMEM` (`mesa:src/freedreno/registers/adreno/adreno_pm4.xml:1099-1112`); el cuerpo queda en ~16 palabras por draw | `CommandBuffer::draw`, `encodeGmem` | [H] de 490 000 a ~100 000-180 000 palabras por frame en la pasada principal; un solo cuerpo vale para sysmem y GMEM |
| G2 | Tiles como turnip: bases a 4 KiB, búsqueda del menor número de bins, y dar GMEM solo a los attachments que el pase toca | `gmemPlan` (`render.cpp:2176`), `gmemTiles` (`:2228`), `closePass` | 102 → 78 tiles; → 39-42 si el segundo attachment no se toca |
| G3 | Fetch sin barreras: `FLUSH_PER_OVERLAP` como estado del pase; en sysmem, `FLUSH_PER_OVERLAP_AND_OVERWRITE` | `render.cpp:1616-1629`, `:1994` | escena Q: de 5 568 a ~110 `CP_WAIT_FOR_IDLE` por frame |
| G4 | Elegir GMEM por contenido, no por nº de draws: pase con fetch o con área grande → GMEM | `render.cpp:2905-2931` | la pasada de 32 ms en sysmem deja de existir en esa forma |
| G5 | Compactar slots de textura por variante | `compiler.cpp` (`walkTextures`, `fillKernel`) | 15 → 1-3 descriptores por draw |
| G6 | Load/store condicionados a visibilidad | `encodeGmem` (`render.cpp:2494-2523`) | menos tráfico en pases parciales |
| G7 | Blancos propios (offscreen) en `TILE6_3`, con UBWC cuando proceda | `Texture::make`, `mrtWords`, `gmemPlan` | [HEREDADO] ×2,5 en relleno con blending en sysmem |
| G8 | Especialización: carga síncrona desde la caché de disco al primer uso; compilación solo en fallo real | `CA.m:7821-7873` | quita esperas de 2 ms a 3 s del hilo de render |

G1 depende de la etapa B. G2, G3, G4 y G8 son independientes y pequeños.

## 4. Respuestas a las preguntas de la auditoría

### 4.1 Modelo de pasadas

[O] Un pase se comparte entre draws con los mismos attachments, acciones y opciones (`render.cpp:2865-2874`).
Por **pase sysmem**: arranque de lote completo (tabla estática de registros, 32 `VFD_FETCH`, `CP_SET_DRAW_STATE`
disable-all; `render.cpp:1153-1170`), 3 `CP_WAIT_FOR_IDLE` (`:1159`, `:1175`, `:1219`), `PC_CCU_FLUSH_COLOR_TS` con
`CP_WAIT_REG_MEM` y `CACHE_FLUSH_TS` con `CP_WAIT_MEM_GTE` (`:1223-1241`); un Clear añade otro WFI y otro flush con
espera (`:922-928`). Por **command buffer**: 1 submit, 1 `CP_WAIT_FOR_IDLE` final (`command.cpp:642`), 2 `GET_PARAM`
(`command.cpp:655`, `:684`) y 1 `WAIT_FENCE` en el hilo de la cola. Ninguna espera síncrona de CPU por pase ni por
draw. Por **draw**: tabla 2.2. GMEM y binning existen (3.1-3.4).

turnip no reemite el estado estático por pase (`tu_init_hw`, una vez por command buffer), solo hace WFI al cambiar la
CCU entre sysmem y GMEM (`mesa:src/freedreno/vulkan/tu_cmd_buffer.cc:751-800`), no espera a ningún flush
(`tu6_emit_flushes`, `:359-460`) y limpia la CCU una vez al final del command buffer (`:5456-5482`).

### 4.2 Memoria

- [O] Cada `MTLBuffer` y cada textura es un GEM propio: `GEM_NEW` + `GEM_INFO` + map, y unmap + `GEM_CLOSE` al morir
  (`gpu.cpp:43-74`, `:109-122`; `CA.m:2678`). Solo hay pool para slabs, sellos y streams (`command.cpp:143-175`).
  [M] 34-68 GEM nuevos cada 2 s durante swipes, hasta 35,7 MB.
- [O] `setVertexBytes:`/`setFragmentBytes:` crean un `MTLBuffer` nuevo por llamada (`CA.m:8266-8297`).
- [O] El stream se construye en un `std::vector` y se copia al BO de comandos en el commit (`command.cpp:652`); el BO
  se recicla (`command.cpp:619`).
- [O] `replaceRegion` es un `memcpy` fila a fila sin conversión (`texture.cpp`, `Texture::replace`). Las texturas
  UBWC de solo lectura ≥ 256 × 256 pasan por una copia lineal y un blit de la GPU que **cierra el pase abierto**
  (`render.cpp:3139-3150`, `freshen` → `blitInto` → `closePass`).
- [O] IOSurface: sin copia si las filas son múltiplo de 64 bytes (`texture.cpp`, `wrapSurface`); si no, copia por CPU
  a la ida y vuelta byte a byte en el hilo de la cola (`CA.m:4429-4470`, `:4575`). Los planos YCbCr se convierten por
  CPU a RGBA8 (`CA.m`, `hakiosConvertYCbCrRows`).
- [O] Todo el mapeo es write-combined (`CA.m`, `cpuCacheMode`); leer de ahí es lento, y por eso las constantes ligadas
  a un offset que no es múltiplo de 16 se copian con `CP_MEMCPY` + `CP_WAIT_MEM_WRITES` + `CP_WAIT_FOR_ME` por rango
  (`render.cpp:1769-1772`).

### 4.3 Sincronización

- [O] Único `usleep` en ruta caliente: `usleep(2000)` × ≤ 1 500 en `hakiosProgramFor:` (`CA.m:7870`). Los demás son
  de diagnóstico: `usleep(ca_prof_us)` (`CA.m:2078`), `sleep(5)` (`:2315`), `usleep(200)` (`:6272`).
- [O] `presentDrawable:` presenta al completar, no al planificar (`CA.m:6745`); backboardd no lo usa [M].
- [O] `hakios_metal_cb_free` espera a que el buffer termine si está en vuelo (`c_api.cpp:803-813`), y lo llama
  `-dealloc` (`CA.m:5369`).
- [O] Un hilo por cola espera cada fence y ejecuta los handlers en orden (`command.cpp:669-704`); una vuelta de copia
  de superficie o un handler lento retrasa todas las finalizaciones siguientes.
- [O] Grabación diferida (`metal_defer=1`): un hilo por cola, un `std::function` y un `make_shared` por draw
  (`c_api.cpp:1538-1549`). Está apagada por defecto en el port; [HEREDADO] «swipes gain (36-38 fps against 26-34) but an
  app opening stays black until touched» (`CA.m:5152`).
- [M] `-commit` cuesta 2,3-3,2 ms en el hilo de render. [H] Reparto entre `closePass`, la copia del stream y el ioctl
  de submit sin medir.

### 4.4 Shaders

[O] La creación de pipeline compila en el hilo que llama, también en las variantes con completion handler
(`CA.m:3253`, `:3413-3440`), bajo un mutex global (`compiler.cpp`, `gCompilerLock`). Hay caché en disco por stage
con clave que incluye bitcode, constantes y buffer conocido. No hay precompilación del `default.metallib`; las
especializaciones por contenido del buffer de configuración se recuerdan en archivos `.keys` por pipeline
(`CA.m:7708-7741`). Espera en caliente: 3.7.

### 4.5 Lo no implementado que empuja a rutas lentas

Blancos lineales (3.5); memoryless tratado como memoria normal (`CA.m:3704-3708`), así que el segundo attachment de
CoreAnimation ocupa GMEM y memoria; superficies con filas no alineadas y YCbCr por copia de CPU (4.2); `luma_boost`
se omite (`CA.m`, `hm_luma_boost_left_out`); GMEM rechaza pases con profundidad, MSAA, blancos UBWC o formatos que
no sean de 4 u 8 bytes (`render.cpp:2177-2196`).

### 4.6 Comparación con turnip/fd6 para un frame de compositor

N quads con textura y blending sobre un blanco:

| | turnip / fd6 | hakios-metal (port) |
|---|---|---|
| estado estático de la GPU | una vez por command buffer | una vez por pase (~300 registros) |
| `CP_WAIT_FOR_IDLE` por pase sysmem | 0 (1 si cambia el modo de la CCU) | 3, más 1 por command buffer |
| esperas a flush dentro del stream | 0 | 2 por pase, 1 más por Clear |
| palabras por draw adicional | ~20 [HEREDADO, captura de turnip en `NOTES.md:570`] | ~43 en sysmem [O, escenas A y G] |
| precarga de shader | al cambiar de programa y solo si el draw es visible | 2 por draw, y por tile |
| draw con framebuffer fetch | modo de primitiva única, sin barrera | 2 WFI + flush con espera (sysmem); WFI + invalidate + WFI por transición y por tile (GMEM) |
| pase principal en GMEM, A610, 2 attachments | 78 tiles; estado solo de draws visibles | 102 tiles; 490 000 palabras |
| CPU por draw | comparar bits de sucio y emitir punteros | validar, generar ~300-600 palabras y filtrarlas; 111-139 µs [M] |

### 4.7 Diseño «un frame = un submit»

CoreAnimation ya entrega un command buffer por frame [M]. Lo que falta es que ese buffer sea barato: un arranque de
estado por buffer; cada pase con su prólogo (MRT, scissor de ventana, modo) y sin cola con esperas; draws como grupos
+ `CP_DRAW_INDX_OFFSET` en un cuerpo único; modo sysmem/GMEM decidido al cerrar el pase con el cuerpo ya grabado;
flush de CCU y de caché solo cuando un pase posterior lee lo escrito (`tu_flush_for_access`,
`mesa:src/freedreno/vulkan/tu_cmd_buffer.cc:5788`) y una vez al final; pool de BOs por tamaño para buffers y texturas
con reutilización al completar.

## 5. Lista priorizada

Ordenada por ganancia esperada. «ms» son por frame de ~130 draws.

| # | Cambio | Ganancia esperada | Riesgo | Sección |
|---|---|---|---|---|
| 1 | Etapa A (A1-A10): sin trabajo repetido ni asignaciones, grabación única | [H] −6 a −9 ms de CPU (de ~17 a ~9-10 ms de draws) | bajo: stream idéntico | 2.6 |
| 2 | Etapa B: `ProgramState`, `TexState`, estado dinámico por bits de sucio | [H] −7 a −8 ms más (draws a ~1-2 ms) | medio | 2.6 |
| 3 | G2 + G3 + G4: tiles como turnip, fetch sin barreras, GMEM por contenido | [H] varios ms de GPU en la pasada principal; quita la pasada de 32 ms en sysmem | medio: G3 hay que verlo en pantalla | 3.8 |
| 4 | G1: grupos de estado reales y cuerpo único | [H] pasada principal de 18-24 ms a < 8 ms | medio-alto | 3.8 |
| 5 | Etapa C: encoder con estado | [H] draws a < 5 µs (< 0,7 ms por frame) | medio | 2.6 |
| 6 | G8: sin `usleep` en el hilo de render | quita tirones de 2 ms a 3 s | bajo | 3.7 |
| 7 | Pool de BOs para buffers y texturas; `setVertexBytes` en el stream | [H] quita 17-34 `GEM_NEW` por segundo | bajo | 4.2 |
| 8 | Pase sin cola con esperas; estado estático por buffer | [H] por pase: 3 WFI y 2 esperas menos (hasta 11 pases por buffer [M]) | medio | 4.1 |
| 9 | G5, G6, G7 | menos carga por draw; relleno más barato en sysmem | G7 medio | 3.8 |
| 10 | `-commit`: medir y reducir | hasta 2-3 ms por frame [M] | — | 4.3 |

## 6. Instrumentación

Ya existe `metal_fps` (`CA.m:5924-6205`). Añadir por command buffer, sin coste apreciable: palabras del stream
(principal y cuerpos × llamadas), nº de `CP_WAIT_FOR_IDLE` y de eventos emitidos, draws grabados doble, cargas de
shader emitidas, aciertos y fallos de `ProgramState`/`TexState`, bytes escritos en tablas, attachments ligados y
tocados por pase, load/store por pase, ms esperando una especialización, ms de `-commit` desglosados (cerrar pase,
copiar stream, ioctl). En host, `framecount` da las mismas cifras sobre el fake GPU y sirve de prueba de regresión
(palabras por draw, asignaciones por draw).

## 7. No verificado

- Qué clúster físico son los procesadores lógicos 0-3 donde corren los draws [M]. Si es el de los núcleos lentos,
  todas las cifras de µs por draw mejoran además moviendo el hilo; es materia del plan 07.
- Si la pasada principal está limitada por el CP (3.2) o por píxeles y barreras: lo separan los A/B en curso
  (`metal_gmem_draws=0`, `metal_gmem_off=16`) y un contador de palabras por pase.
- Si el segundo attachment del pase principal se escribe o se lee (`metal_fps=passes` imprime `attached`/`touched`).
- El load action del pase principal y cuántos draws por frame leen el blanco en SpringBoard.
- El tamaño real de la GMEM del A610 en este kernel (128 o 132 KiB).
- Las cifras [HEREDADO] de 2,4 / 6 / 1,3 ms por capa y de 21 ns por palabra.
- El reparto de los 2,3-3,2 ms de `-commit`.
