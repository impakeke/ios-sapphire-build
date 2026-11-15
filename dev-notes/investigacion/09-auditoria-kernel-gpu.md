# 09 — Auditoría zero-trust del lado kernel de la ruta gráfica (2026-11-14)

- **Autor:** agente Claude Fable 5.2, esfuerzo máximo.
- **Alcance:** solo el kernel: la presentación (IOMobileFramebuffer propio, copia al panel, flip, vsync), el
  user client de la GPU, submit y fences, objetos buffer y energía de la GPU. El driver Metal de userland,
  su rendimiento y los relojes/bus frente a Android los cubren otros informes; lo visto de pasada está en §9.
- **Criterio:** confianza cero en comentarios, descripciones de parches y notas. La referencia es el código
  reconstruido y las fuentes primarias fijadas. Cada afirmación lleva `archivo:línea`; lo que es hipótesis
  se marca como tal.
- **Código auditado:** serie completa `xnu/patches/` (0001-0335) aplicada sobre xnu-8796.141.3. Las líneas
  `Gnnn`, `Fnnn` y `Snnn` son de los archivos reconstruidos:

  | Sigla | Archivo | Líneas | sha256 (inicio) |
  |---|---|---|---|
  | G | `iokit/Kernel/arm/SapphireGpu.cpp` | 4221 | `6f108354…` |
  | F | `iokit/Kernel/arm/SweetFramebuffer.cpp` | 2384 | `5058a6c2…` |
  | S | `iokit/Kernel/arm/SweetSurface.cpp` | 1533 | `173e098f…` |

  Copias en `~/sapphire-angel/research/metal/kernel-gpu/fuente/`; árbol completo en `…/kernel-gpu/xnu/`.
- **Fuentes primarias fijadas** (en `…/kernel-gpu/ref/`):
  - Linux v6.12 (`adc218676eef`): `drivers/gpu/drm/msm` (adreno, GEM, IOMMU, DPU), `arm-smmu`.
  - kgsl de Qualcomm para este SoC: MiCode `Xiaomi_Kernel_OpenSource`, rama `spes-r-oss`
    (`88afd3256421`, khaje, msm-4.19), `drivers/gpu/msm`.
  - Mesa 24.2.0 (`22fafc9824f9`): freedreno.
  - HackiOS `hakios-xnu-kernel` (`63fc2b4633ba`): `drivers/gpu/hakios.gpu.cpp`, el diseño que el cliente
    msm de este fork dice seguir (G3108-3115), y `xnu/files/iokit/Kernel/MiniIOMobileFramebuffer.cpp`, su
    framebuffer.
  - Árbol de dispositivo del teléfono (dtbo, placa "Khaje IDP sapphire"): `ref/dt-telefono-sapphire-sde-panel.dts`.
- **Borradores de parche** (fuera de `xnu/patches/`): `…/kernel-gpu/0336-sapphire-gfx-diag.patch`
  (diagnóstico, §6.3) y `…/kernel-gpu/0338-sapphire-fb-hold-swap-experiment.patch` (experimento apagado por
  defecto, §6.4).

## Resultado en breve

Ordenado por ganancia esperada. Las cifras en ms son estimaciones razonadas salvo donde se dice "medido".

1. **Un frame dibujado y copiado puede no llegar nunca al panel, y es probable que pase a menudo.** Hay un
   solo buffer trasero. Si un `SwapEnd` llega antes de que la copia del frame anterior haya terminado en la
   GPU, la copia nueva se encola sobre el mismo buffer y el flip pasa a esperar a la nueva: el frame
   anterior se pinta, se copia y se pisa sin enseñarse (F1633-1636, F1688, F1359-1379, G2162-2166). El hueco
   en pantalla es entonces de dos intervalos (67-83 ms) con frames de 33-42 ms. La condición es
   *commit→fin en GPU + copia > intervalo hasta el swap siguiente*; el driver mide 26-37 ms de media y
   43-110 ms de máximo para lo primero y 33-59 ms de intervalo medio (datos del agente de medición, §2.3).
   La frecuencia real no está medida: no hay contador de flips. El contador `N by the GPU` cuenta swaps:
   los 21-30 "frames" por segundo son una cota superior de lo que se ve.
2. **Cada frame paga una pasada de GPU a pantalla completa que Android no hace**, partida en dos medias
   pasadas. El kernel escala ×1,5 la superficie de 750×1624 al buffer de 1080×2400 con el blitter 2D, en el
   mismo ring y detrás del dibujo (F1678-1723, G2220-2260, G1641-1679). El pitch del panel (4320) no es
   múltiplo de 64, así que la fuente entera se lee dos veces (G1645, G1656-1677). Compite con un render que
   ya ocupa 18-23 ms de GPU por frame. El plano VIG0 del MDP de este SoC tiene escalador QSEED3LITE (DT
   del teléfono; Linux `dpu_6_3_sm6115.h:37-46`): puede escalar en el scanout con coste cero de GPU.
3. **Entre el fin del render y la luz hay tres esperas en serie, ninguna atada al panel:** la copia en la
   GPU; hasta 8,33 ms hasta que alguien mira la fence (el siguiente swap o un tick de un temporizador de
   120 Hz, F877-883, F1633-1635); y hasta 8,33 ms hasta el vsync real del MDP.
4. **CoreAnimation no recibe ningún vsync del kernel y nada lo frena.** backboardd nunca activa las
   notificaciones (el selector 72 no aparece en cinco arranques guardados): el temporizador de "vsync" del
   kernel solo sirve para mirar la fence (F751-903, F1887-1899). CoreAnimation marca su ritmo con reloj
   propio a los 120 Hz que el kernel publica, sin fase con el panel; `SwapEnd` vuelve tras encolar, `SwapWait`
   no hace nada (F2058-2060) y la superficie se libera al instante. El framebuffer de HackiOS, del que
   deriva esta interfaz, retiene `SwapEnd` con una cola de dos frames, presenta desde un hilo que espera a la
   GPU y lleva un compás propio con el contador de línea del INTF (`MiniIOMobileFramebuffer.cpp:215-221,
   253-260, 358-383`). Aquí no hay nada de eso.
5. **Nada de lo anterior se puede medir con lo que hay.** En la ruta en uso la línea `SWEET FB: 5 s`
   imprime `clean 0 + GPU 0 + invalidate 0`: los tiempos solo se acumulan en la rama sin escala
   (F1786-1790); con `sweetfb_scale=2` nunca, sea cual sea el driver. Y en la rama sin escala "GPU" es el
   tiempo de encolar la copia (G1544-1546). El driver de la GPU no tiene ni un sysctl. El borrador 0336
   añade el histograma de frames presentados en refrescos reales del panel, los frames pisados, la latencia
   swap→flip, el retraso de los ticks y, opcionalmente, el tiempo real de GPU de cada copia y cada submit.
6. **Las fences se sondean; la interrupción de la GPU está enmascarada y el port no atiende ninguna
   interrupción de dispositivo** (G506-516, G789-790, `sleh.c:1942-1966`). El driver hace un `WAIT_FENCE` por
   command buffer en su hilo de cola (informe 10): mientras la GPU trabaja, ese hilo se duerme y despierta
   cada ~50 µs (G3320-3348), miles de veces por segundo. La latencia del sondeo es aceptable; el coste es de
   CPU y el límite es que ni el flip ni la presentación reaccionan al fin del trabajo de la GPU.
7. **El coste de un submit en el kernel es pequeño** (decenas de µs por inspección; el perfil del agente de
   medición da 5 % de las muestras en llamadas de IOKit). Lo que puede pesar dentro son las
   limpiezas de caché de superficies enteras (G3958-3983, F1689-1692) y las esperas por el único candado.
8. **Buffers:** no hay caché en el kernel y cada `GEM_NEW` borra el buffer entero mapeándolo y
   desmapeándolo (G3729-3801). El driver solo reutiliza slabs y streams; cada buffer y textura de Metal es
   un `GEM_NEW` y un `GEM_CLOSE` (informe 10: 34-68 nuevos cada 2 s en scroll, hasta 35,7 MB). Es coste de
   sistema repartido y varios ms concentrados cuando el buffer es un render target grande.
9. **Energía:** sin gestión dinámica. La GPU se enciende una vez con una frecuencia fija y no vuelve a
   apagarse ni a cambiarla (G657-722, G2633-2636). No añade latencia entre frames. Qué frecuencia es de
   verdad lo trata el informe 11.

Las afirmaciones heredadas "la GPU está limitada por ancho de banda de memoria" y "la copia de GPU cuesta
~110 µs" o "~0,5 ms" no tienen una medición que las sostenga en este código (§8).

## 0. Qué se verificó y cómo

- **Reconstrucción.** Copia del árbol de replay de 01 (0001-0328 aplicados; sus parches son idénticos byte a
  byte a los del repo) más 0329-0335 con `git apply --check` y `git apply` en orden: aplican los siete
  (`…/kernel-gpu/apply-0329-0335.log`). Ningún parche posterior a 0326 toca G, F ni S.
- **Qué corre en el teléfono** (leído el 2026-11-14, solo `sysctl` y `dmesg`):
  - Kernel `LC_UUID 4B6A801F-F0EF-33DD-84D0-CD9D83786850` = run de CI 43570770230, serie hasta 0334 (su
    `run.log` lista `Applying patch` hasta 0334). 0335 solo cambia comentarios en otros archivos.
  - Boot-args gráficos: `gpu=3 gpu_mmu=1 gpu_service=1 gpu_div=1 gpu_mhz=1260 sweetfb_gpucopy=1
    sweetfb_direct=0 sweetfb_scale=2 sweetfb_w=750 sweetfb_hz=120 sweetmetal=2`.
  - `kern.sweet_metal: 2` (HakiosMetal), `kern.sweet_fb_rscale: 1000`, `kern.sweet_fb_flipflush: 0`,
    `kern.sweet_fb_frame_stats: held 0 sent 0 late 0`.
- **Logs.** `dmesg` del teléfono (131 KB, `…/kernel-gpu/telefono/dmesg-20261114-094247.txt`) y el ring de un
  arranque anterior con el mismo código de GPU (`~/sapphire-angel/backups/ring-E5.txt`).
- **Datos de userland.** Los contadores del propio driver y el perfil de CPU son del agente de medición:
  `~/sapphire-angel/research/metal/medicion/` (`ab/ab-base-{1,2,3}.txt`, `cons-fps1-a.txt`, `perfil-1.txt`).
  Aquí se usan como dato de entrada y se citan como "medición".
- **No se hizo:** ninguna medición activa (prohibido lanzar cargas), ningún cambio en el teléfono, ninguna
  compilación del kernel completo. En este arranque `/dev/ufsroot0` responde `Resource busy` al abrirlo
  (`spec_open` rechaza un dispositivo de bloques montado cuando su vnode está marcado como alias,
  `spec_vnops.c:410`); el log se leyó con `dmesg`.

## 1. La ruta, de un vistazo

backboardd dibuja con HakiosMetal sobre el cliente msm del kernel (`SapphireGPUClient`, G3477-4176; ring-E5:
`msm: backboardd opened the GPU`, `buffers from the GPU pool`). El otro cliente (`SapphireGpuClient`, tipo
`'SGPU'`, G2794-3104) es síncrono y esta configuración no lo usa.

```
backboardd (HakiosMetal)                    kernel                                  hardware
───────────────────────                     ──────                                  ────────
GEM_NEW / 0x7e (IOSurface) ───────────────► BO: pool 1 GB WC, 4K en el SMMU
GEM_SUBMIT (N IB) ────────────────────────► ring 32 KB: IB… WAIT_FOR_IDLE, fence ─► CP ejecuta en orden
SwapEnd(superficie 750×1624) ─────────────► present(): blit 2D escalado ×1,5 ─────► (detrás del frame)
                                            en 2 pasadas → buffer trasero 1080×2400
                                            ¿fence hecha? (se mira en swap o tick)
                                            scanFrom(): VIG0 SRC0_ADDR + CTL_FLUSH ► MDP lo toma en su vsync
(vsync, tipo 5: nadie lo ha pedido)         temporizador 120 Hz: mira la fence, no es el vsync del panel
```

Datos del panel, del reloj y de la cadena de superficies (ring-E5 L82, L112, L2254-2315; DT):

- Panel "n7 38 0c 0a", modo vídeo, DSC 1.1, 1080×2400 a 120 Hz. `vsync_period 0x158600` / `hsync 0x244` =
  2432 líneas de 580 relojes: 3,43 µs por línea. `SWEET INTF1: 600 frames in 5 s` (medido): refresca a 120 Hz.
- Base de tiempos: 159 999 ticks por 1/120 s (19,2 MHz).
- Superficies de backboardd: **dos**, ids 2 y 3, 750×1624 BGRA, 3072 bytes por fila, 4 997 120 bytes. Un
  solo layer a pantalla completa por swap. El orden observado es submit y, a continuación, swap.

## 2. Presentación: del fin del render al panel

### 2.1 Secuencia

1. `SwapEnd` → `swap()` (F1924-1934, F959-1012): marca la superficie en uso y, con `sweetfb_now=1` (por
   defecto), presenta en el mismo hilo. El mecanismo de retención de 0286 no interviene con HakiosMetal
   (`held 0 sent 0`, medido).
2. `present()` (F1577-1831) con `fPresentLock`:
   - `directPresent()` falla: con `sweetfb_direct=0` ninguna superficie tiene `scanoutPhys` (F1534,
     S143-150).
   - `flipWhenCopied(false)`: si la copia anterior ya terminó, hace ahora su flip (F1633-1635).
   - Rama de escala (F1678-1723): `dc cvac` de la superficie si la GPU no la dibujó desde el último seed
     (F1689-1692) y `sapphire_gpu_copy_scaled()` hacia el buffer trasero.
3. `sapphire_gpu_copy_scaled()` (G2220-2260) con `service_lock`: ventana de la superficie (cacheada por
   descriptor, G2095-2099), identidad del destino (cacheada, G2056-2060), `ring_room`, `blit_scale`, y
   vuelve tras `kick()` sin esperar (`gpu_copy_async=1`, G1544-1546).
4. La superficie se libera en el acto (F1040-1049): CoreAnimation puede dibujar el frame siguiente en ella;
   su trabajo queda en el ring detrás de la copia.
5. El flip (`scanFrom`: `SSPP_SRC0_ADDR`, `YSTRIDE0` y `CTL_FLUSH = 0x20001`, F1084-1094) se escribe cuando
   alguien mira y la fence de la **última** copia encolada está hecha (G2162-2166): el siguiente swap
   (F1633-1635) o el siguiente tick del temporizador (F877-883).
6. El MDP toma la dirección nueva en su siguiente vsync real.

Tiempo desde el fin del render de un frame hasta que el panel lo toma:

| Tramo | Duración | Origen |
|---|---|---|
| Copia escalada en la GPU | T_blit, no medido (§2.2) | G1641-1679 |
| Hasta que se mira la fence | 0-8,33 ms, media 4,2 ms (o antes si llega un swap) | F877-883, F1633-1635 |
| Hasta el vsync del MDP | 0-8,33 ms | hardware |

Los dos últimos tramos no son independientes: temporizador y panel van a la misma frecuencia con un
desfase φ que deriva (§2.5), así que su suma vale φ + 0-8,33 ms. Según la fase del momento, la media está
entre 4,2 y 12,5 ms.

### 2.2 Pasadas a pantalla completa por frame

| Pasada | Quién | Bytes | ¿Evitable? |
|---|---|---|---|
| Composición en la superficie 750×1624 (medición: 108-112 draws, 102 tiles, 18-23 ms de GPU) | GPU, userland | — | fuera de alcance |
| **Blit escalado, media pasada 1** (filas pares del panel) | GPU, kernel | lee 720×1600×4 = 4,6 MB; escribe 5,2 MB | sí |
| **Blit escalado, media pasada 2** (filas impares) | GPU, kernel | lee otros 4,6 MB; escribe 5,2 MB | sí |
| Scanout del MDP, 120 veces por segundo haya o no frame nuevo | MDP | 10,4 MB por refresco = 1,24 GB/s | bajaría a 0,55 GB/s |
| `dc cvac` de la superficie (solo si el seed cambió) | CPU, kernel | 5 MB | sí |
| Copias de CPU | — | ninguna en esta ruta | — |

- **Por qué dos medias pasadas:** el destino del blitter 2D necesita pitch múltiplo de 64 bytes
  (`RB_A2D_DEST_BUFFER_PITCH`, en unidades de 64). El buffer trasero hereda el pitch del framebuffer de
  arranque, 4320 = 67,5 × 64, así que `blit_scale` usa `k = 2`: trata el destino como dos superficies
  entrelazadas de pitch 8640 y lanza un `CP_BLIT` por cada una, con la fuente completa cada vez
  (G1645, G1656-1677). El stride del plano es programable (`scanFrom` lo escribe, F1088): un buffer
  trasero con pitch 4352 (1088 px) bastaría para una sola pasada.
- **Región que se escala:** 720×1600 de la superficie, desde (13,3; 12), a 1080×2400: ×1,5 en los dos ejes
  (F1694-1709 con `fOffX = 20`, `fOffY = 18`).
- El ajuste del blit se emite entero en cada frame: 12 registros, 5 eventos con marca y dos
  `CP_WAIT_FOR_IDLE` (G1459-1503, G1537-1549).
- **T_blit no está medido en ningún sitio.** El driver de userland cronometra sus pasadas, no las del
  kernel, y las dos cifras heredadas de la copia (~110 µs y ~0,5 ms) no son tiempos de ejecución (§8). Mueve
  ~20 MB por frame; es GPU que se quita al render y latencia que se añade antes del flip.

### 2.3 Frames que no llegan al panel

Hechos del código:

- Hay dos buffers: el que escanea el MDP y el trasero (`fFlip[2]`, F272-274, F593-597). En el teléfono
  existen: la sombra de consola, que se reserva tras ellos, está en 0xe33f0000 (ring-E5 L110).
- `present()` empieza con `flipWhenCopied(!gpu_frame)`; con un frame de GPU el argumento es `false`: si la
  copia anterior sigue pendiente devuelve falso sin esperar y sin tocar `fFlipIdx` (F1359-1368, F1633-1635).
- El destino de la copia nueva es `fFlipPhys[fFlipIdx ^ 1]`: **el mismo buffer trasero** (F1688, F1706-1709).
- `sapphire_gpu_copy_pending()` solo conoce la fence de la última copia encolada (`last_copy_fence`,
  G2160-2166, G2247). Desde ese momento los ticks esperan a la copia nueva (F880-882).
- La GPU ejecuta en orden: copia N → render N+1 → copia N+1, las dos copias sobre el mismo buffer.

Consecuencia: si `SwapEnd` N+1 llega antes de que termine la copia N, el frame N queda completo en el buffer
trasero durante todo el render de N+1 y nadie hace su flip. El panel pasa de N−1 a N+1. Mientras cada swap
encuentre pendiente la copia anterior no hay ningún flip.

Cuándo se cumple la condición (medición del driver, 49 ventanas de 2 s en tres series de scroll):

- Intervalo medio entre commits con carga: 33-59 ms. Los huecos caen en "20-50 ms" (1288) o "más de 50 ms"
  (732); "hasta 20 ms", 106.
- Commit → fin en GPU: 26-37 ms de media por ventana, 43-110 ms de máximo. A eso se suma T_blit.
- En 8 de las 49 ventanas la media de commit→fin más 4 ms supera el intervalo medio entre commits. En casi
  todas las ventanas con carga el máximo lo supera.

**Hipótesis:** una fracción grande de los frames se pisa, y en las ventanas con la GPU al 85-107 % casi
todos. Lo decide un contador (`overwritten` del 0336) en la primera prueba de scroll. Si se confirma, es la
explicación directa de los tirones de más de 50 ms con frames de ~30 ms, y el arreglo no toca el driver:

- **Contrapresión:** retener `SwapEnd` (o `SwapWait`) de forma acotada mientras la copia anterior siga
  pendiente. Es lo que hace el framebuffer de origen con su cola `fb_queue`
  (`MiniIOMobileFramebuffer.cpp:358-366, 1274-1291`) y deja a CoreAnimation como mucho un frame por delante.
  El parche 0338 lo implementa tras `kern.sweet_fb_hold_ms`, apagado por defecto (§6.4).
- **Tercer buffer trasero** y una cola corta de (buffer, fence): cada copia terminada se enseña en orden
  aunque llegue otro swap. Cabe: el pool bajo tiene 48 MB (F157-177) y usa 31,4 MB (la página de DSI, dos
  flip buffers y la sombra de consola, redondeados a 64 KB); otro buffer son 10,4 MB.

**Ventana de tearing (hipótesis, no observada).** Tras `scanFrom` el MDP sigue leyendo el buffer antiguo
hasta su vsync (≤ 8,33 ms). Si en ese intervalo llega un swap, su copia se dirige a ese buffer. Con frames
pesados la copia va detrás de ~20 ms de render y llega tarde; con frames ligeros puede escribir mientras se
escanea. Un tercer buffer la cierra.

### 2.4 Quién decide cuándo se presenta

- **CoreAnimation no usa el vsync del kernel.** El cliente del framebuffer registra en el log cada selector
  la primera vez que se llama (F2069-2078). En cinco arranques guardados (`ring-E5`, `ring-R1`, `ring-E2R1`,
  `ring`, `ring-panic2`) backboardd usa los selectores 3, 4, 5, 6, 8, 12, 15, 17, 22, 27, 28, 29, 33, 50, 55,
  57, 68, 74 y 84; el 72, que activa las notificaciones (F1966-1978), no aparece, ni la línea
  `notifications type … on`. `notify()` sale sin enviar nada (F1892-1894). El "vsync" del kernel no llega a
  nadie.
- **CoreAnimation marca su ritmo con reloj propio** a la frecuencia que el kernel publica: `sweetfb_hz` →
  `TimingElements` e `IOMFBDisplayRefresh` (F636, F671-748). HackiOS documenta lo mismo en su framebuffer:
  "CoreAnimation does not go by the refresh notifications of this driver -- it never asks for them -- but by
  a clock of its own at the rate it reads here" (`MiniIOMobileFramebuffer.cpp:375-377`).
- **El kernel solo puede gobernar ese ritmo de tres maneras**, y hoy no usa ninguna:
  - la frecuencia publicada (fija, 120 Hz);
  - bloquear `SwapEnd` o `SwapWait`: `SwapEnd` vuelve tras encolar la copia; `SwapWait` (selector 6, que
    backboardd sí llama: ring-E5 L2247) vuelve al instante (F2058-2060);
  - mantener las superficies en uso: se liberan al encolar la copia (F1040-1049).
- **No hay vsync real en ninguna decisión.** El frame se copia al llegar `SwapEnd`; el flip se escribe en el
  primer swap o tick que ve la fence; el hardware lo toma en su vsync. La GPU no avisa: la fence se consulta
  (§3.2).
- **El diseño de origen hace otra cosa** (`MiniIOMobileFramebuffer.cpp`): "A frame goes to the panel when
  the GPU is done with it: a thread of ours waits for that […] the swap after it is held, in SwapEnd"
  (358-366, 1274-1291: cola `fb_queue` de dos frames con espera en `SwapEnd`); los frames salen "on a beat of
  the refresh rate […] at an even pace whatever each took to draw" (372-383); y la posición del barrido se
  lee del contador de línea del INTF, solo lecturas (253-260). Es un framebuffer distinto (copia por CPU a
  un único buffer), pero sus tres piezas —contrapresión, hilo que espera a la GPU y compás— son las que
  faltan aquí.

### 2.5 El temporizador del kernel, el pacing y por qué salen huecos de más de 50 ms

- **El temporizador de "vsync"** es un `IOTimerEventSource` al ritmo de `sweetfb_hz` sobre una rejilla
  absoluta (F507, F636-637, F910-920). Lo que hace de verdad en cada tick: mirar si la copia terminó y hacer
  el flip (F877-883), soltar retenciones (F871-876), la consola y el fundido.
  - No tiene relación de fase con el panel. Deriva medida (línea del INTF en cada tick múltiplo de 600,
    `dmesg`): de 1390 a 523 en 90 s, unas −10 líneas/s de 2432: una vuelta completa de fase cada ~4 min.
    Dispersión entre muestras de ±0,3 ms.
  - Holgura de coalescencia: se arma desde un hilo del kernel con urgencia normal, así que su plazo duro es
    plazo + min(intervalo/8, 1 ms) (`IOTimerEventSource.cpp:540-543, 570-572`, `thread_call.c:1298-1310`,
    `timer_call.c:1893, 1910-1921`, `arm_timer.c:268-273`). Indicio del mismo mecanismo: `IOSleep(10)` dura
    11,04 ms (ring-E5 L209). Solo afecta a cuándo se mira la fence.
  - Si su hilo se retrasa más de un periodo, la rejilla se reinicia (F915-917). Ese hilo toma
    `fPresentLock` (F880-882), que el hilo del swap mantiene mientras espera `service_lock` (§3.1).
- **Huecos entre commits.** Con reloj propio a 120 Hz, CoreAnimation arranca cada frame en uno de sus
  ticks: un frame que tarda t da un hueco del siguiente múltiplo de 8,33 ms (30 ms → 33,3; 34 ms → 41,7;
  42 ms → 50,0). **Hipótesis** coherente con la observación de HackiOS; el histograma `swap interval` del
  0336 lo enseña directamente. La medición del driver da "de creado a enviado" 21-43 ms de media y 35-81 ms
  de máximo por ventana: los frames lentos caen en 50 ms o más, el umbral con el que el driver cuenta
  "stalls", sin que nada falle. Lo que el kernel añade dentro de ese tiempo: el borrado de buffers nuevos
  (§4.1), las limpiezas de caché y las esperas por candado (§3.1).
- **Huecos en pantalla.** Son los que ve el usuario y pueden ser mayores: cada frame pisado (§2.3)
  convierte dos intervalos en uno solo, y el flip añade 0-16,7 ms variables (§2.1). Nada espacia los flips:
  salen cuando la copia termina y alguien mira.
- Con `sweetfb_hz=240` (0302) CoreAnimation lee 240 Hz y su rejilla pasa a 4,17 ms, igual que la del
  temporizador que mira la fence. El panel sigue a 120 Hz: si CoreAnimation llega a producir dos frames en
  un refresco, el primero se pisa.

### 2.6 Cómo lo hace Android en este teléfono y qué es evitable

- **Hardware de composición** (DT del teléfono, nodo SDE; coincide con el catálogo SM6115 de Linux):
  dos planos, `"vig", "dma"`; el VIG con escalador `qseedv3lite` (`qcom,sde-sspp-qseed-off = 0xa00`,
  versión 0x3000); 4 etapas de mezcla; ancho de línea 2160; UBWC. Linux: `dpu_6_3_sm6115.h:37-55` (VIG0 en
  0x4000 con `dpu_vig_sblk_qseed3_3_0`, DMA0 en 0x24000). Este fork ya usa esos bloques: VIG0 en 0x5e05000,
  CTL0 en 0x5e02000, INTF1 en 0x5e6b800 (F512-513, F577).
- **Android** (SurfaceFlinger + HWC + SDE) asigna capas a planos y el resto lo compone la GPU en un buffer
  que el DPU escanea directamente: no hay copia posterior. Si una capa tiene otra resolución la escala el
  QSEED del plano en el scanout. El vsync que reparte SurfaceFlinger es el del INTF, por interrupción
  (`dpu_6_3_sm6115.h:97`, `dpu_encoder_phys_vid.c:328-358`). (Comportamiento general de Android; no se ha
  verificado aquí con el código de HWC de esta ROM.)
- **Lo que este kernel hace de más:** una copia escalada por GPU en cada frame y un flip por sondeo, con el
  plano que ya programa capaz de escalar y con el instante de toma legible por registro.

**Scanout directo con escalado del MDP.** Linux muestra la secuencia para RGB con filtro bilineal y sin
tablas de coeficientes: `dpu_plane.c:426-493` (`DPU_SCALE_BIL`, `lut_flag = 0`) y `dpu_hw_util.c:282-382`
(fases, pasos de fase, preload, tamaños y `OP_MODE`), más los rectángulos del plano
(`dpu_hw_sspp.c:21-29`: `SRC_SIZE`, `SRC_XY`, `OUT_SIZE`, `OUT_XY`) y la extensión de píxel
(`dpu_hw_sspp.c:46-54, 331`). Son unos 25 registros. Requisitos:

1. Las superficies de pantalla deben ser contiguas y estar por debajo de 4 GiB: el plano recibe direcciones
   físicas de 32 bits (hoy escanea 0x5c000000 y los buffers del pool bajo; el comentario de S859-863 lo
   atribuye a que el SMMU del display está en bypass, sin verificar). El mecanismo existe (`sweetfb_direct`, S126-185, S856-892) pero pide la
   memoria al kernel con máscara física y eso falla con la RAM alta (NOTES, 2026-10-27). Deben salir del
   pool bajo: tres superficies de 5 MB caben, y los buffers traseros de 10,4 MB dejan de hacer falta para
   iOS.
2. Mantener la superficie en uso hasta que el flip **siguiente** se haya tomado. `directPresent` dejó de
   escanear la superficie porque "CoreAnimation may start the next frame in this surface at once, so
   scanning it directly let the panel show frames half drawn" (F1546-1550): se soltaba por un tick del
   temporizador y no por el vsync real. El instante exacto se lee sin interrupciones: los bits de
   `CTL_FLUSH` se borran cuando el hardware toma la configuración (`dpu_hw_ctl.c:26, 80-85`;
   `dpu_encoder_phys_vid.c:349-357, 534`) y el INTF expone contador de frames y de línea
   (`dpu_hw_intf.c:48-50`), que F768-771 ya lee.
3. El flip espera a la fence del render (el número de secuencia msm en el momento del swap), no a una
   copia.
4. CoreAnimation usa hoy dos superficies y reutiliza la misma en swaps seguidos (ring-E5 L2616-2723) porque
   el kernel se la libera al instante. Con scanout directo una está en el panel y la otra se dibuja: hay
   que comprobar que crea una tercera o espera. Esa espera es la contrapresión que hoy falta.

Con ello desaparecen T_blit, los buffers traseros y el problema de §2.3 (cada frame tiene su superficie), y
`kern.sweet_fb_rscale` pasa a ser un recorte del rectángulo fuente. Renderizar directamente a 1080×2400 no
es alternativa: duplica los píxeles de una pasada que ya tarda 18-23 ms.

## 3. Submit y fences

### 3.1 Qué hace un `GEM_SUBMIT` (G3921-4036) y qué cuesta

1. Dos `IONew` y dos `copyin` (tabla de BOs y de comandos) (G3932-3942). El cmdstream **no se copia**: el
   ring recibe un `CP_INDIRECT_BUFFER` por comando, con la dirección de GPU del BO (G3997-4001), como Linux
   (`a6xx_gpu.c:236-239`).
2. Toma `service_lock`, **el único candado**: lo comparten todos los clientes msm, el cliente SGPU, la
   copia al panel, `GEM_NEW`/`CLOSE`/`INFO` y `clientMemoryForType` (G2034, G2185, G2232, G3943).
3. `reap()`: recorre 256 entradas de buffers pendientes de liberar (G3637-3647).
4. `ring_room()`: una lectura de `CP_RB_RPTR`; si no hay sitio, sondea con `IODelay(10)` hasta 2 s **con el
   candado** y, si vence, reinicia la GPU (G3950-3955, G1302-1313).
5. Limpieza de caché: `dc civac` de **toda** la superficie importada si su seed cambió o si el programa la
   mapeó alguna vez por el cliente msm (`mapped` no se borra nunca) (G3958-3983). Los BO del pool no se
   limpian (G3777, G3960-3961).
6. Emite los IB, `CP_WAIT_FOR_IDLE` y `CP_EVENT_WRITE(CACHE_FLUSH_TS)` con el número de secuencia en un
   slot propio del pool (G4004-4009).
7. `kick()`: escribe `CP_RB_WPTR` y **vuelve sin esperar** (G4011, G1316-1321).

**Coste en sistema.** Con los 11 BOs y un comando por submit vistos en el arranque (ring-E5 L2272-2300) los
pasos 1-4, 6 y 7 son decenas de µs (por inspección, no medido). El paso 5 es el único proporcional a
memoria: ~78 000 `dc civac` para la superficie de 5 MB. En `SwapEnd` hay otro tanto con `dc cvac` si el
seed no coincide (F1689-1692). El perfil del agente de medición da 5,05 % de las muestras del hilo
perfilado en llamadas de IOKit (todas: submit, buffers, superficies y swap). El reparto exacto es lo que dan
`submit ns` (llamada entera, espera del candado, posesión, limpieza de caché) y `surface cleans` del 0336.

Otros hechos:

- **Varios submits en vuelo: sí.** El ring es uno, de 32 KB (G116-117, G1362), igual que kgsl
  (`adreno_ringbuffer.h:17`) y Linux. Un submit ocupa 4·n + 6 dwords. kgsl limita a 15 los lotes en vuelo
  (`adreno_dispatch.c:37`); aquí el límite es el ring.
- **No se espera a que la GPU quede ociosa entre submits.** El comentario de cabecera "Submissions run to
  completion before the call returns (no queue yet)" (G3128-3129) describe 0149 y es falso desde 0153.
- **Sí se inserta `CP_WAIT_FOR_IDLE` tras cada submit** (G4004) y dos por copia al panel (G1486, G1543).
  Linux no lo emite en `a6xx_submit` (`a6xx_gpu.c:198-279`). El driver ya pone uno por pasada (medición:
  "each with its flush and wait for idle"). Coste no medido; se espera pequeño.
- **`CTX_RESTORE_BUF` se ejecuta siempre** (G3987); Linux solo al cambiar de contexto
  (`a6xx_gpu.c:231-234`).
- **Un submit rechazado a medias deja sus primeros IB en el ring** sin fence ni `kick`: se validan y emiten
  en el mismo bucle (G3985-4003) y la salida por error no retrocede `ring_wptr`. Se ejecutarían con el
  siguiente `kick`. Defecto de robustez; solo con un submit malformado.
- Un solo ring y un solo espacio de direcciones para todos los procesos, sin prioridades ni preempción.

### 3.2 Fences: sondeo, no IRQ

- La línea SPI 177 de la GPU se enmascara en el GIC antes de encender nada y `RBBM_INT_0_MASK` se deja a 0
  (G506-516, G789-790). El evento de fence se emite sin el bit de IRQ (G4005-4006).
- El kernel no tiene manejador para interrupciones de dispositivo: `sleh_irq` atiende el timer y los IPI y
  para lo demás llama a `cdp->interrupt_handler`, que ningún driver del port instala
  (`osfmk/arm64/sleh.c:1942-1966`; sin `ml_install_interrupt_handler` en `iokit/Kernel/arm` ni `bsd/dev`).
  El "IRQ" del táctil es un GPIO sondeado cada 0,5 ms.
- Linux y kgsl retiran por interrupción (`a6xx_gpu.c:268-270, 1567-1568`; `adreno_a6xx.c:1392, 1463`).
- `msm_wait()` (G3320-3348): comprueba el slot y, si no está, duerme `delay_for_interval(50 µs)` en bucle
  hasta el plazo. Lo usan `WAIT_FENCE`, `CPU_PREP`, el cierre del cliente y `GEM_CLOSE` cuando no cabe en la
  lista de pendientes.
- **Está en la ruta de cada frame, en otro hilo.** El driver espera cada command buffer con un `WAIT_FENCE`
  en su hilo de cola (informe 10, `command.cpp:669-704`); el hilo de render no espera ("0 waits for
  completion", medición). Con 26-37 ms de GPU por command buffer son varios cientos de ciclos de
  dormir-despertar por frame. **Hipótesis:** del orden del 10 % de un núcleo en tiempo de sistema de ese
  hilo. Lo miden `wait` del 0336 (tiempo dormido y número de miradas) y el consumo del hilo.
- Las fences de la copia al panel no las espera nadie dormido: se consultan desde el swap y desde el tick.

### 3.3 Esperas fijas y su granularidad

`IODelay`, `IOSleep` y `delay_for_interval` terminan en `_clock_delay_until_deadline_with_leeway`
(`clock.c:1575-1600`), que solo gira si `ml_delay_should_spin()`. En este port es siempre falso:
`cpu_idle_latency` sale de `powergate_latency`, que `SweetCPU.cpp:91` deja a 0
(`machine_routines.c:1410, 2360-2373`). **Toda espera bloquea el hilo** con un temporizador, y a su plazo
se le suma la holgura de coalescencia (§2.5).

| Espera | Dónde | Por iteración | Máximo | ¿Con candado? | ¿En la ruta de cada frame? |
|---|---|---|---|---|---|
| `msm_wait` | G3345 | 50 µs + despertar | 2 s | no | sí: un `WAIT_FENCE` por command buffer, en el hilo de cola del driver |
| `ring_room` | G1310 | 10 µs + despertar | 200 ms (copia), 2 s (submit) | **sí** | solo con el ring lleno |
| `tlb_flush` → `poll` | G1123, G370 | 1 µs + despertar | 1000 iteraciones | **sí** | en cada `GEM_NEW`/`CLOSE` |
| `map_window` (ventana ocupada) | G2103-2108 | 10 µs + despertar | 20 000 iteraciones | **sí** | solo al cambiar de superficie |
| `flipWhenCopied(true)` | F1365-1373 | 100 µs + despertar | 200 iteraciones | `fPresentLock` | solo ruta de CPU y consola |
| ruta de CPU tras copia rechazada | F1796-1798 | 100 µs + despertar | 200 iteraciones | `fPresentLock` | no |
| `submit()` síncrono | G1282-1293 | 10 µs + despertar | `ms`·100 iteraciones | **sí** | no (SGPU, recuperación) |

"+ despertar" es el coste de programar el temporizador, bloquear y volver a planificar el hilo; no está
medido en este teléfono. Los bucles cuentan iteraciones, no tiempo: `ms * 100` iteraciones de `IODelay(10)`
duran más que `ms`.

## 4. Objetos buffer

### 4.1 Asignación (`GEM_NEW`, G3729-3834)

Con `gpu_pool=1` (por defecto, G3272-3283) un BO es **un tramo físicamente contiguo** del gigabyte
0x1_0000_0000-0x1_4000_0000, DDR que el kernel no gestiona (G3255-3267). No es memoria wired del kernel ni
páginas sueltas. Pasos por cada `GEM_NEW`:

| Paso | Código | Coste |
|---|---|---|
| Buscar el tramo en un mapa de bits de 262 144 páginas, next-fit, con el candado | G3298-3317, G3739-3741 | lineal en lo recorrido |
| `IOMemoryDescriptor::withPhysicalAddress` | G3747 | pequeño |
| **Poner a cero:** mapear el BO entero en el kernel (write-combine), `bzero`, soltar el mapeo | G3763-3772 | proporcional al tamaño; una entrada de pmap por página al mapear y al desmapear |
| Buscar handle libre: barrido lineal de hasta 4096 entradas | G3545-3555 | pequeño |
| Direcciones de GPU: next-fit en otro mapa de 524 288 páginas | G3215-3234 | lineal |
| Mapear en el SMMU **página a página de 4K** con `getPhysicalSegment` por página | G3568-3580, G1087-1097 | 1220 iteraciones para 5 MB |
| **TLBIASID + TLBSYNC** y sondeo de TLBSTATUS | G3581, G1117-1124 | ver 4.3 |

- **Se pone a cero siempre.** 0205 lo limitó a buffers < 256 KB; 0215 volvió a todos por defecto
  (`gpu_zero=1`, G3757-3764). Es correcto como seguridad entre procesos (Linux entrega páginas a cero; kgsl:
  `kgsl_pool.c:287, 307, 338`).
- **No hay caché ni pool de BOs en el kernel.** `freeBo` (G3611-3634) desmapea página a página, hace otro
  TLB flush y devuelve las páginas al mapa de bits. `GEM_MADVISE` responde `retained = 1` sin hacer nada
  (G4137-4139).
- **El diseño de origen sí la tiene.** `hakios.gpu.cpp:389-411, 686-718, 721-768`: hasta 48 buffers y
  160 MB guardados 60 s por cliente, reentregados por tamaño y flags exactos sin borrar, con estadísticas.
  Su comentario da la medida en su teléfono: 2-3,5 ms por textura de 6 MB creada de cero.
- **Userland solo reutiliza slabs, sellos y streams**; cada `MTLBuffer` y cada textura es un `GEM_NEW` con
  su mapeo y un `GEM_CLOSE` al morir (informe 10: 34-68 GEM nuevos cada 2 s en scroll, hasta 35,7 MB). El
  contador del driver por ventana de 2 s lo confirma: "39 made (23 713 KB), 196 taken again", "48 made
  (11 268 KB), 391 taken again" (medición). En el kernel son 17-34 ciclos por segundo de borrar, mapear,
  desmapear y dos invalidaciones de TLB, parte con el candado tomado. En media es poco; concentrado en un
  frame (un render target de 5-11 MB son varios ms) puede empujarlo al tick siguiente (§2.5).
- Observación en el teléfono: `SWEET MEM` da entre 500 y 517 buffers del pool y entre 96 y 115 MB con
  animación. Es una foto, no una tasa.

### 4.2 Mapeo en userland y cachés de CPU

- BO del pool: write-combine en el programa (G3722) y nunca se limpia de caché (`kva = NULL`, G3777): **sin
  coste de caché por submit**. Equivalente a Linux (`msm_gem.c:317-318`, `MSM_BO_WC`).
- IOSurface importada: memoria paginable del kernel, cacheable en el programa (S904-914). Limpieza en el
  submit según §3.1 paso 5, y en `SwapEnd` según §2.1. Con HakiosMetal dibujando la superficie,
  `gpuDrawn`/`gpuSeed` (G3966-3967) evitan la de `SwapEnd` **si** el driver nombra la superficie en
  `bos[]`. No verificado en el teléfono: no hay contador.
- `GEM_CPU_PREP` espera la fence del BO y, si es memoria del kernel, hace `dc civac` del BO entero
  (G4102-4123).

### 4.3 SMMU de la GPU

- Formato y registros como Linux (`io-pgtable-arm`, ARM_64_LPAE_S1, T0SZ 32): G994-1003, G1127-1169.
- Los buffers de los clientes se mapean **solo con páginas de 4K** (G1087-1097), aunque los BO del pool son
  contiguos. Linux elige el tamaño mayor que permita la alineación, 4K/2M/1G (`msm_iommu.c:36-89`,
  `arm-smmu.c:1925`).
- **TLB flush completo (TLBIASID) en cada mapeo y en cada desmapeo** (G3581, G3621, G2781, G2790, G2080,
  G2142). Linux solo invalida al desmapear (`msm_iommu.c:91-113`); al mapear no llama a ningún flush
  (`msm_iommu.c:115-150`).
- `tlb_flush()` sondea TLBSTATUS con `IODelay(1)` hasta 1000 veces (G1123, G363-373). Si la primera lectura
  aún ve la sincronización activa, el hilo duerme con el candado de la GPU tomado (§3.3).
- Las tablas viven en memoria write-combine (G1016-1056) y no se liberan nunca.

### 4.4 Importación de IOSurface (`0x7e`, G3859-3919)

- Rechaza superficies envueltas sobre memoria del cliente (G3869-3872).
- Busca si ya está importada con un barrido lineal de las 4096 entradas, con el candado (G3887-3894).
- La primera vez: `prepare()` (wire) y mapeo 4K + TLB flush (G3897-3903). Queda wired mientras esté
  importada.
- Cada IOSurface nueva se crea con `bzero` de toda su memoria paginable (S912): fuerza el fallo de todas
  sus páginas en la creación.

## 5. Energía y ociosidad de la GPU

- **No hay colapso ni despertar entre frames.** `power_up()` se ejecuta una vez (G657-722); con
  `gpu_service=1` la GPU no se aparca (G2633-2636). `power_down()` solo corre si el arranque falla o sin
  servicio (G2641-2643).
- **Frecuencia fija.** `gpu_mhz=1260` programa `gpu_cc_pll0` con L = 66 (1260 MHz de VCO) y pone el RCG en
  esa fuente con divisor 1 (G609-641, G709-713; ring-E5 L171-172, L183-187). El informe 11 lee que la salida
  que toma el RCG lleva un posdivisor de 2 y que el núcleo va a 630 MHz; aquí no se ha verificado. El texto
  del log "(GPLL0/1 = 600 MHz)" de `rcg_set` es engañoso en cualquier caso (G651).
- **0204:** un único voto al RPM por el nivel del raíl CX (0x1a0 para más de 1025 MHz), antes del reloj y
  nunca rebajado (G700-708; ring-E5 L170: `CX rail to RPM level 0x1a0 for 1260 MHz: 0`).
- No hay devfreq, ni clock gating por hardware (`hw_init_regs`, G1210-1244, no programa HWCG), ni votos de
  bus. No añaden latencia; su efecto en consumo y en rendimiento es del informe de relojes.
- **0317 (recuperación):** si un submit no termina en 2 s (`msm_wait`, o el ring lleno 2 s) se reinicia la
  GPU con el candado tomado: drenar el bus, reset por software, `hw_init`, CP, zap por SCM, y las dos
  fences saltan al último número (G3377-3425, G3427-3455). Es una congelación de 2 s por cuelgue. En el
  `dmesg` leído no hay ninguna línea `SapphireGpu:` (el buffer solo cubre los últimos ~3 min).

## 6. Instrumentación

### 6.1 Lo que hay

| Qué | Dónde | Qué dice de verdad |
|---|---|---|
| `SWEET FB: 5 s: …` | F1411-1442 | Número de `present()` por ruta (swaps, no flips). Tiempos de la ruta GPU solo en la rama sin escala (F1786-1790); con `sweetfb_scale=2` salen a 0 con cualquier driver. "GPU" es tiempo de encolar. |
| `SWEET MEM: …` | F1423-1431, G3589-3608, S118-123 | Foto de superficies y BOs por clase. No tasas. |
| `SWEET INTF1: N frames in 5 s (line L…)` | F768-773 | Refrescos reales del panel y línea en el tick. |
| `SWEET FB: N swaps; 0286: …` | F1050-1053 | Cada 1000 swaps. |
| `kern.sweet_fb_frame_stats` | F2372-2384 | Solo el mecanismo de 0286. |
| `kern.sweet_fb_rscale`, `_flipflush`, `_ids`, `kern.sweet_metal` | F2353-2366 | Controles, no medidas. |
| `GET_PARAM 0x09` (FAULTS) | G4050 | Reinicios de la GPU, para userland. |
| Logs de la GPU | G | Solo arranque, los 4 primeros submits y errores. **Ningún sysctl.** |

### 6.2 Lo que falta para decidir

- Intervalo entre frames **presentados** (flips) y frames pisados antes del flip.
- Tiempo swap → flip, quién encontró la copia hecha y fase del flip respecto al vsync real.
- Retraso de cada tick del temporizador y reinicios de rejilla; cuántas veces se llama a `SwapWait`.
- Tiempo real de GPU de la copia al panel y de cada submit; ocupación del ring.
- Coste de un submit: llamada entera, espera del candado, posesión, limpieza de caché.
- `GEM_NEW` por tamaño con su tiempo de borrado y de mapeo; TLB flush; esperas de fence.

### 6.3 Borrador `0336-sapphire-gfx-diag.patch`

`xnu/patches/0336-sapphire-gfx-diag.patch` (956 líneas, 46 hunks, sha256
`ad2f78ec…`; no está en `xnu/patches/`). Solo contadores, tiempos e histogramas tras dos sysctl de lectura
y una línea de log más cada 5 s; no cambia qué se envía, se copia ni se presenta, con una excepción opcional
y apagada por defecto.

**`kern.sweet_fb_diag`** (SweetFramebuffer.cpp):

| Dato | Qué decide |
|---|---|
| `swaps`, `flips (by swap, by tick)`, `overwritten` | §2.3: cuántos frames se pisan |
| `flip interval`: refrescos reales del panel entre flips (lee `INTF_FRAME_COUNT` en cada flip; cubo 0 = dos flips en un refresco) | el fps que se ve y sus huecos |
| `swap interval` en refrescos de 8,33 ms | cadencia de CoreAnimation |
| `swap to flip` en ms | latencia de §2.1 |
| `tick late` en µs y `grid restarts` | §2.5: holgura y saltos del temporizador que mira la fence |
| `swap waits` | cuántas veces llama CoreAnimation a `SwapWait` (§2.4) |
| `flip written in eighth of the refresh` (lee `INTF_LINE_COUNT`) | fase del flip frente al vsync real |
| `present` (tiempo de `SwapEnd` con candado) y `surface cleans` | coste de §2.1 en el hilo de CoreAnimation |

**`kern.sweet_gpu_diag`** (SapphireGpu.cpp):

| Dato | Qué decide |
|---|---|
| `submit`: número, IB, BOs; tiempo de la llamada, esperando el candado, con él, en `dc civac` y sus bytes | §3.1: coste por submit |
| `the one before not done`, `ring max`, `no room` | atraso de la GPU al encolar |
| `new` por tamaño con tiempo de borrado y de mapeo; `close`; `freeing`; `surfaces`; `tlb flush` y cuántos durmieron | §4 |
| `wait`: llamadas, ya hechas, tiempo dormido, miradas | §3.2 |
| `copy`: número, espera del candado, `the copy before still queued` | §2.3 desde el lado de la GPU |
| `gpu time` de submits y de copias, con histograma | T_blit y tiempo de GPU por submit |

**`kern.sweet_gpu_marks=1`** (opcional): cada submit msm y cada copia al panel va entre dos `CP_REG_TO_MEM`
de `CP_ALWAYS_ON_COUNTER` (19,2 MHz) escritos en el pool (`OFF_DIAG`, 0x20000, libre en G100-117), como
hace Linux en cada submit (`a6xx_gpu.c:92-101, 208-217, 255-258`). La diferencia es el tiempo de GPU de cada
uno. Añade 8 dwords al ring por submit o copia y nada más. El inicio cae tras el `CP_WAIT_FOR_IDLE` con que
termina lo anterior (G1543, G4004); el final, tras el propio.

Verificación hecha:

- `git apply --check` y `git apply` sobre el árbol post-0335: aplica; el resultado coincide con el árbol de
  trabajo del que se generó.
- `clang++ -fsyntax-only` (Apple clang de CommandLineTools) contra las cabeceras reales de XNU del árbol,
  con `KERNEL`, `XNU_KERNEL_PRIVATE`, `IOKIT_KERNEL_PRIVATE`, `ARM64_BOARD_CONFIG_SWEET` y cabeceras vacías
  para las generadas por MIG e iig: **0 errores** en los dos archivos. Inyectando un error en cada bloque
  nuevo, el compilador lo señala: los bloques se compilan de verdad. Con `-Weverything` las líneas nuevas
  solo dan los avisos que ya da el código vecino (`-Wcast-align` del pool, macros `SYSCTL_*`). Guion y
  cabeceras: `…/kernel-gpu/verificacion/`.
- **No verificado:** compilación y enlazado en el CI, ni ejecución en el teléfono.

Uso: los dos sysctl son acumulativos; se leen antes y después de la prueba y se restan
(`…/kernel-gpu/verificacion/gfxdiag-diff.py antes.txt despues.txt`).

```sh
ssh sapphire 'sysctl -n kern.sweet_fb_diag kern.sweet_gpu_diag'     # antes y después
ssh sapphire 'sysctl -w kern.sweet_gpu_marks=1'                     # solo para medir tiempo de GPU
```

Junto a cada `SWEET FB: 5 s` sale además, sin leer nada:

```
SWEET FB: 5 s (0336): N swaps, N flips, N frames overwritten before their flip, N flips 6 or more refreshes after the one before
```

### 6.4 Borrador `0338-sapphire-fb-hold-swap-experiment.patch`

`xnu/patches/0338-sapphire-fb-hold-swap-experiment.patch` (94 líneas,
5 hunks, sha256 `b80f72ab…`; va encima de 0336). Sin cambio de comportamiento mientras no se active.

- `kern.sweet_fb_hold_ms=N` (sysctl de lectura y escritura) o boot-arg `sweetfb_hold=N`; por defecto 0.
- Con N > 0, un `SwapEnd` que encuentra pendiente la copia del frame anterior la espera hasta N ms (200
  como mucho), fuera de todo candado, antes de presentar el suyo. `present()` encuentra entonces la copia
  hecha y hace su flip antes de encolar la nueva en el otro buffer.
- Es el experimento que decide P1 sin escribir la cola de tres buffers: la misma prueba con 0 y con 40,
  cambiando el sysctl en caliente. Debe bajar `overwritten` a ~0, quitar los huecos largos de
  `flip interval`, y `hold` dice cuánto se retuvo a CoreAnimation.
- No es el arreglo final: la ventana de tearing de §2.3 sigue ahí (la espera no la hace más frecuente:
  solo ocurre con la GPU atrasada, cuando la copia siguiente va detrás de un render largo).
- Verificación: `git apply --check` sobre 0336 y los dos en orden sobre post-0335; `clang++ -fsyntax-only`
  con 0 errores. Sin compilar en CI ni probar en el teléfono.

## 7. Defectos y oportunidades, por ganancia esperada

| # | Qué | Evidencia | Ganancia esperada | Riesgo | Experimento decisivo |
|---|---|---|---|---|---|
| P1 | Cola de presentación con contrapresión, como el framebuffer de origen: retener `SwapEnd` (o `SwapWait`) mientras la copia anterior no ha salido, y un tercer buffer trasero con cola de (buffer, fence) | F1633-1636, F1688, G2162-2166; `MiniIOMobileFramebuffer.cpp:358-366, 1274-1291`; medición del driver (§2.3) | Cada frame que deja de pisarse convierte un hueco de 67-83 ms en dos de 33-42 ms. Si se pisa la mitad, el fps visible casi se duplica sin tocar el driver | Bajo-medio: solo kernel; 10,4 MB más del pool bajo (quedan 19) | E1: `overwritten / swaps` e histograma `flip interval` del 0336 en scroll, n≥3; después lo mismo con `kern.sweet_fb_hold_ms=40` (0338) |
| P2 | Scanout directo de la superficie con el escalador QSEED3LITE del VIG0; desaparece la copia por frame | F1678-1723, G1641-1679; DT `qseedv3lite`; `dpu_6_3_sm6115.h:37-46`; `dpu_plane.c:426-493` | T_blit de GPU por frame (por medir; 20 MB movidos) + 0,69 GB/s menos de scanout + T_blit y ~4 ms menos de latencia; resuelve P1 y da contrapresión | Medio-alto: registros del display (pantalla negra recuperable), cadena de superficies de CoreAnimation | E2: T_blit con `kern.sweet_gpu_marks=1`. Si ≥ 2 ms, prototipo tras boot-arg sobre el pool bajo |
| P3 | Buffer trasero con pitch múltiplo de 64 (4352): blit en una pasada | G1645; `RB_A2D_DEST_BUFFER_PITCH` en unidades de 64 | ~⅓-½ de T_blit | Bajo: toca `fRowBytes` de los flip buffers y sus usuarios | E2 con `k = 2` frente a `k = 1` |
| P4 | Flip en cuanto la copia termina: un hilo que espera la fence (como el de HackiOS) o sondeo fino mientras haya copia pendiente | F877-883, F1359-1379; `MiniIOMobileFramebuffer.cpp:358-359` | −4 ms de latencia media y menos varianza | Bajo | E1: `swap to flip`, `flips by tick` |
| P5 | Compás de presentación: espaciar los flips en múltiplos regulares del refresco con `INTF_FRAME_COUNT`/`INTF_LINE_COUNT`, en vez de "cuando se pueda" | F877-883; `MiniIOMobileFramebuffer.cpp:372-383, 253-260`; `dpu_hw_intf.c:48-50` | No sube fps; iguala el tiempo en pantalla de cada frame | Bajo-medio | E1 y E4: `flip interval`, octavos del refresco |
| P6 | Reducir el alcance de `service_lock`: mapeo y limpieza de caché fuera, candado propio para tablas | G3943-4027, G3558-3582, F880-882 | Sin cifra: quita esperas cruzadas entre driver, swap y temporizador | Medio | E5: esperas del candado en `submit ns` y `copy`; máximo de `present` |
| P7 | `dc cvac` en vez de `dc civac` antes de que la GPU lea; no tratar `mapped` como "siempre sucia" | G3974-3982 | Hasta ~1 ms por submit que nombre una superficie mapeada | Bajo | E5: bytes de `cache flush` en `submit ns` |
| P8 | Caché de BOs en el kernel (portar `keep`/`dropKept` de HackiOS), o pool en el driver (informe 10) | G3729-3834 frente a `hakios.gpu.cpp:389-411, 686-768`; 17-34 `GEM_NEW` por segundo | Tiempo de sistema del hilo de render y varios ms en el frame que crea un render target grande | Bajo | E6: `new` por tamaño y su tiempo |
| P9 | No invalidar la TLB al mapear; sondeo de TLBSTATUS girando | G3581, G1117-1124; `msm_iommu.c:115-150` | Una invalidación y un posible sueño con candado menos por `GEM_NEW` | Bajo | E6: `tlb flush`, `slept` |
| P10 | Quitar el `CP_WAIT_FOR_IDLE` de cada submit | G4004; `a6xx_gpu.c:198-279` | Pequeña, sin cifra | Bajo-medio: la copia al panel cambia estado de la GPU entre submits | E2: tiempo de GPU por submit con y sin |
| P11 | Interrupción de la GPU (SPI 177) para fences; mientras tanto, sondeo más espaciado en `msm_wait` | G506-516, G3345; `sleh.c:1942-1966`; `a6xx_gpu.c:1536-1571` | Quita miles de despertares por segundo del hilo de cola (hipótesis: ~10 % de un núcleo); habilita P4 sin temporizador | Alto la IRQ: primera interrupción de dispositivo del port. Bajo el sondeo espaciado | E6: `wait` (tiempo dormido, miradas) y consumo del hilo de cola |
| P12 | IOSurface nueva sin `bzero` explícito de memoria paginable | S912 | ~1-3 ms por superficie de 5 MB creada (hipótesis) | Bajo | Contar creaciones en animaciones |
| P13 | Bloques de 2 MB en el SMMU para BO contiguos grandes | G1087-1097; `msm_iommu.c:36-89` | Menos fallos de TLB de la GPU; sin cifra | Medio | E2 con y sin |
| D1 | Un submit rechazado a medias deja IB en el ring | G3985-4003 | Robustez | Bajo | Revisión de código |
| D2 | Con `sweetfb_scale=2`, un `SwapEnd` que no trae exactamente un layer no copia nada y aun así hace `flipBack()`: enseña lo que hubiera en el buffer trasero, un frame antiguo | F1625, F1717-1720, F1821-1824 | Corrección; no se ha visto (`0 composed by the CPU` en el teléfono) | Bajo | `cpu flips` del 0336 con iOS en pantalla |

Protocolo común: kernel con 0336, la misma prueba de scroll del agente de medición, n≥3 por condición,
lectura de los dos sysctl antes y después, anotado en 03.

- **E1:** sin marcas. Resultado: `overwritten`, `flip interval`, `swap to flip`. Repetido con
  `kern.sweet_fb_hold_ms=40` (0337): los mismos datos más `hold`.
- **E2:** con `kern.sweet_gpu_marks=1`. Resultado: histograma de T_blit y de tiempo de GPU por submit,
  contrastado con "passes timed by the GPU" del driver.
- **E3:** `sweetfb_hz=240` frente a 120 (boot-arg existente): efecto de la rejilla en `swap interval` y en
  `overwritten`.
- **E4:** `tick late`, `grid restarts`, octavos del refresco y `swap waits` (si CoreAnimation llama a
  `SwapWait` una vez por frame, es el sitio natural para la contrapresión).
- **E5:** `submit ns`, `copy`, `present`, `surface cleans`.
- **E6:** `new`, `close`, `tlb flush`, `wait`.

## 8. Afirmaciones heredadas contrastadas

| Afirmación | Dónde | Veredicto |
|---|---|---|
| "this phone's GPU is bound by memory bandwidth (~2.5 ms a full-screen pass at 3x)" | F462-463, 0239, 0320, NOTES 2026-10-27 | **Sin medición en este código.** El kernel no mide el tiempo de ejecución de ninguna pasada. Aun si fuera cierta, la ruta del kernel añade ~20 MB por frame de tráfico evitable y el scanout 1,24 GB/s. |
| "The GPU copy itself costs ~0.5 ms" | NOTES 2026-10-23 | **Engañosa.** Es el tiempo de CPU de encolar la copia: `g_copy` mide de antes a después de `sapphire_gpu_copy()` (F1777-1789), que con `gpu_copy_async=1` vuelve tras `kick()` (G1544-1546). |
| "The copy itself went from ~5 ms of CPU to ~110 µs on the GPU (about 45× faster)" | NOTES 2026-10-21 | **Imposible como tiempo de ejecución:** leer 10,4 MB y escribir otros 10,4 en 110 µs serían ~190 GB/s. Entonces la copia era síncrona y `submit()` daba por terminado el trabajo cuando `CP_RB_RPTR` alcanza `wptr` (G1282-1290): el CP ha leído los comandos, no los ha ejecutado. Linux exige además `RBBM_STATUS` ocioso (`adreno_gpu.c:652-666`, `a6xx_gpu.c:19-51`). |
| "frames that came two to a tick were dropped … (the panel showed 25-30 of the 60 a second backboardd drew)" resuelto por 0201 | F970-977 | A medias: 0201 quitó la pérdida por tick; la pérdida por copia pendiente (§2.3) sigue y nadie la cuenta. |
| "0235: … animations jumped back and forth by a frame. The flip now waits for the copy's fence" | F1351-1357 | Cierto para el orden; el precio es que el flip espera a la copia más nueva y la anterior se pierde. |
| "Submissions run to completion before the call returns (no queue yet), so every fence is done by the time anyone waits for it" | G3128-3129 | **Falso** desde 0153: `kick()` y vuelta (G4011). |
| "Every submit cleans and invalidates all of the client's buffers" | G2668-2669 | Solo el cliente SGPU (G2845-2852, G2991, G3002). El cliente msm con pool no limpia nada (G3777). |
| "mapping 11 MB into the kernel and zeroing it write-combined made every such GEM_NEW cost 0.5 ms and more" | G3749-3752 (0205) | **No verificado.** HackiOS midió 2-3,5 ms para 6 MB en su teléfono. |
| "Vsync … is a 60 Hz timer" / "SwapEnd copies … (no scaling, CPU copy)" | F27-30 | Obsoleto: 120 Hz (F636), copia escalada por GPU (F1678-1723). |
| "A swap only records the frame … The vsync timer shows the latest frame every fFlushTicks ticks" | F953-958 | Obsoleto con `sweetfb_now=1` (F982-1012). |
| "with sweetfb_hz=90/120 … frames that are ready sooner are shown sooner" | F625-627 | A medias: el tick solo decide cuándo se mira la fence; el panel siempre refresca a 120 Hz. |
| "Its render server starts a frame on a vsync tick" (los ticks del kernel) | F629-635 (0302) | **El mecanismo no es ese.** backboardd nunca activa las notificaciones (selector 72 ausente en cinco arranques): usa reloj propio a la frecuencia publicada. `sweetfb_hz` cambia esa frecuencia, por eso el efecto se parece. |
| "Vsync (notification type 5) … sends (count, mach_absolute_time, 0) … to clients that enabled it" | F28-30 | Cierto y sin efecto: no hay ningún cliente que lo active. |
| "the GPU runs one queue in order, so whatever CoreAnimation draws into that surface next is drawn after the copy" | F973-975 | Cierto (un ring, un candado). Es lo que permite soltar la superficie al instante, y lo que quita toda contrapresión. |
| "Nothing in this kernel handles it" (la IRQ de la GPU) | G74-77 | Cierto, y vale para toda interrupción de dispositivo. |
| "(GPLL0/1 = 600 MHz)" con `gpu_mhz` | texto de log, G651 | Engañoso: la fuente es `gpu_cc_pll0`, no GPLL0. La frecuencia real del núcleo, en el informe 11. |

## 9. Visto de pasada (para los otros informes)

- **DDR/bus:** el kernel no vota el reloj de memoria. `power_up` solo habilita ramas de GCC (G663-671).
  El único camino al recurso "clk2" (BIMC) del RPM es manual, `kern.sweet_audio` op 6
  (`TopazModem.cpp:12974-12984`). NOTES afirma que votar 1804,8 MHz "changes nothing: the DDR is already
  fast": no hay evidencia de que el voto llegara a aplicarse. Ningún script de `/redwood/boot.d` vota.
- **`hw_init_regs`** (G1210-1244) es un subconjunto de `a6xx_hw_init`: sin HWCG, sin protección de
  registros del CP, sin contadores de rendimiento (`RBBM_PERFCTR_CNTL`), sin `CP_MEM_POOL_DBG_ADDR`.
- **`GET_PARAM`** (G4040-4056): `MAX_FREQ` dice 600 MHz con la GPU a 1260; `GMEM_SIZE` 128 KB (Linux:
  128K + 4K); `HIGHEST_BANK_BIT` 14 cuando Mesa da 13 para el a610.
- **Capas de la presentación:** con más de un layer habilitado o si la GPU rechaza la copia, `present()`
  cae a `memcpy` por filas de la CPU sobre memoria write-combine (F1794-1804). Con `sweetfb_scale=2` no
  copia nada y hace el flip igualmente (D2 de §7). Un swap sin frame de GPU espera además a la copia
  pendiente con hasta 200 `IODelay(100)` dentro de `SwapEnd` (F1633-1635, F1365-1373).
- **Formato del destino del render:** NOTES (2026-10-27) da 2,4 ms para una capa mezclada a pantalla
  completa en un destino en tiles y 6 ms en uno lineal. Las superficies de pantalla son lineales. Sin
  verificar aquí; Android compone en UBWC, que este DPU escanea (`qcom,sde-ubwc-version`).
- **`IOSleep(10)` = 11,04 ms:** la holgura de coalescencia de temporizadores afecta a todo `IOSleep` y
  `thread_call` del port.

## 10. Dónde vive cada parche en el código final

Lo que hace hoy el código que dejó cada parche, comprobado en los archivos reconstruidos. Las descripciones
de los parches no se han usado como fuente.

| Parche | En el código final | Líneas |
|---|---|---|
| 0046, 0056 | IOSurface e IOMobileFramebuffer propios. El "presentar cada N ticks" de 0056 (`fFlushTicks`) solo actúa con `sweetfb_now=0` | F621-623, F859-870, F1013-1023 |
| 0145 | Arranque de la GPU, SMMU, blitter 2D, servicio de copias | G1-2646 |
| 0147 | Estadística `SWEET FB: 5 s`; `sweetfb_gpucopy` | F1391-1479 |
| 0148 | Cliente `'SGPU'`, síncrono; sin uso con HakiosMetal | G2648-3104 |
| 0149 | Cliente msm | G3106-4201 |
| 0151 | Pool de 1 GB write-combine; `gpuDrawn`/`gpuSeed` | G3255-3317, G3963-3967, F1770-1776 |
| 0152 | Copia al panel sin esperar (`gpu_copy_async`) | G1529-1549 |
| 0153 | Fence msm propia; submit asíncrono; espera de la ventana ocupada | G3236-3247, G4005-4011, G2102-2108 |
| 0154 | La fence es un número de secuencia, no el contador always-on | G1439-1449 |
| 0161 | `gpu_mhz` | G258-264, G576-641, G709-713 |
| 0164, 0165 | Superficies paginables; limpieza de caché por seed | S894-914, G2091-2118, G3968-3976 |
| 0201 | Presentar en `SwapEnd`; rejilla absoluta del temporizador | F970-1012, F905-920 |
| 0204 | Nivel del raíl CX por RPM | G695-708 |
| 0205, 0215 | Borrado de BOs: todos por defecto | G3748-3764 |
| 0212 | "Copia pendiente", para el apagado de pantalla | G2156-2166, F786-801 |
| 0233 | Pool bajo y flip buffers | F148-214, F593-597 |
| 0235 | Flip tras la fence de la copia | F1351-1379 |
| 0239, 0240, 0320 | Escala 2x y 1x: `blit_scale` y geometría | G1633-1679, F458-488, F1678-1723 |
| 0283, 0302 | `sweetfb_hz` de 90 a 240 | F624-637 |
| 0286 | Retención hasta "frame enviado" (puente GL); inactiva con HakiosMetal | F983-1012, F1056-1082, F2310-2339 |
| 0295, 0326 | Negro hasta el primer frame tras encender | F856-858, F2024-2032 |
| 0301 | `IOMFBDisplayRefresh` | F711-741 |
| 0304 | Sin invalidar el flip buffer tras la copia | F158-164, F1711-1713 |
| 0317 | Recuperación de la GPU | G3365-3455 |
| 0319 | Selección del plug-in de Metal | F391-424 |
| 0321 | Escala de render y `kern.sweet_fb_ids` | F165-175, F1693-1705 |

## Material

- `~/sapphire-angel/research/metal/kernel-gpu/`: `fuente/` (archivos reconstruidos), `fuente-con-0336/`,
  `fuente-con-0336-0337/`, `xnu/` (árbol; su git tiene post-0335 y 0336 como commits), `ref/` (fuentes
  primarias), `telefono/` (dmesg), `verificacion/` (comprobación de sintaxis y `gfxdiag-diff.py`),
  `apply-0329-0335.log`, `0336-sapphire-gfx-diag.patch`, `0338-sapphire-fb-hold-swap-experiment.patch`.
- Datos de userland: `~/sapphire-angel/research/metal/medicion/`.
