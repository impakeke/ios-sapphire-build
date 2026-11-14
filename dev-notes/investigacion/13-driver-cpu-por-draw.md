# 13 — Driver Metal: coste de CPU por draw (etapas A y B de 10 §2.7), 2026-11-14

Informe fechado de implementación. Alcance: el núcleo C++ de `hakios-metal` y lo que el plug-in ObjC hace en cada
draw, sobre la base upstream de HackiOS `63fc2b4` + parches A610 propios + opcionales (08 §5). El diagnóstico de
partida es 10 §2; los datos del teléfono, 03 M1, M2 y M6.

Convención de evidencia, la de 10: **[O]** observación propia (código con `archivo:línea` o medida reproducible),
**[M]** medida del teléfono tomada por otro (archivo citado), **[H]** hipótesis sin medir.

Árbol de trabajo: `~/sapphire-angel/research/metal/rebuild/wt-cpu` (worktree de `hakios-upstream`), rama `cpu-draw`,
creada desde `opcional-puerto` (`620950c`). Las rutas `src/…`, `include/…`, `tests/…`, `tools/…` son de
`wt-cpu/hakios-metal/`; `CA.m` es `wt-cpu/userland/src/HakiosMetalCA.m`. Los números de línea son los de la punta de
la rama (§6 dice cuál).

**Estado: en curso.** Este archivo se amplía a medida que avanza el trabajo; lo que falta está en §8.

## 1. Punto de partida medido

### 1.1 En el teléfono (base `propio-args`, la misma fuente que `620950c`)

[M] `medicion/ab/ab-v1260-base-1.txt` y `ab-propio-args-{1,2}.txt` (resumidos con `ab-sum.py`): 141-164 µs de CPU por
draw en el hilo que llama («of ours each»), de ellos 133-154 dentro de `hakios_metal_cb_draw_indexed`/`_draw3`
(«the core's», cronometrado en `CA.m`, `hakiosDrawOnce`); 128-140 draws por command buffer. El plug-in ObjC gasta
fuera del núcleo 7-10 µs por draw.

### 1.2 En el host (fake GPU)

`tools/drawbench.cpp` graba frames sintéticos y cronometra solo las llamadas de draw. Escenas A-H, P, Q, R: las de
`framecount` de la auditoría 10 (interfaz del núcleo, programas hechos a mano). Escenas J, K, L: la interfaz C que
usa el plug-in (`hakios_metal_cb_draw3`/`_draw_indexed`) con programas enlazados, buffers de vértices e índices,
uniformes ligados a múltiplos de 8, un stage que declara diez slots de textura y liga uno, framebuffer fetch y dos
salidas de color. Escenas S, T (`--stages DIR`): lo mismo con los 202 stages reales de la caché del teléfono
(`auditoria-userland/stage-cache/files`, fuera de git), emparejados por `iboBase` y por `render::link`. `--cold KB`
toca KB kilobytes antes de cada draw, para que el draw empiece con las cachés del procesador como las deja el
trabajo del servidor de ventanas entre dos draws.

La tabla de la base y de cada paso está en §4.

## 2. Suite de host en la base

[O] Con las constantes del A635 (lo que compila `make test`), upstream + A610 pasa 261/261. El informe 10 habla de
44 comprobaciones en 8 tests en el árbol del port; en upstream + A610 no falla ninguna con esas constantes.

[O] Pero `make test` no define `HAKIOS_CHIP_A610`, que es con lo que se compila el bundle del teléfono
(`make ios CHIP=a610`). Compilada con esa definición (`make -f tools/dev.mk CHIP=a610 tests`), la suite falla 42
comprobaciones en 19 tests. Ninguna es un fallo del camino de draw:

| Causa | Qué era | Qué se hizo (commit `397c4d4`) |
|---|---|---|
| Tests que enuncian el chip como número | caché de instrucciones, fibras por SP, `RB_CCU_CNTL` en sysmem, registros mágicos, chip id, bins del plan GMEM, tope de un preload: los del A635 | Cada test enuncia el valor del A610 bajo `HAKIOS_CHIP_A610`, sacado de la fila de `GPUId(610)` de Mesa 25.0.7 (`freedreno_devices.py`: `a6xx_gen1_low`, líneas 353-369, y la entrada 445-478) y de `tu_device.cc:1426-1457`, no del código que se prueba |
| Tests de lo que solo tiene un chip con LPAC o con filtro cúbico | `HLSQ_CS_CTRL_REG1`, copias SP de los registros de id (`fd6_compute.cc:119-127`), filtro cúbico (gen3/gen4) | Dicen lo que hace un chip sin ellos: registro no escrito, sampler rechazado por nombre |
| Modelo del fake GPU | Juzgaba el descriptor de un framebuffer fetch en un tile como si GMEM empezase en la dirección 0; empieza en `kGmemBase` (0x100000 en el A610) | El fake resta `kGmemBase` |
| Modelo del fake GPU | Ataba cada carga de constantes de un envío al `constlen` de cualquier draw posterior, fuese cual fuese el programa para el que se cargaron | Las constantes de un stage quedan atadas al programa tras el que se cargaron |
| `-Werror` en macOS | `chipKnown` sin usar en un host sin la GPU del kernel: `make test` no compilaba con Apple clang 21 | `[[maybe_unused]]` |

[O] Un fallo real apareció por el camino y se arregla aparte (`b935418`): `CommandQueue::checkVsc` leía la palabra de
desbordamiento de los streams de visibilidad en la posición de 32 pipes; `render::encodeGmem` la escribe según
`a6xx::kNumVscPipes`, que en el A610 es 16. En el A610 la palabra leída era de la corriente de primitivas del pipe 1:
un desbordamiento real pasaba sin verse (el binning seguía, y los tiles de un pipe desbordado perdían draws) y una
corriente casi llena podía apagar el binning por sí sola. `render::vscOverflowWordAt()` (`include/…/render.hpp`) es
ahora el único sitio que dice dónde está la palabra. **Interfaz compartida con la ruta GMEM: ver §7.3.**

Con esto, 261/261 con las constantes de los dos chips.

## 3. Qué se cambió, por función

(en curso)

## 4. Tabla antes/después en host

(en curso)

## 5. Teléfono frente a host

(en curso)

## 6. Cómo construir y medir

(en curso)

## 7. Riesgos e interfaces compartidas

(en curso)

## 8. Qué falta

(en curso)
