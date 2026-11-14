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
2. **Lo que cae o se corrige.** P4 rinde menos de lo que dice 22 fuera del home quieto: el 86-100 % de los bins de las
   vueltas a la pantalla del Centro de Control tienen geometría (mediana, n = 447). La afirmación «el A610 no tiene
   olas de 128 en el FS» confunde dos propiedades de Mesa (§4). «Los registros de UBWC sin programar» no impiden usar
   TILE6_3 ni UBWC mientras todas las unidades lean la misma configuración, aunque sea la de reset (§2.1). El
   descarte de draws tapados (P8, segunda mitad) no lo hace ningún driver de Mesa y exige leer la geometría de la CPU
   al ejecutar, no al codificar (§3.4).
3. **P3 está listo para probar en el teléfono**: bundle `rebuild/out/blur-tile` con `metal_tile=1` (TILE6_3) y
   `metal_tile=2` (UBWC), apagado por defecto, solo para las texturas que `MetalContext::create_surface` crea privadas
   (`setUsage: 5`, `setStorageMode: 2`, QuartzCore 20H392 0x18830d2ac-0x18830d2e4). Lleva una autocomprobación en el
   teléfono, `hakios-metal-tilecheck`, que compara byte a byte lineal, TILE6_3 y UBWC en cada operación y mide su
   coste. El parche de kernel 0370 (configuración UBWC de Android o de Linux, por boot-arg o sysctl) es opcional. §2.
4. **Orden recomendado**: tilecheck → trazas A/B de `metal_tile` (n ≥ 3) → contadores por pasada (`blur-diag`, §5) →
   P5 y P1 → P9 (A/B del tamaño de ola) → P7 → P4 → P8 solo en su forma de «no cargar». §7.

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
| A3 | Lo caro son las pasadas a resolución completa sobre memoria lineal | Tiempos por pasada, n = 1-20 | Tabla de clases: esas pasadas no cambian con el reloj de la GPU (0 a −8 %); las de GMEM y las pequeñas bajan un 13-26 % | **Se sostiene**, con un dato nuevo: no dependen del reloj del núcleo. Que dependan del patrón de acceso y no del DDR sigue sin medir (el voto del DDR no surte efecto, 03 M24): lo deciden `metal_tile` (§2) y los contadores (§5) |
| A4 | La captura cuesta 2,1-4,3 ms; la reducción desde ella 2,15 ms; un clear de 756×1630 0,7 ms | n = 3-10 | 4,13 ± 0,25 (77) con filtro; 2,25 ± 0,12 (22); 0,71 ± 0,03 (13) | **Se sostiene** |
| A5 | Motor 2D y resolve ~7 GB/s; pipeline 3D sobre lineal 2,3-4,9 GB/s | Cuentas sobre A4 | Clear: 4,93 MB en 0,71 ms = 6,9 GB/s. Captura sin filtro: 9,8 MB en 2,16 ms = 4,5 GB/s. Con filtro: 19,6 MB en 4,13 ms = 4,7 GB/s. `downsample_8`: 4,9 MB en 2,25 ms = 2,2 GB/s | **Se sostiene** como cuenta [H]: los bytes son los útiles, no los medidos. Los mide §5 |
| A6 | Cuatro veces más muestreos cuestan un 19 % más (`single_pass_blur_3` frente a la copia 1:1) | n = 5 y 20 | `single_pass_blur_3` 2,27-2,52 ms (n = 18, cb 43-45 de las 6 capturas a 820) frente a la captura sin filtro, 2,16 de mediana: +5-17 % | **Se sostiene** (+5-17 %) |
| A7 | La pasada principal cuesta 10-13,5 ms | `merge-5` | `merge-7`: 9,58 ± 1,16 ms a 820 MHz (n = 239) | **Corregida**: 9,6 ms de media con `merge-7` |
| A8 | Las vueltas a la pantalla cuestan 2-14 ms por frame; cada una carga y guarda sus bins (~1,5 ms) | n = 2 pasadas | 2,47 ± 0,36 ms por vuelta en GMEM (n = 401); 4,3 ± 1,7 ms por frame (n = 239) | **Se corrige** el coste por vuelta: 2,5 ms, no 1,5 |
| A9 | P4: el home quieto pasa de 1,45-1,72 a ~0,1-0,2 ms; las vueltas parciales ganan (cb 17: 1,47 → 0,4) | 1 traza, cajas de los draws | Home quieto (n = 30): 1,82 ms. Cota inferior de bins con geometría del 3 % (mediana), si el `attachment_clear` de geometría desconocida es el rectángulo de 64×96 que 22 leyó de su buffer de vértices. Vueltas del Centro de Control (n = 447): mediana del 86-100 % de bins con geometría | **Se sostiene para el home quieto; cae para el blur**: en el Centro de Control, P4 ahorra como mucho el 14 % de la carga y el guardado de cada vuelta |
| A10 | Draws tapados: 6,47 Mpx por frame y 88-91 draws (15,4 Mpx) con el CC abierto | `trace-frame.py`, 1 traza | Sin rehacer con n ≥ 3 [no verificado]. Lo que P8 puede hacer conforme está en §3.4 | **Pendiente**; la cifra no cambia el plan |
| A11 | El A610 no tiene doble ola en el FS y el driver compila para olas de 128 | `supports_double_threadsize = False` | Mesa 25.0.7 tiene dos propiedades distintas. `supports_double_threadsize` (falso en `a6xx_gen1_low`) es la del cómputo. Para el FS, ir3 decide por `threadsize_base` y `double_threadsize`, y turnip compila `IR3_SINGLE_ONLY` solo si no hay `supports_double_threadsize` | **A matizar**: §4 |
| A12 | Los registros de UBWC sin programar impiden UBWC en render targets | KGSL frente a Linux, lectura de código | Basta que el RB, el TP, el SP y la UCHE vean la misma configuración, aunque sea la de reset. Los fondos UBWC de solo lectura ya se escriben con el RB y se leen con el TP. tilecheck lee esos registros y lo comprueba en el teléfono | **Cae como impedimento**; queda como ajuste de rendimiento (0370) |
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
HIGHEST_BANK_BIT` responde 14. El driver no lee ese parámetro. Que el RB y el TP coinciden con los valores de reset ya
lo dicen los fondos UBWC de solo lectura: los escribe el motor 2D (RB) y los lee el TP, y se ven bien. Qué valores
tienen de verdad lo lee `hakios-metal-tilecheck` (§2.5) [no verificado aún en el teléfono].

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

### 2.4 Parche de kernel 0370 (opcional)

`blur/parches-nuevos/0370-sapphire-gpu-ubwc-config.patch` (sha256 `b3117f48…`): boot-arg `gpu_ubwc=1|2` y sysctl
`kern.sweet_gpu_ubwc` (0 por defecto: no toca nada). `1` escribe los valores de kgsl en este teléfono (0x0b, 0x0b, 0x0b,
0x00a00000) y `2` los de Linux (0x09, 0x09, 0x09, 0x00800000, `RBBM_NC_MODE_CNTL` 0). Se aplica en cada arranque del CP
y, por sysctl, con la GPU ociosa y el cerrojo del servicio, como 0348; 0 repone los valores encontrados.
`kern.sweet_gpu_ubwc_regs` da los cinco registros ahora y como estaban. `GET_PARAM HIGHEST_BANK_BIT` responde el banco
vigente. Tras escribirlo en caliente hay que reiniciar backboardd: las imágenes ya hechas siguen en la disposición
anterior. Verificado: `git apply --check` limpio sobre 0001-0353 y compilación de solo sintaxis con los stubs de
`kernel-gpu/verificacion` (0 errores). No ejecutado en el teléfono. No es prerrequisito de P3: sirve para medir si el
banco correcto (14 según kgsl) cambia el ancho de banda de TILE6_3/UBWC.

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

### 2.6 P2: clears más baratos

El Clear de 756×1630 cuesta 0,71 ± 0,03 ms (n = 13) y no depende del reloj, como corresponde a 4,93 MB escritos a
6,9 GB/s. Con TILE6_3 escribe los mismos bytes: el ahorro posible es de patrón de acceso, si lo hay (lo mide tilecheck,
«clear 756x1630»). Con UBWC, el motor 2D escribe bloques comprimidos y su flag buffer; el «fast clear» que Qualcomm
cita para UBWC sería que un bloque de un solo color se escribe como flag. Que el motor 2D del A610 lo haga así no
consta en ninguna fuente pública ni en Mesa; lo dice o no la fila «clear» de tilecheck en UBWC frente a lineal. El
alcance no cambia: el Clear sigue cubriendo el attachment entero (22 §4.1), así que es conforme. El recorte del
rasterizado al área de render (la otra mitad de P2 en 22) no tiene efecto en ninguna traza [O, 22 §4.1] y es un
arreglo de conformidad independiente.
