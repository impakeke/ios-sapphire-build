# 22 — El blur de CoreAnimation en el Adreno 610: qué pide, qué ejecuta la GPU y cómo servirlo

Informe fechado (2026-11-14). Pregunta del usuario: el lag más visible aparece al desplegar el Centro de Control, la
vista de widgets, la búsqueda y demás superficies con blur; qué instrucciones de GPU ejecuta el blur de CoreAnimation,
cuánto cuesta cada parte en el Adreno 610 y cómo se sirve bien, sin cambiar lo que CoreAnimation pide.

Convención de evidencia (la de 19): **[O]** observado en una traza, en un listado de ir3, en código (`archivo:línea`) o en
un binario; **[M]** medida propia (tiempos de GPU de las trazas, contador always-on del CP); **[D]** documentado por
Apple o Qualcomm; **[R]** ingeniería inversa o código de terceros fiable (Mesa, Asahi); **[H]** hipótesis. Lo que no
se ha podido comprobar se dice. Material de trabajo fuera de git: `~/sapphire-angel/research/metal/blur/` (scripts en
`tools/`, tablas por pasada `pasadas-N.csv`, clasificación `clasif-detalle-N.txt`).

**Material medido.** Tres trazas `metal_trace=frame` con el driver `merge-5` (4cf8232), kernel 0353, GPU a 820 MHz fijos,
scanout directo y actualizaciones parciales activos (03 M17), en
`~/sapphire-angel/research/metal/ios-graficos/trace/capturas-blur/`: `metal-trace-800-1.txt` (abrir y cerrar el Centro
de Control desde el home, 43 command buffers), `-2.txt` (deslizar a la vista de widgets, 60) y `-3.txt` (bajar la
búsqueda desde el home, 60). Una captura por gesto: **n = 1 por gesto**; dentro de cada una, los frames de la animación
repiten la misma cadena entre 4 y 12 veces, y las cifras que siguen dan la mediana y el rango sobre esas repeticiones.
Los tiempos son de GPU por pasada del núcleo (`gpass`, contador always-on del CP entre el inicio de la pasada y el final
de su cola).

## 1. Anatomía del blur en un frame real

### 1.1 Qué pide CoreAnimation

[D, 19 §1.4] El renderer copia lo que hay debajo de una capa con efecto a otra textura, le aplica el efecto y lo
devuelve; para un material eso es captura del fondo, reducción, blur, filtros de color y composición con vibrancy.
[O, QuartzCore 20H392, `research/metal/blur/qc/`] El trabajo lo organiza `CA::OGL::Context::blur_surface` (1 899
instrucciones), que encadena estados de un `PingPongState` (`scale_and_dilate` con factores 1/2, 1/4 y 1/8) y llama a
`BlurState::single_pass_blur`, `narrow_blur`, `downsample_box_2`, `downsample_blur_2/4`, `tile_downsample`,
`in_place_color_matrix` y `process_edges`, y a `narrowBlurParameters(radio, …)` para los pesos y desplazamientos.
`MetalContext::blur_surface` solo añade una ruta con `MPSImageGaussianBlur` condicionada a un byte global de
depuración; sin él, salta a la genérica. `tile_downsample` devuelve si pudo reducir con tile shaders; si no (este
dispositivo no los declara, 19 §2.6), la reducción se hace con pasadas normales (`downsample_8`/`downsample_4`). Qué
radio elige cada cadena exactamente no se ha leído del desensamblado: la elección por radio que sigue es la observada en
las trazas.

**Lo que hace cada etapa** [O, AIR de 20H392, `ios-graficos/qc-20H392/kernels/funciones-no-uber.tsv`]:

| Etapa | Función de CA | Muestreos por píxel (filtro) | Qué escribe |
|---|---|---|---|
| Captura | uber shader `TimgA2Xhf_Isrc` (copia 1:1) o `downsample_4` directo desde la pantalla | 1 (nearest) o 4 (bilineal) | la región del fondo, con 1 px de borde |
| Filtro sobre la captura | uber shader `Tmpc…_Idst` (`fc_texture_function` 49: función del color despremultiplicado) y `Tc33/Tc3b/Tc4b…_Idst` (matriz 3×3, 3×3+sesgo, 4×5) | 0: lee el destino por `[[color(0)]]` | el mismo píxel, en sitio |
| Borde | `A2Xhf` en anillo (`process_edges`) | 0 | 1-16 px alrededor de la región, color sólido |
| Reducción | `downsample_8` (caja 8×8), `downsample_4`, o `TimgA2Xhf_Isrc` bilineal 2:1 (`downsample_box_2`) | 16 / 4 / 1 bilineales | 1/8, 1/4 o 1/2 de la región |
| Blur separable | `narrow_blur_N` (N = 7…27), un eje por pasada | (N+1)/2 bilineales (4…14), sin toma central | la región reducida |
| Blur pequeño | `single_pass_blur_3` | 4 bilineales | a resolución completa |
| Blur variable | `variable_blur_downsample` (mips) + `variable_blur` | 4 por nivel; 2 niveles × 4 + máscara + ruido | campo de búsqueda |
| Composición | `TimgA2Xhfn_IsrcCcl` (imagen + ruido de tramado, coordenadas recortadas) | 1 bilineal + 1 de ruido (nearest, repeat) | la pantalla |
| Posproceso | `luma_boost` (lee el destino) | 1 de LUT | la pantalla |

Todas las pasadas de las tres trazas escriben `BGRA8Unorm` [O, `pasadas-N.csv`: 0 de 1 751 en otro formato]; las
texturas intermedias son propias de CA (`storage=private`, uso lectura + render target) y el driver las crea lineales
(§3.3). El segundo attachment de cada pasada es *memoryless* y ninguna lo escribe en estas cadenas.

### 1.2 Centro de Control (traza 1)

[O] La captura cubre la apertura (cb 6-9, con dos paradas de compilación: §7), el Centro de Control quieto (de cb 9 a
cb 10 pasan 2,5 s sin frames: el fondo difuminado queda en caché y no se rehace) y el cierre (cb 10-22), y vuelve al home
(cb 23-30; en reposo, 24 draws y 1,9 ms por frame). CA elige la cadena del fondo según el radio del momento:

| Radio (fase) | cb | Cadena del fondo de pantalla completa |
|---|---|---|
| muy grande | 7, 8, 10, 11 | captura 752×1626 + `Tmpc` en sitio → `downsample_8` a ~95×205 → `TimgA2Xhf_Isrc` 2:1 a ~48×103 → `narrow_blur_23/27` H → V + `Tc33` en sitio → composición |
| grande | 12, 13 | captura + `Tmpc` → `downsample_4` a ~200×410 → `narrow_blur_19` H → V + `Tc33` → composición |
| pequeño | 6, 14-16 | captura 752×1626 + `Tmpc` → `narrow_blur_7` H **a resolución completa** (756×1630) → V + `Tc33` a resolución completa → composición |
| mínimo | 17-21 | captura 752×1626 sin filtro → `single_pass_blur_3` a resolución completa → composición |
| cero | 22 | captura → composición |

La cadena de radio grande reduce a 1/4 dentro de una textura de pool de 756×1630 con su clear (cb 12: 1,80 ms la pasada). Cada frame añade cadenas pequeñas: los fondos de los módulos (138×306, capturas de la pantalla en 4 tiles, 0,3-0,5 ms
cada una), el indicador de inicio (270×12: captura, `home_affordance_base`, `downsample_4`, `narrow_blur_27`, y una
pasada con `luma_boost` de 2,0-2,4 ms) y la luminancia de su zona (`generateMipmaps` de 512×16 hasta 1×1 y copia de un
texel, 0,02 ms).

**Un frame de radio grande, cb 10** [M]: 20 pasadas, 26,0 ms de GPU.

| # | Pasada | Target (área) | Load/store c0 | Draws | Programa | Muestreos/px | Modo | ms |
|---|---|---|---|---|---|---|---|---|
| e2 | principal | pantalla 750×1624 | load/store | 96 | uber shader (×14,7 de sobredibujo) | — | GMEM, 78 tiles | 10,43 |
| e3 | captura + filtro | 752×1626 | load/store | 4 | copia (nearest) + anillos + `Tmpc` por fetch | 1 | sysmem | 4,01 |
| e4 | reducción 1/8 | 99×209 | clear | 2 | `downsample_8` | 16 | sysmem | 2,17 |
| e5 | reducción 1/2 | 67×122 de una textura de 756×1630 | **clear** | 2 | copia bilineal | 1 | sysmem | 0,80 |
| e6 | blur H | 69×124 de 99×209 | load | 3 | `narrow_blur_23` | 12 | sysmem | 0,06 |
| e7 | blur V + saturación | ~49×104 de 752×1626 | load | 2 | `narrow_blur_23` + `Tc33` por fetch | 12 | sysmem | 0,05 |
| e8 | composición | pantalla | load | 1 | `TimgA2Xhfn_IsrcCcl` | 1 + ruido | sysmem | 1,32 |
| e9, e11 | fondos de módulos | 138×307 | clear | 18, 28 | uber shader, capturas de la pantalla | — | GMEM, 4 tiles | 0,48 + 0,43 |
| e10, e12 | módulos sobre la pantalla | pantalla | load | 70, 24 | uber shader (vibrancy `Bvcm`) | — | GMEM 78 / sysmem | 2,59 + 0,71 |
| e13-e17 | indicador de inicio | 270×12, 87×23 y 89×25 (de 756×1630, **clear**) | | 1-3 | captura, `home_affordance_base`, `downsample_4`, `narrow_blur_27` | 4 / 14 | sysmem | 0,70 (0,63 el clear) |
| e18 | indicador + `luma_boost` | pantalla | load | 3 | `luma_boost` por fetch a pantalla completa | 1 (LUT) | sysmem | 2,16 |

**Un frame de radio pequeño, cb 14** [M]: la captura (3,76 ms), `narrow_blur_7` H a resolución completa con el clear de
756×1630 (2,91 ms) y V + `Tc33` a resolución completa (4,29 ms) suman 10,96 ms, y la composición lee una fuente de
resolución completa (2,03 ms).

**Medianas de las pasadas que se repiten** [M, `experimentos.txt`, las cinco capturas de `trace/`]:

| Pasada (sysmem salvo donde se dice) | n | Mediana | Rango |
|---|---|---|---|
| Clear de una textura de pool de 756×1630 con draws de < 60 000 px | 6 | 0,69 ms | 0,61-0,80 |
| Copia 1:1 a pantalla completa (1 draw, nearest) | 20 | 1,97 ms | 1,87-2,15 |
| Composición a pantalla completa, fuente reducida | 12 | 1,34 ms | 1,32-1,42 |
| Composición a pantalla completa, fuente de resolución completa | 4 | 2,13 ms | 2,03-2,21 |
| Captura 752×1626 sin filtro | 6 | 2,07 ms | 2,05-3,00 |
| Captura 752×1626 + `Tmpc` por fetch | 10 | 3,91 ms | 3,67-4,33 |
| `downsample_8` desde 752×1626 (la fuente entera, 4,9 MB) | 3 | 2,15 ms | 2,13-2,17 |
| `downsample_4` desde la pantalla a 190×408 (widgets) | 12 | 1,14 ms | 1,10-1,26 |
| Captura y reducción a 340×733 con dos filtros por fetch, GMEM 9 tiles (búsqueda) | 8 | 2,72 ms | 2,15-3,14 |
| `single_pass_blur_3` a resolución completa | 5 | 2,34 ms | 2,27-2,48 |
| `narrow_blur_7` H a resolución completa + clear de 756×1630 | 4 | 3,00 ms | 2,91-3,43 |
| `narrow_blur_7` V + `Tc33` por fetch, resolución completa | 4 | 4,43 ms | 4,27-4,95 |
| `luma_boost` a pantalla completa + ≤ 2 draws pequeños | 29 | 1,99 ms | 1,91-2,40 |
| Pantalla en GMEM con poco dibujo (< 300 000 px), 42 tiles | 2 | 1,47 y 1,95 ms | |
| Pasada principal en GMEM (≥ 80 draws), 78 tiles | 91 | 10,41 ms | 5,81-15,05 |

### 1.3 Vista de widgets (traza 2)

[O] cb 38-49 son el deslizamiento; cb 50-60, la vista quieta con algo que se mueve (17,3-17,7 ms por frame en 3
pasadas). El fondo de la vista no pasa por una captura a resolución completa: `downsample_4` lee directamente la
pantalla.

**cb 41** [M]: 8 pasadas, 22,9 ms.

| # | Pasada | Target (área) | Load/store c0 | Draws | Programa | Muestreos/px | Modo | ms |
|---|---|---|---|---|---|---|---|---|
| e0 | principal | pantalla | load/store | 97 | uber shader | — | GMEM 78 | 10,54 |
| e1 | captura + reducción 1/4 | 190×408 | load | 3 | `downsample_4` desde la pantalla | 4 | sysmem | 1,14 |
| e2 | reducción 1/4 | 68×122 de 98×207 | clear | 2 | `downsample_4` | 4 | sysmem | 0,09 |
| e3 | blur H | 70×124 de 100×209 | clear | 2 | `narrow_blur_23` | 12 | sysmem | 0,06 |
| e4 | blur V + matriz 4×5 | 190×408 | load | 2 | `narrow_blur_23` + `Tc4b` por fetch | 12 | sysmem | 0,05 |
| e5 | widgets y composición | pantalla | load/store | 101 | uber shader | — | GMEM 78 | 7,04 |
| e6 | copia de la pantalla | 750×1624 propia | load | 1 | copia 1:1 (nearest) | 1 | sysmem | 2,00 |
| e7 | barra de estado + `luma_boost` | pantalla | load | 3 | `luma_boost` por fetch a pantalla completa | 1 | sysmem | 1,96 |

La copia de e6 (textura `com.apple.coreanimation.surface`, 750×1624, privada) se repite en cada frame, también en
reposo (cb 50-60), y **ningún draw de las 60 command buffers la lee** [O: 0 `dtex` con ella]: es trabajo pedido cuyo
consumidor no aparece en la traza (otro frame posterior, la CPU o nadie; no verificado). En reposo, cada frame es
principal 13,4 ms + copia 2,0 + `luma_boost` 2,0.

### 1.4 Búsqueda (traza 3)

[O] cb 6-14 son la bajada; desde cb 15 la búsqueda está quieta y los frames son una pasada de ~107 draws (8,0 ms) o
de ~28 (1,9 ms, el cursor): el fondo difuminado ya no se rehace.

**cb 9** [M]: 24 pasadas, 20,8 ms. Principal 10,42 ms en GMEM. El fondo de la búsqueda: captura y reducción a la mitad
en una pasada (`downsample_4` desde la pantalla a 340×733, más `Tc33` y `Tmpc` por fetch, en GMEM con 9 tiles: 3,14 ms),
`downsample_8` a 63×112 (0,70), `narrow_blur_19` H en 65×114 de una textura de 344×737 con su clear (0,23), V (0,03) y
composición a pantalla completa (1,37). El campo de búsqueda: copias de 468×64 y 480×96 (0,13 y 0,09), cuatro
`variable_blur_downsample` que hacen la cadena de mips 240×48 → 30×6 (0,17 en total) y `variable_blur` (0,31). Otros
dos materiales pequeños (192×64 y 64×64: `downsample_4` + `narrow_blur_23`, 0,02-0,23 cada pasada) y dos pasadas más a
la pantalla (0,56 y 3,08 ms; la segunda lleva `luma_boost`).

En cb 12 y 13 una pasada a la pantalla cuesta 11,8 y 3,2 ms porque tres draws de 18 700 px dibujan con el uber shader
**genérico** mientras su variante se compila (`spec=pending`): §7.

### 1.5 Tabla por frame: blur frente al resto

[M, `tabla-frames.md`] «Blur estricto» = captura + cadena (reducciones, blurs y filtros fuera de la pantalla). «Otras a
pantalla» = las pasadas a la superficie de pantalla después de la principal: la composición del material y lo que CA
dibuja encima, que el blur obliga a partir en varias pasadas (§8). GPU = suma de las pasadas del frame.

| Gesto | Frames | GPU por frame | Principal | Otras a pantalla | Blur estricto | Clears sobredimensionados |
|---|---|---|---|---|---|---|
| Centro de Control, radio grande y muy grande (cb 10-13) | 4 | 24,1-26,0 ms | 10,3-10,5 | 5,7-6,8 (4 pasadas) | 6,5-8,1 (7-8 pasadas) | 1,4-1,8 |
| Centro de Control, radio pequeño (cb 14-16) | 3 | 28,8-29,6 ms | 10,3-10,4 | 6,6-6,7 | 11,1-11,9 | — |
| Centro de Control, radio mínimo (cb 17-21) | 5 | 18,6-21,3 ms | 10,4-10,9 | 3,8-5,8 | 4,3-5,5 | — |
| Centro de Control, apertura (cb 6-8) | 3 | 25,0-41,8 ms | 10,2-10,6 | 5,2-9,4 | 6,7-12,5 | 1,4-2,7; genérico 7,7-21,4 |
| Widgets, deslizando (cb 38-49) | 12 | 20,5-23,0 ms | 10,2-10,7 | 6,7-9,1 (2) | 3,2-4,4 (5; de ellos 2,0 la copia de e6) | — |
| Widgets, quieto (cb 50-60) | 9 | 17,1-17,6 ms | 13,3-13,5 | 1,9-2,1 | 1,9-2,1 (la copia) | — |
| Búsqueda, bajando (cb 6-11) | 6 | 19,4-21,1 ms | 10,4-11,8 | 4,6-5,2 (4) | 3,9-5,1 (11-17) | 0,2-0,5 |
| Búsqueda con variantes compilándose (cb 12-13) | 2 | 25,0-28,4 ms | 10,1-10,2 | 9,8-14,0 | 4,0-4,8 | 0,4-0,5; genérico 3,2-11,8 |

Lecturas:

1. **Ningún frame con blur baja de 16,3 ms de GPU** a 820 MHz, y la mayoría está entre 19 y 30: con la GPU sola, 35-60
   frames por segundo, lejos de los 120 (8,33 ms).
2. **La cadena del blur en sí cuesta 2-12 ms por frame**, y lo caro no son los blurs a baja resolución (0,02-0,16 ms por
   pasada) sino las pasadas a **resolución completa**: la captura (2,1-4,3 ms), las reducciones que leen la fuente
   entera (`downsample_8`/`downsample_4` desde 752×1626 o la pantalla: 1,1-3,1 ms), los blurs a resolución completa
   de radio pequeño (2,3-4,4 ms) y la composición (1,3-2,2 ms).
3. **La pasada principal (10-13,5 ms) y las vueltas a la pantalla (2-14 ms) pesan tanto o más que el blur**: el blur
   obliga a redibujar entero lo que tiene debajo en cada frame (actualizaciones parciales inútiles mientras cambia el
   radio o se mueve el material) y a partir la superficie de pantalla en 2-6 pasadas.
4. **El primer uso de cada pipeline** añade paradas de 0,4-1,3 s en el hilo de render y 3-21 ms de GPU por frame
   mientras se dibuja con el uber shader genérico (§7).
5. Los clears de texturas de pool mayores que el área de render cuestan 0,6-0,8 ms cada uno y no los pide el área que
   CA dibuja (§3.4).

(en curso: §2 código ir3, §4 Apple)

## 5. Propuesta priorizada y conforme

Nada de esto cambia lo que CoreAnimation pide: mismas pasadas, mismos shaders, mismos radios. Cambia cómo el driver
(y el kernel) ejecuta cada pasada. Las ganancias son estimaciones [H] con las cuentas de §3.1 sobre los frames de §1;
cada una se confirma con la traza del mismo gesto antes y después (n ≥ 3, §6).

| # | Cambio | Dónde | Ganancia estimada por frame | Riesgo | Validación |
|---|---|---|---|---|---|
| P1 | **Semilla de stages con el catálogo entero de CA**, compilada en la Mac con el compilador del driver, más las combinaciones que CA crea en ejecución recogidas del teléfono; regenerada en el build cuando cambie `CACHE_BUILD` (§7) | herramienta de host + `build-bundle.sh`; el plug-in ya mira `HM_CACHE_SEED` | quita las paradas de 0,4-1,3 s del primer uso y los 0,4-13 ms de GPU por pasada que cuesta el uber shader genérico mientras compila | bajo | host: claves y bytes iguales a los 202 stages de la caché del teléfono; teléfono: primera apertura del Centro de Control tras instalar, 0 pipelines con `compile_ms` > 5 y 0 draws `spec=pending` |
| P2 | **Clear solo del área de render** (`renderTargetWidth/Height`, que el plug-in hoy no pasa al núcleo), en sysmem (rectángulo del motor 2D) y en GMEM (tiles del área) | `CA.m` (descriptor de pasada), `render.cpp` (`fillStream`, tileado de una pasada con Clear) | 0,6-0,8 ms por clear de 756×1630: 1,4-1,8 ms por frame del Centro de Control de radio grande; 0,2-0,5 en la búsqueda | bajo, si la semántica de §4.1 se confirma | host: test del fake con el rectángulo del relleno; teléfono: esas pasadas bajan a 0,03-0,1 ms, capturas idénticas píxel a píxel del Centro de Control a varios radios |
| P3 | **Disposición tiled (`TILE6_3`) y después UBWC para las texturas propias de CA que son render target** (capturas, intermedios del blur, pool), con lo que falta en el núcleo: Clear del motor 2D, carga y guardado en tiles, copia y resolve sobre esas disposiciones | `Texture::make`, `fillStream`, `encodeGmem`, copias; el núcleo ya dibuja en UBWC en sysmem | 30-50 % de las pasadas a resolución completa sobre texturas propias: −1,5 a −3 ms en el radio grande, −4 a −6,5 en el pequeño | medio-alto: configuración UBWC del kernel (`HIGHEST_BANK_BIT` 14 frente a 13 de Mesa, 08/09), errores de imagen vistos por otros ports (12 §27) | host: `fdl6_layout` y el fake; teléfono: sonda de lineal frente a tiled/UBWC (§6.3), trazas y capturas a cada radio, interruptor para A/B |
| P4 | **Cargar y guardar en GMEM solo los bins con primitivas visibles** (el paso de binning lo sabe), como turnip (§3.5) | `encodeGmem` | home quieto: 1,45-1,72 → ~0,1-0,2 ms por frame; vueltas a la pantalla parciales (cb 17: 1,47 → ~0,4) | medio: paquetes condicionales del CP y su caída cuando el VSC se desborda | host: fake con bins sin geometría; teléfono: traza del home quieto y del cierre |
| P5 | **Elección GMEM/sysmem por bytes estimados** (área de los draws, fetch, carga y guardado), no por número de draws: las pasadas de resolución completa con filtro por fetch (`Tmpc`, `Tc33`: 2-4 draws) a GMEM, las vueltas a la pantalla que dibujan poco a sysmem | `gmemWorth` (14 §3.5) | −0,5 a −1,2 ms por pasada con fetch a resolución completa (1-3 por frame en el Centro de Control); −1,0 en vueltas como la de cb 17 | bajo-medio | traza: modo y tiempo de cada pasada antes y después |
| P6 | **Voto del DDR (0347)** si el experimento de §6.1 dice que las pasadas de resolución completa dependen del reloj del DDR | kernel (ya en la serie, sin probar) | hasta −20 % en las pasadas de resolución completa (3-5 ms por frame) [H] | bajo-medio: parche sin probar, consumo y calor | §6.1 |
| P7 | **Copia 1:1 de la pantalla recién dibujada hecha como un segundo resolve** de los bins de la pasada anterior, y la pasada siguiente sobre los mismos bins si nada lee la pantalla entre medias (§8) | `closePass`, análisis del command buffer al confirmarlo | vista de widgets: −1,3 a −3 ms por frame; captura del Centro de Control: −1,3 | alto (mecanismo nuevo; condiciones de exactitud) | host: equivalencia píxel a píxel en el fake; teléfono: capturas |
| P8 | Fuera del blur, en los mismos frames: **no cargar lo que el primer draw tapa** y el **descarte conforme de draws tapados** de 19 §3.4 en la pasada principal | `closePass`, plug-in | −0,7 ms por carga evitada; en los frames con el Centro de Control abierto (cb 9, 23, 24) 88-91 draws y 15,4 Mpx quedan tapados por la composición opaca del fondo en la misma pasada: hasta −8 a −10 ms | medio (necesita la geometría en CPU; 19 §3.4 da las condiciones) | traza: draws tapados y tiempo de la pasada principal |

**Orden recomendado.** P1 y P2 primero (riesgo bajo, efecto visible: la parada del primer uso y ~1,5 ms por frame);
después el experimento de §6.1, que decide entre P3 (si lo que manda es el patrón de acceso) y P6 (si manda el reloj
del DDR); P4 y P5 en paralelo; P7 y P8 cuando lo anterior esté medido. Con P1-P5 un frame del Centro de Control de radio
grande pasaría de ~25 a ~19-21 ms y uno de radio pequeño de ~29 a ~19-22 [H]; para bajar de 16,7 ms hace falta además
la pasada principal (P8 y 14).

**No conformidades vistas en estas pasadas.**

- El Clear de una pasada cubre el attachment entero aunque `renderTargetWidth/Height` sea menor (P2): desviación si
  Metal limita la acción de carga al área de render (§4.1). CA no lee fuera del área en estas trazas, así que no hay
  efecto visible.
- Ningún draw rechazado, omitido ni sustituido en las tres trazas [O: 14 371 draws `res=ok`, 0 `nearest:`/`instead:`,
  `skipped=0` y `status=completed` en los 163 command buffers]. `luma_boost` se dibuja (N-24 resuelto en `merge-4`).
- Dibujar con el uber shader genérico mientras compila la variante es conforme solo si el genérico es equivalente con
  la configuración de los 52 B leída al codificar (N-17 de 19 §2.9); con P1 no se llega a usar.

## 6. Lo que falta medir y el experimento decisivo

### 6.1 El experimento decisivo: relojes de GPU y de DDR sobre el mismo gesto

**Pregunta.** ¿Las pasadas de resolución completa (captura, reducción desde 752×1626, blur pequeño, composición, clear)
dependen del reloj de la GPU, del reloj del DDR o de ninguno (patrón de acceso a memoria lineal)? Decide entre P3, P6 y
trabajo de shader.

**Predicción del modelo de §3.1.** Con la GPU de 820 a 1260 MHz (×1,54) la pasada principal baja claramente y las de
resolución completa en sysmem poco (< 15 %); con el DDR de 1 555 a 1 805-2 093 MHz (×1,16-1,35) las de resolución
completa bajan si están limitadas por DRAM; si no bajan con ninguno, manda el patrón de acceso (P3).

**Para el coordinador.** Kernel 0353, el bundle de traza de `merge-5` instalado por renombrado y comprobado con
`driver-en-uso.sh`; `/var/tmp/metal.args` con **solo** `metal_trace=frame` (sin `metal_fps`, que cambia lo medido).
Antes de cada tanda, abrir y cerrar el Centro de Control una vez sin capturar (para que no entren compilaciones). Gesto,
tres veces por condición (n = 3): `echo 40 > /var/tmp/metal.trace; sleep 0.3; $H swipe 0.92 0.003 0.92 0.65 300; sleep 2;`
y cerrarlo con el gesto de cierre habitual (`$H swipe 0.5 0.95 0.5 0.2 250` o el botón de inicio), `sleep 2`.
Condiciones:

| | GPU | DDR |
|---|---|---|
| A | `sysctl -w kern.sweet_gpu_khz=820000` | sin voto (`sysctl kern.sweet_ddr_khz` → 1555210) |
| B | `sysctl -w kern.sweet_gpu_khz=1260000` | sin voto |
| C | 820000 | `sysctl -w kern.sweet_gpu_ddr=1`; comprobar `kern.sweet_ddr_khz` y `dmesg \| grep "ddr: BIMC vote"` |
| D | 1260000 | voto |

Anotar `kern.sweet_thermal` al principio y al final de cada condición. Riesgos: 0347 no se ha probado en el teléfono
(17 §11.4; si el DDR no se mueve con el voto, C y D no aportan y se anota); a 1260 MHz hubo una incidencia sin causa
(03 M10, n = 1). Análisis: `tools/experimentos.py` y `tools/clasifica.py` de `research/metal/blur/` por condición, cociente
por clase de pasada.

### 6.2 Capturas adicionales

1. **Apertura limpia del Centro de Control**: la de la traza 1 está mezclada con compilaciones; repetir la apertura tras
   una primera apertura y cierre sin capturar, con `metal_trace=frame` y `echo 40 > /var/tmp/metal.trace` justo antes
   del gesto. Da la apertura sin paradas y con los mismos radios que el cierre.
2. **Biblioteca de Apps** (blur con vibrancy y desplazamiento de la lista), con el gesto del `LEEME.md` de la traza.
3. **Quién lee la copia de la vista de widgets** (la textura de 750×1624 de §1.3): 120 command buffers en la vista de
   widgets quieta y abriendo desde ella el selector de apps; si nadie la lee en ninguna, queda como trabajo pedido sin
   consumidor visible (no se toca: es de CA).

### 6.3 Lo que no se ha medido

- Tiempo por draw (las trazas dan tiempo por pasada); `metal_fps=draws` lo da en sysmem a costa de serializar.
- Bytes leídos y escritos por pasada: los contadores de rendimiento del a6xx (UCHE, TP, RB, VBIF/GBIF) no se leen hoy;
  con ellos §3.1 deja de ser una inferencia (§3.5 da los nombres y cómo se leen).
- Lineal frente a tiled/UBWC en **este** teléfono: la sonda de HackiOS (`hakios-metal/tools/probe.cpp`, casos «UBWC» y
  «a Clear in the tiles») se midió en otro chip; construirla para iOS y correrla con el dispositivo Metal abierto a otros
  procesos (`metal_all=1`, 03 M13) daría el dato sin tocar CA [H: no comprobado que la sonda abra el cliente del
  kernel desde un proceso que no es backboardd].
- Qué radio elige cada cadena en `Context::blur_surface` (constantes 3,5; 5,5; 9,5; 20; 21 y factores 1/2, 1/4, 1/8 a
  la vista en el desensamblado, sin leer su lógica).

## 3. Modelo de coste en el Adreno 610

### 3.1 Lo que dicen los tiempos de las pasadas

Las pasadas de un solo propósito de §1 aíslan cada coste. Por cada superficie de pantalla en BGRA8 (750×1624 = 1,22
Mpx, 4,87 MB) [M]:

| Camino | Pasada que lo aísla | Tiempo | Bytes por segundo |
|---|---|---|---|
| Relleno del motor 2D (`CP_BLIT`) | clear de 756×1630 con draws diminutos | 0,69 ms | ~7,1 GB/s escritos |
| Carga + guardado de GMEM (motor de resolve) | vuelta a la pantalla en 42 tiles con poco dibujo | 1,47 ms (carga y guardado) | ~6,6 GB/s |
| Escritura del RB en sysmem a lineal | composición a pantalla completa desde una fuente pequeña | 1,34 ms | ~3,6 GB/s escritos |
| Lectura del TP de una textura lineal + escritura del RB | copia 1:1 (nearest) | 1,97 ms | ~4,9 GB/s entre lectura y escritura |
| Lectura del TP de una textura lineal, en bloques de 4×4 | `downsample_4` de la pantalla a 190×408 | 1,14 ms | ~4,3 GB/s leídos |
| Lectura del TP de una textura lineal, en bloques de 8×8 | `downsample_8` de 752×1626 a 95×205 | 2,15 ms | ~2,3 GB/s leídos |
| Leer el destino por fetch en sysmem (barrera + TP) y reescribirlo | `Tmpc`/`Tc33` en sitio a resolución completa | +1,8-2,1 ms sobre la pasada sin él | |

El DDR corre a 1 555,2 MHz bajo iOS (17 §4.3) y el SM6225 lleva dos canales LPDDR4X de 16 bits (19 §6.4, *product
brief*): **12,4 GB/s de pico** a esa frecuencia (16,7 GB/s a los 2 092,8 MHz del plan). El motor 2D y el resolve llegan
al 53-57 % del pico; el pipeline 3D sobre superficies lineales, al 19-40 %.

Tres comprobaciones de que lo que limita no es la aritmética ni el filtrado [M]:

1. `single_pass_blur_3` (4 muestreos bilineales por píxel) a resolución completa cuesta 2,34 ms; la copia 1:1 (1
   muestreo nearest), 1,97: **cuatro veces más muestreos, un 19 % más de tiempo**.
2. `downsample_8` (16 muestreos × 19 500 píxeles) y `downsample_4` (4 × 77 500) hacen el mismo número de muestreos
   bilineales (~310 000) sobre el mismo volumen de fuente (~4,9 MB), y uno tarda 2,15 ms y el otro 1,14: lo que cambia
   es la forma del acceso (8 filas lineales de 3 KB de paso por píxel de salida frente a 4) y la ocupación (`downsample_8`
   usa 12 registros completos, `downsample_4` 3; §2), no la cantidad de trabajo.
3. Los blurs a 1/16 (`narrow_blur_23/27`, 12-14 muestreos por píxel) cuestan 0,02-0,16 ms la pasada: a esa escala el
   coste por pasada (cabecera, vaciado de la CCU al terminar, espera) domina, y aun así es pequeño: 10-20 pasadas
   pequeñas suman 0,3-0,6 ms por frame.

**Conclusión [H fuerte, por la coherencia de las seis filas]:** el blur es caro en este teléfono por **las pasadas a
resolución completa sobre memoria lineal en sysmem**: cada lectura de una superficie completa por el TP cuesta 1,1-2,2
ms, cada escritura del RB 1,3 ms, cada fetch en sysmem otros ~2 ms, y los clears de texturas mayores que el área 0,7 ms.
Lo que se haga en esas pasadas (4 o 14 muestreos, half o float) cambia poco. El experimento de §6.1 separa la parte de
DRAM (la que sube con el reloj del DDR) de la de patrón de acceso (la que no sube con ninguno de los dos relojes).

### 3.2 Disposición de las texturas: lineal frente a tiled/UBWC

[O] Todas las texturas propias de CA que son render target (las capturas, los intermedios del blur, las de 756×1630
del pool) son lineales: el driver solo comprime (UBWC) las texturas de solo lectura, compartidas, de un nivel, RGBA8 o
BGRA8 y de 256×256 o más (`hm_compress`, `CA.m:4619-4648`; en las trazas, `origin=compressed`: los fondos de pantalla
`Head.HEIC`, `Body.HEIC`…). El núcleo ya sabe dibujar en una textura UBWC en sysmem (`render.cpp:138-160`: `RB_MRT` con
su *flag buffer*) pero rechaza el Clear del motor 2D sobre ella, la carga y el guardado en tiles y la copia desde ella
(`render.cpp:1075-1076`, `:2411`, `:2930-2934`: «not served yet»). [O, 19 §3.2 y `tbdr-apple-vs-adreno.md` §2.5] Mesa
usa `TILE6_3` y UBWC por defecto para las imágenes óptimas también en el A610 (solo excluye el A702), y Qualcomm llama a
las superficies lineales «much less performant». [HEREDADO] Una capa a pantalla completa con mezcla en este teléfono
(Mesa GL, 1125×2436): 6 ms en lineal, 2,4 en tiled y 1,3 en GMEM; y la sonda de HackiOS (`tools/probe.cpp:4932-5053`,
en su A635) mide que muestrear una textura UBWC tarda la mitad que la lineal. [O, `tbdr-apple-vs-adreno.md` §2.6] En
sysmem la CCU del A610 tiene 8 KiB de caché de color: la localidad de la disposición pesa.

### 3.3 Los clears de las texturas del pool

[O] CA reutiliza texturas de un pool y dibuja en un rectángulo con `renderTargetWidth/Height` (en las trazas, `rt`):
67×122 de una de 756×1630, 89×25 de la misma en el mismo frame, 65×114 de una de 344×737. El plug-in no pasa ese tamaño
al núcleo (solo lo escribe en la traza, `CA.m:2197-2198`) y el núcleo hace el Clear con el motor 2D sobre **el nivel
entero**: «the render area is the whole target, as a Metal Clear covers the attachment whatever the scissor»
(`render.cpp:964-967`, `fillStream` `:970-990`); en GMEM, una pasada con Clear se tilea entera (`render.cpp:5290-5294`).
[M] Cada clear de 756×1630 cuesta 0,61-0,80 ms (n = 6), 1-2 por frame en el Centro de Control (1,4-1,8 ms) y 1-3 de
344×737 en la búsqueda (0,2-0,5 ms). Si Metal limita las acciones de carga al área de render, esto además es una
desviación del contrato: §4.1.

### 3.4 GMEM o sysmem, y la carga y el guardado

[M] La pasada principal (96-148 draws, 17,7-18,0 Mpx dibujados para 1,22 Mpx de pantalla: ×14,7 de sobredibujo) cuesta
10,2-13,5 ms en 78 tiles. De esos píxeles, 6,47 Mpx son de 9 draws opacos tapados del todo por un draw opaco posterior
(4 rellenos sólidos de pantalla completa bajo el fondo de pantalla, y los pares imagen/máscara de las capas del fondo)
[O, `trace-frame.py`, «Draws cubiertos por un draw opaco posterior», confianza alta], y su carga de 4,9 MB es
innecesaria (el primer draw opaco cubre todo antes de mezclar nada). Ninguna de las dos cosas es del blur, pero son el
40-55 % de cada frame con blur (19 §3.4 trata el descarte conforme).

[O, 14 §3.5] La elección actual manda a tiles toda pasada con 5 draws o más que lea su target y a sysmem las de menos de
5 draws: las pasadas del blur (1-4 draws) van todas a sysmem, también las de resolución completa con fetch; y vueltas a la
pantalla que dibujan poco van a GMEM y pagan la carga y el guardado enteros (§8).

### 3.5 Lo que haría un driver de Mesa con la misma cadena

(se completa con las fuentes de Mesa: motor 2D, área de render, carga y guardado condicionados, autotune)

## 7. El tirón de la primera vez: compilar en el hilo de render

**Lo medido [M, campos `created` y `compile_ms` de cada `pipe`].** En la traza 1, 28 pipelines se crean durante la
captura; 19 salen de la caché de stages en 0,3-1,0 ms y 9 se compilan de cero en **415-455 ms cada uno**
(`TcimBvcmA2Xhf_Icir`, `TcimA2Xhf_Icir`, `TimgA2Xhfn_IsrcCcl`, `TimgA2S1Xhf_Isrc`…, tanto variantes del catálogo como
combinaciones que CA crea en ejecución). CoreAnimation los pide al codificar el primer frame que los usa, en su hilo
de render: cb 7 tarda **1 318 ms** de crear a confirmar y cb 8, **540 ms**. En la traza 3, dos más (454 ms cada uno) en
cb 12. En la traza 2, ninguno. Mientras la variante especializada de un pipeline genérico se compila, el draw se hace con
el uber shader genérico (`spec=pending`, 17 draws en la traza 1, 4 en la 3), y eso cuesta GPU: la pasada de 138×306 de
cb 8 tarda 13,37 ms con dos draws genéricos y 0,48 ms la misma pasada en cb 10 sin ellos; la pasada a la pantalla de cb
12 de la traza 3, 11,77 ms frente a 2,5-3,1 ms en los frames vecinos. Que estas variantes no estuvieran en la caché
cuadra con que `merge-4` empezó a compilar el uber shader con las constantes de CA en lugar de sustituir variantes
(19 §2.2, N-01): son claves nuevas para esta caché [H].

**Cómo lo evita iOS [O, 19 §2.2].** QuartzCore trae una pipeline library con los 1 079 pipelines de su catálogo ya
compilados para cada generación de GPU de Apple (`pipelines.g10p` para la A11) y la abre con
`setDisableRunTimeCompilation:YES`; solo compila en ejecución lo que no está en el catálogo. (Lo que Apple documenta
sobre archivos binarios y creación asíncrona: §4.)

**Lo que ya hay en el driver [O].** Una caché de stages en disco (`HAKIOS_METAL_CACHE` =
`/private/var/db/hakios-metal-cache`, que sobrevive a los reinicios) y un directorio de solo lectura que se mira después
(`HAKIOS_METAL_CACHE_SEED` = `/redwood/share/hakios-metal-cache`, `CA.m:608-609`, `:3400-3417`); la clave de un stage es
un hash de la clave del compilador (`CACHE_BUILD`), del tamaño de `Stage` y `Kernel`, de `IBO_BASE`, del bitcode AIR, de
las constantes y del buffer conocido (`compiler.cpp:1168-1196`). El comentario del compilador cifra el coste: «a
CoreAnimation uber shader variant takes up to a second to compile, and the window server draws nothing while one does»
(`compiler.cpp:1122-1124`). La semilla de HackiOS (`tools/metal-cache-seed.sh`) se llena con lo que compiló un arranque
anterior en el teléfono, no con el catálogo.

**El equivalente conforme.** El resultado de compilar es el mismo se haga cuando se haga; lo que Metal fija es que el
pipeline devuelto dibuje lo pedido. Por orden:

1. **Compilar el catálogo fuera del teléfono.** El compilador del driver (traductor AIR→NIR e ir3 de Mesa 25.0.7) se
   construye también para el host; con las 451 funciones especializadas de `default.pipelinelib/functions`, el
   `default.metallib` y los valores de constantes de `pipelines.desc` (sección 5) se generan en la Mac los stages de los
   1 079 pipelines con la misma `CACHE_BUILD`, y se instalan en el directorio de semilla con el bundle. Las
   combinaciones que CA crea en ejecución y no están en el catálogo se recogen de la caché del teléfono tras usarlo y
   se añaden a la semilla. Validación: los nombres de fichero que genera la Mac para los stages que ya hay en la caché
   del teléfono (`auditoria-userland/stage-cache/files`, 202) deben coincidir y su contenido ser idéntico byte a byte;
   después, una traza de la primera apertura del Centro de Control tras instalar debe tener 0 pipelines con
   `compile_ms` > 5 y 0 draws `spec=pending`. Riesgo: que el bitcode que entrega `-[_MTLFunction bitcodeData]` en el
   teléfono no sea byte a byte el del fichero (entonces las claves no coinciden y no se gana nada, sin romper nada).
2. **Regenerar la semilla en el build** cada vez que cambie `CACHE_BUILD` (cualquier cambio del compilador): si no, el
   primer arranque con un driver nuevo vuelve a pagar decenas de compilaciones de 0,4 s.
3. **Compilar más deprisa** [H]: 415-455 ms por variante es el tiempo de traducir y optimizar el uber shader entero
   antes de que las constantes poden lo que no se usa; plegar las constantes de función en el AIR/NIR al principio
   debería dejarlo en milisegundos. Medirlo en el host con un perfil de `compileStage` sobre una variante.
4. **El genérico como respaldo solo donde no cuesta**: dibujar con el uber shader genérico mientras se compila cumple el
   contrato si el genérico es equivalente (CA lo diseñó como el mismo programa con la configuración en un buffer, 19
   §2.2), pero cuesta de 0,4 a 13 ms de GPU por pasada en estas trazas. Con la semilla completa no se llega a usar.

## 8. La superficie de pantalla partida en varias pasadas

**Lo medido [M].** Un frame del Centro de Control dibuja la superficie de pantalla en 3-5 pasadas (principal, composición
del fondo, módulos, más módulos, indicador con `luma_boost`); la vista de widgets en 3 y la búsqueda en 4-6. Entre
ellas van pasadas fuera de la pantalla que **leen la pantalla** (capturas de los fondos de los módulos de 138×306, la
captura del indicador de 270×12, la reducción directa de los widgets, la captura de la búsqueda a 340×733).

**Por qué [O, D].** CA pinta las capas de atrás adelante (19 §1.3) y cada `CABackdropLayer` captura lo que hay debajo
**en ese punto del orden**; la pasada a la pantalla tiene que terminar (guardar) para que la captura lea, y la siguiente
vuelve a empezar (cargar). Es una dependencia de datos real: ningún driver puede juntar dos pasadas a la pantalla
separadas por una captura que lee vecindarios de la pantalla (una reducción) sin cambiar el resultado.

**Cuánto cuesta cada vuelta [M].** En GMEM, una vuelta a la pantalla carga y guarda los bins de su área: con poco dibujo,
1,47-1,95 ms a pantalla completa en 42 tiles (unos 9,7 MB entre carga y guardado: ~6,6 GB/s). En sysmem no hay carga
ni guardado, pero cada píxel que se mezcla o se lee por fetch pasa por memoria: una capa a pantalla completa cuesta
1,3-2,2 ms.

**Lo que haría bien un driver de tiles, sin cambiar lo que CA pide:**

1. **Cargar y guardar solo los bins con geometría.** El paso de binning ya sabe qué bins tienen alguna primitiva
   visible. Ejemplo medido [O, traza 1, cb 1-5]: en el home quieto la región sucia es 64×96 px (el segundero del Reloj),
   pero un draw de `attachment_clear` (`path_blit_vert`, cuatro vértices con el rectángulo 416,704-480,800 en su buffer de
   vértices) lleva el scissor de pantalla completa, el área que estima el driver (viewport ∩ scissor) es la pantalla
   entera y se cargan y guardan los 78 tiles: 1,45-1,72 ms por frame para dibujar dos bins. Con carga y guardado
   condicionados a la visibilidad serían 2 bins (§3.5 y §5).
2. **No cargar lo que el primer draw tapa.** [O, `trace-frame.py`, «Load innecesario»] En las pasadas principales del
   Centro de Control un draw opaco de pantalla completa (el fondo) cubre todo antes de mezclar nada, y lo mismo la
   composición del fondo difuminado: la carga de 4,9 MB no hace falta. Es conforme: lo cargado no se observa.
3. **Elegir sysmem cuando la vuelta dibuja poco**: la vuelta de cb 17 (11 draws, 96 000 px, 10 de 42 bins con
   geometría según las cajas de los draws) cuesta 1,47 ms en GMEM porque la regla actual manda a tiles toda pasada con 5
   draws o más que lea su target (14 §3.5); en sysmem serían esos 96 000 px.
4. **Una copia 1:1 de la pantalla recién dibujada es un guardado más** [H, por validar]: la copia de cada frame de la
   vista de widgets (e6, 2,0 ms) y la parte de copia de la captura del Centro de Control leen la pantalla píxel a píxel
   (nearest, mismo tamaño, sin mezcla) justo después de la pasada que la dibujó. Hecha como un segundo *resolve* de los
   bins de esa pasada a la otra textura, no lee 4,9 MB de memoria lineal; y si lo siguiente que toca la pantalla es otra
   pasada sin capturas por medio (la de `luma_boost` en widgets), ésta puede seguir en los mismos bins. Solo vale si la
   copia es exacta (filtro nearest, coordenadas en centros de píxel, mismo formato, sin escritura a otra cosa) y el driver
   lo comprueba al cerrar el command buffer, que es cuando conoce todas sus pasadas.
