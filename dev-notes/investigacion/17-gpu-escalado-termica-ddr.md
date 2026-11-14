# 17 — GPU: escalado de frecuencia, temperatura y DDR

Diseño, código y verificación en anfitrión de los parches 0343, 0345, 0346, 0347 y 0348 (fuera del repo, en
`~/sapphire-angel/research/metal/relojes/parches-nuevos/`): medir relojes y temperaturas, cambiar el nivel de la GPU
en caliente, un gobernador por ocupación con tope térmico, el voto del DDR por nivel y el clock gating por hardware.
Informe del 14 de noviembre de 2026 sobre la serie `xnu/patches/` hasta 0342 (xnu-8796.141.3). Antecedentes:
[11](11-gpu-relojes-bus-vs-android.md) (cadena de relojes, raíles, `cx_ipeak`, DDR, 0337),
[09](09-auditoria-kernel-gpu.md) §5 (energía) y [03](03-experimentos-y-datos.md) M3, M4, M6, M7.

Convenciones: **O** = observación (medida o leída en una fuente primaria), **H** = hipótesis. **DT:N** = línea N de
`relojes/dtb/merged-khaje24a-sapphire.dts`. Fuentes de stock en `~/sapphire-angel/research/metal/relojes/ref/`:

| Clave | Qué | Dónde |
|---|---|---|
| **MI** | Kernel de Xiaomi `topaz-t-oss` @ `345999da` (msm-5.15, mismo SoC) | `ref/downstream/` (`gpucc-khaje.topaz-t-oss.c`, `drivers_clk_qcom_*.c`, `drivers_interconnect_qcom_*.c`) |
| **K5** | kgsl 5.x, CodeLinaro `graphics-kernel` @ `f900d903dbe93e6000b044a9a2c0aeb9b05abc26` | `ref/downstream/kgsl-5.x/` (procedencia en `README-procedencia.txt`) |
| **K4** | kgsl 4.19, MiCode `spes-r-oss` @ `88afd325` | `ref/downstream/kgsl-4.19-spes/` |
| **CLO** | CodeLinaro msm-5.15 `KERNEL.PLATFORM.2.0.r1-23300-kernel.0` @ `0ef8a265`, `drivers/thermal/qcom/` (el `msm-tsens-driver.ko` del teléfono corresponde a este código) | `ref/termica/` (procedencia en su `README.md`) |
| **L** | Linux v6.12 | `ref/linux/`, `ref/termica/` |

## 1. Resumen

1. **El kernel deja la GPU a una frecuencia y un voltaje fijos para siempre** (09 §5): ni escalado, ni temperatura,
   ni voto del DDR. Android sube a los niveles altos solo con carga, apaga los relojes de la GPU en cuanto se queda
   sin trabajo (NAP), la baja al nivel mínimo a los 80 ms (SLUMBER) y vota el bus por nivel; a 55 °C en la GPU no
   recorta nada por temperatura (§3.6).
2. **O (medido hoy, solo lectura). El DDR corre a 1555,2 MHz bajo iOS**, no a los 2092,8 MHz del máximo: periodo de
   643 ps en el registro de `mccc`, 7 lecturas de 7 (§4.3). Android lo fija en 2092,8 MHz mientras la GPU está en sus
   dos niveles altos.
3. **O (medido hoy). Temperaturas bajo iOS a 820 MHz fijos:** en calma (carga 1,1, pantalla quieta, driver Metal
   cargado) GPU 61,4-61,7 °C y CPU 64,8-67,5 °C, unos 20 °C por encima del reposo de Android (GPU 41-43, CPU 42-48);
   durante un relanzamiento de la interfaz con dos procesos ocupando núcleos, CPU hasta 82,2 °C y GPU 69,1 °C. El
   sensor de la GPU es el más frío del SoC en todas las lecturas (§4.2-4.4).
4. **El cambio de nivel de stock es un cambio del PLL solo** (O): las diez filas de la tabla del RCG son fuente 1
   divisor 1 y `gpu_cc_pll0` tiene `SUPPORTS_DYNAMIC_UPDATE`; `clk_zonda_pll_set_rate()` reescribe alpha y L con el
   PLL en marcha (§3.2). kgsl no para la GPU para cambiar de nivel.
5. **kgsl 5.x no vota `cx_ipeak`** (O: ningún archivo de K5 lo menciona; solo K4 lo hace). El `msm_kgsl.ko` del
   teléfono no está en disco, así que lo que hace el Android de este teléfono no está verificado. 0337 y 0345 votan
   como K4; con 0345/0346 los votos solo están puestos mientras la GPU está a 900 MHz o más.
6. **Parches** (todos inertes salvo que se escriba su sysctl o se pase su boot-arg; 0343 es solo lectura):

| Parche | Qué | Control |
|---|---|---|
| 0343 | Relojes medidos (GPU, buses, DDR, CPU), los 16 sensores TSENS | `kern.sweet_gpu_clocks`, `kern.sweet_ddr_khz`, `kern.sweet_thermal`, `kern.sweet_gpu_temp`; `gpu_clkdiag=1` |
| 0345 | Cambio de nivel en caliente, con votos y recuperación | `kern.sweet_gpu_khz`, `kern.sweet_gpu_opp`, `kern.sweet_gpu_opp_park`; `gpu_opp_drain`, `gpu_opp_park` |
| 0346 | Gobernador por ocupación con tope térmico | `kern.sweet_gpu_gov`, `_khz_max`, `_khz_min`, `_temp_max`, `_gov_ms/_up/_down/_idle_ms`, `_gov_stats`; `gpu_gov=1` |
| 0347 | Voto del BIMC (DDR) por nivel, con medición antes y después | `kern.sweet_gpu_ddr`, `_ddr_floor`, `_ddr_stats`; `gpu_ddr=1` |
| 0348 | Clock gating por hardware (`a612_hwcg`) | `kern.sweet_gpu_hwcg`; `gpu_hwcg=1` |

7. **Verificación en anfitrión:** los cinco arneses compilan el código real de los parches contra modelos de los
   registros y pasan (§10). El de 0345 comprueba en cada escritura de registro que el reloj del núcleo no supera lo que
   permite el nivel de CX votado. Apagar el reloj de la GPU entre frames (el NAP de kgsl) no está implementado: sin
   una disciplina de despertar en cada acceso a registros, un acceso olvidado cuelga el bus (§9).

## 2. Material y método

| Qué | Dónde (`~/sapphire-angel/research/metal/relojes/`) |
|---|---|
| Parches | `parches-nuevos/0343-*.patch` … `0348-*.patch`; 0343-0347 también en `xnu/patches/` |
| Generadores (aplican cada cambio sobre el fuente anterior) | `parches-nuevos/work/splice0343.py` … `splice0348.py`; cabeceras `hdr03NN.txt` |
| Construcción y comprobación | `parches-nuevos/work/build.sh` (genera fuentes y parches; los aplica en orden sobre una copia limpia del árbol a 0342 y compara con los fuentes probados), `verify.sh` (arneses y sintaxis) |
| Fuentes de cada paso | `parches-nuevos/work/SapphireGpu.0342.cpp` (base, sha256 `83dc20e2…`) … `SapphireGpu.0348.cpp` |
| Arneses | `parches-nuevos/work/harness0343.cpp` … `harness0348.cpp` y sus `.log` |
| Árbol a 0342 | `xnu-0342/` = `xnu-serie/` (0001-0338) + 0339-0342 de `xnu/patches/` con `git apply` |
| Lecturas del teléfono de este informe | `telefono/lecturas-20261114-1112.txt` |
| Lecturas de Android en este teléfono (coordinador) | `../android/` (`LEEME.md`, `estado-reposo.txt`, `serie-30s.txt`) |

Comprobaciones de cada parche: `git apply --check` y `git apply` en orden sobre una copia limpia del árbol a 0342
(el resultado es idéntico byte a byte al fuente que prueban los arneses); `clang++ -fsyntax-only` con los stubs de
`kernel-gpu/verificacion/` (`syn.sh`), 0 errores; una pasada con `-Wall -Wextra` comparada con la de 0342: ningún
aviso nuevo. Sha256 (prefijo): 0343 `4feb6e87`, 0345 `3eba0af7`, 0346 `49f965d9`, 0347 `0759a4ee`, 0348 `bdcb4e1a`.
El parche 0344 es de otro agente (planificador); no se ha comprobado si toca `SapphireGpu.cpp`.

## 3. Lo que hace Android en este teléfono

### 3.1 Niveles de stock (bin 0) con raíles, picos y bus

Niveles de `qcom,gpu-pwrlevels-0` (DT:8064-8140); el fusible de esta unidad es el bin 0 (O: `speed bin 0` en
`kern.sweet_gpu_pll`). VCO y L/alpha como los calcula `clk_zonda_pll_set_rate()`; VDD_CX por `rate_max` de
`gx_gfx3d_clk_src` y VDD_MX por el del PLL (MI `gpucc-khaje.topaz-t-oss.c:70-94, 234-258`); votos de `cx_ipeak` del
DT (DT:7976-7989: cliente 1 desde 900 MHz, cliente 10 desde 950 MHz; los lee K4, no K5); bus: `qcom,bus-freq` del
nivel → `qcom,bus-table-ddr` (DT:7953).

| Nivel | Núcleo (MHz) | VCO | L / alpha | CX stock | CX en iOS (suelo 0x1a0) | MX stock | Picos (K4) | bus-freq (mín-máx) | ib (kB/s) | BIMC (kHz = ib / 8) | DDR (MHz) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 1260 | 2520 | 131 / 0x4000 | 464 | 464 | 256 | 1 y 10 | 7 (7-7) | 16 343 750 | 2 042 969 | 2092,8 |
| 1 | 1114,8 | 2229,6 | 116 / 0x2000 | 416 | 416 | 128 | 1 y 10 | 7 (7-7) | 16 343 750 | 2 042 969 | 2092,8 |
| 2 | 1025 | 2050 | 107 / 0xc555 | 384 | 416 | 128 | 1 y 10 | 6 (5-7) | 14 093 750 | 1 761 719 | 1804,8 |
| 3 | 785 | 1570 | 82 / 0xc555 | 256 | 416 | 64 | — | 5 (4-5) | 12 148 437 | 1 518 555 | 1555,2 |
| 4 | 600 | 1200 | 63 / 0x8000 | 192 | 416 | 64 | — | 4 (3-5) | 7 945 312 | 993 164 | 1017,6 |
| 5 | 465 | 930 | 48 / 0x7000 | 128 | 416 | 64 | — | 3 (2-4) | 6 000 000 | 750 000 | 768 |
| 6 (inicial) | 320 | 640 | 33 / 0x5555 | 64 | 416 | 64 | — | 2 (1-2) | 4 273 437 | 534 180 | 547,2 |

- **BIMC:** kgsl vota `ib` = tabla[bus-freq] y `ab` = 25 % de `ib` (K5 `kgsl_bus.c:16-73`). `qcom_icc_rpm_set()`
  convierte el agregado en el reloj del BIMC: `max(suma de ab × util / canales, máximo de ib) / buswidth`, con el
  buswidth 8 del nodo `ebi` (el de `qnm_gpu` es 32 y da menos) (MI `drivers_interconnect_qcom_icc-rpm.c:108-176`,
  `drivers_interconnect_qcom_bengal.c:137-148, 672-680`), y `clk-smd-rpm` lo manda en kHz redondeando hacia arriba.
  Con `ab` al 25 % manda `ib`: `ib / 8`. El RPM toma la fila del plan que lo cubre (cada `ib` es el 97,7 % de 8 bytes
  por ciclo de una fila, 11 §4.5).
- 820, 980 y 1100 MHz están en la tabla del reloj pero en ningún nivel del DT.
- **CX/MX en iOS:** iOS es el único votante de APSS (Android suma todos sus consumidores), así que 0337 no baja de
  0x1a0. Con ese suelo CX solo cambia entre 1114,8 y 1260 MHz (416 ↔ 464) y MX queda en 416 siempre. Bajar de 416 es
  otro experimento (`gpu_cx=N`), no parte de estos parches.

### 3.2 Cómo cambia de nivel el driver de relojes de stock

1. kgsl pide la frecuencia con `clk_set_rate` sobre `core_clk` = `GPU_CC_GX_GFX3D_CLK` (K5 `kgsl_pwrctrl.c:244` →
   `adreno.c:3259-3275`; DT:7957-7958).
2. La rama y el RCG tienen `CLK_SET_RATE_PARENT`; el RCG usa `clk_rcg2_ops` (no las de "ping-pong" entre dos PLL de
   otros SoC) y sus diez filas son `F(f, P_GPU_CC_PLL0_OUT_MAIN, 1, 0, 0)`, así que el cambio sube hasta el PLL a
   través del posdivisor de solo lectura (÷2) (MI `gpucc-khaje.topaz-t-oss.c:102-118, 220-258`).
3. `clk_zonda_pll_set_rate()` (MI `drivers_clk_qcom_clk-alpha-pll.c:2583-2626`): L y alpha (L al entero más cercano
   si alpha tiene el bit 15, `:564-575`); escribe **alpha y luego L con el PLL en marcha**; si el PLL está encendido,
   5 µs, sondeo de `ZONDA_PLL_FREQ_LOCK_DET` (bit 29) si `TEST_CTL` tiene `ZONDA_STAY_IN_CFA` (bit 16) o de
   `PLL_LOCK_DET` (bit 31) si no (`wait_for_pll`, 100 lecturas a 1 µs, `:300-330`), y 100 µs "for PLL output to
   stabilize". No apaga la salida, no pasa por standby y no mueve el RCG.
4. Voltaje: `clk_pre_change_regmap()` vota el nivel nuevo antes si es más alto; `clk_post_change_regmap()` lo baja
   después si es más bajo (MI `drivers_clk_qcom_clk-regmap.c:106-181`). El RCG vota VDD_CX por frecuencia, el PLL
   VDD_MX por VCO.
5. kgsl, alrededor del reloj (K5 `kgsl_pwrctrl.c:204-284`): bus antes del reloj al subir, después al bajar
   (`:236-256`); nada espera a que la GPU esté ociosa; el candado es `device->mutex`. K4 vota además `cx_ipeak` antes
   de cruzar 900/950 MHz al subir y lo retira después al bajar (K4 `kgsl_pwrctrl.c:317-364, 615-624, 694-701`).

**O (teléfono):** `TEST_CTL` = 0x00000000 (sin `STAY_IN_CFA`), así que la actualización dinámica espera el bit 31 de
`MODE`; `MODE` = 0xe0000007 tiene los dos bits de enganche a 1 a 820 MHz.

### 3.3 Reposo en kgsl sin GMU

- **NAP**, en cuanto el despachador se queda sin trabajo (K5 `adreno.c:1720-1749`; `kgsl_pwrctrl.c:1962-1999`): con
  todos los anillos vacíos (`rptr == wptr`), `RBBM_STATUS & 0xfffffffe == 0` y el GBIF detenido
  (`RBBM_GBIF_HALT` → ACK, `GBIF_HALT` cliente → ACK, árbitro → ACK), `clk_disable` de `core` (GX_GFX3D), CXO,
  `gcc_bimc_gpu_axi`, `gpu_cc_ahb`, `gcc_gpu_memnoc_gfx`, `cx_gmu` y el voto del SMMU (`:1226-1241`). No toca los
  GDSC, ni el voto de bus, ni los de voltaje. A los 10 ms, el bus baja al nivel 1 (MINBW).
- **SLUMBER** a los 80 ms sin trabajo (`CONFIG_QCOM_KGSL_IDLE_TIMEOUT`, K5 `adreno.c:902`): parar el CP, bus a 0,
  relojes fuera, el núcleo a 320 MHz, GDSC de GX y de CX fuera (`kgsl_pwrctrl.c:2021-2048`).
- Despertar de NAP: `clk_enable` y quitar los dos `GBIF_HALT`; de SLUMBER, todo el arranque de la GPU.

### 3.4 Ocupación y gobernador

- **Contador de ocupación:** el contador de potencia 0 del GMU CX, que cuenta tics del XO (19,2 MHz) con la GPU
  ocupada; kgsl lo usa para todas las a6xx, la a610 sin GMU incluida (K4 `adreno_a6xx.c:603-609` lo programa:
  `GPU_GMU_AO_GPU_CX_BUSY_MASK` = 0xff000000, `GMU_CX_GMU_POWER_COUNTER_SELECT_0[7:0]` = 0x20,
  `..._ENABLE` = 1; `:2408` lo elige; K5 `adreno_a6xx.c:2145-2162`: `busy_us = tics × 10 / 192`). Linux hace lo mismo
  con el GMU wrapper de la a610 (L `a6xx_gpu.c:1052-1056`, `:2011-2025`, y `funcs_gmuwrapper` con `gpu_busy`,
  `:2193-2220`). Direcciones: 0x598ec38, 0x597e104, 0x597e100 y la cuenta en 0x597e110 (desplazamientos en palabras
  0x23b0e, 0x1f841, 0x1f840, 0x1f844 desde 0x5900000, K5 `a6xx_reg.h:994-1106`).
- **msm-adreno-tz** (K5 `governor_msm_adreno_tz.c:344-425`): el algoritmo vive en TrustZone (SMC SIP, servicio 0x0D);
  el kernel solo acumula y, si un intervalo pasa de 50 ms ocupado, salta al nivel 0. No se puede reproducir desde
  la fuente.
- **Linux** en esta GPU: `simple_ondemand` con umbral 50 y diferencial 10, cada 50 ms (L `msm_gpu_devfreq.c:122-155`):
  por encima del 50 % al máximo.

### 3.5 Temperatura en el DT de stock

- **TSENS** (DT:11328-11336): `tsens0`, `compatible = "qcom,tsens24xx"` (lo atiende `msm-tsens-driver.ko`), SROT
  0x4410000, TM 0x4411000. 16 sensores; el de la GPU es el 15 (§5).
- **Zona `gpu`** (DT:6036-6100): `polling-delay-passive` 10 ms; disparo pasivo a 95 °C (`gpu-trip`, histéresis 0,
  `msm_gpu` sin límites) y a 100 °C (`gpu-cx-mon`, histéresis 5 °C: `msm_gpu` desde el estado 4, más módem y CDSP);
  115 y 125 °C sin mapas de enfriamiento.
- **Gobernador térmico:** `step_wise` por defecto (MI `thermal_of.c` no lee `thermal-governor`; Kconfig por defecto).
  En 5.15: por encima del disparo y subiendo, un estado más por lectura; plano o bajando, se mantiene; por debajo y
  bajando, un estado menos (MI `gov_step_wise.c:37-168`). Estado N del dispositivo de kgsl = tope en el nivel N
  (K5 `kgsl_pwrscale.c:639-679, 775-778`; `devfreq_cooling.c`): 4 = 600 MHz, 6 = 320 MHz.
- **BCL** (caída de la batería, no temperatura): nivel 0 → GPU ≤ estado 2 (1025 MHz), nivel 1 → ≤ 600 MHz
  (DT:5152-5240). iOS no lo atiende.

### 3.6 Lo medido en Android (coordinador, `android/`)

- Disparos de la zona `gpu`: 95, 100 y 125 °C; CPU 110/115 °C. `devfreq-5900000.qcom,kgsl-3d0` con 6 estados.
- En reposo, ambiente caluroso: GPU 41-43 °C, CPU 42-48 °C, batería 38,8 °C. Con 30 s de uso: GPU hasta 55 °C, CPU
  hasta 56 °C, y **ningún dispositivo de enfriamiento activo**. Android baja la GPU en reposo por ocupación, no por
  calor. El cluster gold tiene `scaling_max_freq` = 2400 MHz (iOS lo fija en 2803,2 MHz, 11 §12).

## 4. Lo que hace hoy iOS, y lo medido

### 4.1 Comportamiento

`power_up()` (0337) vota CX/MX y los picos para la frecuencia de `gpu_mhz`, programa el PLL y deja la GPU ahí: sin
escalado, sin apagar relojes en reposo, sin leer temperatura, sin votos de bus (09 §5, 11 §5). A 1260 MHz fijos el
teléfono se calienta y el usuario ve fallos gráficos (03 M7); la imagen en uso es de 820 MHz.

### 4.2 Cómo y en qué estado se midió

**Método.** Lectura de registros por `kern.sweet_ipa_peek` (TopazModem 0229, presente en el kernel 0342), que
mapea una página física como memoria de dispositivo y devuelve N palabras; la petición es `"p 0 PA N"` (el primer
número es de relleno: el código de la petición `p` vuelve a leer la dirección después de él). Registros: el periodo
del DDR en `mccc` (0x447d220), `SROT_CTRL` (0x4410004), `TM_TRDY` (0x44110e4) y los 16 `TM_Sn_STATUS`
(0x44110a0-0x44110dc). Solo lectura: no cambia nada en el teléfono. Crudo:
`~/sapphire-angel/research/metal/relojes/telefono/lecturas-20261114-1112.txt`.

**Estado del teléfono** (14 nov 2026, hora del teléfono, PST): kernel 0342 (CI 43620776409), ruta R, boot-args con
`gpu_vco2=1 gpu_mhz=820` (`kern.sweet_gpu_pll`: 820000 kHz, CX 416, MX 416, bin 0), arranque a las 10:49:35. En esa
sesión se reinstaló el driver Metal: `HakiosMetal` se reemplazó a las 11:12:50 por `rebuild/out/cpu-A-wip` (sha256
`e992c97d…`), backboardd arrancó de nuevo a las 11:12:50 (pid 3235), SpringBoard a las 11:12:51 y
`CalendarWidgetExtension` a las 11:13:02. A las 11:23 backboardd es cliente de `SapphireGPU` (driver cargado).

| Serie | Hora | Estado | n |
|---|---|---|---|
| A1 | 11:12:44 | Antes de la reinstalación; carga media 5,0; driver en uso sin comprobar (03 M8: parte de la tarde CoreAnimation compuso por software a 3-5 núcleos) | 1 |
| A2-A4 | 11:13:05-11:13:26 | Relanzamiento de backboardd y SpringBoard; carga media 10,3 → 8,3; `CalendarWidgetExtension` al 100 % y un `gzip` (de la instalación) al 94 % de un núcleo | 3 |
| B1-B3 | 11:23:33-11:23:53 | Calma: carga media 1,1, pantalla quieta (`kern.sweet_fb_diag` sin swaps nuevos en 30 s), driver `cpu-A-wip` en uso, el proceso más ocupado `wifid` al 6,6 % | 3 |

### 4.3 DDR (medido)

**O.** Periodo 0x283 = 643 ps en las 7 lecturas (A1-A4, B1-B3) → **1555,2 MHz**, la fila 1555,2 del plan, con la
GPU a 820 MHz, en reposo y con la CPU ocupada por igual.

Interpretación (H): el arranque deja el DDR en 1555,2 MHz y, sin escalado del RPM, se queda ahí. Para la GPU a 820
MHz kgsl votaría 1804,8 MHz (el bus de 1025) y para 1114,8/1260 MHz 2092,8; si la pasada principal tiene una parte
limitada por memoria (03 M6: doblar el reloj la bajó de 20-24 a ~16 ms, no a la mitad), ese 25 % menos de DDR es un
candidato. Lo decide 0347 (§8) más la activación del escalado del RPM.

### 4.4 Temperaturas (medidas)

`SROT_CTRL` = 0x0de7fff9 (controlador encendido, los 16 sensores activos) y `TM_TRDY` = 0x8 (primera ronda
completa) en todas las lecturas; los 16 valores con `VALID`. Décimas de grado convertidas a °C. Qué es cada sensor:
la zona térmica del DT de stock que lo usa (DT:5438-6039) y lo que vigila según los nombres de Linux para sm6115
(`sm6115.dtsi`): las CPU 4-7 son los cuatro A73 (gold) y las 0-3 los A53 (silver).

| # | Zona | Qué vigila | A1 11:12:44 | A2 11:13:05 | A3 11:13:16 | A4 11:13:26 | B1 11:23:33 | B2 11:23:43 | B3 11:23:53 |
|---|---|---|---|---|---|---|---|---|---|
| 0 | `mapss` | subsistema de aplicaciones | 64,8 | 76,0 | 69,5 | 68,7 | 64,1 | 64,1 | 64,8 |
| 1 | `cdsp-hvx` | DSP de cálculo | 63,3 | 71,4 | 67,2 | 66,4 | 62,5 | 62,5 | 62,5 |
| 2 | `wlan` | WLAN | 62,5 | 68,7 | 65,6 | 64,5 | 61,4 | 61,4 | 61,7 |
| 3 | `camera` | cámara | 63,3 | 72,2 | 67,9 | 66,4 | 62,5 | 62,5 | 62,9 |
| 4 | `video` | vídeo | 64,5 | 74,1 | 69,1 | 67,9 | 63,3 | 62,9 | 63,3 |
| 5 | `mdm-1` | módem (Linux `modem1`) | 62,9 | 69,9 | 66,0 | 65,2 | 61,7 | 61,7 | 62,1 |
| 6 | `cpu-1-0` | CPU 4 (A73) | 66,4 | 80,7 | 71,4 | 71,0 | 66,0 | 65,6 | 66,0 |
| 7 | `cpu-1-1` | CPU 5 (A73) | 66,4 | 81,1 | 70,2 | 69,5 | 65,2 | 65,2 | 65,6 |
| 8 | `cpu-1-2` | CPU 6 (A73) | 67,2 | 82,2 | 72,2 | 71,4 | 66,0 | 65,6 | 66,4 |
| 9 | `cpu-1-3` | CPU 7 (A73) | 66,4 | 81,1 | 71,0 | 69,5 | 65,6 | 64,8 | 66,0 |
| 10 | `cpuss-0` | CPU 4-5 (Linux `cpu45`) | 67,5 | 81,1 | 72,6 | 71,4 | 67,2 | 66,4 | 67,2 |
| 11 | `cpuss-1` | CPU 6-7 (`cpu67`) | 67,9 | 81,8 | 72,6 | 71,8 | 67,5 | 66,8 | 67,2 |
| 12 | `cpuss-2` | CPU 0-3, A53 (`cpu0123`) | 66,4 | 79,1 | 72,2 | 71,8 | 66,0 | 65,6 | 66,0 |
| 13 | `mdm-0` | módem (Linux `modem0`) | 62,9 | 70,2 | 66,8 | 65,6 | 62,1 | 61,7 | 62,5 |
| 14 | `display` | bloque de pantalla del SoC | 62,9 | 71,4 | 66,8 | 66,0 | 62,1 | 61,7 | 62,1 |
| 15 | `gpu` | GPU | 62,1 | 69,1 | 65,6 | 64,8 | 61,7 | 61,4 | 61,7 |

Comparación con Android en este teléfono y ambiente (`android/LEEME.md`, mismo día, ambiente caluroso): en reposo GPU
41-43 °C y CPU 42-48 °C; tras 30 s de uso, GPU 55 °C y CPU 56 °C.

Interpretación (H, salvo las cifras):

1. **En calma (B), iOS está unos 20 °C por encima del reposo de Android**: GPU 61,4-61,7 °C frente a 41-43, CPU
   64,8-67,5 °C frente a 42-48, con la pantalla quieta y carga 1,1. Lo que hoy está fijo bajo iOS y no en Android: la
   GPU a 820 MHz con CX en 416 y sin apagar relojes, el DDR en 1555,2 MHz, y las CPU a 2803,2/1900,8 MHz (11 §12;
   Android limita las A73 a 2400 MHz y las escala). Si las CPU de iOS entran en estados de reposo profundos no está
   medido.
2. **El sensor de la GPU es el más frío del SoC** en todas las lecturas; los de CPU son los más calientes y los que más
   suben con carga de CPU (79-82 °C en A2, con el relanzamiento de la interfaz y dos procesos ocupando núcleos). La GPU
   no es el mayor foco de calor en estas condiciones; 0346 y 0348 atacan su parte, no la de la CPU.
3. Ninguna lectura se acerca a los 95 °C del disparo de stock.
## 5. Parche 0343: relojes y temperaturas medidos (solo lectura)

`0343-sapphire-gpu-clocks-thermal-diag.patch` (+332, aplica sobre 0342). La parte de relojes del borrador 0339 de
11 §8.1, renumerado, sin sus escrituras en `hw_init_regs` (no son de solo lectura), más TSENS y el DDR.

| sysctl | Qué da |
|---|---|
| `kern.sweet_gpu_clocks` | Medidos al leerlo (≈ 0,2 s): `gx_gfx3d`, `cx_gmu`, `gcc_gpu_memnoc_gfx`, `gcc_bimc_gpu_axi`, DDR (periodo y fila del plan), CPU gold y silver |
| `kern.sweet_ddr_khz` | El reloj del DDR en kHz, del periodo de `mccc`; no necesita la GPU |
| `kern.sweet_thermal` | `SROT_CTRL`, `TM_TRDY` y los 16 sensores por nombre de zona, en m°C (`off`, `not-ready` o `invalid` si no hay valor) |
| `kern.sweet_gpu_temp` | El sensor 15 en m°C (`ENODEV` apagado, `EAGAIN` sin primera ronda, `EIO` sin valor válido) |
| `gpu_clkdiag=1` | Las dos líneas en el log tras el encendido |

- **Relojes:** el procedimiento de `clk_measure` (MI `drivers_clk_qcom_clk-debug.c:91-190`, constantes `:45-53`,
  multiplicador `:275-299`): el multiplexor de depuración de GCC (+0x62000, divisor +0x30000, rama +0x30004) elige el
  reloj, el contador corre contra XO/4 (4,8 MHz) con una pasada corta y otra larga (iguales = reloj parado) y
  `f = ((n × 10 + 15) × 4,8 MHz) / (ticks × 10 + 35)` × divisores. Entradas de MI `drivers_clk_qcom_debugcc-khaje.c`:
  GPU CC 0xed (su multiplexor en +0x1568, divisor 2 en +0x10fc, rama +0x1100; `gx_gfx3d` 0x0b, `cx_gmu` 0x18),
  `gcc_gpu_memnoc_gfx` 0xee, `gcc_bimc_gpu_axi` 0x97, APSS 0xb6 (multiplexor en 0xf11101c, divisor fijo 8; 1 gold,
  0 silver).
- **DDR:** `mccc_debug` (DT:6311-6315), periodo en +0x20 en ps; `f = 10¹² / periodo` (`clk-debug.c:466-475`).
- **TSENS** (CLO `tsens2xxx.c`; L `tsens-v2.c`, `tsens.c:751-793`): `SROT_CTRL` (+4: bit 0 encendido, bit 3+n sensor
  n); `TM_TRDY` (TM+0xe4, bit 3: primera ronda completa; 0 tras un reinicio del controlador, valores viejos: stock lo
  mira antes de cada lectura); `TM_Sn_STATUS` (TM+0xa0+4n: bits 11:0 décimas de grado con signo, bit 21 `VALID`,
  sondeado hasta 20 veces a 1 µs). Fuera de −40..150 °C cuenta como no válido. El SO no calibra ni enciende nada en
  v2: lo hace el firmware de arranque. Leer no tiene efectos (las interrupciones se borran escribiendo otros
  registros). Nombres (zonas, DT:5438-6039): 0 `mapss`, 1 `cdsp-hvx`, 2 `wlan`, 3 `camera`, 4 `video`, 5 `mdm-1`,
  6-9 `cpu-1-0`..`cpu-1-3`, 10-12 `cpuss-0`..`cpuss-2`, 13 `mdm-0`, 14 `display`, 15 `gpu`.
- **Locking:** la medición de relojes va bajo `clk_lock`; las páginas de APSS, `mccc` y TSENS se mapean una vez en
  el primer uso (`OSCompareAndSwapPtr`; en una carrera la segunda se libera).
- **Riesgo:** registros que iOS no había tocado. Las lecturas de `mccc` y TSENS ya se hicieron en el teléfono sin
  incidencias (§4.2-4.4); los multiplexores de depuración, no. Síntoma si uno no fuera accesible: cuelgue al leer
  `kern.sweet_gpu_clocks`. Desactivar: no leerlo.

## 6. Parche 0345: cambio de nivel en caliente

`0345-sapphire-gpu-opp-switch.patch` (+411 −6, tras 0343). `kern.sweet_gpu_khz` (lectura: la frecuencia; escritura:
una fila de la tabla en kHz o en MHz, 1114 = 1114,8), `kern.sweet_gpu_opp` (estadística), `kern.sweet_gpu_opp_park`.
Requiere la ruta de stock de 0337 (`gpu_vco2=1` y un `gpu_mhz` de la tabla) y el servicio de la GPU.

### 6.1 Secuencia

Subir de A a B:

1. `opp_lock` (serializa cambios; siempre antes que `service_lock`, nunca al revés).
2. Votos de pico para B (`cx_ipeak_set` de 0337, sin registrar los aceptados fuera del arranque). *Danger* →
   `EAGAIN`, nada cambia.
3. CX al nivel de B si es mayor que el votado; MX al de 2B; (0347) el BIMC. Rechazo de un raíl → `EIO` y se deshacen
   los votos de pico.
4. `service_lock`; esperar hasta `gpu_opp_drain` ms (100) a que la GPU esté ociosa (`CP_RB_RPTR == WPTR` y
   `RBBM_STATUS` sin ocupación salvo el bit 0, el acceso AHB en curso). Con el candado tomado no entra trabajo nuevo:
   la cola se vacía en lo que tarde lo encolado. Si no → `EBUSY` y se deshacen los votos.
5. PLL: alpha, L, 5 µs, el bit de enganche que dice `TEST_CTL[16]` (hasta 1 ms), 100 µs; L y alpha leídos de vuelta.
6. Soltar `service_lock`.

Bajar de A a B: 1, 4, 5 con **L antes que alpha**, 6; después del reloj, CX/MX/BIMC al nivel de B y fuera los votos
de pico que B no necesita (orden de `clk_post_change_regmap` y de K4/K5).

**Orden de L y alpha.** Stock escribe alpha primero en los dos sentidos; entre las dos escrituras el PLL persigue la L
vieja con la alpha nueva, lo que al bajar queda hasta medio paso de L (9,6 MHz de núcleo) por encima de la frecuencia
vieja con los raíles aún en su nivel. El modelo de anfitrión lo muestra al bajar de 1260 (1260,8 MHz con CX 464) y de
1114,8 (1117,8 MHz con CX 416). 0345 escribe L primero al bajar: lo que persigue el PLL entre escrituras queda en o
por debajo de la mayor de las dos frecuencias. Con la GPU ociosa no tiene consecuencia práctica; mantiene el
invariante.

**Camino largo** (`kern.sweet_gpu_opp_park=1` o `gpu_opp_park=1`): RCG a GPLL0 / 2 (300 MHz: bajo toda fila, válido
con cualquier nivel de raíl), PLL configurado y arrancado desde standby como en el arranque (`gpu_pll_start_vco`),
RCG de vuelta. Es la alternativa si la actualización dinámica diera problemas, y la recuperación de un PLL sin
enganche.

### 6.2 Fallos a mitad y estado en que queda la GPU

| Fallo | Respuesta | Estado final |
|---|---|---|
| Fila fuera de tabla o por encima del bin | `EINVAL` | Sin cambios |
| Sin ruta de stock, sin servicio, o tras un fallo irrecuperable | `ENODEV` | Sin cambios |
| Pico rechazado | `EAGAIN`, votos deshechos | Sin cambios |
| Voto de raíl rechazado al subir | `EIO`, votos de pico deshechos | Sin cambios (un raíl que sí subió se queda: más alto es seguro) |
| GPU sin vaciar a tiempo | `EBUSY`, votos deshechos | Sin cambios |
| PLL sin enganche en 1 ms | Camino largo a la frecuencia vieja; `EIO` | Frecuencia vieja, sus votos |
| … y el reinicio tampoco engancha | RCG queda en GPLL0 / 2 | 300 MHz, cambios rechazados en adelante, votos de 300 MHz |
| El RCG no completa un cambio de fuente | `service_ready = false` | Servicio parado: copias por CPU, Metal recibe NotReady |

Leer un registro de la GPU con su reloj parado cuelga el bus (cabecera de `SapphireGpu.cpp`); por eso un RCG que no
termina un cambio apaga el servicio, que es lo único que lee registros de la GPU después.

### 6.3 Verificación

`harness0345.cpp` compila el código real de 0337 (PLL, picos) y de 0345 contra un modelo del PLL Zonda (L, alpha,
enganche con retardo, `TEST_CTL`, salida), del RCG (`UPDATE`, fuente, divisor), de la GPU (ocupada N lecturas o
siempre), del RPM (acepta o rechaza CX 464) y de `cx_ipeak` (*danger*). En cada escritura de registro comprueba: I1
núcleo ≤ `rate_max` del CX votado; I2 VCO ≤ `rate_max` del MX votado; I3 votos de pico presentes desde 900/950 MHz;
I4 el PLL solo se escribe con `service_lock` tomado y la GPU ociosa; y el orden de candados. 12 escenarios (subir,
bajar, GPU que no se vacía y que se vacía a tiempo, pico rechazado, CX 464 rechazado, PLL sin enganche con y sin
reinicio bueno, RCG atascado, camino largo, peticiones, toda la escalera en los dos sentidos y modos, contabilidad).
0 fallos, 0 violaciones, 0 errores de candado. Secuencias del modelo:

    820 → 1260:  [ipeak 0x2000=1] [ipeak 0xe000=1] [cx 464] [alpha 0x4000] [L 131]
    1260 → 320:  [L 33] [alpha 0x5555] [cx 416] [ipeak 0x2000=0] [ipeak 0xe000=0]
    GPU ocupada: [ipeak …=1] [cx 464] [cx 416] [ipeak …=0]   (EBUSY, PLL intacto)

## 7. Parche 0346: gobernador

`0346-sapphire-gpu-governor.patch` (+487, tras 0345). Apagado salvo `kern.sweet_gpu_gov=1` (o `gpu_gov=1`, que lo
arranca cuando el servicio de la GPU está arriba). Un hilo del kernel; cada `kern.sweet_gpu_gov_ms` (50):

1. **Ocupación:** el contador de potencia 0 del GMU CX (§3.4), programado como kgsl y Linux y reprogramado si se lee
   cambiado; carga = tiempo ocupado / tiempo de pared del periodo.
2. **Escalera:** los niveles del DT (320 465 600 785 1025 1114,8 1260 MHz) entre `kern.sweet_gpu_khz_min` (320000)
   y `kern.sweet_gpu_khz_max` (por defecto, la frecuencia de arranque; si es una fila que no es nivel del DT, 820 por
   ejemplo, es la cima). Así, activarlo nunca sube por encima de lo que se arrancó.
3. **Frecuencia:** carga ≥ 95 % → la cima (como `simple_ondemand` de Linux por encima de su umbral, o el salto de
   msm-adreno-tz tras 50 ms ocupado); ≥ `gov_up` (80 %) → al menos un nivel más, hasta el que dejaría la carga en el
   medio entre `up` y `down`; < `gov_down` (40 %) dos periodos seguidos → al menos uno menos, hasta ese mismo nivel;
   sin envíos, sin copias al panel y < 2 % durante `gov_idle_ms` (100) → el nivel mínimo (kgsl apaga los relojes de
   la GPU al quedarse sin trabajo y la baja al mínimo a los 80 ms).
4. **Temperatura:** sensor 15. A partir de `kern.sweet_gpu_temp_max` (95000 m°C, el `gpu-trip` de stock; admite
   50000-95000), un nivel menos por cada lectura más alta que la anterior; por debajo, un nivel más por cada lectura
   que no sube; desde 5 °C más (el `gpu-cx-mon` de 100 °C de stock, cuyo mapa empieza en el estado 4), 600 MHz como
   mucho. El tope se guarda como frecuencia, no como índice, para que conserve su sentido si cambia la escalera. Tres
   periodos sin lectura válida → el nivel mínimo hasta que vuelva a leer.
5. Cambio con `gpu_opp_set()` de 0345. `EBUSY` → otra vez en el periodo siguiente. Pico o raíl rechazado → el
   gobernador se queda por debajo de esa frecuencia el resto de la sesión. Sin ruta de stock, sin servicio, fallo
   irrecuperable, contador quieto un segundo con trabajo entrando, o contador más rápido que el reloj de pared 20
   periodos → se para. Al parar devuelve la frecuencia de arranque. Mientras corre, `kern.sweet_gpu_khz` da `EBUSY`.

`kern.sweet_gpu_gov_stats`: estado y motivo de parada, frecuencia, escalera, tope térmico, frecuencia rechazada,
ajustes; periodos, carga última y media, subidas/bajadas/caídas a reposo, rechazos, periodos con tope térmico,
temperatura última y máxima, lecturas fallidas, reprogramaciones del contador, muestras malas e histograma de la
carga. El tiempo en cada frecuencia está en `kern.sweet_gpu_opp`.

Por qué esta política y no la de stock: la de kgsl corre en TrustZone y no se puede reproducir desde fuente (§3.4); la
de Linux (al máximo por encima del 50 %) calentaría con la carga que tiene hoy el driver Metal (42 % a 820 MHz,
03 M6). Llamar al DCVS de TrustZone por SMC (servicio 0x0D) es una opción no explorada.

**Verificación** (`harness0346.cpp`: el código real de 0337, 0343, 0345 y 0346 contra el modelo de 0345, un TSENS
simulado y una GPU cuya ocupación es una cantidad de trabajo fija dividida por la frecuencia): reposo → 320 MHz a los
100 ms; saturada → la cima; la carga de 03 M6 (42 % a 820) se asienta en 600 MHz con 2 cambios en 200 periodos;
carga ligera → baja escalón a escalón; los dos disparos térmicos (95,0 subiendo → un nivel; plano → se mantiene; 95,5
→ otro; 100,1 → ≤ 600 MHz; por debajo y bajando → recupera un nivel por periodo); sensor ilegible; contador muerto
(se para a los 1050 ms) y desbocado; GPU que no se vacía; pico rechazado (se queda en 1114,8, nunca 1260); escalera
por bin y límites; ruta de parada (vuelve a 820) y arranque por sysctl. 0 fallos; los invariantes de 0345 se cumplen
en todos los periodos.

## 8. Parche 0347: voto del DDR por nivel

`0347-sapphire-gpu-ddr-vote.patch` (+141, tras 0346). Apagado salvo `kern.sweet_gpu_ddr=1` (o `gpu_ddr=1`).

- El voto que pediría kgsl, en kHz del BIMC (§3.1): `ib / 8` del nivel de bus del nivel de la GPU (820 y 980 toman
  el de 1025; 1100 el de 1114,8), nunca por debajo de `kern.sweet_gpu_ddr_floor` (kHz, 0). RPM `clk2` 0, clave
  `KHz`, conjunto activo, desde `opp_votes()`: al subir después de los raíles y antes del reloj; al bajar después del
  reloj. Un voto rechazado se cuenta y deja el anterior; el cambio de la GPU sigue.
- `kern.sweet_gpu_ddr=1` vota ya para la frecuencia en curso; `=0` vota `INT_MAX`, lo que deja el driver de relojes de
  stock en el BIMC al arrancar (MI `drivers_clk_qcom_clk-smd-rpm.c:1380-1401`, `clk_vote_bimc`). Cada escritura por
  sysctl mide el DDR antes del voto y 20 ms después, y lo escribe en el log; `kern.sweet_gpu_ddr_stats` da votos,
  rechazos, el último voto y su respuesta, el DDR antes/después y ahora.
- **Para qué sirve:** nada en este kernel activa el escalado de relojes del RPM ("Enab" en `clk0` 2,
  `clk_smd_rpm_enable_scaling`, MI `:395-423`). Con el escalado apagado, un voto no debería cambiar nada (H de
  11 §10.2). La lectura antes/después lo decide. Si el DDR no se mueve de 1555,2 MHz, activar el escalado es un paso
  global aparte que este parche no da: stock en khaje solo vota el BIMC a `INT_MAX` antes de activarlo (no hay
  `qcom,hw-clk-handoff` en el DT), pero en Android cada driver vota después sus buses; en iOS nadie vota `cnoc`,
  `snoc`, `qup`, `ipa`, `mmrt`… y quedarían sin sostener. El experimento manual existe (`kern.sweet_audio` op 6, que
  vota `clk2`, `clk1`, `clk0`/`Enab`, `qup`, `ipa`, `mmxi`, `ce`): primero votar el máximo en todos los relojes de
  bus del RPM de holi/khaje (MI `:1121-1185`), luego `Enab` en el conjunto de reposo y en el activo, y con 0347 a 1 y
  un suelo puesto, medir.
- **Verificación** (`harness0347.cpp`): apagado no vota; el voto de cada nivel; el orden de kgsl alrededor del PLL en
  los dos sentidos; el suelo; un voto rechazado no frena el cambio; `INT_MAX` al apagar; con el gobernador saturado
  y en reposo; invariantes intactos. 0 fallos.

## 9. Parche 0348 y reposo: clock gating por hardware, y lo que no se implementa

`0348-sapphire-gpu-hwcg.patch` (+82, tras 0347). Apagado salvo `gpu_hwcg=1` o `kern.sweet_gpu_hwcg=1`.

- Lo que kgsl hace en cada arranque de esta GPU (K5 `adreno_a6xx.c:345-410`, `a6xx_hwcg_set`): la tabla `a612_hwcg`
  (46 registros), `UCHE_GBIF_GX_CONFIG[18:16]` = 2 y `RBBM_CLOCK_CNTL` = 0xaaa8aa82; apagado = ceros. La tabla del
  parche (la del borrador 0339) es igual, registro a registro por desplazamiento (`a6xx.xml`) y valor, a la
  `a612_hwcg` de L `a6xx_catalog.c:14-62`. Sin GMU, kgsl omite los registros CGC del GMU (Linux los escribe por su
  wrapper); el parche sigue a kgsl.
- Con `gpu_hwcg=1`, al final de `hw_init_regs()` (cada arranque del CP, también tras un reinicio de 0317). Con el
  sysctl, ya, con `service_lock` tomado y la GPU ociosa (`EBUSY` si no se vacía), y en adelante en cada arranque.
- Efecto esperado: los bloques de la GPU paran su reloj cuando no tienen trabajo, a cualquier frecuencia. Los
  contadores *always-count* del CP y del RBBM pueden parar con la GPU ociosa (11 §11); `gxfreq` mide mientras corren
  sus propios comandos; el contador del gobernador (el del GMU) no es uno de ellos.
- **Verificación** (`harness0348.cpp`): 48 escrituras al encender con `RBBM_CLOCK_CNTL` la última, los demás bits de
  `UCHE_GBIF_GX_CONFIG` intactos, nada si ya está como se pide, ceros al apagar. 0 fallos.

**Apagar la rama del reloj del núcleo en reposo (NAP de kgsl, §3.3): no implementado.** Con la rama 0x1054 (o el
resto de ramas de NAP) apagada, cualquier lectura de un registro de la GPU cuelga el bus. Hoy leen registros de la GPU
`ring_room`, `kick`, `msm_gpu_idle`, `map_window`, las copias al panel, el TLB del SMMU, la recuperación de 0317,
`smmu_fault`, los sysctl de diagnóstico y el gobernador (contador del GMU, que cuelga de `cx_gmu`). Hacerlo con
seguridad requiere: todos los accesos por un único par de funciones que comprueben que la GPU está despierta (y
despierten bajo `service_lock`), el protocolo de GBIF de kgsl antes de apagar (`RBBM_GBIF_HALT`, cliente, árbitro, con
sus ACK) y al despertar (soltarlos), y un temporizador de reposo. Un acceso olvidado es un cuelgue duro sin log. Con
0346 (320 MHz en reposo) y 0348 (gating por hardware) se obtiene la mayor parte del ahorro sin ese riesgo; medirlo
antes de decidir el NAP.

## 10. Locking

- Orden de candados: `opp_lock` → `service_lock`. Ningún camino que tenga `service_lock` llama a código que tome
  `opp_lock` (los caminos de msm y de copias no lo tocan). `kern.sweet_gpu_hwcg` toma solo `service_lock`;
  `kern.sweet_gpu_ddr` solo `opp_lock`; `clk_lock` (0343) es independiente.
- Los votos al RPM (`topaz_rpm_vote`, que duerme hasta 1 s esperando respuesta) y a `cx_ipeak` van bajo `opp_lock`,
  nunca bajo `service_lock`: no bloquean los envíos a la GPU. El estado estático de `cx_ipeak_set` solo se toca en el
  arranque (un hilo) y luego bajo `opp_lock`.
- Bajo `service_lock` solo pasan la espera de vaciado (≤ `gpu_opp_drain` ms, 100) y el PLL (≈ 0,1-0,2 ms; el camino
  largo, algo más): durante ese tiempo los envíos y las copias al panel esperan el candado.
- El gobernador lee `msm_seq`, el número de copias y `opp_khz` sin candado (palabras alineadas, solo como "hubo
  trabajo" o como referencia); sus estructuras son de su hilo; las estadísticas se leen sin candado.

## 11. Orden de prueba en el teléfono

Kernel con 0343, 0345, 0346 y 0347 (`xnu/patches/`, CI run 43631168892); 0348 entra en la tanda siguiente. Con los
boot-args de hoy (`gpu_vco2=1 gpu_mhz=820`, ningún boot-arg nuevo) el kernel se comporta como 0342: todo lo nuevo
está apagado o es de solo lectura. Cada paso, de menos a más riesgo, en una sesión `ssh sapphire` (PATH con
`/var/jb/usr/bin:/var/jb/usr/sbin`). Volver atrás en cualquier momento: `sysctl -w kern.sweet_gpu_gov=0` (devuelve la
frecuencia de arranque), `sysctl -w kern.sweet_gpu_khz=820000`, `sysctl -w kern.sweet_gpu_ddr=0`; reiniciar lo
deshace todo.

### 11.0 Antes de medir

    sysctl kern.sweet_gpu_pll                 # "gx_gfx3d 820000 kHz ... l 85 alpha 6aaa ... test_ctl 00000000 ... CX 416 MX 416; speed bin 0"
    rebuild/gpu-tools/driver-en-uso.sh        # en la Mac: "DRIVER EN USO" (03 M8); si no, las medidas de frames no valen
    sysctl -n kern.sweet_thermal              # temperatura de partida
    uptime; ps -Ao pcpu,comm | sort -rn | head -5    # anotar la carga: en §4.4 dos procesos ocupados subieron la CPU 15 °C

### 11.1 0343: relojes y temperaturas (solo lectura)

    sysctl kern.sweet_ddr_khz                 # 1555210 (periodo 643 ps, como en §4.3)
    sysctl kern.sweet_gpu_temp                # m°C; en calma ~61500 (§4.4)
    sysctl -n kern.sweet_thermal              # "tsens ctrl 0de7fff9 (on, sensors on ffff), trdy 00000008 (ready), ..." y 16 valores
    sysctl -n kern.sweet_gpu_clocks           # tres veces

Qué mirar: `kern.sweet_ddr_khz` y `kern.sweet_thermal` deben coincidir con §4.3-4.4 (son los mismos registros).
`kern.sweet_gpu_clocks` es lo único de 0343 que toca registros nuevos (los multiplexores de depuración): esperado
`gx_gfx3d` ≈ 820000 (la fórmula de stock da unos 20 kHz menos), `cx_gmu` ≈ 200000, `ddr 1555210 ... plan row
1555200`, `cpu gold` ≈ 2803200, `cpu silver` ≈ 1900800; `gcc_gpu_memnoc_gfx` y `gcc_bimc_gpu_axi` son primeras
lecturas (sin valor esperado). Si la primera lectura de `kern.sweet_gpu_clocks` congela el teléfono: reiniciar y no
volver a leerla; el resto de los parches no la usa.

### 11.2 0345: cambio de nivel a mano

Con la interfaz quieta:

    sysctl kern.sweet_gpu_khz                         # 820000
    sysctl -w kern.sweet_gpu_khz=600000; echo $?      # 0
    gxfreq 200 3                                      # 600,00 MHz, 3 de 3
    sysctl -n kern.sweet_gpu_pll                      # "600000 kHz ... l 63 alpha 8000"
    sysctl -n kern.sweet_gpu_opp                      # err 0, "PLL without lock 0", µs del cambio, sondeos
    sysctl -w kern.sweet_gpu_khz=320000; gxfreq 200 3     # 320,00
    sysctl -w kern.sweet_gpu_khz=785000; gxfreq 200 3     # 785,00
    sysctl -w kern.sweet_gpu_khz=1025000; gxfreq 200 3    # 1025,00 (votos de pico 1 y 10; CX sigue en 416)
    sysctl -w kern.sweet_gpu_khz=820000               # vuelta
    dmesg | grep "SapphireGpu: opp"                   # una línea por cambio hecho por sysctl; ninguna de error

Con la interfaz en movimiento (`homeswipe.sh 8` en otra sesión): `820000 → 600000 → 820000` y mirar la pantalla y,
en `kern.sweet_gpu_opp`, "idle after … us" (lo que esperó a que la GPU se vaciara). Después el camino largo:

    sysctl -w kern.sweet_gpu_opp_park=1
    sysctl -w kern.sweet_gpu_khz=600000; gxfreq 200 3; sysctl -w kern.sweet_gpu_khz=820000; gxfreq 200 3
    sysctl -w kern.sweet_gpu_opp_park=0

Qué mirar: retorno 0; `gxfreq` igual a la fila (n ≥ 3 por nivel); en `kern.sweet_gpu_opp`, "refused" a 0, "PLL
without lock 0", "max … us" (sin carga, del orden de 0,2-1 ms); la pantalla. Si un cambio da `EIO`: leer
`kern.sweet_gpu_opp` y `dmesg | grep opp`, no seguir con el modo dinámico y repetir con `kern.sweet_gpu_opp_park=1`.
`EBUSY` con la interfaz en movimiento puede salir (la GPU no se vació en 100 ms): repetir.

### 11.3 0346: gobernador

    sysctl kern.sweet_gpu_khz_max                     # 820000: la cima es la frecuencia de arranque
    sysctl -w kern.sweet_gpu_gov=1
    sleep 10; sysctl -n kern.sweet_gpu_gov_stats; sysctl -n kern.sweet_gpu_opp
        # quieto: "to-idle" >= 1, carga ~0, y en "time at each rate" crece 320000
    # carga: tools/perf/ab.sh ETIQUETA "" desde la Mac (homeswipe), o homeswipe.sh 8 en el teléfono
    sysctl -n kern.sweet_gpu_gov_stats                # histograma de carga, subidas/bajadas, temperatura última y máxima
    sysctl -n kern.sweet_gpu_opp                      # tiempo en cada frecuencia durante la carga
    sysctl -n kern.sweet_thermal                      # comparar con 11.0
    sysctl -w kern.sweet_gpu_khz_max=1025000          # y repetir la carga; luego 1114800; luego 1260000
    sysctl -w kern.sweet_gpu_gov=0                    # vuelve a 820000

Qué mirar: en `kern.sweet_gpu_gov_stats`, que no aparezca "stopped:" mientras corre, "busy counter set up 1 times",
"bad samples 0", "refused" a 0; los buffers/s de `ab.sh` frente a 820 MHz fijos (03 M7: 21,8); la temperatura en
calma con el gobernador frente a §4.4 (la GPU pasa a 320 MHz en reposo). Mientras corre, escribir
`kern.sweet_gpu_khz` da `EBUSY` (es así por diseño). Con 1260000 de cima, mirar la pantalla: los fallos vistos a 1260
MHz fijos coincidieron con la composición por software (03 M8), así que la relación con la frecuencia está sin medir.
Si el gobernador se para solo, "stopped:" dice por qué (p. ej. el contador del GMU no cuenta).

### 11.4 0347: voto del DDR

    sysctl kern.sweet_ddr_khz                         # 1555210
    sysctl -w kern.sweet_gpu_ddr=1                    # vota para la frecuencia en curso (820000 → 1761719 kHz)
    dmesg | grep "ddr: BIMC vote"                     # "the DDR at X kHz before, Y kHz 20 ms after"
    sysctl -n kern.sweet_gpu_ddr_stats
    # con el gobernador encendido: tras 10 s quieto (voto 534180) y bajo carga a 1025000 (voto 1761719)
    sysctl -n kern.sweet_gpu_ddr_stats                # "DDR now"
    sysctl -w kern.sweet_gpu_ddr=0                    # INT_MAX

Lo que decide: si el DDR sigue en 1555210 con todos los votos, el RPM los ignora con el escalado apagado (H de 11
§10.2 se sostiene) y el siguiente paso es el experimento de escalado de §8, aparte. Si cambia, H cae: anotar los
valores, y si con la GPU en reposo baja de 1555210, poner suelo (`sysctl -w kern.sweet_gpu_ddr_floor=1555200`) o
apagarlo.

### 11.5 0348 (tanda siguiente)

    sysctl kern.sweet_gpu_hwcg                        # 0
    sysctl -w kern.sweet_gpu_hwcg=1                   # con la interfaz en uso
    dmesg | grep "SapphireGpu: hwcg"                  # "on (RBBM_CLOCK_CNTL aaa8aa82)"

Qué mirar: la pantalla; reinicios de la GPU (`dmesg | grep "was reset"`); la temperatura en calma frente al paso
11.3. Apagar con `sysctl -w kern.sweet_gpu_hwcg=0`.

### 11.6 Qué anotar en 03

Por paso: fecha y hora, imagen (run de CI y sha), boot-args, ruta de arranque, `driver-en-uso.sh`, carga y procesos
ocupados, resultados con su n, y `kern.sweet_thermal` antes y después. Lo que funcione pasa a boot-args (`gpu_gov=1`,
`gpu_ddr=1`, `gpu_hwcg=1`) con n ≥ 3.

## 12. Riesgos, síntomas y cómo desactivar

| Parche | Riesgo | Síntoma | Desactivar |
|---|---|---|---|
| 0343 | Multiplexores de depuración no accesibles | Cuelgue al leer `kern.sweet_gpu_clocks` | No leerlo |
| 0345 | La actualización dinámica del PLL se comporta distinto que en el modelo | `EIO` y `pll_fail` en `kern.sweet_gpu_opp`; la GPU vuelve a su frecuencia por el camino largo | `kern.sweet_gpu_opp_park=1`, o no escribir `kern.sweet_gpu_khz` |
| 0345 | El RCG no completa un cambio | Servicio parado, copias por CPU (pantalla más lenta), log `the RCG did not take a switch` | Reiniciar; no repetir |
| 0345 | Vaciado largo bajo `service_lock` | Un frame tarde en cada cambio | `gpu_opp_drain` más bajo |
| 0346 | Política que oscila o se queda baja | `kern.sweet_gpu_gov_stats` (histograma, cambios) | `kern.sweet_gpu_gov=0` (vuelve la de arranque) |
| 0346 | Un nivel alto inestable (fallos gráficos a 1260 MHz vistos con la GPU fija) | Fallos en pantalla | `kern.sweet_gpu_khz_max` por debajo |
| 0346 | El contador del GMU no cuenta en iOS | El gobernador se para (`does not count`) y deja la de arranque | — |
| 0347 | El voto sí mueve el DDR (contra H) y lo baja con la GPU en reposo | CPU más lenta; DDR bajo en `kern.sweet_gpu_ddr_stats` | `kern.sweet_gpu_ddr=0` o `kern.sweet_gpu_ddr_floor` |
| 0348 | Gating con efectos sobre el render | Errores de render, reinicios de 0317 | `kern.sweet_gpu_hwcg=0` |

Los votos de pico (`cx_ipeak`) son de K4; K5 no los hace (§1.5). Pueden recortar la potencia del módem mientras están
puestos (H de 11 §8); con el gobernador solo lo están por encima de 900 MHz.

## 13. Afirmaciones heredadas contrastadas

| Afirmación | Dónde | Veredicto |
|---|---|---|
| "Android vota además el límite de corriente de pico de CX (`cx_ipeak`)" | 11 §1.4 y §4.5 | **Solo verificado en kgsl 4.19** (K4 `kgsl_pwrctrl.c:317-364`). kgsl 5.x, el de msm-5.15, no tiene ningún lector de `qcom,gpu-cx-ipeak`; el `msm_kgsl.ko` del teléfono no está en disco |
| "a 1260 MHz el DDR está fijo en 2092 MHz" | 11 §4.5 | Es lo que vota kgsl en Android; bajo iOS el DDR está en 1555,2 MHz (medido, §4.3) |
| "la frecuencia del DDR bajo iOS: sin medir" | 11 §1.7, §10.2 | Medida: 1555,2 MHz, n=7 (§4.3) |

## 14. Estado al cerrar (14 de noviembre de 2026)

**Terminado.** 0343, 0345, 0346 y 0347 están en `xnu/patches/` (CI run 43631168892; su código es el de
`parches-nuevos/`); 0348 está en `parches-nuevos/` y entra en la tanda siguiente. Los cinco aplican en orden sobre
0342, compilan en sintaxis contra las cabeceras de xnu y pasan sus arneses de anfitrión. Lo integrado no se modifica:
un cambio de código va como parche nuevo encima, y los siguientes de este trabajo usan 0351 en adelante (0349 y 0350
son del trabajo de pantalla). Medidos en el teléfono, en solo lectura: DDR a 1555,2 MHz y las temperaturas de §4.4.

**Sin hacer.** Probar en el teléfono (§11). Comprobar que 0344 (otro agente) no toca las mismas
zonas de `SapphireGpu.cpp`. El escalado del RPM y el NAP, como experimentos aparte (§8, §9). La CPU fija a 2803 MHz,
que hoy es el sensor más caliente, está fuera de este informe.
