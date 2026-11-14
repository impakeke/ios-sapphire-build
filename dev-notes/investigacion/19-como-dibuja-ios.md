# 19 — Cómo dibuja iOS: el camino de un frame y el contrato de CoreAnimation con Metal

Documento de referencia (2026-11-14). Pregunta: qué hace iOS 16.7.16 (20H392) para poner un frame en la pantalla,
qué espera CoreAnimation de un driver Metal correcto y dónde se desvía el nuestro (hakios-metal, upstream `63fc2b4`
más los parches A610), para arreglarlo de forma general en el driver y en el kernel, no con atajos sobre CoreAnimation.

Convención de evidencia: **[O]** observado en un binario de Apple (offset o símbolo), en código (archivo:línea) o en
una medida propia; **[D]** documentado por Apple (URL en §6); **[R]** ingeniería inversa de terceros fiable (URL en §6);
**[H]** hipótesis. Lo heredado (comentarios y docs de HackiOS, `NOTES.md`) cuenta como [H] hasta verlo en código o
en binario. El material extraído de Apple está fuera de git, en `~/sapphire-angel/research/metal/ios-graficos/`.

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
(más `display.wireless0-2`, pantallas virtuales sin uso) existen allí con política de prioridad fija, 55 y 54 [O,
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
- **El reloj.** En un iPhone el frame arranca con el vsync del panel. Aquí CoreAnimation no recibe ningún vsync:
  nunca activa las notificaciones del framebuffer (el selector 72 no aparece en ningún arranque) y marca su ritmo
  con un reloj propio a la frecuencia que el kernel publica en `IOMFBDisplayRefresh` y `TimingElements`, 120 Hz
  (09 §2.4; `SweetFramebuffer.cpp`, `publishModes`). Cuando un frame tarda más de un intervalo, el panel sigue
  enseñando el anterior y el siguiente frame arranca en el siguiente tick libre: con 120 Hz, un frame de 30-42 ms
  deja huecos de 33,3, 41,7 o 50 ms (09 §2.5, [H] coherente con lo medido).

### 1.4 El compositor: pasadas y draws

**La pasada principal.** El pipeline lineal de capas, de atrás adelante, acaba en una pasada sobre la superficie de
pantalla: 750×1624, `BGRA8Unorm` (formato 80), con 99-152 draws en movimiento y 108 en reposo [O, 03 M2, M6;
`medicion/ab/`]. Cada draw es un quad: «primitive 3, 6 vertices» (triángulos, dos por capa) con el uber shader
(`fixed_vert_lph_spc` + `fixed_frag_lph_cph`/`_cpf`) [O, consola]. No hay buffer de profundidad: el orden de
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

(en redacción: el detalle de cada pasada del blur y de los casos concretos sale de los binarios de 20H392 y de la
traza de §5)

### 1.5 La presentación

- **Lo que entrega backboardd.** Dos IOSurfaces de 750×1624 BGRA (ids 2 y 3, 3 072 bytes por fila) que alterna
  como superficies de pantalla, y un único layer a pantalla completa por swap; el orden observado es submit del
  command buffer y, a continuación, swap (09 §1). Pide el swap con `IOMobileFramebufferSwapBegin` (un id),
  `SwapSetLayer` y `SwapEnd` (la petición de 0x46c bytes, cuyo formato coincide campo a campo con el `dcp_swap` que
  documenta Asahi para el DCP [R], 12 §9.20), y llama a `SwapWait` (selector 6).
- **Lo que hace el kernel del teléfono.** Copia y escala ×1,5 la superficie al buffer del panel con el blitter de la
  GPU y hace el flip del plano VIG0 del MDP (09 §2). Con `kern.sweet_fb_queue=1` (0340), cada frame se copia a su
  propio buffer, se enseña en orden cuando la copia termina, la superficie sigue en uso hasta su flip y `SwapEnd`
  espera (hasta 50 ms) si CoreAnimation va más de dos frames por delante: es la contrapresión que un framebuffer
  real ejerce reteniendo las superficies (15 §2). Medido con 0342: frames pisados de 10,6 % a 0 (03 M7).
- **Lo que hace un iPhone** (en redacción: se completa con IOMobileFramebuffer de 20H392 y Asahi).

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
`CA::OGL::new_metal_context`, que abre la pipeline library de QuartzCore a través de
`MTLPipelineLibraryBuilder::newLibraryWithFile` y necesita del dispositivo una `targetDeviceInfo`. Si no hay
dispositivo, compone por CPU (§4.1).

### 2.2 Shaders y pipelines

**Qué trae 20H392 [O].** `QuartzCore.framework` contiene `default.metallib` (141 funciones en AIR, cada una en
variante `_lpf` y `_lph`; sha256 `11c74cc4…`) y `default.pipelinelib/` con `functions`, `pipelines.desc` y binarios
precompilados para las GPU de Apple, `pipelines.g4p` … `pipelines.g15p` (el del iPhone X es `g10p`). Fuentes: el
mtree del IPSW (`087-86698-044.dmg.mtree`) y los ficheros leídos por rangos del DMG raíz (`ios-graficos/qc-20H392/`).
La afirmación de HackiOS de que este sistema «no tiene `default.metallib`» (`CA.m:1412-1414`, `tools/ca-metallib.py`)
es falsa para 20H392.

**Qué pide CoreAnimation [O, consola del teléfono; R, NOTES].** Pipelines con nombre de la pipeline library
(`newRenderPipelineStateWithName:options:reflection:error:`) y, para lo que no está en ella, funciones
especializadas en tiempo de ejecución (`newFunctionWithDescriptor:error:` con valores de function constants) y
`newRenderPipelineStateWithDescriptor:`. El uber shader tiene dos formas:

- `fixed_vert_lph_spc` + `fixed_frag_lph_cph`/`_cpf`: especializado por function constants. La consola enumera los
  valores con que se enlaza cada uno, p. ej. `4=1 6=2 8=1 16=1 29=3 30=54 33=1 35=1 46=17 50=1 52=1`
  (`medicion/ab/ab-propio-args-1.txt`).
- `fixed_vert_lph_gen` + `fixed_frag_lph_cpf`: genérico, lee su configuración en tiempo de ejecución de 52 bytes del
  buffer 0. El driver lo especializa por el contenido de esos 52 bytes: «specialise: fixed_vert_lph_gen+fixed_frag_lph_cpf
  for 52 bytes of its buffer 0: 96 instruction words, not 32064, in 816 ms» (71 veces en los registros de
  `medicion/ab/`).

**Qué exige Metal [D].** Una función creada con valores de constantes se comporta como el AIR con esos valores; un
pipeline con nombre de una pipeline library equivale al descriptor que la library guarda para él.

**Qué hace hakios-metal [O].** Identifica cada variante del uber shader por su etiqueta
(`com.apple.coreanimation.frag.…`) y compila la variante precompilada de `functions` que la etiqueta nombra; si la
etiqueta no está, compila **otra**, «la más cercana» (`hm_ca_nearest`, `CA.m:1569`): en cada arranque con el driver
cargado la consola registra de 4 a 8 sustituciones, p. ej. `TmuaA2Xhf_Ired_Icir` → `TmuaA2Xhf_Igrn_Icir`,
`TimgA2Xhf_Isqr` → `TimgA2Xhf_Ialp`, `TcimA2S1Xhfn_IsrcN3Oc3mtc4` → `TcimA2S1Xhf_IalpCcl`, y una sin sustituto
(`TvdkA2Xhf_Isrc`: «nothing of the same kind stands in for it»). Es la no conformidad de más consecuencia visible: el
draw se ejecuta con otra configuración de entrada, máscara, mezcla o matriz de color (§4.3).

(en redacción: detalle de la auditoría del plug-in y de los shaders)

### 2.3 Recursos: buffers, texturas, IOSurface

**Buffers de constantes [O, consola].** El driver rechaza draws cuyo buffer ligado es más corto que lo que el
shader declara: «refused: a draw of fixed_vert_lph_spc+fixed_frag_lph_cph … fixed_frag_lph_cph reads 64 bytes at 0 of
constant buffer 2; 16 are bound» y «refused: a draw of downsample_blur_vert_lph+narrow_blur_27_frag_lph …
downsample_blur_vert_lph reads 64 bytes at 0 of constant buffer 3; 48 are bound» (`ab-gmem0-*.txt`,
`ab-nobin-2.txt`, `ab-r-stop-3.txt`). Metal no valida eso en ejecución: la GPU de Apple ejecuta el draw y el shader
especializado lee solo lo que usa. Rechazarlo quita una capa o una etapa de un blur del frame.

**Texturas sobre IOSurface [O, consola].** Si la fila no es múltiplo de 64 bytes, el driver no muestrea la superficie
sino una copia por CPU «made again when the surface changes» (filas de 2 848 y 480 bytes en los registros); las
superficies YCbCr de dos planos (formato privado 500) se leen a través de una copia RGBA8 convertida por CPU, también
rehecha cuando la superficie cambia. En Metal, una textura sobre una IOSurface **es** la memoria de la superficie: lo
que el productor escribe (y desbloquea) es lo que la GPU lee en el siguiente uso, sin copia y sin conversión fuera
del muestreador.

(en redacción: formatos, sRGB, samplers, ranuras sin enlazar, heaps, vida de los recursos)

### 2.4 Pasadas

(en redacción)

### 2.5 Draws, mezcla y lectura del framebuffer

(en redacción)

### 2.6 Blits, compute y tile shaders

(en redacción)

### 2.7 Sincronización y presentación

(en redacción)

### 2.8 Lo que el dispositivo declara cambia el contrato

(en redacción)

### 2.9 No conformidades

(en redacción)

### 2.10 Interruptores de diagnóstico de CoreAnimation

(en redacción)

## 3. Lo que hacen los drivers de Apple y el nuestro no

(en redacción)

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
la app, su instantánea de lanzamiento, la animación de zoom) y, con él, pipelines, texturas y superficies que no
existían en el frame anterior. Hipótesis, por orden de probabilidad a la vista de la evidencia:

(en redacción: se completa con la auditoría de no conformidades, §2)

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

**Explicación.** Las dos rutas producen la misma firma por la misma razón de fondo: un filtro de composición o una
matriz de color que no se aplica como CoreAnimation pidió. En la ruta por CPU es una limitación de esa ruta; en la
ruta Metal es una no conformidad del plug-in: CoreAnimation pide una función especializada con unos valores de
function constants y el plug-in compila otra (§2, resolución de funciones). Un texto con vibrancy que se dibuja
como máscara y se colorea con una matriz sale con el color crudo de la máscara si la matriz no se aplica, y un
`darkenSourceOver` dibujado como `sourceOver` deja una banda blanca opaca [H: lo decide la decodificación de las
etiquetas y de las constantes, §2].

**Cómo confirmarlo.** En el arranque con el síntoma: (1) `driver-en-uso.sh`; (2) si el driver está, las líneas
`stands in for it` de la consola y una traza del frame del bloqueo (§5): el draw de la hora debe nombrar una
variante sustituta; (3) si no está, es §4.1.

**Arreglo general.** Compilar exactamente la función que CoreAnimation pide, con sus valores de constantes, a
partir del `default.metallib` real de 20H392 (existe: §2): sin sustitutos no hay variante equivocada.

### 4.4 (d) 20-25 fps con el hilo de render saturado

**Observado [O]** (03 M1-M2, M6, M7; 10 §1): el hilo `com.apple.coreanimation.display.primary` de backboardd pasa el
84-90 % del tiempo en CPU, el 46-60 % dentro del driver; ~150 draws por command buffer a 126-163 µs cada uno
(19-24 ms por frame); la pasada principal tarda 16-24 ms de GPU y las pasadas a pantalla completa en sysmem 18-36 ms;
«a buffer made to committed» 26-30 ms de media; los huecos entre commits caen en «20-50 ms» o «más de 50 ms».

**Explicación.** Dos límites, cada uno por encima de un intervalo: la CPU del driver en el hilo que codifica
(*render execute*, §1.3) y la GPU. El número de fps sale además cuantizado: CoreAnimation arranca cada frame en un
tick de su reloj a la frecuencia que publica el kernel (`IOMFBDisplayRefresh`, 120 Hz; §1.5), así que un frame de
30-42 ms de hilo deja huecos de 33,3, 41,7 o 50 ms [H coherente con 09 §2.5]. Las no conformidades que pesan aquí
no son de resultado sino de modelo de coste: Metal concentra la validación y la traducción en la creación del
pipeline y deja el draw barato, y CoreAnimation se apoya en eso (un draw por capa, ~150 por frame); el driver
valida, regenera y filtra el estado completo en cada draw (10 §2), especializa el uber shader leyendo el buffer de
configuración en cada draw y, si la variante no está, espera en el hilo de render (`usleep(2000)` hasta 1 500 veces,
10 §3.7), donde CoreAnimation espera una compilación asíncrona y una ruta genérica inmediata (§2).

**Cómo confirmarlo.** `thrtop`/`psamp` del hilo (cuota del driver), «us of ours each» y «a buffer made to committed»
de `metal_fps`, el histograma `swap interval` de 0336 (picos en múltiplos de 8,33 ms) y, con la traza (§5), el
número de draws por pasada y por programa.

## 5. Qué mirar de un frame

(en redacción)

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
| Alyssa Rosenzweig, *Dissecting the Apple M1 GPU* I-IV y *The Apple GPU and the impossible bug* (asahilinux.org / rosenzweig.io) | 2021-2022 | TBDR de AGX, memoria de tile, partial renders (detalle en `tbdr-apple-vs-adreno.md`) | T |
| Saar Amar, CVE-2021-30807 y CVE-2021-30883 (IOMobileFramebuffer en A11): <https://saaramar.github.io/IOMFB_integer_overflow_poc/> | 2021 | En el iPhone X IOMFB es una kext del AP (`AppleMobileDispH10P`), sin DCP; métodos del user client | T |
| Crash log de backboardd de iOS 15.2.1 en los foros de Apple (adjunto `08d2afda…`) | 2023-02 | Hilos `render-server`, `display.primary` (`CA::WindowServer::IOMFBServer`), `frameinfo.primary`, `CA::OGL::AsynchronousDispatcher` | T |
| Aditya Vaidyam, *The Secret Life of Core Animation* y *CAPluginLayer & CABackdropLayer* (2018); `avaidyam/QuartzInternal` | 2018 | Capas internas de QuartzCore, backends SW/OGL/Metal, `CABackdropLayer` (`scale`, `groupName`) | T? (macOS) |
| `qingralf/iOS16-Runtime-Headers`, `theos/headers` (QuartzCore) | 2021-2022 | Cabeceras privadas de iOS 16: `CABackdropLayer`, `CAFilter` (`kCAFilter*`), `CADisplay`, `CAWindowServer` | T (nombres y tipos) |
| Mesa freedreno/turnip (`767fbf7c`), `docs/drivers/freedreno.rst` | 2026-11 | Grupos de draw state, GMEM, binning, LRZ, autotune: la referencia para un driver de Adreno (detalle en 10, 14 y `tbdr-apple-vs-adreno.md`) | T |
| ANGLE, backend Metal: <https://github.com/google/angle/tree/99a746a6e378fcb2e57d89cf47a0310800d7411a/src/libANGLE/renderer/metal> | 2026 | Uso correcto de Metal en 2D: grabar antes de codificar, `DontCare` por defecto, framebuffer fetch solo en familias Apple | T |
| Chromium `iosurface_image_backing.mm` y WebKit `RemoteLayerBackingStore.mm` | 2026 | Coherencia de IOSurface entre procesos en el punto *scheduled*; WebKit entrega IOSurfaces a CoreAnimation como `contents` | T |
| Skia Graphite (`src/gpu/graphite`) y su presentación en el blog de Chromium (2025-07-08) | 2025-2026 | Orden por clave (pintor → pipeline → bindings), fusión de draws, lectura del destino por fetch o por copia | T |

(en redacción: fuentes de la arquitectura de GPU y de los binarios, según `tbdr-apple-vs-adreno.md` y
`binarios-ios-20H392.md`)
