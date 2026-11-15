# 19 — Cómo dibuja iOS: el camino de un frame y el contrato de CoreAnimation con Metal

Documento de referencia (2026-11-14). Pregunta: qué hace iOS 16.7.16 (20H392) para poner un frame en la pantalla,
qué espera CoreAnimation de un driver Metal correcto y dónde se desvía el nuestro (hakios-metal, upstream `63fc2b4`
más los parches A610), para arreglarlo de forma general en el driver y en el kernel, no con atajos sobre CoreAnimation.

Convención de evidencia: **[O]** observado en un binario de Apple (offset o símbolo), en código (archivo:línea) o en
una medida propia; **[D]** documentado por Apple (URL en §6); **[R]** ingeniería inversa de terceros fiable (URL en §6);
**[H]** hipótesis. Lo heredado (comentarios y docs de HackiOS, `NOTES.md`) cuenta como [H] hasta verlo en código o
en binario. El material extraído de Apple está fuera de git, en `~/sapphire-angel/research/metal/ios-graficos/`.

## Resultado en breve

1. **QuartzCore de 20H392 trae sus shaders en AIR** (`default.metallib`, 141 funciones) y una pipeline library de
   1 079 pipelines con sus descriptores y los valores de constantes de cada variante; el código precompilado que
   trae es de GPU de Apple y no sirve aquí. La premisa de HackiOS («no hay `default.metallib`») es falsa para esta
   imagen: el driver puede compilar exactamente cada pipeline que CoreAnimation pide (§2.2).
2. **CoreAnimation exige blending programable**: especializa todos sus fragment shaders con
   `fc_framebuffer_fetch=1` sin mirar lo que declara el dispositivo. `[[color(n)]]` coherente, en orden de primitiva,
   es parte del contrato mínimo (§2.5).
3. **Un pipeline que falla dos veces aborta backboardd.** Por eso el plug-in sustituye las variantes que no sabe
   compilar por «la más cercana» (4-8 por arranque en el teléfono, p. ej. canal rojo → verde); cambian el dibujo y
   son la no conformidad de más consecuencia visible. Lo conforme es compilar el uber shader real con las constantes
   de CoreAnimation (§2.2, §4.3).
4. **El driver omite en silencio lo que no sirve** (command buffer «Completed» sin error), rechaza draws en uso normal
   por buffers de constantes más cortos que lo declarado, toma un scissor de anchura 0 por «todo el target» y lee
   las IOSurfaces desalineadas y las YCbCr a través de copias hechas al codificar, no al ejecutar. Tabla de 28 no
   conformidades (24 del driver y 4 del kernel) con evidencia y consecuencia en §2.9.
5. **El ritmo de frames en el iPhone X** sale de un `CADisplayTimer` propio, no de las notificaciones de vsync (el
   selector 72 no se usa por diseño en el A11), y la contrapresión es sondear `SwapWait` antes de cada frame; el
   kernel responde 0 al instante (§1.3, K-3).
6. **Lo que el dispositivo declara es contrato**: tile shaders, raster order groups, memoryless y la alineación de
   IOSurface (`iosurfaceReadOnlyTextureAlignmentBytes`, con la que CoreAnimation crea sus superficies) cambian lo que
   hace CoreAnimation; declarar la alineación real de 64 B quita copias sin atajos (§2.8).
7. **Los fallos visibles** (§4): el blur oscuro con rayas y la barra blanca son la composición por CPU con el driver
   sin cargar; los destellos de colores tienen cuatro mecanismos con una prueba que los separa; la hora en rojo es una
   máscara de un canal leída como color; los 20-25 fps eran CPU del driver y un vaciado de la L2 antes de cada WFI, y
   hoy (44-55 buffers/s) los fija el encadenado de CPU, GPU, copia al panel y presentación.
8. **Frente a la GPU de Apple** lo que CoreAnimation aprovecha no es tanto el HSR (casi ninguna capa es opaca) como
   leer el destino en memoria de tile sin coste por tile, que es justo lo caro en el A610 (§3).
9. **Instrumentación lista** (§5): `metal_trace=frame` vuelca command buffers enteros con lo pedido y lo hecho, y
   `trace-frame.py` los resume y marca anomalías; bundle `rebuild/out/trace-merge` para el driver que lleva el
   teléfono.

## 1. El camino de un frame

### 1.1 De un vistazo

```
 app (UIKit, CALayer)             backboardd (render server)                       kernel                 panel
 ────────────────────             ─────────────────────────                        ──────                 ─────
 evento → cambia capas            hilo render-server: recibe y decodifica
 commit de la transacción ──mach─► la transacción → árbol de render
  (layout, display, prepare,      hilo display.primary, en cada tick:
   commit)                         animaciones → plan de render → pasadas
 contenidos en IOSurface ────────► (backing stores, compartidas)
                                   MetalContext: command buffer ──────────────► GPU (driver Metal)
                                   swap: SwapBegin/SetLayer/SwapEnd ──────────► IOMobileFramebuffer ──► scanout
```

Apple describe el *render loop* en cinco fases: **event** y **commit** en la app, **render prepare** y **render
execute** en el render server, y **display**; cada fase tiene como plazo el vsync siguiente, y por defecto un frame
se procesa durante dos intervalos antes de verse (doble búfer). Si el render server se retrasa, el sistema pasa a
triple búfer y le da un intervalo más [D, tech talks 10855 y 10857; §6]. La app no renderiza: comitea su árbol de
capas a un proceso aparte con «a server side version of Core Animation» [D/R, WWDC 2014 419]. En este teléfono ese
proceso es backboardd: sus hilos `com.apple.coreanimation.render-server` y `com.apple.coreanimation.display.primary`
(más `display.wireless0-2`, con ~1 ms de CPU: pantallas inalámbricas inactivas [H]) existen allí con política de
prioridad fija, 55 y 54 [O,
`research/metal/hilos/datos/tanda1/*.threads`], y el de display es el que se satura (03 M1).

### 1.2 En la app: la transacción

Cada cambio de un `CALayer` (posición, opacidad, contenido, animación añadida) queda en la transacción implícita
del hilo, que se confirma «when the thread's runloop next iterates» [D, `CATransaction`]. El commit tiene cuatro
pasos: *layout* (`layoutSubviews`), *display* (cada capa con dibujo propio recibe «a texture-backed Core Graphics
context»: desde ese momento, para CoreAnimation, «these layers are now just images»), *prepare* (decodificación de
imágenes y conversión de las que estén en un formato que la GPU no pueda usar directamente) y *commit*, que empaqueta
el árbol recursivamente y lo envía al render server [D, tech talks 10855 y 10856; WWDC 2014 419]. El transporte son
mensajes mach y los contenidos viajan como IOSurfaces compartidas [R]. Las animaciones se comitean una vez y las
evalúa el render server en cada frame, sin volver a la app [D, WWDC 2014 419; 10857]. Por eso una animación de
SpringBoard avanza aunque su hilo principal esté ocupado, y por eso el coste de cada frame en movimiento cae en
backboardd. Sin commits ni animaciones no hay frame nuevo: iOS no redibuja la pantalla por su cuenta [D, 10855].

### 1.3 En backboardd: el árbol de render y el reloj

- El hilo `render-server` recibe las transacciones de todos los procesos y las aplica al árbol de render (una
  copia del árbol de capas por contexto de cliente). Consume poco: 8,1 % de un núcleo durante los gestos frente al
  76,9 % del hilo de display (03 M1).
- El hilo de display hace en cada frame el *render prepare*: evalúa las animaciones y recorre el árbol «from parent
  to child and sibling to sibling so that the layers are arranged from back to front», compilándolo en «a linear
  pipeline» de operaciones simples para la GPU [D, 10855, 10857]; y el *render execute*: codifica ese pipeline en
  pasadas de un command buffer de Metal, lo confirma y pide el swap [D en lo funcional; el reparto entre los dos
  hilos es O por consumo de CPU, 03 M1].
- **El reloj [O, QuartzCore 20H392].** En el iPhone X CoreAnimation **no usa las notificaciones de vsync** de
  IOMobileFramebuffer: `CADeviceUseVBL::use_vbl` (0x18836d0e4) solo vale 1 si el `ChipID` de MobileGestalt está en
  `vbl_chip_ids` (0x18856e5c0: A8 a A10, de 0x7000 a 0x8010) o con la variable `CA_FORCE_TIMER`; para el A11
  (0x8015) vale 0, e `IOMFBServer::add_vsync_source` (0x1882d9ee4) crea un `CADisplayTimer` propio con el intervalo
  del modo de pantalla. En cada tick, `IOMFBServer::timer_callback` (0x188350b24) lee
  `IOMFBDisplay::timing_reference()` y realinea la fase del timer (`CADisplayTimerAlignPhase`). Por eso el selector
  72 (`EnableNotifications`) no aparece nunca en el teléfono: es el diseño para el A11, no una carencia del kernel.
  El intervalo sale de lo que publica el kernel (`IOMFBDisplayRefresh`, `TimingElements`: 120 Hz aquí; 09 §2.4);
  de qué se alimenta `timing_reference` está por leer [H: marcas de swap completado o el refresco publicado]. En este
  teléfono la rejilla del timer no tiene fase con el panel (09 §2.5).
- **Antes de empezar un frame** `IOMFBDisplay::can_update_` (0x1882be944) mira si hay un swap pendiente y llama a
  `swap_wait_timeout(fb, id, 0x80000001, …)` (0x18853c088): `IOMobileFramebufferSwapWait` en bucle mientras devuelva
  distinto de 0, con `usleep(100)`, hasta 1 ms [O]. Es la contrapresión de CoreAnimation: si el swap anterior no ha
  terminado, ese tick no actualiza. Cuando un frame tarda más de un intervalo, el panel sigue enseñando el anterior y
  el siguiente frame arranca en el siguiente tick en que se puede actualizar: con 120 Hz, un frame de 30-42 ms deja
  huecos de 33,3, 41,7 o 50 ms (09 §2.5, [H] coherente con lo medido).

### 1.4 El compositor: pasadas y draws

**La pasada principal.** El pipeline lineal de capas, de atrás adelante, acaba en una pasada sobre la superficie de
pantalla: 750×1624, `BGRA8Unorm` (formato 80), con 99-152 draws en movimiento y 108 en reposo [O, 03 M2, M6;
`medicion/ab/`]. Cada draw es un quad: «primitive 3, 6 vertices» (triángulos, dos por capa) con el uber shader
(`fixed_vert_lph_spc` + `fixed_frag_lph_cph`/`_cpf`) [O, consola]; QuartzCore dibuja con
`drawPrimitives:vertexStart:vertexCount:` (y la forma con instancias), nunca con índices [O, sitios de llamada en
20H392]. No hay buffer de profundidad: el orden de
los draws es el orden de pintado [O, 10 §3.6]. CoreAnimation no agrupa capas en un draw: el número de draws crece con
el número de capas visibles y de trozos que necesitan su propio estado.

**Pasadas offscreen.** Una pasada offscreen es «anytime the GPU must render a layer by first rendering it somewhere
else and then copying it over»; Apple nombra cuatro causas que se pueden evitar: sombras sin `shadowPath`, máscaras,
esquinas redondeadas «sin información suficiente» y efectos visuales [D, 10857]. A ellas se suman la opacidad de
grupo («if layer is not opaque … and if layer has nontrivial content») y `shouldRasterize`, que compone la capa una
vez y la guarda en una caché limitada a 2,5 veces el tamaño de la pantalla, de la que sale si no se usa en 100 ms
[D, WWDC 2014 419]. En el teléfono, un command buffer lleva 1 pasada en reposo y 3-11 en movimiento [O, 10 §1.1].

**Blur y vibrancy.** El renderer copia lo que hay debajo del efecto a otra textura, le aplica el efecto y lo devuelve
[D, 10857]. En 2014 Apple contaba cinco pasadas para el blur oscuro en el mejor caso: contenido, captura reducida, blur
horizontal, blur vertical y composición con escalado y tinte; vibrancy añade dos más con «an expensive compositing
filter» [D, WWDC 2014 419]. En 20H392 las funciones de `default.metallib` dan los nombres de esa cadena:
`downsample_4/6/8`, `downsample_blur_2/4`, `narrow_blur_7…27`, `single_pass_blur_3`, `upsample`,
`variable_blur(_downsample)`, más `luma_boost` [O, `metal/quartzcore-functions.txt`]; y la pila de un fallo de
backboardd da el recorrido `filter_backdrop` → `render_luminance_map` → `MetalContext::draw` →
`encode_gamma_luts` → `create_gamma_lut_buffer` [R, `NOTES.md` 2026-10-22]. En la consola aparecen pasadas de
752×1626, la pantalla más un píxel por lado, con 35 draws y 32-36 ms de GPU en sysmem [O, `ab-real-propio-args.txt`]:
[H] la captura del fondo de un material a pantalla completa, con borde para el muestreo.

Lo que calcula cada etapa, leído en el AIR de 20H392 [O, `shaders-pipelines-20H392.md` §2]:

| Función | Qué hace |
|---|---|
| `downsample_4/6/8` | reducción con 4, 6 (en parejas) o 16 tomas, offsets y pesos que pone la CPU |
| `downsample_blur_2/4` | reducción con blur: 7 y 13 tomas (centro + parejas) |
| `narrow_blur_7…27` | blur separable de N tomas lógicas con (N+1)/2 muestreos bilineales en parejas; opción de dividir por α |
| `single_pass_blur_3` | blur 3×3 en una pasada, 4 tomas bilineales |
| `upsample` | ampliación separable (un eje por pasada) con un núcleo polinómico de 4 tomas (ajuste tipo Lanczos-2 [H]) |
| `variable_blur(_downsample)` | blur de radio variable por máscara, mezclando dos niveles de mip con B-spline bicúbico |
| `asg_*` | remuestreo 1D en gamma 2 (2:1, 4:3) |
| `luma_boost`, `edr_scale`, `p3_clamp`, `harmony`, `alpha_linear_premultiply` | posprocesos sobre el destino, que leen por `[[color(0)]]` |
| `inplace_copy` | copia el framebuffer a una textura desde el fragment shader, con `raster_order_group(0)`; no devuelve color |
| `tile_downsample_1/2/4/8` | reducción dentro de la memoria de tile (imageblocks): solo GPUs de Apple |

Ningún blur ni downsample lee el framebuffer: trabajan sobre la captura. La vibrancia y el oscurecimiento de los
materiales se hacen en el uber shader (`fc_blend_function` 41-47: matriz de color sobre el destino, vibrancia oscura
y clara, `darkenSourceOver` = 46), leyendo el destino por fetch. Los casos concretos (dock, carpetas, Centro de
Control, Biblioteca de Apps) son combinaciones de captura del fondo, cadena de reducción y blur, y composición con
vibrancia; qué pasadas y a qué tamaños hace cada uno en el teléfono lo da la traza de §5.

### 1.5 La presentación

- **Lo que entrega backboardd.** Dos IOSurfaces de 750×1624 BGRA (ids 2 y 3, 3 072 bytes por fila) que alterna
  como superficies de pantalla, y un único layer a pantalla completa por swap; el orden observado es submit del
  command buffer y, a continuación, swap (09 §1). Pide el swap con `IOMobileFramebufferSwapBegin` (un id),
  `SwapSetLayer` y `SwapEnd` (la petición de 0x46c bytes, cuyo formato coincide campo a campo con el `dcp_swap` que
  documenta Asahi para el DCP [R], 12 §9.20), y llama a `SwapWait` (selector 6).
- **Lo que CoreAnimation pide al framebuffer [O, IOMobileFramebuffer y QuartzCore de 20H392,
  `binarios-ios-20H392.md` §6 y §9].** Los selectores que backboardd usa en el teléfono son `GetLayerDefaultSurface`
  (3), `SwapBegin` (4), `SwapEnd` (5, 1 132 B), `SwapWait` (6, `{id, flags, timeout}`), `GetDisplaySize` (8),
  `RequestPowerChange` (12), `SetDebugFlags` (15), `SetGammaTable` (17), `SetDisplayDevice` (22), `GetGammaTable`
  (27), `GetDotPitch` (28), `GetDisplayArea` (29), `EnableDisableVideoPowerSavings` (33), `SetBrightnessCorrection`
  (50), `SetMatrix` (55), `GetColorRemapMode` (57), `SetParameter` (68), `SupportedFrameInfo` (74) y `SetContrast`
  (84). `SwapSetLayer` rellena la petición en memoria del proceso. El contrato de `SwapWait` que se deduce del código:
  devolver distinto de 0 mientras el swap `id` no haya terminado y 0 cuando ya terminó [H sobre el valor exacto]; con
  eso CoreAnimation no empieza un frame mientras el anterior no esté en pantalla.
- **Lo que hace el kernel del teléfono.** Copia y escala ×1,5 la superficie al buffer del panel con el blitter de la
  GPU y hace el flip del plano VIG0 del MDP (09 §2). Con `kern.sweet_fb_queue=1` (0340), cada frame se copia a su
  propio buffer, se enseña en orden cuando la copia termina, la superficie sigue en uso hasta su flip y `SwapEnd`
  espera (hasta 50 ms) si CoreAnimation va más de dos frames por delante: es la contrapresión que un framebuffer
  real ejerce reteniendo las superficies (15 §2). Medido con 0342: frames pisados de 10,6 % a 0 (03 M7). La copia
  escalada cuesta 4,15 ms de GPU por frame de media, un tercio del tiempo de GPU de un frame (03 M11). Con el
  scanout directo del plano (0350/0352) la superficie se escanea sin copia, pero CoreAnimation vuelve a dibujar en la
  que está en el panel en más de la mitad de los frames y el kernel cae a la copia (03 M12): con dos superficies y sin
  un `SwapWait` que espere, nada le impide reutilizarla (K-3, §2.7).
- **Lo que hace un iPhone.** El iPhone X no tiene DCP: IOMobileFramebuffer es una kext del procesador principal
  (`AppleMobileDispH10P`), con user clients AppleCLCD/IOMFB [R, Saar Amar, CVE-2021-30883]; el DCP llega con el A14
  [R]. La API de usuario es la misma (`SwapBegin`/`SwapSetLayer`/`SwapEnd`/`SwapWait`) y la petición de swap tiene la
  forma que Asahi documenta para el DCP: hasta 4 capas de IOSurface con rectángulos de origen y destino, color de
  fondo, flags, marcas de tiempo y regiones activas; el fin del swap se notifica con su id y la superficie que sale de
  pantalla sigue en uso hasta ese momento [R, `iomfb_template.h`, m1n1 `ipc.py`]. Con varias capas, el hardware de
  pantalla compone (planos), sin pasar por la GPU.

## 2. El contrato de CoreAnimation con Metal

Para cada cosa que CoreAnimation usa de Metal: qué usa (binario de 20H392 o consola del teléfono), qué exige Metal
y qué hace hoy hakios-metal (upstream `63fc2b4` + parches A610, árbol `rebuild/hakios-upstream`, 620950c; `CA.m:N` es
`userland/src/HakiosMetalCA.m`). La tabla de no conformidades está en §2.9.

### 2.1 Cómo llega CoreAnimation a un dispositivo Metal

[R, `NOTES.md` 2026-10-21/22, trazas de un dispositivo que registraba cada mensaje] Metal lee `MetalPluginName` y
`MetalPluginClassName` del servicio acelerador (`IOAcceleratorES`), carga `/System/Library/Extensions/<nombre>.bundle`,
exige una subclase de `_MTLDevice` y la crea con `initWithAcceleratorPort:`; `MTLAddDevice` exige además que la clase
declare el protocolo `MTLDevice`. backboardd pregunta después ~100 capacidades (`supports…`, límites) y crea la cola.
El render server de la pantalla (`CA::WindowServer::EAGLServer`, el nombre es histórico) crea su contexto Metal en
`CA::OGL::new_metal_context` [O, QuartzCore 20H392: también la cola, su prioridad y sus colas de envío y
completado], que abre la pipeline library de QuartzCore a través de `MTLPipelineLibraryBuilder::newLibraryWithFile` y
necesita del dispositivo una `targetDeviceInfo` [R, NOTES]. Si no hay dispositivo, compone por CPU (§4.1).

### 2.2 Shaders y pipelines

**Qué trae 20H392 [O].** `QuartzCore.framework` (CFBundleVersion 1045.17.2) contiene:

- `default.metallib` (1 014 944 B, sha256 `11c74cc4…`): 141 funciones en AIR 2.5 (Metal 3.0), compiladas con
  `framebuffer_fetch_enable`; 95 de fragmento, 39 de vértice, 7 kernels; nombres y tamaños idénticos a
  `metal/quartzcore-functions.txt`. LLVM 18 (`llvm-dis`) las lee enteras, con nombres de argumentos y tipos.
- `default.pipelinelib/`: `functions` (451 módulos de una función: las variantes ya especializadas del uber shader,
  con las constantes plegadas), `pipelines.desc` (**1 079 pipelines** con su descriptor completo: funciones, vertex
  descriptor, formatos, mezcla, writeMask; y en su sección 5 los valores de las function constants de cada variante)
  y `pipelines.g4p` … `g15p`, código máquina por generación de GPU de Apple (`g10p` = A11: 711 objetos Mach-O de AGX y
  332 reflexiones `MTLPSBIN`). QuartzCore lleva en su `__TEXT` la misma lista de 1 079 nombres.
- La afirmación de HackiOS de que este sistema «no tiene `default.metallib`» (`CA.m:1412-1414`, `inject.c:1082`,
  `tools/ca-metallib.py`) es falsa para 20H392; su sustituto (`QuartzCore-default.metallib`, hecho con el metallib de
  macOS) no está en el teléfono y, con el real presente, no se enlaza (`CA.m:2516-2535`).

Fuentes: mtree del IPSW y ficheros leídos por rangos del DMG raíz; análisis completo en
`ios-graficos/shaders-pipelines-20H392.md`.

**El uber shader [O].** Casi todo lo que CoreAnimation dibuja pasa por un único programa, `ogl_metal_uber.metal`
(clase C++ `UberShader<T1,T2>`), en las formas `fixed_vert_lph/lpf_spc|gen` y `fixed_frag_lph_cph|cpf`:

- `_lph`/`_lpf`: color de vértice `half4` o `float4`. `_cph`/`_cpf`: operaciones de color en `half` o en `float`.
- `_spc`: atributos por vertex descriptor y configuración por **function constants**; `_gen` (genérico): *vertex
  pulling* y configuración leída en ejecución de un `FragmentShaderConfig` de 52 B en el buffer 0, que replica una a
  una las constantes. El genérico es el mismo programa con la configuración en memoria.
- El fragmento tiene 61 constantes. Las que deciden el contrato: `fc_framebuffer_fetch` (4) lee el destino por
  `[[color(n)]]`; `fc_framebuffer_sample` (5) lo lee **muestreando** el attachment ligado como textura cuando no hay
  fetch; `fc_texture_function` (29) forma la fuente (imagen, imagen × color, máscaras, matrices de color 3×3/4×5,
  vibrancia, LUT 3D…); `fc_blend_function` (30) hace la **mezcla programable** en el shader (Porter-Duff, modos W3C,
  plusD, vibrancia oscura/clara; 54 = sin mezcla en el shader, la hace el blending fijo del pipeline);
  `fc_image_function0/1` (46-47) convierte los planos de cada imagen (RGBA, canal suelto, YCbCr biplanar con
  `ycbcr_matrix`, formas antialiasadas, supercírculo de esquinas continuas…); `fc_memoryless_index0/1` (54-55) toma
  como imagen otro attachment del mismo pase leído por fetch; `fc_dest_index`/`fc_dest_count` (35-36) eligen qué
  attachment se lee y se escribe.
- Uniformes en el buffer 1 (`CA::OGL::Metal::Uniform`, 176 B); LUTs de gamma de 128 KiB en el buffer 7; hasta 2
  imágenes × 3 planos, ruido, curvas TRC, cubos 3D.

**El catálogo de pipelines [O].** De los 1 079: 986 del uber shader (444 variantes de fragmento, 7 de vértice) y 93
de funciones normales (`path_*`, `attachment_clear`, `downsample_*`, `narrow_blur_*`, `single_pass_blur_3`,
`variable_blur`, `inplace_copy`, `luma_boost`, `harmony`, `p3_clamp`…). Todos sin profundidad ni stencil y con una
muestra; 901 con 2 attachments de color y 178 con 3 (el tercero `R32Float`, cobertura de paths); cada pipeline
escribe uno. Formatos del attachment 0: XR de 10 bits (RGB10A8_2P_XR10, BGRA10_XR, BGR10_XR) en 788, BGRA8Unorm en
256, RGBA16Float en 13. Mezcla fija activa en 581 (463 `One, OneMinusSourceAlpha`: sourceOver premultiplicado);
mezcla programable en el shader en 188; sin mezcla en 310. **354 pipelines leen el framebuffer** de verdad (331 del
uber shader, 23 normales), aunque los 986 del uber shader estén compilados con `fc_framebuffer_fetch=1`. 24
pipelines genéricos (uno por formato y número de attachments) valen para cualquier configuración.

**Qué pide CoreAnimation en ejecución [O, consola; R, NOTES 2026-10-22].** Los pipelines del catálogo los crea por
nombre desde la pipeline library (`newPipelineLibraryWithFilePath:error:`, API privada que un ingeniero de Apple
confirma que usa CoreAnimation [D, foro 727037]; `newRenderPipelineStateWithName:options:reflection:error:`); el
resto los crea en ejecución con la función del metallib, sus valores de constantes y
`newRenderPipelineStateWithDescriptor:`. En el teléfono aparecen ambos: pipelines `_spc` enlazados con sus
constantes (la consola las enumera: `4=1 6=2 8=1 16=1 29=3 30=54 33=1 35=1 46=17 50=1 52=1`) y el genérico, que el
driver especializa por el contenido del buffer 0 («specialise: fixed_vert_lph_gen+fixed_frag_lph_cpf for 52 bytes of
its buffer 0: 96 instruction words, not 32064, in 816 ms», 71 veces en `medicion/ab/`).

**Cómo lo hace QuartzCore [O, `binarios-ios-20H392.md` §3].** `new_metal_context` carga `default.metallib` con
`newLibraryWithURL:error:` y la pipeline library con `newPipelineLibraryWithFilePath:error:` +
`setDisableRunTimeCompilation:YES`. `create_pipeline_state` (0x188380b94) nombra cada pipeline, comprueba que el
dispositivo cumpla el `supportsFeatureSet:` que la entrada de la library exige («Pipeline %s requires %@» /
«excludes %@») y lo pide con `newRenderPipelineStateWithName:…`; si sale nil, lo registra («Metal failed to load
render pipeline: pipeline=%s sdk=20H218») y lo compila en ejecución: `load_shader_function` (0x1884827c4) con un
`MTLFunctionDescriptor` y sus `MTLFunctionConstantValues` (unas 40 constantes `fc_*` puestas con
`setConstantValue:type:withName:`), `newFunctionWithDescriptor:error:` y `newRenderPipelineStateWithDescriptor:error:`,
con etiqueta `com.apple.coreanimation.draw.<nombre>`. **Si un pipeline de render falla, lo reintenta una vez y al
segundo fallo llama a `abort_with_payload` (0x188381ef4): backboardd muere.** Los de tile también abortan; los de
cómputo solo se registran. No hay caída a un renderer por software en ese camino. Un driver no puede, por tanto,
devolver nil por un pipeline que no sabe compilar: tiene que compilarlo bien.

**Qué exige Metal [D].** La función se compila con los valores dados, buscados por índice y luego por nombre; las
constantes `required` deben venir [`makeFunction(name:constantValues:)`, `MTLFunctionConstantValues`]. Un pipeline con
nombre equivale al descriptor que la library guarda para él. La forma con `completionHandler:` es asíncrona.

**Qué hace hakios-metal [O, auditoría `noconformidades-driver.md` §3].** El AIR sale de
`-[_MTLFunction bitcodeData]` y las constantes del guion de especialización (`CA.m:2742-2896`); con eso, la ruta
normal compila exactamente lo pedido. Hay cuatro desvíos:

1. **Sustitución por «la variante más cercana»** (N-01, `hm_ca_nearest`, `CA.m:1569-1641`, `1703-1719`). Para un
   pipeline que CoreAnimation crea en ejecución y no está entre los 986 del catálogo, el plug-in no compila el uber
   shader con las constantes de CA: elige otra variante precompilada «parecida» y su vértice. En cada arranque con el
   driver cargado la consola registra de 4 a 8, p. ej. `TmuaA2Xhf_Ired_Icir` → `TmuaA2Xhf_Igrn_Icir` (la imagen 0 deja de
   leerse por el canal rojo y pasa al verde), `TimgA2Xhf_Isqr` → `TimgA2Xhf_Ialp` (máscara de forma → solo alfa),
   `TcimA2S1Xhfn_IsrcN3Oc3mtc4` → `TcimA2S1Xhf_IalpCcl` (matriz de color con ruido → alfa × color), y una sin sustituto:
   `TvdkA2Xhf_Isrc` (vibrancia oscura). Las etiquetas codifican las constantes (gramática en
   `shaders-pipelines-20H392.md` §3.3: `T` = `fc_texture_function`, `B` = mezcla, `A` = attachments, `X` = banderas
   half/fetch/`cpf`/rango extendido/ruido, `_I` = `fc_image_function`). Sobre las 444 etiquetas reales, una simulación
   «dejando una fuera» cambia la entrada de la imagen en 93 [O, `A-herramientas/nearest2.py`].
2. **`edr_scale` sustituido siempre por `inplace_copy`** (N-08, `CA.m:1922-1981`): en 20H392 `edr_scale` existe y lee
   `[[color(0)]]`, las LUTs de gamma y el ruido; `inplace_copy` no devuelve color, escribe el framebuffer en una
   textura con `raster_order_group(0)`, y el compilador del driver rechaza escribir texturas desde un draw: el pipeline
   sale nil.
3. **Draws de `luma_boost` omitidos** por defecto (N-24, `CA.m:8233-8250`).
4. **Constantes perdidas sin error** en casos que CA no usa hoy (N-25).

La especialización del genérico por el contenido del buffer (N-17, `CA.m:7451-7527`) es una optimización del driver,
no una desviación del resultado, mientras el buffer no cambie entre la codificación y la ejecución: lee los 52 B en
CPU al codificar; mientras compila la variante, dibuja con el genérico. (La espera `usleep(2000)` en el hilo de render
que describe 10 §3.7 es del port de Angel, no de este árbol.) Las formas con `completionHandler:` compilan de forma
síncrona dentro de la llamada (N-36): no cambia el resultado, sí el tiempo del hilo de render.

### 2.3 Recursos: buffers, texturas, IOSurface

**Lo que usa CoreAnimation [R, NOTES 2026-10-22; O, consola; HEREDADO, comentarios del plug-in].** Buffers de un pool
con offsets (`newBufferWithLength:options:`, `contents`), texturas propias y **texturas sobre IOSurface**
(`newTextureWithDescriptor:iosurface:plane:`: los backing stores de las apps, las superficies de pantalla, las
fotos y fondos en YCbCr '420f'/'420v' con el formato privado 500), samplers, `replaceRegion:`, y texturas
*memoryless* para el segundo attachment del pase y los blurs. Heaps (`newHeapWithDescriptor:`, `setPurgeableState:`):
los usa SpringBoard [R, NOTES 2026-10-22] y el CoreAnimation de macOS saca de ellos sus offscreens [R, 12 §9.17]; en el
de 20H392 está por confirmar.

**Lo que exige Metal [D].** Un buffer nuevo sale a cero (`makeBuffer(length:options:)`); de una textura nueva no se
promete nada. Una textura sobre una IOSurface o sobre un buffer **es** esa memoria: la GPU lee lo que haya al
ejecutar, y lo que escribe queda en ella. El seed de la IOSurface sube en cada unlock tras escribir; el lock solo
acota el acceso de la CPU. Los recursos se retienen hasta que el command buffer termina; `makeAliasable` devuelve la
memoria al heap. Las alineaciones que el dispositivo declara (`minimumLinearTextureAlignmentForPixelFormat:`) son las
que el cliente respeta.

**Lo que hace hakios-metal [O, auditoría].**

- **Buffers de constantes:** rechaza el draw si un rango de constantes que ir3 decidió empujar pasa del final del
  buffer ligado, aunque la rama que toma el shader especializado no lo lea (N-03, `render.cpp:244-258`). Ocurre en
  uso normal: «refused: a draw of fixed_vert_lph_spc+fixed_frag_lph_cph … reads 64 bytes at 0 of constant buffer 2;
  16 are bound» (con el Clear de su pasada: queda el color de clear) y «… narrow_blur_27_frag_lph …
  downsample_blur_vert_lph reads 64 bytes at 0 of constant buffer 3; 48 are bound» (una etapa del blur)
  (`medicion/ab/ab-gmem0-*.txt`, `ab-nobin-2.txt`, `ab-r-stop-3.txt`).
- **IOSurface con filas no múltiplo de 64 B:** no muestrea la superficie sino una copia por CPU refrescada al
  **codificar** y devuelta a la superficie en un completed handler asíncrono, que corre después de que
  `waitUntilCompleted` vuelva (N-06). La causa raíz es que el dispositivo no declara la alineación de 64 B que exige el
  núcleo (N-07, `texture.cpp:996-998`). En el teléfono: filas de 2 848 y 480 B.
- **YCbCr '420f'/'420v':** convertido a RGBA8 por la CPU al crear o ligar la textura, no al ejecutar (N-05,
  `CA.m:3772-3799`, `4435-4497`). Con los planos todavía vacíos la conversión da **verde (0, 136, 0)**; con croma
  constante, rojo, azul o cian. La ruta está activa en el teléfono («a two-plane YCbCr surface sampled as format 500 is
  read through an RGBA8 copy»). Además el uber shader de 20H392 tiene su propia conversión YCbCr
  (`fc_image_function` 20, 35, 37/38 con `ycbcr_matrix`, variantes `_Iybr`): si CA pide esa ruta sobre la copia RGBA,
  la conversión se hace dos veces (N-16, [H]).
- **Copias en vez de alias:** texturas sobre buffer con filas u offset no alineados a 64 y buffers *no-copy* son copias
  hechas al crear (N-12).
- **Formatos:** XR (552-555), superficies comprimidas '&…', 'w30r' y planos sueltos de 420 → nil (N-15); el swizzle del
  descriptor da nil en texturas propias y se ignora sobre IOSurface (N-14). sRGB por formato y por vista, conforme.
- **Samplers:** filtros, modos de dirección (incluido `clampToZero`), anisotropía y comparación servidos; los clamps
  de LOD por encoder se descartan (N-26); bicúbico rechazado por nombre en A610.
- **Ranuras sin enlazar:** textura nula 1×1 a cero y sampler a cero: leen (0,0,0,0), no pintan color (D-16).
- **Heaps:** `usedSize` solo crece, `makeAliasable` no devuelve nada; agotado, los recursos salen nil sin log; heaps
  *placement* → nil (N-13).
- **Memoria nueva:** el driver no limpia; el kernel sí por defecto (`gpu_zero=1`); con `gpu_zero=0` o `gpu_bocache=2`
  llega memoria previa (N-35) [HEREDADO, `k/0215`: «folders opening in the dark appearance showed white frames, and once
  the whole screen went yellow»].
- **Memoryless:** memoria normal (`CA.m:3631-3638`); semánticamente válido (el contenido puede sobrevivir), pero ocupa
  memoria y GMEM (§3).

### 2.4 Pasadas

**Lo que exige Metal [D].** `Load` conserva el contenido; `Clear` escribe **todo** el attachment; `DontCare` permite
cualquier contenido al empezar o al acabar; *memoryless* no admite `Load` ni `Store`. Por defecto, color: load
`DontCare`, store `Store`. Un encoder válido para todo descriptor de pasada servible.

**Lo que hace hakios-metal [O, anexo B de la auditoría].** El mapeo de load/store es conforme (DontCare como
Load/Store en sysmem, permitido; `Unknown` y store tardío servidos; resolves de color; `clearColor` convertido como
turnip); **un Clear fuera de la unión de draws sí se escribe** (en GMEM los tiles cubren la ventana si la pasada limpia
en tile, o el relleno 2D cubre el nivel). GMEM está encendido por defecto (`metal_gmem_draws=56`). No reordena dentro
de un command buffer; fusiona pasadas consecutivas sobre los mismos attachments (sin comparar slice, B-07). Las
desviaciones:

- Un descriptor con algo no servido (stencil en otra textura, `renderTargetArrayLength > 1`, rasterización con más
  de una muestra, textura sin uso RenderTarget…) da **encoder nil**: la pasada entera, Clear incluido, no existe y el
  command buffer se completa (N-10).
- Un selector no implementado o un estado no servido (más de un viewport o scissor, fill mode, índice fuera de rango)
  **envenena el encoder**: se omiten todos los draws siguientes; si la pasada tenía Clear, el target sale entero del
  color de clear (N-09).
- Un scissor de **anchura 0** se toma por «sin scissor»: el draw cubre todo el target (N-04, `render.cpp:1523-1525`);
  con altura 0 se rechaza. Que CoreAnimation emita scissors de anchura 0 está sin verificar.
- Si el VSC se desborda en binning, ese frame pierde draws en los tiles del pipe, sin log (N-19).

### 2.5 Draws, mezcla y lectura del framebuffer

**Lo que usa CoreAnimation [O, catálogo de 20H392].** Quads de dos triángulos; mezcla fija sobre todo
`One, OneMinusSourceAlpha` (sourceOver premultiplicado), y además `Zero, OneMinusSourceAlpha`, `One, One`,
`DstColor, Zero` y otras; mezcla programable en el shader en 188 pipelines (vibrancia, plusD, `darkenSourceOver` y
compañía), siempre con la fija apagada; lectura del destino por `[[color(n)]]` en 354; dos o tres attachments con uno
escrito por draw y otro leído por fetch como imagen *memoryless*; cobertura de paths acumulada en un `R32Float`
(`One, One` o `Max`) y leída por `path_blit`.

**La lectura del framebuffer no es opcional [O, QuartzCore 20H392].** `create_fragment_shader` fija
`fc_framebuffer_fetch` y `fc_framebuffer_sample` a partir de dos bits de flags del contexto, y `new_metal_context` los
pone **sin condición** (`flags |= 0x2800`, 0x188488778): todo fragment shader de CoreAnimation se especializa con
`fc_framebuffer_fetch=1`, declare lo que declare el dispositivo. La rama sin fetch del uber shader (muestrear el
attachment como textura) existe en el AIR pero el CoreAnimation de iOS 16.7 no la elige. Un driver para este sistema
tiene que servir `[[color(n)]]` con su semántica completa.

**Lo que exige Metal [D].** `[[color(m)]]` lee el valor actual del attachment; los load/store de attachments desde el
fragment shader se ejecutan en orden de primitiva por fragmento, así que el blending programable es coherente sin
sincronización explícita (ANGLE: «always coherent» [R]). Las escrituras a texturas o buffers desde el fragment shader
no tienen orden salvo con `[[raster_order_group(n)]]` (Apple4). Con MSAA, `[[color(m)]]` puede hacer la función
por muestra.

**Lo que hace hakios-metal [O, anexo B].** Mezcla fija conforme: factores, ecuaciones, writeMask por attachment,
dual-source, sRGB. Se rechazan `alphaToCoverage`/`alphaToOne` y las topologías de punto o línea en el descriptor.
Fetch: correcto entre draws y en GMEM (con `FLUSH_PER_OVERLAP` y barrera en las transiciones); **no conforme dentro
de un mismo draw en sysmem**: «Within ONE draw nothing orders a pixel's read after an earlier primitive's write of
it» (`render.cpp:1588-1615`), es decir, si dos primitivas del mismo draw solapan, la de debajo se pierde (N-18);
turnip usa `FLUSH_PER_OVERLAP_AND_OVERWRITE` en sysmem. Los quads de CA no se solapan consigo mismos; los paths sí
pueden. Escribir texturas desde un draw (`inplace_copy`) y los raster order groups no están servidos (N-08).

### 2.6 Blits, compute y tile shaders

**Lo que usa CoreAnimation [O, QuartzCore y metallib de 20H392].** Blits `copyFromTexture:…toTexture:`,
`generateMipmapsForTexture:` y `copyFromBuffer:…toBuffer:`; kernels de cómputo para el nivel medio de imagen y la
atenuación del panel (`compute_apl`, `compute_apl_fast`, `sum_apl_and_compute_dimming_factor`); y **tile shaders**
con imageblocks (`tile_downsample_1/2/4/8`, `newRenderPipelineStateWithTileDescriptor:…`, `dispatchThreadsPerTile:`)
para reducir el blur cuando el dispositivo declara `supportsTileShaders` (no depende de la familia: QuartzCore nunca
pregunta por Apple4).

**Lo que hace hakios-metal [O, anexo D].** Copias en la GPU salvo arrays, 3D, formatos por bloques y argument
buffers, que la CPU lee o escribe **al codificar** (N-29: datos viejos si la fuente la escribe trabajo anterior aún en
vuelo); `generateMipmaps` servido; `synchronize*`/`optimize*` solo dejan una línea. Si un kernel de CA no compila o el
dispatch no se sirve, sus salidas no se escriben (N-31); `maxTotalThreadsPerThreadgroup` es 1024 siempre, sin el
límite por registros (N-30). Los pipelines de tile se rechazan (`CA.m:3429-3437`); como un pipeline de tile fallido
aborta backboardd (§2.2) y backboardd no aborta, el dispositivo no declara hoy `supportsTileShaders` y
CoreAnimation reduce el blur con pasadas normales [H por inferencia; lo confirma la traza].

### 2.7 Sincronización y presentación

**Lo que usa CoreAnimation [O, QuartzCore 20H392].** Una cola creada en `CA::OGL::new_metal_context` con
`setSubmissionQueue:`, `setCompletionQueue:` y `setGPUPriority:`. Por frame, `MetalContext::start_command_buffer`
hace `commandBuffer`, `enqueue`, `setProtectionOptions:` y `addCompletedHandler:`; `MetalContext::flush` vacía el
pool de buffers, cierra los encoders y, si el llamante pide esperar, usa `commitAndWaitUntilSubmitted` (si devuelve NO,
sigue por el camino normal); si no, `commit` y, cuando hace falta, `waitUntilScheduled`; con un flag de temporización
añade un `addScheduledHandler:` y dos completed handlers. `waitUntilCompleted` solo aparece en `finish`,
`finish_image`, `set_surface`, `clear_surface` y el destructor. No usa `presentDrawable:` (backboardd no tiene
`CAMetalLayer`: presenta sus propias IOSurfaces por IOMobileFramebuffer). Consecuencia para el driver [H]:
`commitAndWaitUntilSubmitted` y `waitUntilScheduled` deben volver en cuanto el trabajo está enviado; si esperan a
que termine, el render server se serializa con la GPU.

**Lo que exige Metal [D].** Una cola planifica sus command buffers en orden de `enqueue`, y un command buffer empieza
después de los anteriores de su cola; con recursos *tracked* (los que no salen de heaps) un command buffer ve lo que
escribieron los anteriores; los de heaps son *untracked* y se ordenan con fences o eventos. El scheduled handler se
llama cuando el driver ha planificado el buffer en la GPU; el completed handler, cuando la GPU termina;
`waitUntilScheduled` vuelve tras los scheduled handlers y `waitUntilCompleted` tras la GPU **y** los completed
handlers. `status` termina en `completed` o `error`, y `error` explica el fallo (p. ej. `pageFault`). `GPUStartTime` y
`GPUEndTime` son horas de host de la GPU y valen 0 hasta terminar. Los eventos son monótonos y actúan en el punto
codificado. Entre procesos, el software de Apple (WebKit, Chromium) trata *scheduled* como el punto a partir del cual
otra GPU o el compositor pueden consumir una IOSurface [R].

**Lo que hace hakios-metal [O, anexo D].** Un hilo por cola espera cada fence en orden de commit y ejecuta los
handlers en orden; todo command buffer termina con la GPU ociosa; los recursos se retienen hasta completar. Las
desviaciones:

- **Trabajo omitido y «Completed»:** todo draw, pasada, dispatch o copia rechazados se omiten y el buffer termina
  `Completed` sin error (N-02, `CA.m:5182`, `command.cpp:371-378`); un `fail()` descarta el buffer entero, también lo
  ya grabado (N-20); fallos de SMMU y fences perdidas se reportan como completados (N-22).
- **`waitUntilScheduled` prematuro** cuando el commit queda retenido (`metal_defer=1` o un evento aún no alcanzado):
  vuelve antes del `GEM_SUBMIT` (N-11). Como el swap y la copia al panel van en el mismo ring, el panel puede tomar una
  superficie sin dibujar o vieja. La función que espera de verdad, `hakios_metal_cb_wait_scheduled`, existe (parche
  opcional 0002) y el plug-in no la llama.
- **`waitUntilCompleted` antes de los completed handlers** que devuelven las copias de IOSurface (N-06).
- **`enqueue` no reserva orden** (N-21); eventos emulados en CPU por command buffer entero (N-33);
  `commitAndWaitUntilSubmitted` lo atiende la clase base (N-34, sin verificar qué hace sin el driver de Apple);
  `GPUStartTime` = hora del commit (N-37).

**La presentación, lado kernel.** El contrato con IOMobileFramebuffer lo resume §1.5: `SwapBegin`/`SwapEnd`/`SwapWait`
y el uso de la superficie mientras el panel la lee. Un framebuffer de Apple mantiene la superficie marcada en uso
mientras el panel puede leerla y notifica el fin del swap [R, Asahi]. El kernel del teléfono escribe la marca de uso
que lee `IOSurfaceClientIsInUse` en la página compartida de la superficie (`sweet_hold`, `SweetFramebuffer.cpp`), pero
en la ruta del swap CoreAnimation no la consulta: usa `IOSurfaceIsInUse` para reutilizar backing stores y colas de
imágenes, no para las superficies de pantalla [O, QuartzCore 20H392]. Con 0340 el kernel retiene las superficies hasta
su flip y frena `SwapEnd` si CoreAnimation va dos frames por delante (15 §2). La contrapresión que CoreAnimation
espera de verdad es otra: sondear `SwapWait` antes de cada frame y no actualizar mientras el swap anterior esté
pendiente (§1.3) [O]; el kernel responde 0 al instante (K-3).
Lo que tampoco hace: los campos de la petición de swap distintos de superficie, rectángulos y máscara de capas (color
de fondo, flags, marcas de tiempo), los swaps de varias capas en modo escalado («2x frame not shown»,
`SweetFramebuffer.cpp`, ruta de copia) y la semántica de los selectores de color y gamma (K-4). Las notificaciones de
vsync no hacen falta: en el A11 CoreAnimation no las pide (§1.3).

### 2.8 Lo que el dispositivo declara cambia el contrato

[O, auditoría §4] El dispositivo es `HakiosMetalDevice : _MTLDevice` con `featureProfile` 1: `supportsFamily:`
responde sí a Apple1, Apple2 y Common1 [HEREDADO + log del plug-in]. De los 105 selectores de `MTLDevice`, el plug-in
define 39; los otros 66, incluidas todas las consultas de capacidad (`supportsFamily:`, `readWriteTextureSupport`,
`areRasterOrderGroupsSupported`, `minimumLinearTextureAlignmentForPixelFormat:`…), los contesta `_MTLDevice` con la
fila de límites de Apple para ese perfil, no a partir de lo que hakios-metal implementa. El iPhone X real es Apple4
[D, `MTLGPUFamily`]: blending programable, raster order groups, imageblocks, tile shaders y memoryless.

**Lo que pregunta CoreAnimation [O, QuartzCore 20H392, todas en `new_metal_context` (0x188487e28)].**
`supportsFamily:` 1001, 1002 (cuatro veces), 1003 y 1005 (**nunca 1004**, Apple4); `supportsRasterOrderGroups`,
`supportsTileShaders`, `supportsSIMDGroup`, `supportsNativeHardwareFP16`, `supportsYCBCRFormats12` y
`supportsYCBCRPackedFormats12`, `supportsMemorylessRenderTargets`; límites `maxFragmentTextures`,
`maxFragmentSamplers`, `maxTextureWidth2D/Height2D`, `maxColorAttachments` (usa como mucho 3) y
`iosurfaceReadOnlyTextureAlignmentBytes`. No pregunta `readWriteTextureSupport`, `argumentBuffersSupport` ni los
límites de hilos. `supportsFamily:` lo contesta `_MTLDevice` desde la lista que el driver le da; otras respuestas
de la base se derivan de ella (`readWriteTextureSupport` = Apple4 ? Tier2 : 0) [O, Metal 20H392].

**Qué decide con cada respuesta [O, `MetalContext::get` (0x1882f1394) y sus consumidores].**

| Respuesta | Qué cambia en CoreAnimation |
|---|---|
| (ninguna) | `fc_framebuffer_fetch=1` siempre: blending programable obligatorio (§2.5) |
| `supportsTileShaders` | el downsample del blur con tile shaders (`BlurState::tile_downsample`, `tile_downsample_*`, `dispatchThreadsPerTile:`); si el pipeline de tile falla, aborta |
| `supportsRasterOrderGroups` (con Apple1) | rutas *in-place*: `Context::copy_destination` y `MaskCorners` (las que usan `inplace_copy`, con escritura de textura ordenada por `raster_order_group`) |
| `supportsMemorylessRenderTargets` | offscreens y capturas de backdrop *memoryless* (`capture_backdrop`, `render_subclass`, el acelerador de paths) |
| `iosurfaceReadOnlyTextureAlignmentBytes` | `CADeviceSetMinimumAlignment`: la alineación con que CoreAnimation crea sus IOSurfaces |
| `maxTextureWidth2D/Height2D` | `CADeviceSetMaxRenderableIOSurfaceSize` |
| `supportsFamily:` Apple1/2/3/5 | flags internos: Apple1 = «GPU de Apple» (activa varias rutas, también la de paths), Apple5 y FP16 |
| `supportsFeatureSet:` | qué pipelines precompilados de la library se pueden cargar |

Consecuencias para el contrato:

- La alineación es parte del contrato y tiene efecto directo: si el dispositivo declara los 64 B que exige el núcleo
  (`iosurfaceReadOnlyTextureAlignmentBytes`, `minimumLinearTextureAlignmentForPixelFormat:`), CoreAnimation crea sus
  superficies alineadas y desaparecen las copias de N-06 para ellas (N-07).
- Declarar tile shaders, ROG o memoryless compromete a servirlos: un pipeline de tile que falla aborta backboardd, y
  una ruta *in-place* sin ROG ni escritura de texturas da el `inplace_copy` rechazado de N-08.
- Lo que la familia declarada promete y el driver no da es no conforme aunque CoreAnimation no lo use hoy: swizzle de
  descriptor y heaps *placement* (Apple2, N-14, N-13, N-23).

Esto se documenta para saber qué contrato aplica, no como palanca: declarar menos de lo que la GPU puede servir
cambia el trabajo que hace CoreAnimation, no corrige el driver.

### 2.9 No conformidades

Tabla consolidada (la completa, con 37 filas y anexos por área, está en
`ios-graficos/noconformidades-driver.md`). [M] = línea del driver en la consola del teléfono (`medicion/ab/`).

| # | Dónde | Desviación | Qué exige Metal | Consecuencia visible | Sev. | Cómo confirmarlo |
|---|---|---|---|---|---|---|
| N-01 | `CA.m:1569-1641`, `1703-1719` | Pipeline creado en ejecución y ausente del catálogo → otra variante precompilada «parecida», con otras constantes [M: 4-8 por arranque] | La función con sus constantes | Otra entrada, máscara, mezcla o matriz de color en esa capa; quad lleno del color de vértice | crítica | `stands in for it` al abrir apps; traza (§5); A/B con `hm_ca_nearest` devolviendo nil |
| N-02 | `CA.m:5182`; `command.cpp:371-378` | Trabajo rechazado se omite y el buffer acaba `Completed` sin error | `status` = `error` si no se ejecuta lo codificado | Capas o pasadas ausentes; el target conserva su Clear o lo anterior | crítica | contar `refused:`; `metal_strict` pone esos buffers en `Error` |
| N-03 | `render.cpp:244-258` | Draw rechazado si un rango de constantes empujado pasa del buffer ligado, aunque no se lea [M] | Se lee lo que el shader accede | Capa o etapa de blur perdida | alta | las líneas `refused: … N are bound` |
| N-04 | `render.cpp:1523-1525` | Scissor de anchura 0 = «sin scissor» | Área cero no deja pasar fragmentos | Una capa a pantalla completa con su color | crítica si CA lo emite [H] | registrar scissors de área cero |
| N-05 | `CA.m:3772-3799`, `4435-4497` | YCbCr convertido a RGBA en CPU al crear o ligar, no al ejecutar [M] | La GPU lee la superficie al ejecutar | Verde (0,136,0) con planos vacíos; rojo, azul o cian con croma constante | alta→crítica | contador de conversiones con plano Y a cero; color capturado |
| N-06 | `CA.m:3819-3846`, `4359-4516` | IOSurface con filas no alineadas → copia refrescada al codificar y devuelta en un handler asíncrono [M] | La textura es la superficie; `waitUntilCompleted` tras los handlers | Contenido viejo, bandas, instantáneas desfasadas | alta | marcas de tiempo del write-back frente a `waitUntilCompleted` |
| N-07 | `texture.cpp:996-998` | No declara la alineación de 64 B que exige el núcleo | El dispositivo declara la alineación | Causa raíz de N-06 y N-12 | alta | imprimir la respuesta heredada |
| N-08 | `CA.m:1922-1981`; `compiler.cpp:1416-1424` | `edr_scale` cambiado por `inplace_copy`, que se rechaza (escritura de textura desde un draw, ROG) | La función pedida; ROG e imágenes en fragment | Pasada EDR inexistente; textura destino vieja | alta | `the library has no edr_scale…` + `refused: a render pipeline` |
| N-09 | `CA.m:7563-7569`, `8334-8338` | Un rechazo envenena el encoder: se omiten los draws siguientes | Cada llamada válida se ejecuta | Resto de la pasada sin dibujar; el target del color de clear | alta | `refused: this draw, because …` repetido |
| N-10 | `CA.m:5582-5616` | Descriptor de pasada no servido → encoder nil | Un encoder | Pasada entera ausente | alta | `refused: a render pass: …` |
| N-11 | `CA.m:6340-6366` | `waitUntilScheduled` antes del envío con el commit retenido | Scheduled = planificado en la GPU | Panel con superficie sin dibujar (con `metal_defer=1`) | alta (condicional) | destellos con y sin `metal_defer=1` |
| N-12 | `CA.m:4135-4170`, `2657-2669` | Texturas sobre buffer y buffers *no-copy* son copias hechas al crear | Comparten memoria | Imágenes que no se actualizan | alta [H] | `a texture over a buffer's rows … is a copy` |
| N-13 | `CA.m:1145-1166`, `4014-4018` | Heaps sin subasignación ni aliasing; agotados, nil sin log; *placement* nil | `makeAliasable` libera; placement es Apple2 | Offscreens de blur nil → pasadas omitidas | alta | `usedSize` por heap en un scroll con blur |
| N-14 | `CA.m:3647-3653` | Swizzle del descriptor: nil o ignorado | Swizzle es Apple2 | Canales cambiados o imagen ausente | alta [H uso] | registrar el swizzle pedido |
| N-15 | `texture.cpp:34-160`, `960-990` | XR, 'w30r', superficies comprimidas, planos sueltos de 420 → nil | Formatos de la familia | Capas vacías; si es la imagen de lanzamiento, solo el icono | alta | `refused: a texture: over IOSurface …` al abrir apps |
| N-16 | `CA.m:4410-4416` | Conversión YCbCr en CPU además de la del shader de CA | Una sola conversión | Tintes verde o magenta en fotos y fondos [H] | alta [H] | traza del draw del fondo: `_Iybr` o `_Isrc` |
| N-17 | `CA.m:7451-7527` | Especialización del genérico por los 52 B leídos al codificar | La GPU lee el buffer al ejecutar | Otra rama si CA escribe tras codificar [H] | media | `metal_nospec` A/B |
| N-18 | `render.cpp:1588-1615` | Fetch en sysmem sin orden entre primitivas del mismo draw | Orden de primitiva por fragmento | Solapes de un mismo draw (paths) mal | media | `metal_gmem_draws=0` frente a `=1` en un path |
| N-19 | `render.cpp:2406-2423` | VSC desbordado: draws perdidos en ese frame | Todo draw se ejecuta | Bloques sin capas en frames pesados | media | `metal_gmem_off=16` |
| N-20 | `command.cpp:603-607` | Un `fail()` descarta el command buffer entero | Falla el recurso, no el frame | Frame entero sin dibujar | alta [H frecuencia] | `no memory for`, CB en `Error` |
| N-22 | `k/0145`, `k/0153`; `command.cpp:640-670` | Fallos de SMMU y fences perdidas → «Completed» | `pageFault`, `status` error | Frames dañados presentados como buenos | media | log del kernel en el instante |
| N-24 | `CA.m:8233-8250` | Draws de `luma_boost` omitidos por defecto | Cada draw se ejecuta | Sin refuerzo de luminancia EDR | media | `luma_boost: left out` |
| N-26 | `CA.m:7870-7921` | Clamps de LOD por encoder descartados | Se aplican siempre | Blur con otro nivel de mip [H] | media | registrar los clamps |
| N-35 | `k/0205`, `k/0215`, `k/0342` | Memoria nueva sin limpiar con `gpu_zero=0` o `gpu_bocache=2` | Buffers nuevos a cero | Frames blancos, pantalla amarilla [HEREDADO] | crítica en esos modos | `sysctl kern.bootargs`, `kern.sweet_gpu_bocache` |
| K-1 | `SweetFramebuffer.cpp`, ruta de copia | Swap de varias capas en modo escalado no se enseña («2x frame not shown») | La pantalla compone las capas pedidas | El panel se queda en el frame anterior durante transiciones con varias capas | media | `SWEET FB: 2x frame not shown (layers N…)` en el log del kernel |
| K-2 | `SweetFramebuffer.cpp` | Ignora color de fondo, flags y marcas de tiempo de la petición de swap; sin notificaciones de swap completado | Contrato de IOMobileFramebuffer [R, Asahi] | Sin efecto visible conocido mientras CA no los use [H] | baja | volcar la petición de swap (`sweet_fb_swaps_logged`) |
| K-3 | `SweetFramebuffer.cpp`, selector 6 | `SwapWait` vuelve 0 al instante (cuenta y nada más) | CA lo sondea antes de cada frame (`can_update_` → `swap_wait_timeout`, hasta 1 ms) y no actualiza mientras el swap anterior siga pendiente [O, QuartzCore] | CA no tiene contrapresión propia: dibuja en la superficie que aún se copia o escanea; 0340 la suple reteniendo `SwapEnd`. Con scanout directo, «swapped again while on the panel or waiting» en más de la mitad de los frames (03 M12): es esta desviación | alta | contar en 0336 los `SwapWait` que encuentran el swap pendiente; repetir 03 M12 con `SwapWait` que espere al flip |
| K-4 | `SweetFramebuffer.cpp`, selectores 17, 22, 27, 29, 33, 50, 55, 57, 68, 74, 84 | Respondidos con éxito y ceros: tabla de gamma, área de pantalla, matriz de color, corrección de brillo, contraste, parámetros, frame info | La semántica de cada uno (tabla en `binarios-ios-20H392.md` §9) | Sin Night Shift ni filtros de color del sistema; CA puede leer una tabla de gamma o un área de pantalla a cero [H] | media | volcar entradas y salidas de cada selector la primera vez |

Orden de arreglo general (auditoría §7): compilar exactamente lo que CoreAnimation entrega (fuera N-01, N-08, N-24;
las variantes de `functions` solo como caché si las constantes coinciden con las pedidas); no omitir trabajo (recortar
y rellenar rangos de constantes, scissor vacío que descarta, rechazos locales al draw, y lo que no se pueda servir,
command buffer en `Error`); recursos que son la memoria que dicen ser (superficies con filas y planos alineados a
64 B creadas por el kernel, alineación declarada, YCbCr muestreado en la GPU al ejecutar); sincronización real
(`waitUntilScheduled` que espera al envío, `waitUntilCompleted` tras los handlers, orden de `enqueue`, eventos en la
GPU, tiempos de `CP_ALWAYS_ON`, fallos de la GPU como `MTLCommandBufferError`); heaps de verdad; y declarar
exactamente lo implementado. En el kernel: `SwapWait` con la semántica que CoreAnimation sondea (distinto de 0
mientras el swap pedido no se haya tomado en el panel), que es la contrapresión que necesita el scanout directo
(K-3); los swaps de varias capas compuestos, o un framebuffer que declare solo las capas que de verdad compone
(K-1); y la semántica de los selectores de color y gamma (K-4).

### 2.10 Interruptores de diagnóstico de CoreAnimation

Solo como herramientas para ver qué hace el compositor y aislar causas, no como arreglo. QuartzCore de 20H392 tiene
153 opciones booleanas y 54 valores (`debug_option_env_vars`, 0x1d5b4b960; `debug_value_env_vars`, 0x1d5b4be28);
tabla completa con índices y lectores en `ios-20H392/secciones/opciones-depuracion.md` [O]. `init_debug`
(0x1883794f8) las lee una vez por proceso: en un build de cliente **solo de variables de entorno** del proceso que
compone (backboardd); las preferencias de `com.apple.coreanimation` solo cuentan en builds internos. En este sistema
se ponen en el `EnvironmentVariables` del job de backboardd en `launchd.plist` (el port ya lo edita con
`tools/patch-launchd-plist.py`); su salida va al stderr de backboardd, que llega a la consola. En ejecución,
`CARenderServerSetDebugOption` exige el entitlement `com.apple.QuartzCore.debug`. Programa para enumerarlas, compilado
y firmado, sin ejecutar: `ios-20H392/tools/ca_debug_options.c` (`--server` pregunta a backboardd).

| Opción [índice] | Qué enseña o aísla | Lector |
|---|---|---|
| `CA_PRINT_OFFSCREENS` [28], `CA_PRINT_MEMORYLESS_OFFSCREENS` [126] | cada pasada offscreen que prepara el compositor | `Context::prepare_destination_` |
| `CA_PRINT_BACKDROPS` [25], `CA_COLOR_BACKDROPS` [26] | capturas de backdrop (blur, materiales) | `capture_backdrop`, `render_layers` |
| `CA_COLOR_OFFSCREEN` [17] | tiñe lo que se compone offscreen | `ContentsGeometry::fill_and_unbind` |
| `CA_PRINT_SHADERS` [27] | cada pipeline y función que crea | `create_pipeline_state`, `load_shader_function` |
| `CA_PERF_HUD` [36] (+ `CA_PERF_HUD_LEVEL`, `_ORIGIN`, `_SCALE`) | el HUD de rendimiento del compositor | `update_perf_hud`, `MetalContext::flush` |
| `CA_PRINT_TREE` [5] | el árbol de render en cada frame | `Server::render_display` |
| `CA_PRINT_FRAME_INFO` [42], `CA_EMIT_FRAME_RATE_DEBUG_SIGNPOSTS` [117] | información de frame y ritmo | `frame_info_callback`, `timer_callback` |
| `CA_DISABLE_OCCLUSION_CULLING` [11], `CA_DISABLE_HIDDEN_CULLING` [76], `CA_DISABLE_DIRTY_REGIONS` [12] | confirman que el compositor descarta capas tapadas y ocultas y recorta a regiones sucias | `prepare_layers_roi`, `Updater::prepare_layer0` |
| `CA_DISABLE_DETACHED` [21] | sin capas «despegadas» a planos de pantalla: aísla los swaps de varias capas (K-1) | `detach_contents`, `IOMFBDisplay::detach_layer` |
| `CA_DISABLE_PRECOMPILED_PIPELINES` [84], `CA_DISABLE_GENERIC_SHADERS` [82] | todo pipeline compilado en ejecución; sin calentamiento del genérico | `load_pipeline_state`, `warmup_shaders` |
| `CA_DISABLE_TILE_SHADERS` [134], `CA_DISABLE_INPLACE_SHADERS` [135], `CA_ENABLE_MEMORYLESS` | aíslan las rutas que dependen de capacidades declaradas | `MetalContext::get` |
| `CA_DISABLE_BACKDROP_CACHE` [67], `CA_DISABLE_LUMA_BOOST` [91] | aíslan la caché de backdrops y el refuerzo de luminancia | `capture_backdrop`, `IOMFBDisplay::begin_update` |
| `CA_FORCE_TIMER` (getenv directo), `CA_VSYNC_OFF` [111], `CA_MINIMUM_FRAME_DURATION` (valor 44) | ritmo de frames | `CADeviceUseVBL`, `AppleCLCDDisplay::minimum_frame_duration` |

Una prueba que estas opciones resuelven sin tocar el driver: con `CA_DISABLE_OCCLUSION_CULLING=1` el número de draws
de la pasada principal con una app opaca a pantalla completa debe subir; si sube, CoreAnimation ya descarta las capas
tapadas y el descarte en el driver (§3.4) tiene poco que ganar.

## 3. Lo que hacen los drivers de Apple y el nuestro no

Detalle, citas y cuentas en `ios-graficos/tbdr-apple-vs-adreno.md`.

### 3.1 La GPU de Apple: TBDR con memoria de tile y HSR

- **Dos fases [D, WWDC 2020 10602; Tech Talk 602].** El *tiling* transforma una vez toda la geometría del pase y la
  reparte en listas por tile (el Tiled Vertex Buffer, el Parameter Buffer de PowerVR [R]); el *render* recorre los
  tiles (32×32 o 32×16 píxeles en la familia Apple4) y en cada uno ejecuta la load action, rasteriza, decide la
  visibilidad, sombrea lo visible y ejecuta la store action. Color y profundidad viven en memoria del chip.
- **HSR [D].** «Each pixel will keep the depth and primitive ID for the frontmost primitive»; es «pixel perfect and
  submission order independent for opaque meshes». Una primitiva deja de ser opaca si mezcla, lee el framebuffer,
  hace `discard`, escribe profundidad o máscara de muestras, tiene efectos laterales o escribe con máscara de canales
  [D, 10602, 10632; O, Mesa AGX `agx_linker.c:207-227`]: entonces se sombrea lo que cubre en cuanto llega. Qué hace el
  HSR sin attachment de profundidad no está documentado [H: gana el último opaco en orden de envío].
- **Lo que en Apple es barato y en Adreno caro.** Leer el destino (blending y `[[color(n)]]`) sale de la memoria de
  tile, ordenado por hardware («blending is always something the GPU executes in order» [D]); los attachments
  *memoryless* no existen fuera del chip; load y store son programas por tile derivados de las acciones; el coste por
  tile es leer su lista de primitivas, no repetir comandos [R, Asahi]. Lo caro en Apple es vaciar el tile a mitad de
  pase (barreras de memoria en fragmentos, *partial renders* cuando se llena el Tiled Vertex Buffer).

### 3.2 El Adreno 610

- **Binning [D, Qualcomm; O, Mesa].** Un paso de binning marca en un *visibility stream* en qué bins es visible cada
  primitiva; después cada bin se pinta en GMEM y se resuelve a memoria. El procesador de comandos recorre el stream
  entero del pase **en cada bin**; el visibility stream solo permite saltar draws sin primitivas en ese bin, no draws
  tapados. Un triángulo que cruza bins se rasteriza entero en cada uno [D].
- **GMEM del A610 [O].** 128 + 4 KiB (KGSL, `adreno-gpulist.h:1499-1510`); con dos attachments de 4 bytes, bins de unos
  16 000 píxeles: 78-84 bins a 750×1624 con el reparto de turnip, 102 con el del port (10 §3.1). Plantilla
  `a6xx_gen1_low` de Mesa: sin fast-clear de GMEM, caché de la CCU en sysmem de 8 KiB de color.
- **FlexRender [D].** El driver elige por render target entre binning y render directo (sysmem); turnip decide por
  ancho de banda estimado y deja en sysmem los pases pequeños [O].
- **LRZ y early-Z [D, O].** Hay LRZ (Z de baja resolución construido en el binning) y early-Z, pero solo con
  attachment de profundidad y test activo; en el A610 sin seguimiento de dirección en la GPU ni fast-clear, así que
  turnip solo lo usa si el pase limpia la profundidad. Mezcla, lectura del framebuffer, `discard` y escrituras con
  máscara lo desactivan.
- **UBWC [O].** Disponible en el A610 (Mesa solo lo excluye en el A702); hakios-metal usa destinos lineales
  [HEREDADO: una capa a pantalla completa con mezcla cuesta 6 ms en lineal, 2,4 en tiled y 1,3 en GMEM, Mesa GL a
  1125×2436].

### 3.3 Por qué el overdraw cuesta distinto, y qué lo cambia en CoreAnimation

En Apple una capa opaca tapada por otra opaca no se sombrea; en el A610 sin profundidad se rasteriza, se sombrea con
su textura y se escribe, unos 0,6 ms por capa a pantalla completa en GMEM y 1,1-2,7 ms en sysmem a 750×1624 [HEREDADO,
escalado]. Pero el catálogo de 20H392 (§2.2) dice que casi ninguna capa de CoreAnimation es opaca en el sentido del
HSR: 581 de los 1 079 pipelines mezclan con blending fijo, 188 mezclan en el shader y 354 leen el destino; ninguno
usa profundidad. Lo que CoreAnimation aprovecha de la GPU de Apple no es tanto el HSR como que **leer el destino es
barato y no hay coste por tile en el procesador de comandos**, justo lo caro en el A610: el fetch exige orden entre
primitivas solapadas (`FLUSH_PER_OVERLAP`, barreras) y cada bin repite el stream entero (10 §3.2-3.3, 14).

Además CoreAnimation, si el dispositivo declara `supportsMemorylessRenderTargets`, hace *memoryless* sus offscreens
y capturas de backdrop (§2.8), y sus pipelines llevan dos o tres attachments por pase, uno escrito y otro leído por
fetch como imagen (`fc_memoryless_index`, §2.2) [O]. En Apple eso vive en la memoria de tile y no cuesta nada; en el
A610, mientras el driver le dé memoria y GMEM reales, un segundo attachment parte por la mitad el tamaño de los bins
(los 102 tiles de 10 §3.1, y los 42 frente a 78 de 14 §3.3 cuando no se toca). Qué attachments son *memoryless* en
la pasada principal del teléfono lo dice la traza (§5: campo `storage` de cada `tex`).

### 3.4 Estrategia razonable en el A610 sin cambiar la semántica

Por ganancia y riesgo (detalle y condiciones en `tbdr-apple-vs-adreno.md` §4):

1. **Medir antes** (riesgo nulo): factor de overdraw de la pasada principal (Σ áreas de draws / pantalla), separado en
   draws con fetch, con mezcla y opacos, y área opaca que tapa algo. La traza de §5 lo da.
2. **Lo seguro**, ya planificado en 10 y 14: retorno anticipado por tile, carga y guardado condicionados a geometría,
   menos bins (GMEM real y solo para los attachments tocados), fetch sin barreras de más, destinos tiled/UBWC en
   sysmem, y GMEM elegido por contenido (las pasadas que leen el destino van mejor en tiles).
3. **Descartar en el driver draws completamente tapados por un draw opaco posterior del mismo pase**, solo con todas
   las condiciones de conformidad: el oclusor no mezcla ni lee el destino, sin `discard`, máscara completa, geometría
   conocida en CPU que cubra por abajo la huella del tapado, nada intermedio que lea el resultado y sin efectos
   laterales. Pocos oclusores posibles en CoreAnimation; vale para clears y copias a rectángulo.
4. **Profundidad sintética para LRZ: descartada** salvo dato nuevo. Pide reordenar draws, un attachment más en GMEM
   (+25-50 % de bins) y unas 7 capas a pantalla completa tapadas para amortizarlo.

Lo que hace el propio CoreAnimation contra el overdraw: las capas opacas no se mezclan, el blur solo redibuja regiones
sucias [D, WWDC 2014 419], y la API de QuartzCore de macOS nombra regiones de actualización, opacas y no tapadas
(`CARenderUpdateGetUnobscuredRegionOfInterest`, `CARenderContextCopyOpaqueRegion`…) [O, macOS 26.7.1]. Que el render
server de iOS 16.7 omita capas tapadas por opacas no está visto [H].

## 4. Diagnóstico de los fallos visibles

Regla previa a cualquier diagnóstico visual: **comprobar que el driver está cargado** antes de mirar una captura
(`rebuild/gpu-tools/driver-en-uso.sh`: `IOUserClientCreator` de `SapphireGPU` debe nombrar a backboardd, y con
`metal_fps=1` deben llegar líneas `fps:`). Sin driver, Metal no registra dispositivo y CoreAnimation compone en
la CPU: lo que se ve entonces no dice nada del driver (14, «Lo primero»).

### 4.1 (a) Fondo difuminado oscuro y verdoso con rayas, barra translúcida blanca

**Observado [O].**

- `medicion/shots/hoja-blur.png`, `hoja-cache.png`, `hoja-nuevos.png`: con `gpu-G1`, `gpu-G2`, `gpu-G3`, `gpu-G3b`,
  `cpu-A-wip` y el binario heredado, instalados con `cp` encima del binario ya cargado, la Biblioteca de Apps sale
  con el fondo oscuro, verdoso y con rayas verticales, la barra de búsqueda blanca opaca y sin el texto «App
  Library», y las bandejas de las carpetas grises planas; con `propio-args` sale bien.
- `medicion/shots/hoja-real.png`: los mismos bundles (`propio-args`, `gpu-G3b`, `gpu-G4`, `cpu-A-wip`) instalados por
  renombrado pintan bien los cuatro, en los dos búferes.
- Las consolas de esos ensayos: `medicion/ab/ab-h820-G3-1.txt` tiene 0 bytes (ninguna línea del driver en 34 s);
  `ab-real-cpu-A-wip.txt` y `ab-real-propio-args.txt` tienen 69 y 72 líneas `fps:`.
- 14 («Lo primero»): con el bundle copiado encima, `ioreg -c SapphireGPU` no tiene ningún cliente y backboardd
  consume 250-588 % de un núcleo; con el bundle renombrado, el cliente es backboardd y consume 71-98 %.

**Explicación.** No es un defecto del dibujo del driver: en esos ensayos el driver no está. `dyld` rechaza el
binario nuevo porque el kernel conserva en el vnode la firma del primero cargado (mecanismo reproducido en la
Mac, 14), Metal no tiene dispositivo y la elección del contexto de render de CoreAnimation (§1.4) cae a su ruta
por CPU. Esa ruta dibuja los materiales de otra manera: blur oscuro con rayas, materiales con vibrancy blancos y
planos [O, capturas]. Que sea la ruta de software de CoreAnimation y no otra cosa es [H] fuerte: lo sostienen la
falta de cliente de GPU, el consumo de CPU y la desaparición del síntoma al instalar bien.

**Consecuencia para lo ya medido [H].** La captura `fin-0.png` (binario heredado a 1260 MHz, 03 M6) tiene el dock
y el widget de Calendario blancos y planos, la misma firma, y su consola no tiene líneas `fps:`. Los fallos gráficos
que el usuario vio a 1260 MHz (03 M7; los describió como líneas verdes en el blur y dock blanco) son con toda
probabilidad la ruta por CPU, no la temperatura. Se confirma repitiendo a 1260 MHz con el bundle instalado por
renombrado.

### 4.2 (b) Destellos de colores sólidos a pantalla completa al abrir una app

Sin captura ni traza del destello. Al abrir una app el render server recibe un árbol de capas nuevo (la ventana de
la app, su imagen de lanzamiento, la animación de zoom desde el icono) y, con él, pipelines, texturas y superficies
que no existían en el frame anterior: es justo donde actúan las rutas del driver que se apartan de Metal.

**Lo que no es [O, auditoría §5.1].** El driver no tiene ningún color fijo de diagnóstico (cuatro búsquedas
independientes en plug-in y núcleo); las texturas y samplers sin ligar leen (0,0,0,0); la memoria nueva sale a cero
con los boot-args por defecto.

**Hipótesis, con la evidencia de cada una:**

| | Mecanismo (§2.9) | Por qué da verde, rojo, cian o azul | Evidencia | Observación que lo decide |
|---|---|---|---|---|
| H1 | Variante sustituida (N-01) | La variante «cercana» lee la máscara o la imagen por otro canal (`_Ired` → `_Igrn`, `_Isqr` → `_Ialp`): con una textura sin alfa el quad entero toma el color de vértice o la tinta de la capa | sustituciones en cada arranque [O, consola] | líneas `stands in for it` en el segundo del destello; traza (§5) del draw sustituido y su área; A/B con un build sin `hm_ca_nearest` |
| H2 | YCbCr convertido antes de tiempo (N-05) | Planos aún a cero → verde (0, 136, 0) en BT.601; croma constante → rojo (178, 0, 0), azul (0, 48, 225), cian (76, 255, 255) [O, cálculo con `CA.m:4467-4474`] | la ruta está activa [O, consola] | contador de conversiones con plano Y a cero, con id y seed de la superficie; comparar el RGB del destello con esos valores |
| H3 | Scissor de anchura 0 = «sin scissor» (N-04) | La capa (fondo de la ventana o de la imagen de lanzamiento) se pinta sin recorte, a pantalla completa, con su color | defecto [O]; uso por CA [H] | registrar scissors de área cero con el programa ligado |
| H4 | Lo que debía tapar el icono no se dibuja (N-02, N-03, N-09, N-10, N-13, N-15) | En la apertura, CoreAnimation amplía el icono a pantalla completa y lo funde con la imagen de lanzamiento; si esta no se dibuja (formato de superficie rechazado, pasada o draw omitidos, heap agotado), se ve el icono ampliado: verde (Mensajes, Teléfono), rojo (Música), azul (Mail, Safari), cian (Tiempo) [H] | las omisiones son silenciosas [O]; draws rechazados en uso normal [O, consola] | **prueba decisiva**: abrir Mensajes, Música, Mail y Tiempo, n ≥ 3 cada una, con vídeo y consola: si el color sigue al icono de cada app, H4 (o H1 sobre el icono); si es siempre el mismo verde (0, 136, 0), H2 |

Parte del camino del frame: render prepare y execute del primer frame de un árbol nuevo (pipelines creados en
ejecución, superficies recién importadas). Mecanismos que no dan colores nuevos pero alargan o enmarcan el destello:
copia de superficie desfasada (N-06), `waitUntilScheduled` prematuro con el commit retenido (N-11), frame descartado
entero (N-20), reset de la GPU (N-22).

**Protocolo** (auditoría §5.3): comprobar el driver; `metal_fps=1` y la traza de §5 en `/var/tmp/metal.args`; abrir las
cuatro apps tres veces cada una grabando la pantalla (cámara externa a ≥ 120 fps si la captura interna no ve el frame)
y guardando la consola; para cada destello, su RGB y las líneas de los 500 ms anteriores (`stands in for it`,
`refused:`, `two-plane YCbCr`, `rows the GPU cannot take`, `over IOSurface N`, `specialise:`), y los mensajes del
propio CoreAnimation cuando una textura sobre IOSurface sale nil («Failed to allocate MTLTexture from IOSurface 0x%x»,
`update_surface`) [O, cadena de QuartzCore 20H392]; repetir con `metal_strict` (si el destello coincide con un command
buffer en `Error`, es omisión) y con `metal_gmem_draws=0`.

Por qué el plug-in sustituye en vez de fallar: si un pipeline de render sale nil dos veces, CoreAnimation aborta
backboardd (§2.2). La sustitución evita la caída pero cambia el dibujo; lo conforme es compilar exactamente lo pedido,
que con el `default.metallib` real presente es posible para todo pipeline del uber shader.

### 4.3 (c) Fecha y hora del bloqueo en rojo, barra de estado blanca

**Observado [O].**

- `medicion/shots/blur-cpuA-2-0.png`: pantalla de bloqueo con la fecha y la hora en rojo saturado. Se tomó con
  `cpu-A-wip` copiado encima (sin driver: §4.1).
- En los arranques con el driver cargado, la consola registra en cada arranque de 4 a 8 pipelines que CoreAnimation
  crea en tiempo de ejecución y que el plug-in sustituye por «la variante más cercana»
  (`medicion/ab/*.txt`, mensaje `CoreAnimation's X is not in the library: Y stands in for it`). Entre ellas:
  `TmuaA2Xhf_Ired_Icir` → `TmuaA2Xhf_Igrn_Icir` (`ab-v1260-defer-1.txt`), `TimgA2Xhf_Isqr` → `TimgA2Xhf_Ialp`,
  `TcimA2S1Xhfn_IsrcN3Oc3mtc4` → `TcimA2S1Xhf_IalpCcl`, y `TvdkA2Xhf_Isrc` → «nothing of the same kind stands in for it»
  (`ab-propio-args-1.txt`).
- [HEREDADO, `hakios-xnu-kernel/CHANGELOG.md`, 2.3.4] HackiOS atribuyó a esa misma sustitución, cuando elegía una
  variante fija, «the red at the top of the default wallpaper … the white band behind the status bar
  (`darkenSourceOver`)».

**Explicación.** El rojo saturado es la firma de una máscara de un canal leída como color: una textura R8 o L8
muestreada da (r, 0, 0, 1). El uber shader de 20H392 la convierte con `fc_image_function` (16 = rrrr, 17 = aaaa,
8 = solo alfa…) o CoreAnimation le pone un swizzle de textura (R, R, R, 1); si ninguna de las dos cosas se aplica, el
texto sale rojo [O, semántica del AIR, `shaders-pipelines-20H392.md` §1.4.3]. En la ruta Metal hay dos mecanismos del
driver que lo producen: la variante sustituta con otra `fc_image_function` (N-01: p. ej. `_Isrc`, RGBA tal cual, en
lugar de `_Ired`) y el swizzle del descriptor ignorado en texturas sobre IOSurface (N-14). La banda blanca de la barra
de estado es la otra mitad de la misma familia: el degradado de legibilidad se compone con
`fc_blend_function` 46 (`darkenSourceOver`: sourceOver con cobertura (luma(D))⁴, `Bdso` en las etiquetas); dibujado
con otra mezcla, queda una banda blanca opaca. En la captura sin driver la causa es la ruta por CPU, que no aplica
esa conversión o ese filtro [H].

**Cómo confirmarlo.** En el arranque con el síntoma: (1) `driver-en-uso.sh`; (2) si el driver está, las líneas
`stands in for it` de la consola y una traza del frame del bloqueo (§5): para el draw de la hora, el formato de su
textura (`tex fmt`, R8/L8), si pidió swizzle (`swizzled`), de dónde salió el fragment (`fs_from` = `variant`, `nearest`
u `own`) y su `fc_image_function`; para la barra, su `fc_blend_function`; (3) si no está, es §4.1.

**Arreglo general.** Compilar exactamente la función que CoreAnimation pide, con sus valores de constantes, a
partir del `default.metallib` real de 20H392 (existe: §2), y aplicar el swizzle del descriptor también en las
texturas sobre IOSurface: sin sustitutos ni swizzles perdidos no hay canal equivocado.

### 4.4 (d) 20-25 fps con el hilo de render saturado

**Observado [O]** (03 M1-M2, M6, M7; 10 §1): el hilo `com.apple.coreanimation.display.primary` de backboardd pasa el
84-90 % del tiempo en CPU, el 46-60 % dentro del driver; ~150 draws por command buffer a 126-163 µs cada uno
(19-24 ms por frame); la pasada principal tarda 16-24 ms de GPU y las pasadas a pantalla completa en sysmem 18-36 ms;
«a buffer made to committed» 26-30 ms de media; los huecos entre commits caen en «20-50 ms» o «más de 50 ms».

**Explicación, y lo que ya la confirmó.** Dos límites, cada uno por encima de un intervalo: la CPU del hilo que
codifica (*render execute*, §1.3) y la GPU. El número de fps sale además cuantizado: CoreAnimation arranca cada frame
en un tick de su reloj a la frecuencia que publica el kernel (`IOMFBDisplayRefresh`, 120 Hz; §1.3), así que un frame
de 30-42 ms de hilo deja huecos de 33,3, 41,7 o 50 ms [H coherente con 09 §2.5]. El límite de CPU tenía dos causas,
y las dos están medidas:

- **El modelo de coste del driver.** Metal concentra validación y traducción en la creación del pipeline y deja el
  draw barato; CoreAnimation se apoya en eso (un draw por capa, ~150 por frame). El driver validaba, regeneraba y
  filtraba el estado completo en cada draw (10 §2). La rama `cpu-draw` lo baja de ~150 a 59 µs por draw (03 M9).
- **Un defecto del kernel:** XNU vaciaba la L2 del clúster A73 antes de cada WFI (16; 439-518 µs por entrada en
  reposo en las CPU 0-3, 03 M10): el hilo de render perdía su caché cada vez que el núcleo descansaba. Con
  `kern.sweet_idle_cache=0` (0344/0350, por defecto desde 0351) y el driver fusionado, 16-26 µs por draw y 44-55
  buffers por segundo (03 M10, M12).

Con eso el hilo de render deja de estar saturado (pasa casi un cuarto del tiempo esperando su tick, 03 M11) y lo que
fija los frames es el encadenado: por frame, ~13,7 ms de CPU del hilo (7,2 de QuartzCore, 3,4 del driver) y 12,5 ms
de GPU, de ellos 8,3 de dibujo y 4,15 de la copia escalada del kernel (03 M11): entre uno y dos intervalos de 120 Hz.
En la GPU pesan la pasada principal (10-11 ms en 78 tiles) y pasadas a pantalla completa de pocos draws (7 draws,
6-8 ms en sysmem, 03 M12) que la traza de §5 debe identificar (candidatas: la captura del fondo de los materiales,
752×1626, y los posprocesos sobre el destino, §1.4). Desviaciones de §2 que pesan en el tiempo y no en el resultado:
la especialización del genérico en el hilo que codifica (816 ms por variante la primera vez; mientras compila se
dibuja con el genérico), las formas asíncronas de creación de pipelines hechas síncronas (N-36), el fetch con
barreras y la contrapresión por retención de `SwapEnd` en vez de por `SwapWait` (7,6 % del hilo dentro de la llamada
de IOMobileFramebuffer, 03 M11; K-3).

**Cómo confirmarlo.** `thrtop`/`psamp` del hilo (cuota del driver), «us of ours each» y «a buffer made to committed»
de `metal_fps`, el histograma `swap interval` de 0336 (picos en múltiplos de 8,33 ms) y, con la traza (§5), pasadas,
draws por pasada y por programa, y tiempo de GPU por pasada.

## 5. Qué mirar de un frame

### 5.1 La traza que hace falta

Entender un frame es tener, para un command buffer entero, la lista de lo que CoreAnimation pidió y lo que el driver
hizo con ello. Por command buffer: etiqueta, momentos de creación, commit, scheduled y completed, y si acabó con
trabajo omitido. Por pasada: cada attachment (textura, tamaño, formato, uso, *storage mode*, si es IOSurface y cuál),
load y store action, clear color, y si el driver la hizo en GMEM (cuántos tiles) o en sysmem, con su tiempo de GPU.
Por draw: etiqueta del pipeline, funciones y constantes (o la clave de especialización del genérico), **si el
programa compilado es el pedido o un sustituto**, mezcla por attachment, si lee el destino y cuál, texturas
(tamaño, formato, sampler) y buffers ligados, primitiva y número de vértices, scissor, viewport y área cubierta, y si
se rechazó, se omitió o esperó compilación. Por blit y dispatch: operación, origen, destino, tamaños, función.

Con eso se responde lo que hoy no se sabe: qué pasadas hace cada material y a qué escalas (§1.4), cuántos draws leen
el destino (§3.3), el factor de overdraw y la fracción opaca (§3.4), qué pasadas a pantalla completa en sysmem son las
caras (§4.4), y qué draw sustituido, rechazado o mal convertido coincide con cada destello (§4.2, §4.3).

### 5.2 Anomalías que un analizador debe marcar

- Draw con programa sustituto (`stands in for it`) o rechazado; command buffer «completed» con trabajo omitido.
- `Load` sobre un attachment que nadie escribió antes en la traza; `DontCare` seguido de `Load`; pasada cuyo resultado
  no lee nadie después.
- Pasadas consecutivas sobre el mismo target (candidatas a fusión) y cadenas de reducción y ampliación del blur con
  sus escalas.
- Draws completamente cubiertos por un draw opaco posterior de la misma pasada (candidatos a descarte conforme, §3.4).
- Textura sobre IOSurface leída por copia (filas no alineadas, YCbCr) y la edad de esa copia frente al seed.
- Scissor de área cero; constantes ligadas más cortas que lo declarado.

### 5.3 La herramienta: `metal_trace=frame` y `trace-frame.py`

Escrita sin teléfono, compilada y probada con trazas sintéticas; no se ha ejecutado todavía en el teléfono.
Todo en `~/sapphire-angel/research/metal/ios-graficos/trace/` (fuera de git), con su `LEEME.md`:

- `0001-plug-in-metal_trace-frame.patch`: el modo en el plug-in. Al tocar `/var/tmp/metal.trace` (el plug-in lo mira
  cada 100 ms) vuelca los K command buffers siguientes **completos** a `/var/tmp/metal-trace-<pid>-<n>.txt`, en líneas
  `tipo clave=valor`: `cb` (tiempos, estado, trabajo omitido, pasadas GMEM, tiles), `enc`/`att` (attachments con
  load/store/clear), `tex` (memoria: IOSurface o propia, formato, uso, *storage*, copia o conversión YCbCr), `samp`,
  `pipe` (etiqueta, funciones, **de dónde salió el código de cada etapa**: `variant:`, `nearest:… (for PEDIDA)`,
  `instead:inplace_copy(edr_scale)` u `own`; constantes; mezcla por attachment en `pblend`; fetch), `draw` (primitiva,
  vértices, scissor, viewport, área, caja real de los vértices transformados, especialización `hit`/`pending`,
  resultado `ok`/`refused`/`left out`), `dtex`/`dsamp`/`dbuf` (con los primeros 64 bytes de cada buffer ligado), `blit`,
  `dispatch` y `gpass` (cada pasada del núcleo: GMEM o sysmem, tiles, motivo, µs de GPU). Con el modo apagado, coste
  de un booleano por command buffer. Interruptores: `metal_trace=frame`, `metal_trace_cbs=K`, `metal_trace_every=S`,
  `metal_trace_dir=DIR`; el disparador admite `K` y `proc=NOMBRE`.
- `0002-nucleo-hakios_metal_program_fs_traits.patch` (opcional): qué attachments lee cada fragment por fetch y si
  descarta; no cambia la clave de la caché de shaders.
- `trace-frame.py`: resumen por command buffer y por pasada (target, load/store, draws, cobertura, programas, fetch,
  texturas leídas, especialización, GMEM/sysmem, tiempo) y las anomalías de §5.2, con la geometría real de los quads
  (la convención de las funciones de vértice de 20H392: `mvp_matrix` en el buffer 2, posición en el atributo 0 o en
  el `SurfaceVertex` del genérico) para afirmar coberturas. `--draws --cb N` lista cada draw.
- `pruebas/test_trace_frame.py`: trazas sintéticas con una anomalía de cada clase y contrato de formato contra el
  plug-in.

Qué bundle usar: `rebuild/out/trace-merge` es el driver fusionado que lleva el teléfono (`merge-1`, 98d2c3c) con la
traza (parche rebasado en `trace/merge/0001-plug-in-metal_trace-frame.patch`; el plug-in es idéntico en 98d2c3c,
2ee78db y 6d3f273, y 0002 aplica a los tres); `rebuild/out/trace` es el driver base `620950c` con la traza. Se
instala por renombrado (`rebuild/gpu-tools/instalar-por-renombrado.sh trace-merge`) y se comprueba con
`driver-en-uso.sh`. El analizador entiende además los bits de `merge-2` que dicen por qué una pasada fue a tiles.

**Capturas que deciden** (comandos exactos en el `LEEME.md`): la Biblioteca de Apps (blur y vibrancia), el Centro de
Control abriéndose, el home quieto y en movimiento, la pantalla de bloqueo (la hora: §4.3) y la apertura de Mensajes,
Música, Mail y Tiempo, tres veces cada una (§4.2). Siempre tras comprobar que el driver está dentro.

## 6. Bibliografía

Selección comentada. Las listas completas, con las citas literales de cada hecho, están fuera de git en
`~/sapphire-angel/research/metal/ios-graficos/`: `bibliografia-apple-ca-metal.md` (CoreAnimation, timing,
presentación, IOSurface, contrato de Metal, render server, DCP), `tbdr-apple-vs-adreno.md` (arquitecturas de GPU),
`shaders-pipelines-20H392.md` y `binarios-ios-20H392.md` (binarios de 20H392). Fiabilidad: **A** = Apple oficial,
**T** = tercero fiable, **T?** = tercero con reservas.

### 6.1 Fuentes primarias propias (binarios de Apple, consultados el 2026-11-14)

| Fuente | Qué aporta | Fiabilidad |
|---|---|---|
| IPSW `iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw` (CDN de Apple, `updates.cdn-apple.com/2025FallFCS/fullrestores/122-77006/…`), leído por rangos HTTP sin descargarlo entero | `QuartzCore.framework` de 20H392 (CFBundleVersion 1045.17.2): `default.metallib` (141 funciones AIR 2.5), `default.pipelinelib/` (`functions`, `pipelines.desc`, `pipelines.g10p`); mtree del sistema raíz; cryptex SystemOS con el dyld shared cache | A (binario) |
| dyld shared cache de 20H392 (cryptex SystemOS `087-86593-047.dmg`, leído en streaming sin guardarlo): QuartzCore, Metal, IOMobileFramebuffer, IOSurface, IOGPU, AGXMetalA11, con los símbolos locales del subcaché `.symbols` | Ritmo de frames y contrapresión (`CADeviceUseVBL`, `swap_wait_timeout`), selectores de IOMobileFramebuffer, consultas de capacidad y lo que deciden, creación y fallo de pipelines, flush del command buffer, opciones `CA_*` (`binarios-ios-20H392.md`, `ios-20H392/secciones/`) | A (binario) |
| `metal/quartzcore-functions.txt` (repo) | Lista de las 141 funciones; idéntica a la del metallib de 20H392 | A (derivado) |
| Consolas del driver en el teléfono, `research/metal/medicion/ab/*.txt` | Sustituciones de variantes, draws rechazados, especializaciones, copias de IOSurface y YCbCr, tiempos de pasada | O |

### 6.2 Apple

| Fuente | Fecha | Qué aporta | Fiab. |
|---|---|---|---|
| WWDC 2014 419, *Advanced Graphics and Animations for iOS Apps*, transparencias: <https://devstreaming-cdn.apple.com/videos/wwdc/2014/419xxli6f60a6bs/419/419_advanced_graphics_and_animation_performance.pdf>; transcripción <https://asciiwwdc.com/2014/sessions/419> | 2014-06 | Render server como proceso aparte; fases del commit; pasadas de máscara (3), blur (5), vibrancy (+2); caché de `shouldRasterize` (2,5× pantalla, 100 ms); opacidad de grupo | A (la transcripción, T) |
| Tech talks 10855, 10856, 10857 (*Explore UI animation hitches and the render loop*; *… commit phase*; *… render phase*): <https://developer.apple.com/videos/play/tech-talks/10855/> (y 10856, 10857) | 2020-12-21 | Render loop en cinco fases, doble/triple búfer, hitches, render prepare/execute, pasadas offscreen y sus causas. La mejor fuente oficial sobre el render server | A |
| WWDC 2021 10147, *Optimize for variable refresh rate displays*: <https://developer.apple.com/videos/play/wwdc2021/10147/> | 2021-06 | `timestamp`/`targetTimestamp`, CADisplayLink por vsync, frame pacing | A |
| WWDC 2020 10615, *Build GPU binaries with Metal*: <https://developer.apple.com/videos/play/wwdc2020/10615/> | 2020-06 | MSL → AIR → binario en el dispositivo (MTLCompilerService), caché de shaders, `MTLBinaryArchive` | A |
| WWDC 2020 10631 y 10632 (*Bring your Metal app to Apple silicon Macs*; *Optimize Metal Performance for Apple silicon Macs*) | 2020-06 | Blending programable, tile shaders e imageblocks solo en GPUs de Apple; TBDR, load/store, memoryless | A |
| WWDC 2014 604, *Working with Metal: Fundamentals* | 2014-06 | Lectura del color del framebuffer en el fragment shader desde Metal 1 en iOS | A |
| *Metal Shading Language Specification* 4.1: <https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf> | 2026-06 | `[[color(m)]]`, raster order groups, tile functions, imageblocks, function constants, sRGB | A |
| *Metal Feature Set Tables*: <https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf> | 2026-10 | A11 = Apple4; qué familia introduce cada capacidad | A |
| Referencia de Metal (`MTLCommandBuffer`, `MTLLoadAction`/`MTLStoreAction`, `MTLHazardTrackingMode`, `MTLFence`, `MTLEvent`, `MTLPixelFormat`, `MTLSamplerDescriptor`, `makeTexture(descriptor:iosurface:plane:)`, `makeFunction(name:constantValues:)`), en `https://developer.apple.com/documentation/metal/…` | consulta 2026-11-14 | El contrato que el driver debe cumplir (§2), con citas literales en `bibliografia-apple-ca-metal.md` H5.x | A |
| Referencia de IOSurface (`IOSurfaceLock`/`Unlock`, `LockOptions`, `GetSeed`, `IsInUse`, `CreateMachPort`): <https://developer.apple.com/documentation/iosurface> | consulta 2026-11-14 | Semántica de lock, seed, uso entre procesos | A |
| Referencia de QuartzCore (`CATransaction`, `CALayer`, `CADisplayLink`, `CAMetalLayer`) | consulta 2026-11-14 | Transacciones, rasterización, opacidad de grupo, drawables | A |
| *Metal Best Practices Guide* y *Metal Programming Guide* (archivo) | 2016-2017 | Load/store, drawables, visibilidad CPU↔GPU por commit y completado | A (archivo) |
| Foro de Apple, hilo 727037 (*Capturing MTLPipelineLibrary is not supported*): <https://developer.apple.com/forums/thread/727037> | 2023-03 | Un ingeniero de Apple confirma la API privada `newPipelineLibraryWithFilePath:` y su uso por CoreAnimation | A (foro) |
| Foro de Apple, hilo 741156: <https://developer.apple.com/forums/thread/741156> | 2023-11 | backboardd es el render server de iOS | A (foro) |

### 6.3 Ingeniería inversa y terceros

| Fuente | Fecha | Qué aporta | Fiab. |
|---|---|---|---|
| Asahi Linux, driver DCP: <https://github.com/AsahiLinux/linux/tree/6ba0637d1ed9a2e3639dd3fc9eca6cd0483a6434/drivers/gpu/drm/apple> (`iomfb_template.h`: petición de swap) y m1n1 `proxyclient/m1n1/fw/dcp/ipc.py` | 2026-11 | Estructura de la petición de swap (4 capas IOSurface, rectángulos, color de fondo, marcas de tiempo), `swap_complete`; modelo de datos de IOMobileFramebuffer | T |
| Asahi Linux, informes de progreso (agosto y septiembre de 2021; Linux 6.19, febrero de 2026) | 2021-2026 | DCP, page flipping sin tearing, marcas de tiempo del swap | T |
| Alyssa Rosenzweig, *Dissecting the Apple M1 GPU* I y IV (<https://alyssarosenzweig.ca/blog/asahi-gpu-part-1.html>, `…part-4.html`) y *The Apple GPU and the Impossible Bug* (`…part-5.html`) | 2021-01-07, 2021-05-02, 2022-05-13 | Herencia PowerVR, blending en código de shader, Tiled Vertex Buffer = parameter buffer, partial renders | T |
| Saar Amar, CVE-2021-30807 y CVE-2021-30883 (IOMobileFramebuffer en A11): <https://saaramar.github.io/IOMFB_integer_overflow_poc/> | 2021 | En el iPhone X IOMFB es una kext del AP (`AppleMobileDispH10P`), sin DCP; métodos del user client | T |
| Crash log de backboardd de iOS 15.2.1 en los foros de Apple (adjunto `08d2afda…`) | 2023-02 | Hilos `render-server`, `display.primary` (`CA::WindowServer::IOMFBServer`), `frameinfo.primary`, `CA::OGL::AsynchronousDispatcher` | T |
| Aditya Vaidyam, *The Secret Life of Core Animation* y *CAPluginLayer & CABackdropLayer* (2018); `avaidyam/QuartzInternal` | 2018 | Capas internas de QuartzCore, backends SW/OGL/Metal, `CABackdropLayer` (`scale`, `groupName`) | T? (macOS) |
| `qingralf/iOS16-Runtime-Headers`, `theos/headers` (QuartzCore) | 2021-2022 | Cabeceras privadas de iOS 16: `CABackdropLayer`, `CAFilter` (`kCAFilter*`), `CADisplay`, `CAWindowServer` | T (nombres y tipos) |
| Mesa freedreno/turnip (`767fbf7c`), `docs/drivers/freedreno.rst` | 2026-11 | Grupos de draw state, GMEM, binning, LRZ, autotune: la referencia para un driver de Adreno (detalle en 10, 14 y `tbdr-apple-vs-adreno.md`) | T |
| ANGLE, backend Metal: <https://github.com/google/angle/tree/99a746a6e378fcb2e57d89cf47a0310800d7411a/src/libANGLE/renderer/metal> | 2026 | Uso correcto de Metal en 2D: grabar antes de codificar, `DontCare` por defecto, framebuffer fetch solo en familias Apple | T |
| Chromium `iosurface_image_backing.mm` y WebKit `RemoteLayerBackingStore.mm` | 2026 | Coherencia de IOSurface entre procesos en el punto *scheduled*; WebKit entrega IOSurfaces a CoreAnimation como `contents` | T |
| Skia Graphite (`src/gpu/graphite`) y su presentación en el blog de Chromium (2025-07-08) | 2025-2026 | Orden por clave (pintor → pipeline → bindings), fusión de draws, lectura del destino por fetch o por copia | T |

### 6.4 Arquitectura de GPU (Apple y Adreno)

Copias de las fuentes de Apple y Qualcomm con `SHA256SUMS` en `ios-graficos/tbdr-fuentes/`.

| Fuente | Fecha | Qué aporta | Fiab. |
|---|---|---|---|
| WWDC 2020 10602, *Harness Apple GPUs with Metal*: <https://developer.apple.com/videos/play/wwdc2020/10602/> | 2020-06-24 | Fases del TBDR, Tiled Vertex Buffer y partial render, HSR (profundidad e ID de primitiva por píxel), blending sin unidad dedicada, programmable blending | A |
| WWDC 2020 10603, *Optimize Metal apps and games with GPU counters* | 2020-06-25 | HSR «submission order independent for opaque meshes» | A |
| Tech Talks *Metal 2 on A11* (602-606): <https://developer.apple.com/videos/play/tech-talks/602/> | 2017-09-12 | TBDR en toda la serie A, memoria de tile, imageblocks de 32 KB, raster order groups en la A11 | A |
| WWDC 2019 606, *Delivering Optimized Metal Apps and Games* | 2019-06-05 | «iOS GPUs are excellent at reducing opaque overdraw» | A |
| *Tailor your apps for Apple GPUs and tile-based deferred rendering*: <https://developer.apple.com/documentation/metal/tailor-your-apps-for-apple-gpus-and-tile-based-deferred-rendering> | — | Imageblocks bajo control desde la A11 | A |
| Qualcomm, *Snapdragon Game Developer Guide* (80-78185-2), *Overview* y *Adreno GPU on Mobile: Best Practices*: <https://docs.qualcomm.com/doc/80-78185-2/topic/overview.html>, `…/mobile_best_practices.html` | sin fecha | Binning y visibility stream, FlexRender, LRZ y lo que lo desactiva, early-Z, UBWC, minimizar bins | A (Qualcomm) |
| Qualcomm, product brief del Snapdragon 680 | 2022-11 | Memoria 2×16 LP4x a 2133 MHz | A (Qualcomm) |
| Imagination, *Introduction to PowerVR for Developers* (TBDR, HSR): <https://docs.imgtec.com/starter-guides/powervr-architecture/> | — | Origen del HSR y del parameter buffer | T |
| Danylo Piliaiev (Igalia), *Low-resolution-Z on Adreno GPUs*: <https://blogs.igalia.com/dpiliaiev/adreno-lrz/> | 2022-07-13 | Reglas del LRZ, del autor del LRZ de turnip | T |
| Rob Clark, *freedreno update: new year edition*: <https://bloggingthemonkey.blogspot.com/2014/01/freedreno-update-new-year-edition.html> | 2014-01-08 | Binning por hardware; poca ganancia para gestores de ventanas | T (época a3xx) |
| Mesa `767fbf7c` (`docs/drivers/freedreno.rst`, `docs/drivers/freedreno/hw/lrz.rst`, `docs/drivers/asahi.rst`, `src/freedreno/…`, `src/asahi/…`) y KGSL (CodeLinaro graphics-kernel `f900d903`) | 2026-11 | Fila del A610, GMEM de 128 + 4 KiB, LRZ, UBWC, clasificación de shaders de AGX para el HSR | T |
