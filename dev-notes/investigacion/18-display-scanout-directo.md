# 18 — Display: scanout directo de la superficie de iOS con el escalador del DPU (2026-11-14)

- **Autor:** agente Claude Opus 5.5, esfuerzo máximo.
- **Alcance:** la presentación del kernel frente al DPU (MDSS) del SM6225: qué hace hoy el port con el plano, diseño
  del scanout directo de la superficie de 750×1624 por el VIG0 con su escalador QSEED3LITE, y tres parches de la serie:
  **0349** (diagnóstico del DPU, solo lectura), **0350** (scanout directo, apagado por defecto) y **0352** (arreglos de
  0350 que encontró la simulación y flip tomado por `CTL_FLUSH`, apagado por defecto).
- **Estado:** 0349 y 0350 en `xnu/patches/` y en el kernel del teléfono (CI 43632182225, imagen
  `boot_a-0350-vco2-820.img`); 0349 leído en el teléfono (§1.4). 0352 en `xnu/patches/` (aplica en orden sobre 0351;
  CI 43635044868). **El scanout no se ha encendido todavía en el teléfono.**

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
2. **La copia de hoy no estira: recorta y escala ×1,5 uniforme** la ventana de 720×1600 en (13,33; 12) de la
   superficie de 750×1624 (F2032-2047): la ventana del panel en el lienzo 3x de 1125×2436, a 2/3. Las razones 1,44 y
   1,478 serían las de estirar la superficie entera, que nadie hace. El scanout repite la misma ventana y el mismo
   factor; el táctil no cambia. Esa copia cuesta 4,15 ms de GPU por frame de media (03 M11): un tercio del tiempo de GPU
   del frame, en el mismo ring que el render, con la GPU como límite.
3. **El plano recibe direcciones físicas de 32 bits y el stream del display (SID 0x420) no se traduce** (inferido: el
   port nunca programa ese SID y el panel enseña 0x5c000000 y el pool bajo 0xe2000000). El pool del scanout va por
   debajo de 4 GiB, junto a los flip buffers.
4. **Diseño:** las superficies de pantalla de backboardd salen de un pool físico propio (4 huecos de 5 MiB en
   0xe5000000), mapeadas *write-combined* en todas partes (ni la GPU ni el DPU necesitan mantenimiento de caché), y el
   VIG0 las escanea con el QSEED3LITE configurado como Linux (bilineal, sin tablas): 27 registros idénticos a los de
   Linux y del driver de stock para los mismos tamaños (§6.2). Los frames entran en la cola de 0340 junto a las copias;
   uno que no encaja va por la copia, en orden. La superficie queda «en uso» hasta que el DPU ha tomado el flip
   siguiente: CoreAnimation necesita una tercera para no esperar (§3.9).
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
  ninguna región fija por encima de 0x66000000 (`reserved-memory`). El pool del scanout va ahí (20 MiB).

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

Cuenta del pool: 750×1624 con filas de 3072 bytes son 4 988 928 bytes (4 997 120 redondeados a página de 16 KiB);
huecos de 5 MiB. Cuatro huecos (dos superficies, la tercera que CoreAnimation crea si las dos están en uso, y una de
margen) son 20 MiB en 0xe5000000-0xe6400000. El pool de los flip buffers (48 MB) está casi lleno (página del DSI, dos
flip buffers, la sombra de consola y el tercer flip buffer de 0340: 41,7 MB).

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

No se estira ni se ponen bandas: se escanea la misma ventana que copia la GPU, `SRC_XY = (13, 12)`,
`SRC_SIZE = 720×1600`, salida 1080×2400 en (0, 0), ×1,5 en los dos ejes. La única diferencia es 1/3 de píxel 2x (media
columna del panel) en el origen horizontal: `SRC_XY` es entero y la fase inicial se deja a 0, como Linux. Con
`kern.sweet_fb_rscale` (0321) la ventana se recalcula igual que en la copia (`sweet_scan_window`) y el factor sube
(400 ‰: ×3,75; el QSEED3 admite hasta ×20).

### 3.5 QSEED3LITE: registros y valores

Para 720×1600 → 1080×2400 (`sweet_plane_scaled_regs`; idéntico a Linux y al driver de stock, §6.2):

| Registro (VIG0 +) | Valor | Origen |
|---|---|---|
| `SRC_SIZE` 0x000 | 0x064002d0 (1600<<16 \| 720) | `setup_rects` |
| `SRC_XY` 0x008 | 0x000c000d (12<<16 \| 13) | `setup_rects` |
| `OUT_SIZE` 0x00c, `OUT_XY` 0x010 | 0x09600438, 0 (los del ABL) | `setup_rects` |
| `SW_PIX_EXT_C0/C1C2/C3` LR, TB, REQ 0x100-0x128 | 0, 0, 0x064002d0 | `setup_pe_config` |
| `PHASE_INIT_Y_H/Y_V/UV_H/UV_V` 0xa90-0xa9c | 0 | `dpu_hw_setup_scaler3` |
| `PHASE_STEP_Y_H/Y_V/UV_H/UV_V` 0xa10-0xa1c | 0x155555 (1 398 101 = 2²¹·720/1080 = 2²¹·1600/2400) | `mult_frac` |
| `PRELOAD` 0xa20 | 0x02040204 (H 4, V 2) | versión ≥ 3.0 |
| `SRC_SIZE_Y_RGB_A` 0xa40, `SRC_SIZE_UV` 0xa44 | 0x064002d0 | |
| `DST_SIZE` 0xa48 | 0x09600438 | |
| `OP_MODE` 0xa04 | 0xa0034401 (con el alfa del formato del ABL) | enable, BIL, blend, 8 bits, alfa bilineal |
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
- **Vida de la superficie:** en uso (contador de IOSurface) desde su `SwapEnd` hasta que el DPU ha tomado el flip de un
  frame posterior; entonces se suelta (`sweet_hold` y `release`).
- **Frames mezclados:** uno que no encaja (varias capas, superficie fuera del pool, una superficie que el panel aún
  puede leer) va por la copia, a la misma cola, en orden. El flip de un flip buffer vuelve a poner el plano del ABL con
  la misma regla de §3.6.
- **Profundidad y contrapresión:** las de 0340 (`kern.sweet_fb_queue_depth`, `_hold_ms`).
- **Pantalla apagada y encendida:** el tick vuelve al framebuffer de arranque (con `fPresentLock` desde 0350), lo que
  restaura el plano; la superficie se suelta cuando el DPU lo toma.

### 3.8 Coste esperado

- GPU: desaparecen las dos medias pasadas de la copia, 4,15 ms por frame de media (03 M11), y sus `CP_WAIT_FOR_IDLE`;
  el render del frame siguiente empieza ese tiempo antes.
- CPU: desaparecen los `dc cvac` de 5 MB en `SwapEnd` (§1.6) y los `dc civac` del submit en el modo 0 de 0339.
- Ancho de banda de scanout: el DPU lee 720×1600×4 = 4,6 MB por refresco en vez de 10,4 MB (0,55 frente a 1,24 GB/s).
- Memoria: 20 MiB de pool fijo; los flip buffers se quedan (son la ruta de vuelta).

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
5. «Notificación»: CoreAnimation no pide notificaciones de vsync (09 §2.4); lo que recibe es la superficie de vuelta:
   la del frame anterior deja de estar en uso cuando el DPU ha tomado este flip (≤ 0,5 ms después, en la siguiente
   mirada del hilo).

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
serializan. El modelo (§6.3) lo cuantifica en el régimen del teléfono: 17,5 frames/s con dos superficies frente a 30
con tres o cuando CoreAnimation crea la tercera; con la GPU como límite, 19 frente a 28,2. CoreAnimation crea otra
superficie cuando todas las que tiene están en uso (lo hacía con la retención de topaz: F1189-1197 a 0342); el pool
tiene cuatro huecos. Lo dice `kern.sweet_fb_scanout_diag` (`pool: N of 4 slots in use, M surfaces made`) y, si no
crea la tercera, crecen `swaps that waited` y el `swap interval` de 0336.

## 4. Los parches

En `xnu/patches/`, numerados por el coordinador: 0349 y 0350 (escritos como 0347 y 0348, integrados tal cual) y 0352
(incremental, sobre la serie con 0343-0351). La copia de trabajo de 0352 y las versiones descartadas están en
`~/sapphire-angel/research/metal/display/` (`parches-nuevos/`, `work/obsoletos/`).

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

## 6. Verificación

Herramientas en `~/sapphire-angel/research/metal/display/work/verif/`.

### 6.1 Aplicación y compilación

- `check-0352.sh`: la serie oficial 0343-0350 de `xnu/patches/` sobre el árbol a 0342 y después 0352, con y sin el
  0351 de otro agente delante: **todos aplican en orden** con `git apply --check`; `clang++ -fsyntax-only` con los
  stubs de `kernel-gpu/verificacion/`: **0 errores** en los tres archivos.
- `inject.py`: un identificador sin declarar al principio de cada función nueva o cambiada: **31 de 31** (0349/0350) y
  **11 de 11** (0352) señalados: todo el código nuevo se compila de verdad.
- `warn.sh` (`-Weverything` con la lista `-Wno` del kernel): en las líneas añadidas solo salen los avisos de las macros
  `SYSCTL_*` que ya da el código vecino.

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

### 6.3 Simulación de la cola con frames de superficie (`sim-scanout/`)

`extract.py` corta del `SweetFramebuffer.cpp` con 0352, tal cual (solo las barreras `dsb` pasan a comentario), los
globales del scanout, `scanFrom`/`flushNote`/`flipNote` y todo desde `queueOn()` hasta el user client. `sim.cpp` los
ejecuta contra un modelo: reloj virtual en el que el código del kernel tarda (cada lectura del reloj avanza 100 ns y el
hardware sigue, mientras los demás hilos del kernel esperan el candado; `IODelay` igual), una GPU que ejecuta dibujos y
copias en orden (copia de 1,5-4 ms), un DPU que toma el plano en cada inicio de frame si hay flush pendiente (con y sin
lectura de `CTL_FLUSH`), el temporizador de 120 Hz, el hilo de la cola y un CoreAnimation que dibuja en superficies
libres, a veces envía parte del dibujo después del `SwapEnd`, y llama a `SwapEnd`. Los registros del modelo ven cada
escritura.

Comprueba en cada ejecución: que el plano nunca se toma a medias (en cada toma los 27 registros son el juego del ABL o el
escalado para la ventana que contienen, y un plano escalado apunta a una superficie del pool); que la geometría se
escribe sin flush pendiente (con lectura) o dentro de la ventana (sin ella); que la GPU nunca dibuja en una superficie
que el panel escanea ni se suelta una superficie que el panel aún puede leer; que ningún frame llega al panel antes de
terminar su dibujo; el orden; que todo frame se enseña o se cuenta como descartado; y las de 0340 (ninguna copia sobre
lo que el panel lee o sobre un frame en cola).

22 escenarios (dos, tres y cuatro superficies, y CoreAnimation que crea la tercera; régimen del teléfono, GPU
saturada, ligero, ráfagas; frames de CPU y de superficies fuera del pool mezclados; envíos después del `SwapEnd`;
`CTL_FLUSH` sin lectura; apagado y encendido en caliente; GPU colgada; flips tomados por los bits; copias solas para
comparar) × 30 semillas × 600 frames: **todas las ejecuciones pasan** (`run-0352.log`). Mutaciones del texto del kernel
(`mutate.py`): sin limpiar el hueco de la cola, flip anotado antes de esperar, superficies soltadas sin flip tomado,
valla de superficie ignorada, `CTL_FLUSH` ignorado al escribir el plano, superficie en pantalla no retenida, ventana
ignorada sin lectura: **las siete se detectan**. Quitar la comprobación de plano escribible de `queueFlip` no se
detecta y es correcto: `planeScaled`/`planeUnscaled` esperan igual (cambia dónde se espera, no lo que se escribe).

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

Cifras del modelo (no del teléfono; la copia del modelo cuesta 1,5-4 ms, la real 4,15): en el régimen del teléfono
(CPU 25-40 ms, GPU 14-24 ms), `SwapEnd` → panel 23,6 ms con scanout y tres superficies frente a 26,2 ms con copias, al
mismo ritmo (lo limita la CPU); con la GPU saturada (25-45 ms), 28,2 frames/s y 57 ms frente a 26,2 frames/s y 100 ms.

## 7. Orden de prueba en el teléfono, qué mirar y cómo volver

Todo por SSH (`PATH=/var/jb/usr/bin:/var/jb/usr/sbin:$PATH`); el USB y SSH no dependen del display, así que una
pantalla negra o congelada se arregla por SSH. **Con 0350 sin 0352, no encender `kern.sweet_fb_scanout=1`** (§6.3,
defecto 1). Probar siempre por sysctl antes que con boot-arg (el cmdline del teléfono ya tiene 572 caracteres; por
encima de 575 el shim pierde `sweet_splash`).

1. **Diagnóstico (0349; ya disponible con 0350):**
   `sysctl -n kern.sweet_fb_scanout_diag kern.sweet_fb_latch kern.sweet_fb_regs`. Esperado y visto: «ready», `CTL_FLUSH`
   con los bits puestos tras casi cada escritura, VIG0 como en §1.4.
2. **Kernel con 0352, sin tocar nada:** `kern.sweet_fb_scanout_diag` dice «CTL_FLUSH read its bits back right after N
   of M flips: flips are taken by the frame counter (kern.sweet_fb_flush_taken 0)». Opcional e independiente:
   `sysctl -w kern.sweet_fb_flush_taken=1` con la copia de siempre; en `kern.sweet_fb_queue_diag`, `flips taken by
   time` sigue a 0, y en `kern.sweet_fb_diag` el cubo 0 de `flip interval` no crece.
3. **Solo el pool:** `sysctl -w kern.sweet_fb_scanout=2; killall -9 backboardd` (una vez: reinicios seguidos dejan
   SpringBoard en el modo seguro del cargador de tweaks, barra roja, del que se sale tocando «Exit Safe Mode»).
   Mirar: `pool: 2 (o 3) of 4 slots in use, N surfaces made in it` y, en el log, `SWEET SURF: scanout pool: surface …
   in a slot`; la pantalla igual que antes; en `kern.sweet_fb_diag`, `surface cleans` deja de crecer.
4. **Scanout:** `sysctl -w kern.sweet_fb_scanout=1` (sin reiniciar nada: las superficies ya están en el pool). Mirar
   en `kern.sweet_fb_scanout_diag`: «plane now scaled», `showing 13,12 720x1600 of a surface (rows of 3072 bytes) at
   0xe5…`, `frames` ≈ `flips` creciendo juntos, `copied instead` pequeño (frames de varias capas), `swapped again while
   on the panel or waiting 0`, `flushes not taken 0`, `pool` con la tercera superficie. En `kern.sweet_fb_regs`, VIG0
   +000=064002d0, +008=000c000d, +00c=09600438, +010=0, +014 entre 0xe5000000 y 0xe63fffff, +024=00000c00,
   +038=80000000, +108/+118/+128=064002d0; escalador +004=a0034401, +010 a +01c=00155555, +020=02040204,
   +040/+044=064002d0, +048=09600438, +090 a +09c=0. Que la copia desaparece: el contador de copias de
   `kern.sweet_gpu_diag` deja de crecer, y con `kern.sweet_gpu_marks=1` desaparecen los ~4,15 ms por frame.
5. **Encuadre en el cristal:** ningún registro dice si el hardware respeta `SRC_XY` como Linux espera, y las capturas
   leen la IOSurface, no el panel. Una mirada (o una foto) basta: en una pantalla quieta, alternar
   `kern.sweet_fb_scanout` entre 1 y 0 cada pocos segundos; la imagen no debe moverse ni cambiar de tamaño (solo media
   columna de diferencia y el filtro bilineal del DPU en vez del de la GPU).
6. **Medir** (n ≥ 3, `tools/perf/homeswipe.sh`) con 1 y con 0, cambiando el sysctl en caliente: buffers/s,
   commit→fin, ocupación de la GPU, `swap interval`, `flip interval`, `arrival to flip`, temperatura.
7. **Volver:** `sysctl -w kern.sweet_fb_scanout=0` (al momento: el frame en pantalla se re-presenta por la copia y el
   plano vuelve al del ABL) y `kern.sweet_fb_flush_taken=0`. Las superficies siguen en el pool hasta el siguiente
   reinicio de backboardd, y la copia funciona con ellas.

| Si falla… | Se ve | Qué mirar | Vuelta |
|---|---|---|---|
| El plano escalado está mal (recorte, escalador) | imagen negra, desplazada, de colores cambiados o basura, con el sistema vivo | `kern.sweet_fb_regs` frente a los valores del paso 4 | `kern.sweet_fb_scanout=0` |
| El DPU no toma un flush del plano escalado | imagen congelada | `flushes not taken` | automático a los 100 ms; si el pipe queda colgado, `reboot` (o `kern.sweet_reboot_mode=2` y `reboot`) |
| CoreAnimation dibuja en una superficie en uso | desgarro | `swapped again while on the panel or waiting`, `drawn after the SwapEnd` | `kern.sweet_fb_scanout=0` |
| CoreAnimation no crea una tercera superficie | menos frames por segundo | `swaps that waited`, `swap interval`, `pool` | `kern.sweet_fb_scanout=0` |
| El criterio del pool no coge las superficies de pantalla | nada cambia | `not from the pool` creciendo | ver `SWEET SURF: screen-sized surface …` (0349) |
| Pánico en código nuevo | reinicio | ring | el arranque siguiente viene con `scanout=0` si se activó por sysctl |

## 8. Riesgos y lo no verificado

- **No verificado en el teléfono:** que `SRC_XY` recorte una fuente RGB lineal (Linux lo usa así; paso 5); que el SID
  0x420 alcance 0xe5000000 como alcanza 0xe2000000; que nadie use 0xe5000000-0xe6400000 (ningún código del port,
  ninguna región fija del DT); cómo responde CoreAnimation a superficies retenidas hasta el flip siguiente (si crea la
  tercera); las propiedades que distinguen sus superficies de pantalla de las de SpringBoard (0349 las registra).
- **Verificado en el teléfono (n = 1 arranque):** el plano del ABL, la versión del escalador, la lectura de `CTL_FLUSH`
  y el punto de toma (§1.4, §3.6).
- **Calidad:** bilineal sin tabla, como la copia de hoy. Con tablas haría falta el contenido que da el HAL cerrado.
- **Medio píxel:** el origen horizontal es 13 en vez de 13,33 (fase inicial 0, como Linux).
- **Memoria fija:** 20 MiB del banco bajo, en uso solo con superficies en el pool.

## Material

- `~/sapphire-angel/research/metal/display/`: `parches-nuevos/0352-…` (la copia de trabajo de 0352); `work/xnu` (mis
  0347/0348 sobre la serie a 0342, con un commit por parche), `work/xnu-0350` (la serie oficial a 0350 más 0352),
  `work/headers/` (descripciones), `work/obsoletos/` (0347/0348 con mi numeración y los arreglos), `work/mkpatch.sh`,
  `work/verif/` (`check-0352.sh`, `check-all.sh`, `inject.py`, `warn.sh`, `stubs/`, `arnes/` con `arnes.log` y
  `arnes-sde.log`, `sim-scanout/` con `run-0352.log` y `mutate.log`), `ref/` (Linux v6.12, SDE KAMORTA, SDM),
  `telefono/` (lecturas del teléfono: sysctl de 0336/0340 y volcados de 0349).
