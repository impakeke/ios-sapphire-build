# 19 — Cómo dibuja iOS: el camino de un frame y el contrato de CoreAnimation con Metal

Documento de referencia (2026-11-14). Pregunta: qué hace iOS 16.7.16 (20H392) para poner un frame en la pantalla,
qué espera CoreAnimation de un driver Metal correcto y dónde se desvía el nuestro (hakios-metal, upstream `63fc2b4`
más los parches A610), para arreglarlo de forma general en el driver y en el kernel, no con atajos sobre CoreAnimation.

Convención de evidencia: **[O]** observado en un binario de Apple (offset o símbolo), en código (archivo:línea) o en
una medida propia; **[D]** documentado por Apple (URL en §6); **[R]** ingeniería inversa de terceros fiable (URL en §6);
**[H]** hipótesis. Lo heredado (comentarios y docs de HackiOS, `NOTES.md`) cuenta como [H] hasta verlo en código o
en binario. El material extraído de Apple está fuera de git, en `~/sapphire-angel/research/metal/ios-graficos/`.

## 1. El camino de un frame

(en redacción)

## 2. El contrato de CoreAnimation con Metal

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

(en redacción)
