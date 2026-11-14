# 14 — Driver Metal: pasada GMEM, estado por tile y geometría de tiles (2026-11-14)

Informe fechado. Alcance: la pasada GMEM del núcleo `hakios-metal` (cuello B de [10](10-auditoria-rendimiento-hakios-metal.md)):
qué ejecuta el procesador de comandos (CP) en cada tile, cómo se reparten los tiles, el framebuffer fetch y la
elección GMEM/sysmem. El coste de CPU por draw (cuello A) lo trabaja otro árbol (`wt-cpu`, rama `cpu-draw`).

Convención de evidencia: **[O]** observación propia (código con `archivo:línea`, medida de host reproducible o
desensamblado); **[S]** fuente primaria citada; **[H]** hipótesis sin medir; **[M]** medida en el teléfono tomada por
el coordinador. Lo medido en el teléfono es de una sola tanda (n = 1 por bundle): ver «Medido en el teléfono».

## Lo primero: cómo se instala un bundle, y qué pasó con `gpu-G1`…`gpu-G3b`

Las capturas en las que `gpu-G1`, `gpu-G2`, `gpu-G3`, `gpu-G3b`, `cpu-A-wip` y el binario heredado pintan mal el blur
de la Biblioteca de Apps (`medicion/shots/hoja-blur.png`) no son del driver: en esos ensayos backboardd no tenía el
driver cargado y lo que se veía era CoreAnimation componiendo por software. [M] Instalados por renombrado, los bundles
de esta rama cargan (backboardd es cliente de `SapphireGPU`) y pintan bien la Biblioteca de Apps (coordinador, 03 M8).

**La causa.** Copiar el binario nuevo **encima** del instalado (`cp … $B/HakiosMetal`) conserva el fichero y su vnode.
El kernel guarda en el vnode la firma de código del primer binario que se cargó desde él y, mientras algún proceso lo
tenga mapeado, contesta al `fcntl(F_ADDFILESIGS_RETURN)` de `dyld` con la extensión que cubre **esa** firma. `dyld`
rechaza todo binario cuya firma empiece más allá (`code signature does not cover entire file up to signature`), Metal
no registra ningún dispositivo y CoreAnimation va por software: materiales planos (dock y widgets opacos, el fondo de
la Biblioteca oscuro y con rayas), ~10 fps, backboardd en 2,5-6 núcleos y ninguna línea `fps:`. En cada arranque
solo cargan el primer binario cargado y los que no son mayores que él.

| Evidencia | Qué dice |
|---|---|
| [S] El kernel del teléfono, `xnu-8796.141.3` (`~/sapphire-angel/research/metal/hilos/xnu-0342`) | `bsd/kern/kern_descrip.c:3890-3894`: «First check if we have something loaded a this offset» → `ubc_cs_blob_get(vp, …, fs.fs_file_start)`; si ya hay una firma no se lee la nueva (`:3909`). `:3992-4002`: lo que se devuelve a `dyld` es `blob->csb_end_offset` de la que **ya había**. `bsd/kern/ubc_subr.c:4019`: ese valor es el `codeLimit` de la firma redondeado a su página de hash (4 KiB aquí): para `propio-args`, 8 495 104 |
| [O] Reproducción en la Mac (XNU + dyld, la misma lógica), `rebuild/gpu-tools/cs-test/run.sh`, n = 3 por orden | Bundle pequeño cargado y uno mayor copiado encima con `cp` mientras un proceso mapea el primero: `dlopen` falla 3 de 3 con `code signature does not cover entire file up to signature … (signed 0x2000, expected 0x11090)`. Copiado encima el pequeño otra vez: carga. El mayor puesto con `cp` a un fichero nuevo + `mv`: carga 3 de 3. Orden inverso (grande primero, pequeño encima): carga 3 de 3 |
| [O] Dónde empieza la firma (`otool -l`, `LC_CODE_SIGNATURE dataoff`) | `propio` 8 493 120 · `propio-args` 8 493 280 · `gpu-G1` 8 517 424 · `gpu-G2` 8 518 032 · `gpu-G3` y `gpu-G3b` 8 518 192 · `gpu-G4` 8 535 216 · `cpu-A-wip` 8 558 048 · heredado (8 630 976 bytes de fichero) más allá de todos |
| [M] Los arranques del día | 0334: primero el heredado (el mayor); después `propio` y `propio-args`, menores, cargan (03 M5). 0338 a 1260: primero `propio-args`; el heredado, mayor, sin líneas `fps:` y backboardd al 588 % (03 M6). 0338 a 820 y 0342: primero `propio-args`; todos los mayores, mal; `propio-args` otra vez, bien |
| [O] `ioreg -c SapphireGPU -r -l` (solo lectura), leído mientras el coordinador probaba `cpu-A-wip` copiado encima | backboardd de 29 y de 46 s de vida al 250-285 % de CPU y **ningún cliente** en `SapphireGPU`. 17 s después, con `propio-args` reinstalado: backboardd nuevo de 15 s, 71 % de CPU y `IOUserClientCreator = "pid 1372, backboardd"` |
| [O] Capturas píxel a píxel (decodificador `rebuild/gpu-tools/img/pngio.py`) | El home con `gpu-G3` copiado encima (`g3-0.png`) y con el heredado a 1260 (`fin-0.png`) son idénticos salvo el reloj; frente a `propio1-0.png` difieren solo donde hay materiales con blur |
| [M] `medicion/ab/ab-h820-G3-1.{cpu,fb,txt}` (copiado encima) | backboardd 439,8 % de un núcleo, 51-59 flips cada 5 s con 6 o más refrescos de retraso, consola de 0 bytes |

**Para probar un bundle:** instalar por renombrado (`cp` a un temporal en la misma carpeta y `mv -f` sobre
`HakiosMetal`: `medicion/bundle.sh` ya lo hace; `rebuild/gpu-tools/instalar-por-renombrado.sh` es lo mismo) y, antes
de mirar una captura o una medida, comprobar que el driver está dentro: `rebuild/gpu-tools/driver-en-uso.sh` (solo
lectura) debe nombrar a backboardd como cliente de `SapphireGPU`, y con `metal_fps=1` deben llegar líneas `fps:`.

Las medidas tomadas con un binario copiado encima de otro menor son de la ruta por software: los `ab-v1260-angel-*`
de 03 M6, `ab-h820-G3-1` y `ab-k342-*` de `cpu-A-wip`/`gpu-G3b`.

## Medido en el teléfono

[M] Ensayos del coordinador, instalación por renombrado, kernel 0342 a 820 MHz, `homeswipe.sh 8`, **n = 1 por
bundle** (`medicion/ab/ab-real-{propio-args,gpu-G3b,gpu-G4}.txt`; las cifras de abajo salen de sus líneas `fps:` y de
las cuatro pasadas más lentas de cada periodo; orientativo hasta repetir con n ≥ 3):

| | `propio-args` (base) | `gpu-G3b` | `gpu-G4` |
|---|---|---|---|
| Pasada principal (≥ 90 draws, 750 × 1624): mín-mediana-máx | 102 tiles: 17,1-18,4-21,2 ms (31) | 78 tiles: 12,3-13,3-14,0 ms (14) | 78 tiles: 11,6-13,6-16,0 ms (44) |
| Pasadas de 28-55 draws a 750 × 1624 entre las más lentas | sysmem 18,4-21,4-40,0 ms (9) | sysmem 17,4-19,8-24,2 ms (30) | ninguna |
| Pasadas de 28-55 draws a 752 × 1626 | sysmem 32,1-35,9 ms (2) | sysmem 35,5-35,8 ms (2) | 78 tiles: 16,2-17,0 ms (2) |
| Tiempo de GPU por command buffer | 22,7 ms | 16,8 ms | 16,5 ms |
| Commit → fin, media | 23,0 ms | 17,1 ms | 16,8 ms |
| El peor buffer de cada periodo (commit → fin): mín-mediana-máx | 28,5-34,1-48,1 ms | 25,4-29,3-51,7 ms | 19,6-24,4-30,2 ms |
| Pasadas en tiles por buffer; tiles por buffer | 1,04; 105,7 | 0,99; 72,6 | 1,69; 96,9 |

Lecturas: la pasada principal toca los dos attachments en el teléfono (78 tiles de 128 × 128, no 42) y baja de 18,4 a
13,3 ms; el tiempo de GPU por buffer baja un 26 %. `gpu-G4` no cambia la media, pero manda a tiles las pasadas de
28-55 draws que en sysmem costaban 17-24 ms (0,7 pasadas más en tiles por buffer) y el peor buffer de cada periodo
baja de 29 a 24 ms de mediana. Queda una pasada de 71 draws en sysmem a 41 ms en los dos bundles (una vez cada uno):
«its like had 10 draws at most lately», la que `draw()` graba solo para sysmem (§3.5). El coste de CPU por draw no
cambia (171 µs, coordinador).

## 0. Dónde está cada cosa

| Cosa | Dónde |
|---|---|
| Árbol de trabajo | `~/sapphire-angel/research/metal/rebuild/wt-gpu`, rama `gpu-pass`, sobre `opcional-puerto` (`620950c`: upstream HackiOS `63fc2b4` + `patches/a610` + `patches/opcional`). Nueve commits, `08f0ccf`…`fa8d36c`, cada uno encima del anterior (la historia no se reescribe) |
| Herramientas de host | `rebuild/gpu-tools/`: `host.mk` (build por objetos), `t.sh [fc]` (suite con las constantes de los dos chips), `verify.sh REV` (suite de un commit exportado aparte), `stage.py`, `bundle.sh NOMBRE [REV]`, `framecount.cpp` (`framecount P Q …` elige escenas; `FC_GMEM_OFF=N` aplica los bits de `metal_gmem_off`; `FC_DUMP`, `FC_LOG` y `FC_LOG_STATE` vuelcan los paquetes y el estado de cada draw de las escenas X y X7; el de la auditoría 10 es `framecount-base.cpp`), `streams.sh` (§4.1), `base-a610.fails` |
| Para el teléfono | `rebuild/gpu-tools/instalar-por-renombrado.sh`, `driver-en-uso.sh` (solo lectura), `cs-test/` (la reproducción de «Lo primero») |
| Microcódigo del CP del teléfono | `rebuild/gpu-tools/sqe/a630_sqe.phone.fw` (leído de `/chosen/gpu-sqe-firmware` del árbol de dispositivos, 32 504 bytes, sha256 `413dbae6…0129`, versión `016ee206`) |
| Su desensamblado | `rebuild/gpu-tools/sqe/a630_sqe.phone.dis` (9 020 líneas; `qrisc-disasm` de Mesa `767fbf7c`; reensamblado da los mismos 32 504 bytes), `handlers.txt`, `build/` |
| Referencia | Mesa `767fbf7c` en `~/sapphire-angel/research/metal/auditoria-userland/mesa` (las citas `mesa:` son de ese commit) |

| Bundle (`rebuild/out/`) | Commit | sha256 | Qué lleva |
|---|---|---|---|
| `gpu-G1` | `f647bb5` | `698bcc0c…0ced` | grupos de estado, retorno anticipado, rejilla desde el origen |
| `gpu-G2` | `27eabea` | `46f472de…14d9` | + bins de turnip y solo para los attachments tocados |
| `gpu-G3` | `a2eabbb` | `6debba05…387a` | + barrera del fetch como grupo |
| `gpu-G3b` | `0a65a5b` | `d5a40d11…c449` | + todos los grupos `DIRTY` (§3.1). **El que conviene probar primero** |
| `gpu-G4` | `92ed3e7` | `a4ceeb93…f4e7` | + elección GMEM/sysmem por contenido (§3.5) |
| `gpu-G4b` | `fa8d36c` | `fd358406…39b2` | + el perfil de una pasada en tiles dice por qué fue a tiles (`touched`, §6). **El último** |

Todos llevan el parche opcional de `metal.args` (`strings` da `/var/tmp/metal.args` y el formato de la línea `fps:`
en los cinco; el plug-in es byte a byte el de `620950c`) y la clave de caché de stages de `propio-args`
(`24ed84207640dc54c2b865f7`): `bundle.sh` comprueba que `compiler.cpp`, `metallib.cpp`, `link.cpp`, `kernel.hpp`,
`compiler.hpp`, `metallib.hpp`, `compute.hpp` y la declaración de `Stage` son los de `620950c` y solo entonces la
fija, de modo que un bundle `gpu-*` encuentra los stages que dejó `propio-args`. `gpu-G1`, `gpu-G2` y `gpu-G3` no
tienen ningún defecto conocido y no se han probado instalados por renombrado. Con un solo bundle instalado
(`gpu-G3b`, `gpu-G4` o `gpu-G4b`) cada hito se aísla por `metal_gmem_off` en `/var/tmp/metal.args`, sin reinstalar
(§6). `out/gpu-bis-base` (`620950c` con este build) y `out/gpu-bis-vsc` (`c7fa1d6`) son los de la bisección que se
pidió antes de conocerse la causa; el primero sirve de control del build (§4.1).

## 1. Estado de la suite

[O] Con Apple clang 21 el `make test` del árbol no compila en la base: `-Werror` rechaza `chipKnown`, sin uso fuera
del teléfono (`src/c_api.cpp:218`). `host.mk` compila con `-Wno-unused-function` y nada más cambia.

| Árbol | Constantes A635 (las de `make test`) | Constantes A610 (`-DHAKIOS_CHIP_A610`, las del teléfono) |
|---|---|---|
| Base `620950c` | 261 tests, 0 comprobaciones fallidas | 261 tests, 42 fallidas en 19 tests |
| `gpu-pass` `fa8d36c` | 272 tests, 0 fallidas | 272 tests, 29 fallidas en 14 tests |

Los 19 tests que fallan en la base con las constantes del A610 esperan valores del A635 escritos a mano (lista:
`rebuild/gpu-tools/base-a610.fails`). Cinco eran de GMEM y pasan con los dos juegos de constantes, por dos arreglos
de fondo y no por relajar nada: el fake comparaba la base del bin de un framebuffer fetch como si GMEM estuviera en 0
(en el A610 está en `0x100000`), y las expectativas de reparto estaban escritas para el A635. Los 14 que quedan no
son de GMEM (palabras de arranque, caché de instrucciones, memoria privada, `rbCcuCntlSysmem`, sampler) y siguen
como estaban. Cada commit de la rama pasa la suite por separado (`verify.sh REV`).

El fake no rasteriza: comprueba el estado con el que corre cada draw. Lo que ganó para estos streams, cada regla con
su gemelo de mutación (`render::Options::gmemTwin` 1-8 o un stream mutado a mano):

| Regla del fake | Gemelo que la hace saltar |
|---|---|
| Ejecuta grupos, modos, `CP_SET_MODE`, visibilidad y retorno anticipado como el microcódigo (§2) | — (tests del modelo) |
| Cada draw que corre en cada tile tiene el estado que le da el stream plano: registros, cargas de texturas, samplers, constantes y UBO (comparación por resumen, `draw_state_groups_give_each_draw…`) | 1: fragmentos con solo lo que escribió el draw |
| Tras un `HLSQ_INVALIDATE_CMD` lo cargado ya no vale: el draw que lo lee sin recargar es un fallo | 2: cargas sin `DIRTY` y sin reenviar con el programa |
| `LOCAL` puesto antes de `CP_SET_BIN_DATA5` no arma el retorno | 3 |
| Un tile empieza sin grupos puestos | 4: sin soltar grupos entre tiles |
| La ventana de un tile es el bin del VSC que nombra su pipe y su hueco | 5: rejilla desde la esquina del área |
| Los bins de dos attachments escritos no se pisan ni llegan a la caché de color | 6: `RB_MRT_BASE_GMEM` sin reescribir |
| Un fetch que lee el bin con las cachés de textura viejas es un fallo | 7: barrera soltada en el siguiente draw aunque lea |
| Un grupo puesto otra vez, sin `DIRTY`, a lo que ejecutó la última vez es un fallo | 8: solo las cargas `DIRTY` |
| Un draw del stream principal con un grupo todavía puesto por un IB es un fallo | stream a mano |
| Un grupo solo contiene registros, `CP_LOAD_STATE6*`, `NOP` y la barrera (`CP_WAIT_FOR_IDLE`, `CACHE_INVALIDATE`) | 4 streams a mano |

## 2. Lo que hace el microcódigo del teléfono (desensamblado)

Las líneas son de `a630_sqe.phone.dis`. `$14` es el registro de banderas globales del SQE, `$12` el nivel de IB,
`$15` el siguiente draw visible que da el descodificador del stream de visibilidad y `$16` el draw en curso.

1. **`CP_SET_DRAW_STATE`** (L3622): guarda cada grupo en la RAM de draw state. Con `$14.b30` (lo pone `CP_SET_MODE 1`,
   L4261) ejecuta en el acto los grupos pendientes; sin él los ejecuta el siguiente draw que se dibuja (L3896-3905).
   Con `b30` puesto y `b29` no, o dentro de un grupo, salta al manejador de error y el CP se para (L3628-3630, L270).
2. **Ejecución de grupos** (`fxn3123`, L3634-3717): del id más bajo al más alto; un grupo cuya máscara de modo no
   incluye el modo en curso queda pendiente; misma dirección, misma longitud y sin `DIRTY` → no se ejecuta (la
   comparación es con lo último **ejecutado** de ese grupo, `@SDS_BASE`/`@SDS_DWORDS`, que el hardware guarda por
   grupo: `mesa:src/freedreno/registers/adreno/adreno_control_regs.xml:110-123`); misma dirección y más longitud →
   solo la cola; lo demás, entero. Los paquetes del grupo pasan por la misma tabla de paquetes, a nivel 3. Las
   banderas de cada entrada (`DISABLE`, `DISABLE_ALL_GROUPS`, `DIRTY`) las procesa el hardware, no el microcódigo:
   si deshabilitar un grupo borra lo que el CP recuerda haber ejecutado no se ve en el desensamblado.
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

[O] En la base los draws de un pase GMEM se graban una vez y cada tile los llama con `CP_INDIRECT_BUFFER`; lo que se
repite es su **ejecución**: el cuerpo es un stream plano (registros deduplicados, cargas y el paquete de draw), y
el stream de visibilidad solo salta el paquete de draw. `render::drawStates` (`src/gmem.cpp`) convierte ese stream al
cerrar el pase, sin tocar cómo se codifica un draw: lo recorre draw a draw llevando lo que vale cada registro escrito,
y por cada grupo que un draw toca escribe un fragmento con **todos** los registros del grupo tal como están en ese
draw, seguidos de las cargas del draw que son de ese grupo. El reparto de registros entre grupos solo decide cuánto se
reejecuta cuando algo cambia; cualquier reparto es correcto porque cada fragmento es completo.

| Grupo (id) | Contenido | Notas |
|---|---|---|
| barrier (0) | la barrera de un framebuffer fetch (§3.4) | solo en tiles (`GMEM`) |
| pass (1) | `RB_MRT[i]` de buffer, profundidad, MSAA, `RB_RENDER_CNTL`, LRZ | |
| program (2) | `HLSQ_INVALIDATE_CMD` primero; registros de las dos etapas, del enlace y de entradas/salidas del FS; las dos precargas `ST6_SHADER` | como `tu6_emit_program_config` y `setup_config_stateobj` |
| vertex (3) | `VFD_*`, índice de reinicio | |
| loads (4) | constantes, tablas de UBO, texturas y samplers con sus registros, tabla de IBO | enviado otra vez con cada `program`: «CP_LOAD_STATE packets that are invalidated by the PROGRAM_CONFIG draw state» (`tu_cmd_buffer.cc:1275-1313`) |
| raster (5) | cull, modos de polígono, `GRAS_SC_CNTL` | |
| viewport (6) | viewport, guardband, Z clamp, los dos scissors | 21 palabras aparte de las 28 de raster |
| blend (7) | blend, profundidad, stencil | |

**Todos los grupos van `DIRTY`.** El CP no reejecuta un grupo puesto a la dirección y longitud que ejecutó la última
vez (§2.2), y no hay fuente que diga si un `DISABLE`, un reset u otro contexto le hacen olvidar esa ejecución. Los
fragmentos de un pase viven en memoria que los command buffers se turnan: el fragmento de un grupo en el frame
siguiente suele caer en la dirección del frame anterior, con otras palabras o con los registros pisados entretanto
por los pases que se dibujan desde el stream principal (un pase sysmem escribe `RB_MRT`, el viewport y el programa
directamente). `DIRTY` hace que el grupo se ejecute recuerde el CP lo que recuerde; un draw solo pone un grupo
cuando su fragmento cambió, así que nada se ejecuta dos veces por ello. [S] Es el bit que turnip pone en los
estados que `PROGRAM_CONFIG` invalida (`tu_cmd_buffer.cc:1275-1313`). [H] Lo probable es que deshabilitar un grupo
sí borre esa memoria: turnip deshabilita su grupo de constantes tras el paso de binning precisamente para que se
reemita («so make sure these states are re-emitted», Mesa 25.0.7 `tu_cmd_buffer.cc:1792-1804`) y reemite todos tras
`tu_disable_draw_states`, a menudo con las mismas direcciones. El diseño no depende de ello.

Además: las copias de constantes ligadas fuera de múltiplo de 16 (en la base, `CP_MEMCPY` + dos esperas antes de cada
carga, en cada tile) se hacen una vez antes del paso de binning (`DrawStates::prologue`); cada pase empieza sin grupos (la
cabecera de todo pase, `encodeBegin`, lleva un `DISABLE_ALL_GROUPS`) y `encodeGmem` los suelta tras el paso de binning
y tras los draws de cada tile, como fd6 (`fd6_gmem.cc:1133-1135`, `:2194-2203`); y escribe
`CP_SKIP_IB2_ENABLE_LOCAL 1` en cada tile **después** de su `CP_SET_BIN_DATA5` (§2.6), con lo que el tile deja el
cuerpo en el primer draw posterior al último visible. Un stream con algo que `drawStates` no sabe mover, o un pase
sin binning, se dibuja del stream plano, como en la base.

### 3.2 Rejilla de bins donde binnea el VSC (G1)

[O, del código] En la base, un pase cuyos draws tocan parte de la ventana se tilea desde la esquina de esa parte, y a
su paso de binning se le dice una rejilla de ese tamaño con el offset de ventana en (0, 0). El VSC no tiene registro de
origen (`VSC_BIN_SIZE`, `VSC_BIN_COUNT` y el sitio de cada pipe en bins es todo lo que recibe): binnea por la
posición en la ventana, y un tile en (288, 992) recibiría la visibilidad del bin (0, 0). [S] Los dos drivers de Mesa
ponen la rejilla sobre el framebuffer entero en esta familia (`mesa:src/gallium/drivers/freedreno/freedreno_gmem.c:552-559`;
`tu_cmd_buffer.cc:1662-1667`). En la rama `gmemTiles` toma los bins de la rejilla de la ventana que toca el área, y el paso de
binning binnea la rejilla entera (`GmemPlan::gridCols/gridRows`, scissor de ventana desde el origen). [H] Que la base
pintara mal esos pases en el teléfono no está observado: es lo que dice el modelo. La forma nueva es coherente tanto
si el VSC cuenta desde el origen como si contara desde la esquina del scissor de ventana.

### 3.3 Geometría de tiles (G2)

[O] Por qué salen 102 tiles de 768 × 16 en la base: dos attachments de 4 bytes se reparten los 128 KiB bajo la caché
de color, cada parte recortada a múltiplo de 16 KiB, y los bins van en una sola columna del ancho de la ventana:
65 536 / (768 × 4) = 21 filas, 16 al alinear. No hay `cpp` mal contado. El kernel programa `0x21000` de GMEM y el
driver usa `0x20000` para bins y deja los 4 KiB finales a la caché de color de la CCU, como turnip
(`mesa:src/freedreno/common/fd6_gmem_cache.h:113-121`).

En la rama `gmemPlan` reparte y tilea como turnip: partes en bloques de 4 KiB con la fórmula de
`tu_render_pass_gmem_config` (`mesa:src/freedreno/vulkan/tu_pass.cc:848-877`) y búsqueda de
`tu_tiling_config_update_tile_layout` (`mesa:src/freedreno/vulkan/tu_util.cc:286-343`: todos los anchos, el menor
número de bins y, a igualdad, el más cuadrado). Y al cerrar el pase da bins solo a los attachments que sus draws
tocan (`gmemTouched`): el que ningún FS nombra como salida, ninguno lee y ningún tile limpia se queda sin bin, y su
GMEM pasa al anterior como bins más altos del mismo ancho (el ancho no puede cambiar: el descriptor de un fetch lo
lleva como pitch). El `RB_MRT_BASE_GMEM` grabado del attachment sin tocar se reescribe a 0, donde turnip deja el
`RB_MRT` de un attachment que el subpase no usa. Una rejilla cuyos pipes tendrían más de 32 bins no se binnea
(`gmemPipes`; `use_hw_binning` de fd6, `is_hw_binning_possible` de turnip, `tu_util.cc:345-354`).

| 750 × 1624, attachments de 4 bytes | Base | Rama |
|---|---|---|
| 1 | 51 tiles de 768 × 32 | 39 de 256 × 128 |
| 2, los dos tocados | 102 de 768 × 16 | 78 de 128 × 128 |
| 2, uno tocado | 102 de 768 × 16 | 42 de 128 × 240 |
| 3 | sin bin: a sysmem | 126 de 128 × 80 |

Los pipes siguen la regla de fd (`freedreno_gmem.c:321-326`): 78 bins son 13 pipes de 6 × 1, 42 son 14 de 3 × 1.

### 3.4 Framebuffer fetch en tiles (G3)

[S] Un fetch en un tile lee el bin a través de las cachés de textura, en orden de rasterización por
`GRAS_SC_CNTL.SINGLE_PRIM_MODE = FLUSH_PER_OVERLAP` (fd6 `build_prim_mode`, `mesa:src/gallium/drivers/freedreno/a6xx/fd6_emit.cc:533-555`;
turnip, `mesa:src/freedreno/vulkan/tu_pipeline.cc:3800-3845`, `:4468-4500`; el XML: «Invalidate UCHE and wait for any
pending work to finish if there was possibly an overlapping primitive prior to the current one»,
`mesa:src/freedreno/registers/adreno/a6xx.xml:1707-1731`). [HEREDADO, comentario de HackiOS en `encodeDraw`] El
rasterizador ordena el fetch respecto de los draws anteriores que también leen, no de los que corrieron sin el modo:
el primer draw que lee tras uno que no leía lleva una barrera (`CP_WAIT_FOR_IDLE`, `CACHE_INVALIDATE`,
`CP_WAIT_FOR_IDLE`); sin ella HackiOS vio el texto de un widget cortado por una banda y el blur en bloques.

[O] En el stream plano esa barrera son tres paquetes que cada tile ejecuta al pasar, dibuje o no alguno de los
draws que leen, más otra barrera al empezar cada tile: la escena Q (27 transiciones) son 5 568 `CP_WAIT_FOR_IDLE`
por frame en la base. En la rama la barrera es un grupo propio (id 0, solo para tiles): lo pone `DIRTY` el draw que se
grabó con ella y lo suelta el primer draw posterior que ya no va en orden de rasterización. Pendiente de uno a otro,
se ejecuta en el primer draw de esa racha que el tile dibuja —donde hace falta— y en ningún tile que no dibuje
ninguno. La barrera de comienzo de tile desaparece cuando el pase lleva sus barreras así. El microcódigo ejecuta los
paquetes de un grupo por su tabla de paquetes y espera los `CP_WAIT_FOR_IDLE` pendientes antes del draw (`fxn3601`).
Ninguno de los dos drivers de Mesa mete un `CP_WAIT_FOR_IDLE` en un grupo: es lo menos respaldado del diseño, y por
eso tiene dos alternativas por interruptor (§6): la barrera en el stream, como en la base (`1024`) y sin barreras entre
draws con todo el pase en `FLUSH_PER_OVERLAP` (`2048`).

### 3.5 GMEM o sysmem según lo que lleva el pase (G4)

[O] En la base, un pase grabado de las dos formas va a tiles con los draws del listón (`metal_gmem_draws`, 56 por
defecto en el plug-in) y a sysmem con menos, sean lo que sean sus draws. En la rama, `render::gmemWorth` decide al cerrar el pase con los
criterios de turnip (`mesa:src/freedreno/vulkan/tu_autotune.cc`, `get_optimal_mode`), sobre lo que el pase sabe de
sí mismo:

| Criterio | turnip | Aquí |
|---|---|---|
| Pase pequeño → sysmem | «Too few draws to tune», menos de 5 draws (`:1855-1870`); sysmem es el modo en que errar cuesta menos (`:1836-1840`) | menos de `kGmemFewDraws` = 5 draws (o del listón, si es menor: `metal_gmem_draws=1` sigue siendo «todo pase que pueda») |
| El pase lee su target → GMEM | pase con `SINGLE_PRIM_MODE` en sysmem: «should cause significantly increased SYSMEM bandwidth (though we haven't quantified it)» (`:1815-1820`) | algún draw lee su target (`OpenPass::read`) y hay 5 draws o más |
| Memoria movida | sysmem si `clear·px + D ≤ (11·(load + store)·px + D)/10` (`:1043-1067`; `load`, `store` y `clear` por attachment en `tu_render_pass_bandwidth_config`, `tu_pass.cc:905-932`; `D`, el tráfico de los draws, por las muestras que pasó el pase la vez anterior) | tiles si `draws · 22·T ≥ listón · (11·(L + S) − 10·C)`, en bytes por píxel: `T` lo que el pase toca, `L` y `S` lo que los tiles cargan y almacenan, `C` lo que un pase sysmem rellenaría por su Clear |

La tercera fila es la desigualdad de turnip con `D` proporcional al número de draws, calibrada por el listón: el
listón es donde empiezan a compensar los tiles en un pase que carga y almacena todo lo que toca (`L + S = 2T`,
`C = 0`). Un pase así necesita los 56 draws del listón; uno que no hace falta cargar (load action DontCare, o un
Clear que hacen los tiles), 28; uno cuyo Clear en sysmem ya cuesta lo que el store de los tiles, 5. Las cargas y
almacenamientos evitables los evita el driver desde la base (no carga con DontCare ni con Clear en tile; no almacena
lo no escrito ni con store DontCare); en la rama cuentan además en la elección. No hay muestras medidas como en turnip
(`ZPASS_DONE` alrededor del pase): es lo que falta para usar su estimación tal cual (§8).

Un pase que va a tiles por su contenido se anota como pesado en el historial de su clase (`noteDraws`), para que
`draw()` siga grabando de las dos formas el siguiente de su clase. Lo que `draw()` graba solo para sysmem (su clase
tuvo menos de la mitad del listón últimamente) no pasa por aquí: se decide antes del primer draw.

**Por qué una pasada sysmem de 30-39 draws cuesta 20 ms.** Lo medido [M, `medicion/ab/ab-real-gpu-G3b.txt`, 820 MHz,
n = 1]: a 750 × 1624, pasadas en sysmem de 21 draws 16,0 ms, de 30 draws 22,9-23,5, de 39 draws 18,8-19,5, de 48-53
draws 18,5-20,6; a 752 × 1626, de 35 draws 35,5 ms; y una de 71 draws 41,0 ms. En tandas anteriores, una de 20 draws
1,5 ms y, a 138 × 306, una de 18 draws 19,5 ms (`ab-propio-args-1.txt`). El coste no sigue al número de draws (de 21
a 53 draws, 16-23 ms) ni solo al área: depende de qué draws son.

Lo que hace el stream [O]: en sysmem **cada** draw que lee su target lleva `CP_WAIT_FOR_IDLE`,
`PC_CCU_FLUSH_COLOR_TS` con `CP_WAIT_REG_MEM` sobre su palabra, `CACHE_INVALIDATE` y otro `CP_WAIT_FOR_IDLE`
(`encodeDraw`; el orden por rasterización solo se usa en tiles), y después lee el target desde memoria con un
descriptor de textura. No hay resolve. En host: escena B, 5 draws que leen → 14 `CP_WAIT_FOR_IDLE` frente a 4; escena S
en sysmem, 9 → 22. Los draws que no leen no llevan ninguna espera ni relleno, pero cada píxel que escriben o mezclan
pasa por la caché de color hacia y desde memoria: una capa a pantalla completa con blending son 4,9 MB leídos y 4,9
escritos. [M, informe 11 §9] En esas pasadas la GPU mueve 1,0-1,4 GB/s: 7-10 ms por capa a pantalla completa.

Lo que añade `gpu-G4` [M + O]: todas esas pasadas de 28-55 draws van a tiles con su regla, que solo manda a tiles una
pasada bajo el listón por dos motivos: algún draw lee su target, o sus tiles no necesitan cargar (DontCare o Clear) y
tiene 28 draws o más. En tiles dejan de estar entre las cuatro más lentas de cada periodo; la de 752 × 1626 pasa de
35,5 a 16,2-17,0 ms, y en los periodos sin pasada grande lo más lento son pasadas de 78 draws en 78 tiles a 6,5-6,7
ms, donde con `gpu-G3b` eran las de 39 draws en sysmem a 19 ms. [H] Los 20 ms son, por tanto, lo que cuesta en
sysmem lo que esas pasadas llevan: capas grandes mezcladas a través de memoria y, si leen su target, una barrera por
draw. Cuál de los dos motivos mandó cada una a tiles lo dice `gpu-G4b` con `metal_fps=timeline` o `metal_fps=passes`
(`touched 0x1xx`: lee su target; `0x4xx`: no carga nada; §6); cuánto cuesta cada draw en sysmem, `metal_fps=draws`
con `gpu-G3b`.

**Lo que queda en sysmem y cuesta.** [M] La pasada de 71 draws a 41 ms (una vez con cada bundle) lleva el motivo «its
like had 10 draws at most lately»: `draw()` graba solo para sysmem la pasada cuya clase tuvo menos de medio listón de
draws en sus 16 últimas veces, antes de saber qué trae, y `closePass` no puede mandar a tiles lo que no se grabó para
tiles. Es un tirón de un frame cada vez que una pasada ligera se vuelve pesada. Desaparece cuando la elección se hace
al cerrar para toda pasada, que es lo que permite grabar los hechos de un draw y codificar después (`cpu-draw`, §9).

## 4. Antes y después en host

`framecount` con las constantes del A610 sobre `92ed3e7`, n = 3 por condición, recuentos idénticos en las tres.
«Palabras» es lo que el CP del fake trae al ejecutar el stream como el microcódigo (`FakeGpu::Stats::cpWords`); la
fila de la base se obtiene del mismo binario con `FC_GMEM_OFF=1344` (cuerpo plano, bins antiguos, barreras en el
stream) y coincide con el recuento estático de la auditoría 10 (490 138 y 779 668 palabras).

| Escena P: 108 draws, 2 attachments, sin fetch | Tiles | Palabras | Registros escritos | `CP_LOAD_STATE6` | `CP_WAIT_FOR_IDLE` |
|---|---|---|---|---|---|
| Base (`1344`) | 102 | 490 138 | 93 031 | 55 620 | 110 |
| G1: grupos y retorno anticipado (`1280`) | 102 | 159 413 | 46 299 | 3 581 | 110 |
| G2 con bin para los dos attachments (`512`) | 78 | 127 254 | 28 261 | 1 754 | 86 |
| G2/G3/G4 | 42 | 76 413 | 18 331 | 1 349 | 50 |
| — con el cuerpo plano (`64`) | 42 | 204 940 | 38 911 | 23 220 | 50 |
| — sin retorno anticipado (`128`) | 42 | 87 883 | 18 331 | 1 349 | 50 |
| R: los mismos draws en sysmem | — | 4 939 | 975 | 540 | 4 |

| Escena Q: P con un fetch cada 4 draws | Tiles | Palabras | `CP_LOAD_STATE6` | `CP_WAIT_FOR_IDLE` |
|---|---|---|---|---|
| Base (`1344`) | 102 | 779 668 | 58 298 | 5 568 |
| G1 (`1280`) | 102 | 288 477 | 4 821 | 3 122 |
| G2: barreras en el stream (`1024`) | 42 | 157 461 | 2 087 | 1 832 |
| G3: la barrera, un grupo | 42 | 159 349 | 2 087 | 202 |
| Alternativa: todo el pase ordenado (`2048`) | 42 | 139 887 | 2 087 | 92 |

| Escena S: 39 draws a tamaño completo, 9 leen su target, listón 56 | Tiles | Palabras | `CP_WAIT_FOR_IDLE` |
|---|---|---|---|
| Por draws (`4096`): sysmem | — | 3 190 | 22 |
| G4: tiles por el fetch | 42 | 63 078 | 102 |

De las 76 413 palabras de P, 32 024 son estado ejecutado en 1 057 grupos (por tile: una vez `pass`, `program`,
`vertex`, `raster` y `blend`; `loads` y `viewport` por cada draw que corre, 421 veces); el resto es el paseo por los
draws que el tile salta (3 165 draws saltados, dos entradas de grupo y el paquete de draw cada uno) y lo fijo de cada
tile. Lo caro de las 490 138 eran los registros y las cargas, que bajan a la quinta y a la cuadragésima parte.

La meta de 30 000 palabras en P no se alcanza: con binning por hardware el CP tiene que leer el paquete de cada draw
anterior al último visible del tile para saltarlo (§8). Y la escena S enseña el límite del propio recuento: en
palabras, sysmem «gana» 20 a 1, cuando lo que se mide en el teléfono es que esas pasadas en sysmem cuestan más que
la pasada grande en tiles. Las palabras leídas dicen cuánto trabaja el CP, no cuánto esperan el pipeline ni la
memoria.

### 4.1 La escena del blur en host: streams palabra por palabra, estado por draw, VSC y build

Hecho cuando la causa de «Lo primero» aún se discutía; vale como comprobación de que la rama no cambia nada fuera de
lo que dice cambiar. Escena X de `framecount` con las constantes del A610: cinco pasadas pequeñas de un draw (el fondo
a 375 × 812 BGRA8, 187 × 406 RGBA16Float y 93 × 203 BGRA8, y de vuelta), la pasada principal de 750 × 1624 con dos
attachments y 64 draws (el segundo muestrea el resultado de la cadena a pantalla completa; uno de cada cuatro iconos
lee su target) y una pasada pequeña más que muestrea el target principal. X: todo en un command buffer; X7: un
command buffer por pasada. `rebuild/gpu-tools/streams.sh` lo repite entero.

| Comprobación | Resultado [O] |
|---|---|
| Stream de cada commit con los interruptores de la rama apagados (`FC_GMEM_OFF=4416`: cuerpo plano, bins de antes, elección por draws) frente al de la base `620950c`, paquete a paquete | Idéntico en los siete commits que tocan el driver (`c7fa1d6`, `f647bb5`, `27eabea`, `a2eabbb`, `0a65a5b`, `92ed3e7`, `fa8d36c`): X, 176 286 paquetes; X7, los 8 submits |
| Lo mismo con la rama como es | `c7fa1d6`: idéntico a la base (la rejilla desde el origen solo cambia pases de área parcial). Desde `f647bb5`: solo cambia el submit de la pasada en tiles (174 852 paquetes → 45 276 con G1, 18 994 con G2, 17 534 desde G3). Las pasadas sysmem de antes y de después son las mismas palabras; en X, seis paquetes de la última llevan la dirección de la tabla del pase desplazada 0xe000 (la pieza de fragmentos y lista ocupa más que el cuerpo plano) |
| Estado con el que corre cada draw (registros, programa, constantes, tablas de texturas, samplers y UBO cargadas: el resumen del fake, `FC_LOG`) con grupos, con barreras en línea (`1024`) y sin retorno anticipado (`128`), frente al cuerpo plano (`64`) | X7: los 298 draws del paso de binning y de los tiles (64 + 234), con el mismo estado que les da el stream plano en ese tile; las 6 pasadas sysmem, igual; 0 fallos del fake. X: los 298 iguales dejando fuera los tres registros que dicen dónde está el buffer de visibilidad (cambia de sitio) |
| Dos ejecuciones del mismo binario | Idénticas (3 de 3) una vez que cada command buffer se ejecuta antes de confirmar el siguiente; confirmados todos a la vez, la dirección del buffer de visibilidad depende de qué buffer ha devuelto ya el suyo |
| El VSC frente a Mesa 25.0.7 (`rebuild/mesa/mesa-25.0.7/src/freedreno`), fila del A610 (`common/freedreno_devices.py:445-478`, `:140-141`): `tile_align` 32 × 16, `tile_max` 1024 × 1008, `num_vsc_pipes` 16 | Las constantes del driver son esas. `VSC_BIN_SIZE`, `VSC_BIN_COUNT` de la rejilla entera, scissor de ventana desde (0, 0) y offsets de ventana a 0 en el binning: `tu6_emit_binning_pass` (`vulkan/tu_cmd_buffer.cc:1750-1783`) y `update_vsc_pipe` (`:1661-1688`). Pipes en orden de filas con el último recortado y `VSC_SIZE` = bins del pipe: `tu_tiling_config_update_pipes` (`vulkan/tu_util.cc:336-385`); no más de 32 bins por pipe (`:372-380`). Por tile, `CP_SET_BIN_DATA5_OFFSET` con `pipe × pitch` de draw, `pipe × 4` y `pipe × pitch` de primitivas, y el hueco contado por filas con el ancho real del pipe: `tu6_emit_tile_select` (`tu_cmd_buffer.cc:1094-1100`). Límites `pitch − 64` y prueba de overflow por pipe usado sobre `VSC_DRAW_STRM_SIZE_REG`/`VSC_PRIM_STRM_SIZE_REG` con `WRITE_GE`: `emit_vsc_overflow_test` (`:1690-1720`). Diferencias: pitches fijos (16 KiB y 128 KiB; turnip empieza en 4 KiB y 16 KiB y dobla), agrupación de pipes por la regla de fd, y el scissor del binning hasta el borde de la rejilla en vez del framebuffer |
| La palabra de overflow | La base la **lee** a 32 pipes fijos (`CommandQueue::checkVsc`); con los 16 del A610 eso es el byte 0x1F7F0 del stream de primitivas del pipe 1: un overflow real pasa sin verse y solo apagaría el binning con ese stream al 98 %. No descarta draws. `gpu-pass` no lo toca; lo arregla `b935418` de `cpu-draw` |
| El build: `out/gpu-bis-base` (`620950c` compilado con `gpu-tools/bundle.sh`) frente a `out/propio-args` | 31 de 33 secciones idénticas en tamaño y bytes, entre ellas todo `__TEXT` y todo `__DATA`, en las mismas direcciones; difieren `__LINKEDIT` (las rutas del directorio de build en la tabla de símbolos y la firma) y el `LC_UUID`. Es el mismo código |

[O] Coste de CPU de `drawStates` en host (sonda temporal, n = 6 por escena): 97-192 µs para el pase de P (4 674
palabras de cuerpo → 5 557 de fragmentos + 1 203 de lista), 212-366 µs para el de Q (15 753 + 1 827), 114-270 µs
para uno de 140 draws. Corre una vez por pase tileado, en el hilo que cierra el pase. En el teléfono está sin medir;
con la proporción teléfono/host de la auditoría 10 para la grabación (×16-30) serían milisegundos por frame, y eso
va contra el otro cuello (CPU del hilo de render): hay que mirarlo en `CPU/draw` y «hecho→commit» de `ab.sh`.

## 5. Qué cambió, por función

| Función | Cambio |
|---|---|
| `render::drawStates`, `DrawStates::place`, `groupOf` (`src/gmem.cpp`, nuevo; `include/hakios-metal/gmem.hpp`) | El cuerpo plano de un pase → prólogo (copias), fragmentos y lista (`CP_SET_DRAW_STATE` + draw); barrera como grupo, en línea u ordenada; gemelos 1, 2, 7, 8 |
| `render::gmemPlan` | Partes de GMEM en bloques de 4 KiB con la fórmula de turnip; `kGmemPlanOld` conserva el reparto anterior |
| `render::gmemBins` (nuevo) | Búsqueda de la rejilla de turnip |
| `render::gmemTouched` (nuevo) | Bins solo para los attachments tocados |
| `render::gmemPipes` (nuevo) | Agrupación en pipes de fd; falso con más de 32 bins por pipe |
| `render::gmemTiles` | Los bins de la rejilla de la ventana que toca el área (antes, una rejilla propia desde la esquina) |
| `render::gmemWorth`, `GmemChoice` (nuevo) | La elección de §3.5 |
| `render::encodeGmem` | Binning sobre la rejilla entera con índices absolutos; grupos soltados tras el binning y tras cada tile; `CP_SKIP_IB2_ENABLE_LOCAL` tras `CP_SET_BIN_DATA5` y apagado al final del tile; barrera de comienzo de tile solo si el pase no lleva las suyas como grupo; parámetros nuevos `vsc`, `body` (con valor por defecto) |
| `CommandBuffer::closePass` | Elección por contenido en los pases grabados de las dos formas y anotación en el historial; attachments tocados (salidas nombradas por `SP_FS_OUTPUT_REG`, escritos, leídos, limpiados) y reescritura de `RB_MRT_BASE_GMEM`; conversión a grupos, pieza `[fragmentos][lista]`, prólogo; cargas y almacenamientos en una lambda común |
| `CommandBuffer::draw` | **Una línea**: `gmemPlan(…, gmemOff_ & kGmemOldTiles ? kGmemPlanOld : 0)` |
| `render::encodeDraw`, `encodeInPass`, `encodeBegin`, `encodeEnd` | Sin tocar |
| `render::Options` | `gmemTwin` (un byte; la estructura sigue sin relleno) |
| `GmemPlan` | `gridCols`, `gridRows` |
| `CommandBuffer` (`command.hpp`) | Bits de `setGmemOff`: 64, 128, 256, 512, 1024, 2048, 4096. `PassTime::touched` pasa a 16 bits: la máscara de attachments abajo y, encima, `kPassReads`, `kPassBelowBar`, `kPassNoLoad` |
| `FakeGpu` (`fake_gpu.hpp/.cpp`) | Estado del CP (§2), contadores «as run», registro de draws con resumen de estado, reglas de §1 |
| `Makefile` | `CORE` += `src/gmem.cpp` |
| `tests/render_test.cpp` | 11 tests nuevos y los gemelos; tres tests de reparto con literales por chip |

## 6. Interruptores y cómo aislar cada hito con un solo bundle

`metal_gmem_off=N` en `/var/tmp/metal.args` llega al núcleo sin cambios en el plug-in (1, 2, 4, 8, 16 y 32 son los
que ya había). Los bits se suman.

| Bit | Efecto | Para qué |
|---|---|---|
| 64 | Cuerpo plano: sin grupos de estado (ni retorno anticipado) | ¿el fallo está en los grupos? |
| 128 | Sin `CP_SKIP_IB2_ENABLE_LOCAL`: cada tile lee su lista hasta el final | ¿en el retorno anticipado? |
| 256 | Bins como en la base: una columna, partes de 16 KiB, bin para cada attachment | ¿en la geometría? |
| 512 | Bin para cada attachment aunque no se toque | ¿en `gmemTouched`? |
| 1024 | Barreras del fetch en la lista, ejecutadas por cada tile, y barrera al empezar el tile | ¿en la barrera como grupo? |
| 2048 | Sin barreras entre draws; todo draw de un pase con fetch en `FLUSH_PER_OVERLAP` | alternativa de §3.4 |
| 4096 | Tiles o sysmem por draws contra el listón, sin `gmemWorth` (solo en `gpu-G4`) | ¿en la elección? |

Con `gpu-G3b`, `gpu-G4` o `gpu-G4b` instalado: `1344` (+`4096` desde G4) reproduce el stream de la base palabra por
palabra (§4.1); `1280` es G1; `1024` es G2; sin bits, G3. Así un A/B entre hitos no cambia de binario ni de caché de
stages.

En `gpu-G4b`, las líneas `passes:` y `timeline:` del plug-in (`metal_fps=passes`, `metal_fps=timeline`) dicen de cada
pasada en tiles por qué lo está, en el valor `touched`: el byte bajo es la máscara de attachments escritos o leídos;
`0x100`, algún draw lee su target; `0x200`, fue a tiles con menos draws que el listón; `0x400`, sus tiles no cargan
nada.

## 7. Riesgos a mirar en el teléfono

[M] Con `gpu-G3b` y `gpu-G4` la Biblioteca de Apps y el home pintan bien (coordinador, una captura cada uno). El fake
comprueba estado, no píxeles ni tiempos: lo de abajo es qué seguir mirando en otras pantallas (multitarea, bloqueo,
Centro de Control, apps), y con qué acotar si algo aparece. Antes de mirar una captura: `driver-en-uso.sh` debe decir
que backboardd tiene el cliente y deben llegar líneas `fps:`.

| Qué mirar | Qué significaría | Interruptor para acotar |
|---|---|---|
| Pantalla congelada o negra al primer frame con la pasada grande en tiles; `kern.sweet_gpu_diag` con esperas de fence que no acaban | El CP se para en un paquete nuevo. Por orden de sospecha: `CP_WAIT_FOR_IDLE` dentro de un grupo, `CP_SKIP_IB2_ENABLE_LOCAL` tras el bin data, los grupos en el paso de binning con `CP_SET_MODE 1` | `1024`, `128`, `64` |
| Iconos, textos o capas que faltan en franjas horizontales de 240 px o columnas de 128 px, o solo cerca del borde de un tile | Visibilidad o retorno anticipado mal: el tile deja la lista antes de tiempo o lee los streams de otro bin | `128`; `16` (sin binning, del plug-in) |
| Un icono con la textura, el color o el blend de otro, distinto según la zona de la pantalla | Estado de un draw saltado que no se reemite: un registro fuera de su grupo o una carga perdida tras el invalidate | `64` |
| Contenido desplazado o basura junto a las líneas x = 128·n, y = 240·n, o en la franja inferior (los bins pasan del borde: 7 × 240 = 1680 > 1624) | Geometría de bins o `RB_MRT_BASE_GMEM` del segundo attachment | `256`, `512` |
| Texto de un widget cortado por una banda, blur en bloques, materiales translúcidos con rectángulos de otro tono | La firma conocida de un fetch sin barrera: la barrera como grupo no corre donde debe | `1024`; después `2048` |
| Draws que faltan en pases que tocan solo parte de la pantalla (un cambio pequeño con el resto quieto) | La rejilla desde el origen no es la del VSC en el hardware | `1` (tilear la ventana entera) |
| En `gpu-G4`: transiciones y pantallas de pocos draws (bloqueo, multitarea) más lentas, con las pasadas de 17-52 draws «in N tiles» | La elección por contenido manda a tiles lo que iba mejor en sysmem, o al revés | `4096` |
| Con `kern.sweet_gpu_flush=1` (kernel 0342, limpieza de caché por suciedad): basura o cuelgues que desaparecen con `=0` | La pieza de fragmentos y lista se escribe al cerrar el pase; si el seguimiento de suciedad no la ve, la GPU lee memoria vieja | `kern.sweet_gpu_flush=0` |

Medidas que deciden, con `ab.sh` y n ≥ 3: tiempo de GPU de la pasada principal (`draws N in 42 tiles`), `CPU/draw` y
«hecho→commit» (el coste de `drawStates`), y las pasadas de 17-52 draws con `gpu-G4` con y sin `4096`.

## 8. Qué falta

- **En el teléfono**: repetir con n ≥ 3 lo de «Medido en el teléfono»; capturas de más pantallas (§7); `gpu-G4b` con
  `metal_fps=timeline` para ver por qué va a tiles cada pasada de 28-55 draws; `CPU/draw` y «hecho→commit» con y sin
  `64` para el coste de `drawStates`.
- **La pasada que `draw()` graba solo para sysmem** (71 draws, 41 ms): §3.5. No se arregla en `closePass`.
- **La meta de 30 000 palabras en P.** Quedan 76 413. Dos caminos: listas por tile hechas en CPU a partir del área de
  cada draw (sirve si CoreAnimation da viewports o scissors ajustados; en P los da, en el teléfono está sin mirar), o
  la cuarta palabra de `CP_INDIRECT_BUFFER` (§2.7) partiendo la lista en trozos que el SQE salta enteros; Mesa no la
  usa y no hay más respaldo que el desensamblado.
- **Coste de CPU de `drawStates`** en el teléfono, y bajarlo: hoy reconstruye cada fragmento con vectores ordenados
  por draw. Con los objetos de estado precalculados de `cpu-draw` (10 §2.6) los fragmentos salen hechos de la
  grabación y `drawStates` sobra.
- **Elección GMEM/sysmem**: con 78 tiles la pasada principal toca los dos attachments: mirar con `metal_fps=passes`
  si el segundo se escribe de verdad o solo lo nombra el FS (con uno serían 42 tiles). `D` medido como en turnip (`ZPASS_DONE` alrededor del pase y lectura al completar) en
  lugar de proporcional a los draws; ver el contenido de los pases que `draw()` graba solo para sysmem (hace falta
  acumular `fbRead` en `OpenPass` para todo pase: una línea en `draw()`, no hecha por ser territorio de `cpu-draw`);
  comparar con el selector por tiempo medido que ya existe (`metal_gmem=1 metal_gmem_draws=0`, 10 §3.9).
- **Fetch en sysmem**: las barreras por draw siguen (`encodeDraw`, sin tocar). El orden por rasterización de fd6 para
  sysmem (`FLUSH_PER_OVERLAP_AND_OVERWRITE`) las quitaría; HackiOS no vio ganancia en su teléfono (comentario
  heredado, sin verificar aquí).
- **Cuatro attachments o más de 8 bytes por píxel** no caben en la GMEM del A610 con tiles útiles; siguen en sysmem.

## 9. Notas para la fusión con `cpu-draw`

- `CommandBuffer::draw`: una línea cambiada (los flags de `gmemPlan`). `encodeDraw` y `encodeInPass`, ninguna.
- `OpenPass`, `RegShadow`, `Piece`: sin cambios. `closePass` usa `OpenPass::read`, `written`, `clears`, `area`,
  `bodies`, `dual`, `kind` y `ordinal` como estaban.
- `render::Options` gana un byte (`gmemTwin`); la comparación por bytes de `draw()` para unir draws sigue valiendo.
- `CommandBuffer::PassTime::touched` es de 16 bits (la interfaz C lo devuelve como `unsigned`: sin cambios en
  `c_api.cpp` ni en el plug-in).
- La elección de §3.5 está en `closePass` y solo ve los pases grabados de las dos formas. Si `cpu-draw` deja de
  grabar doble y codifica al cerrar, `render::gmemWorth` vale tal cual para toda pasada (necesita `draws`, el listón,
  si algún draw lee su target y los bytes que los tiles cargarían, almacenarían y limpiarían: lo que `closePass` ya
  calcula con `loadStore`), y el tirón de la pasada «its like had N draws» desaparece.
- El arreglo de la palabra de overflow del VSC (`b935418` de `cpu-draw`) no está en `gpu-pass`: entra con la fusión.
- `render.hpp`: `gmemPlan`, `gmemTiles` y `encodeGmem` ganan parámetros con valor por defecto; `GmemPlan` dos campos.
- `drawStates` lee el cuerpo grabado tal como lo deja `appendDeduped`: si `cpu-draw` cambia qué paquetes lleva el
  cuerpo de un pase GMEM (otro orden, paquetes nuevos), `drawStates` devuelve falso y el pase se dibuja del stream
  plano (correcto, sin la ganancia). Sus tests lo dirían: `draw_states_keep_each_groups_registers_whole` y
  `draw_state_groups_give_each_draw_that_runs_the_state_the_plain_stream_gives_it`.
- Los streams dorados de `cpu-draw` (`FakeGpu::submitHook`) que cubran pases GMEM hay que regenerarlos tras la fusión:
  el stream de un pase tileado es otro. Los dos árboles tocan `fake_gpu.hpp/.cpp`.
- `Makefile`: `CORE` lleva `src/gmem.cpp`.
- La caché de stages: `bundle.sh` fija la clave de `propio-args` mientras el compilador y `Stage` no cambien; si
  `cpu-draw` toca `Stage` o `Kernel`, la clave es la del Makefile y el primer arranque recompila los stages.
