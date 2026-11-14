# 14 — Driver Metal: pasada GMEM, estado por tile y geometría de tiles (2026-11-14)

Informe fechado. Alcance: la pasada GMEM del núcleo `hakios-metal` (cuello B de [10](10-auditoria-rendimiento-hakios-metal.md)):
qué ejecuta el procesador de comandos (CP) en cada tile, cómo se reparten los tiles, el framebuffer fetch y la
elección GMEM/sysmem. El coste de CPU por draw (cuello A) lo trabaja otro árbol (`wt-cpu`, rama `cpu-draw`).

Convención de evidencia: **[O]** observación propia (código con `archivo:línea`, medida de host reproducible o
desensamblado); **[S]** fuente primaria citada; **[H]** hipótesis sin medir; **[M]** medida en el teléfono tomada por
el coordinador.

## 0. Dónde está cada cosa

| Cosa | Dónde |
|---|---|
| Árbol de trabajo | `~/sapphire-angel/research/metal/rebuild/wt-gpu`, rama `gpu-pass`, sobre `opcional-puerto` (`620950c`: upstream HackiOS `63fc2b4` + `patches/a610` + `patches/opcional`) |
| Build de host por objetos | `rebuild/gpu-tools/host.mk` (`make -f host.mk -j4 SRC=… OUT=… [DEFS=-DHAKIOS_CHIP_A610] tests framecount`) |
| `framecount` | `rebuild/gpu-tools/framecount.cpp` (el de la auditoría 10 es `framecount-base.cpp`) |
| Microcódigo del CP del teléfono | `rebuild/gpu-tools/sqe/a630_sqe.phone.fw` (leído de `/chosen/gpu-sqe-firmware` del árbol de dispositivos, 32 504 bytes, sha256 `413dbae6…0129`, versión `016ee206`) |
| Su desensamblado | `rebuild/gpu-tools/sqe/a630_sqe.phone.dis` (9 020 líneas; `qrisc-disasm` de Mesa `767fbf7c`; reensamblado da los mismos 32 504 bytes) y `handlers.txt` |
| Referencia | Mesa `767fbf7c` en `~/sapphire-angel/research/metal/auditoria-userland/mesa` (las citas `mesa:` son de ese commit) |
| Bundles | `rebuild/out/gpu-G1`, `gpu-G2`… |

## 1. Estado de la suite en la base (`620950c`)

[O] Con Apple clang 21 el `make test` del árbol no compila: `-Werror` rechaza `chipKnown`, sin uso fuera del teléfono
(`src/c_api.cpp:218`). `host.mk` compila con `-Wno-unused-function` y nada más cambia.

| Constantes | Tests | Comprobaciones fallidas |
|---|---|---|
| A635 (las de `make test`) | 261 | 0 |
| A610 (`-DHAKIOS_CHIP_A610`, las del teléfono) | 261 | 42, en 19 tests |

Los 19 tests que fallan con las constantes del A610 esperan valores del A635 escritos a mano (palabras de arranque,
tamaño de la caché de instrucciones, memoria privada, reparto de GMEM). Lista: `rebuild/gpu-tools/base-a610.fails`.
Cinco son de GMEM (`the_gmem_plan_fits…`, `a_pass_of_two_attachments_in_gmem…`, `a_gmem_pass_is_tiled_over_its_render_area`,
`a_fetch_in_a_corner…`, `gmem_for_a_pass_of_enough_draws…`).

## 2. Medida de partida en host (`framecount`, constantes del A610, n = 3, recuentos idénticos)

| Escena | Tiles | Palabras que lee el CP |
|---|---|---|
| P: 108 draws, 2 attachments, GMEM con binning | 102 de 768 × 16 | 490 138 |
| Q: P con cada 4.º draw de framebuffer fetch | 102 | 779 668 |
| R: los 108 draws en sysmem | — | 4 939 |

## 3. Lo que hace el microcódigo del teléfono (desensamblado)

Las líneas son de `a630_sqe.phone.dis`. `$14` es el registro de banderas globales del SQE, `$12` el nivel de IB,
`$15` el siguiente draw visible que da el descodificador del stream de visibilidad y `$16` el draw en curso.

1. **`CP_SET_DRAW_STATE`** (L3622): guarda cada grupo en la RAM de draw state. Con `$14.b30` (lo pone `CP_SET_MODE 1`,
   L4261) ejecuta en el acto los grupos pendientes; sin él los ejecuta el siguiente draw que se dibuja (L3896-3905).
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
   microcódigo el primer tile lo borra y el retorno anticipado no llega a armarse en ninguno de los dos.
7. **`CP_INDIRECT_BUFFER` admite una cuarta palabra** (L493-494 y L559-640): el número de draws del IB, con el que el
   SQE salta un IB2 entero sin draws visibles. Mesa no la usa; aquí tampoco.

(El resto del informe se completa al cerrar cada hito.)
