# 18 — Display: scanout directo de la superficie de iOS con el escalador del DPU (2026-11-14)

- **Autor:** agente Claude Opus 5.5, esfuerzo máximo.
- **Alcance:** la presentación del kernel frente al DPU (MDSS) del SM6225: qué hace el port con el plano, diseño del
  scanout directo de la superficie de 750×1624 por el VIG0 con su escalador QSEED3LITE, lo que CoreAnimation lee del
  framebuffer para no dibujar en la superficie que está en el panel, cómo nacen y mueren sus superficies de pantalla,
  dónde pone cada camino la ventana del panel, y cinco parches de la serie: **0349** (diagnóstico del DPU, solo
  lectura), **0350** (scanout directo, apagado por defecto), **0352** (arreglos de 0350 que encontró la simulación y
  flip tomado por `CTL_FLUSH`), **0353** (`SwapWait` con el estado real de la cola) y **0354** (pool para la vida
  entera del anillo de CoreAnimation, un solo modo del plano mientras una superficie del anillo no puede escanearse, y
  la ventana recortada por la dirección de la fuente en los dos caminos).
- **Estado:** 0349-0353 en `xnu/patches/` y en el kernel del teléfono (CI 43640189709, imagen
  `boot_a-0353-vco2-820.img`; 03 M16). Con 0353 el scanout directo rinde (03 M16-M17), pero tras horas de uso con
  reinicios de backboardd el pool se llena y la pantalla salta (03 M22; §3.13, §3.14); el teléfono queda con
  `kern.sweet_fb_scanout=2`. 0354 en `parches-nuevos/`, sin compilar en CI ni probar en el teléfono.

## Convenciones

`F`, `S` y `G` son líneas de `SweetFramebuffer.cpp`, `SweetSurface.cpp` y `SapphireGpu.cpp` del árbol **a 0342**
(3118, 1539 y 5278 líneas; sha256 `b8fee873…`, `b3b6c97d…`, `83dc20e2…`), reconstruido aplicando 0339-0342 de
`xnu/patches/` sobre `relojes/xnu-serie` (serie a 0338): coincide byte a byte con `relojes/xnu-0342`. No son las
líneas de 09 ni de 15. El código nuevo de 0349, 0350 y 0352 se cita por nombre de función.

Fuentes primarias, fijadas en `~/sapphire-angel/research/metal/display/ref/`:

| Sigla | Qué | Versión |
|---|---|---|
| Linux | `drivers/gpu/drm/msm/disp/dpu1`, `msm_atomic.c`, `msm_mdss.c`, `sm6115.dtsi`, `math.h` | v6.12, `adc218676eef` |
| SDE | driver de display de Qualcomm para la familia de este SoC (`msm/sde`) | CodeLinaro `display-drivers`, `LA.UM.9.15.r1-08400-KAMORTA.QSSI14.0`, `119a051bc133` |
| SDM | HAL de display de Qualcomm (userspace, la parte abierta) | `LineageOS/android_hardware_qcom_display` `fd1cfe095f3c` |
| DT | árbol del teléfono, nodo `mdss_mdp` | `relojes/dtb/merged-khaje24a-sapphire.dts:15209-15319` |

KAMORTA es la familia bengal/khaje (SM4250/SM6115/SM6225, kernel 4.19); el Android del teléfono es de kernel 5.15, cuyo
`display-drivers` no está publicado para khaje. La parte del escalador (`sde_hw_util.c`, `sde_plane.c`) es la misma en
las ramas que se han mirado.

## Resultado en breve

1. **El kernel no configura el display: lo deja el bootloader** (continuous splash: relojes, DSI, panel, DSC, INTF1,
   PP0, LM0, CTL0 y el plano VIG0 sobre 0x5c000000). Del DPU el port solo escribe, en cada flip, `SSPP_SRC0_ADDR`,
   `SSPP_SRC_YSTRIDE0` y `CTL_FLUSH = 0x20001` (F1375-1378), y una vez `INTF_FRAME_LINE_COUNT_EN` (F754). Usa un solo
   plano (VIG0); el escalador no se había tocado nunca.
2. **La copia de hoy no estira: recorta y escala ×1,5 uniforme** la ventana de 720×1600 en (13,33; 12) de la superficie
   de 750×1624 (F2032-2047): la ventana del panel en el lienzo 3x de 1125×2436, a 2/3. Las razones 1,44 y 1,478 serían
   las de estirar la superficie entera, que nadie hace. El scanout repite la misma ventana y el mismo factor; con 0354
   la ventana empieza en (16, 12) en los dos caminos y el táctil la sigue (§3.14). Esa copia cuesta 4,15 ms de GPU por
   frame de media (03 M11): un tercio del tiempo de GPU del frame, en el mismo ring que el render, con la GPU como
   límite.
3. **El plano recibe direcciones físicas de 32 bits y el stream del display (SID 0x420) no se traduce** (inferido: el
   port nunca programa ese SID y el panel enseña 0x5c000000 y el pool bajo 0xe2000000). El pool del scanout va por
   debajo de 4 GiB, junto a los flip buffers.
4. **Diseño:** las superficies de pantalla de backboardd salen de un pool físico propio (ocho huecos de 5 MiB desde
   0xe5000000 con 0354; cuatro con 0350-0353, que se llenan: §3.13), mapeadas *write-combined* en todas partes (ni la
   GPU ni el DPU necesitan mantenimiento de caché), y el VIG0 las escanea con el QSEED3LITE configurado como Linux
   (bilineal, sin tablas): 27 registros idénticos a los de Linux y del driver de stock para los mismos tamaños (§6.2).
   Los frames entran en la cola de 0340 junto a las copias; uno que no encaja va por la copia, en orden. La superficie
   queda en uso hasta que el DPU ha tomado el flip siguiente, y CoreAnimation lo sabe por `SwapWait` (0353): entonces
   crea una tercera superficie (§3.10).
5. **Las tablas (LUT) del QSEED3LITE no salen del kernel en el driver de stock:** las da el HAL de userspace como
   propiedad de plano (`lut_sep`), desde una extensión cerrada; sin ellas, SDE y Linux programan bilineal sin tabla.
6. **Medido en el teléfono con 0349** (n = 1 arranque, 16 932 flips): el ABL deja el VIG0 como 0350 espera (ARGB8888,
   PE override, escalador 0x3000 apagado: «ready»); **`CTL_FLUSH` devuelve sus bits hasta que el DPU los toma** (puestos
   justo tras la escritura en 16 927 de 16 932 flips), como lo usan Linux y SDE; y el DPU toma el plano en el fetch
   programable, **línea 2420 de 2432** (`INTF_PROG_FETCH_START` 0x156ad1), ~12 líneas antes de que se mueva
   `INTF_FRAME_COUNT`.
7. **Dos defectos de 0350**, encontrados por la simulación de la cola con el texto del kernel (§6.3) y corregidos en
   0352: una copia podía heredar el estado de un frame de superficie del hueco de la cola (frame basura y lectura de un
   puntero viejo), y el flip se anotaba antes de esperar un plano escribible (sin lectura de `CTL_FLUSH`, una
   superficie se soltaba un refresco antes de tiempo). **No se debe encender `kern.sweet_fb_scanout=1` con 0350 sin
   0352.**
8. **Camino con scanout:** fin del render → hilo de la cola (≤ 0,5 ms) → flip (registros + `CTL_FLUSH`) → el DPU lo
   toma en la siguiente línea 2420 → se enciende desde arriba del panel. Del fin del render a la primera línea, entre
   ~0,1 ms y un refresco (media ~4,5 ms: medio intervalo de 8,33 ms); la copia de hoy añade sus 4,15 ms de GPU (§3.9).
9. **Lo que CoreAnimation lee del framebuffer es `SwapWait`, y nada más** (QuartzCore 20H392 desensamblado, §3.10):
   dibuja en un anillo de tres páginas y, antes de cada frame, recupera la página más vieja solo cuando
   `SwapWait(su id, 0x80000000)` responde 0; si no, ese tick no dibuja. Crea una superficie nueva cuando no queda
   ninguna libre. No usa notificaciones de fin de swap (no importa ninguna) ni el contador de uso de la IOSurface. **Hasta
   0352 el kernel responde 0 al instante:** CoreAnimation recupera todas las páginas menos la actual, le bastan dos
   superficies y, con el scanout, dibuja en la que el panel aún escanea. Es lo medido en 03 M12. Además de copias y
   cambios del plano, eso es desgarro: en el modelo, ~9 dibujos por segundo sobre la superficie en pantalla. **Con 0352
   sin 0353, `kern.sweet_fb_scanout=1` no sirve ni para mirar la imagen.**
10. **0353 responde `SwapWait` con el estado de la cola:** ocupado mientras un frame de esa superficie espera, está en el
    panel o lo está dejando; en pantalla cuando el DPU ha tomado su flip; una espera bloqueante (`idle()`) hasta que el
    último frame está en el panel, y el `SwapEnd` siguiente espera a su frame (tras `idle()` CoreAnimation deja de
    preguntar por la página del panel). Con la copia el ritmo no cambia: sus superficies quedan libres en el `SwapEnd`,
    como siempre. `kern.sweet_fb_swapwait` vale 1 por defecto. Con 0354 el scanout lo exige (con 0 copia sus frames) y
    el `SwapEnd` tras `idle()` solo espera si en el panel puede haber un frame de superficie, hasta 250 ms.
11. **Con dos superficies no hay diseño que no serialice** dibujo y presentación: retener el `SwapEnd` hasta que el frame
    está en el panel da 33,6 frames/s en el modelo del teléfono, frente a 55,4 de la copia. Con 0353 CoreAnimation crea
    la tercera y el modelo da 54,2 frames/s, 4,9 ms menos del tick al panel, la GPU ocupada un 43 % en vez de un 69 %,
    ninguna copia y ningún cambio del plano en régimen (§3.11, §6.4). Con la GPU como límite, 49,6 frente a 41,8
    frames/s y 36,6 frente a 66,8 ms.
12. **Con cuatro huecos el pool se llena** (03 M22: `4 of 4 slots in use, 31 surfaces made in it, 14 refused`, tras
    horas de uso con reinicios de backboardd). CoreAnimation tiene tres superficies en uso, hace otras cuando cambia lo
    que necesita una página mientras las viejas viven hasta quedarse sin uso, y un backboardd reiniciado hace las suyas
    mientras el kernel aún retiene la del panel (QuartzCore 20H392, §3.13). Una superficie rechazada queda fuera del
    pool toda su vida: sus frames van por la copia, los de las otras se escanean, y el plano cambia de modo en cada uno
    de los suyos (5,2 frames/s en el teléfono y en el modelo con el texto de 0353). **0354:** ocho huecos y **un solo
    modo mientras el anillo sea el mismo:** si una superficie que el window server presenta no puede escanearse, todos
    los frames van por la copia mientras esa superficie viva; el plano cambia de modo cuando cambia el anillo, no frame
    a frame. En el modelo, con la vida del anillo: con ocho huecos se escanean todos los frames (cinco huecos usados
    como mucho); con cuatro o tres, el 80 % o el 53 %, sin ningún cambio de modo en régimen.
13. **Con 0353 los dos caminos no ponen la ventana en el mismo sitio** (§3.14). La copia aplica el origen de la ventana
    (13,33; 12 de la superficie 2x) con el origen de la fuente del blitter, el scanout con `SRC_XY` del plano; los
    registros leídos en el teléfono son los calculados. Si los dos motores aplican su origen, los dos caminos coinciden
    a 0,35 píxeles del panel; si el plano no aplica `SRC_XY`, los frames copiados quedan 19,75 y 17,75 píxeles (1,3 y
    1,1 mm) arriba y a la izquierda de los escaneados: lo que vio el usuario mientras el plano alternaba [H, una
    observación]. **0354** pone la ventana en (16, 12) (`fOffX` 24, el múltiplo de 24 más cercano al centro: a 1,5
    píxeles del panel del centro en vez de 2,5; el táctil sigue la misma regla) y los dos caminos la recortan por la
    dirección de la fuente: `SRC_XY` queda a 0, y el origen del blitter, sin columnas. Coinciden a 1,27 píxeles como
    mucho sea cual sea la lectura del hardware (`encuadre.cpp`, §6.2).
14. **Frames 2x de varias capas.** El camino 2x solo enseña una capa a pantalla completa. Con 0353, un frame de varias
    capas voltea el buffer trasero tal cual (un frame más viejo, durante un refresco) y con el scanout cambia el plano
    dos veces. 0354 lo enseña por su capa 0 si esta es la superficie de pantalla del window server, y si no, no lo
    enseña (el panel conserva su frame).

## 1. Auditoría: qué hace hoy el port con el DPU

### 1.1 Quién configura qué

- **El ABL deja el display encendido** (continuous splash): el arranque del kernel lee el plano tal cual
  (`fBootSrc = fVig0[0x14/4]`, `fBootStride = fVig0[0x24/4]`, F760-761), y el log de cuatro arranques guardados
  (`ring-E5`, `ring-R1`, `ring-E2R1`, `ring-panic2`, en `~/sapphire-angel/backups/`) dice siempre lo mismo:
  `MDP VIG0 src 0x5c000000 stride 4320 (boot)` y `INTF1: te_en 0x1 config 0x80800000 hsync 0x2440010
  vsync_period 0x158600 hctl 0x18f0028 vstart 0x1b30 vend 0x1558af fmt 0x2100`. 0x5c000000 es el `splash_region`
  del DT (`reserved-memory`, 15 MB).
- El kernel mapea VIG0 (0x5e05000), CTL0 (0x5e02000), DSI0 (0x5e94000) e INTF1 (página 0x5e6b000, bloque en +0x800)
  con `ml_io_map` (F686-688, F751). Nadie más toca el MDSS (búsqueda de constantes 0x5e0xxxx en `iokit/`, `bsd/`,
  `osfmk/`, `pexpert/`).
- **Escrituras al DPU en todo el kernel** antes de 0350 (aparte del DSI, que envía comandos DCS al panel):

| Registro | Valor | Dónde | Cuándo |
|---|---|---|---|
| INTF1 `FRAME_LINE_COUNT_EN` (+0xa8) | 3 | F754 | una vez, al arrancar |
| VIG0 `SSPP_SRC0_ADDR` (+0x14) | dirección física del buffer | F1375 | cada flip (`scanFrom`) |
| VIG0 `SSPP_SRC_YSTRIDE0` (+0x24) | 4320 | F1376 | cada flip |
| CTL0 `CTL_FLUSH` (+0x18) | 0x20001 (VIG0 + CTL) | F1378 | cada flip |

- **Lecturas:** `INTF_FRAME_COUNT` (+0xac) e `INTF_LINE_COUNT` (+0xb0) en cada flip (0336, 0340: F255-279,
  F1366-1371, F2196) y en el log de 5 s; `HSYNC_CTL` y `VSYNC_PERIOD_F0` para el total de líneas (2432 de 580 relojes).

### 1.2 Bloques del DPU de este teléfono

Direcciones del DT (`qcom,sde-*-off`, relativas a `mdp_phys` 0x5e00000) y del catálogo de Linux
(`catalog/dpu_6_3_sm6115.h:19-97`, relativas a `mdp` 0x5e01000); coinciden:

| Bloque | Dirección | Tamaño | DT | Linux | Uso |
|---|---|---|---|---|---|
| MDP TOP | 0x5e01000 | 0x494 | `qcom,sde-off/len` | `sm6115_mdp` | lectura (0349) |
| CTL0 | 0x5e02000 | 0x1dc | `-ctl-off/size` | `sm6115_ctl` (`DPU_CTL_ACTIVE_CFG`) | `CTL_FLUSH` |
| VIG0 | 0x5e05000 | 0x1f8 | `-sspp-off` "vig" | `sspp_0`, `VIG_SDM845_MASK` | dirección y stride; con 0350, 27 registros |
| VIG0 escalador | 0x5e05a00 | 0xa0 | `-sspp-qseed-off 0xa00`, `-qseed-scalar-version 0x3000`, `-qseed-sw-lib-rev "qseedv3lite"` | `dpu_vig_sblk_qseed3_3_0` (`SSPP_SCALER_VER(3, 0)`) | con 0350 |
| VIG0 CSC | 0x5e06a00 | 0x100 | `-sspp-csc-off 0x1a00`, `csc-10bit` | `_VIG_SBLK` | lectura (0349) |
| DMA0 | 0x5e25000 | 0x1f8 | `-sspp-off` "dma" | `sspp_8` | nunca |
| LM0 | 0x5e45000 | 0x320 | `-mixer-off`, 4 etapas, ancho 2048 | `lm_0` | lectura (0349) |
| PP0 | 0x5e71000 | 0xd4 | `-pp-off` | `pingpong_0` | lectura (0349) |
| INTF1 (DSI0) | 0x5e6b800 | 0x2c0 | `-intf-off`, "dsi" | `intf_1`, prog fetch 24 líneas | contadores |

Ancho máximo de línea del SSPP: 2160 (`qcom,sde-sspp-linewidth`); del mezclador: 2048. El panel es de vídeo, con DSC
(INTF: `display_hctl` 0x18f0028 = 360 relojes activos por línea, 1080/3) y 2432 líneas de 580 relojes: 3,43 µs por
línea; el área activa va de la línea 12 a la 2411.

### 1.3 Qué toca cada flip

`scanFrom()` (F1341-1382) escribe dirección y stride, `dsb`, `CTL_FLUSH = 0x20001`, `dsb`. Nada más: ni tamaños,
ni formato, ni el escalador. `CTL_FLUSH` (`dpu_hw_ctl.c:26`): el bit 0 es VIG0 (`update_pending_flush_sspp`,
`dpu_hw_ctl.c:176-180`) y el 17 el propio CTL (`CTL_FLUSH_MASK_CTL`, l. 47), que Linux pone con cada cambio de
mezclador.

### 1.4 Estado en que el ABL deja el VIG y el escalador (leído con 0349)

`kern.sweet_fb_regs` en el teléfono (kernel 0350, 2026-11-14; `telefono/dpu-20261114-145306.txt` y
`lectura-0350-1459.txt`, del mismo arranque). VIG0 y su escalador «at boot» (leídos en `start()` antes del primer
flip) y «now» coinciden salvo la dirección:

| Registro | Valor | Lectura |
|---|---|---|
| `SRC_SIZE`, `OUT_SIZE` | 0x09600438, 0x09600438 | 1080×2400 a 1080×2400 |
| `SRC_XY`, `OUT_XY` | 0, 0 | sin recorte, en (0, 0) |
| `SRC0_ADDR` | 0x5c000000 al arrancar; ahora un flip buffer (0xe3de0000) | |
| `SRC_YSTRIDE0` | 0x10e0 | 4320 |
| `SRC_FORMAT` | 0x000237ff | 8 bits por componente, alfa (`SRCC3_EN`), 4 bytes por píxel, desempaquetado de 4, lineal, RGB |
| `SRC_UNPACK_PATTERN` | 0x03020001 | ARGB8888 de Linux (B, G, R, A en memoria): el orden de las superficies `'BGRA'` |
| `SRC_OP_MODE` | 0x80000000 | PE override (extensión de píxel por software), sin volteos ni BWC |
| `SW_PIX_EXT_*_REQ_PIXELS` | 0x09600438 | la fuente entera, como Linux sin escalar |
| Escalador `HW_VERSION` | 0x3000 | la versión del DT |
| Escalador `OP_MODE` | 0 | apagado |
| Escalador `PHASE_STEP_*`, `PRELOAD` | 0x00200000 (1,0), 0x03050305 | sin uso con el escalador apagado |
| `CTL_LAYER(LM0)` | 0x01000002 | VIG0 en la etapa 0 sobre el color de borde |
| `CTL_DSC_ACTIVE`, `CTL_INTF_ACTIVE` | 1, 2 | DSC0 e INTF1 |
| `LM_OUT_SIZE` | 0x09600438 | |
| INTF1 `PROG_FETCH_START` | 0x00156ad1 | 1 403 601 relojes / 580 = **línea 2420**: el fetch del frame siguiente, y la toma del plano |

`kern.sweet_fb_scanout_diag` (0350): «ready»: el plano pasa todas las comprobaciones de `scanoutInit`.

`kern.sweet_fb_latch` (16 932 flips): bits puestos justo tras la escritura en 16 927 (los otros 5, escritos al tiempo
que el DPU los tomaba); el 6,3 % se limpia antes de que se mueva el contador de frames y el 99,5 % antes de su primer
movimiento; escritos en el último dieciseisavo del refresco (líneas ≥ 2280), 64 de 1044 se toman un refresco después
(los escritos tras la línea 2420). Nunca más de 100 ms pendientes con la pantalla encendida.

### 1.5 Memoria: direcciones físicas, no el SMMU del display

- `SSPP_SRC0_ADDR` es de 32 bits y recibe direcciones físicas: 0x5c000000 (splash), 0xe2000000-0xe5000000 (pool bajo
  de los flip buffers y la sombra de consola, F157, F186, F338-361).
- El stream del display en el SMMU de aplicaciones (DT: `iommus = <… 0x420 0x02>`, `qcom,smmu_sde_unsec`,
  `qcom,iommu-earlymap`) no lo programa el port. Sí programa otros SIDs del mismo SMMU (0x0c600000): una banca sin
  traducción para la cámara (`smmu_identity`, `TopazModem.cpp`, TFE 0x400) y traducción real para el ADSP
  (`smmu_s1`), cuyo comentario dice lo que también vale aquí: un bypass solo alcanza direcciones de 32 bits.
- **Inferencia:** como el panel enseña lo que hay en 0xe2xxxxxx y 0x5c000000, el SID 0x420 pasa sin traducción. No se ha
  leído el SMR/S2CR del SID.
- Lo que el DPU escanee debe estar en memoria física contigua por debajo de 4 GiB. La RAM del kernel está por encima
  (`mkadt.py --highmem`): por eso `sweetfb_direct` (contiguo con máscara física, S856-866) falla siempre en este
  teléfono (NOTES 2026-10-27).
- Hueco bajo en uso, según el código: cámara 0xd7000000-0xe0000000, módem 0xe0000000 (16 MB), GPU 0xe1000000-0xe1500000,
  framebuffer 0xe2000000-0xe5000000, QSEE 0xe8000000-0xe9000000 (`SweetQsee.cpp:80-85`, `sweet_cam.c:802-803`,
  `SapphireGpu.cpp:96-101, 1421-1427`). **0xe5000000-0xe8000000 no lo usa ningún código del port**, y el DT no tiene
  ninguna región fija por encima de 0x66000000 (`reserved-memory`). El pool del scanout va ahí: 20 MiB
  (0xe5000000-0xe6400000) con 0350-0353, 40 MiB (0xe5000000-0xe7800000) con 0354. En el árbol a 0353 sigue sin usarlo
  otro código (búsqueda de 0xe5…-0xe7… en `iokit/Kernel/arm`, `osfmk/arm*` y `bsd/dev/arm64`: solo constantes de
  instrucciones de trampa).

### 1.6 La copia por GPU de hoy

- Ventana: `kx = 750·256`, `ky = 1624·256`; origen (`fOffX·kx/1125`, `fOffY·ky/2436`) = (3413, 3072)/256 =
  (13,33; 12); tamaño (1080·kx/1125, 2400·ky/2436)/256 = 720×1600 (F2032-2047). Escala 1080/720 = 2400/1600 = 1,5.
  Recorta 13,3 px a la izquierda, 16,7 a la derecha y 12 arriba y abajo (en píxeles 2x).
- Dos medias pasadas del blitter 2D (pitch 4320, no múltiplo de 64), bilineales (`blit_scale`, G2206-2237), en el ring
  detrás del render: **4,15 ms de GPU por frame de media** (03 M11, `kern.sweet_gpu_marks=1`, 1266 copias, 820 MHz).
- En `SwapEnd`, además, la limpieza de caché de la superficie antes de que la GPU la lea (`sweet_fb_clean_for_gpu`,
  F1796-1815): en un arranque con la cola y `kern.sweet_gpu_flush=1`, `surface cleans 1963` en 2020 presentaciones, 1,54
  ms cada una (`telefono/lectura-20261114-135453.txt`, n = 1 lectura). Con las superficies del pool (WC) desaparece.

## 2. Cómo lo hacen Linux y el driver de stock

- **Plano escalado** (Linux, `dpu_plane.c:1033-1100`, `dpu_plane_sspp_update_pipe`): dirección y stride, rectángulos
  (`setup_rects`, `dpu_hw_sspp.c:404-444`), escalador (`_dpu_plane_setup_scaler`, l. 529-575), formato
  (`setup_format`, `dpu_hw_sspp.c:210-329`, que siempre pone `MDSS_MDP_OP_PE_OVERRIDE`, l. 305) y QoS. Después el
  flush del CTL.
- **Cuándo se escriben los registros:** `msm_atomic_commit_tail` (`msm_atomic.c:215-235`) espera a que no haya flush
  en curso (`wait_flush` → `dpu_encoder_wait_for_commit_done`, que espera `CTL_FLUSH == 0`,
  `dpu_encoder_phys_vid.c:524-540`), y entonces escribe los planos, en cualquier línea, y el flush.
- **Configuración del escalador** (`_dpu_plane_setup_scaler3`, `dpu_plane.c:426-493`): pasos de fase
  `mult_frac(1 << 21, src, dst)` por eje, fase inicial 0, precarga 4×2 para versión ≥ 3.0 (l. 53-56, 473-479), filtro
  `DPU_SCALE_BIL` para Y/RGB y alfa, `lut_flag = 0`, `blend_cfg = 1`. Extensión de píxel: el tamaño de la fuente
  (`_dpu_plane_setup_pixel_ext`, l. 495-511; `setup_pe_config`, `dpu_hw_sspp.c:331-386`). Registros:
  `dpu_hw_setup_scaler3` (`dpu_hw_util.c:282-382`).
- **El driver de stock hace lo mismo cuando userspace no da datos del escalador**: `_sde_plane_setup_scaler`
  (`sde_plane.c:1252-1300`) pide la tabla `lut_sep` (`_sde_plane_setup_scaler3lite_lut`, l. 821-833) y, si no la hay o
  no hay `scaler_v2`, calcula el bilineal por defecto (`_sde_plane_setup_scaler3`, l. 836-939). `sde_hw_setup_scaler3`
  (`sde_hw_util.c:350-…`) escribe los mismos registros.
- **Las tablas del QSEED3LITE** (33 coeficientes × 10 filtros separables en escalador+0x100 y +0x200, con
  `DIR_FILTER_WEIGHT` en +0x60 y el bit de intercambio en `COEF_LUT_CTRL`, `sde_hw_util.c:239-289`) **las pone
  userspace**: propiedad de plano `lut_sep` (`sde_plane.c:3467, 3474`), que el HAL envía al arrancar el display
  (`display_base.cpp:82-85` → `hw_device_drm.cpp:963-971`); la implementación abierta de quien las genera no da nada
  (`ResourceDefault::GetScaleLutConfig`, `resource_default.cpp:941-943`): en el teléfono las da la extensión cerrada de
  Qualcomm. El kernel no tiene ninguna tabla.
- **Flip tomado:** Linux y SDE dan por hecho un commit cuando, en el vblank, `CTL_FLUSH` ya no tiene los bits escritos
  (`dpu_encoder_phys_vid.c:345-353`, «double-check with hw that it accepted the flush bits»;
  `sde_encoder_phys_vid.c:498-515`, que solo entonces suelta el buffer anterior).
- **Leer el DPU entero no tiene efectos:** el volcado de Linux lee todos esos bloques con sus tamaños
  (`dpu_kms.c:904-1010`, `dpu_kms_mdp_snapshot`).

## 3. Diseño del scanout directo

### 3.1 La memoria de la superficie: tres opciones

| | Opción | A favor | En contra | Decisión |
|---|---|---|---|---|
| (a) | Mapear la superficie (páginas sueltas) en una banca de traducción del SMMU para el SID del display | superficies normales | hay que pasar el SID 0x420 de bypass a traducción **con el panel escaneando** (splash, flip buffers y consola mapeados antes); un fallo de traducción del display es un pipe atascado; el SMMU es el que usan UFS y USB, y la banca del display la dejó el ABL sin que se sepa cómo | descartada para el primer paso |
| (b) | Las superficies de pantalla de backboardd salen de un pool físico por debajo de 4 GiB | el mecanismo de los flip buffers (memoria fija, WC, bypass); contigua; sin tocar el SMMU | 5 MiB por superficie de memoria fija; solo las superficies creadas con el pool activo | **elegida** |
| (c) | El driver Metal dibuja en un buffer del pool del panel | ninguna superficie especial | cambia el driver, y CoreAnimation sigue presentando IOSurfaces: otra cadena en paralelo | descartada |

Cuenta del pool: 750×1624 con filas de 3072 bytes son 4 988 928 bytes (4 997 120 redondeados a página de 16 KiB); huecos
de 5 MiB. 0350 pone cuatro (dos superficies, la tercera que CoreAnimation crea si las dos están en uso, y una de
margen): 20 MiB en 0xe5000000-0xe6400000. No bastan para la vida del anillo (§3.13): 0354 pone ocho, 40 MiB en
0xe5000000-0xe7800000, por debajo del pool de QSEE (0xe8000000). El pool de los flip buffers (48 MB) está casi lleno
(página del DSI, dos flip buffers, la sombra de consola y el tercer flip buffer de 0340: 41,7 MB).

### 3.2 Requisitos de la superficie y cómo los cumple 0350

- **Quién:** la crea backboardd, al tamaño 2x de la pantalla (750×1624), `'BGRA'`, 4 bytes por píxel, un plano, filas
  múltiplo de 64 bytes, sin `IOSurfaceAddress`. SpringBoard crea superficies del mismo tamaño (`keys 10`, frente a
  `keys 11` de las de backboardd en `ring.txt`) que no gastan huecos; 0349 registra los nombres de sus propiedades.
- **Memoria:** `IOMemoryDescriptor::withPhysicalAddress` sobre el hueco, como la superficie del panel
  (`sweet_surface_create_physical`, S346-366). **Mapeada write-combined en todas partes:** en el kernel
  (`kernelAddress()`), en cada programa (`mapCache`, S664) y en el mapeo del cliente de la GPU (`clientMemoryForType`,
  G4602): mapeada «por defecto», memoria que el kernel no gestiona queda como Device y un acceso desalineado fallaría
  (S859-863). Sin líneas en ninguna caché, ni la GPU ni el DPU necesitan limpiezas: el submit la salta en los dos modos
  de `kern.sweet_gpu_flush`, y la copia de `present()` también.
- **Vida:** un hueco vuelve al pool cuando la superficie se libera; el framebuffer retiene las superficies que el DPU
  puede leer, así que nunca se reutiliza un hueco que el DPU lee.

### 3.3 Formato y orden de componentes

La superficie es `'BGRA'` (bytes B, G, R, A en memoria) y el plano del ABL es ARGB8888 de Linux con ese mismo orden
(`SRC_UNPACK_PATTERN` 0x03020001, §1.4): es lo que el panel enseña bien hoy desde los flip buffers, que el blitter llena
sin reordenar. 0350 conserva formato y desempaquetado; del `SRC_FORMAT` saca el alfa (bit 8) y los 10 bits (bit 14)
para el op mode del escalador, como Linux (`dpu_hw_setup_scaler3`, l. 369-379).

### 3.4 Geometría: igual que la copia

No se estira ni se ponen bandas: se escanea la misma ventana que copia la GPU, 720×1600 de la superficie, salida
1080×2400 en (0, 0), ×1,5 en los dos ejes. La ventana es la del panel en el lienzo 3x de 1125×2436, en (`fOffX`, 18),
a 2/3: su origen en la superficie es (13,33; 12) con `fOffX` 20 (0350-0353) y (16, 12) con `fOffX` 24 (0354). Con
0350-0353 el scanout lo pone en `SRC_XY = (13, 12)` (1/3 de píxel 2x menos que la copia, que lo da en 1/256 de píxel
con el origen de la fuente del blitter; fase inicial 0, como Linux); con 0354 los dos caminos lo ponen en la dirección
de la fuente y `SRC_XY` queda a (0, 0) (§3.14). Con `kern.sweet_fb_rscale` (0321) la ventana se recalcula igual que en
la copia (`sweet_scan_window`) y el factor sube (400 ‰: ×3,75; el QSEED3 admite hasta ×20).

### 3.5 QSEED3LITE: registros y valores

Para 720×1600 → 1080×2400 (`sweet_plane_scaled_regs`; idéntico a Linux y al driver de stock, §6.2):

| Registro (VIG0 +) | Valor | Origen |
|---|---|---|
| `SRC_SIZE` 0x000 | 0x064002d0 (1600<<16 \| 720) | `setup_rects` |
| `SRC_XY` 0x008 | 0 con 0354 (el origen va en `SRC0_ADDR`: superficie + 12·3072 + 16·4 = +0x9040); 0x000c000d (12<<16 \| 13) con 0350-0353 | `setup_rects` |
| `OUT_SIZE` 0x00c, `OUT_XY` 0x010 | 0x09600438, 0 (los del ABL) | `setup_rects` |
| `SW_PIX_EXT_C0/C1C2/C3` LR, TB, REQ 0x100-0x128 | 0, 0, 0x064002d0 | `setup_pe_config` |
| `PHASE_INIT_Y_H/Y_V/UV_H/UV_V` 0xa90-0xa9c | 0 | `dpu_hw_setup_scaler3` |
| `PHASE_STEP_Y_H/Y_V/UV_H/UV_V` 0xa10-0xa1c | 0x155555 (1 398 101 = 2²¹·720/1080 = 2²¹·1600/2400) | `mult_frac` |
| `PRELOAD` 0xa20 | 0x02040204 (H 4, V 2) | versión ≥ 3.0 |
| `SRC_SIZE_Y_RGB_A` 0xa40, `SRC_SIZE_UV` 0xa44 | 0x064002d0 | |
| `DST_SIZE` 0xa48 | 0x09600438 | |
| `OP_MODE` 0xa04 | 0xa0034401 (con el alfa del formato del ABL); se lee 0x20034401: el bit 31 (`blend_cfg`) no se conserva (`telefono/regs-scan.txt`) | enable, BIL, blend, 8 bits, alfa bilineal |
| `SSPP_SRC_OP_MODE` 0x038 | 0x80000000 (el del ABL \| PE override) | `setup_format` |

Para estirar la superficie entera (razones 1,44 y 1,478) los pasos serían 0x1638e3 y 0x15a740; 0350 no estira. Sin
tabla: filtro bilineal (`y_rgb_filter_cfg = 3`), como la copia de hoy (el blitter también es bilineal). El plano sin
escalar es el del ABL, leído en `start()`, y vuelve en el primer flip de un flip buffer.

### 3.6 Flush atómico y toma del plano

- Los registros del plano tienen doble buffer: el DPU los toma todos juntos si el bit de VIG0 de `CTL_FLUSH` está
  puesto, en el inicio del fetch del frame siguiente (línea 2420, §1.4). **Lo escrito mientras un flush está pendiente
  se toma con él:** un cambio de geometría a medias sería un frame roto o un pipe atascado.
- Regla de 0350/0352: el plano se reescribe solo con `CTL_FLUSH & 0x20001` limpio, que es lo que exige Linux
  (`msm_atomic_commit_tail`). Mientras no se ha visto que `CTL_FLUSH` devuelve sus bits (`flushNote()`: 16 flips, a lo
  sumo uno de cada 64 limpio justo tras la escritura), además solo entre 1/16 y 3/4 del refresco (líneas 152-1824, a
  ≥ 2 ms de la toma). En el teléfono los devuelve (16 927 de 16 932), así que basta con los bits.
- **Flip tomado:** con 0352, los bits de `CTL_FLUSH` limpios, para los flips del scanout (y para todos con
  `kern.sweet_fb_flush_taken=1`); el contador de frames de 0340 si no. El contador solo adivina los flips escritos tras
  la línea 2420, que el DPU toma un refresco después.
- Si el DPU no toma un flush del plano escalado en 100 ms, el scanout se apaga solo y vuelven las copias.

### 3.7 Cómo encaja con la cola de 0340

- **El «buffer trasero» es la propia superficie.** Un `SwapEnd` de una superficie del pool entra en la cola como frame
  de scanout: dirección, ventana y la valla del último submit msm en ese momento (HakiosMetal envía al hacer `commit`,
  `command.cpp:390-396, 603-628`: el submit precede al `SwapEnd`; un ring, en orden). Si un submit posterior nombra la
  superficie, el flip espera también a ese (`gpuFence`, que pone el submit). Sin límite de tiempo, como las copias: una
  GPU colgada se reinicia a los 2 s y sus vallas saltan (0317). Un frame de superficie aún sin dibujar cuando se vacía
  la cola se descarta, no se enseña a medias.
- **Vida de la superficie:** en uso desde su `SwapEnd` hasta que el DPU ha tomado el flip de un frame posterior;
  entonces se suelta (`sweet_hold` y `release`). CoreAnimation no mira ese contador de uso en sus superficies de
  pantalla: lo sabe por `SwapWait`, que 0353 responde con este mismo estado (§3.10).
- **Frames mezclados:** uno que no encaja (superficie fuera del pool o de otro tamaño, una superficie que el panel aún
  puede leer) va por la copia, a la misma cola, en orden. El flip de un flip buffer vuelve a poner el plano del ABL con
  la misma regla de §3.6. Con 0354, mientras viva una superficie del anillo que no puede escanearse van por la copia
  todos los frames, y uno 2x de varias capas se enseña por su capa 0 o no se enseña (§3.12).
- **Profundidad y contrapresión:** la de CoreAnimation, por `SwapWait` (0353, que el scanout exige): como mucho dos
  frames por delante del panel, lo que cabe en la cola de 0340 (`kern.sweet_fb_queue_depth` 2) sin que el `SwapEnd`
  espere. Las esperas de 0340 en `SwapEnd` (`_hold_ms`) quedan para lo que no respeta esa contrapresión.
- **Pantalla apagada y encendida:** el tick vuelve al framebuffer de arranque (con `fPresentLock` desde 0350), lo que
  restaura el plano; la superficie se suelta cuando el DPU lo toma.

### 3.8 Coste esperado

- GPU: desaparecen las dos medias pasadas de la copia, 4,15 ms por frame de media (03 M11), y sus `CP_WAIT_FOR_IDLE`;
  el render del frame siguiente empieza ese tiempo antes.
- CPU: desaparecen los `dc cvac` de 5 MB en `SwapEnd` (§1.6) y los `dc civac` del submit en el modo 0 de 0339.
- Ancho de banda de scanout: el DPU lee 720×1600×4 = 4,6 MB por refresco en vez de 10,4 MB (0,55 frente a 1,24 GB/s).
- Memoria: 40 MiB de pool fijo con 0354 (20 con 0350-0353); los flip buffers se quedan (son la ruta de vuelta).

### 3.9 El camino completo, la latencia y lo que necesita CoreAnimation

Camino de un frame con scanout (sin copia):

1. CoreAnimation envía el dibujo (`commit` de HakiosMetal → `GEM_SUBMIT`) y llama a `SwapEnd`.
2. `SwapEnd` → `presentScanout()`: valida y encola el frame con su valla; no espera salvo que ya haya
   `kern.sweet_fb_queue_depth` frames esperando (hasta `hold_ms`).
3. La GPU termina el dibujo. El hilo de la cola, que mira cada 500 µs mientras hay un frame esperando, ve la valla
   hecha y el flip anterior tomado (bits de `CTL_FLUSH` limpios) y escribe el flip: dirección y stride (y los 27
   registros si cambia la geometría) y `CTL_FLUSH`. Si el frame ya estaba dibujado al llegar el `SwapEnd`, el flip se
   escribe en el propio `SwapEnd`.
4. El DPU toma el plano en el siguiente fetch programable (línea 2420): es el «vsync» real del INTF, atómico para todos
   los registros. 82 µs después (24 líneas) se enciende la primera línea activa; la última, 8,24 ms más tarde.
5. «Notificación»: CoreAnimation no pide notificaciones de vsync (09 §2.4) ni de fin de swap; lo sabe preguntando:
   con 0353, `SwapWait` por el swap del frame anterior responde 0 cuando el DPU ha tomado este flip (lo ve la propia
   llamada, que mira el estado de la cola antes de responder; §3.10).

Del fin del render a la luz (primera línea), con scanout:

| Tramo | Duración |
|---|---|
| hasta que el hilo de la cola mira | 0-0,5 ms (media 0,25) |
| hasta la siguiente toma (línea 2420) | 0-8,33 ms (media 4,17), uniforme frente a la fase del panel |
| de la toma a la primera línea activa | 0,08 ms |
| **total** | **~0,1 ms en el mejor caso, 8,9 ms en el peor, ~4,5 ms de media: entre 0 y 1 intervalo de 8,33 ms, medio de media** |

Con la copia de hoy hay que sumar los 4,15 ms de GPU de la copia (que además va detrás de cualquier otro trabajo en el
ring) antes de su valla: media ~8,7 ms, un intervalo. El scanout quita medio intervalo de latencia y medio intervalo de
GPU por frame. Bajar los 0,5 ms del sondeo pediría la interrupción de la GPU (09 P11).

**Lo que necesita CoreAnimation para encadenar frames sin esperar:** tres superficies. Una está en el panel (A), otra
esperando su flip o recién flipada (B) y la tercera se dibuja (C). A vuelve a estar libre cuando el DPU toma el flip de
B. Con dos, CoreAnimation solo puede empezar el frame N+2 cuando el N+1 ya está en el panel: dibujo y presentación se
serializan. Cuándo crea la tercera y qué le dice que A sigue en uso: §3.10; las cifras de cada opción: §3.11.

### 3.10 Lo que CoreAnimation lee del framebuffer: `SwapWait` (QuartzCore 20H392)

Leído en el desensamblado de QuartzCore de 20H392 [O]: el `__TEXT` del teléfono (`dyld_shared_cache_arm64.03`,
desplazamiento 0x14f8000, en `display/ref/dsc-20H392/`) y el desensamblado con nombres de
`ios-graficos/ios-20H392/desensamblado/QuartzCore.named.s.gz`. Direcciones de 20H392; `display` es el
`CA::WindowServer::IOMFBDisplay` (un `AppleDisplay`).

- **Páginas.** El constructor de `AppleDisplay` (0x1883ad1e8-0x1883ad208) pone `[display+0x360] = 3` páginas (1 si
  `CA::WindowServer::page_flipping_disabled`) y la siguiente `[+0x358] = 1`. Cada página, de 48 bytes desde `+0x3a8`,
  guarda la semilla de su frame (+0), el `Buffer` en que se dibujó (+8; contador de uso en `Buffer+8`), su `Surface`
  (+0x10), el id del swap que la enseñó (+0x18) y banderas (+0x28). `finish_update_` (0x1882ed374-0x1882ed388) hace
  actual la página del frame recién enviado y avanza la siguiente.
- **Antes de cada frame** `IOMFBDisplay::can_update_` (0x1882be944) mira las dos páginas que siguen a la actual, la más
  vieja primero (`min(3, 2)` en 0x1882bea10-0x1882bea20; la actual se salta, 0x1882bea54-0x1882bea64). Una página sin
  frame o sin id de swap se recupera sin preguntar (0x1882beacc, 0x1882beadc). Si tiene id, `SwapWait(id,
  0x80000000)`: en el A11 (`CADeviceUseVBL::use_vbl` = 0, 19 §1.3) la primera por `swap_wait_timeout` (0x18853c088:
  `SwapWait`, `usleep(100)`, otra vez, hasta 1 ms en total; la constante 0,001 está en 0x18855cb20) y la segunda con
  una sola llamada (0x1882beb2c). Una respuesta distinta de 0 termina la vuelta (0x1882bec80). Recuperar una página
  baja el contador de uso de su `Buffer` y suelta su `Surface` (0x1882beb84-0x1882bebf4). La función devuelve si
  recuperó alguna (0x1882bed98-0x1882bedc8); si no, ese tick del temporizador propio de CoreAnimation (120 Hz) no dibuja.
- **El buffer del frame:** `allocate_buffer` (0x18837881c) toma de la lista de `Buffer` uno con contador de uso 0 y la
  superficie que corresponde, el de menos área por redibujar; si no hay, crea otro (0x1883788d8: un `Buffer` de 136
  bytes y su superficie). `collect_buffers` (0x188305288) solo libera buffers sin uso cuya superficie ya no corresponde.
  El límite lo ponen las páginas: tres buffers ocupados a la vez como mucho.
- **Banderas, por cómo se usan** en sus 21 llamadas: `0x80000000` responde ya (`can_update_` compara la respuesta por
  la página actual con `kIOReturnBusy`, 0xe00002d5, en 0x1882bed14); `1`, el frame del swap está en el panel
  (`IOMFBFlipBook::swapped_frame_displayed_p`, la página actual); `2`, todos los swaps hasta ahora, con id 0: `idle()`
  (0x188394534), `set_all_layers_to_null`, `finish_update` en modo síncrono (tras `SwapEnd`), el flipbook;
  `0x80000003` en `is_ready()`. `kern_SwapWait` de IOMobileFramebuffer manda `{id, flags, 0}` (0x1af223648). Que el bit
  31 sea «no esperar», el 0 «en pantalla» y el 1 «todos» se deduce del uso [H]; el lado del kernel de Apple
  (`AppleMobileDispH10P`) no se ha leído.
- **`idle()`** espera con `SwapWait(0, 2)` y después borra el id de swap de todas las páginas, la actual incluida
  (0x188394574-0x1883945cc): cuando esa página deja de ser la actual, se recupera sin preguntar.
- **No hay notificación de swap:** QuartzCore no importa ningún callback de fin de swap; las de vsync (selector 72)
  solo se piden con `use_vbl` (A8-A10). `SwapWait` es lo único por lo que CoreAnimation sabe en qué estado está un swap.
- **Ninguna propiedad decide cuántas superficies:** las que lee de IOMobileFramebuffer (`CopyProperty`) son
  `Brightness_Scale`, `SupportsRotation`, `IOMFBUUID`, `DisplayContainerID`, `DisplayAttributes` y `Transport`.
  `IOMFBDisplay::triple_buffered()` (0x1883abf4c, bit 51 de `[display+0x9f2]`) no es un ajuste: lo pone `can_update_`
  cuando solo pudo recuperar una página, es decir, cuando el frame se dibuja con dos swaps aún en uso (con `SwapWait` a
  0 al instante no se pone nunca). Las cadenas «triple buffered» de QuartzCore son de los backing stores de las capas.

**La señal que falta hasta 0352.** El kernel responde `SwapWait` con 0 al instante (0336 solo lo cuenta). Con eso
`can_update_` recupera en cada frame todas las páginas menos la actual: le bastan dos superficies, y la que dibuja a
continuación es la del frame anterior, que con el scanout sigue en el panel hasta que el DPU toma el flip del actual. Es
lo medido en 03 M12 (dos superficies; «swapped again while on the panel or waiting» 1029 frente a 897 frames
escaneados; 813 cambios del plano). Con la copia no se nota: la superficie solo la lee la copia, que va en el único
ring de la GPU antes de lo que se dibuje después en ella (0201).

**El contrato** [O + H]: para dibujar el frame N+1, CoreAnimation tiene que recuperar la página del N-2, la más vieja:
que las superficies del swap N-2 ya no se usen, es decir, con el scanout, que el DPU haya tomado el flip del N-1. El N
puede estar aún esperando. CoreAnimation va así como mucho dos frames por delante del panel (N-1 en el panel, N
esperando, N+1 dibujándose) con tres superficies, y la tercera la crea él cuando la necesita. `SwapWait(id,
0x80000000)` tiene que responder `kIOReturnBusy` mientras las superficies de `id` estén en uso y 0 cuando no;
`SwapWait(id, 0x80000001)`, mientras su frame no esté en el panel; `SwapWait(0, 2)`, esperar a que el último lo esté.
No hace falta el selector 72 ni retener el `SwapEnd`. (Matiz a 19 §1.5: para dibujar un frame, CoreAnimation no espera
a que el anterior esté en pantalla, sino a que lo esté el penúltimo, es decir, a que la superficie del antepenúltimo
haya salido de ella.)

**Cómo lo cumple 0353** (§4.4): los ids de swap siguen a los frames (cola, flip escrito, flip tomado, superficies
retenidas por el scanout), y `SwapWait` responde con ese estado, el mismo que usa `scanoutBusy()`:

| Pregunta | Responde 0 cuando |
|---|---|
| `SwapWait(id, 0x80000000)` (o sin el bit 31) | ningún frame de `id` para escanear espera en la cola, está en el panel o lo está dejando (sin flip posterior tomado); un frame copiado no retiene su superficie (la copia va antes en el ring), uno compuesto por la CPU tampoco |
| `SwapWait(id, 0x80000001)` | el DPU ha tomado el flip de `id` o uno posterior y nada de `id` o anterior espera en la cola |
| `SwapWait(0, 2)` / `0x80000003` | ídem para el último swap |
| sin `0x80000000` | espera a lo anterior, 100 ms como mucho (`kIOReturnTimeout`) |

Antes de responder, la llamada mira la cola (`queueFlip()`): un flip tomado desde la última mirada del hilo cuenta ya.
La misma pregunta ocupada más de 1 s se responde 0 y se cuenta (ninguna espera de un frame dura eso; una GPU colgada se
reinicia a los 2 s). Tras una espera de todos (`SwapWait(0, 2)` bloqueante), el `SwapEnd` siguiente vuelve cuando su
propio frame está en el panel: después de `idle()` CoreAnimation ya no pregunta por la página del frame en pantalla, y
sin esa espera el frame siguiente al siguiente podía dibujarse en esa superficie mientras se escanea (lo encontró el
modelo, §6.4). 0353 espera siempre, 50 ms como mucho. Con 0354, solo si en el panel puede haber un frame de superficie
(uno copiado está en un flip buffer y su superficie ya está libre), y hasta 250 ms: con 0353, en el teléfono, 14 de 78
esperas llegaron a los 50 ms (`SwapEnds held after a wait for every swap 78, 1433117 us in all, max 50122, timed out
14`, `telefono/diag-scan.txt`), y una espera que vence deja dibujar en la superficie del panel.
`kern.sweet_fb_swapwait=2` retiene también las superficies de los frames copiados hasta un flip posterior, como un
IOMobileFramebuffer que las retuviera; 0 responde 0 al instante, como hasta 0352. El valor por defecto es 1 (§3.11;
medido en 03 M16). **Con 0354 el scanout exige 1 o 2:** con 0 sus frames se copian (`kern.sweet_fb_swapwait 0` en las
causas de `kern.sweet_fb_scanout_diag`), y poner 0 con el scanout activo re-presenta el frame en pantalla por la copia,
como `kern.sweet_fb_scanout=0`. Con 0353 solo, `swapwait=0` con `scanout=1` desgarra (en el modelo, 277 dibujos sobre
la superficie escaneada por ejecución).

### 3.11 Con dos superficies, y las opciones medidas en el modelo

El modelo de CoreAnimation (§6.4) sigue el algoritmo de §3.10 contra el texto del kernel; régimen del teléfono
calibrado con 03 M11 (CPU del hilo de render 10-17 ms por frame, dibujo de GPU 4-24 ms con la distribución medida,
copia 3-6 ms), temporizador de 120 Hz con fase cualquiera frente al panel; 30 semillas × 30 s:

| Opción | Frames/s | Tick → panel | `SwapEnd` → panel (p95) | GPU ocupada | Copias por superficie ocupada | Cambios del plano | Superficies |
|---|---|---|---|---|---|---|---|
| Copia, `SwapWait` al instante (hasta 0352) | 55,4 | 31,5 ms | 17,5 (26,5) ms | 69 % | — | 0 | 2 |
| Copia, 0353 (`swapwait=1`) | 55,4 | 31,5 ms | 17,5 (26,5) ms | 69 % | — | 0 | 2 |
| Scanout, `SwapWait` al instante (0352) | 55,4 | 27,4 ms | 13,4 (22,3) ms | 48 % | 9,0/s, y 9,2 dibujos/s sobre la superficie escaneada | 12,5/s | 2 |
| Scanout, `SwapEnd` retenido hasta que su frame está en el panel | 33,6 | 26,3 ms | 12,3 (20,5) ms | 27 % | 0 | 0 | 2 |
| Scanout, 0353 con dos superficies como máximo (límite que CoreAnimation no tiene) | 33,5 | 26,4 ms | 12,4 (20,6) ms | 27 % | 0 | 0 | 2 |
| **Scanout, 0353 (`swapwait=1`)** | **54,2** | **26,6 ms** | **12,6 (20,8) ms** | **43 %** | **0** | **0** | **3** |
| Scanout, 0353, temporizador 0,5 ms tras la toma del panel | 54,8 | 26,6 ms | 12,5 (20,8) ms | 44 % | 0 | 0 | 3 |

Con la GPU como límite (dibujo de 14-24 ms, CPU 6-10 ms): copia 41,8 frames/s y 66,8 ms del tick al panel; scanout con
`SwapEnd` retenido 27,9 y 32,3 ms; scanout con 0353, 49,6 y 36,6 ms. Ligero (CPU 3-6 ms, GPU 2-4 ms): copia 117,1 y
20,5 ms; retenido 61,6 y 12,7 ms; 0353, 113,8 y 14,0 ms (120,0 con el temporizador alineado).

- **Con dos superficies** el frame N+2 solo puede empezar cuando el N+1 está en el panel; retener el `SwapEnd` o
  responder ocupado con dos superficies como máximo dan lo mismo (33,5-33,6 frames/s): un frame por cada CPU + GPU +
  espera al panel. La copia, que libera la superficie en el `SwapEnd`, rinde más que eso. Lo correcto es darle a
  CoreAnimation la señal para que cree la tercera, que es lo que hace 0353.
- **Lo que cuesta la tercera:** CoreAnimation va dos frames por delante del panel como mucho (la copia, más: sus
  superficies quedan libres al momento y la cola de 0340 retiene el `SwapEnd`); cuando el flip del N-1 no está tomado en
  el milisegundo que pregunta, se salta un tick (2,3 por segundo en el modelo): 1,2 frames/s menos que la copia, a
  cambio de 4,9 ms menos de latencia y 26 puntos de GPU. Con el temporizador de CoreAnimation alineado con la toma del
  panel se salta 0,5 ticks por segundo. CoreAnimation alinea su fase con `IOMFBDisplay::timing_reference()` (19 §1.3), y
  qué lee esa función está por mirar: es el siguiente paso para acercar el scanout a 120 Hz.
- `kern.sweet_fb_swapwait=2` con la copia: menos latencia con la GPU como límite (44,1 frente a 66,8 ms), pero menos
  frames: 51,6 frente a 55,4 (ligero, 91,1 frente a 117,1). Por eso el valor por defecto es 1.

### 3.12 El plano en régimen

El plano cambia de modo (escalado ↔ sin escalar: 27 registros) cuando un frame va por la copia después de uno
escaneado, o al revés. Con 0353 eso pasa en cada frame que no encaja: varias capas, una superficie fuera del pool o de
otro tamaño, el sysctl cambiado, o una superficie aún en uso (esto último, con `SwapWait` fiel, casi no pasa: 6 de
19 058 frames en el teléfono). En régimen
(una capa a pantalla completa, las tres superficies en el pool) el plano queda escalado: en el modelo, como mucho un
cambio por ejecución (el primero). Pero con una superficie del anillo fuera del pool, sus frames van por la copia (5,2
por segundo en 03 M22) y el plano cambia dos veces por cada uno (77 veces en 10 s en cada sentido), y cada
frame de varias capas lo cambia dos veces (3,6 por segundo con uno de cada 30 en el modelo).

0354 quita las dos causas de cambios en régimen:

- **Un solo modo mientras el anillo sea el mismo.** Una superficie que el window server presenta y no puede escanearse
  (fuera del pool, otro tamaño o formato) se anota por su id y su puntero (`fScanBlock[]`, sin retenerla); mientras
  alguna anotada siga viva (`sweet_surface_alive()`: la tabla de ids aún tiene esa superficie con ese id; ni liberada
  ni soltada por todos sus usuarios), todos los frames van por la copia (`frames copied for them`). Cuando se va, vuelve
  el scanout: un cambio de modo cuando cambia el anillo, no uno por frame. Con ocho huecos no debería anotarse ninguna
  (§3.13); si se anota, `kern.sweet_fb_scanout_diag` dice cuántas, y la línea de cada hueco dice qué superficies lo
  llenan.
- **Frames 2x de varias capas.** `shownRecord()` los enseña por su capa 0 si esta es la superficie a pantalla completa
  del window server (con una copia del registro que solo tiene la capa 0 en la máscara), y si no, no los enseña (el
  panel conserva su frame; su swap queda hecho para `SwapWait`). Los ocho primeros van al log con lo que trae cada capa.
  Las otras capas no se ven en ese frame; con la copia 2x de 0353 tampoco (`present()` solo copia una capa en 2x), y
  además voltea el buffer trasero tal cual: un frame más viejo durante un refresco. Si el log muestra capas con
  contenido que importa, componerlas es el paso siguiente.

En el modelo, con 0354: ningún cambio de modo en régimen en ningún escenario, también con frames de dos capas cada 30
(1,8 por segundo enseñados por su capa 0) y con la vida del anillo (§3.13, §6.4).

### 3.13 La vida del anillo de CoreAnimation y el tamaño del pool

**Lo que se vio** (03 M22, kernel 0353, scanout encendido varias horas con reinicios de backboardd):
`pool: 4 of 4 slots in use, 31 surfaces made in it, 14 refused (full)`; en 10 s, `not from the pool` +52 y los cambios
del plano +77 en cada sentido; la pantalla entera saltaba. Más tarde, con el scanout aún encendido
(`telefono/diag-scan.txt`): `pool: 3 of 4 slots in use, 40 surfaces made in it, 14 refused`, y en todo el arranque
19 058 frames, de ellos 4 766 copiados por `not from the pool`, 57 por `not one layer` y 6 por `swapped again`, y 4 799
cambios a escalado. Casi todos los cambios del plano vienen de frames de una superficie fuera del pool. El pool no
pierde huecos (bajó de 4 a 3 en uso y siguió creando superficies en él): se queda corto en los momentos de más
superficies.

**Cómo hace y suelta CoreAnimation sus superficies de pantalla** [O, QuartzCore 20H392, desensamblado con nombres]:

- Cada página del anillo (§3.10) apunta a un `Buffer`, y cada `Buffer` a su superficie.
  `IOMFBDisplay::current_page_surface` (0x18853c4cc) mira la del `Buffer` de la página siguiente: si su ancho, su alto,
  su formato, un bit de sus banderas (bit 24 de `[superficie+0x38]`, frente a lo que da el método virtual `+0x5c8` del
  display) o un valor de 64 bits (el método `+0xc8` de la superficie, frente al argumento de 64 bits de la función) no
  coinciden con lo que pide el display (0x18853c650-0x18853c6a4), crea otra con `Display::allocate_surface`
  (0x18853c6fc) con el nombre `"CA Framebuffer"` (`"CA Assembly Buffer"` en el otro caso, 0x18853c594-0x18853c5dc) y
  suelta la vieja de ese `Buffer` (0x18853c724). La página que la enseñó la retiene hasta que se recupera
  (0x1882beb84-0x1882bebf4), y el kernel mientras el panel pueda leerla.
- `CA::SurfaceUtil::CAIOSurfaceCreate` llama a `IOSurfaceCreate` (0x18832468c) y después pone el nombre con
  `IOSurfaceSetValue` (0x1883246b8): el kernel no lo ve al crearla; por eso el criterio del pool es el proceso, el
  tamaño y el formato (§3.2), y coge también otras superficies de backboardd del tamaño de la pantalla.
- `IOMFBDisplay::collect_buffers` (0x188305288) libera los `Buffer` sin uso cuya superficie ya no corresponde al valor
  de 64 bits actual (0x1883052d8-0x18830530c), con su superficie.
- Qué cambia ese valor o ese bit en el teléfono no está leído [H]. Que pasa lo dicen los contadores: 40 superficies
  hechas en el pool en un arranque de unas horas, con un puñado de reinicios de backboardd.

**Cuántas a la vez:** tres en uso (las páginas). Cuando cambia lo que pide el display, hasta tres nuevas mientras viven
las viejas que aún no ha liberado `collect_buffers` (hasta tres); un backboardd reiniciado hace las suyas mientras el
kernel aún retiene la superficie del panel del anterior (hasta que el DPU toma un flip posterior); y backboardd hace a
veces superficies del tamaño de la pantalla que no presenta, que también cogen hueco. En el peor caso, tres viejas +
tres nuevas + una sin presentar: siete; ocho deja uno de margen. Con cuatro huecos, la nueva que no cabe queda fuera
del pool **toda su vida**, y es una de las tres del anillo: sus frames van por la copia.

**0354:** ocho huecos de 5 MiB (0xe5000000-0xe7800000; §1.5) y el modo único de §3.12, que hace que una superficie
fuera del pool no cambie el plano frame a frame aunque el pool vuelva a quedarse corto. Para verlo,
`kern.sweet_fb_scanout_diag` lista cada hueco en uso con la superficie, su `IOSurfaceName`, el proceso que la hizo, su
edad, cuántas veces se presentó y cuándo por última vez (`SweetSurface` guarda creador, hora de creación, swaps y
último swap; `presentNow()` cuenta los swaps).

En el modelo (§6.4) la vida del anillo es: un cambio de lo que pide el display cada 3-8 s (las viejas se sueltan en
cuanto quedan sin uso, más deprisa que `collect_buffers`: por eso usa menos huecos que la cuenta del peor caso), un
reinicio de backboardd cada 10-30 s y una superficie del tamaño de la pantalla, sin presentar, durante 4-6 s de cada
5-20 s. Con el texto de 0353 de la serie y cuatro huecos (cambio cada 8 s, reinicio cada 30 s, superficie suelta 6 s
de cada 20): el 90 % de los frames escaneados, 5,2 frames/s copiados por una superficie fuera del pool (en el teléfono,
5,2/s), 10,4 cambios del plano por segundo (6,9 en régimen); con tres huecos, 24,6 cambios por segundo en régimen. Con
0354:

| Pool | Frames escaneados | Copiados por la superficie fuera del pool / por las demás del anillo | Cambios del plano en régimen | Huecos usados como mucho |
|---|---|---|---|---|
| ocho huecos, en los cinco escenarios de la vida del anillo | 100 % | 0 / 0 | 0 | 5 |
| cuatro (cambio cada 8 s, reinicio cada 30 s, superficie suelta 6 s de cada 20) | 80 % | 5,5/s / 5,5/s | 0 | 4 |
| tres (ídem) | 53 % | 12,9/s / 12,9/s | 0 | 3 |

Con cuatro o tres huecos el plano se queda en la copia mientras dura la superficie de fuera, y vuelve al scanout cuando
muere: dos cambios por cada vez que el pool se queda corto (0,07 y 0,13 por segundo en total).

### 3.14 El encuadre de los dos caminos

**Qué rectángulo usa cada uno** con `fOffX` 20, de 0350 a 0353 (superficie 2x de 750×1624, panel de 1080×2400):

- **Ventana:** la del panel en el lienzo 3x de 1125×2436 (los puntos de iOS a escala 3), en (`fOffX`, `fOffY`) =
  (20, 18), a 2/3: origen (13,33; 12) y tamaño 720×1600 en la superficie (§1.6); de ahí, ×1,5 a todo el panel. El
  panel enseña 1080×2400 de los 1125×2436 del lienzo: 45 columnas y 36 filas fuera.
- **Copia** (`present()` → `sapphire_gpu_copy_scaled()` → `blit_scale()`): dos pasadas bilineales del blitter 2D,
  intercaladas (filas pares e impares del panel, con pitch 8640 porque 4320 no es múltiplo de 64); el origen en 1/256
  de píxel, (3413, 3072), va en `GRAS_A2D_SRC_XMIN`/`YMIN`, con la base de la textura en la superficie.
- **Scanout** (`presentScanout()`): `SRC0_ADDR` = la superficie, `SRC_XY` = (13, 12), `SRC_SIZE` 720×1600,
  `OUT_SIZE` 1080×2400 en `OUT_XY` (0, 0), escalador con fase inicial 0 y paso 2/3.
- **Leído en el teléfono** (kernel 0353, `kern.sweet_fb_regs`, `telefono/regs-scan.txt` y `regs-copia.txt`, con el
  home quieto): con el scanout, VIG0 +000 = 064002d0, +008 = 000c000d, +00c = 09600438, +010 = 0, +014 = e5a00000,
  +024 = 00000c00, +038 = 80000000; escalador +010-+01c = 00155555, +040/+044 = 064002d0, +048 = 09600438, fases 0:
  lo calculado (§3.5). Con la copia, el plano del ABL (+000 y +00c = 09600438, +008 = 0, +014 = un flip buffer, +024 =
  000010e0). Los dos caminos están programados como dice el código; la diferencia, si la hay, está en cómo aplica cada
  motor su origen.

**Dónde cae cada píxel** (`encuadre.cpp`, §6.2). Para cada píxel del panel, la coordenada de la superficie que enseña
cada camino; la diferencia copia − scanout es positiva cuando la copia enseña en ese píxel algo más a la derecha o más
abajo de la superficie, es decir, cuando su imagen está desplazada arriba y a la izquierda:

| Ventana y scanout | Lectura del hardware | Copia − scanout (media, píxeles del panel) | Máximo |
|---|---|---|---|
| `fOffX` 20, 0353 | los dos motores aplican su origen | +0,25, −0,25 | 0,35 |
| | el blitter ignora su origen | −19,75, −18,25 | 27,2 |
| | **el plano ignora `SRC_XY`** | **+19,75, +17,75** | 26,6 |
| `fOffX` 24, 0354 | los dos motores aplican su origen | −0,25, −0,25 | 0,35 |
| | el blitter ignora su origen | −0,25, −1,00 | 1,27 |
| | el plano ignora `SRC_XY` | −0,25, −0,25 | 0,35 |

**Qué casa con lo visto.** Con el pool lleno, la mayoría de los frames se escaneaban y unos cinco por segundo iban por
la copia; el usuario vio la imagen entera saltar en diagonal hacia arriba y a la izquierda unos milímetros, una y otra
vez. Con el píxel del panel de 0,064 mm (6,67", 1080×2400), +19,75 y +17,75 píxeles son 1,3 mm a la izquierda y 1,1 mm
hacia arriba en los frames copiados: es la lectura «el plano ignora `SRC_XY`» [H: una observación, sin foto]. Con los
dos orígenes aplicados no se vería nada, y con el del blitter ignorado el salto iría hacia abajo y a la derecha. Ni los
registros ni el código dicen por qué el plano no recortaría por `SRC_XY`, que Linux usa así; con 0354 no hace falta
saberlo.

**0354 recorta por la dirección en los dos caminos.** `fOffX` pasa al múltiplo de 24 más cercano al centro, 24
((1125 − 1080) / 2 = 22,5): en el lienzo 3x la ventana empieza en la columna 24 (96 bytes, múltiplo de los 16 que pide
el DPU) y en la superficie 2x en (16, 12): 64 bytes justos, lo que pide la base de la textura del blitter. El scanout
pone en `SRC0_ADDR` las filas enteras y los grupos de 16 bytes de columnas del origen (superficie + 12·3072 + 16·4 =
+0x9040) y en `SRC_XY` el resto, (0, 0); la copia pone en la base de la textura las filas enteras de cada pasada y los
grupos de 16 píxeles de columnas, y en `GRAS_A2D_SRC_XMIN`/`YMIN` el resto: ninguna columna y una fracción de fila
(el centrado de las filas de cada pasada). Con eso los dos caminos coinciden a 1,27 píxeles del panel como mucho sea
cual sea la lectura, y la ventana queda a 1,5 píxeles del panel del centro (16 columnas de la superficie fuera a la
izquierda y 14 a la derecha) en vez de 2,5. El táctil (`SweetHID.cpp`) usa la misma regla para su `fOffX`: lo que se ve
y lo que se toca se mueven juntos unos 4 píxeles del panel (0,26 mm) a la izquierda respecto a 0353, en los dos modos.

## 4. Los parches

En `xnu/patches/`, numerados por el coordinador: 0349 y 0350 (escritos como 0347 y 0348, integrados tal cual), 0352
(incremental, sobre la serie con 0343-0351) y 0353. 0354 está en
`~/sapphire-angel/research/metal/display/parches-nuevos/`, sobre la serie con 0343-0353. Las versiones descartadas, en
`work/obsoletos/`, entre ellas una revisión de 0353 posterior a la integrada (valor por defecto 0, el scanout exigiendo
`SwapWait`, la retención solo con un frame de superficie en el panel): lo que tiene de más lo lleva 0354 (punto 6), con
el valor por defecto de la serie, 1.

### 4.1 `0349-sapphire-fb-dpu-regs-latch-diag.patch` (diagnóstico; solo lectura)

`SweetFramebuffer.cpp` y `SweetSurface.cpp`. No escribe ningún registro que no se escribiera antes.

- **`kern.sweet_fb_regs`** (lectura): MDP TOP, CTL0, VIG0, su escalador y su CSC, LM0, PP0 e INTF1 tal como están, 8
  palabras por línea (~13 KB de texto), más VIG0 y su escalador tal como los dejó el ABL.
- **`kern.sweet_fb_latch`** (lectura): para cada flip, si `CTL_FLUSH` devuelve los bits recién escritos (0x20001),
  cuánto tardan en limpiarse, con cuántos frames de `INTF_FRAME_COUNT` (por dieciseisavo del refresco en que se
  escribió), cuántas veces avanzó el contador con los bits aún puestos y cuántos no se limpiaron en 100 ms. Lo miran el
  hilo de la cola (cada 500 µs con un flip pendiente) y los ticks; con la pantalla apagada no mira nadie (de ahí el
  máximo de 36 s en «more»).
- **Registro de superficies de pantalla:** las 16 primeras del tamaño del panel o del 2x, quién las crea y los nombres de
  sus propiedades (`SWEET SURF: screen-sized surface N by P: …`).

### 4.2 `0350-sapphire-fb-scanout-vig-scaler.patch` (scanout directo; apagado por defecto)

`SweetFramebuffer.cpp`, `SweetSurface.cpp`, `SweetSurface.h`, `SapphireGpu.cpp`.

| Interruptor | Valores | Efecto |
|---|---|---|
| `kern.sweet_fb_scanout` (boot-arg `sweetfb_scanout`) | **0** (defecto) | como antes |
| | 1 | superficies de pantalla de backboardd en el pool y scanout directo de sus frames |
| | 2 | solo el pool (los frames se siguen copiando) |
| `kern.sweet_fb_scanout_diag` | lectura | listo o por qué no; `CTL_FLUSH`; pool; frames, flips y frames copiados con su motivo; dibujos después del `SwapEnd`; esperas en `SwapEnd`; cambios del plano y sus esperas; superficies soltadas; paradas; flushes no tomados; la ventana en pantalla |

Piezas: el pool y su criterio (`SweetSurface.cpp`: `sweet_pool_*`, `kernelAddress()` WC para el pool); la valla por
superficie y el mapeo WC del cliente de la GPU (`SapphireGpu.cpp`: `sapphire_gpu_msm_fence*`, `gpuFence` en el submit,
`clientMemoryForType`, el modo 0 de la limpieza salta el pool); y en `SweetFramebuffer.cpp`: `sweet_plane_scaled_regs`
y `sweet_scan_window` (aritmética pura), `scanoutInit` (lee y valida el plano del ABL, configura el pool),
`presentScanout` (decide y encola), `planeScaled`/`planeUnscaled`/`planeWritable` (escriben el plano solo cuando no
puede tomarse a medias), `frameDone`/`frameShow` (valla y flip de cada clase de frame), `scanoutLeave`/`scanoutRetire`
(vida de la superficie), `flipNote` (la contabilidad de 0340 de un flip), `scanoutStop` (vuelta a la copia en caliente)
y el vigilante de 100 ms en `queueFlip`.

### 4.3 `0352-sapphire-fb-scanout-fixes-flush-taken.patch`

Solo `SweetFramebuffer.cpp`; nada cambia mientras `kern.sweet_fb_scanout` y `kern.sweet_fb_flush_taken` estén a 0
(salvo que `presentQueued()` limpia el hueco de la cola que rellena, que solo importa con frames de superficie en ella).

1. `presentQueued()` (0340) limpia el hueco que rellena (defecto 1 de §6.3).
2. `scanFrom()` y `planeScaled()` anotan el flip cuando lo escriben, tras la espera (defecto 2 de §6.3).
3. Ningún frame de superficie se enseña antes de terminar su dibujo (0350 lo hacía a los 250 ms); `queueDrain()`
   descarta el que aún se dibuja.
4. `flushNote()` cuenta lo que lee `CTL_FLUSH` tras cada escritura; con la lectura establecida, `planeWritable()` no
   exige ventana de líneas y los flips del scanout se dan por tomados por los bits. **`kern.sweet_fb_flush_taken`**
   (boot-arg `sweetfb_flush_taken`), defecto 0: 1 = todos los flips, copias incluidas, se dan por tomados por los bits.
5. `kern.sweet_fb_scanout_diag`: la primera línea da cuántos flips devolvieron los bits y qué regla toma los flips.

### 4.4 `0353-sapphire-fb-swapwait-from-queue.patch` (`SwapWait` con el estado de la cola)

Solo `SweetFramebuffer.cpp`. Necesita 0340, 0350 y 0352. Con la cola apagada (`kern.sweet_fb_queue=0`) no cambia nada.
Con la copia, CoreAnimation sigue con dos superficies y el mismo ritmo (§3.11): lo que cambia es que `SwapWait` dice la
verdad sobre el panel, que las esperas bloqueantes esperan, y que el `SwapEnd` tras una espera de todos espera a su
frame (50 ms como mucho). Con el scanout, CoreAnimation hace la tercera superficie y el plano queda escalado en régimen
(03 M16).

| Interruptor | Valores | Efecto |
|---|---|---|
| `kern.sweet_fb_swapwait` (boot-arg `sweetfb_swapwait`) | 0 | `SwapWait` responde 0 al instante, como hasta 0352 (con 0354 el scanout copia entonces sus frames) |
| | **1** (defecto) | `SwapWait` responde con el estado de la cola (§3.10) |
| | 2 | además, las superficies de un frame copiado quedan en uso hasta un flip posterior tomado |
| `kern.sweet_fb_swapwait_diag` | lectura | preguntas por superficies libres, por un frame en pantalla y por todos (y cuántas ocupado); esperas, su tiempo y las vencidas; la pregunta ocupada más larga y las respondidas 0 al pasar 1 s; `SwapEnd` retenidos tras una espera de todos; los ids de swap del último flip, del panel y de las superficies retenidas |

Piezas: `SweetQFrame.swap` y los ids de swap de `AppleCLCD` (`fSwapShow`, `fFlipSwap`, `fPanelSwap`, `fScanShowSwap`,
`fScanLeaveSwap[]`), anotados en `presentQueued`/`presentScanout` (frame en cola), `frameShow` y `flipNote` (flip
escrito), `flipTaken` (flip tomado), `scanoutLeave`/`scanoutRetire` (superficies retenidas); `swapShown`, `swapFree` y
`swapWait` (la respuesta), `swapEndHold` (el `SwapEnd` tras una espera de todos, desde `swap()`); el selector 6 del
user client llama a `swapWait`. `scanoutBusy()` no cuenta las copias en cola de la superficie (la copia va antes en el
ring), para que diga lo mismo que `swapFree()`. El comentario de 0350 sobre la vida de la superficie dice que
CoreAnimation lo sabe por `SwapWait`, no por el contador de uso.

### 4.5 `0354-sapphire-fb-scanout-pool-stable-framing.patch` (pool, modo único y encuadre)

`SweetFramebuffer.cpp`, `SweetSurface.cpp`, `SweetSurface.h`, `SapphireGpu.cpp` y `hid/SweetHID.cpp`. Necesita 0350,
0352 y 0353. Con `kern.sweet_fb_scanout=0` cambian la ventana (punto 4: la imagen y el táctil, 4 píxeles del panel a la
izquierda), los frames 2x de varias capas (punto 3) y que el `SwapEnd` de un frame copiado ya no espera tras `idle()`
(punto 6).

1. **Pool de ocho huecos** (`SWEET_FB_SCAN_SLOTS` 8: 0xe5000000-0xe7800000), por la cuenta de §3.13.
2. **Un solo modo mientras el anillo sea el mismo** (§3.12): `scanoutBlock()` anota (id y puntero, sin retener) la
   superficie que `presentScanout()` rechaza por no ser del pool o por tamaño o formato; `scanoutBlocked()` quita las
   que ya no están vivas (`sweet_surface_alive()`, en `SweetSurface.cpp`) y dice si queda alguna; mientras quede,
   `presentScanout()` manda el frame a la copia (`held_off`). Ocho anotaciones como mucho; si hicieran falta más, la
   nueva reemplaza a la más antigua.
3. **Frames 2x de varias capas:** `shownRecord()` (§3.12), desde `presentNow()` y `scanoutStop()`; `present()` no
   voltea el buffer trasero por un frame 2x del que no copió nada (`not_shown`).
4. **Ventana recortada por la dirección** (§3.14): `fOffX` es el múltiplo de 24 más cercano a (1125 − 1080) / 2, 24,
   en `AppleCLCD::start()` y en `SweetHIDTouch::start()`; `presentScanout()` pone el origen en `SRC0_ADDR` (filas y
   grupos de 16 bytes) y el resto en `SRC_XY`; `blit_scale()` pone filas y grupos de 16 píxeles en la base de la textura
   y el resto en `GRAS_A2D_SRC_XMIN`/`YMIN`. `SweetQFrame` lleva el origen (`ox`, `oy`) y el plano recuerda el que
   enseña (`fPlaneOX`, `fPlaneOY`) para el diagnóstico.
5. **Censo del pool** en `kern.sweet_fb_scanout_diag`: una línea por hueco en uso (`slot N: surface S "CA Framebuffer"
   by backboardd, made T s ago, swapped K times, last M ms ago`; `sweet_scanout_pool_describe()`), la línea `0354:`
   (superficies anotadas vistas y anotadas ahora, frames copiados por ellas, frames enseñados por su capa 0, frames no
   enseñados) y `showing X,Y WxH of a surface (rows of B bytes) from 0x…: X,Y of it through the address, SRC_XY 0,0`.
   `SweetSurface` guarda el proceso creador y la hora (`create()`), y `presentNow()` cuenta sus swaps y el último;
   `SweetSurface::free()` quita los valores con el candado de la tabla (el censo lee de ahí el nombre). El texto del
   diagnóstico pasa de 2 a 3 KB.
6. **De la revisión de 0353:** `scanoutOn()` exige `kern.sweet_fb_swapwait` 1 o 2 (con 0 los frames del scanout se
   copian y se cuentan como `kern.sweet_fb_swapwait 0`); poner 0 con el scanout activo llama a `scanoutStop()`; la
   retención del `SwapEnd` tras una espera de todos solo se da si en el panel puede haber un frame de superficie
   (`fScanShowSwap`, `fScanLeaveSwap[]`, frames de scanout en cola), y dura hasta 250 ms (§3.10).

| Interruptor | Valores | Efecto |
|---|---|---|
| `kern.sweet_fb_scanout` | 0, 1, 2 | como en 0350; con 1, el modo único |
| `kern.sweet_fb_swapwait` | **1** (defecto), 2, 0 | como en 0353; el scanout exige 1 o 2 |
| `kern.sweet_fb_scanout_diag` | lectura | además, el censo de huecos, la línea `0354:` y el origen de la ventana repartido entre la dirección y `SRC_XY` |

## 5. Candados

- Todo el estado del scanout (cola, superficies en pantalla y saliendo, plano, cuentas de `CTL_FLUSH`) va con
  `fPresentLock`, como la cola de 0340. El tick del apagado de pantalla toma `fPresentLock` alrededor de su flip.
- Orden: `fPresentLock` → `service_lock` (la copia, como antes) y `fPresentLock` → `sweet_surface_lock` (soltar una
  superficie puede liberarla y devolver su hueco; 0340 ya soltaba superficies con `fPresentLock`). `fLock` nunca está
  tomado al tomar `fPresentLock` (`scanoutStop` copia `fPending` con `fLock` y lo suelta antes). `SweetSurface` pregunta
  `sweet_fb_scanout_pool_on()` sin candado (dos palabras).
- **Esperas:** el `SwapEnd` que espera sitio en la cola duerme con `IOLockSleepDeadline` (suelta el mutex). La espera de
  un plano escribible es un bucle de lecturas de registros de 20 ms como mucho con `fPresentLock`, solo en cambios de
  modo y en el vaciado de la cola; con la lectura de `CTL_FLUSH` establecida dura lo que tarde el flush pendiente (≤ un
  refresco). No usa `IODelay`, así que sirve en la consola de pánico.
- **Sin candado:** `sweet_cons_show()` (pánico) llama a `scanFrom()` como antes. `gpuFence` lo escribe el submit con
  `service_lock` y lo lee `frameDone()` sin él (una palabra); igual `msm_seq`.
- **0353:** los ids de swap se escriben solo con `fPresentLock`. `swapWait()` se llama desde el hilo del cliente sin
  candados: lee el swap retenido del puente GL (`fHeldRec`) con `fLock` y lo suelta, y después toma `fPresentLock`; su
  espera duerme con `IOLockSleepDeadline` sobre `fPresentLock` (lo suelta) y la despiertan `queueFlip()` (el mismo
  evento que a los `SwapEnd` que esperan) o su propio plazo de 1 ms. `swapEndHold()` se llama desde `swap()` después de
  `presentNow()`, sin candados, y espera igual; nunca desde el temporizador. Ningún orden de candados nuevo.
  `kern.sweet_fb_swapwait_diag` lee los ids sin candado (palabras; diagnóstico).
- **0354:** `fScanBlock[]`, `fPlaneOX`/`fPlaneOY`, los swaps de cada superficie y el registro reducido de
  `shownRecord()` van con `fPresentLock`. `sweet_surface_alive()` y `sweet_surface_copy()` (en `shownRecord()`) toman
  `sweet_surface_lock` con `fPresentLock` tomado: el orden `fPresentLock` → `sweet_surface_lock` que ya existía. El
  censo (`sweet_scanout_pool_describe()`) recorre los huecos con `sweet_surface_lock`; el puntero de cada hueco se pone
  tras publicar la superficie y se borra cuando el hueco vuelve, en `free()`, los dos con ese candado. Los valores de
  una superficie (de donde el censo lee el nombre) se cambian siempre con él, y `free()` los quita de la superficie con
  él antes de devolver el hueco (los suelta después): el censo nunca lee un diccionario liberado. Ninguna superficie se
  suelta con `sweet_surface_lock` tomado (comprobado en los tres archivos), así que `free()` puede tomarlo. Los swaps y
  su hora se escriben con `fPresentLock` y el censo los lee sin él (palabras; diagnóstico). `shownRecord()` reserva el
  registro reducido con `IOMallocData` con `fPresentLock` tomado (un mutex).

## 6. Verificación

Herramientas en `~/sapphire-angel/research/metal/display/work/verif/`.

### 6.1 Aplicación y compilación

- `check-0352.sh`: la serie oficial 0343-0350 de `xnu/patches/` sobre el árbol a 0342 y después 0352, con y sin el
  0351 de otro agente delante: **todos aplican en orden** con `git apply --check`; `clang++ -fsyntax-only` con los
  stubs de `kernel-gpu/verificacion/`: **0 errores** en los tres archivos.
- `check-0353.sh`: la serie oficial 0343-0352 de `xnu/patches/` sobre el árbol a 0342 y después 0353: **los 11
  aplican en orden**; **0 errores** de sintaxis en los tres archivos; el `SweetFramebuffer.cpp` resultante es igual al
  del árbol de trabajo (`check-0353.log`).
- `check-0354.sh`: la serie oficial 0343-0353 de `xnu/patches/` sobre el árbol a 0342 y después 0354: **los 12
  aplican en orden**; **0 errores** de sintaxis en los cuatro archivos (`hid/SweetHID.cpp` incluido); los cinco
  archivos resultantes son iguales a los del árbol de trabajo (`work/xnu-0354`); `warn-0354.sh`: **ningún aviso** de
  `-Weverything` en las 336 líneas añadidas (`check-0354.log`).
- `inject.py`: un identificador sin declarar al principio de cada función nueva o cambiada: **31 de 31** (0349/0350),
  **11 de 11** (0352), **20 de 20** (0353) y **21 de 21** (0354) señalados: todo el código nuevo se compila de verdad.
- `warn.sh` (`-Weverything` con la lista `-Wno` del kernel): en las líneas añadidas solo salen los avisos de las macros
  `SYSCTL_*` que ya da el código vecino (también en las 329 de 0353).

### 6.2 Aritmética del plano frente a Linux y al driver de stock (`arnes/`)

`extract.py` corta **literalmente** de Linux v6.12 `setup_rects`, `setup_pe_config`, `_dpu_plane_setup_scaler3`,
`_dpu_plane_setup_pixel_ext`, `dpu_hw_setup_scaler3` (con sus funciones de tabla y de realce), `mult_frac`, las
estructuras y los offsets, y del kernel `sweet_plane_off[]`, `sweet_plane_scaled_regs()` y `sweet_scan_window()`.
`arnes.c` hace escribir a Linux un plano escalado en un registrador y lo compara registro a registro:

- caso del teléfono: **Linux escribe exactamente los mismos 27 registros con los mismos valores** (tabla de §3.5);
- 200 003 casos (rectángulos aleatorios dentro de los límites del escalador, versiones 0x00030000 y 0x3000, con y sin
  alfa, 8 y 10 bits, op modes del ABL aleatorios sin volteo): **0 diferencias**;
- la ventana de `sweet_scan_window()` frente a la de la copia (1/256 px) para cada escala de render de 400 a 1000 ‰:
  origen dentro del píxel, tamaño a ±0,5 px, **0 fuera**;
- cinco mutaciones del código del kernel (precarga, filtro de alfa, orden de `REQ_PIXELS`, PE override, paso de fase):
  **las cinco se detectan**.

`arnes-sde.c`: `_sde_plane_setup_scaler3` y `sde_hw_setup_scaler3` literales del driver de stock, con el bloque iniciado
como lo hace su catálogo con el DT del teléfono (`sde_init_scaler_blk`, 0x3000): **100 001 casos, 0 diferencias** en los
registros del escalador.

`encuadre/encuadre.cpp`: `blit_scale()` (de `SapphireGpu.cpp`) y `sweet_scan_window()` extraídos tal cual (y el
`blit_scale()` de 0353, para comparar), las escrituras de registros de la copia capturadas y el muestreo bilineal del
blitter modelado (centros de texel, `XMIN`…`XMAX` repartidos sobre el ancho de destino, las dos pasadas intercaladas);
el scanout con su dirección, su `SRC_XY` y el paso del escalador. Para cada píxel del panel compara la coordenada de la
superficie que enseña cada camino, con `fOffX` 20 y 24, el scanout como 0353 y como 0354, y tres lecturas del
hardware: la tabla de §3.14 (`encuadre-0354.log`).

### 6.3 Simulación de la cola con frames de superficie (`sim-scanout/`)

`extract.py` corta del `SweetFramebuffer.cpp`, tal cual (solo las barreras `dsb` pasan a comentario), los globales del
scanout, `scanFrom`/`flushNote`/`flipNote` y todo desde `queueOn()` hasta el user client (con 0353, también
`swapShown`/`swapFree`/`swapWait`/`swapEndHold`). `simcore.h` es el modelo común: reloj virtual en el que el código
del kernel tarda (cada lectura del reloj avanza 100 ns y el hardware sigue, mientras los demás hilos del kernel esperan
el candado; `IODelay` igual), una GPU que ejecuta dibujos y copias en orden, un DPU que toma el plano en cada inicio de
frame si hay flush pendiente (con y sin lectura de `CTL_FLUSH`), el temporizador de 120 Hz del kernel y el hilo de la
cola. Los registros del modelo ven cada escritura. `sim.cpp` pone encima un window server que dibuja en una superficie
cuyo contador de uso está a 0 (copia de 1,5-4 ms), a veces envía parte del dibujo después del `SwapEnd`, y llama a
`SwapEnd`: **no es lo que hace CoreAnimation** (§3.10), así que sus ritmos no valen para el teléfono; sirve para las
invariantes del kernel con muchas mezclas de frames. El de CoreAnimation está en §6.4.

Comprueba en cada ejecución: que el plano nunca se toma a medias (en cada toma los 27 registros son el juego del ABL o el
escalado para la ventana que contienen, y un plano escalado apunta a una superficie del pool); que la geometría se
escribe sin flush pendiente (con lectura) o dentro de la ventana (sin ella); que la GPU nunca dibuja en una superficie
que el panel escanea ni se suelta una superficie que el panel aún puede leer; que ningún frame llega al panel antes de
terminar su dibujo; el orden; que todo frame se enseña o se cuenta como descartado; y las de 0340 (ninguna copia sobre
lo que el panel lee o sobre un frame en cola).

22 escenarios (dos, tres y cuatro superficies, y CoreAnimation que crea la tercera; régimen del teléfono, GPU saturada,
ligero, ráfagas; frames de CPU y de superficies fuera del pool mezclados; envíos después del `SwapEnd`; `CTL_FLUSH` sin
lectura; apagado y encendido en caliente; GPU colgada; flips tomados por los bits; copias solas para comparar) × 30
semillas × 600 frames: **todas las ejecuciones pasan**, con 0352 (`run-0352.log`) y con 0353 (`run-0353-old.log`, 400
frames). Mutaciones del texto del kernel (`mutate.py`): sin limpiar el hueco de la cola, flip anotado antes de esperar,
superficies soltadas sin flip tomado, valla de superficie ignorada, `CTL_FLUSH` ignorado al escribir el plano,
superficie en pantalla no retenida, ventana ignorada sin lectura: **las siete se detectan**, también con 0353
(`mutate-0353-old.log`) y con 0354 (`run-0354-old.log`: todas las ejecuciones pasan; `mutate-0354-old.log`). Quitar la
comprobación de plano escribible de `queueFlip` no se detecta y es correcto: `planeScaled`/`planeUnscaled` esperan igual
(cambia dónde se espera, no lo que se escribe).

Dos defectos de 0350 que encontró la simulación (corregidos en 0352):

1. `presentQueued()` rellenaba un hueco de la cola sin limpiarlo: una copia que caía donde había estado un frame de
   superficie heredaba `scan = true` (y su `surf`) y se enseñaba como tal: plano escalado sobre un flip buffer, frames
   desordenados, y una lectura de `gpuFence` de una superficie que quizá ya no existe.
2. `scanFrom()` anotaba el flip (contador, línea) **antes** de esperar un plano escribible: tras la espera la anotación
   tenía un refresco de retraso y, sin lectura de `CTL_FLUSH`, `flipTaken()` daba el flip por tomado antes de tiempo y
   soltaba una superficie que el panel aún leía. (`planeScaled()` hacía lo mismo desde `queueDrain()`.)

Y dos hechos del modelo que no son defectos: un envío que nombra la superficie **después** de que su frame ya está en
pantalla la rasga (el kernel no puede esperar algo que aún no existe; el diseño supone que el dibujo de un frame se
envía antes de su `SwapEnd`, como hace HakiosMetal, y `drawn after the SwapEnd` lo vigila); y el `queueDrain()` de 0340
suelta las superficies de un frame cuya copia aún no terminó tras 20 ms, lo que es inocuo porque lo que CoreAnimation
dibuje después va detrás de la copia en el mismo ring.

### 6.4 Simulación de CoreAnimation (`sim-scanout/sim-ca.cpp`)

El window server de `sim-ca.cpp` es el `IOMFBDisplay` de §3.10: anillo de tres páginas (siguiente 1, actual 0 al
empezar), `can_update_` en cada tick de su temporizador de 120 Hz (fase cualquiera, o 0,5 ms tras la toma del panel)
con las dos páginas tras la actual, la más vieja primero, recuperando sin preguntar las que no tienen frame o id y
preguntando las demás con `SwapWait(id, 0x80000000)`: la primera como `swap_wait_timeout` (cada 100 µs de tiempo
simulado, durante los cuales corren el hilo de la cola, el temporizador y el hardware, hasta 1 ms) y la segunda una
vez; el frame va al buffer libre dibujado más recientemente o a una superficie nueva (en el pool si hay hueco); CPU,
dibujo enviado a la GPU, `SwapBegin`/`SwapEnd` seguidos (lo visto en el teléfono), y la página se vuelve la actual.
Opciones: `idle()` cada N frames (`SwapWait(0, 2)` y borrado de los ids de todas las páginas), frames de dos capas,
envíos después del `SwapEnd`, el sysctl del scanout apagado y encendido, pool de dos huecos, dos superficies como
máximo, `SwapEnd` retenido hasta que su frame está en el panel. `SwapWait` llama al `swapWait()` extraído (o responde 0
al instante, como 0352).

Además de las invariantes del kernel de §6.3, con 0353 cada ejecución falla si la GPU dibuja en una superficie que el
panel puede estar leyendo, si un frame llega al panel antes de terminar su dibujo o fuera de orden, si el kernel copia
un frame por tener la superficie aún en uso, si el plano cambia de modo más de una vez en un régimen de una capa con
las tres superficies en el pool, o si una pregunta se responde 0 por llevar 1 s ocupada o una espera vence (salvo en
el escenario de la GPU colgada).

36 escenarios × 30 semillas × 30 s simulados: **todas las ejecuciones pasan** (`run-ca-0353.log`; las cifras de §3.11
salen de ahí). Mutaciones del texto de 0353 (`mutate-ca.py`, 6 semillas × 15 s de los escenarios de 0353;
`mutate-ca.log`): sin contar el frame en pantalla, sin contar los que se dejan, sin el flip pendiente en `swapShown`,
sin anotar el swap en el flip, sin `fScanShowSwap`, sin moverlo en `scanoutLeave`, sin la retención tras `idle()`, la
retención sin mirar qué hay en el panel, sin limpiar en `scanoutRetire`, sin la cola de scanout en `swapFree`, sondeo
que responde siempre 0, `swapShown` sin la cola, scanout sin exigir `SwapWait`: **las trece se detectan** (entre 6 y
90 ejecuciones fallidas cada una). La decimocuarta, sin `queueFlip()` antes de responder, no cambia nada medible: con
el hilo de la cola mirando cada 500 µs, solo hace la respuesta hasta una mirada más vieja.

**La vida del anillo (0354).** `sim-ca.cpp` modela además el pool de N huecos (las superficies del window server del
tamaño de la pantalla cogen hueco al crearse si lo hay; un hueco vuelve al liberarse la superficie: soltada por su
creador y por todo lo que la retenga en el kernel), los cambios de lo que pide el display (cada pocos segundos
CoreAnimation necesita superficies nuevas; las viejas se sueltan en cuanto quedan sin uso), los reinicios de
backboardd (todas sus superficies soltadas a la vez, sus páginas vacías, uno nuevo un segundo después) y superficies
del tamaño de la pantalla que no se presentan, retenidas unos segundos. La elección de `presentNow()` es la de 0354:
llama al `shownRecord()` extraído. Comprueba además, en cada frame, que el kernel manda un frame a la copia por una
superficie anotada solo si hay una superficie fuera del pool que el window server ha presentado y sigue viva, y que no
escanea ninguno mientras la haya; que en régimen (desde un segundo después de cada evento) el plano no cambia de modo;
que con ocho huecos se escanea al menos el 90 %; que todo frame de varias capas se enseña; y, con
`SIM_SRCXY_IGNORED=1`, que la ventana que toma el plano es la de la copia también en la lectura «el plano ignora
`SRC_XY`».

46 escenarios × 30 semillas × 30 s: **todas las ejecuciones pasan** con 0354 (`run-ca-0354.log`), también en la lectura
«el plano ignora `SRC_XY`» (`run-ca-0354-srcxy-ignored.log`, 20 semillas). Con el texto de 0353 de la serie (`v0353/`,
`fOffX` 20; `run-ca-official.log`): la vida del anillo reproduce lo del teléfono (§3.13); con «el plano ignora
`SRC_XY`», cada frame escaneado toma otra ventana que la copia (1 602 frames en una ejecución de 30 s,
`run-official-srcxy-ignored.log`); y `swapwait=0` con el scanout desgarra (277 dibujos sobre la superficie escaneada por
ejecución: lo que cierra el punto 6 de 0354).

Mutaciones de 0354 (`mutate-0354.py`: 6 semillas × 15 s, 45 s en los escenarios de la vida del anillo, en las dos
lecturas del hardware; `mutate-0354.log`): sin modo único, sin anotar la superficie rechazada, anotaciones que no
caducan, solo la primera anotación, recorte por `SRC_XY` como 0353, columnas por `SRC_XY`, filas dos veces (dirección
y `SRC_XY`), columnas dos veces, frames de varias capas tal cual, capa 0 nunca a pantalla completa, registro sin
reducir a la capa 0: **las once se detectan** (entre 5 y 12 ejecuciones fallidas cada una; las de columnas por
`SRC_XY` y las de dos veces, solo en la lectura en la que cambian algo). Las trece de 0353 se siguen detectando con
el texto de 0354.

Lo que el modelo no tiene: el coste de CPU de cambiar el plano y de la copia en el hilo de render (por eso, con 0352 y
scanout, da 55,4 frames/s y el teléfono 47,0 y 38,5), un límite de trabajo de GPU en vuelo en el driver (con la GPU
colgada, CoreAnimation llena la cola de la GPU sin freno salvo con 0353 y scanout, que lo frena a 4 frames/s), y la
fase real del temporizador de CoreAnimation. Reutiliza menos superficies que el teléfono con 0352 (16 % de los frames
frente a 53 %), en el mismo sentido.

## 7. Orden de prueba en el teléfono, qué mirar y cómo volver

Todo por SSH (`PATH=/var/jb/usr/bin:/var/jb/usr/sbin:$PATH`); el USB y SSH no dependen del display, así que una
pantalla negra o congelada se arregla por SSH. **Con 0350 sin 0352, no encender `kern.sweet_fb_scanout=1`** (§6.3,
defecto 1); **con 0352 sin 0353 tampoco**: CoreAnimation dibuja en la superficie que se escanea (§3.10); **con 0353
sin 0354, el scanout funciona hasta que el pool se llena** (horas de uso con reinicios de backboardd: la pantalla salta,
03 M22). Probar siempre por sysctl antes que con boot-arg (el cmdline del teléfono ya tiene 572 caracteres; por encima
de 575 el shim pierde `sweet_splash`). No reiniciar backboardd varias veces seguidas: deja SpringBoard en el modo seguro
del cargador de tweaks (barra roja; se sale tocando «Exit Safe Mode»).

1. **Diagnóstico (0349):** `sysctl -n kern.sweet_fb_scanout_diag kern.sweet_fb_latch kern.sweet_fb_regs`. Esperado y
   visto: «ready», `CTL_FLUSH` con los bits puestos tras casi cada escritura, VIG0 como en §1.4.
2. **0352:** `kern.sweet_fb_scanout_diag` dice «CTL_FLUSH read its bits back right after N of M flips: flips are taken
   by it» (visto con 0353: 34 987 de 34 992). Opcional e independiente: `sysctl -w kern.sweet_fb_flush_taken=1` con la
   copia de siempre; en `kern.sweet_fb_queue_diag`, `flips taken by time` sigue a 0, y en `kern.sweet_fb_diag` el cubo
   0 de `flip interval` no crece.
3. **`SwapWait` con la copia** (`kern.sweet_fb_swapwait` 1 al arrancar): `sysctl -n kern.sweet_fb_swapwait_diag`
   durante un deslizamiento. Esperado: `asked if the surfaces are free` crece uno o dos por frame con `busy` casi a 0
   (las copias liberan en el `SwapEnd`); `waited` pocas veces (`idle()`), `timed out 0`, `answered 0 after 1 s busy 0`.
   Con 0354, `SwapEnds held after a wait for every swap` no crece mientras se copia (con 0353 sí: en el teléfono, 78
   retenciones, 14 hasta los 50 ms).
4. **Solo el pool:** `sysctl -w kern.sweet_fb_scanout=2; killall -9 backboardd` (una vez). Mirar: `pool: 2 (o 3) of 8
   slots in use` y, con 0354, una línea por hueco, `slot N: surface S "CA Framebuffer" by backboardd, made … s ago,
   swapped K times, last … ms ago`; la pantalla igual que antes; en `kern.sweet_fb_diag`, `surface cleans` deja de
   crecer.
5. **Scanout:** `sysctl -w kern.sweet_fb_scanout=1` (con `kern.sweet_fb_swapwait` a 1 y las superficies ya en el
   pool). Mirar en `kern.sweet_fb_scanout_diag`: «plane now scaled»; con 0354, `showing 16,12 720x1600 of a surface
   (rows of 3072 bytes) from 0xe5…9040: 16,12 of it through the address, SRC_XY 0,0` (con 0353, `showing 13,12 … at
   0xe5…00000`); `frames` ≈ `flips` creciendo juntos; **`swapped again while on the panel or waiting` sin crecer**;
   `flushes not taken 0`; **`pool: 3 of 8 slots in use`**, con los tres huecos de `CA Framebuffer` presentándose
   (`last` de pocos ms); en la línea `0354:`, `kept now 0` y `frames copied for them` sin crecer; **`plane to scaled` y
   `to unscaled` sin crecer en régimen**. En `kern.sweet_fb_swapwait_diag`: `asked if the surfaces are free` con una
   parte `busy`, `longest busy` de milisegundos, `answered 0 after 1 s busy 0`; tras un reposo, `SwapEnds held after a
   wait for every swap` con `max` de decenas de ms y `timed out` sin crecer. En `kern.sweet_fb_regs` con 0354: VIG0
   +000=064002d0, **+008=00000000**, +00c=09600438, +010=0, **+014 = la base de un hueco + 0x9040** (0xe5009040,
   0xe5509040, 0xe5a09040…), +024=00000c00, +038=80000000, +108/+118/+128=064002d0; escalador +004 se lee 20034401 (se
   escribe a0034401: el bit 31 no se conserva), +010 a +01c=00155555, +020=02040204, +040/+044=064002d0,
   +048=09600438, +090 a +09c=0. Que la copia desaparece: el contador de copias de `kern.sweet_gpu_diag` deja de
   crecer, y con `kern.sweet_gpu_marks=1` desaparecen los ~4,15 ms por frame.
6. **El encuadre en el cristal (lo que tiene que ver el usuario):** con una pantalla quieta (la de bloqueo, con el
   reloj), alternar `kern.sweet_fb_scanout` entre 1 y 2 cada pocos segundos: **la imagen no se mueve ni cambia de
   tamaño** (con 0353 se mueve unos 1,3 mm en horizontal y 1,1 mm en vertical si el plano ignora `SRC_XY`, §3.14). La
   imagen entera queda 4 píxeles del panel (0,26 mm) a la izquierda respecto a 0353, en los dos modos, y el táctil con
   ella: tocar un icono pequeño o una tecla del teclado cae donde se ve. El reloj de la pantalla de bloqueo, centrado.
   Las capturas leen la IOSurface, no el panel: hace falta mirarlo (o una foto).
7. **La vida del anillo (0354):** con el scanout encendido, apagar y encender la pantalla varias veces, abrir y cerrar
   apps, y una vez (no más) `killall -9 backboardd`. Mirar en `kern.sweet_fb_scanout_diag`: los huecos en uso (`N of
   8`: tres en régimen, más en los cambios; `8 of 8` querría decir que el pool vuelve a quedarse corto, y entonces 0354
   copia sin alternar) y qué superficie hay en cada uno; `refused` sin crecer; la línea
   `0354:` (`seen` solo crece si el pool se queda corto, y entonces `kept now` vuelve a 0 cuando esas superficies
   mueren); `plane to scaled` y `to unscaled` crecen como mucho en uno o dos por cada cambio, nunca varias veces por
   segundo. En el log (`dmesg`), las líneas `SWEET FB: 0354: swap … of N layers`, si hay frames de varias capas: qué
   capas trae cada uno (si lo que traen importa, componerlas es lo siguiente). La pantalla no salta.
8. **Medir** (n ≥ 3, `tools/perf/homeswipe.sh`) con `kern.sweet_fb_scanout` 1 y 2 intercalados: buffers/s,
   commit→fin, ocupación de la GPU, `swap interval`, `flip interval`, `arrival to flip`, temperatura (03 M16, con 0353:
   60,1 y 48,1 buffers/s frente a 49,2, 41,4 y 43,0; commit→fin 14,2 y 15,7 ms frente a 31,6, 24,7 y 24,4).
9. **Volver:** `sysctl -w kern.sweet_fb_scanout=2` o `0` (al momento: el frame en pantalla se re-presenta por la copia
   y el plano vuelve al del ABL), `kern.sweet_fb_flush_taken=0` y, si hiciera falta, `kern.sweet_fb_swapwait=0` (con
   0354 también apaga el scanout). Las superficies siguen en el pool hasta que backboardd las cambia, y la copia
   funciona con ellas.

| Si falla… | Se ve | Qué mirar | Vuelta |
|---|---|---|---|
| El plano escalado está mal (recorte, escalador) | imagen negra, desplazada, de colores cambiados o basura, con el sistema vivo | `kern.sweet_fb_regs` frente a los valores del paso 5 | `kern.sweet_fb_scanout=2` |
| Los dos caminos siguen sin coincidir | la imagen salta al alternar 1 y 2 (paso 6) | `showing … SRC_XY` (0,0 con 0354), VIG0 +008 y +014 | `kern.sweet_fb_scanout=2` |
| El DPU no toma un flush del plano escalado | imagen congelada | `flushes not taken` | automático a los 100 ms; si el pipe queda colgado, `reboot` (o `kern.sweet_reboot_mode=2` y `reboot`) |
| CoreAnimation dibuja en una superficie en uso (el contrato de §3.10 no se cumple) | desgarro | `swapped again while on the panel or waiting`, `drawn after the SwapEnd`, `kern.sweet_fb_swapwait_diag` | `kern.sweet_fb_scanout=2` |
| CoreAnimation no crea una tercera superficie | menos frames por segundo, muchos `busy` | `pool`, `asked if the surfaces are free … busy`, `swap interval` | `kern.sweet_fb_scanout=2` |
| Una superficie del anillo queda fuera del pool | con 0353, el plano cambia de modo varias veces por segundo y la imagen salta; con 0354, todo por la copia mientras viva | `pool: N of 8`, `refused`, las líneas de los huecos, `0354: … kept now` | se pasa sola cuando backboardd cambia sus superficies; si no, `kern.sweet_fb_scanout=2` y un reinicio de backboardd |
| Algo usa la memoria de los huecos nuevos (0xe6400000-0xe7800000) | basura o fallos en la imagen de las superficies de los huecos 4 a 7 | el censo de huecos y la dirección de `showing` | `kern.sweet_fb_scanout=0` y un reinicio de backboardd (las superficies salen del pool) |
| Un frame de varias capas pierde algo | un elemento que falta en algunos frames | `SWEET FB: 0354: swap … of N layers` en el log; `frames of several layers shown by their layer 0` | ninguna en caliente: componer esas capas es el paso siguiente |
| `SwapWait` dice ocupado de más (contabilidad de 0353) | la interfaz se congela o va a saltos de 1 s | `answered 0 after 1 s busy` creciendo; en `swaps:`, ids que no avanzan | `kern.sweet_fb_swapwait=0` |
| Esperas largas en `SwapEnd` o en `idle()` | tirón al empezar a moverse tras un reposo | `SwapEnds held … max` (hasta 250 ms con 0354), `timed out`, `waited … max` | `kern.sweet_fb_scanout=2` (con la copia no se retiene) |
| El criterio del pool no coge las superficies de pantalla | nada cambia | `not from the pool` creciendo | ver `SWEET SURF: screen-sized surface …` (0349) |
| Pánico en código nuevo | reinicio | ring | el arranque siguiente viene con `scanout=0` si se activó por sysctl |

## 8. Riesgos y lo no verificado

- **No verificado en el teléfono:** que el plano no aplique `SRC_XY` (lo dice una observación del usuario, §3.14 [H];
  0354 no depende de ello); que nadie use 0xe6400000-0xe7800000, los cuatro huecos que añade 0354 (ningún código del
  port, ninguna región fija del DT; 0xe5000000-0xe6400000 se usa desde 0350 sin fallos); qué cambia el anillo de
  CoreAnimation en el teléfono (§3.13 [H]) y que ocho huecos basten (la cuenta del peor caso da siete; el censo de
  0354 lo dirá); las propiedades que distinguen sus superficies de pantalla de las de SpringBoard (0349 las registra).
- **Verificado en el teléfono:** el plano del ABL, la versión del escalador, la lectura de `CTL_FLUSH` y el punto de
  toma (n = 1 arranque; §1.4, §3.6); que el DPU toma los flips del plano escalado sobre el pool sin flushes perdidos ni
  cuelgues; que con 0352 CoreAnimation se queda con dos superficies (03 M12) y con 0353 hace la tercera, la pone en el
  pool y el scanout rinde (03 M16-M17); que el pool de cuatro huecos se llena con horas de uso (03 M22). n = 1 arranque
  en cada caso. La imagen escaneada se ha visto (03 M16-M22), pero nadie ha comparado su encuadre con el de la copia
  más allá de los saltos de M22.
- **El contrato de `SwapWait`:** lo que hace CoreAnimation con cada respuesta está leído [O, §3.10]; el significado de
  cada bit de las banderas se deduce de dónde y cómo se usa [H], y el lado del kernel de Apple (`AppleMobileDispH10P`)
  no se ha leído (no hay kernelcache de 20H392 aquí). Si un bit significara otra cosa, los peores casos están acotados:
  una pregunta ocupada se responde 0 al pasar 1 s, una espera bloqueante vence a los 100 ms, y
  `kern.sweet_fb_swapwait=0` vuelve a lo de antes.
- **Las copias en el mismo ring:** que una copia en cola no retenga su superficie (en `swapFree()` y en
  `scanoutBusy()`) se apoya en que la copia del kernel y lo que CoreAnimation dibuja después van por el único ring de la
  GPU, en orden (0201; 03 M7 lo midió: ningún frame pisado con la cola). Si algún día hubiera dos rings, las copias en
  cola tendrían que retener su superficie (`kern.sweet_fb_swapwait=2` lo hace para todas las copias).
- **La fase del temporizador de CoreAnimation:** con la de 0353 y una fase cualquiera, CoreAnimation se salta 2,3
  ticks por segundo en el modelo; alineado con la toma del panel, 0,5 (§3.11). De qué se alimenta
  `IOMFBDisplay::timing_reference()`, con la que alinea su fase, está por leer.
- **Calidad:** bilineal sin tabla, como la copia de hoy. Con tablas haría falta el contenido que da el HAL cerrado.
- **Medio píxel:** con 0350-0353 el origen horizontal del scanout es 13 en vez de 13,33; con 0354 el origen es entero
  en los dos caminos, (16, 12). La copia conserva una fracción de fila en cada una de sus dos pasadas intercaladas (el
  centrado de sus filas), como antes.
- **Memoria fija:** 40 MiB del banco bajo con 0354, en uso solo con superficies en el pool.
- **Frames de varias capas:** con 0354 se ve solo su capa 0 (si es la de pantalla); lo que traigan las demás no se ve
  en esos frames (con la copia 2x de 0353 tampoco se ve). Las ocho primeras van al log con lo que trae cada capa.
- **Anotaciones por id y puntero:** una superficie anotada (§3.12) se reconoce por su id y su puntero sin retenerla. Si
  se liberara y otra nueva tomara la misma dirección y el mismo id (los ids recorren 4095 antes de repetirse), el modo
  único duraría la vida de la nueva: más copias, nunca un acceso a memoria liberada (el puntero no se desreferencia).
- **La retención de hasta 250 ms:** un primer frame pesado tras un reposo (abrir el Centro de Control tras un reinicio:
  68,8 ms de codificación y hasta 34,5 ms de GPU, 03 M23) retiene su `SwapEnd` lo que tarde en llegar al panel; con 0353
  se suelta a los 50 ms y puede dibujarse en la superficie del panel.
- **El táctil y la imagen se mueven juntos 4 píxeles del panel** a la izquierda respecto a 0353 (`fOffX` 24 en los dos);
  si alguna calibración del táctil dependiera del 20, cambiaría con ella.

## Material

- `~/sapphire-angel/research/metal/display/`: `parches-nuevos/` (0354); `work/xnu` (mis 0347/0348 sobre la serie a
  0342, con un commit por parche), `work/xnu-0350` (worktree del anterior: la serie oficial a 0350, 0352, 0351, la
  revisión de 0353 y el trabajo de 0354 sobre ella), `work/xnu-0354` (worktree: la serie oficial 0343-0353 de
  `xnu/patches/` en un commit y 0354 en otro), `work/headers/` (descripciones), `work/obsoletos/` (0347/0348 con mi
  numeración y los arreglos, la copia de 0352 igual a la integrada y la revisión de 0353 que no se integró),
  `work/mkpatch.sh`, `work/verif/` (`check-0352.sh`, `check-0353.sh`, `check-0354.sh` y sus `.log`, `check-all.sh`,
  `inject.py` e `inject-0353.log`, `warn.sh`, `warn-0354.sh` y `warn-0353.log`, `stubs/`, `arnes/` con `arnes.log` y
  `arnes-sde.log`, `encuadre/` con `encuadre.cpp`, `extract.py` y `encuadre-0354.log`, `sim-scanout/` con `simcore.h`,
  `sim.cpp`, `sim-ca.cpp`, `extract.py`, `mutate.py`, `mutate-ca.py`, `mutate-0354.py`, `run-0352.log`,
  `run-0353-old.log`, `run-0354-old.log`, `run-ca-0353.log`, `run-ca-0354.log`, `run-ca-0354-srcxy-ignored.log`,
  `mutate.log`, `mutate-0353-old.log`, `mutate-0354-old.log`, `mutate-ca.log`, `mutate-0354.log`, y `v0353/`: el
  modelo de CoreAnimation con el texto de 0353 de la serie, `run-ca-official.log` y
  `run-official-srcxy-ignored.log`), `ref/` (Linux v6.12, SDE KAMORTA, SDM; `dsc-20H392/`: el `__TEXT` de QuartzCore
  leído del caché dyld del teléfono, su cabecera, `dis.py` y `qc.dis.txt`, el desensamblado anotado), `telefono/`
  (lecturas del teléfono: sysctl de 0336/0340, volcados de 0349, `regs-scan.txt`/`regs-copia.txt` y
  `diag-scan.txt`/`diag-copia.txt` de 0353 en los dos modos, `surfinfo-20261114-1.txt`, el ring de `ring-20261114/`),
  `tools/surfinfo.c` (lista las superficies de un tamaño con sus valores).
- El desensamblado con nombres de QuartzCore que cita §3.10: `~/sapphire-angel/research/metal/ios-graficos/ios-20H392/
  desensamblado/QuartzCore.named.s.gz` (y sus símbolos en `simbolos/`).
