# 11 — GPU: relojes, raíles, bus y memoria frente a Android

Auditoría de la potencia, los relojes, el bus y la memoria de la GPU (Adreno 610 v2, SM6225) que programa
el kernel de iOS, comparada con lo que hace Android en este mismo teléfono. Alcance: solo
potencia/relojes/bus/memoria y, de pasada, CPU; el driver Metal y la lógica submit/alloc/present están en
[09](09-auditoria-kernel-gpu.md) y [10](10-auditoria-rendimiento-hakios-metal.md). Auditoría del 14 de
noviembre de 2026 sobre la serie `xnu/patches/` 0001-0335 reconstruida (xnu-8796.141.3).

Convenciones: **G123** = línea 123 de `iokit/Kernel/arm/SapphireGpu.cpp` reconstruido a 0335
(sha256 `6f108354…`). **DT:123** = línea del árbol de dispositivos de Android de este teléfono ya fusionado
(`dtb/merged-khaje24a-sapphire.dts`, §2). **O** = observación (medida o leída en una fuente primaria),
**H** = hipótesis.

## 1. Resumen

1. **O (medido). El núcleo de la GPU corre a 630,00 MHz, no a 1260.** 15 muestras de 15 con `gxfreq`
   (03 M3): los contadores de ciclos del CP y del RBBM contra el contador de 19,2 MHz. `gpu_mhz=1260`
   programa el **VCO** de `gpu_cc_pll0` a 1260 MHz; el reloj del núcleo sale de `OUT_MAIN`, que es el VCO
   dividido por 2.
2. **O (fuentes y binarios del teléfono). Android consigue 1260 MHz con el VCO a 2520 MHz.** La cadena
   completa, con el posdivisor ÷2 y el RCG en ÷1, está en los módulos del `vendor_boot` de este teléfono
   (`gpucc-khaje.ko`, `clk-qcom.ko`) y en el código de stock (§4). El valor de `USER_CTL` y el del RCG que
   escribe iOS son los mismos que los de Android; lo único distinto es la frecuencia del VCO: la mitad.
3. **O. El nivel de raíl para 1260 MHz es 464 (SUPER_TURBO) en VDD_CX**, no el 0x1a0 (416) que vota 0204
   leyendo `qcom,level` del DT: en una GPU sin GMU el voltaje lo decide el driver de relojes, y su tabla
   pide 464 para 1260 MHz y 416 para 1114,8 (§4.3). El PLL cuelga además de VDD_MX (256 con el VCO a
   2520 MHz), que iOS no vota.
4. **O. Android vota además el límite de corriente de pico de CX** (`cx_ipeak`, clientes 1 y 10) antes de
   pasar de 900 y de 950 MHz, y fija el DDR en su nivel máximo (2092 MHz) mientras la GPU está en sus dos
   niveles altos. iOS no hace ninguna de las dos cosas.
5. **La afirmación heredada "la GPU está limitada por el ancho de banda de memoria" no se sostiene.** El
   argumento que la apoyaba era que subir el reloj no cambiaba nada; el reloj no subía (600 → 490 MHz con
   `gpu_mhz=980`, 600 → 630 con `gpu_mhz=1260`). La pasada principal del compositor mueve como mucho
   unos 25 MB en 18-24 ms, 1,4 GB/s, muy por debajo de lo que da el DDR en cualquier nivel razonable (§9).
6. **H. Con el reloj real a 1260 MHz esa pasada baja hacia 9-12 ms** si, como indican sus números, la
   domina el trabajo por tile y por draw, que va al ritmo del reloj del núcleo. Lo confirma o lo
   desmiente la escalera del parche 0337 (§8).
7. **Sin medir: la frecuencia del DDR bajo iOS.** Nadie vota el BIMC y el escalado de relojes del RPM está
   apagado, así que el DDR está donde lo dejó el arranque. Se lee con un registro (§10.2).
8. El resto de diferencias de `hw_init` (acceso mínimo de 64 bytes, clock gating por hardware, contadores
   de rendimiento) son menores o de consumo; tabla en §11.

El parche [`0337-sapphire-gpu-pll-vco.patch`](#8-parche-0337) programa el PLL, los raíles y los votos como
Android tras `gpu_vco2=1`. Está en `~/sapphire-angel/research/metal/relojes/parche/`.

## 2. Material y método

Todo el material pesado está fuera de git, en `~/sapphire-angel/research/metal/relojes/`:

| Carpeta | Contenido |
|---|---|
| `xnu/` | Árbol reconstruido a 0335: el replay de `auditoria-sweet_usb` más 0329-0335 con `git apply`. Idéntico (`diff -rq`) al de `kernel-gpu/` |
| `xnu-0336/`, `xnu-0337/` | El mismo árbol con el 0336 del agente del kernel, y con 0336 + 0337 |
| `dtb/` | Los 6 DTB de `vendor_boot_b` y los 47 overlays de `dtbo_b`, con su `.dts`; `merged-khaje24a-sapphire.dts` = base `Khaje SoC` msm-id 0x24a + overlay `Khaje IDP sapphire` (`fdtoverlay`). La base msm-id 0x206 es idéntica en todo lo de GPU; el overlay `sapphiren` solo añade NFC |
| `vendor_ramdisk/` | El ramdisk de `vendor_boot_b` extraído: 253 módulos del kernel de Android de este teléfono (5.15.94), entre ellos `gpucc-khaje.ko`, `clk-qcom.ko`, `gcc-khaje.ko`, `clk-smd-rpm.ko`, `bwmon.ko`, `memlat.ko`, `qnoc-bengal.ko`, `cx_ipeak.ko` |
| `ref/downstream/` | Kernel de stock: `MiCode/Xiaomi_Kernel_OpenSource` rama `topaz-t-oss` @ `345999da` (msm-5.15.41, mismo SoC) y `spes-r-oss` @ `88afd325` (4.19, kgsl en el árbol); kgsl 5.x de CodeLinaro `graphics-kernel` @ `f900d903` |
| `ref/linux/` | Linux v6.12: `gpucc-sm6115.c`, `a6xx_gpu.c`, `a6xx_catalog.c`, `msm_gpu.c`, `clk-smd-rpm.c`, `sm6115.dtsi`, `a6xx.xml`, `adreno_pm4.xml` |
| `ref/mesa/` | Mesa 24.3.0: `freedreno_devices.py` y otros |
| `scripts/` | `extract_dtbs.py` (vendor_boot v4 y dtbo), `kodump.py` (vuelca símbolos de datos de un `.ko`) |
| `gxfreq/` | Fuente y binario de la herramienta de §3 (la copia versionada es `tools/perf/gxfreq.c`) |
| `parche/` | `0337-sapphire-gpu-pll-vco.patch`, su generador (`work/splice0337.py`) y el arnés de anfitrión (`work/harness.cpp`) |
| `telefono/` | `sysctl` y `dmesg` del arranque auditado |

Del teléfono, en solo lectura: `sysctl` (`kern.sweet_*`, `hw.*`, `machdep.*`) y `dmesg`. El ring del log
no se pudo leer en esta sesión (`/dev/ufsroot0`: *Resource busy*); las líneas `SapphireGpu` y `SWEET
CPUFREQ` citadas son de rings guardados de arranques con los mismos boot-args
(`~/sapphire-angel/backups/ring-E5.txt` y otros siete).

## 3. Medición: la frecuencia real del núcleo

**Método.** El de Linux: `msm_gpu.c:657-668` calcula el reloj de cada envío como
`ciclos × 1000 / ns`, con los ciclos del contador de rendimiento 0 del CP en modo `PERF_CP_ALWAYS_COUNT`
(`a6xx_gpu.c:1019`) y el tiempo del contador always-on de 19,2 MHz, leídos ambos por el propio CP con
`CP_REG_TO_MEM` (`a6xx_gpu.c:92-101`, `:208-217`). `gxfreq` hace lo mismo por el cliente `SGPU` del
kernel: escribe `RBBM_PERFCTR_CNTL` (0x500) = 1, `CP_PERFCTR_CP_SEL_0` (0x8d0) = 0 y
`RBBM_PERFCTR_RBBM_SEL_0` (0x507) = 0, y toma dos muestras de `CP_ALWAYS_ON_COUNTER` (0x980),
`RBBM_PERFCTR_CP_0` (0x400) y `RBBM_PERFCTR_RBBM_0` (0x41c) separadas 200 ms. El kernel de iOS no activa el
clock gating de la GPU (§11), así que los contadores cuentan siempre.

    f = (ciclos_B − ciclos_A) × 19 200 000 / (aon_B − aon_A)

**O (03 M3, kernel 0334, `gpu_mhz=1260 gpu_div=1`).** 3 ejecuciones de `gxfreq 200 5`, 15 muestras: los
dos contadores dan **630,00 MHz** en las 15; ventanas de 200-300 ms, 20-21 ticks entre las dos lecturas
del always-on de una misma muestra.

No hay otra forma de leerlo en caliente con el kernel 0334-0335: ningún sysctl expone registros de GPUCC
(`kern.sweet_audio` solo llega al códec, a los amplificadores y a TLMM). Lo que sí queda en el ring de
cada arranque son los registros tras el encendido: `gpucc_pll0_l 00000042`, `gpucc_gx_gfx3d_rcg_cfg
00000101` y `gpu_cc_pll0 locked at 1260 MHz (l 66 alpha a000)`; con §4.2 dicen lo mismo que la medición.
Con 0337, `kern.sweet_gpu_pll` devuelve el PLL y el RCG en cualquier momento.

## 4. La cadena del reloj del núcleo en Android (este teléfono)

Fuentes: el DT fusionado, los módulos del `vendor_boot_b` del teléfono y el código de stock del mismo SoC.
Los datos de los `.ko` (leídos con `scripts/kodump.py`) coinciden campo a campo con
`gpucc-khaje.c` @ `345999da`.

### 4.1 De kgsl a la rama

| Eslabón | Qué es | Fuente |
|---|---|---|
| kgsl pide la frecuencia | `clk_set_rate(pwr->grp_clks[0], pl->gpu_freq)` sobre `core_clk` | kgsl 5.x `adreno.c:3270`; DT:7957-7958: `core_clk` = `<&gpucc 10>` = `GPU_CC_GX_GFX3D_CLK` |
| Rama | `gpu_cc_gx_gfx3d_clk`, enable 0x1054 bit 0, `CLK_SET_RATE_PARENT` | `gpucc-khaje.c:364-381` |
| RCG | `gpu_cc_gx_gfx3d_clk_src`, `cmd_rcgr` 0x101c, sin M/N, `CLK_SET_RATE_PARENT`. **Las diez filas** de su tabla son `F(f, P_GPU_CC_PLL0_OUT_MAIN, 1, 0, 0)`: fuente 1, divisor 1 → `CFG = 0x101` | `gpucc-khaje.c:220-246`, mapa `:176-183`; `.ko`: `ftbl_gpu_cc_gx_gfx3d_clk_src` (10 filas, `src` 4, `pre_div` 1), `gpu_cc_parent_map_1` |
| Posdivisor | `gpu_cc_pll0_out_main`: `USER_CTL[9:8]`, tabla `{ 0x1, 2 }`, `clk_alpha_pll_postdiv_ro_ops`, `CLK_SET_RATE_PARENT`. Solo lectura: lee el registro, divide por `1 << fls(ctl)` = 2 y pide al PLL `2 × f` | `gpucc-khaje.c:97-118`; `clk-alpha-pll.c:1347-1358`, `:1393-1415`; `.ko`: `post_div_table_gpu_cc_pll0_out_main = {1, 2}`; desensamblado de `clk_alpha_pll_postdiv_round_ro_rate` en `clk-qcom.ko` (0x5050-0x50a8: `1 << fls`, `mul` por la frecuencia pedida) |
| PLL | `gpu_cc_pll0`, Zonda, VCO de 595,2 a 3600 MHz, referencia 19,2 MHz. Configuración inicial `L = 0x21`, `alpha = 0x5555`, `CONFIG_CTL = 0x08200800`, `CONFIG_CTL_U = 0x05022001`, `CONFIG_CTL_U1 = 0x00000010`, `USER_CTL = 0x01000101`; el comentario del código la llama **"640MHz configuration"**: es el OPP de 320 MHz | `gpucc-khaje.c:56-95`; `.ko`: `gpu_cc_pll0_config`, `zonda_vco` |

`USER_CTL = 0x01000101` lleva el bit 8 a 1: `OUT_MAIN = VCO / 2`. El driver de iOS escribe ese mismo
valor (G625) y el mismo `CFG = 0x101` (G710). Dos comprobaciones internas de que el divisor es real: el
OPP más bajo, 320 MHz, con el VCO igual al OPP quedaría por debajo del mínimo del Zonda (595,2 MHz); y los
límites de voltaje del PLL están dados para VCO de 1800 a 3600 MHz (§4.3), el doble del rango de OPP.

Para el OPP máximo: **VCO = 2520 MHz → OUT_MAIN = 1260 MHz → RCG ÷1 → `gx_gfx3d` = 1260 MHz.** El mismo
contador de §3 leería 1260 MHz en Android en ese nivel.

### 4.2 L y alpha

`clk_zonda_pll_set_rate()` (`clk-alpha-pll.c:2583-2626`): `L = ⌊f/19,2⌋`, `alpha = ⌊resto × 2¹⁶ / 19,2⌋`
(`alpha_pll_round_rate`, `:578-600`), y si el bit 15 de alpha está a 1, L se redondea al entero más
cercano (`zonda_pll_adjust_l_val`, `:564-575`): alpha es entonces una fracción negativa. El desensamblado
de `clk_zonda_pll_set_rate` en el `clk-qcom.ko` del teléfono hace lo mismo (0x7130-0x71f4) y espera el bit
de bloqueo 29 o el 31 según `TEST_CTL` bit 16 (0x7240-0x7278).

Con esa regla, lo que escribe hoy iOS para `gpu_mhz=1260`, `L = 66` y `alpha = 0xa000` (G599, ring:
`gpucc_pll0_l 00000042`), es un VCO de (66 − 1 + 0,625) × 19,2 = **1260,0 MHz**. La tabla de 0161 (G595-598)
es la de `set_rate` aplicada al OPP en lugar de a su doble.

### 4.3 OPP, VCO y niveles de raíl

Niveles de `gpu_cc_gx_gfx3d_clk_src` (clase `vdd_cx`, tabla `vdd_l2_corner`) y de `gpu_cc_pll0` (clase
`vdd_mx`, tabla `vdd_corner`): `gpucc-khaje.c:247-258` y `:85-93`, `vdd-level-bengal.h`; en el `.ko`,
`rate_max` = `[0, 0, 320, 465, 600, 785, 0, 1025, 1114,8, 1260] MHz` con `vdd_l2_corner = (0, 48, 64, 128,
192, 256, 320, 384, 416, 464)`, y `[0, 0, 1800, 2400, 0, 3000, 0, 3600, 0] MHz` con `vdd_corner = (0, 48,
64, 128, 192, 256, 320, 384, 416)`. El nivel es el más bajo cuyo `rate_max` cubre la frecuencia
(`vdd-class.c:224-246`). VDD_CX es `pm6125_s3_level`, recurso RPM `rwcx` 0; VDD_MX es `pm6125_s5_level`,
`rwmx` 0; clave `vlvl` (DT:3802-3809, 3857-3864; `rpm-smd-regulator.c:150`). No hay raíl GX aparte: los
dos GDSC de la GPU cuelgan de VDD_CX (DT:8508-8530).

| Núcleo (MHz) | Nivel del DT, bin 0 | VCO (MHz) | L | alpha | VDD_CX | VDD_MX (PLL) | Bus kgsl → DDR |
|---|---|---|---|---|---|---|---|
| 320 | 6 (inicial) | 640 | 33 | 0x5555 | 64 LOW_SVS | 64 | 2 → 547 MHz |
| 465 | 5 | 930 | 48 | 0x7000 | 128 SVS | 64 | 3 → 768 |
| 600 | 4 | 1200 | 63 | 0x8000 | 192 SVS_PLUS | 64 | 4 → 1017 |
| 785 | 3 | 1570 | 82 | 0xc555 | 256 NOM | 64 | 5 → 1555 |
| 820 | — | 1640 | 85 | 0x6aaa | 384 TURBO | 64 | — |
| 980 | — | 1960 | 102 | 0x1555 | 384 TURBO | 128 | — |
| 1025 | 2 | 2050 | 107 | 0xc555 | 384 TURBO | 128 | 6 → 1804 |
| 1100 | — | 2200 | 115 | 0x9555 | 416 TURBO_NO_CPR | 128 | — |
| 1114,8 | 1 | 2229,6 | 116 | 0x2000 | 416 TURBO_NO_CPR | 128 | 7 → 2092 |
| **1260** | **0** | **2520** | **131** | **0x4000** | **464 SUPER_TURBO** | **256 NOM** | **7 → 2092** |

820, 980 y 1100 MHz están en la tabla del driver de relojes pero ningún nivel del DT de este teléfono los
usa. `qcom,level` del DT (0x1a0 para 1260 y para 1114,8, DT:8071-8080) es el nivel que una GPU con GMU
manda al RPMh (`kgsl_pwrctrl.h:73-74`); en el A610, sin GMU, kgsl solo llama a `clk_set_rate` y el voto de
voltaje lo hace la clase `vdd` del reloj. 0204 tomó `qcom,level`.

### 4.4 Speed bin

El DT trae cinco tablas (DT:8058-8420), elegidas por el fusible `gpu_speed_bin` (QFPROM 0x1b40000 +
0x6006, 2 bytes, bits 5-12; DT:6727, 6757-6767; kgsl `adreno.c:805-806`, `:947`):

| Fusible | OPP máximo | Niveles |
|---|---|---|
| 0 | 1260 MHz | 320, 465, 600, 785, 1025, 1114,8, 1260 |
| 235 | 1114,8 MHz | hasta 1114,8 |
| 216 | 1025 MHz | hasta 1025 |
| 157, 127 | 745, 600 MHz | tablas heredadas de bengal |

**Sin leer: el fusible de esta unidad.** El LUT de cpufreq del teléfono llega a 2803,2 MHz en el cluster
gold (§12), que es el SM6225-AD (Snapdragon 685), y lo esperable es el bin 0 (H). 0337 lee el fusible, lo
escribe en el log y no pasa del máximo de su tabla salvo `gpu_anybin=1`.

### 4.5 Qué más hace kgsl al subir de nivel

- **Bus.** `icc_set_bw(MASTER_GRAPHICS_3D → SLAVE_EBI, ab, ib)` con `ib = qcom,bus-table-ddr[nivel]`
  (kgsl `adreno.c:3277-3295`; DT:7953, 7956). La tabla, en kBps: 0, 1 562 500, 4 273 437, 6 000 000,
  7 945 312, 12 148 437, 14 093 750, 16 343 750: cada entrada es el 97,7 % de 8 bytes por ciclo de uno de
  los niveles del DDR (200, 547, 768, 1017, 1555, 1804, 2092 MHz, DT:7648-7649). En 1260 y en 1114,8 MHz
  el voto es fijo en el nivel 7: **todo el DDR, a 2092 MHz**.
- **Corriente de pico de CX.** `qcom,gpu-cx-ipeak` (DT:7976-7989): antes de cruzar 900 MHz vota el cliente
  1 de `cx_ipeak@3ed000`, y antes de 950 MHz el cliente 10 (`kgsl_pwrctrl.c:333-364` de 4.19, con el
  comentario "Hardware damage is possible at peak current if mitigation not done to limit peak power";
  `cx_ipeak.c:288-336`). La cámara es el cliente 8 (DT:11608).
- **Escalado.** `msm-adreno-tz` mueve la GPU entre niveles; arranca en el 6 (320 MHz) y solo está en los
  altos mientras hay carga. Los votos de voltaje, de bus y de corriente de pico bajan con ella.

## 5. Lo que programa iOS

Secuencia de `power_up()` (G657-722), con los valores del ring de un arranque con los boot-args actuales:

| Paso | Registro / acción | Valor leído | Línea |
|---|---|---|---|
| GPLL0 a la GPU | GCC 0x79004 bit 15 | 0x00c05d5b → 0x00c0dd5b | G666 |
| Ramas de bus | `gcc_bimc_gpu_axi` 0x71154, `gcc_gpu_memnoc_gfx` 0x3600c, `gcc_gpu_snoc_dvm_gfx` 0x36018 | en marcha | G669-671 |
| GDSC CX | GPUCC 0x106c, estado en 0x1540 | `PWR_ON` | G673 |
| `gpu_cc_cxo`, `gpu_cc_ahb` | 0x109c, 0x1078 | en marcha | G676-677 |
| GMU | RCG 0x1120 = GPLL0/3 (200 MHz), rama 0x1098 con retardos 0xff0 | `cfg 00000505` | G681-684 |
| Voto del SMMU | 0x5000 | en marcha | G685 |
| GDSC GX | 0x100c, reset 0x1008, clamp 0x1508 | `PWR_ON` | G692 |
| Raíl CX | RPM `rwcx` 0 `vlvl` = 0x1a0 si `gpu_mhz` > 1025, 0x180 si ≥ 980 | `: 0` (aceptado) | G699-708 |
| PLL | `L = 66`, `alpha = 0xa000`, `CONFIG_CTL` 0x08200800 / 0x05022001 / 0x10, `USER_CTL = 0x01000101` y luego `\|= 0xf` | `mode e0000007`, `l 00000042` | G609-641 |
| RCG del núcleo | 0x101c: fuente 1 (`OUT_MAIN`), divisor 1 | `cfg 00000101` | G710 |
| Rama del núcleo | 0x1054, con `FORCE_MEM_CORE` y `FORCE_MEM_PERIPH` | `00006221` | G714-716 |
| `gpu_cc_gx_cxo` | 0x1060 | en marcha | G717 |

Las ramas, los GDSC y el orden son los de Android (mismas ramas que la lista `clocks` del DT:7957-7958;
`gpucc-khaje.c:466-483` para el GMU y `gx_cxo`). No hay voto de VDD_MX, ni de bus, ni de corriente de
pico. La GPU se enciende una vez y se queda a esa frecuencia (no hay escalado ni apagado en reposo). El
texto del log `(GPLL0/1 = 600 MHz)` de `rcg_set` (G651) y el de la primera línea (G2505) se imprimen
también cuando la fuente es el PLL.

Frecuencia real del núcleo según el boot-arg, con el kernel a 0335:

| Boot-args | VCO | Núcleo |
|---|---|---|
| `gpu_div=2` | — (GPLL0) | 300 MHz |
| `gpu_div=1` | — (GPLL0) | 600 MHz |
| `gpu_mhz=785` | 785 | 392,5 MHz |
| `gpu_mhz=820` | 820 | 410 MHz |
| `gpu_mhz=980` | 980 | 490 MHz |
| `gpu_mhz=1025` | 1025 | 512,5 MHz |
| `gpu_mhz=1100` | 1100 | 550 MHz |
| `gpu_mhz=1260` | 1260 | **630 MHz** (medido) |

Todos los valores de `gpu_mhz` menos 1260 dejan la GPU **más lenta** que `gpu_div=1`.

## 6. Tabla: Android (DT + kgsl + relojes) frente a iOS

| Parámetro | Android, nivel máximo | iOS (0335, boot-args actuales) | ¿Igual? |
|---|---|---|---|
| Reloj del núcleo `gx_gfx3d` | 1260 MHz (bin 0) | **630 MHz** (medido) | **No** |
| VCO de `gpu_cc_pll0` | 2520 MHz, L 131, alpha 0x4000 | 1260 MHz, L 66, alpha 0xa000 | **No** |
| `USER_CTL` del PLL (posdivisor) | 0x01000101 \| 0xf: ÷2 | 0x01000101 \| 0xf: ÷2 | Sí |
| `CONFIG_CTL`, `_U`, `_U1` | 0x08200800, 0x05022001, 0x10 | los mismos | Sí |
| RCG `gx_gfx3d` | fuente 1, ÷1 (`CFG 0x101`) | `CFG 0x101` | Sí |
| VDD_CX (`rwcx` 0) | 464 para 1260; 416 para 1114,8 | 416 (0x1a0) | **No** para 1260 |
| VDD_MX (`rwmx` 0) | ≥ 256 con el VCO a 2520 | sin voto | **No** |
| Corriente de pico de CX | votos de los clientes 1 y 10 desde 900 y 950 MHz | sin votos | **No** (irrelevante a 630 MHz) |
| Reloj del GMU | GPLL0/3 = 200 MHz, retardos 0xf/0xf | igual | Sí |
| Ramas GCC y GPUCC, GDSC CX y GX | DT:7957-7958, 8508-8530 | las mismas | Sí |
| Voto de bus GPU → DDR | `ib` = 16,3 GB/s (nivel 7) | ninguno | **No** |
| Frecuencia del DDR | 2092 MHz fijo en los dos niveles altos; por debajo, `gpubw_mon`, `bwmon` y `memlat` | la que dejó el arranque (sin medir) | **¿?** |
| Escalado de relojes del RPM | activado por `clk-smd-rpm` tras votar el máximo | nunca activado | **No** |
| QoS del puerto de la GPU en el BIMC | fijo, prioridad 0 (la más baja), BKE activo | sin programar | No (sin efecto negativo) |
| Clock gating por hardware | tabla `a612_hwcg` + `RBBM_CLOCK_CNTL = 0xaaa8aa82` | sin programar (apagado) | **No** (consumo) |
| Acceso mínimo (`min-access-length`) | 64 bytes en `RB/TPL1/SP_NC_MODE_CNTL` y `UCHE_MODE_CNTL` | sin programar (32 bytes) | **No** |
| Resto de `hw_init` (GBIF QoS, UCHE, ROQ, pool, prim fifo…) | §11 | igual | Sí |
| Registros "mágicos" del a610 (`RB_CCU_CNTL`, `RB_DBG_ECO_CNTL`…) | Mesa `freedreno_devices.py:438-466` | iguales en el blitter del kernel (G1459-1481) | Sí |
| Gestión de frecuencia y temperatura | `msm-adreno-tz`, límites térmicos, 320 MHz en reposo | frecuencia fija, GPU siempre encendida | **No** |
| CPU | gold hasta 2803,2 MHz, silver hasta 1900,8, con `schedutil` | las dos fijas al máximo | Sí (al máximo) |

## 7. Diferencias por impacto probable

| # | Diferencia | Evidencia | Cambio propuesto | Experimento que la decide |
|---|---|---|---|---|
| 1 | Núcleo a 630 MHz en vez de 1260 | **Medida** (§3) | 0337: VCO al doble (§8) | Escalera de §8: `gxfreq` debe dar la frecuencia pedida; tiempo de la pasada principal del driver frente a frecuencia |
| 2 | VDD_CX a 416 donde Android pone 464 para 1260 MHz | `.ko` del teléfono (§4.3) | 0337: `rwcx` 0 = 464 antes del reloj | Estabilidad a 1260 MHz reales con 464 frente a `gpu_cx=416` |
| 3 | Sin voto de VDD_MX para el PLL | `.ko` (§4.3) | 0337: `rwmx` 0 = 416 | Que el PLL bloquee a 2520 MHz (línea `gpu_cc_pll0 locked`) |
| 4 | Sin votos de corriente de pico desde 900 MHz | DT y kgsl (§4.5) | 0337: clientes 1 y 10 de `cx_ipeak` | Líneas `cx_ipeak: vote … taken` en el log; estabilidad con el módem transmitiendo |
| 5 | Frecuencia del DDR desconocida, sin votos y sin escalado del RPM | §10 | Medir primero (§10.2). Si no está al máximo: el traspaso de `clk-smd-rpm` (voto máximo en todos los relojes del RPM y después activar el escalado) | Periodo del reloj del DDR; `membw` en 4 hilos |
| 6 | Sin gestión de temperatura ni escalado a 1260 MHz reales | §4.5, §5 | Fuera de 0337. Un gobernador mínimo (≤ 820 MHz en reposo) | Temperatura y estabilidad en la escalera |
| 7 | Acceso mínimo de 32 bytes en vez de 64 | §11 | Poner el bit de 64 bytes en los cuatro registros, tras boot-arg | Tiempo de una pasada limitada por memoria (sysmem a pantalla completa), con y sin |
| 8 | Clock gating por hardware apagado | §11 | Tabla `a612_hwcg`, tras boot-arg | Temperatura; con gating los contadores always-count dejan de valer en reposo |
| 9 | Contadores de rendimiento apagados | §11 | `RBBM_PERFCTR_CNTL = 1`, `CP_PERFCTR_CP_SEL_0 = 0` en `hw_init_regs` | — (instrumentación) |
| 10 | Memoria de la GPU mapeada write-combined en los programas | §10.4 | Del driver (09, 10) | — |

## 8. Parche 0337

`xnu/patches/0337-sapphire-gpu-pll-vco.patch` (sha256 `39873905…`,
un archivo, +369 −4). `git apply --check` pasa sobre el árbol a 0335 + 0336 (`xnu-0336/`) y sobre 0335
solo (`xnu/`); ninguno de sus hunks toca los de 0336. Lo nuevo se ha compilado y ejecutado en el anfitrión
contra registros simulados (`parche/work/harness.cpp`: L y alpha de los diez OPP, lectura de vuelta, tope
por bin, voto rechazado, PLL sin bloqueo, corriente de pico con y sin *danger*). No está compilado dentro
de xnu: eso lo hace el CI.

**Elección de interfaz.** `gpu_vco2=1` hace que `gpu_mhz` sea la frecuencia del núcleo. Por defecto vale
0 y no cambia nada: una imagen con la cmdline actual sigue a 630 MHz al actualizar el kernel, y el
comportamiento antiguo y el nuevo se comparan con el mismo kernel. Cuando la escalera fije el OPP estable,
cambiar el valor por defecto es una línea. `gpu_mhz=1260 gpu_vco2=1` deja la cmdline de expG en 573
caracteres (límite 575).

Con `gpu_vco2=1`:

1. `gpu_mhz` tiene que ser una fila de la tabla de stock: 320, 465, 600, 785, 820, 980, 1025, 1100,
   1114 (= 1114,8) o 1260. Si no, sigue la ruta antigua.
2. Lee el speed bin (QFPROM) y no pasa del máximo de su tabla (§4.4). `gpu_bin=N` da el bin sin leer el
   fusible; `gpu_anybin=1` quita el tope.
3. Desde 900 MHz vota la corriente de pico como `cx_ipeak_update_v2`: clientes 1 (≥ 900) y 10 (≥ 950),
   salvo función desactivada o cliente en bypass; si el registro de *danger* no queda a 0 en 50 ms, retira
   los votos y usa 820 MHz. `gpu_ipeak=0` los omite.
4. **Antes del reloj**, los raíles: `rwcx` 0 al nivel de stock para la frecuencia, nunca por debajo de
   0x1a0 (lo que 0204 vota hoy); `rwmx` 0 a 0x1a0. El suelo existe porque iOS tiene un único votante y
   Android suma los de todos los consumidores del raíl: bajar el voto de APSS a 256 para 785 MHz podría
   dejar corto a otro bloque. `gpu_cx=N` y `gpu_mx=N` fijan los niveles (0 = sin voto).
5. Configura y arranca el PLL en el orden de `clk_zonda_pll_configure()` y `clk_zonda_pll_enable()`, con L
   y alpha de §4.3 para el doble del OPP, y espera el bit de bloqueo que espera stock.
6. RCG en fuente 1, divisor 1, como antes.

Un voto rechazado, una frecuencia fuera de tabla o un PLL que no bloquea dejan todo a la ruta antigua
(`gpu_mhz` como VCO y después `gpu_div`).

**Log de arranque** (lo nuevo, para `gpu_mhz=1260 gpu_vco2=1`):

    SapphireGpu: gpu_mhz=1260 gpu_vco2=1: gpu_mhz is the core clock; the PLL's VCO runs at twice that, as the stock driver sets it
    SapphireGpu:   speed bin fuse 0 (QFPROM 6004: ........), gaming bin . (602c: ........)
    SapphireGpu:   cx_ipeak: vote for 900000 kHz and above (client register 2000): danger 00000000: taken
    SapphireGpu:   cx_ipeak: vote for 950000 kHz and above (client register e000): danger 00000000: taken
    SapphireGpu:   CX rail (RPM rwcx 0) to level 464 for a 1260000 kHz core clock (the stock driver votes 464): 0
    SapphireGpu:   MX rail (RPM rwmx 0) to level 416 for a 2520000 kHz VCO (the stock driver votes 256): 0
    SapphireGpu: gpu_cc_pll0 locked: VCO 2520000 kHz (l 131 alpha 4000), USER_CTL 0100010f: OUT_MAIN = VCO / 2 = 1260000 kHz
    SapphireGpu:   gx_gfx3d_clk_src src 1 div 1 (gpu_cc_pll0 OUT_MAIN / 1; OUT_MAIN = VCO / 2): cmd 00000000 cfg 00000101 updated
    SapphireGpu: *** core clock: gx_gfx3d 1260000 kHz from gpu_cc_pll0 OUT_MAIN; gpu_cc_pll0 mode e0000007 l 131 alpha 4000 user_ctl 0100010f … ***

Sin `gpu_vco2`, la última línea dice `gx_gfx3d 630000 kHz` y antes aparece `gpu_mhz=1260 without gpu_vco2=1
is the PLL's VCO: the core clock is half of it, 630.0 MHz`. Los volcados `--- clock tree` incluyen
`gpucc_pll0_alpha` y `gpucc_pll0_user_ctl`.

**`sysctl kern.sweet_gpu_pll`** (solo lectura): la misma línea `gx_gfx3d … kHz from …` calculada de los
registros en el momento de la lectura: `MODE`, `L`, `alpha`, `USER_CTL`, `OPMODE`, `TEST_CTL`, los tres
`CONFIG_CTL`, el RCG (`cmd`, `cfg`, fuente, divisor), la rama, los votos de `rwcx`/`rwmx` hechos por el
driver, el speed bin y los boot-args. Es un cálculo a partir de registros; la medición sigue siendo
`gxfreq`.

**Escalera.** Una imagen por paso (`repack-boot.py --set gpu_vco2=1 --set gpu_mhz=N`), y en cada una:
el log de arriba, `gxfreq 200 5` (debe dar N, n ≥ 3), `sysctl kern.sweet_gpu_pll`, y el tiempo de la
pasada principal con `metal_fps=1` durante la misma animación.

| Paso | `gpu_mhz` | VCO | VDD_CX votado (stock) | VDD_MX | Votos de pico |
|---|---|---|---|---|---|
| 0 (control) | 1260 sin `gpu_vco2` | 1260 | 416 | — | — |
| 1 | 785 | 1570 | 416 (256) | 416 | — |
| 2 | 820 | 1640 | 416 (384) | 416 | — |
| 3 | 980 | 1960 | 416 (384) | 416 | 1 y 10 |
| 4 | 1025 | 2050 | 416 (384) | 416 | 1 y 10 |
| 5 | 1114 | 2229,6 | 416 (416) | 416 | 1 y 10 |
| 6 | 1260 | 2520 | 464 (464) | 416 | 1 y 10 |

Predicción si la pasada principal va al ritmo del reloj (H de §9): 18-24 ms × 630 / N. Si el tiempo deja
de bajar a partir de un paso, lo que limita desde ahí no es el reloj.

**Riesgos de la escalera.**
- Nada gestiona la temperatura y el reloj no baja en reposo: Android solo sostiene 1260 MHz, 464 y los
  votos de pico mientras hay carga. Vigilar la temperatura y no dejar el teléfono en los pasos 5-6 sin
  atención.
- El paso 6 usa un nivel de VDD_CX (464) que iOS no ha pedido nunca; el RPM puede rechazarlo (el parche
  cae a la ruta antigua y lo dice).
- Los votos de pico quedan puestos de forma permanente; si el módem los tiene en cuenta puede recortar su
  potencia máxima de transmisión mientras estén (H, sin fuente del lado del módem).
- La lectura del fusible y los registros de `cx_ipeak` son MMIO que iOS no ha tocado antes; Android los
  lee y escribe desde EL1. `gpu_bin=0` y `gpu_ipeak=0` evitan cada uno.

## 9. La pasada principal del compositor: cuánto debería tardar

**O (03 M2).** Destino 750×1624, 108-132 draws (quads texturizados con alfa), GMEM en 102 tiles: 18-24 ms
de GPU por pasada.

Aritmética de esa pasada:

- 750×1624 = 1,218 Mpx; 102 tiles = 6×17 bins de 128×96 = 12 288 px (alineación de bin del a610: 32×16,
  `freedreno_devices.py:444-445`). El GMEM del a610 son 132 KB (`a6xx_catalog.c:683`).
- 18-24 ms / 102 = 176-235 µs por tile. Por draw y tile: 18,21 ms / (108 × 102) = 1,65 µs;
  23,16 / (112 × 102) = 2,03; 22,06 / (132 × 102) = 1,64; 21,62 / (99 × 102) = 2,14. A 630 MHz son
  1000-1400 ciclos de reloj por draw y tile.
- Memoria que mueve: resolve de 1,218 Mpx × 4 B = 4,9 MB; texturas, del orden de 4 B por fragmento, 10-20 MB
  con 2-4 pantallas de sobredibujado. Menos de 25 MB por pasada: **1,0-1,4 GB/s** durante la pasada.
- Lo que da el DDR: 8 bytes por ciclo, 16,7 GB/s a 2092 MHz, 8,1 a 1017, 4,4 a 547 (la tabla de bus de
  kgsl es exactamente eso, §4.5). El escaneo del panel a 120 Hz (1080×2400×4 B) son 1,24 GB/s.

Lectura (H, salvo la aritmética):

1. **No es ancho de banda de memoria.** La pasada usa menos del 10 % del DDR a 2092 MHz y menos de un
   tercio a 547 MHz. Una sola CPU copiando (`membw`, 1,5-2,5 GB/s de copia = 3-5 GB/s de tráfico) mueve
   más bytes por segundo que la GPU en esta pasada.
2. **Tampoco es fill rate.** Con la cifra heredada del blitter en este teléfono (una capa mezclada a
   pantalla completa a 3x, 2,74 Mpx, en 2,4 ms con tiles = 1,14 Gpx/s, que con el reloj medido son 1,8
   píxeles por ciclo), 2-4 pantallas de fragmentos a 750×1624 son 2-4 ms de los 18-24.
3. **Lo que queda, 14-20 ms, es coste por tile**: reproducir el flujo de draws y su estado en cada uno de
   los 102 bins, más restore y resolve. Es trabajo del CP y de la geometría, que va al ritmo del reloj del
   núcleo. Por eso la cifra es compatible con las dos cosas a la vez: una GPU a medio reloj (factor 2) y
   un coste por tile alto (el resto, del driver: 09 y 10).
4. **A 1260 MHz reales: 9-12 ms** si el punto 3 es cierto. Sigue por encima de 8,33 ms (120 Hz) y entra
   en 16,7 ms (60 Hz). Android no reproduce 108 draws en 102 bins para una interfaz: su driver usa
   flujos de visibilidad por bin o render directo, y además corre al doble de reloj.

Lo que distingue las lecturas sin tocar el driver: el tiempo de la misma pasada a 300 MHz (`gpu_div=2`),
600 MHz (`gpu_div=1`) y 630 MHz (`gpu_mhz=1260`) con el kernel actual, y en los pasos de la escalera de
§8. Proporcional a 1/f: reloj. Plano: memoria.

## 10. Bus, DDR y memoria

### 10.1 Qué hace Android

- **Relojes del RPM** (khaje usa los de holi, `clk-smd-rpm.c:1121-1227`): `bimc_clk` = `clk2` 0 (el DDR),
  `cnoc` = `clk1` 1, `snoc` = `clk1` 2, `mmnrt`/`mmrt` = `mmxi` 0/1, QUP, IPA, CE; clave `KHz`. En el
  arranque vota el BIMC a `INT_MAX` (`:1397-1401`) y **activa el escalado de relojes del RPM**
  (`clk_smd_rpm_enable_scaling`, clave `Enab`, `:1418`). Linux v6.12 hace el mismo traspaso
  (`clk-smd-rpm.c:189-210`, `:402-428`, `:1278-1306`) y comenta que los relojes de bus dejarían de estar
  sostenidos entre activar el escalado y el arranque del driver de interconexión (`:177-181`): hasta que
  el sistema operativo activa el escalado, el RPM no baja esos relojes.
- **Plan del DDR** (DT:7648-7649): 200, 547, 768, 1017, 1555, 1804 y **2092 MHz**.
- **Quién mueve el DDR**: `bwmon` (monitor de tráfico CPU → DDR en 0x1b8e200, DT:7676-7686), `memlat`
  (fallos de caché por cluster; con el gold a 2803,2 MHz pide 2092 MHz, DT:7688-7727), kgsl (§4.5) y la
  pantalla (mínimo 1,6 GB/s, DT:15246).
- **QoS del BIMC**: el puerto de la GPU queda en modo fijo con prioridad 0 y BKE activo
  (`interconnect/qcom/bengal.c:127-135`), la misma que las CPU (`:34-41`).

### 10.2 Qué hay en iOS

- `power_up` solo enciende ramas (§5). No hay votos de bus ni de DDR en el arranque.
- `topaz_rpm_vote` (`TopazModem.cpp:11278`) y `kern.sweet_audio` op 6 (`:12972-12986`) permiten votar a
  mano `clk2`, `clk1`, `clk0` y otros. Nada activa el escalado (`clk0`, `Enab`) en el arranque.
- **H.** Con el escalado apagado, los relojes de bus y el DDR están en el nivel en que los dejó el
  arranque, y un voto suelto no cambia nada. Es coherente con lo anotado en las descripciones de 0203 y
  0204 (votar el BIMC "is taken and changes nothing"; `memcpy` 2,1-2,5 GB/s con y sin votos) y con el
  traspaso de Linux. **Cuál es ese nivel no está medido.**

**Cómo medirlo.** El periodo del reloj del DDR está en un registro: bloque `mccc` 0x447d200, desplazamiento
0x20, en picosegundos (`debugcc-khaje.c:440-448` y `mccc_debug` DT:6311-6315; `clk-debug.c:466-475`:
`f = 10¹² / periodo`). Es una lectura de MMIO sin efecto, que hoy no tiene ruta desde el espacio de
usuario; cabe en un parche de diagnóstico de una línea de log. Los demás relojes (el de la rama
`gcc_bimc_gpu_axi`, selector 0x97 del multiplexor de depuración de GCC; `gcc_gpu_memnoc_gfx`, 0xee; los
de CPU, 0xb6) se miden con el contador de `clk_measure` (`clk-debug.c:91-190`, `debugcc-khaje.c:22-26,
360-455`).

Sin parche, una cota inferior: `userland/tests/membw` en 4 procesos a la vez con QoS de interfaz. Si la
suma de copias es S, el tráfico es al menos 2 S, y el DDR está al menos en el nivel cuyo 8 B × f lo cubre
(4,4 GB/s a 547 MHz, 8,1 a 1017, 12,4 a 1555, 16,7 a 2092).

### 10.3 El `memcpy` de 1,5 GB/s

Cifras heredadas, de un solo hilo y 64 MB (`userland/tests/membw.c`): 1,7 GB/s (0202), 2,1-2,5 (0203,
0204), 1,5 (NOTES, 27 de octubre), 12,6 GB/s dentro de caché.

- Un hilo no mide el DDR. Un A73 a 2,8 GHz copiando fuera de caché da del orden de 2,5-5 GB/s con el
  DDR sobrado; 2,1-2,5 está en la parte baja de ese rango y no dice a qué frecuencia va el DDR más allá
  de que cubre 4-5 GB/s de tráfico (≥ 547 MHz).
- 1,5 GB/s es lo que da un A53. `membw` corre con QoS por defecto, y con `sweetsched` con el bit 2
  (`sweetsched=15` lo lleva) el QoS por defecto prefiere el cluster de eficiencia (§12). En el kernel de
  esa fecha `sweetsched` no existía; la cifra pudo salir con el sistema ocupado. Sin dato para decidirlo.
- Para comparar hay que fijar el cluster (`pthread_set_qos_class_self_np`, como hace `cpufreq.c`) y
  repetir (n ≥ 3).

### 10.4 Memoria de la GPU vista desde la CPU

Los buffers del cliente msm salen del gigabyte 0x1_0000_0000-0x1_4000_0000 y se mapean **write-combined**
en el programa (G3255-3285, G3722; `MAIR_EL1` del teléfono: índice 1 = 0x44, memoria normal sin caché).
Para la GPU es lo mismo que en Linux (`MSM_BO_WC`). Para la CPU, cada lectura de esos buffers va al DDR
sin caché: copiar **desde** un buffer de la GPU o leer-modificar-escribir sobre él es órdenes de magnitud
más lento que en memoria normal. Qué rutas del driver leen de esos buffers es de 09 y 10.

## 11. `hw_init` registro a registro

`hw_init_regs()` (G1210-1245) frente a Linux `a6xx_gpu.c` `hw_init` (v6.12, `:861-1040`) y kgsl
`a6xx_start` (5.x, `adreno_a6xx.c:556-840`; núcleo a610 en `adreno-gpulist.h:1499-1518`).

| Registro | Linux / kgsl para a610 | iOS | |
|---|---|---|---|
| `GBIF_HALT` 0x3c45, `RBBM_GBIF_HALT` 0x16 | 0 | 0 | = |
| `RBBM_SECVID_TSB_*` | 0 | 0 | = |
| `*_ADDR_MODE_CNTL` (12) | 1 | 1 | = |
| `GBIF_QSB_SIDE0..3` 0x3c03-06 | 0x00071620 | 0x00071620 | = |
| `RBBM_GBIF_CLIENT_QOS_CNTL` 0x11 | 3 | 3 | = |
| `UCHE_WRITE_RANGE_MAX`, `TRAP_BASE`, `WRITE_THRU_BASE` | 0x1ffffffffffc0, 0x1fffffffff000 ×2 | iguales | = |
| `UCHE_GMEM_RANGE_MIN/MAX` | 0x100000, + 132 KB − 1 | iguales | = |
| `UCHE_FILTER_CNTL` 0xe18, `UCHE_CACHE_WAYS` 0xe17 | 0x804, 4 | 0x804, 4 | = |
| `CP_ROQ_THRESHOLDS_2/1` | 0x00800060, 0x40201b16 | iguales | = |
| `CP_MEM_POOL_SIZE` 0x8c3 | 48 | 48 | = |
| `CP_MEM_POOL_DBG_ADDR` 0x90e | 47 (`a6xx_gpu.c:993`, kgsl `:645`) | sin escribir | ≠ (efecto desconocido) |
| `PC_DBG_ECO_CNTL` 0x9e00 | 0x00080000 | 0x00080000 | = |
| `CP_AHB_CNTL` 0x98d | 1 | 1 | = |
| `RBBM_INTERFACE_HANG_INT_CNTL` 0x1f | 0x4003ffff | 0x4003ffff | = |
| `UCHE_CLIENT_PF` 0xe19 | 0x81 | 0x81 | = |
| `RBBM_PERFCTR_GPU_BUSY_MASKED` 0x50b | 0xffffffff | sin escribir | ≠ (solo estadística) |
| `RBBM_PERFCTR_CNTL` 0x500 | 1 | sin escribir | ≠ (contadores apagados) |
| `CP_PERFCTR_CP_SEL_0` 0x8d0 | `ALWAYS_COUNT` (Linux `:1019`) | sin escribir | ≠ |
| `RB_NC_MODE_CNTL` 0x8e08, `TPL1_NC_MODE_CNTL` 0xb604, `SP_NC_MODE_CNTL` 0xae02 | kgsl con el DT de este teléfono (`min-access-length` 64, `ubwc-mode` 1, bank bit 14): 0xb. Linux (bank bit 13): 0x9 | sin escribir (0) | ≠ |
| `UCHE_MODE_CNTL` 0xe01 | kgsl 0x00a00000; Linux 0x00800000 | sin escribir (0) | ≠ |
| Clock gating: 46 registros `RBBM_CLOCK_*` + `RBBM_CLOCK_CNTL` 0xae | tabla `a612_hwcg`, 0xaaa8aa82; kgsl además `UCHE_GBIF_GX_CONFIG[18:16] = 2` | sin escribir | ≠ (consumo) |
| `CP_PROTECT_*` | tabla `a630_protect` | sin escribir | ≠ (seguridad, no rendimiento) |
| `RBBM_INT_0_MASK` | interrupciones activas | 0: el kernel sondea | ≠ (09) |

De todo lo que falta, lo único que toca el acceso a memoria de la GPU es el bit de acceso mínimo de 64
bytes (bit 3 de los tres `NC_MODE_CNTL`, bit 23 de `UCHE_MODE_CNTL`): Android y Linux lo ponen en este
GPU, iOS lo deja en 32. **H:** efecto pequeño o nulo fuera de UBWC; se decide con un A/B. Mesa no lo
conoce (no está en `freedreno_dev_info.h`), así que cambiarlo no altera lo que el driver de usuario
calcula.

## 12. CPU

- **O.** `sweet_cpufreq_max()` (`bsd/dev/sweet_cpufreq.c`) recorre el LUT de cada dominio de
  `qcom,cpufreq-hw` (0xf521000 silver, 0xf523000 gold; LUT en +0x110, filas de 32 bytes, `PERF_STATE` en
  +0x920, como `qcom-cpufreq-hw.c`) y escribe el índice de mayor frecuencia. Ring: `gold perf state 8 -> 8
  (2803 MHz)`, `silver perf state 6 -> 6 (1900 MHz)` en 8 arranques de 8: el cargador ya las deja ahí.
  `hw.cpufrequency` = 2 803 200 000. Son los máximos del SM6225-AD (4 × 2,8 GHz + 4 × 1,9 GHz), y el
  mismo tope que usa `memlat` (DT:7709: 2 803 200 kHz).
- Nada las baja ni las limita: no hay cpufreq ni mitigación térmica en este kernel.
- **`sweetsched=15`** (`osfmk/kern/sched_clutch.c:4855-4929`): bit 1, QoS utility y background prefieren
  el cluster E; bit 2, **también el QoS por defecto**; bit 4, sin migración ni robo P → E; bit 8, un A73
  libre roba trabajo del cluster E. Con 15, todo hilo de QoS por defecto empieza en un A53 a 1,9 GHz
  salvo que un A73 libre lo robe. Qué hilos del camino de render tienen ese QoS es del plan 07.
- La frecuencia efectiva se mide con `userland/tests/cpufreq ui` y `cpufreq bg` (cadena de sumas
  dependientes).

## 13. Experimentos

| # | Qué | Predicción | Estado |
|---|---|---|---|
| X1 | `gxfreq` con `gpu_mhz=1260` | 630 MHz | **Hecho: 630,00 MHz, 15/15** (03 M3) |
| X2 | Escalera de 0337 (§8): `gxfreq`, `kern.sweet_gpu_pll`, tiempo de la pasada principal | `gxfreq` = N; tiempo ∝ 1/N si manda el reloj | Pendiente |
| X3 | Misma pasada con el kernel actual a 300, 600 y 630 MHz (`gpu_div=2`, `gpu_div=1`, `gpu_mhz=1260`) | ∝ 1/f | Pendiente |
| X4 | Periodo del reloj del DDR (0x447d220) | 478 ps si está a 2092 MHz | Pendiente (necesita parche de diagnóstico) |
| X5 | `membw` × 4 con QoS de interfaz | S ≥ 4 GB/s si el DDR está en los niveles altos | Pendiente |
| X6 | En Android (slot b, root): `gpu_available_frequencies` y `clock_mhz` de `/sys/class/kgsl/kgsl-3d0/`, y `clk_measure` de `gpu_cc_gx_gfx3d_clk` en debugfs con la GPU forzada al nivel 0 | tabla hasta 1260 MHz (bin 0); `clk_measure` ≈ 1 260 000 000 | Pendiente, opcional |
| X7 | A/B del bit de acceso mínimo de 64 bytes | diferencia solo en pasadas limitadas por memoria | Pendiente |

## 14. Afirmaciones heredadas

| Afirmación | Dónde | Veredicto |
|---|---|---|
| "`gpu_mhz=785/820/980/1025/1100/1260` starts gpu_cc_pll0 at the stock khaje OPP" | 0161, NOTES L524 | **Falsa.** Programa el VCO al valor del OPP; el núcleo va a la mitad (medido a 630 MHz con 1260) |
| "980 MHz was stable on this phone" | NOTES L524 | Eran 490 MHz |
| "A simple 13-draw frame still costs 6-8 ms of GPU … so it is bandwidth-bound more than clock-bound" | NOTES L524 | **Sin base.** El reloj no había subido |
| "the GPU is bound by memory bandwidth (~2.5 ms a full-screen pass at 3x …)" | NOTES L260-262 | **Sin base** (§9): la cifra equivale a 1,8 píxeles por ciclo de un reloj de 630 MHz |
| "a DDR vote of 1804.8 MHz … changes nothing: the DDR is already fast" | NOTES L261-262 | El voto no puede cambiar nada con el escalado del RPM apagado; "already fast" no está medido. El máximo del DDR es 2092 MHz, no 1804,8 |
| "The stock levels: 1025 MHz TURBO, 1114.8 and 1260 MHz TURBO_L1" | 0204 | **Incorrecto para 1260**: el driver de relojes pide 464, no 416. `qcom,level` no es lo que decide el voltaje en esta GPU |
| "VDD_GFX is not raised" | 0161, comentarios G250-263 | No hay VDD_GFX en este SoC: la GPU cuelga de VDD_CX (y el PLL, de VDD_MX) |
| "(GPLL0/1 = 600 MHz)" con `gpu_mhz` | log, G651 y G2505 | Texto engañoso; la fuente es el PLL |
| "an A73 on LPDDR4X at speed gets 6-8 [GB/s]" | 0202 | Sin fuente; optimista para un hilo |
| "the single A73 is the limit there, not the DDR" | 0204 | Plausible (H); un hilo no lo demuestra |

Los informes [09](09-auditoria-kernel-gpu.md) (§ energía y tabla final) y
[10](10-auditoria-rendimiento-hakios-metal.md) dan la GPU "a 1260 MHz": vale la frecuencia medida aquí.
