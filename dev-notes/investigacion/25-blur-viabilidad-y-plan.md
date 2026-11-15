# 25 — El blur de CoreAnimation: verificación de 22, viabilidad de cada propuesta y plan de implementación

Informe fechado (2026-11-14). Encargo: tratar el informe 22 como hipótesis, comprobar cada afirmación contra las trazas
disponibles con n ≥ 3, contra Mesa 25.0.7, contra KGSL y contra nuestro kernel; convertir cada propuesta (P1-P9) en un
plan implementable con sus prerrequisitos; y preparar la medición que falta. Sin cambiar lo que pide CoreAnimation y
sin nada del trabajo heredado de «Angel».

Convención de evidencia (la de 19 y 22): **[O]** observado en una traza, en código (`archivo:línea`), en un binario o en
un registro; **[M]** medida propia con su n; **[D]** documentado por Apple o Qualcomm; **[R]** código de terceros fiable
(Mesa, Linux, KGSL); **[H]** hipótesis. «No verificado» donde no hay dato.

**Material.** Driver: worktree `~/sapphire-angel/research/metal/rebuild/wt-blur`, rama `blur-proto` sobre `96d9bac`
(`merge-7`), sin commit: el diff está en `rebuild/out/blur-tile/blur-tile.patch`. Kernel: árbol de trabajo
`~/sapphire-angel/research/metal/blur/parches-nuevos/work/xnu` (el de `kernel-gpu/parches-nuevos` a 0342, más 0343-0353
de `xnu/patches`) y parches en `blur/parches-nuevos/`. Análisis: `blur/tools25/`. Trazas: `ios-graficos/trace/`.

## Resultado en breve

1. **Lo que se sostiene de 22, ahora con n ≥ 3** (12 aperturas y cierres del Centro de Control con `merge-7`, 6 a 820 MHz
   y 6 a 1260 MHz, `capturas-cc-4cond`): el coste del blur está en las pasadas a resolución completa sobre memoria
   lineal en sysmem, y esas pasadas **no dependen del reloj de la GPU**. La captura con filtro cuesta 4,13 ± 0,25 ms a
   820 MHz (n = 77) y 4,11 ± 0,21 ms a 1260 MHz (n = 79). `downsample_8` desde 752×1626 cuesta 2,25 ± 0,12 ms frente a
   2,18 ± 0,10 (n = 22 y 16). El clear de 756×1630 cuesta 0,71 ± 0,03 ms frente a 0,69 ± 0,03 (n = 13 y 18). La
   cadena del blur entera (captura, cadena y composición) cuesta 10,7 ± 3,1 ms por frame frente a 10,0 ± 3,5 (n = 104 y
   107 frames). En cambio la pasada principal baja un 23 % (9,58 → 7,42 ms) y los frames sin blur un 19 %. §1.
2. **Lo que cae o se corrige.**
   - P4 rinde menos de lo que dice 22 fuera del home quieto: el 86-100 % de los bins de las vueltas a la pantalla del
     Centro de Control tienen geometría (mediana, n = 447).
   - La afirmación «el A610 no tiene olas de 128 en el FS» confunde dos propiedades de Mesa (§4).
   - «Los registros de UBWC sin programar» no impiden usar TILE6_3 ni UBWC: todas las unidades leen la misma
     configuración (banco 14, modo 0, medido en el teléfono, §2.1).
   - El descarte de draws tapados (P8, segunda mitad) no lo hace ningún driver de Mesa, y exige leer la geometría en la
     CPU al ejecutar, no al codificar (§3.4).
3. **P3 medido en el teléfono** (bundle `blur-tile`, `metal_tile=1|2`, solo las texturas privadas que crea
   `MetalContext::create_surface`, QuartzCore 20H392 0x18830d2ac-0x18830d2e4).
   - **Correcto**: `hakios-metal-tilecheck` da 0 fallos, comparando byte a byte lineal, TILE6_3 y UBWC en cada
     operación.
   - **En aislado gana mucho**: clear 676 → 559 → 383 µs; mezcla a pantalla completa 1 780 → 1 162 → 788; fetch 1 868 →
     1 178 → 882; carga y guardado GMEM 1 319 → 1 081 → 614 (lineal → TILE6_3 → UBWC).
   - **En el Centro de Control gana poco**: 19,5-19,8 → 19,15 (TILE6_3) y 18,97 ms (UBWC) por frame. El 72 % del
     tiempo va a pasadas cuyo destino es la superficie de pantalla, una IOSurface lineal que el interruptor no toca:
     14,0 de 19,5 ms.
   - **Una clase empeora**: `downsample_8` leyendo la captura en TILE6_3 o UBWC tarda +0,45-0,68 ms. Los contadores de
     la GPU (`metal_perf=1`, 1 beat = 32 B medido) lo explican: ya en lineal trae de DDR 2,65 veces la textura que lee
     (13,0 MB por 4,9 útiles, 94 % de fallos en el L1 del TP), y en TILE6_3 4,1 veces. §2.7.
4. **La palanca grande es la superficie de pantalla en UBWC.** El DPU del SM6115/SM6225 escanea UBWC 1.0 en ARGB8888
   con la misma disposición que `fdl6_layout`. Exige:
   - la configuración UBWC de Android en la GPU (0370 con `gpu_ubwc=1`);
   - superficies del pool en esa disposición y el SSPP programado para leerlas;
   - la copia del kernel leyendo UBWC.
   Estimación [H, con las medianas de tilecheck]: −2 a −4,5 ms por frame con blur. §2.8.
5. **Orden recomendado**: contadores de T0/T1/T2 (por qué empeora `downsample_8`) → 0370 con `gpu_ubwc=1` → pantalla en
   UBWC → P5 y P1 → P9 → P7 → P4 → P8 solo en su forma de «no cargar». §7.

## 1. Auditoría de 22, afirmación por afirmación

**Datos.** 22 sale de tres trazas de `merge-5`, una por gesto (n = 1 por gesto). Las trazas posteriores con más de una
captura del mismo gesto son las de `capturas-cc-4cond` (03 M24): `merge-7`, kernel 0353, 12 capturas de 45 command
buffers de la apertura y el cierre del Centro de Control, 1-3 y 10-12 a 820 MHz, 4-9 a 1260 MHz. Cada captura trae la
apertura con blur (unos 7 frames), el Centro de Control abierto sin blur (unos 25) y el cierre con blur (unos 7). Se
clasifica cada pasada con `blur/tools/clasifica.py` (las mismas clases que 22) y se resume con `blur/tools25/audita.py`
(n, media, desviación típica, mediana, rango) y `blur/tools25/bins2.py` (bins con geometría, con cota superior e
inferior). Para la vista de widgets y la búsqueda no hay más capturas del gesto: lo que 22 dice de ellas sigue en
n = 1.

**Por clase de pasada** [M, `audita.py` sobre `capturas-cc-4cond`; ms de GPU por pasada, media ± dt (n)]:

| Pasada | 820 MHz | 1260 MHz | Cambio con +54 % de reloj | 22 decía |
|---|---|---|---|---|
| Captura 752×1626 + `Tmpc` por fetch (sysmem) | 4,13 ± 0,25 (77) | 4,11 ± 0,21 (79) | 0 % | 3,91 (n = 10), 3,67-4,33 |
| Captura 752×1626 sin filtro (sysmem) | mediana 2,16 (28) | mediana 2,18 (22) | 0 % | 2,07 (n = 6) |
| `downsample_8` desde 752×1626 (sysmem) | 2,25 ± 0,12 (22) | 2,18 ± 0,10 (16) | −3 % | 2,15 (n = 3) |
| `downsample_8` + clear de 756×1630 en la misma pasada | 2,86 ± 0,26 (20) | 2,63 ± 0,42 (27) | −8 % | — |
| Clear de pool 756×1630 + draws < 60 000 px | 0,71 ± 0,03 (13) | 0,69 ± 0,03 (18) | −3 % | 0,69 (n = 6) |
| Blur a resolución completa (`narrow_blur_7/23`, `single_pass_blur_3`) | mediana 2,32 (116), hasta 8,39 | mediana 2,13 (117) | −8 % | 2,3-4,4 |
| Pantalla con `luma_boost` | mediana 2,17 (96) | mediana 2,13 (95) | −2 % | 1,99 (n = 29) |
| Composición a pantalla (sysmem) | 1,66 ± 0,89 (83) | 1,38 ± 0,77 (86) | −17 % | 1,3-2,2 |
| Vuelta a la pantalla en GMEM | 2,47 ± 0,36 (401) | 2,15 ± 0,27 (421) | −13 % | 1,47 y 1,95 (n = 2) |
| Fondos de módulos, offscreen en GMEM | 0,43 ± 0,05 (419) | 0,32 ± 0,04 (439) | −26 % | 0,3-0,5 |
| Pasada principal en GMEM (frames de ≥ 4 pasadas) | 9,58 ± 1,16 (239) | 7,42 ± 0,84 (243) | −23 % | 10,2-13,5 (con `merge-5`) |

**Por frame** [M, mismas capturas; frames de 4 pasadas o más]:

| | 820 MHz | 1260 MHz |
|---|---|---|
| GPU media por frame, por captura | 19,38 ± 0,27 ms (n = 6 capturas: 19,0-19,9) | 16,33 ± 0,07 ms (n = 6: 16,3-16,4) |
| Frames con blur: GPU | 25,4 ± 4,1 ms (n = 104), 16,6-34,3 | 22,1 ± 4,0 ms (n = 107), 14,4-29,9 |
| …de ello, blur (captura + cadena + composición) | 10,7 ± 3,1 ms, 2,5-23,6 | 10,0 ± 3,5 ms, 2,3-18,8 |
| Frames con el Centro de Control abierto, sin blur | 15,5 ± 1,4 ms (n = 135) | 12,6 ± 1,0 ms (n = 136) |

La primera fila rehace 03 M24 con las 12 capturas (M24 analizó 4 de las 6 de 820 MHz y daba 19,7-20,3): **+54 % de
reloj quita el 15,7 % del tiempo de GPU por frame**, y lo que no baja es precisamente la parte del blur.

| # | Afirmación de 22 | De qué dato sale en 22 | Comprobación | Veredicto |
|---|---|---|---|---|
| A1 | Ningún frame con blur baja de 16,3 ms de GPU a 820 MHz; la mayoría entre 19 y 30 | 3 trazas `merge-5`, n = 1 por gesto | CC, `merge-7`, n = 104 frames: 16,6-34,3 ms, mediana 26,5 | **Se sostiene** para el Centro de Control. Widgets y búsqueda siguen en n = 1 |
| A2 | La cadena del blur cuesta 2-12,5 ms por frame | Ídem | 2,5-23,6 ms, 10,7 ± 3,1 (n = 104). Los 23,6 son el primer frame de una apertura con `narrow_blur_23` a resolución completa (6,2 + 8,4 ms, captura 1, cb 8) | **Se amplía el rango**: hasta 23,6 ms |
| A3 | Lo caro son las pasadas a resolución completa sobre memoria lineal | Tiempos por pasada, n = 1-20 | Tabla de clases: esas pasadas no cambian con el reloj de la GPU (0 a −8 %); las de GMEM y las pequeñas bajan un 13-26 % | **Se sostiene**, con dos datos nuevos: no dependen del reloj del núcleo, y la disposición pesa. Con TILE6_3 o UBWC la captura con filtro baja de 4,18 a 2,97-3,03 ms y la sin filtro de 2,19 a 1,64-1,69 (§2.7), así que no es solo el DDR. Pero `downsample_8` empeora con ellas, y cuánto es DDR lo dirán los contadores (§5) |
| A4 | La captura cuesta 2,1-4,3 ms; la reducción desde ella 2,15 ms; un clear de 756×1630 0,7 ms | n = 3-10 | 4,13 ± 0,25 (77) con filtro; 2,25 ± 0,12 (22); 0,71 ± 0,03 (13) | **Se sostiene** |
| A5 | Motor 2D y resolve ~7 GB/s; pipeline 3D sobre lineal 2,3-4,9 GB/s | Cuentas sobre A4 | Clear: 4,93 MB en 0,71 ms = 6,9 GB/s. Captura sin filtro: 9,8 MB en 2,16 ms = 4,5 GB/s. Con filtro: 19,6 MB en 4,13 ms = 4,7 GB/s. `downsample_8`: 4,9 MB en 2,25 ms = 2,2 GB/s | **Se sostiene** como cuenta [H]: los bytes son los útiles, no los medidos. Los mide §5 |
| A6 | Cuatro veces más muestreos cuestan un 19 % más (`single_pass_blur_3` frente a la copia 1:1) | n = 5 y 20 | `single_pass_blur_3` 2,27-2,52 ms (n = 18, cb 43-45 de las 6 capturas a 820) frente a la captura sin filtro, 2,16 de mediana: +5-17 % | **Se sostiene** (+5-17 %) |
| A7 | La pasada principal cuesta 10-13,5 ms | `merge-5` | `merge-7`: 9,58 ± 1,16 ms a 820 MHz (n = 239) | **Corregida**: 9,6 ms de media con `merge-7` |
| A8 | Las vueltas a la pantalla cuestan 2-14 ms por frame; cada una carga y guarda sus bins (~1,5 ms) | n = 2 pasadas | 2,47 ± 0,36 ms por vuelta en GMEM (n = 401); 4,3 ± 1,7 ms por frame (n = 239) | **Se corrige** el coste por vuelta: 2,5 ms, no 1,5 |
| A9 | P4: el home quieto pasa de 1,45-1,72 a ~0,1-0,2 ms; las vueltas parciales ganan (cb 17: 1,47 → 0,4) | 1 traza, cajas de los draws | Home quieto (n = 30): 1,82 ms. Cota inferior de bins con geometría del 3 % (mediana), si el `attachment_clear` de geometría desconocida es el rectángulo de 64×96 que 22 leyó de su buffer de vértices. Vueltas del Centro de Control (n = 447): mediana del 86-100 % de bins con geometría | **Se sostiene para el home quieto; cae para el blur**: en el Centro de Control, P4 ahorra como mucho el 14 % de la carga y el guardado de cada vuelta |
| A10 | Draws tapados: 6,47 Mpx por frame y 88-91 draws (15,4 Mpx) con el CC abierto | `trace-frame.py`, 1 traza | Sin rehacer con n ≥ 3 [no verificado]. Lo que P8 puede hacer conforme está en §3.4 | **Pendiente**; la cifra no cambia el plan |
| A11 | El A610 no tiene doble ola en el FS y el driver compila para olas de 128 | `supports_double_threadsize = False` | Mesa 25.0.7 tiene dos propiedades distintas. `supports_double_threadsize` (falso en `a6xx_gen1_low`) es la del cómputo. Para el FS, ir3 decide por `threadsize_base` y `double_threadsize`, y turnip compila `IR3_SINGLE_ONLY` solo si no hay `supports_double_threadsize` | **A matizar**: §4 |
| A12 | Los registros de UBWC sin programar impiden UBWC en render targets | KGSL frente a Linux, lectura de código | Basta que el RB, el TP, el SP y la UCHE vean la misma configuración. Medido: las cuatro con banco 14 y modo 0 (0x2, 0x00200000), y tilecheck da 0 fallos en TILE6_3 y UBWC en todas las operaciones | **Cae como impedimento para la GPU sola**. Para compartir UBWC con el DPU (pantalla) hacen falta los valores de kgsl (0370, §2.8) |
| A13 | El primer uso de cada pipeline compila 415-455 ms en el hilo de render | `merge-5` | `merge-6`/`merge-7` (03 M20, M23): la espera era el cerrojo del compilador; ahora el peor frame de la primera apertura codifica en 52-70 ms | **Superada**: la compilación en uso sigue existiendo (P1), la espera de 0,4-1,3 s no |
| A14 | La copia 1:1 de la vista de widgets la repite cada frame y nadie la lee | 1 traza | Sin rehacer (no hay más capturas de ese gesto) [no verificado] | n = 1 |
| A15 | El clear del attachment entero es lo que documenta Metal | [D] + `rtw.m` en Intel, n = 3 | Sin dato nuevo | Se mantiene, con la salvedad de 22 (driver de Apple sin probar) |

## 2. P3 y P2: formatos de memoria de las texturas intermedias

### 2.1 Qué admite el Adreno 610

**Mesa 25.0.7** [R]. La fila del A610 (`src/freedreno/common/freedreno_devices.py:446-478`) hereda de `a6xx_base`
`has_8bpp_ubwc = True` (:329) y no quita UBWC. Declara `highest_bank_bit = 13`, `ubwc_swizzle = 0x7`, `macrotile_mode = 0`,
`tile_align_w = 32`, `tile_align_h = 16`, y de `a6xx_gen1_low` (:353-368) `has_gmem_fast_clear = False` y
`sysmem_per_ccu_color_cache_size = 8 KiB`. `fdl6_layout` (`fdl/fd6_layout.c:123-311`) da a una imagen tiled de 4 bytes por
píxel el pitch alineado a 64 píxeles (256 B) y las filas a 16 (`fdl6_tile_alignment`, :86-111). Por debajo de 16 de
ancho la deja lineal (`FDL_MIN_UBWC_WIDTH`, `freedreno_layout.h:201`). Con UBWC pone primero el flag buffer, con bloques
de 16×4 (:26-81). La regla de swap: «It seems CCU ignores swap and always uses WZYX when tiled. TP, on the other hand,
always respects swap. We should return WZYX such that CCU and TP agree each other» (`fdl/fd6_format_table.c:370-375`).
En la disposición TILE6_3 influyen el banco más alto, los niveles de swizzle de banco (el nivel 1 solo en modo UBWC
1.0) y el modo de macrotile (`fdl/fd6_tiled_memcpy.cc`, comentario de cabecera, :30-120). Con eso, el mismo TILE6_3 sin
compresión ya depende de esos registros.

**KGSL en este teléfono** [R + O]. `a6xx_start` (kgsl 5.x, graphics-kernel `f900d903`, `adreno_a6xx.c:676-737`) escribe
`RB_NC_MODE_CNTL`, `TPL1_NC_MODE_CNTL`, `SP_NC_MODE_CNTL` y `UCHE_MODE_CNTL` con el modo UBWC y la longitud mínima de
acceso del DT y el banco más alto del núcleo. El DT del teléfono da `qcom,min-access-length = <0x40>` y
`qcom,ubwc-mode = <0x01>` (`relojes/dtb/merged-khaje24a-sapphire.dts:7961-7962`). El A610 tiene
`highest_bank_bit = 14` (`adreno-gpulist.h:1520`). Resultado: RB, TPL1 y SP a 0x0000000b, UCHE a 0x00a00000. El DPU
declara `qcom,sde-ubwc-version = <0x10000000>` (UBWC 1.0) y `qcom,sde-highest-bank-bit = <0x01>` (:15256-15258). El
módulo `msm_kgsl.ko` del Android instalado no está en `relojes/vendor_ramdisk`, así que los valores de kgsl salen de su
fuente y del DT, no del binario [no verificado sobre el binario].

**Linux v6.12** [R]. `a6xx_calc_ubwc_config` da al A610 banco 13, `min_acc_len` 1 y `ubwc_swizzle` 7
(`a6xx_gpu.c:513-517`, en `relojes/ref/linux`). Resultado: 0x00000009, UCHE 0x00800000 y `RBBM_NC_MODE_CNTL` 0
(:568-609). Kgsl y Linux difieren solo en el banco más alto.

**Nuestro kernel** [O]. `hw_init_regs` no escribe ninguno de los cinco (`SapphireGpu.cpp`, a 0353) y `GET_PARAM
HIGHEST_BANK_BIT` responde 14. El driver no lee ese parámetro.

**Lo que tiene la GPU** [M, `hakios-metal-tilecheck` en el teléfono, kernel 0353, `blur/tilecheck-1.txt`, n = 1 lectura
por registro] (`CP_REG_TO_MEM`):
- `RB_NC_MODE_CNTL` = `TPL1_NC_MODE_CNTL` = `SP_NC_MODE_CNTL` = 0x00000002 y `UCHE_MODE_CNTL` = 0x00200000: banco más
  alto 14 en las cuatro unidades, modo 0 (sin el swizzle de banco de nivel 1 de UBWC 1.0), acceso mínimo de 32 B,
  nivel 2 activo.
- `RBBM_NC_MODE_CNTL` se lee como 0xdeafbead: el CP no lo lee o no está implementado aquí [no verificado cuál].
- `RBBM_PERFCTR_CNTL` = 0, contadores apagados.
- `RB_CCU_CNTL` = 0x01000000.

Las unidades coinciden entre sí, que es lo que pide la corrección. Frente a kgsl (0x0b, 0x00a00000) faltan el bit de
modo y el acceso mínimo de 64 B. Frente a Linux (0x09) difieren el banco (13) y esos dos bits. Quién deja el 0x2 (el
valor de reset o el ABL) no está establecido.

### 2.2 Qué usa hoy el driver

[O, `96d9bac`] Todo render target es lineal (`render.cpp` `mrtWords`). Solo se comprimen las texturas de solo
lectura, compartidas, RGBA8 o BGRA8, de un nivel y de 65 536 píxeles o más (`hm_compress`, plug-in). Sus filas lineales
viven en una textura aparte y el motor 2D las copia a UBWC antes del primer draw que las muestrea (`freshen`). El
núcleo ya sabía dibujar en sysmem sobre un destino UBWC, pero rechazaba el Clear del motor 2D sobre él, la carga y el
guardado en tiles y la copia desde él (`render.cpp:1075`, `:2411`, `:2930`). El descriptor que lee un framebuffer
fetch en sysmem (`levelDescriptor`) no llevaba la disposición, y el swap de un destino UBWC era el del formato (WXYZ
para BGRA8), no WZYX. Las dos cosas solo importaban con render targets comprimidos, que no existían.

### 2.3 El prototipo `blur-tile`

**Qué texturas.** CoreAnimation crea sus intermedios en `CA::OGL::MetalContext::create_surface` [O, QuartzCore 20H392,
desensamblado `ios-graficos/ios-20H392/desensamblado`, 0x18830d2a4-0x18830d334]: descriptor 2D, `setUsage: 5`
(ShaderRead | RenderTarget), `| 2` (ShaderWrite) con el bit 14 de sus flags, `setStorageMode: 2` (Private) salvo el bit
19 (Shared), niveles de mip con 0x200, etiqueta «com.apple.coreanimation.surface». No pide `PixelFormatView`. Las dos
lecturas de textura por CPU de QuartzCore son `MetalContext::get_average_luma` (la cadena de luminancia, con mips) y
`_CAMetalTextureGetBytes` (0x1882fe3c4, 0x18847b4c4). Metal define la memoria privada como la que «will never be
accessed by the CPU directly» (`MTLResource.h`, SDK de iOS 16.5) y pide para su compresión con pérdida las mismas
condiciones de forma (`MTLTexture.h:241`).

**La regla del interruptor** (`hm_tile_for`, plug-in): con `metal_tile=1|2` en `metal.args` o en los boot-args,
storage Private, `allowGPUOptimizedContents`, uso RenderTarget sin ShaderWrite ni PixelFormatView, 2D, un nivel, una
muestra, RGBA8/BGRA8 o su par sRGB (UBWC: solo los dos unorm), ancho ≥ 16, no memoryless. Lo demás queda lineal: las
texturas sobre IOSurface o sobre buffer, las compartidas y la de luminancia con mips. Si el núcleo rechaza una, se crea
lineal y la consola lo dice una vez.

**En el núcleo** (`texture.hpp`, `texture.cpp`, `render.cpp`, `a6xx.hpp`; diff en `out/blur-tile/blur-tile.patch`):

| Pieza | Qué hace | Referencia |
|---|---|---|
| `TextureDesc::tiled`, `Texture::make`/`plan` | Pitch alineado a 256 B, filas a 16, capa a 4096. Sin filas para la CPU: `contents()` nulo, `read`/`replace` rechazan con el motivo | `fdl6_tile_alignment`, `fd6_layout.c:86-111` |
| `Texture::colorTile`, `colorSwap`, `layoutInto`, `flagPitchWord` | TILE6_3 y WZYX para tiled y UBWC. Flag buffer en los descriptores de muestreo, fetch y vistas | `fdl6_view_init`, `fd6_view.c:142-437`; `fd6_format_table.c:370-375` |
| `mrtWords` | `RB_MRT_BUF_INFO` en el layout; flags con `FLAG_MRTS` | `fd6_view.c:408-413` |
| `fillStream`/`clearStream` | Clear del motor 2D en el layout, con `RB_2D_DST_FLAGS` si es UBWC | `r2d_dst`, `tu_clear_blit.cc:396-413` |
| `encodeGmem` (blit) | Carga y guardado por evento blit en el layout; UBWC con `RB_BLIT_DST_INFO.FLAGS` y `RB_BLIT_FLAG_DST` | `tu_emit_blit` + `tu_cs_image_flag_ref`, `tu_image.cc:181-185` |
| `encodeBlit` | Fuente tiled o UBWC (`SP_PS_2D_SRC_INFO` tile y FLAGS, `SP_PS_2D_SRC_FLAGS`); destino tiled | `r2d_src`, `tu_clear_blit.cc:268-295` |
| `Texture::view`, `swizzled` | Conservan la disposición. Solo vista del todo en su formato o en su par sRGB (mismo swap); otra se rechaza | `is_mutable` de Mesa, `fd6_format_table.c:374` |
| Fake GPU | Juzga las escrituras, lecturas, cargas y guardados tiled (pitch, filas, alcance) sin ejecutarlos | — |
| Plug-in | `hm_tile_mode`, `hm_tile_for`, `hakios_metal_texture_new_tiled`, `origin=tiled` en la traza | — |

**Comprobado en el host** [O]: suite de 285 pruebas sin fallos con las constantes de los dos chips. Golden streams
iguales a los de `96d9bac` salvo dos líneas a propósito: el test nuevo, y el gemelo «tiled target told WXYZ» del fake,
que sustituye al antiguo «solo lineal». El stream sin `metal_tile` es palabra por palabra el de `merge-7`. El test
nuevo `a_tiled_target_is_drawn_cleared_copied_sampled_loaded_and_stored_in_its_layout` recorre pitch, filas,
descriptores, rechazos, vistas, el Clear en sysmem, el draw, el muestreo, las copias y una pasada GMEM con carga y
guardado.

**Conformidad.** Lo que cambia es la disposición en memoria de texturas que Metal declara inaccesibles para la CPU. Las
operaciones que CoreAnimation usa sobre ellas (render, Clear, Load/Store, muestreo, fetch, blits) leen y escriben lo
mismo. La única diferencia observable sería una lectura por CPU, que Metal no permite sobre memoria privada; el núcleo
la rechaza con el motivo en lugar de devolver otra cosa. Las vistas que reinterpretan el formato se rechazan por nombre
(no conforme, pero visible); CoreAnimation no las pide (no pone `PixelFormatView`).

**Riesgos.** (1) Que alguna unidad no comparta la configuración de banco o swizzle: lo detecta tilecheck. (2) Que el
evento blit de GMEM no acepte TILE6_3 de BGRA8 con WZYX como turnip supone: lo detecta tilecheck en las pasadas GMEM.
(3) Los dos rechazos de arriba: `grep 'tiled texture (TILE6_3)\|of a tiled'` en la consola. (4) Memoria: las filas a 16
añaden como mucho 15 filas por textura.

### 2.4 Parche de kernel 0370

`blur/parches-nuevos/0370-sapphire-gpu-ubwc-config.patch` (sha256 `b3117f48…`), integrado en la serie como
`xnu/patches/0370-sapphire-gpu-ubwc-config.patch` (idéntico byte a byte): boot-arg `gpu_ubwc=1|2` y sysctl
`kern.sweet_gpu_ubwc` (0 por defecto: no toca nada). `1` escribe los valores de kgsl en este teléfono (0x0b, 0x0b, 0x0b,
0x00a00000) y `2` los de Linux (0x09, 0x09, 0x09, 0x00800000, `RBBM_NC_MODE_CNTL` 0). Se aplica en cada arranque del CP
y, por sysctl, con la GPU ociosa y el cerrojo del servicio, como 0348; 0 repone los valores encontrados.
`kern.sweet_gpu_ubwc_regs` da los cinco registros ahora y como estaban. `GET_PARAM HIGHEST_BANK_BIT` responde el banco
vigente. Tras escribirlo en caliente hay que reiniciar backboardd: las imágenes ya hechas siguen en la disposición
anterior. Verificado: `git apply --check` limpio sobre 0001-0353 (y en la serie hasta 0380, que lo incluye) y
compilación de solo sintaxis con los stubs de `kernel-gpu/verificacion` (0 errores). No ejecutado aún en el teléfono.
No es prerrequisito de P3 (la GPU sola funciona con los valores de reset, §2.1); **sí lo es de la pantalla en UBWC**:
el DPU espera el bit de modo de kgsl (§2.8).

### 2.5 Prueba de corrección sin mirar la pantalla: `hakios-metal-tilecheck`

`tools/tilecheck.cpp` (en el diff), binario firmado ad hoc en `out/blur-tile/hakios-metal-tilecheck` (sha256
`e76011f8…`). Usa el núcleo del driver en un proceso propio, como `hakios-metal-probe`: cliente msm del kernel, sin
Metal ni CoreAnimation. Compila allí seis shaders pequeños desde el bitcode de `tools/kernels/*.ll` con el compilador
del driver, para el A610 y no con los fixtures del A635, que usan la precarga de texturas del FS que el A610 no tiene.
Solo interpreta texturas lineales. Hace tres cosas:

1. Lee por el CP (`CP_REG_TO_MEM`) `RB/TPL1/SP_NC_MODE_CNTL`, `UCHE_MODE_CNTL`, `RBBM_NC_MODE_CNTL`, `RBBM_PERFCTR_CNTL` y
   `RB_CCU_CNTL`, los decodifica como `a6xx_set_ubwc_config` y comprueba que el RB, el TP, el SP y la UCHE coinciden.
2. Para BGRA8 y RGBA8 a 752×1626, 99×209 y 270×12, repite la misma secuencia sobre un destino lineal, uno TILE6_3 y
   uno UBWC: Clear, draw, draw mezclado y fetch en sysmem; carga, dos draws mezclados y guardado en GMEM; Clear en
   tiles y guardado. Lee cada etapa por copia 2D y por muestreo a texturas lineales y compara byte a byte con el
   lineal. Además copia una imagen aleatoria al layout y de vuelta.
3. Mide (mediana de 7) el Clear de 756×1630, draw, mezcla y fetch a pantalla completa, muestreo 1:1 y a 1/4 con
   bilineal, carga y guardado GMEM de la pantalla entera y copias 2D, en cada layout. Es el dato que falta en 22 §6.5:
   lineal frente a tiled/UBWC en este teléfono.

**Resultado en el teléfono** [M, coordinador, kernel 0353 sin 0370, GPU a 820 MHz, `blur/tilecheck-1.txt`]:
- 0 fallos en las 3 × 2 × 2 secuencias (formato × tamaño × layout) y FAULTS 0 → 0.
- Los registros, en §2.1.
- Tiempos, mediana de 7 en µs, BGRA8:

| Operación | Lineal | TILE6_3 | UBWC |
|---|---|---|---|
| Clear de 756×1630 (motor 2D) | 676 | 559 | 383 |
| Draw a pantalla completa 752×1626 (escritura) | 718 | 562 | 385 |
| Draw mezclado (lectura + escritura) | 1 780 | 1 162 | 788 |
| Fetch en sysmem | 1 868 | 1 178 | 882 |
| Muestreo 1:1 hacia una textura lineal | 3 306 | 2 059 | 1 553 |
| Muestreo a 1/4 con bilineal | 842 | 643 | 431 |
| Carga + guardado GMEM de 752×1626 (39 tiles) | 1 319 | 1 081 | 614 |
| Copia 2D hacia fuera (a lineal) | 2 014 | 1 568 | 972 |
| Copia 2D hacia dentro (desde lineal) | 1 989 | 1 286 | 1 130 |

TILE6_3 ahorra un 18-38 % y UBWC un 43-55 %. Los dibujos de tilecheck son degradados y colores planos, muy
compresibles: con contenido que comprime peor, UBWC se acerca a TILE6_3. La dispersión es pequeña (mín-máx en el
fichero).

### 2.6 P2: clears más baratos

El Clear de 756×1630 cuesta 0,71 ± 0,03 ms (n = 13) y no depende del reloj, como corresponde a 4,93 MB escritos a
6,9 GB/s. Con TILE6_3 escribe los mismos bytes: el ahorro posible es de patrón de acceso, si lo hay (lo mide tilecheck,
«clear 756x1630»). Con UBWC, el motor 2D escribe bloques comprimidos y su flag buffer; el «fast clear» que Qualcomm
cita para UBWC sería que un bloque de un solo color se escribe como flag. Que el motor 2D del A610 lo haga así no
consta en ninguna fuente pública ni en Mesa; lo dice o no la fila «clear» de tilecheck en UBWC frente a lineal. El
alcance no cambia: el Clear sigue cubriendo el attachment entero (22 §4.1), así que es conforme. El recorte del
rasterizado al área de render (la otra mitad de P2 en 22) no tiene efecto en ninguna traza [O, 22 §4.1] y es un
arreglo de conformidad independiente.

### 2.7 P3 en CoreAnimation: lo que ganó el Centro de Control y por qué tan poco

[M, coordinador: trazas `metal_trace=frame` del Centro de Control con `blur-tile`, en `ios-graficos/trace/capturas-tile/`:
A y A2 sin interruptor (n = 3 + 3), B con `metal_tile=1` (n = 3), C con `metal_tile=2` (n = 2; la tercera, corta, no
cuenta). Análisis con `blur/tools25/ab.py` y `destinos.py`.]

**Qué texturas tocó.** Todas las privadas de CoreAnimation salieron `origin=tiled` (B) o `origin=compressed` (C):
capturas de 752×1626, pool de 756×1630, 64×64, 270×12, 138×306/307, 180×72/73, 97-99×207-209 y 72×8. Las de IOSurface
(la superficie de pantalla) y las compartidas no cambiaron, como manda el criterio.

**Por clase de pasada** (ms; media, salvo donde dice mediana):

| Clase | A | A2 | B (TILE6_3) | C (UBWC) |
|---|---|---|---|---|
| Captura 752×1626 + `Tmpc` | 4,18 (n 38) | 4,28 (39) | **2,97** (39) | **3,03** (27) |
| Captura sin filtro | 2,19 (15) | 2,25 (15) | 1,64 (12) | 1,69 (5) |
| Clear de 756×1630 + draws pequeños | 0,73 (9) | 0,75 (16) | 0,69 (13) | **0,40** (19) |
| Blur a resolución completa (mediana) | 2,35 | 2,40 | 2,10 | 2,02 |
| `downsample_8` desde la captura | 2,31 (11) | 2,25 (14) | **2,99** (10) | **2,76** (13) |
| Pasada principal | 8,88 (135) | 9,02 (135) | 8,86 | 8,75 |
| Vuelta a la pantalla en GMEM | 2,51 (201) | 2,50 (199) | 2,50 | 2,48 |
| Composición en sysmem | 1,63 (42) | 1,50 (39) | 1,70 | 1,47 |
| Pantalla + `luma_boost` | 2,55 (49) | 2,68 (51) | 2,51 | 2,32 |
| Fondos de módulos, offscreen GMEM | 0,43 (212) | 0,43 | 0,43 | 0,43 |

**Por frame** (frames de ≥ 4 pasadas; medias por captura):

| | A | A2 | B | C |
|---|---|---|---|---|
| GPU por frame | 19,45 / 19,65 / 19,53 | 19,69 / 19,80 / 19,77 | 19,32 / 19,01 / 19,12 | 18,85 / 19,09 |
| Pasadas a la pantalla | 13,99 | 14,01 | 14,05 | 14,09 |
| Pasadas a texturas privadas | 5,56 | 5,74 | 5,10 | 4,88 |
| …en frames con blur (54-57 frames) | 11,34 | 11,27 | 10,07 | 9,90 |
| …en frames sin blur (66-68) | 0,97 | 0,97 | 0,96 | 0,97 |

**Lectura.**
1. **El 72 % del tiempo** de un frame del Centro de Control va a pasadas cuyo destino es la superficie de pantalla:
   principal, vueltas, composición y `luma_boost`. Es una IOSurface lineal que el interruptor no toca.
2. **Más de la mitad de los frames** de cada captura son del Centro de Control abierto sin blur, donde las texturas
   privadas suman 1 ms.
3. **Donde actúa, actúa como en aislado**: −1,2 ms en la captura con filtro (−29 %), −0,55 en la sin filtro, −0,33 en
   el clear con UBWC, −0,3 en los blurs a resolución completa.
4. **`downsample_8` empeora** +0,45-0,68 ms (+20-30 %) al leer la captura en TILE6_3 o UBWC. Es su patrón: 16 muestras
   bilineales sobre una caja de 8×8 por píxel de salida, a 1/8. El muestreo a 1/4 de tilecheck no lo reproduce: allí
   TILE6_3 y UBWC ganan. Los contadores lo explican (abajo): ya en lineal relee 2,65 veces la textura, y en TILE6_3 4,1
   veces.
5. Neto sobre la textura de captura: −1,2 ms al escribirla, +0,6 al reducirla. **Lo que queda por ganar está en la
   pantalla.**

**Los contadores** [M, `blur-tile-ctr` con `metal_perf=1`, trazas `capturas-tile/T0` (lineal), `T1` (TILE6_3) y `T2`
(UBWC), n = 3 trazas cada una, 820 MHz]. Calibración: el guardado de la pantalla entera en el home quieto escribe
152 743 beats del GBIF = 4,89 MB con 32 B por beat, lo que mide la pantalla (750×1624×4 con el relleno de los
gránulos). **1 beat = 32 B** queda medido; todo va por AXI0 (rd1 = wr1 = 0).

| Clase (ms) | T0 lineal | T1 TILE6_3 | T2 UBWC | DDR leído / escrito por pasada (T0 → T1 → T2) | Fallos L1 TP |
|---|---|---|---|---|---|
| Captura + `Tmpc` | 4,07 | 2,92 | 2,98 | 10,0/10,4 → 9,9/10,0 → 7,4/3,8 MB | 28 → 36 → 36 % |
| Captura sin filtro | 2,06 | 1,40 | 1,44 | 4,7/5,1 → 4,5/4,6 → 4,7/1,8 MB | 30 % |
| Clear de 756×1630 | — | 0,66 | 0,39 | — → 0,03/4,95 → 0,03/**0,03** MB | — |
| `downsample_8` desde la captura | 2,18 | 2,77 | 2,67 | **13,0** → **20,1** → 13,4 MB leídos (útiles: 4,9) | 94 → 100 → 100 % |
| Principal (GMEM) | 8,55 | 8,76 | 8,84 | 16,3/4,9 MB, 2,9 GB/s | 26 % |
| Vuelta a la pantalla (GMEM) | 2,45 | 2,42 | 2,45 | 5,9/4,9 MB, 4,5 GB/s | 22 % |

Lo que dicen:
- **La captura mueve los mismos bytes en lineal y en TILE6_3**, y tarda un 28 % menos: pasa de 5,0 a 6,8 GB/s. Lo que
  gana es la eficiencia del acceso a DDR, no el volumen. Con UBWC escribe 2,7 veces menos (3,8 frente a 10,0 MB).
- **El clear en UBWC escribe solo los flags**: 0,03 MB frente a 4,95. Es el *fast clear*, y aun así tarda 0,39 ms.
- **`downsample_8` relee la textura**. Para leer 4,9 MB útiles trae de DDR 13,0 MB en lineal (2,65 veces) y 20,1 en
  TILE6_3 (4,1 veces). Todo llega al TP por la UCHE (`uche_rd_tp` = bytes de DDR). Casi todas las peticiones fallan en
  el L1 del TP: 652 000 de 696 000 en lineal; 921 000 de 925 000 en TILE6_3, donde además hay un 33 % más de
  peticiones. En UBWC trae 13,4 MB y sus lecturas no pasan por el contador de la UCHE.
  Es decir: ni el L1 ni la UCHE retienen las líneas entre los muestreos que las comparten, y la disposición en bloques
  multiplica las peticiones. El coste de `downsample_8` es la relectura, no la disposición. [H] El conjunto de trabajo
  (cientos de fibras en vuelo × 16 muestras bilineales sobre cajas de 8×8 de una fila de 3 KB) no cabe en el L1. Si
  dibujar esa pasada en GMEM, con los fragmentos en orden de bins, reduce la relectura lo dirán D2/D3.
- **La pasada principal no está limitada por el ancho de banda**: 2,9 GB/s de 12,4 de pico. Sus 8,5-8,8 ms son el
  coste por tile y el sombreado (10, 14), no la memoria.
- Los contadores no cambian el tiempo de forma visible: D0 (`blur-diag` sin `metal_perf`) da 19,80 ms por frame (n = 3);
  T0, 19,26 y 19,20 (la tercera traza está cortada). Son sesiones distintas, así que no hay comparación limpia.

**Conformidad observada.** Capturas de pantalla del Centro de Control abierto iguales en A, B y C
(`medicion/shots/tile-{A,B,C}-0.png`, coordinador). Ninguna línea de rechazo en la consola [no se ha contado aún].

### 2.8 La superficie de pantalla en UBWC: viabilidad y plan

**El display la puede leer** [R, Linux v6.12 en `display/ref/linux-v6.12`]:
- El MDSS del SM6115 (bengal; el SM6225 «khaje» es de la misma familia y su DT da los mismos números) es UBWC 1.0 al
  codificar y 2.0 al descodificar, con swizzle 7, `ubwc_static` 0x11f y banco 1 (= 14) (`sm6115_data`,
  `msm_mdss.c:649-656`).
- El DT del teléfono declara lo mismo: `qcom,sde-ubwc-version = <0x10000000>`, `qcom,sde-ubwc-static = <0x11f>`,
  `qcom,sde-ubwc-swizzle = <0x07>`, `qcom,sde-highest-bank-bit = <0x01>` (`relojes/dtb/merged-khaje24a-sapphire.dts:15255-15258`).
- Con descodificador 2.0, Linux escribe `UBWC_STATIC` (MDSS +0x144) con 0x11f (`msm_mdss.c:172-177`, `:318-324`).
- Un plano acepta el modificador `QCOM_COMPRESSED` en ARGB/XRGB/ABGR/XBGR8888 si el MDSS tiene UBWC (`dpu_plane.c:60-71`,
  `:1357-1370`).
- Para un formato UBWC, el SSPP se programa así (`dpu_hw_sspp.c:271-300`): `SRC_FORMAT` con el modo de fetch en los
  bits 30-31, `OP_MODE` con `BWC_EN`, `SSPP_FETCH_CONFIG` = 0x87 | banco << 18, y `SSPP_UBWC_STATIC_CTRL` = fast clear
  (bit 31, con alfa) | swizzle & 1 | bit 8 (UBWC 1.0) | banco << 4.
- Planos: SRC0 recibe el bitstream, que va tras el meta; SRC2 recibe el meta, al principio del buffer
  (`dpu_formats.c:331-356`). Cada plano va alineado a 4096 (`DPU_UBWC_PLANE_SIZE_ALIGNMENT`, `:14`).
- Es la misma disposición que `fdl6_layout` da a una imagen RGBA8 de un nivel con UBWC (flags primero, filas a 16
  «other participants expect 16», `fd6_layout.c:213-218`). Que los alineamientos de pitch del display
  (`VENUS_RGB_STRIDE`/`_META_STRIDE`) sean exactamente los de fdl6 está por comprobar: su definición no está en la copia
  local de Linux [no verificado].
- El DPU no lee TILE6_3 sin compresión en RGB: los formatos tiled del DPU son los UBWC (`MDP_FETCH_UBWC`). Para la
  pantalla, UBWC o nada.

**Cabe en el pool.** Para 750×1624: datos 3 072 × 1 632 = 5 013 504 B y meta 64 × 416 = 26 624 → 28 672 B; en total
5 042 176 B. Un hueco del pool de 0354 tiene 5 MiB (5 242 880 B; 18 §3.1).

**Coherencia GPU ↔ DPU.** UBWC 1.0 con swizzle 7 espera el swizzle de banco de nivel 1, que en la GPU es el bit de modo
de `*_NC_MODE_CNTL`. Hoy la GPU lo tiene a 0 (§2.1): escribiría UBWC que el DPU leería mal [H, por las fórmulas de
`fd6_tiled_memcpy.cc`]. Con kgsl el bit está a 1 (0x0b). **0370 con `gpu_ubwc=1` es prerrequisito.** Además, el MDSS
debe tener `UBWC_STATIC` = 0x11f: nuestro kernel no lo escribe y no se ha leído qué dejó el ABL [no verificado].

**Quién lee la pantalla por CPU.** CoreAnimation, en uso normal, no la lee. Las capturas de pantalla y los snapshots
vuelven a dibujar el árbol de capas en otra superficie con la GPU: `CA::WindowServer::Display::render_display(CA::OGL::Renderer&,
CA::Render::Update*)`, `render_display_layer`, `_CARenderServerSnapshot` (QuartzCore 20H392, nombres en el
desensamblado) [H fuerte por los nombres y la firma; sin comprobar en el teléfono]. Los usos de `IOSurfaceLock` en
QuartzCore son del renderer por software, de imágenes, de depuración (`_CAIOSurfaceWriteToFileWithSuffix`) y de
`-[CAWindowServerDisplay hitTestAtPosition:options:]` con la opción «LayerBackgroundStatistics», que queda sin aclarar
[O nombres]. Fuera de CoreAnimation:
- Nuestras herramientas: `fbshot` lee la IOSurface en crudo, y con UBWC leería bytes comprimidos.
- La copia del kernel al panel (`kern.sweet_fb_scanout=2` o un frame que no encaja): lee la superficie con el motor 2D
  y tendría que leerla como UBWC (flags en su blit).

**Qué ganaría** [H, con las medianas de tilecheck; cota inferior con TILE6_3, porque la compresión depende del
contenido]:

| Pasada sobre la pantalla (ms en A) | Mecanismo | UBWC | Cota (TILE6_3) |
|---|---|---|---|
| Principal (8,88; GMEM, carga y guardado) | carga + guardado de 4,9 MB | −0,7 | −0,24 |
| 2 vueltas por frame (2,5 cada una) | ídem | −1,4 | −0,5 |
| `luma_boost` (2,55; fetch en sysmem) | fetch + escritura | −1,0 | −0,7 |
| Composición (1,63; escritura o mezcla) | escritura | −0,3 a −1,0 | −0,15 a −0,6 |
| Capturas que leen la pantalla (TP) | lectura | ~−0,5 | ~−0,3 |
| **Por frame con blur** | | **−3 a −4,5** | **−1,5 a −2** |
| Por frame del Centro de Control abierto (principal + 2 vueltas) | | −2,1 | −0,7 |

El escaneo del panel también lee menos DDR: 4,9 MB por refresco sin comprimir, 590 MB/s a 120 Hz.

**Plan** (sin implementar):
1. **Diagnóstico** (0393, escrito: `blur/parches-nuevos/0393-sapphire-fb-regs-mdss-ubwc.patch`; `git apply --check`
   limpio sobre 0001-0380). `kern.sweet_fb_regs` (0349) gana un bloque «MDSS» (0x5e00000, 0x160 B) con `HW_REV`,
   `UBWC_DEC_HW_VERSION` (+0x58) y `UBWC_STATIC` (+0x144). Los registros UBWC del VIG0 ya estaban en ese volcado:
   `SSPP_UBWC_STATIC_CTRL` (+0x44), `SSPP_FETCH_CONFIG` (+0x48), `SSPP_UBWC_ERROR_STATUS` (+0x138). Las lecturas de M18
   en adelante (`display/telefono/regs-scan.txt`) dan, como dejó el ABL: `SRC_FORMAT` 0x000237ff (fetch lineal),
   `SSPP_UBWC_STATIC_CTRL` 0xc0000101, `SSPP_FETCH_CONFIG` 0x00000087 (banco 0 en los dos) [O].
2. **0370 con `gpu_ubwc=1`** y tilecheck otra vez: corrección con los valores de kgsl.
3. **Kernel** (0394 en adelante, tras `kern.sweet_fb_ubwc`, apagado por defecto; después de tener la lectura de 0393 y
   tilecheck con `gpu_ubwc=1`):
   - Las superficies del pool, con la disposición UBWC dentro de su hueco y una marca en la información de superficie
     que recibe el cliente de la GPU (`HakiosSurface` → `SurfaceInfo`).
   - El VIG0 programado como `dpu_hw_sspp.c` para UBWC: SRC0, SRC2, strides, `FETCH_CONFIG`, `UBWC_STATIC_CTRL`,
     `BWC_EN`.
   - `UBWC_STATIC` = 0x11f si el ABL no lo dejó así.
   - El blit de la copia con fuente UBWC (`SP_PS_2D_SRC_INFO.FLAGS` y `SP_PS_2D_SRC_FLAGS`).
   - Un contador de `SSPP_UBWC_ERROR_STATUS` por flip: detecta una descodificación mala sin mirar la pantalla.
4. **Driver**: `Texture::wrapSurface` crea una textura UBWC cuando la superficie lo dice (`fdl6_layout` sobre la memoria
   de la superficie). Las rutas de render, Clear, carga y guardado, fetch, muestreo y copia ya están en `blur-tile`.
5. **Prueba**:
   - 0 errores UBWC del SSPP.
   - Una captura por re-render (botones) y la vista.
   - Trazas A/B (n ≥ 3) con el desglose de `destinos.py`: deben bajar las pasadas a la pantalla.
   - `fbshot` deja de servir con UBWC: hace falta una captura por la GPU.

**Riesgos.**
- Lectores por CPU que no se han visto.
- Un desacuerdo de banco o swizzle entre GPU, DPU y lo que dejó el ABL: imagen rota, que el contador del SSPP
  detectaría.
- La copia por el kernel.
- Memoria: igual (el hueco ya es de 5 MiB).

## 3. P4, P5, P7 y P8: carga, guardado, modo de cada pasada y trabajo tapado

### 3.1 P4: cargar y guardar solo los bins con geometría

**Referencias** [R, Mesa 25.0.7]. Turnip permite la carga condicionada si el attachment se carga, no se limpia y no se
resuelve, y el guardado condicionado si se guarda y no se limpia (`tu_render_pass_cond_config`, `tu_pass.cc:540-565`).
En cada tile, con binning, pone un `CP_REG_TEST` del bit del bin en `VSC_STATE_REG(pipe)` (`tu6_emit_cond_for_load_stores`,
`tu_cmd_buffer.cc:1037-1049`) y envuelve cada evento blit de carga o guardado en `CP_COND_REG_EXEC` con `PRED_TEST`
(`tu_clear_blit.cc:4753-4771`, `:4826-4849`, `:5205-5218`). No lo hace si el stream de draws escribe el predicado
(consultas de rendimiento, `tu_cmd_buffer.cc:4598-4605`). Freedreno hace lo mismo con las IB de carga y guardado de
cada tile (`emit_conditional_ib`, `fd6_gmem.cc:826-873`, usada en `:1686` y `:1901`), salvo si el batch se limpió o no
hay binning por hardware.

**Conformidad.** Un bin sin primitivas visibles no cambia en la pasada: no cargarlo ni guardarlo deja la memoria como
estaba. Deja de ser conforme si la pasada limpia (el Clear escribe todo el attachment, 22 §4.1), si resuelve, o si la
visibilidad está incompleta (desbordamiento del VSC, N-19 de 19 §2.9).

**Lo que da con n ≥ 3** [M, `bins2.py` sobre `capturas-cc-4cond`, 820 MHz]:

- Home quieto (24 draws, n = 30): 1,82 ms. Un draw de geometría desconocida (el `attachment_clear`) lleva la cota
  superior al 100 % de bins; sin él, la mediana es el 3 %. Si ese draw es el rectángulo de 64×96 que 22 leyó de su
  buffer de vértices, quedan 2-3 bins: ~0,1-0,2 ms por frame. Es ahorro en reposo (energía), no en el blur.
- Vueltas a la pantalla del Centro de Control (n = 447): todas las geometrías conocidas, y la mediana de bins con
  geometría es del 86 % (cota inferior) al 100 % (superior). El ahorro es como mucho el 14 % de la carga y el guardado
  de esas pasadas: ≤ 0,3 ms por pasada.
- Pasada principal (n = 238): 85-99 %.

**Diseño sobre `96d9bac`.** En `render::encodeGmem`, dentro de cada tile y tras `CP_SET_BIN_DATA5` (donde ya escribe
`CP_SKIP_IB2_ENABLE_LOCAL`), un `CP_REG_TEST` de `VSC_STATE_REG(pipe)` con el bit del hueco del tile, y la lambda `blit`
envuelta en `CP_COND_REG_EXEC(PRED_TEST, palabras)` para cargas y guardados. Condiciones como turnip: hay paso de
binning (`vsc != 0`), ningún attachment se limpia en tile (`clear == 0`), no hay resolve, y el VSC no se ha desbordado
en los frames recientes (`CommandQueue::checkVsc`, que ya existe). El fake necesita `CP_REG_TEST` y `CP_COND_REG_EXEC`
para ejecutarlo. Sin prototipo: con estos datos, P4 no es prioridad para el blur.

### 3.2 P5: GMEM o sysmem por bytes

**Referencia** [R]. El autotune de turnip compara `sysmem_bandwidth = bytes_por_píxel_sysmem × píxeles + tráfico de los
draws` con `gmem_bandwidth = (bytes_por_píxel_gmem × píxeles × 11 + tráfico de los draws) / 10` (`tu_autotune.cc:596-613`).
El tráfico de los draws lo mide con `ZPASS_DONE`. Fuerza GMEM cuando una pipeline lee el destino en sysmem: «should
cause significantly increased SYSMEM bandwidth» (`:550`).

**Hoy** [O]. `render::gmemWorth` (`render.cpp:2532`) usa esa desigualdad con el tráfico de los draws proporcional a su
número. Manda a sysmem toda pasada de menos de 5 draws, incluidas la captura con filtro por fetch (4 draws) y los blurs
a resolución completa con fetch. Esas pasadas cuestan 4,13 ms (captura) y 4,1-5,1 ms (blur vertical + `Tc33`) y no
dependen del reloj (§1).

**Lo que falta saber, y cómo se mide sin build nuevo.** Cuánto cuestan esas pasadas en GMEM. El interruptor
`metal_gmem_draws=1` ya manda a tiles todo lo que puede, y `metal_gmem_draws=0` todo a sysmem. Con `blur-diag` y
`metal_perf=1`, las condiciones D2 y D3 del protocolo (§7) dan, por clase de pasada, el tiempo y los bytes de DDR en
cada modo.

**Diseño.** `gmemWorth` con el tráfico de los draws estimado en bytes: el área de cada draw (`render::drawArea`, que ya
existe) por los bytes por píxel, doble si mezcla o lee el destino. En GMEM, la carga y el guardado de lo que se toca
más un coste fijo por tile. Las constantes, de las medidas D2/D3. La elección de modo no cambia lo que se dibuja: es
conforme.

### 3.3 P7: la copia 1:1 de la pantalla como segundo resolve

**Referencia** [R]. Turnip guarda un bin a dos destinos al final del tile, el resolve primero y luego el guardado
(`tu6_emit_tile_store`, `tu_cmd_buffer.cc:1262-1301`, `tu_store_gmem_attachment` con destino `a` o `gmem_a`).

**Dónde aplicaría** [M, n = 1 por gesto]. Solo a la copia de cada frame de la vista de widgets (e6 de 22 §1.3,
2,0 ms). No aplica a la captura del Centro de Control: copia con 1 px de desplazamiento.

**Condiciones de exactitud.** Al cerrar el command buffer, la pasada N+1 es un único draw de copia con filtro nearest,
mismo tamaño y formato, coordenadas en centros de píxel, sin mezcla, que cubre todo su destino. Su fuente es el target
de la pasada N, que va en GMEM. Nada entre medias lee ni escribe ninguno de los dos. La geometría tiene que leerse
cuando el buffer de vértices ya es definitivo: al confirmar el command buffer, no al codificar.

**Conformidad.** El contenido final de las dos texturas es el mismo.

**Riesgo.** Alto: es un mecanismo nuevo, y la condición «nada entre medias» se decide en `closePass` sobre el command
buffer entero.

**Prioridad.** Baja: 2 ms por frame en una sola vista, sin n ≥ 3.

### 3.4 P8: lo que tapa la pasada principal

Dos cosas distintas que 22 junta.

**(a) No cargar lo que un draw opaco cubre entero.** Si un draw que no mezcla, no lee el destino, no descarta
fragmentos y escribe todos los canales cubre el target entero, lo cargado antes no se observa: conforme. Para que sea
seguro sin más análisis, ese draw tiene que ser el primero del pase, o todos los anteriores tienen que estar libres de
efectos laterales y escribir solo ese attachment. Ningún driver de Mesa lo deduce de la geometría. Freedreno omite la
restauración de GMEM solo cuando la API dice que el contenido no vale o se limpió antes de cualquier draw
(`batch->invalidated`, `batch->cleared`, `freedreno_draw.c:58-185`, `:400-440`). Turnip solo mira las load ops de la
API. Lo nuestro sería nuevo, y depende de conocer en la CPU la cobertura exacta: posiciones del buffer de vértices por
la `mvp_matrix` de `[[buffer(2)]]`, una convención de CoreAnimation, no un contrato (22 §1, `trace-frame.py`).
Ahorro: una carga de pantalla (~0,7 ms) en las pasadas donde ocurre.

**(b) Descartar draws tapados.** Bajo la regla del «como si», un driver puede omitir trabajo cuyo efecto no se observa.
Las condiciones son las de 19 §3.4: el oclusor no mezcla ni lee, sin `discard`, máscara completa, cobertura conocida,
nada intermedio que lea, sin efectos laterales ni consultas de oclusión. Lo hacen en hardware las GPU de Apple (HSR) y
Mali (Forward Pixel Kill); ningún driver de Mesa lo hace en software [R: ni turnip ni freedreno tienen un paso así]. Aquí
exigiría las posiciones de los vértices al confirmar el command buffer, no al codificar: Metal permite escribir un
buffer compartido después de codificar el draw y antes del commit. El beneficio que 22 da (88-91 draws y 15,4 Mpx
tapados en los frames con el Centro de Control abierto) sale de una traza [no verificado con n ≥ 3, A10]. Los frames sin
blur del Centro de Control abierto cuestan 15,5 ms (n = 135), así que el techo es real, pero el riesgo de conformidad
también.

**Recomendación.** Primero (a), solo con el primer draw del pase y solo cuando su cobertura del target entero se
demuestre con la geometría leída al confirmar. (b), después de medir con n ≥ 3 cuánto tapa de verdad.

## 4. P9: olas de 64 o de 128 en el fragment shader

**Lo que declara Mesa** [R, 25.0.7]:

- La fila del A610 hereda de `a6xx_gen1_low` `supports_double_threadsize = False` (`freedreno_devices.py:367`),
  `reg_size_vec4 = 48` (:354) y los valores por defecto `threadsize_base = 64` y `max_waves = 16` (:140-141). `has_dp2acc`
  no lo pone ninguna plantilla que use el A610: no hay instrucciones de producto escalar acumulado, lo que no afecta al
  tamaño de ola.
- **Turnip** fija `IR3_SINGLE_ONLY` para todas las etapas en un chip sin `supports_double_threadsize`
  (`tu_shader_key_subgroup_size`, `tu_shader.cc:2953-2962`, llamado por etapa en `tu_pipeline.cc:1720`): en el A610 el
  FS de turnip va con olas de 64.
- **Freedreno** (GL) crea todo shader gráfico con `IR3_SINGLE_OR_DOUBLE` (`ir3_gallium.c:378-383`) y usa
  `supports_double_threadsize` solo para el cómputo (`ir3_gallium.c:307-309`, `fd6_program.cc:174`). Su FS lleva
  `THREADSIZE = THREAD128` cuando ir3 lo elige (`fd6_program.cc:121-122`, `:159-163`), y ir3 lo elige para el FS si
  `registros × 2 ≤ reg_size_vec4` (`ir3_should_double_threadsize`, `ir3.c:113-163`).

Así que la afirmación de 22 («un chip que Mesa declara sin doble ola») vale para el cómputo y para turnip, no para el FS
de freedreno. En la práctica, el A610 ejecuta FS de 128 fibras con freedreno en Linux.

**Lo que hace el driver** [O, `96d9bac`]. Compila con `IR3_SINGLE_OR_DOUBLE` (`compiler.cpp:760-764`, «tu_shader.cc's
SINGLE_OR_DOUBLE»), como freedreno y no como turnip. Programa `SP_FS_CTRL_REG0.THREADSIZE` y `HLSQ_FS_CNTL_0.THREADSIZE`
con lo que decide ir3 (`render.cpp:1941`, `:2114-2133`). En el cómputo sigue a freedreno: `HLSQ_CS_CNTL_1` a THREAD128 y
el tamaño real en `HLSQ_FS_CNTL_0` (`compute.cpp:442-457`).

**Lo que cambia de verdad.** El número de fibras residentes por registro es el mismo con olas de 64 o de 128:
`ola × ⌊48 / (r × ola/64)⌋`. A 12 registros: 4 × 64 = 2 × 128 = 256 fibras. Lo que cambia es el objetivo del reparto de
registros: con olas de 128 los escalones están en 24, 12 y 8 registros; con olas de 64, también en 16, 9… En
`downsample_8`, ir3 con `SINGLE_ONLY` baja de 12 a 9 registros, 320 fibras frente a 256 (+25 %), a cambio de 11 ciclos
(22 §2, listados en `blur/ir3/ir3c/`) [O host]. El efecto en tiempo no está medido.

**Experimento que lo decide.** Un build con `real_wavesize = IR3_SINGLE_ONLY` solo para el FS, tras un interruptor que
entre en el nombre del stage en caché (`stageCacheName`, para no mezclar stages) o con otra `CACHE_BUILD`. La primera
sesión recompila. A/B en la misma traza del Centro de Control (n ≥ 3 por condición, tras un uso completo previo):

- Las pasadas con `downsample_8` (2,25 ± 0,12 ms hoy) y `variable_blur`.
- La pasada principal (el uber shader especializado, que puede bajar de registros o no).
- Capturas de pantalla idénticas.

Si `downsample_8` baja más que su dispersión (±0,12 ms) y nada sube, se adopta lo que hace turnip; si no, se queda como
está. El cambio de clave obliga a recompilar la caché entera: hacerlo junto con P1.

## 5. La medición que falta (22 §6.2): contadores por pasada

**Implementado** (rama `blur-diag` sobre `96d9bac`, diff `out/blur-diag/blur-diag.patch`; también dentro de
`blur-tile-ctr`):

- `CommandBuffer::setPerf`, `perfStamp` y `PassTime::ctr` en `command.hpp`/`command.cpp`.
- C API `hakios_metal_cb_set_perf`, `hakios_metal_cb_pass_counters` y `hakios_metal_perf_counter_name`.
- Plug-in `hm_perf_on` (`metal_perf=1`) y `hm_perf_text`.

**Funcionamiento.** Con `metal_perf=1` y `metal_trace=frame` o `metal_fps=passes`, cada command buffer perfilado hace,
una sola vez, un WFI y escribe desde su stream `RBBM_PERFCTR_CNTL = 1`, los cuatro bytes de `GBIF_PERF_CNT_SEL`, el
enable `GBIF_PERF_PWR_CNT_EN` y nueve selectores. Junto a cada sello de tiempo existente (inicio y final de pasada)
lee 13 contadores con `CP_REG_TO_MEM`.

| # | Contador | Countable | Para qué |
|---|---|---|---|
| 0-3 | `GBIF_PERF_CNT_LOW0-3` (0x3cc4-0x3cc7) | AXI0/AXI1 read data beats 34/35, write 46/47 (KGSL `a6xx_reg.h:856-859`) | Bytes de DDR de la pasada |
| 4-5 | `RBBM_PERFCTR_UCHE_0/1` (0x476, 0x478) | `VBIF_READ_BEATS_TP` 4, `READ_REQUESTS_TP` 9 | Lo que lee el TP de memoria |
| 6-7 | `RBBM_PERFCTR_TP_0/1` (0x48e, 0x490) | `L1_CACHELINE_REQUESTS` 6, `MISSES` 7 | Localidad de las lecturas de textura (lineal frente a tiled) |
| 8-9 | `RBBM_PERFCTR_CCU_0/1` (0x45c, 0x45e) | `COLOR_BLOCKS` 5, `COLOR_BLOCK_HIT` 7 | Caché de color en sysmem |
| 10-12 | `RBBM_PERFCTR_RB_0/1/2` (0x4d6-0x4da) | `C_READ` 14, `C_WRITE` 15, `STALL_CYCLES_CCU_COLOR_WRITE` 35 | Lecturas y escrituras de color y esperas |

Los offsets y countables salen de Mesa 25.0.7 `a6xx.xml.h` (`REG_A6XX_RBBM_PERFCTR_CCU/UCHE/TP/RB`, `:3091-3103`;
selectores `:3949`, `:6807-6809`, `:10194`; GBIF `:4090-4123`; countables `:767-1040`). La programación del GBIF
(selección un byte por contador, enable un bit) sigue a KGSL (`a6xx_counter_gbif_enable`, `adreno_a6xx_perfcounter.c`,
copia en `blur/fuentes/kgsl-f900d903/`). No toca el contador 0 del CP ni el del RBBM, los que usa `gxfreq`.

Las diferencias por pasada salen en las líneas `gpass` de la traza (`ctr=gbif_rd0=…,…`) y en las `passes:`. Sin
`metal_perf=1` el stream es el de `merge-7`: golden iguales en los dos chips, test nuevo
`perf_counters_are_selected_once_and_read_around_each_pass`.

**No hace falta kernel.** Nuestro kernel no protege registros (`hw_init_regs` no escribe `CP_PROTECT_*`) y `gxfreq` ya
escribe `RBBM_PERFCTR_CNTL` desde un IB (03 M3). Si el kernel llegara a proteger registros como Linux, que bloquea
0x3c00-0x3cc3 (22 `fuentes-mesa.md` §8.2), habría que dejar pasar los selectores del GBIF o reservarle los contadores.
Un parche que escriba `RBBM_PERFCTR_CNTL = 1` en `hw_init_regs`, como Linux y kgsl, es opcional.

**Cómo se lee.** `blur/tools25/ab.py` pasa los beats a bytes con 32 B por beat [H, por el `bus_width` 32 de KGSL]. La
calibración está en la propia traza: un clear de 756×1630 escribe 4,93 MB. Si los beats × 32 no dan eso, se corrige el
factor.

Qué decide cada resultado, sobre la captura con filtro (4,13 ms) y `downsample_8` (2,25 ms):

- Bytes de DDR ≈ útiles (9,8-19,6 MB y 4,9 MB) y a un ritmo cercano al pico: manda el DDR, y TILE6_3 no ayuda.
- Bytes ≫ útiles, o tasa de fallos del L1 del TP alta y que baja con `metal_tile=1`: manda la disposición, y P3 es el
  camino.
- Ni lo uno ni lo otro: latencia u ocupación (P9).

## 6. P1: la semilla de shaders

**Qué es enumerable sin el teléfono** [O]:

- El catálogo de QuartzCore 20H392: 1 079 pipelines (`ios-graficos/qc-20H392/pipelines/summary.json`), con 444
  variantes de fragmento y 7 de vértice ya especializadas en `default.pipelinelib/functions`
  (`rebuild/cpu-tools/variants`, 451 ficheros).
- El plug-in compila cada variante con las constantes que CoreAnimation le pasa al crear la pipeline (en la traza,
  `fs_fc="4=1 6=2 30=54"`, `pipe` de `capturas-cc-4cond`) y con el `IBO_BASE` del VS.
- La clave es un hash de la `CACHE_BUILD`, el tamaño de `Stage` y `Kernel` (1 448 y 848 B en el host y en iOS), el
  `IBO_BASE`, el bitcode, las constantes y el buffer conocido (`stageCacheName`, `compiler.cpp:1180`).

**Qué no lo es.**

- Los pipelines «own(no variant)» que CoreAnimation crea en ejecución con combinaciones de constantes fuera del
  catálogo (por ejemplo `TmuaA2Xhfn_Isrc_Isqr` en la misma traza).
- Las especializaciones del uber shader genérico por los 34 bytes que la compilación lee de los 52 de
  `FragmentShaderConfig` (13 §10.6). En el teléfono, el índice `.known` tenía 11 configuraciones con `merge-7` y las
  trazas de 22 mostraban 19.

Unas y otras son finitas en la práctica y se recogen del teléfono: líneas `pipe` de la traza y registros `.known`.

**Coste en el host** [M, i5-7500, `stagecc` con la clave del teléfono]: las 451 variantes compilan en 15,7 s de reloj
lanzando un proceso por función. Cada compilación son 1-2 ms; el resto es arrancar el proceso. Salen 377 stages
distintos, 3,4 MB. El uber shader genérico tarda 172-193 ms por configuración en el host y 0,43-1,1 s en el teléfono
(13 §10.6).

**La clave no coincide todavía** [M]. De los 377 nombres que genera el host con la clave del teléfono, ninguno está en
la caché del teléfono (1 374 `.stage`, leída por `ssh ls` el 2026-11-14), ni siquiera el del VS más simple sin
constantes (`vert.VfxXh`, `fixed_vert_lph_spc`). Coinciden los tamaños, la `CACHE_BUILD`, el `IBO_BASE` y las
constantes. La entrada que queda es el bitcode: el que el plug-in obtiene de Metal en el teléfono no es byte a byte el
de la función en el fichero `.metallib` [H, el riesgo que 22 §7 ya nombraba]. Para comprobarlo hace falta que el
plug-in escriba, una vez por stage, el sha256 de los primeros bytes del bitcode y el nombre de la caché, y comparar con
el host.

**Diseño que cumple el requisito del usuario** (nada se compila en uso; el arranque puede tardar):

1. **Dónde corre.** En backboardd, al crear el dispositivo Metal y antes del primer frame de CoreAnimation, con el
   logotipo de arranque en pantalla. El plug-in recorre la pipeline library de QuartzCore con los mismos objetos
   `MTLFunction` y el mismo camino de bitcode que usará después, así que las claves coinciden por construcción. Lo hace
   en hilos de fondo, y CoreAnimation no dibuja hasta que terminan.
2. **Qué recorre.**
   - Las 451 variantes con las constantes de cada uno de los 1 079 descriptores del catálogo.
   - Una lista persistente de lo visto en uso: pipelines «own» (sus constantes) y configuraciones del genérico (las
     máscaras y valores del `.known`), que crece en cada sesión y se compila en el arranque siguiente.
   - Coste estimado en el teléfono: 451 × 2-12 ms ≈ 1-5 s, más 11-19 genéricos × 0,4-1,1 s ≈ 5-20 s; [H] hasta medirlo.
3. **Dónde guarda.** La caché escribible de siempre, en un subdirectorio por `CACHE_BUILD`:
   `/private/var/db/hakios-metal-cache/<CACHE_BUILD>/`. Lo de otra clave se puede borrar entero sin riesgo. La semilla
   de solo lectura (`HAKIOS_METAL_CACHE_SEED`, `/redwood/share/…`) se llena en el build cuando el host reproduzca las
   claves.
4. **Cómo se invalida.** La clave cambia con el compilador (`CACHE_BUILD` es el hash de `compiler.cpp`, las cabeceras y
   los `.a` de Mesa). Si cambia, el directorio nuevo está vacío y el arranque siguiente lo llena. La lista de lo visto
   en uso no depende de la clave: guarda nombres de función, constantes y bytes, no stages.
5. **En uso**, una pipeline que falte en la caché sigue el camino actual (genérico mientras compila en segundo plano) y
   entra en la lista para el arranque siguiente. La consola lo cuenta, porque es un fallo del requisito.

## 7. Orden recomendado y protocolos de prueba

| Paso | Qué | Necesita | Medida y n | Decide | Estado |
|---|---|---|---|---|---|
| 1 | `hakios-metal-tilecheck --reps 7` | `out/blur-tile/hakios-metal-tilecheck`; nada instalado | 0 FAIL; tiempos por layout | Corrección de TILE6_3/UBWC y ganancia en aislado | Hecho: 0 FAIL (§2.5) |
| 2 | A/B/C: `metal_tile=0/1/2` | `out/blur-tile` | CC, n = 3 | P3 en CoreAnimation | Hecho: −0,4 a −0,7 ms por frame (§2.7) |
| 3 | T0/T1/T2: lo mismo con `metal_perf=1` | `out/blur-tile-ctr` | CC, n = 3 por condición, `ab.py` | Por qué empeora `downsample_8`; bytes por clase | En cola |
| 4 | D0/D1: coste de los contadores | `out/blur-diag` | n = 3 + 3 | Que `metal_perf` no deforma lo medido | En cola |
| 5 | D2/D3: `metal_gmem_draws=1/0` | `out/blur-diag` | n = 3 + 3 | Constantes de P5 | En cola |
| 6 | 0370 con `gpu_ubwc=1` + tilecheck | kernel con 0370 | 0 FAIL; tiempos | Los valores de kgsl en la GPU (prerrequisito de 8) | — |
| 7 | 0393: lectura de MDSS `UBWC_STATIC` | parche de diagnóstico (escrito) | una lectura | Qué dejó el ABL en el display | Escrito; lo integra el coordinador |
| 8 | Pantalla en UBWC (0394+ y driver) | 6 y 7 | errores UBWC del SSPP = 0; capturas; n = 3 con `destinos.py` | La palanca grande (§2.8) | Diseño |
| 9 | P5 implementado | 5 | n = 3 | — | — |
| 10 | P1: precompilación al arrancar | comprobar la clave (§6) | primera apertura tras instalar: 0 `compile_ms` > 5 | — | Diseño |
| 11 | P9: FS `SINGLE_ONLY` | build nuevo (con P1) | n = 3 | Tamaño de ola | Diseño |
| 12 | P7, P4, P8 (a) | builds nuevos | n = 3 | — | — |

**Condiciones comunes** (las de 03 M24): kernel 0353, `kern.sweet_gpu_khz=820000`, salida por copia con pool,
actualizaciones parciales activas, temperatura anotada al principio y al final, bundle instalado por renombrado y
comprobado con `driver-en-uso.sh`. Antes de cada tanda, abrir y cerrar el Centro de Control una vez sin capturar. Por
captura: `echo 45 > /var/tmp/metal.trace; sleep 0.3; /var/root/hidtouch swipe 0.92 0.003 0.92 0.65 300; sleep 2;` y
el cierre de M24.

**Qué no hacer.** Mirar solo la pantalla: tilecheck primero. Mezclar condiciones en una misma sesión sin reiniciar
backboardd: `metal.args` se lee una vez por proceso. Comparar trazas con y sin `metal_perf` como si fueran la misma
condición.

## 8. Material y reproducción

| Qué | Dónde |
|---|---|
| Driver con TILE6_3/UBWC (`metal_tile`), contadores y tilecheck | `rebuild/wt-blur` (rama `blur-proto`, sin commit); diffs `out/blur-tile/blur-tile.patch`, `out/blur-tile-ctr/blur-tile-ctr.patch` |
| Driver con contadores solamente | `rebuild/wt-blur-diag` (rama `blur-diag`); `out/blur-diag/blur-diag.patch` |
| Bundles | `out/blur-tile` (b4406121…), `out/blur-tile-ctr` (7c140a33…), `out/blur-diag` (51b9ad75…); `COMMIT` en cada uno |
| Autocomprobación en el teléfono | `out/blur-tile/hakios-metal-tilecheck` (e76011f8…), fuente `hakios-metal/tools/tilecheck.cpp` |
| Parches de kernel | `blur/parches-nuevos/0370-sapphire-gpu-ubwc-config.patch` (integrado) y `0393-sapphire-fb-regs-mdss-ubwc.patch` (sha256 `405db374…`); árbol `blur/parches-nuevos/work/xnu`, rama `serie-0380` (el 0342 de `kernel-gpu/parches-nuevos` más 0343-0380 de `xnu/patches`, más 0393) |
| Auditoría n ≥ 3 | `blur/tools25/audita.py`, `bins2.py`; clasificación con `blur/tools/clasifica.py` |
| A/B de trazas | `blur/tools25/ab.py NOMBRE=DIR …` (tiempo, bytes de DDR y fallos del L1 por clase); `blur/tools25/destinos.py` (pantalla frente a texturas privadas por frame) |
| Resultados del teléfono | `blur/tilecheck-1.txt`; trazas `ios-graficos/trace/capturas-tile/{A,A2,B,C,T0,T1,T2}`, `capturas-diag/D0` |
| Compilación del catálogo en el host | `cpu-tools/build-hostcc.sh` con `EXTRA='-DHAKIOS_METAL_CACHE_BUILD="…"'`, `stagecc` sobre `cpu-tools/variants` |

Suite de host: 285 pruebas (`blur-diag`) y 286 (`blur-proto`), sin fallos en los dos chips y con los golden iguales. En
una de cuatro ejecuciones falló una vez `a_command_buffer_released_in_flight_gives_its_buffers_back` (buffers vivos por
encima de 40), que depende del hilo de la cola y pasó en las otras tres: es una prueba sensible al tiempo, sin relación
con estos cambios [O].
