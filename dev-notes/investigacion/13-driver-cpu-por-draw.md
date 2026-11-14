# 13 — Driver Metal: coste de CPU por draw (etapas A y B de 10 §2.7), 2026-11-14

Informe fechado de implementación. Alcance: el núcleo C++ de `hakios-metal` y lo que el plug-in ObjC hace en cada
draw, sobre la base upstream de HackiOS `63fc2b4` + parches A610 propios + opcionales (08 §5). El diagnóstico de
partida es 10 §2; los datos del teléfono, 03 M1, M2 y M6.

Convención de evidencia, la de 10: **[O]** observación propia (código con `archivo:línea` o medida reproducible),
**[M]** medida del teléfono tomada por otro (archivo citado), **[H]** hipótesis sin medir.

Árbol de trabajo: `~/sapphire-angel/research/metal/rebuild/wt-cpu` (worktree de `hakios-upstream`), rama `cpu-draw`,
creada desde `opcional-puerto` (`620950c`). Las rutas `src/…`, `include/…`, `tests/…`, `tools/…` son de
`wt-cpu/hakios-metal/`; `CA.m` es `wt-cpu/userland/src/HakiosMetalCA.m`.

**Estado: en curso.** Este archivo se amplía a medida que avanza el trabajo; lo que falta está en «Qué falta».

## 1. Punto de partida medido

### 1.1 En el teléfono (base `propio-args`, la misma fuente que `620950c`)

[M] `medicion/ab/ab-v1260-base-1.txt` y `ab-propio-args-{1,2}.txt` (resumidos con `ab-sum.py`): 141-164 µs de CPU por
draw en el hilo que llama («of ours each»), de ellos 133-154 dentro de `hakios_metal_cb_draw_indexed`/`_draw3`
(«the core's», cronometrado en `CA.m:8406-8417`); 128-140 draws por command buffer. El plug-in ObjC gasta fuera del
núcleo 7-10 µs por draw.

### 1.2 En el host (fake GPU)

`tools/drawbench.cpp` graba frames sintéticos y cronometra solo las llamadas de draw. Escenas A-H, P, Q, R: las de
`framecount` de la auditoría 10 (interfaz del núcleo, programas hechos a mano). Escenas J, K, L: la interfaz C que
usa el plug-in (`hakios_metal_cb_draw3`/`_draw_indexed`) con programas enlazados, buffers de vértices e índices,
uniformes ligados a múltiplos de 8, un stage que declara diez slots de textura y liga uno, framebuffer fetch y dos
salidas de color. Escenas S, T (`--stages DIR`): lo mismo con los 202 stages reales de la caché del teléfono
(`auditoria-userland/stage-cache/files`, fuera de git), emparejados por `iboBase` y por `render::link`.

(tabla de la base y de cada paso: §4)

### 1.3 Por qué el teléfono va ~20× más lento por draw que el host

(en curso: §5)

## 2. Suite de host

(en curso)

## 3. Qué se cambió, por función

(en curso)

## 4. Tabla antes/después en host

(en curso)

## 5. Teléfono frente a host

(en curso)

## 6. Cómo construir y medir

(en curso)

## 7. Riesgos

(en curso)

## 8. Qué falta

(en curso)
