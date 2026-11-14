# 14 — Driver Metal: pasada GMEM, estado por tile y geometría de tiles (2026-11-14)

Informe fechado. Alcance: la pasada GMEM del núcleo `hakios-metal` (cuello B de [10](10-auditoria-rendimiento-hakios-metal.md)):
qué ejecuta el procesador de comandos (CP) en cada tile, cómo se reparten los tiles, el framebuffer fetch y la
elección GMEM/sysmem. El coste de CPU por draw (cuello A) lo trabaja otro árbol (`wt-cpu`, rama `cpu-draw`).

Convención de evidencia: **[O]** observación propia (código con `archivo:línea`, medida de host reproducible o
desensamblado); **[S]** fuente primaria citada; **[H]** hipótesis sin medir; **[M]** medida en el teléfono tomada por
el coordinador. Nada de este informe está medido en el teléfono.

## 0. Dónde está cada cosa

| Cosa | Dónde |
|---|---|
| Árbol de trabajo | `~/sapphire-angel/research/metal/rebuild/wt-gpu`, rama `gpu-pass`, sobre `opcional-puerto` (`620950c`: upstream HackiOS `63fc2b4` + `patches/a610` + `patches/opcional`) |
| Herramientas de host | `rebuild/gpu-tools/`: `host.mk` (build por objetos), `t.sh` (suite con las constantes de los dos chips), `verify.sh` (suite de un commit o del índice), `stage.py`, `bundle.sh NOMBRE [REV]`, `framecount.cpp` (el de la auditoría 10 es `framecount-base.cpp`) |
| Microcódigo del CP del teléfono | `rebuild/gpu-tools/sqe/a630_sqe.phone.fw` (leído de `/chosen/gpu-sqe-firmware` del árbol de dispositivos, 32 504 bytes, sha256 `413dbae6…0129`, versión `016ee206`) |
| Su desensamblado | `rebuild/gpu-tools/sqe/a630_sqe.phone.dis` (9 020 líneas; `qrisc-disasm` de Mesa `767fbf7c`; reensamblado da los mismos 32 504 bytes), `handlers.txt`, `build/` |
| Referencia | Mesa `767fbf7c` en `~/sapphire-angel/research/metal/auditoria-userland/mesa` (las citas `mesa:` son de ese commit) |
| Bundles | `rebuild/out/gpu-G1` (commit `f647bb5`, sha256 `698bcc0c…0ced`), `rebuild/out/gpu-G2` (`27eabea`, sha256 `46f472de…14d9`); cada carpeta lleva `COMMIT` |

Los bundles se compilan con la clave de caché de stages de `propio-args` (`24ed84207640dc54c2b865f7`): `bundle.sh`
comprueba que `compiler.cpp`, `metallib.cpp`, `link.cpp`, `kernel.hpp`, `compiler.hpp`, `compute.hpp` y la declaración
de `Stage` son byte a byte los de `620950c` y solo entonces fija la clave. Así un bundle `gpu-*` encuentra los stages
que dejó `propio-args` y no recompila los ~200 de CoreAnimation en su primer uso.

## 1. Estado de la suite

[O] Con Apple clang 21 el `make test` del árbol no compila en la base: `-Werror` rechaza `chipKnown`, sin uso fuera
del teléfono (`src/c_api.cpp:218`). `host.mk` compila con `-Wno-unused-function` y nada más cambia.

| Árbol | Constantes A635 (las de `make test`) | Constantes A610 (`-DHAKIOS_CHIP_A610`, las del teléfono) |
|---|---|---|
| Base `620950c` | 261 tests, 0 comprobaciones fallidas | 261 tests, 42 fallidas en 19 tests |
| `gpu-pass` `27eabea` | 269 tests, 0 fallidas | 269 tests, 29 fallidas en 14 tests |

Los 19 tests que fallan en la base con las constantes del A610 esperan valores del A635 escritos a mano (lista:
`rebuild/gpu-tools/base-a610.fails`). Cinco eran de GMEM y pasan ahora con los dos juegos de constantes, por dos
arreglos de fondo y no por relajar nada: el fake comparaba la base del bin de un framebuffer fetch como si GMEM
estuviera en 0 (en el A610 está en `0x100000`), y las expectativas de reparto estaban escritas para el A635. Los 14
que quedan no son de GMEM (palabras de arranque, caché de instrucciones, memoria privada, `rbCcuCntlSysmem`, sampler)
y siguen como estaban. Cada commit de la rama pasa la suite por separado (`verify.sh REV`).

## 2. Lo que hace el microcódigo del teléfono (desensamblado)

Las líneas son de `a630_sqe.phone.dis`. `$14` es el registro de banderas globales del SQE, `$12` el nivel de IB,
`$15` el siguiente draw visible que da el descodificador del stream de visibilidad y `$16` el draw en curso.

1. **`CP_SET_DRAW_STATE`** (L3622): guarda cada grupo en la RAM de draw state. Con `$14.b30` (lo pone `CP_SET_MODE 1`,
   L4261) ejecuta en el acto los grupos pendientes; sin él los ejecuta el siguiente draw que se dibuja (L3896-3905).
   Con `b30` puesto y `b29` no, o dentro de un grupo, salta al manejador de error y el CP se para (L3628-3630, L270).
2. **Ejecución de grupos** (`fxn3123`, L3634-3717): del id más bajo al más alto; un grupo cuya máscara de modo no
   incluye el modo en curso queda pendiente; misma dirección, misma longitud y sin `DIRTY` → no se ejecuta (la
   comparación es con lo último **ejecutado** de ese grupo, `@SDS_BASE`/`@SDS_DWORDS`); misma dirección y más
   longitud → solo la cola; lo demás, entero. Los paquetes del grupo pasan por la misma tabla de paquetes, a nivel 3.
3. **Modo en curso** (`CP_SET_MARKER`, L815-955): `RM6_BIN_VISIBILITY` → binning; `RM6_DIRECT_RENDER` → sysmem; los
   demás marcadores → GMEM.
4. **Visibilidad** (L3791-3880, `fxn3500`/`fxn3512`/`fxn3532`, L4067-4157): con `CP_SET_VISIBILITY_OVERRIDE 1`
   (`b11|b21`, L1068) todo draw se dibuja. En un tile tras un paso de binning, un draw `USE_VISIBILITY` avanza `$16`
   y se dibuja solo si `$15 == $16`; cuando el stream no tiene más draws visibles se pone `b6` (L4137).
5. **Retorno anticipado** (`fxn3571`, L4158-4192): `b7 = b6 ∧ LOCAL (b8) ∧ GLOBAL (b9)`. Al ponerse `b7` dentro de un
   IB2 se descarta el resto del IB2 y se vuelve al IB1; un `CP_INDIRECT_BUFFER` con `b7` puesto se salta (L483-484).
6. **`RM6_BIN_RENDER_START` y `CP_SET_BIN_DATA5(_OFFSET)` borran `LOCAL`** (`fxn848`, L1029-1040: ponen a cero los
   contadores de draws y borran `b4-b8` y `b11-b14`; L858, L986). `LOCAL` vale para un tile: hay que ponerlo después
   de `CP_SET_BIN_DATA5` en cada tile. turnip lo pone una vez tras el binning (`mesa:src/freedreno/vulkan/tu_cmd_buffer.cc:3687-3691`)
   y fd6 una vez al empezar el lote (`mesa:src/gallium/drivers/freedreno/a6xx/fd6_gmem.cc:1323-1325`): con este
   microcódigo el primer tile lo borra y el retorno anticipado no llega a armarse en ninguno de los dos, lo que
   cuadra con el comentario de turnip («an effect we struggle to even measure», `tu_cmd_buffer.cc:3681-3686`).
7. **`CP_INDIRECT_BUFFER` admite una cuarta palabra** (L493-494 y L559-640): el número de draws del IB, con el que el
   SQE salta un IB2 entero sin draws visibles. Mesa no la usa; aquí tampoco.

## 3. Diseño

### 3.1 Estado por tile: grupos de draw state (G1)

[S] La forma es la de los dos drivers de Mesa: «state updates can be batched up into "draw states" … At draw time, if
the draw call is going to actually execute (some primitive is visible in the current tile), the SQE goes through the
GROUP_IDs and for any with an update since the last time they were executed, it executes the corresponding fragment»,
con su condición: «the generated draw state has to always update all of the state you have chosen to pack into that
GROUP_ID, since any of your previous state changes in a previous draw state command may have been skipped»
(`mesa:docs/drivers/freedreno.rst:158-176`; emisión en `tu6_draw_common`, `tu_cmd_buffer.cc:8870-8919`, y
`fd6_state_emit`, `fd6_emit.h:108-141`).

[O] Los draws de un pase GMEM ya se grababan una vez y cada tile los llamaba con `CP_INDIRECT_BUFFER`; lo que se
repetía era su **ejecución**: el cuerpo era un stream plano (registros deduplicados, cargas y el paquete de draw), y
el stream de visibilidad solo salta el paquete de draw. `render::drawStates` (`src/gmem.cpp`) convierte ese stream al
cerrar el pase, sin tocar cómo se codifica un draw: lo recorre draw a draw llevando lo que vale cada registro escrito,
y por cada grupo que un draw toca escribe un fragmento con **todos** los registros del grupo tal como están en ese
draw, seguidos de las cargas del draw que son de ese grupo. El reparto de registros entre grupos solo decide cuánto se
reejecuta cuando algo cambia; cualquier reparto es correcto porque cada fragmento es completo.

| Grupo (id) | Contenido | Notas |
|---|---|---|
| pass (0) | `RB_MRT[i]` de buffer, profundidad, MSAA, `RB_RENDER_CNTL`, LRZ | |
| program (1) | `HLSQ_INVALIDATE_CMD` primero; registros de las dos etapas, del enlace y de entradas/salidas del FS; las dos precargas `ST6_SHADER` | como `tu6_emit_program_config` y `setup_config_stateobj` |
| vertex (2) | `VFD_*`, índice de reinicio | |
| loads (3) | constantes, tablas de UBO, texturas y samplers con sus registros, tabla de IBO | siempre `DIRTY` y enviado otra vez con cada `program`: «CP_LOAD_STATE packets that are invalidated by the PROGRAM_CONFIG draw state» (`tu_cmd_buffer.cc:1275-1313`) |
| raster (4) | cull, modos de polígono, `GRAS_SC_CNTL` | |
| viewport (5) | viewport, guardband, Z clamp, los dos scissors | 21 palabras aparte de las 28 de raster |
| blend (6) | blend, profundidad, stencil | |

Además: las copias de constantes ligadas fuera de múltiplo de 16 (`CP_MEMCPY` + dos esperas antes de cada carga, en
cada tile) se hacen una vez antes del paso de binning (`DrawStates::prologue`); `encodeGmem` suelta todos los grupos
tras el paso de binning y tras los draws de cada tile, como fd6 (`fd6_gmem.cc:1133-1135`, `:2194-2203`); y escribe
`CP_SKIP_IB2_ENABLE_LOCAL 1` en cada tile **después** de su `CP_SET_BIN_DATA5` (§2.6), con lo que el tile deja el
cuerpo en el primer draw posterior al último visible. Un stream con algo que `drawStates` no sabe mover, o un pase
sin binning, se dibuja del stream plano como antes.

### 3.2 Rejilla de bins donde binnea el VSC (G1)

[O] Un pase cuyos draws tocan parte de la ventana se tileaba desde la esquina de esa parte, y a su paso de binning
se le decía una rejilla de ese tamaño. El VSC no tiene registro de origen: binnea por la posición en la ventana. Un
tile en (288, 992) recibía la visibilidad del bin (0, 0). [S] Los dos drivers de Mesa ponen la rejilla sobre el
framebuffer entero en esta familia (`mesa:src/gallium/drivers/freedreno/freedreno_gmem.c:552-559`;
`tu_cmd_buffer.cc:1662-1667`). `gmemTiles` toma ahora los bins de la rejilla de la ventana que toca el área, y el
paso de binning binnea la rejilla entera (`GmemPlan::gridCols/gridRows`).

### 3.3 Geometría de tiles (G2)

[O] Por qué salían 102 tiles de 768 × 16: dos attachments de 4 bytes se repartían los 128 KiB bajo la caché de color,
cada parte recortada a múltiplo de 16 KiB, y los bins iban en una sola columna del ancho de la ventana:
65 536 / (768 × 4) = 21 filas, 16 al alinear. No había `cpp` mal contado. El kernel programa `0x21000` de GMEM y el
driver ya usa `0x20000` para bins y deja los 4 KiB finales a la caché de color de la CCU, como turnip
(`mesa:src/freedreno/common/fd6_gmem_cache.h:113-121`).

`gmemPlan` reparte y tilea ahora como turnip: partes en bloques de 4 KiB con la fórmula de
`tu_render_pass_gmem_config` (`mesa:src/freedreno/vulkan/tu_pass.cc:848-877`) y búsqueda de
`tu_tiling_config_update_tile_layout` (`mesa:src/freedreno/vulkan/tu_util.cc:286-343`: todos los anchos, el menor
número de bins y, a igualdad, el más cuadrado). Y al cerrar el pase da bins solo a los attachments que sus draws
tocan (`gmemTouched`): el que ningún FS nombra como salida, ninguno lee y ningún tile limpia se queda sin bin, y su
GMEM pasa al anterior como bins más altos del mismo ancho (el ancho no puede cambiar: el descriptor de un fetch lo
lleva como pitch). El `RB_MRT_BASE_GMEM` grabado del attachment sin tocar se reescribe a 0, donde turnip deja el
`RB_MRT` de un attachment que el subpase no usa. Una rejilla cuyos pipes tendrían más de 32 bins no se binnea
(`gmemPipes`; `use_hw_binning` de fd6, `is_hw_binning_possible` de turnip, `tu_util.cc:345-354`).

| 750 × 1624, attachments de 4 bytes | Antes | Ahora |
|---|---|---|
| 1 | 51 tiles de 768 × 32 | 39 de 256 × 128 |
| 2, los dos tocados | 102 de 768 × 16 | 78 de 128 × 128 |
| 2, uno tocado | 102 de 768 × 16 | 42 de 128 × 240 |
| 3 | sin bin: a sysmem | 126 de 128 × 80 |

Los pipes siguen la regla de fd (`freedreno_gmem.c:321-326`): 78 bins son 13 pipes de 6 × 1, 42 son 14 de 3 × 1.

## 4. Antes y después en host

`framecount` con las constantes del A610, n = 3 por condición, recuentos idénticos en las tres. «Palabras» en la
base es el recuento estático (el CP lee el cuerpo entero en cada tile, así que es lo que ejecuta); en los demás es lo
que el CP del fake trae al ejecutar el stream como el microcódigo (`FakeGpu::Stats::cpWords`).

| Escena P (108 draws, 2 attachments) | Tiles | Palabras | Registros escritos | `CP_LOAD_STATE6` | `CP_WAIT_FOR_IDLE` |
|---|---|---|---|---|---|
| Base `620950c` | 102 | 490 138 | 93 031 | 55 620 | 110 |
| G1 (`metal_gmem_off=256` en G2) | 102 | 131 522 | 27 528 | 3 377 | 110 |
| G2, bin para los dos attachments (`=512`) | 78 | 106 353 | 14 212 | 1 598 | 86 |
| G2 | 42 | 65 178 | 10 780 | 1 265 | 50 |
| G2 con el cuerpo plano (`=64`) | 42 | 204 940 | 38 911 | 23 220 | 50 |
| G2 sin retorno anticipado (`=128`) | 42 | 76 648 | 10 780 | 1 265 | 50 |
| R: los mismos draws en sysmem | — | 4 939 | 975 | 540 | 4 |

De las 65 178 palabras de G2, 20 789 son estado ejecutado en 842 grupos; el resto es sobre todo el paseo por los
draws que el tile salta (3 165 draws saltados a 11 palabras: dos grupos y el paquete de draw). El microcódigo
despacha un `CP_SET_DRAW_STATE` con una instrucción y un draw saltado con una veintena; lo caro de las 490 138 eran
los registros y las cargas, que bajan a la novena y a la cuadragésima parte.

La meta de 30 000 palabras en P no se alcanza con binning por hardware: el CP tiene que leer el paquete de cada draw
anterior al último visible del tile para saltarlo. §8 dice qué la alcanzaría.

(Las secciones de fetch, elección GMEM/sysmem, cambios por función, riesgos a mirar en el teléfono y lo que falta se
completan al cerrar G3 y G4.)
