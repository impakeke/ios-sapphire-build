# 18 — Display: scanout directo de la superficie de iOS con el escalador del DPU (2026-11-14)

- **Autor:** agente Claude Opus 5.5, esfuerzo máximo.
- **Alcance:** la presentación del kernel frente al DPU (MDSS) del SM6225: qué hace hoy el port con el plano, diseño
  del scanout directo de la superficie de 750×1624 por el VIG0 con su escalador QSEED3LITE, y dos parches al final de
  la serie: **0347** (diagnóstico, solo lectura) y **0348** (scanout directo, apagado por defecto).
- **Estado:** parches escritos y verificados en la Mac (§6). **Sin compilar en CI y sin ejecutar en el teléfono.**
- **Parches:** `~/sapphire-angel/research/metal/display/parches-nuevos/` (fuera de `xnu/patches/`; los integra el
  coordinador). **Colisión de números:** el agente de relojes tiene también un `0347-sapphire-gpu-ddr-vote` y un
  `0348-sapphire-gpu-hwcg` (`relojes/parches-nuevos/`). Los dos juegos aplican en cualquier orden y compilan juntos
  (§6.1): basta renumerar uno de los dos.

## Convenciones

`F`, `S` y `G` son líneas de `SweetFramebuffer.cpp`, `SweetSurface.cpp` y `SapphireGpu.cpp` del árbol **a 0342**
(3118, 1539 y 5278 líneas; sha256 `b8fee873…`, `b3b6c97d…`, `83dc20e2…`), reconstruido aplicando 0339-0342 de
`xnu/patches/` sobre `relojes/xnu-serie` (serie a 0338): coincide byte a byte con `relojes/xnu-0342`. No son las
líneas de 09 ni de 15. Las funciones nuevas de 0347/0348 se citan por nombre.

Fuentes primarias, fijadas en `~/sapphire-angel/research/metal/display/ref/`:

| Sigla | Qué | Versión |
|---|---|---|
| Linux | `drivers/gpu/drm/msm/disp/dpu1`, `msm_mdss.c`, `sm6115.dtsi` | v6.12, `adc218676eef` |
| SDE | driver de display de Qualcomm para la familia de este SoC (`msm/sde`) | CodeLinaro `display-drivers`, `LA.UM.9.15.r1-08400-KAMORTA.QSSI14.0`, `119a051bc133` |
| SDM | HAL de display de Qualcomm (userspace, la parte abierta) | `LineageOS/android_hardware_qcom_display` `fd1cfe095f3c` |
| DT | árbol del teléfono, nodo `mdss_mdp` | `relojes/dtb/merged-khaje24a-sapphire.dts:15209-15319` |

KAMORTA es la familia bengal/khaje (SM4250/SM6115/SM6225, kernel 4.19); el Android del teléfono es de kernel 5.15, cuyo
`display-drivers` no está publicado para khaje. La parte del escalador (`sde_hw_util.c`, `sde_plane.c`) es la misma en
las dos ramas que se han mirado.

## Resultado en breve

1. **El kernel no configura el display: lo deja el bootloader** (continuous splash: relojes, DSI, panel, DSC, INTF1,
   PP0, LM0, CTL0 y el plano VIG0 sobre 0x5c000000). Del DPU el port solo escribe, en cada flip, `SSPP_SRC0_ADDR`,
   `SSPP_SRC_YSTRIDE0` y `CTL_FLUSH = 0x20001` (F1375-1378), y una vez `INTF_FRAME_LINE_COUNT_EN` (F754). Usa un solo
   plano (VIG0); el DMA0 ni se mapea. El escalador no se ha tocado nunca.
2. **La copia de hoy no estira: recorta y escala ×1,5 uniforme.** Copia la ventana de 720×1600 en (13,33; 12) de la
   superficie de 750×1624 al panel de 1080×2400 (F2044-2047: es la ventana del panel en el lienzo 3x de 1125×2436,
   a 2/3). Las razones 1,44 y 1,478 serían las de estirar la superficie entera, que nadie hace. El scanout repite
   exactamente la misma ventana y el mismo factor; el táctil no cambia.
3. **El plano recibe direcciones físicas de 32 bits y el stream del display (SID 0x420) no se traduce:** el port
   nunca programa ese SID y el panel muestra lo que hay en 0x5c000000 y en el pool bajo 0xe2000000. Inferido, no leído
   de registros del SMMU (§1.5). El pool del scanout va por debajo de 4 GiB, junto a los flip buffers.
4. **Diseño elegido:** las superficies de pantalla de backboardd salen de un pool físico propio (4 huecos de 5 MiB en
   0xe5000000), mapeadas *write-combined* en todas partes (sin mantenimiento de caché ni para la GPU ni para el DPU), y
   el VIG0 las escanea con el QSEED3LITE configurado como Linux (bilineal, sin tablas). Los frames entran en la cola de
   0340 junto a los de copia; un frame que no encaja va por la copia, en orden. La superficie queda «en uso» hasta que
   el DPU ha tomado el flip siguiente. Se descartan mapear la superficie en el SMMU del display (toca la SMMU que
   comparten UFS y USB) y que el driver Metal dibuje en otro buffer (§3.1).
5. **Las tablas (LUT) del QSEED3LITE no salen del kernel en el driver de stock:** las da el HAL de display de userspace
   como propiedad de plano (`lut_sep`), desde una extensión cerrada de Qualcomm; sin ellas, tanto SDE como Linux
   programan bilineal sin tabla (`lut_flag = 0`). 0348 hace eso.
6. **Escribir el plano a medias es el riesgo real** (pantalla negra o basura un frame, o el pipe atascado): los
   registros escritos mientras hay un flush pendiente se toman con él. 0348 solo reescribe el plano con `CTL_FLUSH`
   limpio y el barrido lejos del inicio de frame; 0347 mide antes si `CTL_FLUSH` se lee como Linux lo usa.
7. **Lo que se quita:** la copia escalada de la GPU (dos medias pasadas, ~20 MB por frame, en el ring detrás del
   render), los `dc cvac` de la superficie en `SwapEnd` (en este arranque, 1963 de 2020 presentaciones, 1,54 ms cada
   uno, §1.7) y la mitad del ancho de banda de scanout (720 de ancho en vez de 1080: 0,55 frente a 1,24 GB/s a 120 Hz).

## 1. Auditoría: qué hace hoy el port con el DPU

### 1.1 Quién configura qué

- **El ABL deja el display encendido** (continuous splash): el arranque del kernel lee el plano tal cual
  (`fBootSrc = fVig0[0x14/4]`, `fBootStride = fVig0[0x24/4]`, F760-761) y el log de cuatro arranques guardados
  (`ring-E5`, `ring-R1`, `ring-E2R1`, `ring-panic2`, en `~/sapphire-angel/backups/`) dice siempre lo mismo:
  `MDP VIG0 src 0x5c000000 stride 4320 (boot)` y `INTF1: te_en 0x1 config 0x80800000 hsync 0x2440010
  vsync_period 0x158600 hctl 0x18f0028 vstart 0x1b30 vend 0x1558af fmt 0x2100`. 0x5c000000 es el `splash_region`
  del DT (`reserved-memory`, 15 MB).
- El kernel mapea VIG0 (0x5e05000), CTL0 (0x5e02000), DSI0 (0x5e94000) e INTF1 (página 0x5e6b000, bloque en +0x800)
  con `ml_io_map` (F686-688, F751). No mapea MDP TOP, LM0, PP0, DSC, DSPP, DMA0 ni el VBIF. Nadie más en el kernel
  toca el MDSS (búsqueda de constantes 0x5e0xxxx en `iokit/`, `bsd/`, `osfmk/`, `pexpert/`).
- **Escrituras al DPU en todo el kernel** (aparte del DSI, que envía comandos DCS al panel: brillo, encendido):

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

| Bloque | Dirección | Tamaño | DT | Linux | Uso hoy |
|---|---|---|---|---|---|
| MDP TOP | 0x5e01000 | 0x494 | `qcom,sde-off/len` | `sm6115_mdp` | no se mapea |
| CTL0 | 0x5e02000 | 0x1dc | `-ctl-off/size` | `sm6115_ctl` (`DPU_CTL_ACTIVE_CFG`) | `CTL_FLUSH` |
| VIG0 | 0x5e05000 | 0x1f8 | `-sspp-off` "vig" | `sspp_0`, `VIG_SDM845_MASK` | dirección y stride |
| VIG0 escalador | 0x5e05a00 | 0xa0 | `-sspp-qseed-off 0xa00`, `-qseed-scalar-version 0x3000`, `-qseed-sw-lib-rev "qseedv3lite"` | `dpu_vig_sblk_qseed3_3_0` (`SSPP_SCALER_VER(3, 0)`) | nunca |
| VIG0 CSC | 0x5e06a00 | 0x100 | `-sspp-csc-off 0x1a00`, `csc-10bit` | `_VIG_SBLK` | nunca |
| DMA0 | 0x5e25000 | 0x1f8 | `-sspp-off` "dma" | `sspp_8` | nunca |
| LM0 | 0x5e45000 | 0x320 | `-mixer-off`, 4 etapas, ancho 2048 | `lm_0` | nunca |
| PP0 | 0x5e71000 | 0xd4 | `-pp-off` | `pingpong_0` | nunca |
| INTF1 (DSI0) | 0x5e6b800 | 0x2c0 | `-intf-off`, "dsi" | `intf_1`, prog fetch 24 líneas | contadores |

Ancho máximo de línea del SSPP: 2160 (`qcom,sde-sspp-linewidth`); del mezclador: 2048. El panel es de vídeo, con DSC
(INTF: `display_hctl` 0x18f0028 = 360 relojes activos por línea, 1080/3) y 2432 líneas de 580 relojes.

### 1.3 Qué toca cada flip

`scanFrom()` (F1341-1382) escribe dirección y stride, `dsb`, `CTL_FLUSH = 0x20001`, `dsb`. Nada más: ni tamaños,
ni formato, ni el escalador. El plano conserva para siempre la geometría del ABL (fuente y salida de 1080×2400), por
eso todo lo que se enseña tiene que estar ya a la resolución del panel. `CTL_FLUSH` (`dpu_hw_ctl.c:26`): el bit 0 es
VIG0 (`update_pending_flush_sspp`, `dpu_hw_ctl.c:176-180`) y el 17 el propio CTL (`CTL_FLUSH_MASK_CTL`, l. 47), que
Linux pone con cada cambio de mezclador.

### 1.4 Estado en que el ABL deja el VIG y el escalador

Conocido por el log: dirección 0x5c000000 y stride 4320. **El resto no se ha leído nunca:** tamaños de fuente y salida,
formato y desempaquetado, `SRC_OP_MODE` (si usa la extensión de píxel por software), el estado del escalador (versión,
op mode) y del mezclador. El teléfono no tiene vía para leerlo: ningún sysctl vuelca el DPU, `dmesg` no está en el
`PATH` de la sesión SSH y el ring por `/dev/ufsroot0` devolvió 0 bytes en este arranque. **0347 añade la vía**
(`kern.sweet_fb_regs`, §4.1) y 0348 no arranca el scanout si el plano no es el que espera (§4.2).

### 1.5 Memoria: direcciones físicas, no el SMMU del display

- `SSPP_SRC0_ADDR` es de 32 bits y recibe direcciones físicas: 0x5c000000 (splash), 0xe2000000-0xe5000000 (pool bajo
  de los flip buffers y la sombra de consola, F157, F186, F338-361) y, si existieran, superficies de `sweetfb_direct`
  (S856-892).
- El stream del display en el SMMU de aplicaciones (DT: `iommus = <… 0x420 0x02>`, `qcom,smmu_sde_unsec`,
  `qcom,iommu-earlymap`) no lo programa el port. Sí programa otros SIDs del mismo SMMU (0x0c600000): una banca sin
  traducción para la cámara (`smmu_identity`, `TopazModem.cpp`, TFE 0x400) y traducción real para el ADSP
  (`smmu_s1`), cuyo comentario dice lo que también vale aquí: un bypass solo alcanza direcciones de 32 bits.
- **Inferencia:** como el panel enseña lo que hay en 0xe2xxxxxx y 0x5c000000, el SID 0x420 pasa sin traducción
  (bypass o banca sin traducción del ABL). No se ha leído el SMR/S2CR del SID (leer el espacio global del SMMU desde
  userland no tiene vía, y no se ha intentado).
- **Consecuencia:** lo que el DPU escanee debe estar en memoria física contigua por debajo de 4 GiB. La RAM del kernel
  está por encima (`mkadt.py --highmem`), por eso `sweetfb_direct` (contiguo con máscara física, S856-866) falla
  siempre en este teléfono (NOTES 2026-10-27) y el pool bajo es memoria fija que el kernel no gestiona.
- Hueco bajo en uso, según el código: cámara 0xd7000000-0xe0000000, módem 0xe0000000 (16 MB), GPU 0xe1000000-0xe1500000,
  framebuffer 0xe2000000-0xe5000000, QSEE 0xe8000000-0xe9000000 (`SweetQsee.cpp:80-85`, `sweet_cam.c:802-803`,
  `SapphireGpu.cpp:96-101, 1421-1427`). **0xe5000000-0xe8000000 no lo usa ningún código del port**, y el DT no tiene
  ninguna región fija por encima de 0x66000000 (`reserved-memory`). 0348 pone ahí su pool (20 MiB).

### 1.6 La copia por GPU de hoy, con números

- Ventana: `kx = 750·256`, `ky = 1624·256`; origen (`fOffX·kx/1125`, `fOffY·ky/2436`) = (3413, 3072)/256 =
  (13,33; 12); tamaño (1080·kx/1125, 2400·ky/2436)/256 = 720×1600 (F2032-2047). Escala 1080/720 = 2400/1600 = 1,5.
  Recorta 13,3 px a la izquierda, 16,7 a la derecha y 12 arriba y abajo (en píxeles 2x). Es la presentación de un
  iPhone X (1125×2436 a 3x) con el panel de 1080×2400 centrado (F128-137, F629-630), a 2x.
- Coste: dos medias pasadas del blitter 2D (pitch 4320, no múltiplo de 64), bilineales (`blit_scale`,
  G2206-2237), en el ring detrás del render; el tiempo de GPU no está medido (09 §2.2).
- Coste de CPU en `SwapEnd` que no tiene que ver con la copia: la limpieza de la superficie antes de que la GPU la lea
  (`sweet_fb_clean_for_gpu`, F1796-1815).

### 1.7 Lectura del teléfono (2026-11-14, solo lectura, arranque de 5 min)

`~/sapphire-angel/research/metal/display/telefono/lectura-20261114-135453.txt`. `kern.sweet_fb_queue 1`,
`kern.sweet_gpu_flush 1`, `kern.sweet_fb_rscale 1000`. De `kern.sweet_fb_diag`: 2185 swaps, 2011 flips, 164 pisados;
**`present: 2020`, `surface cleans 1963, 3 029 030 us`**: con la cola, casi cada `SwapEnd` limpia de caché la
superficie entera (1,54 ms cada vez, en el hilo de CoreAnimation), aun con la contabilidad de 0339 activa.
`arrival to flip`: 977 frames en 4-8 ms y 985 en 8-12 ms. n = 1 lectura: orientativo.

## 2. Cómo lo hacen Linux y el driver de stock

- **Plano escalado** (Linux, `dpu_plane.c:1033-1100`, `dpu_plane_sspp_update_pipe`): dirección y stride
  (`setup_sourceaddress`), rectángulos (`setup_rects`, `dpu_hw_sspp.c:404-444`: `SRC_SIZE`, `SRC_XY`, `OUT_SIZE`,
  `OUT_XY`), escalador (`_dpu_plane_setup_scaler`, l. 529-575), formato (`setup_format`, `dpu_hw_sspp.c:210-329`, que
  siempre pone `MDSS_MDP_OP_PE_OVERRIDE`, l. 305) y QoS. Después el flush del CTL.
- **Configuración del escalador** (`_dpu_plane_setup_scaler3`, `dpu_plane.c:426-493`): pasos de fase
  `mult_frac(1 << 21, src, dst)` por eje, fase inicial 0, precarga 4×2 para versión ≥ 3.0 (l. 53-56, 473-479),
  filtro `DPU_SCALE_BIL` para Y/RGB y alfa, `lut_flag = 0`, `blend_cfg = 1`. Extensión de píxel: el tamaño de la
  fuente (`_dpu_plane_setup_pixel_ext`, l. 495-511; `setup_pe_config`, `dpu_hw_sspp.c:331-386`). Escritura de
  registros: `dpu_hw_setup_scaler3` (`dpu_hw_util.c:282-382`).
- **El driver de stock hace lo mismo cuando userspace no da datos del escalador**: `_sde_plane_setup_scaler`
  (`sde_plane.c:1252-1300`) pide la tabla `lut_sep` (`_sde_plane_setup_scaler3lite_lut`, l. 821-833) y, si no la
  hay o no hay `scaler_v2`, calcula el bilineal por defecto (`_sde_plane_setup_scaler3`, l. 836-939, idéntico al de
  Linux salvo `dyn_exp_disabled = 0`). `sde_hw_setup_scaler3` (`sde_hw_util.c:350-…`) escribe los mismos registros.
- **Las tablas del QSEED3LITE** (33 coeficientes × 10 filtros separables, en escalador+0x100 y +0x200, con
  `DIR_FILTER_WEIGHT` en +0x60 y el bit de intercambio en `COEF_LUT_CTRL`, `sde_hw_util.c:239-289`) **las pone
  userspace**: propiedad de plano `lut_sep` (`sde_plane.c:3467, 3474`), que el HAL envía en el arranque del display
  (`display_base.cpp:82-85` → `hw_device_drm.cpp:963-971`); la implementación abierta de quien las genera no da nada
  (`ResourceDefault::GetScaleLutConfig`, `resource_default.cpp:941-943`): en el teléfono las da la extensión cerrada
  de Qualcomm. El kernel no tiene ninguna tabla.
- **Flip tomado:** Linux y SDE dan por hecho un commit cuando, en el vblank, `CTL_FLUSH` ya no tiene los bits que se
  escribieron (`dpu_encoder_phys_vid.c:345-353`, "double-check with hw that it accepted the flush bits";
  `wait_for_commit_done`, l. 524-540; `sde_encoder_phys_vid.c:498-515`, que solo entonces suelta el buffer anterior).
- **Leer el DPU entero no tiene efectos:** el volcado de Linux lee todos esos bloques con sus tamaños
  (`dpu_kms.c:904-1010`, `dpu_kms_mdp_snapshot`).

## 3. Diseño del scanout directo

### 3.1 La memoria de la superficie: tres opciones

| | Opción | A favor | En contra | Decisión |
|---|---|---|---|---|
| (a) | Mapear la superficie (páginas sueltas) en una banca de traducción del SMMU para el SID del display | ninguna restricción de memoria; superficies normales | hay que pasar el SID 0x420 de bypass a traducción **con el panel escaneando**: las direcciones del splash, de los flip buffers y de la consola tendrían que estar mapeadas antes; un error de traducción del display es un pipe atascado; el SMMU es el mismo que usan UFS y USB, y la banca y el SMR del display los dejó el ABL sin que se sepa cómo | descartada para el primer paso; documentada |
| (b) | Las superficies de pantalla de backboardd salen de un pool físico por debajo de 4 GiB | el mecanismo ya existe para los flip buffers (memoria fija, WC, bypass); cada superficie es contigua; sin tocar el SMMU | 5 MiB por superficie de memoria fija; solo las superficies creadas con el pool activo | **elegida** |
| (c) | El driver Metal dibuja en un buffer del pool del panel | ninguna superficie especial | cambia el driver, y CoreAnimation sigue presentando IOSurfaces: habría que mantener otra cadena paralela | descartada |

Cuenta del pool: 750×1624 con filas de 3072 bytes son 4 988 928 bytes (4 997 120 redondeados a página de 16 KiB);
huecos de 5 MiB. Cuatro huecos (dos superficies, la tercera que CoreAnimation crea si las dos están en uso, y una de
margen) son 20 MiB en 0xe5000000-0xe6400000. El pool de los flip buffers (48 MB) no tiene sitio: lo ocupan la página
del DSI, dos flip buffers, la sombra de consola y el tercer flip buffer de 0340 (41,7 MB).

### 3.2 Requisitos de la superficie y cómo los cumple 0348

- **Quién:** la crea backboardd, al tamaño 2x de la pantalla (750×1624), `'BGRA'`, 4 bytes por píxel, un plano,
  filas múltiplo de 64 bytes, sin `IOSurfaceAddress`. SpringBoard crea superficies del mismo tamaño (`keys 10`, frente
  a `keys 11` de las de backboardd en `ring.txt`) que no deben gastar huecos; 0347 registra los nombres de sus
  propiedades para afinar el criterio si hiciera falta.
- **Memoria:** `IOMemoryDescriptor::withPhysicalAddress` sobre el hueco, como la superficie del panel
  (`sweet_surface_create_physical`, S346-366). **Mapeada write-combined en todas partes:** en el kernel
  (`kernelAddress()`), en cada programa (`mapCache`, S664) y en el mapeo del cliente de la GPU (`clientMemoryForType`,
  G4602). Mapeada «por defecto», memoria que el kernel no gestiona queda como Device y un `memcpy` desalineado fallaría
  (lo dice el propio código, S859-863). Sin líneas en ninguna caché, ni la GPU ni el DPU necesitan limpiezas: el
  submit la salta en los dos modos de `kern.sweet_gpu_flush`, y la copia de `present()` también.
- **Vida:** un hueco vuelve al pool cuando la superficie se libera; el framebuffer retiene la superficie que enseña,
  así que nunca se reutiliza un hueco que el DPU lee.

### 3.3 Formato y orden de componentes

La superficie es `'BGRA'` (bytes B, G, R, A en memoria: `DRM_FORMAT_ARGB8888` en little endian), el mismo orden que
los flip buffers: hoy el blitter copia sin reordenar y el panel lo enseña bien con el formato del ABL. 0348 conserva
`SSPP_SRC_FORMAT` y el desempaquetado del ABL, y comprueba al arrancar que el formato es lineal, de 4 bytes y RGB.
Del registro saca si hay alfa (bit 8, `SRCC3_EN`) y si es de 10 bits (bit 14), que Linux usa para el op mode del
escalador (`dpu_hw_setup_scaler3`, l. 369-379).

### 3.4 Geometría: igual que la copia

No se estira ni se ponen bandas: se escanea la misma ventana que copia la GPU, `SRC_XY = (13, 12)`,
`SRC_SIZE = 720×1600`, salida 1080×2400 en (0, 0), ×1,5 en los dos ejes. La única diferencia es 1/3 de píxel 2x
(media columna del panel) en el origen horizontal, porque `SRC_XY` es entero y la fase inicial se deja a 0, como
Linux: es invisible y el táctil no cambia. Con `kern.sweet_fb_rscale` (0321) la ventana se recalcula igual que en la
copia (`sweet_scan_window`) y el factor sube (400 ‰: ×3,75; el QSEED3 admite hasta ×20 de ampliación).

### 3.5 QSEED3LITE: registros y valores

Para 720×1600 → 1080×2400 (lo que escribe `sweet_plane_scaled_regs`, igual a Linux, §6.3):

| Registro (VIG0 +) | Valor | Origen |
|---|---|---|
| `SRC_SIZE` 0x000 | 0x064002d0 (1600<<16 \| 720) | `setup_rects` |
| `SRC_XY` 0x008 | 0x000c000d (12<<16 \| 13) | `setup_rects` |
| `OUT_SIZE` 0x00c, `OUT_XY` 0x010 | 0x09600438, 0 (los del ABL) | `setup_rects` |
| `SW_PIX_EXT_C0/C1C2/C3` LR, TB, REQ 0x100-0x128 | 0, 0, 0x064002d0 | `setup_pe_config` |
| `PHASE_INIT_Y_H/Y_V/UV_H/UV_V` 0xa90-0xa9c | 0 | `dpu_hw_setup_scaler3` |
| `PHASE_STEP_Y_H` 0xa10, `UV_H` 0xa18 | 0x155555 (1 398 101 = 2²¹·720/1080) | `mult_frac` |
| `PHASE_STEP_Y_V` 0xa14, `UV_V` 0xa1c | 0x155555 (2²¹·1600/2400) | `mult_frac` |
| `PRELOAD` 0xa20 | 0x02040204 (H 4, V 2) | versión ≥ 3.0 |
| `SRC_SIZE_Y_RGB_A` 0xa40, `SRC_SIZE_UV` 0xa44 | 0x064002d0 | |
| `DST_SIZE` 0xa48 | 0x09600438 | |
| `OP_MODE` 0xa04 | 0x80034001, + 0x20000400 si el formato lleva alfa | enable, BIL, blend, 8 bits |
| `SSPP_SRC_OP_MODE` 0x038 | el del ABL \| bit 31 (PE override) | `setup_format` |

Las dos razones son la misma (1,5), así que los dos pasos coinciden. Para estirar la superficie entera (750×1624 →
1080×2400, razones 1,44 y 1,478) serían 0x1638e3 y 0x15a740: el arnés los calcula también (§6.3), pero 0348 no estira.
Sin tabla:
filtro bilineal (`y_rgb_filter_cfg = 3`, `DPU_SCALE_BIL`), como la copia de hoy (el blitter también es bilineal,
G2206-2237).

### 3.6 Flush atómico y sincronía con el vsync

- Los registros del plano tienen doble buffer: se toman todos juntos en el inicio de frame si el bit de VIG0 de
  `CTL_FLUSH` está puesto. **Lo escrito mientras un flush está pendiente se toma con él:** un cambio de geometría a
  medias (tamaños nuevos con el escalador viejo) sería un frame roto o un pipe atascado.
- 0348 reescribe el plano solo si (1) `CTL_FLUSH & 0x20001` lee 0 (el DPU tomó el anterior) y (2) `INTF_LINE_COUNT`
  está entre 1/16 y 3/4 del refresco (152-1824 de 2432 líneas: a ≥ 2 ms del inicio de frame y del fetch programable de
  24 líneas que lo precede). Escribir 27 registros son microsegundos. Fuera de esa ventana, el hilo de la cola vuelve a
  mirar a los 500 µs.
- **Flip tomado:** como en 0340 (el contador de frames del INTF ha avanzado desde la escritura), y además, en cuanto
  un flip ha demostrado que `CTL_FLUSH` devuelve sus bits hasta que el DPU los toma, que los bits estén limpios (lo que
  hacen Linux y SDE). Como el flip se escribe a mitad de refresco, un avance del contador basta.
- Si el DPU no toma un flush del plano escalado en 100 ms, el scanout se apaga solo y vuelven las copias.

### 3.7 Cómo encaja con la cola de 0340

- **El «buffer trasero» es la propia superficie.** Un `SwapEnd` de una superficie del pool entra en la cola como frame
  de scanout: dirección de la superficie, ventana, y como valla la del último submit msm en ese momento (HakiosMetal
  envía al hacer `commit`, `command.cpp:390-396, 603-628`: el submit precede al `SwapEnd`; un ring, en orden). Si un
  submit posterior nombra la superficie, el flip espera también a ese (`gpuFence` de la superficie, que pone el
  submit). Sin límite de tiempo, como las copias: una GPU colgada se reinicia a los 2 s y sus vallas saltan (0317).
  Un frame de superficie aún sin dibujar cuando se vacía la cola se descarta, no se enseña a medias.
- **Vida de la superficie:** en uso desde su `SwapEnd` (como hoy) hasta que el DPU ha tomado el flip de un frame
  posterior: mientras está en pantalla y mientras el DPU la abandona. Después se suelta (`sweet_hold` y `release`).
  CoreAnimation solo dibuja en superficies que no están en uso; con dos, una está en pantalla y otra en la cola, y
  crea una tercera (lo hacía con la retención de topaz: F1189-1197 a 0342).
- **Triple buffer del lado de CoreAnimation:** el pool tiene cuatro huecos. Si CoreAnimation no crea la tercera y
  espera, se nota en los swaps por segundo (`swap interval` de 0336) y en `swaps that waited` de
  `kern.sweet_fb_scanout_diag`.
- **Frames mezclados:** un frame que no encaja (varias capas, superficie fuera del pool, una superficie que el panel
  aún puede leer) va por la copia, a la misma cola, en orden. El flip de un flip buffer vuelve a poner el plano del ABL
  con las mismas reglas de §3.6.
- **Profundidad y contrapresión:** las de 0340 (`kern.sweet_fb_queue_depth`, `_hold_ms`): un `SwapEnd` espera si ya
  hay tantos frames en cola; al vencer, el más nuevo de la cola cede su sitio y no se enseña (`overwritten`).
- **Encendido y apagado:** al apagar la pantalla, el tick vuelve al framebuffer de arranque (ahora con
  `fPresentLock`), lo que restaura el plano; la superficie se suelta cuando el DPU lo toma. Al encender, el frame que se
  re-presenta pasa por el mismo camino.

### 3.8 Coste esperado

- GPU: desaparecen las dos medias pasadas de la copia (leen 9,2 MB y escriben 10,4 MB por frame) y sus
  `CP_WAIT_FOR_IDLE`; el render deja de competir con ellas en el ring.
- CPU: desaparecen los `dc cvac` de 5 MB en `SwapEnd` (1,54 ms, §1.7) y los `dc civac` del submit en el modo 0 de
  0339 (la superficie es WC).
- Latencia: `SwapEnd` → fin del render → siguiente ventana escribible (≤ 0,5 ms de sondeo) → inicio de frame. Se
  quitan la copia y su espera detrás del render.
- Ancho de banda de scanout: el DPU lee 720×1600×4 = 4,6 MB por refresco en vez de 10,4 MB.
- Memoria: 20 MiB de pool fijo; los flip buffers se quedan (son la ruta de vuelta).

## 4. Los parches

Fuera de `xnu/patches/`, en `~/sapphire-angel/research/metal/display/parches-nuevos/`. Van en orden, sobre 0342 (y
con los 0343-0348 de relojes antes o después: §6.1).

### 4.1 `0347-sapphire-fb-dpu-regs-latch-diag.patch` (diagnóstico; solo lectura)

`SweetFramebuffer.cpp` y `SweetSurface.cpp`; 6 hunks. No escribe ningún registro que no se escribiera antes ni cambia
qué se presenta.

- **`kern.sweet_fb_regs`** (lectura): MDP TOP, CTL0, VIG0, su escalador y su CSC, LM0, PP0 e INTF1 tal como están, 8
  palabras por línea (~12 KB de texto), más VIG0 y su escalador tal como los dejó el ABL (leídos en `start()` antes del
  primer flip del kernel). Linux lee esos mismos bloques enteros en su volcado (`dpu_kms_mdp_snapshot`).
- **`kern.sweet_fb_latch`** (lectura): para cada flip, si `CTL_FLUSH` devuelve los bits recién escritos (0x20001),
  cuánto tardan en limpiarse, con cuántos frames de `INTF_FRAME_COUNT` de diferencia (por dieciseisavo del refresco
  en que se escribió el flip), cuántas veces avanzó el contador con los bits aún puestos y cuántos no se limpiaron en
  100 ms. Lo miran el hilo de la cola (cada 500 µs mientras hay un flip pendiente) y los ticks.
- **Registro de superficies de pantalla:** las 16 primeras superficies del tamaño del panel o del 2x, quién las crea y
  los nombres de sus propiedades (`SWEET SURF: screen-sized surface N by P: …`).

```sh
ssh sapphire 'PATH=/var/jb/usr/bin:/var/jb/usr/sbin:$PATH; sysctl -n kern.sweet_fb_regs kern.sweet_fb_latch'
```

Qué decide: el formato y el op mode del plano del ABL (alfa, extensión de píxel), el estado del escalador (versión,
apagado), qué hay en el mezclador; si `CTL_FLUSH` sirve como señal de flip tomado y dónde está, en líneas, el punto en
que el DPU toma el plano.

### 4.2 `0348-sapphire-fb-scanout-vig-scaler.patch` (scanout directo; apagado por defecto)

`SweetFramebuffer.cpp`, `SweetSurface.cpp`, `SweetSurface.h`, `SapphireGpu.cpp`; 28 hunks.

| Interruptor | Valores | Efecto |
|---|---|---|
| `kern.sweet_fb_scanout` (boot-arg `sweetfb_scanout`) | **0** (defecto) | como antes |
| | 1 | superficies de pantalla de backboardd en el pool y scanout directo de sus frames |
| | 2 | solo el pool (los frames se siguen copiando) |
| `kern.sweet_fb_scanout_diag` | lectura | listo o por qué no; pool; frames, flips y frames copiados con su motivo; dibujos después del `SwapEnd`; esperas en `SwapEnd`; cambios del plano y sus esperas; superficies soltadas; paradas; flushes no tomados; la ventana en pantalla |

Piezas: el pool y su criterio (`SweetSurface.cpp`: `sweet_pool_*`, `kernelAddress()` WC para el pool); la valla
por superficie y el mapeo WC del cliente de la GPU (`SapphireGpu.cpp`: `sapphire_gpu_msm_fence*`, `gpuFence` en el
submit, `clientMemoryForType`, el modo 0 de la limpieza salta el pool); y en `SweetFramebuffer.cpp`:
`sweet_plane_scaled_regs` y `sweet_scan_window` (aritmética pura, comprobada en el host), `scanoutInit` (lee y valida
el plano del ABL, configura el pool), `presentScanout` (decide y encola), `planeScaled`/`planeUnscaled`/`planeWritable`
(escriben el plano solo cuando no puede tomarse a medias), `frameDone`/`frameShow` (valla y flip de cada clase de
frame), `scanoutLeave`/`scanoutRetire` (vida de la superficie), `flipNote` (la contabilidad de 0340, ahora tras la
espera), `scanoutStop` (vuelta a la copia en caliente) y el vigilante de 100 ms en `queueFlip`.

Cambia también dos detalles de 0340 que la simulación sacó a la luz (§6.4): `presentQueued()` limpia el hueco de la
cola que rellena, y el flip se anota cuando se escribe, no antes de esperar.

## 5. Candados

- Todo el estado del scanout (cola, superficies en pantalla y saliendo, plano) va con `fPresentLock`, como la cola de
  0340. El tick del apagado de pantalla toma ahora `fPresentLock` alrededor de su flip (antes escribía sin él).
- Orden: `fPresentLock` → `service_lock` (la copia, como antes) y `fPresentLock` → `sweet_surface_lock` (soltar una
  superficie puede liberarla y devolver su hueco; 0340 ya soltaba superficies con `fPresentLock`). `fLock` nunca está
  tomado al tomar `fPresentLock` (`scanoutStop` copia `fPending` con `fLock` y lo suelta antes). `SweetSurface` pregunta
  `sweet_fb_scanout_pool_on()` sin candado (dos palabras).
- **Esperas:** el `SwapEnd` que espera sitio en la cola duerme con `IOLockSleepDeadline` (suelta el mutex). La espera
  de un plano escribible es un bucle de lecturas de registros de 20 ms como mucho, con `fPresentLock`: solo en los
  cambios de modo (primer frame de superficie tras copias, primera copia tras superficies, vaciado de la cola, apagado,
  pánico); los flips del hilo de la cola llegan ya escribibles. No usa `IODelay`, así que sirve en la consola de pánico.
- **Sin candado:** `sweet_cons_show()` (pánico) llama a `scanFrom()` como antes; restaura el plano con el mismo bucle.
  `gpuFence` lo escribe el submit con `service_lock` y lo lee `frameDone()` sin él (una palabra); igual `msm_seq`.
- La contabilidad de 0336/0347 son contadores sin candado, como en 0336.

## 6. Verificación

Herramientas en `~/sapphire-angel/research/metal/display/work/verif/`.

### 6.1 Aplicación y compilación

- `check-all.sh`: `git apply --check` y `git apply` en orden sobre un árbol limpio a 0342: **los dos aplican**, y el
  resultado es idéntico al árbol de trabajo. Con los parches de relojes (0343, 0345, 0346, 0347-ddr-vote,
  0348-hwcg) antes o después de los míos, **todos aplican** en los dos órdenes.
- `clang++ -fsyntax-only` con `kernel-gpu/verificacion/syn.sh` y sus stubs: **0 errores** en los tres archivos, solos y
  con los de relojes.
- `inject.py`: un identificador sin declarar al principio de cada función nueva (31): **los 31 se señalan**: todo el
  código nuevo se compila de verdad.
- `warn.sh` (`-Weverything` con la lista `-Wno` del kernel): en las líneas añadidas solo salen los avisos de las macros
  `SYSCTL_*` que ya da el código vecino.

### 6.2 Aritmética del plano frente a Linux (`arnes/`)

`extract.py` corta **literalmente** de Linux v6.12 `setup_rects`, `setup_pe_config`, `_dpu_plane_setup_scaler3`,
`_dpu_plane_setup_pixel_ext`, `dpu_hw_setup_scaler3` (con sus funciones de tabla y de realce), `mult_frac` y las
estructuras y offsets, y del kernel parcheado `sweet_plane_off[]`, `sweet_plane_scaled_regs()` y
`sweet_scan_window()`. `arnes.c` hace escribir a Linux un plano escalado en un registrador y lo compara registro a
registro con el del kernel:

- caso del teléfono (720×1600 en (13,12) → 1080×2400): **Linux escribe exactamente los mismos 27 registros con los
  mismos valores** (tabla de §3.5);
- 200 003 casos (rectángulos aleatorios dentro de los límites del escalador, las dos codificaciones de versión
  0x00030000 y 0x3000, con y sin alfa, 8 y 10 bits, op modes del ABL aleatorios sin volteo): **0 diferencias**;
- la ventana de `sweet_scan_window()` frente a la de la copia (1/256 px) para cada escala de render de 400 a 1000 ‰:
  origen dentro del píxel, tamaño a ±0,5 px, **0 fuera**;
- cinco mutaciones del código del kernel (precarga, filtro de alfa, orden de `REQ_PIXELS`, PE override, paso de fase):
  **las cinco se detectan** (en todos los casos, o en todos los que tienen alfa).

`arnes-sde.c` hace lo mismo con el driver de stock: `_sde_plane_setup_scaler3` y `sde_hw_setup_scaler3` literales, con
el bloque del escalador iniciado como lo hace el catálogo con el DT del teléfono (`sde_init_scaler_blk`, 0x3000):
**100 001 casos, 0 diferencias** en los registros del escalador.

### 6.3 Simulación de la cola con frames de superficie (`sim-0348/`)

`extract.py` corta del `SweetFramebuffer.cpp` parcheado, tal cual (solo las barreras `dsb` pasan a comentario), los
globales de 0348, `scanFrom`/`flipNote` y todo desde `queueOn()` hasta el user client (la cola de 0340, su hilo y el
scanout). `sim.cpp` los ejecuta contra un modelo: reloj virtual en el que el código del kernel tarda (cada lectura del
reloj avanza 100 ns y el hardware sigue, mientras los demás hilos del kernel esperan el candado), una GPU que ejecuta
dibujos y copias en orden, un DPU que toma el plano en cada inicio de frame si hay un flush pendiente (con y sin
lectura de `CTL_FLUSH`), el temporizador de 120 Hz, el hilo de la cola y un CoreAnimation que dibuja en superficies
libres y llama a `SwapEnd`. Los registros del modelo ven cada escritura.

Comprueba en cada ejecución: que el plano nunca se toma a medias (en cada toma los 27 registros son el juego del ABL o
el escalado para la ventana que contienen, y un plano escalado apunta a una superficie del pool); que la geometría
solo se escribe sin flush pendiente (con lectura de `CTL_FLUSH`) y dentro de la ventana; que la GPU nunca dibuja en
una superficie que el panel escanea ni se suelta una superficie que el panel aún puede leer; que ningún frame llega
al panel antes de terminar su dibujo; el orden; que todo frame se enseña o se cuenta como descartado; y las
comprobaciones de 0340 (ninguna copia sobre lo que el panel lee o sobre un frame en cola).

Diecisiete escenarios (dos, tres y cuatro superficies y CoreAnimation que crea la tercera; régimen del teléfono,
GPU saturada, ligero, ráfagas; frames de CPU y frames de superficies fuera del pool mezclados; envíos después del
`SwapEnd`; `CTL_FLUSH` sin lectura; apagado y encendido en caliente; GPU colgada) × 30 semillas × 600 frames:
RESULTADO_SIM

Dos defectos del código que encontró la simulación, corregidos en 0348:

1. `presentQueued()` (0340) rellenaba un hueco de la cola sin limpiarlo: una copia que caía en el hueco de un frame de
   superficie heredaba `scan = true` y se enseñaba como tal (modo del plano equivocado, frames desordenados).
2. `scanFrom()` anotaba el flip (contador de frames, línea) **antes** de esperar un plano escribible: tras la espera la
   anotación tenía un frame de retraso y, sin lectura de `CTL_FLUSH`, `flipTaken()` daba el flip por tomado antes de
   tiempo y soltaba una superficie que el panel aún leía. Ahora se anota al escribir.

Y dos hechos del modelo que no son defectos y se cuentan aparte: un envío que nombra la superficie **después** de que
su frame ya está en pantalla la rasga (el kernel no puede esperar algo que aún no existe: el diseño supone que el dibujo
de un frame se envía antes de su `SwapEnd`, como hace HakiosMetal, y `drawn after the SwapEnd` lo vigila); y el
`queueDrain()` de 0340 suelta las superficies de un frame cuya copia aún no terminó tras 20 ms, lo que es inocuo porque
lo que CoreAnimation dibuje después en ellas va detrás de la copia en el mismo ring.

## 7. Si falla: qué vería el coordinador y cómo volver

Con 0347 y 0348 y sin tocar nada, la presentación es la de hoy; el arranque añade la línea
`SWEET FB: scanout (kern.sweet_fb_scanout 0): ready|<motivo>; plane at boot: …` con el plano del ABL.

Activarlo en caliente, sin boot-arg (el cmdline del teléfono ya tiene 572 caracteres; por encima de 575 el shim pierde
`sweet_splash`):

```sh
ssh sapphire 'PATH=/var/jb/usr/bin:/var/jb/usr/sbin:$PATH; sysctl -w kern.sweet_fb_scanout=1; killall -9 backboardd'
ssh sapphire 'PATH=/var/jb/usr/bin:/var/jb/usr/sbin:$PATH; sysctl -n kern.sweet_fb_scanout_diag kern.sweet_fb_latch'
```

| Si falla… | Se ve | Qué mirar | Vuelta |
|---|---|---|---|
| El plano escalado está mal (formato, recorte, el escalador no responde como Linux) | imagen negra, desplazada, de colores cambiados o basura, con el sistema vivo | `kern.sweet_fb_regs`, `flips` creciendo | `sysctl -w kern.sweet_fb_scanout=0`: el frame en pantalla se vuelve a presentar por la copia al momento y el plano vuelve al del ABL |
| El DPU no toma un flush del plano escalado | imagen congelada | `flushes not taken` | automático a los 100 ms; si el pipe queda colgado, reiniciar (`reboot`, o `kern.sweet_reboot_mode=2` y `reboot` para fastboot) |
| CoreAnimation dibuja en una superficie en uso | desgarro (franjas de dos frames) | `swapped again while on the panel or waiting` | `kern.sweet_fb_scanout=0` |
| CoreAnimation no crea una tercera superficie | menos swaps por segundo | `swaps that waited`, `swap interval` | `kern.sweet_fb_queue_depth=1` o `scanout=0` |
| El criterio del pool no coge las superficies de pantalla | nada cambia | `not from the pool` creciendo, `pool: … made` | reiniciar backboardd con `scanout=1`; ver `SWEET SURF: screen-sized surface …` |
| Pánico en código nuevo | reinicio | ring | el arranque siguiente viene con `scanout=0` (si se activó por sysctl) |

El USB y SSH no dependen del display: una pantalla negra o congelada se arregla por SSH. Por eso conviene probar
siempre por sysctl y no con el boot-arg.

**Orden de prueba propuesto:** (1) arrancar sin tocar nada y leer `kern.sweet_fb_regs`, `kern.sweet_fb_latch` y
`kern.sweet_fb_scanout_diag` (¿`ready`?, ¿`CTL_FLUSH` devuelve los bits?, ¿en qué línea se toma el plano?);
(2) `scanout=2` y reiniciar backboardd: las superficies pasan al pool con la copia de siempre (debe verse igual y
dejar de crecer `surface cleans` de `kern.sweet_fb_diag`); (3) `scanout=1`, mirando la pantalla (bordes, barra de
estado, alineación del táctil); (4) `tools/perf/homeswipe.sh` con 0 y con 1, n≥3: buffers/s, commit→fin, ocupación de
la GPU, `swap interval`, `flip interval`, `arrival to flip`, temperatura.

## 8. Riesgos y lo no verificado

- **No verificado en el teléfono:** que `CTL_FLUSH` devuelva los bits pendientes (Linux y SDE lo usan; 0347 lo mide y
  0348 se adapta si no); dónde toma el DPU el plano respecto a `INTF_LINE_COUNT` con el fetch programable (la ventana
  deja ≥ 2 ms de margen; 0347 lo mide); el estado del VIG0 que deja el ABL (0348 no arranca si no es el esperado); que
  `SRC_XY` recorte una fuente RGB lineal (Linux lo usa así); que el SID 0x420 alcance 0xe5000000 como alcanza
  0xe2000000; que nadie use 0xe5000000-0xe6400000 (ningún código del port, ninguna región fija del DT); cómo
  responde CoreAnimation a superficies retenidas hasta el flip siguiente; las propiedades que distinguen sus
  superficies de pantalla de las de SpringBoard (0347 las registra).
- **Calidad:** bilineal sin tabla, como la copia de hoy. Con tablas haría falta el contenido que da el HAL cerrado.
- **Medio píxel:** el origen horizontal es 13 en vez de 13,33 (fase inicial 0, como Linux).
- **Memoria fija:** 20 MiB del banco bajo en uso solo cuando hay superficies en el pool.
- **Sin compilar en CI y sin ejecutar en el teléfono.**

## Material

- `~/sapphire-angel/research/metal/display/`: `parches-nuevos/` (0347, 0348), `work/xnu` (árbol con un commit por
  parche sobre la serie a 0342), `work/headers/` (descripciones), `work/mkpatch.sh`, `work/verif/` (`check-all.sh`,
  `inject.py`, `warn.sh`, `stubs/`, `arnes/` con `arnes.log` y `arnes-sde.log`, `sim-0348/` con `run.log`),
  `ref/` (Linux v6.12, SDE KAMORTA, SDM, `math.h`), `telefono/` (lectura del teléfono).
