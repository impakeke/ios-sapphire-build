# 17 — GPU: escalado de frecuencia, temperatura y DDR

Diseño, código y verificación en anfitrión de los parches 0343, 0345, 0346 y 0347 (fuera del repo, en
`~/sapphire-angel/research/metal/relojes/parches-nuevos/`): medir relojes y temperaturas, cambiar el nivel de la GPU
en caliente, un gobernador por ocupación con tope térmico y el voto del DDR por nivel. Informe del 14 de noviembre de
2026 sobre la serie `xnu/patches/` hasta 0342 (xnu-8796.141.3). Antecedentes: [11](11-gpu-relojes-bus-vs-android.md)
(cadena de relojes, raíles, `cx_ipeak`, DDR, 0337), [09](09-auditoria-kernel-gpu.md) §5 (energía) y
[03](03-experimentos-y-datos.md) M3, M4, M6, M7.

Convenciones: **O** = observación (medida o leída en una fuente primaria), **H** = hipótesis. Las citas de stock son
de `~/sapphire-angel/research/metal/relojes/ref/` (procedencia en 11 §2): kernel de Xiaomi `topaz-t-oss` @ `345999da`
(msm-5.15, mismo SoC), kgsl 4.19 de `spes-r-oss` @ `88afd325`, kgsl 5.x de CodeLinaro `graphics-kernel` @ `f900d903`,
Linux v6.12. **DT:N** = línea N de `dtb/merged-khaje24a-sapphire.dts`.

## 1. Resumen

1. **El kernel deja la GPU a una frecuencia y un voltaje fijos para siempre** (09 §5): ni escalado, ni temperatura,
   ni voto del DDR. Android sube a los niveles altos solo con carga, baja en reposo y vota el DDR por nivel; a 55 °C
   en la GPU no recorta nada (lectura de Android en este teléfono, §3.3).
2. **El cambio de nivel en caliente de stock es un cambio del PLL solo** (O): las diez filas de
   `ftbl_gpu_cc_gx_gfx3d_clk_src` son fuente 1 divisor 1 y `gpu_cc_pll0` tiene `SUPPORTS_DYNAMIC_UPDATE`
   (`gpucc-khaje.topaz-t-oss.c:70-95, 220-258`); `clk_zonda_pll_set_rate()` escribe alpha y L con el PLL en marcha,
   espera 5 µs, el bit de enganche que dice `TEST_CTL[16]` y 100 µs (`clk-alpha-pll.c:2583-2626`). El voltaje sube
   antes de un reloj más rápido y baja después de uno más lento (`clk-regmap.c:106-181`).
3. **0343** (solo lectura) mide los relojes (GPU, buses, DDR, CPU) con el contador de depuración de Qualcomm y lee los
   16 sensores TSENS por su nombre de zona térmica. Es lo primero que hay que compilar: da la frecuencia real del DDR
   bajo iOS (sin medir hasta ahora) y la temperatura de la GPU.
4. **0345** cambia el nivel con `kern.sweet_gpu_khz`: votos de pico y raíles antes de subir, después de bajar; el PLL
   con la GPU ociosa y `service_lock` tomado; recuperación si el PLL no engancha. Verificado en anfitrión contra un
   modelo del PLL con invariantes eléctricos en cada escritura de registro (§6).
5. **0346** (gobernador) y **0347** (voto del DDR): §7 y §8.

## 2. Material y método

| Qué | Dónde |
|---|---|
| Parches nuevos | `~/sapphire-angel/research/metal/relojes/parches-nuevos/0343-*.patch`, `0345-*.patch`, … |
| Generadores (aplican los cambios sobre el fuente de la serie) | `parches-nuevos/work/splice0343.py`, `splice0345.py`, … |
| Fuente resultante de cada paso | `parches-nuevos/work/SapphireGpu.0342.cpp` (base, sha256 `83dc20e2…`), `SapphireGpu.0343.cpp`, `SapphireGpu.0345.cpp`, … |
| Arneses de anfitrión | `parches-nuevos/work/harness0343.cpp`, `harness0345.cpp`, …; compilan el código real del parche, extraído por marcadores (`extrae.py`) |
| Árbol a 0342 | `relojes/xnu-0342/` (`xnu-serie/` + 0339-0342 de `xnu/patches/` con `git apply`) |
| Lecturas de Android en este teléfono | `~/sapphire-angel/research/metal/android/` (`LEEME.md`, `estado-reposo.txt`, `serie-30s.txt`) |

Comprobaciones de cada parche: `git apply --check` sobre el árbol a 0342 con los anteriores aplicados en orden,
`clang++ -fsyntax-only` con los stubs de `kernel-gpu/verificacion/` (`syn.sh`) y una pasada con `-Wall -Wextra` que se
compara con la de 0342 (ningún aviso nuevo), y el arnés.

## 3. Lo que hace Android en este teléfono

### 3.1 Niveles de stock (bin 0) con raíles, picos y bus

Niveles de `qcom,gpu-pwrlevels-0` (DT:8064-8140), VCO y L/alpha como los calcula `clk_zonda_pll_set_rate()`, nivel
de VDD_CX por `rate_max` de `gx_gfx3d_clk_src` y de VDD_MX por el del PLL (`gpucc-khaje.topaz-t-oss.c:85-93,
247-258`), votos de `cx_ipeak` (DT:7976-7989: cliente 1 desde 900 MHz, cliente 10 desde 950 MHz) y bus
(`qcom,bus-freq` del nivel → `qcom,bus-table-ddr`, DT:7953):

| Nivel | Núcleo (MHz) | VCO | L / alpha | CX stock | CX en iOS (suelo 0x1a0) | MX stock | Picos | bus-freq (mín-máx) | ib (kB/s) | BIMC (kHz = ib / 8) | DDR (MHz) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 1260 | 2520 | 131 / 0x4000 | 464 | 464 | 256 | 1 y 10 | 7 (7-7) | 16 343 750 | 2 042 969 | 2092,8 |
| 1 | 1114,8 | 2229,6 | 116 / 0x2000 | 416 | 416 | 128 | 1 y 10 | 7 (7-7) | 16 343 750 | 2 042 969 | 2092,8 |
| 2 | 1025 | 2050 | 107 / 0xc555 | 384 | 416 | 128 | 1 y 10 | 6 (5-7) | 14 093 750 | 1 761 719 | 1804,8 |
| 3 | 785 | 1570 | 82 / 0xc555 | 256 | 416 | 64 | — | 5 (4-5) | 12 148 437 | 1 518 555 | 1555,2 |
| 4 | 600 | 1200 | 63 / 0x8000 | 192 | 416 | 64 | — | 4 (3-5) | 7 945 312 | 993 164 | 1017,6 |
| 5 | 465 | 930 | 48 / 0x7000 | 128 | 416 | 64 | — | 3 (2-4) | 6 000 000 | 750 000 | 768 |
| 6 (inicial) | 320 | 640 | 33 / 0x5555 | 64 | 416 | 64 | — | 2 (1-2) | 4 273 437 | 534 180 | 547,2 |
| 7 | 0 (reposo profundo) | — | — | — | — | — | — | 0 | 0 | — | — |

- La columna BIMC es lo que `icc-rpm.c` (`qcom_icc_rpm_set`, `:117-176`) pide al RPM: `max(suma de ab, máximo de
  ib) / buswidth`, con el `buswidth` 8 del nodo `ebi` (`interconnect_qcom_bengal.c:672-680`; el de `qnm_gpu` es 32
  y da menos), en Hz, que `clk-smd-rpm` pasa a kHz redondeando hacia arriba. El RPM toma la fila del plan del DDR que
  lo cubre: cada `ib` de la tabla es el 97,7 % de 8 bytes por ciclo de una fila (11 §4.5).
- 820, 980 y 1100 MHz están en la tabla del reloj pero en ningún nivel del DT.
- MX: con el suelo de 0337 (0x1a0) iOS vota 416 en todos los niveles; el PLL solo pide 256 a 2520 MHz de VCO.
- CX: iOS es el único votante de APSS (Android suma todos sus consumidores), así que 0337 no baja de 0x1a0; con ese
  suelo el raíl solo cambia entre 1114,8 y 1260 MHz (416 ↔ 464). Bajar de 416 por debajo de lo que ha usado siempre
  0204 es otro experimento (`gpu_cx=N`).

### 3.2 Cómo cambia de nivel el driver de relojes de stock

O, de las fuentes de stock del SoC:

1. kgsl pide la frecuencia con `clk_set_rate` sobre `core_clk` = `GPU_CC_GX_GFX3D_CLK` (11 §4.1).
2. La rama y el RCG tienen `CLK_SET_RATE_PARENT`; el RCG usa `clk_rcg2_ops` (no las de "ping-pong" entre dos PLL de
   otros SoC) y todas sus filas son la misma fuente con el mismo divisor, así que el cambio sube hasta el PLL a través
   del posdivisor de solo lectura (`clk_alpha_pll_postdiv_ro_ops`, ÷2) (`gpucc-khaje.topaz-t-oss.c:97-118, 234-258`).
3. `clk_zonda_pll_set_rate()` (`clk-alpha-pll.c:2583-2626`): calcula L y alpha (con L al entero más cercano si alpha
   tiene el bit 15), escribe **alpha y luego L con el PLL en marcha**, y si el PLL está encendido espera 5 µs, sondea
   `ZONDA_PLL_FREQ_LOCK_DET` (bit 29) si `TEST_CTL` tiene `ZONDA_STAY_IN_CFA` (bit 16) o `PLL_LOCK_DET` (bit 31) si no
   (`wait_for_pll`: 100 lecturas a 1 µs, `:300-330`), y espera 100 µs "for PLL output to stabilize". No apaga la salida,
   no pasa por standby y no mueve el RCG.
4. La clase de voltaje: `clk_pre_change_regmap()` vota el nivel nuevo antes del cambio si es más alto;
   `clk_post_change_regmap()` lo baja después si es más bajo (`clk-regmap.c:106-181`). El RCG vota VDD_CX por
   frecuencia y el PLL VDD_MX por VCO.

### 3.3 Temperatura en Android (este teléfono)

- DT: la zona `gpu` usa el sensor 15 de `tsens0` con `polling-delay-passive` 10 ms y disparos pasivos a 95 °C
  (`gpu-trip`, histéresis 0, dispositivo de enfriamiento `msm_gpu` sin límites) y 100 °C (`gpu-cx-mon`, histéresis
  5 °C: `msm_gpu` desde el estado 4, más módem y CDSP), y 115 y 125 °C para reinicio y `thermal-engine` (DT:6036-6100).
- O (lectura de Android por el coordinador, `android/estado-reposo.txt`): los disparos de la zona `gpu` son 95, 100 y
  125 °C; los de CPU 110/115 °C. El dispositivo de enfriamiento `devfreq-5900000.qcom,kgsl-3d0` tiene 6 estados (uno
  por nivel por debajo del máximo: el estado 4 es el nivel 4, 600 MHz).
- O (`android/serie-30s.txt`, ambiente caluroso): en reposo la GPU está a 41-43 °C y la CPU a 42-48 °C; con 30 s de
  uso la GPU llega a 55 °C y la CPU a 56 °C, y **ningún dispositivo de enfriamiento se activa**. Android baja la GPU
  en reposo por ocupación, no por temperatura. En ese Android el cluster gold tiene `scaling_max_freq` = 2400 MHz
  (iOS lo fija en 2803,2: 11 §12).

## 4. Lo que hace hoy iOS

`power_up()` (0337) vota CX/MX y los picos para la frecuencia de `gpu_mhz`, programa el PLL y deja la GPU ahí: no hay
escalado, ni apagado de relojes en reposo, ni lectura de temperatura, ni votos de bus (09 §5, 11 §5). A 1260 MHz fijos
el teléfono se calienta y el usuario ve fallos gráficos (03 M7); la imagen en uso es de 820 MHz.

## 5. Parche 0343: relojes y temperaturas medidos (solo lectura)

`0343-sapphire-gpu-clocks-thermal-diag.patch` (+313, aplica sobre 0342). Es la parte de relojes del borrador 0339 de
11 §8.1, renumerado, sin sus escrituras en `hw_init_regs` (esas no son de solo lectura), más los sensores y el DDR.

| sysctl | Qué da |
|---|---|
| `kern.sweet_gpu_clocks` | Medidos en el momento (≈ 0,2 s): `gx_gfx3d`, `cx_gmu`, `gcc_gpu_memnoc_gfx`, `gcc_bimc_gpu_axi`, DDR (periodo y fila del plan), CPU gold y silver |
| `kern.sweet_ddr_khz` | El reloj del DDR en kHz, del registro de periodo de `mccc` (0x447d220); no necesita la GPU |
| `kern.sweet_thermal` | Los 16 sensores TSENS por nombre de zona, en m°C, y el estado del controlador (`SROT_CTRL`) |
| `kern.sweet_gpu_temp` | El sensor de la GPU (15), en m°C |
| `gpu_clkdiag=1` (boot-arg) | Las dos líneas en el log tras el encendido |

- **Medición de relojes:** el procedimiento de `clk_measure` de stock (`clk-debug.c:91-190`; constantes `:45-53`):
  el multiplexor de depuración de GCC (+0x62000, divisor +0x30000, rama +0x30004) elige el reloj, el contador corre
  contra XO/4 (4,8 MHz) con una pasada corta y una larga (si coinciden, el reloj está parado), y
  `f = ((n × 10 + 15) × 4,8 MHz) / (ticks × 10 + 35)` por los divisores del camino. Entradas de
  `debugcc-khaje.c`: GPU CC 0xed (su multiplexor en GPU CC +0x1568, divisor 2 en +0x10fc, rama +0x1100; `gx_gfx3d`
  0x0b, `cx_gmu` 0x18), `gcc_gpu_memnoc_gfx` 0xee, `gcc_bimc_gpu_axi` 0x97, APSS 0xb6 (multiplexor en 0xf11101c,
  divisor fijo 8; 1 = gold, 0 = silver).
- **DDR:** `mccc_debug` (DT:6311-6315), registro de periodo en +0x20, en ps; `f = 10¹² / periodo`
  (`clk-debug.c:466-475`). 478 ps = 2092 MHz; 643 ps = 1555 MHz; 983 ps = 1017 MHz.
- **TSENS:** `tsens0` (DT:11328-11336): `compatible = "qcom,tsens24xx"`, SROT 0x4410000 (8 bytes), TM 0x4411000.
  `TM_Sn_STATUS` = TM + 0xa0 + 4n: bits 11:0 la última temperatura en décimas de grado con signo, bit 21 `VALID`
  (0 durante unos ciclos de AHB mientras llega un valor nuevo: se sondea hasta 20 veces a 1 µs).
  `SROT_CTRL` (+4): bit 0 encendido, bits 3..18 sensores activos. Nombres (zonas que usan cada sensor, DT:5438-6039):
  0 `mapss`, 1 `cdsp-hvx`, 2 `wlan`, 3 `camera`, 4 `video`, 5 `mdm-1`, 6-9 `cpu-1-0`..`cpu-1-3`, 10-12
  `cpuss-0`..`cpuss-2`, 13 `mdm-0`, 14 `display`, 15 `gpu`.
- **Locking:** la medición de relojes va bajo su propio candado (`clk_lock`); las páginas del multiplexor de APSS, de
  `mccc` y de TSENS se mapean una vez en el primer uso (con `OSCompareAndSwapPtr`, sin fugas en una carrera).
- **Verificación:** `harness0343.cpp` compila el bloque real contra registros simulados: `gx_gfx3d` a 820 y 1260 MHz
  dentro de 100 kHz, CPU gold y silver por el divisor 8, un reloj parado da 0, las ramas de depuración y la de XO/4
  quedan como estaban, periodos 478/643/983 ps a su fila del plan, sensores con valor negativo, `VALID` tardío y nunca
  válido, informe truncado sin desbordar. 0 fallos.
- **Riesgo:** registros que iOS no ha tocado (multiplexores de depuración, `mccc`, TSENS); stock los lee y escribe
  desde EL1. Si alguno no fuera legible, el síntoma sería un cuelgue al leer ese sysctl. Desactivar: no leerlos.

## 6. Parche 0345: cambio de nivel en caliente

`0345-sapphire-gpu-opp-switch.patch` (+411 −6, aplica tras 0343). `kern.sweet_gpu_khz` (lectura y escritura) y
`kern.sweet_gpu_opp` (estadística). Requiere la ruta de stock de 0337 (`gpu_vco2=1` y un `gpu_mhz` de la tabla) y el
servicio de la GPU.

### 6.1 Secuencia

Subir de A a B:

1. `opp_lock` (serializa cambios; siempre antes que `service_lock`).
2. Votos de pico para B (`cx_ipeak_set` de 0337: cliente 1 desde 900 MHz, 10 desde 950; si el gestor de límites
   responde *danger* → `EAGAIN`, nada cambia).
3. CX al nivel de B si es mayor que el votado; MX al de 2B. Rechazo → `EIO` y se deshacen los votos de pico.
4. `service_lock`; esperar a que la GPU esté ociosa (`CP_RB_RPTR == WPTR` y `RBBM_STATUS` sin ocupación salvo el bit
   0 de AHB) hasta `gpu_opp_drain` ms (100). Con el candado tomado no entra trabajo nuevo, así que la cola se vacía en
   lo que tarde lo encolado. Si no → `EBUSY` y se deshacen los votos.
5. PLL: alpha y luego L, 5 µs, bit de enganche según `TEST_CTL[16]` (hasta 1 ms), 100 µs; comprobar L y alpha leídos.
6. Soltar `service_lock`; bajar los votos que sobren (ninguno al subir).

Bajar de A a B: pasos 1, 4, 5 con **L antes que alpha**, 6; y después del reloj, CX/MX al nivel de B y fuera los votos
de pico que B no necesita (orden de `clk_post_change_regmap` y de kgsl).

**Orden de L y alpha.** Stock escribe alpha primero en los dos sentidos. Entre las dos escrituras el PLL persigue la L
vieja con la alpha nueva: al bajar eso queda hasta medio paso de L por encima de la frecuencia vieja (9,6 MHz de
núcleo) con los raíles aún en el nivel viejo. El modelo de anfitrión lo muestra al bajar de 1260 (1260,8 MHz con CX
464) y de 1114,8 (1117,8 MHz con CX 416). 0345 escribe L primero al bajar: en los dos sentidos lo que persigue el PLL
entre escrituras queda en o por debajo de la mayor de las dos frecuencias. Con la GPU ociosa es una diferencia sin
consecuencia práctica, pero mantiene el invariante.

**Camino largo** (`kern.sweet_gpu_opp_park=1`, boot-arg `gpu_opp_park=1`): RCG a GPLL0 / 2 (300 MHz: por debajo de
toda fila, válido con cualquier nivel de raíl), PLL configurado y arrancado de nuevo desde standby como en el arranque
(`gpu_pll_start_vco` de 0337), RCG de vuelta. Es la alternativa si la actualización dinámica diera problemas.

### 6.2 Fallos a mitad y estado en que queda la GPU

| Fallo | Qué hace | Estado final |
|---|---|---|
| Nivel fuera de tabla o por encima del bin | `EINVAL` | Sin cambios |
| Sin ruta de stock, sin servicio, o tras un fallo irrecuperable | `ENODEV` | Sin cambios |
| Pico rechazado | `EAGAIN`, votos deshechos | Sin cambios |
| Voto de raíl rechazado al subir | `EIO`, votos de pico deshechos | Sin cambios (el voto que sí entró queda: más alto es seguro) |
| GPU sin vaciar en el tiempo | `EBUSY`, votos deshechos | Sin cambios |
| PLL sin enganche en 1 ms | Camino largo a la frecuencia vieja; `EIO` | Frecuencia vieja, votos de la vieja |
| … y el reinicio tampoco engancha | RCG queda en GPLL0 / 2 | 300 MHz, cambios rechazados en adelante, votos de 300 MHz |
| El RCG no completa un cambio de fuente | `service_ready = false` | Servicio parado: copias por CPU, Metal recibe NotReady |

Leer un registro de la GPU con su reloj parado cuelga el bus (cabecera de `SapphireGpu.cpp`); por eso un RCG que no
termina un cambio apaga el servicio, que es lo único que lee registros de la GPU después.

### 6.3 Verificación en anfitrión

`harness0345.cpp` compila el código real de 0337 (PLL, picos) y de 0345 contra un modelo del PLL Zonda (L, alpha,
enganche con retardo, `TEST_CTL`, salida), del RCG (`UPDATE`, fuente, divisor), de la GPU (ocupada N lecturas o
siempre), del RPM (acepta o rechaza CX 464) y de `cx_ipeak` (*danger*). En **cada escritura de registro** comprueba:
I1 núcleo ≤ `rate_max` del CX votado; I2 VCO ≤ `rate_max` del MX votado; I3 votos de pico presentes desde 900/950 MHz;
I4 el PLL solo se escribe con `service_lock` tomado y la GPU ociosa; y el orden de candados. 12 escenarios: subir y
bajar con su orden de votos, GPU que no se vacía y que se vacía a tiempo, pico rechazado, CX 464 rechazado, PLL sin
enganche con y sin reinicio bueno, RCG atascado, camino largo, validación de peticiones, toda la escalera de stock en
los dos sentidos y en los dos modos, contabilidad de tiempo por nivel. Resultado: 0 fallos, 0 violaciones de
invariantes, 0 errores de candado (`work/harness0345.log`).

Secuencias del modelo (eventos en orden):

    820 → 1260:  [ipeak 0x2000=1] [ipeak 0xe000=1] [cx 464] [alpha 0x4000] [L 131]
    1260 → 320:  [L 33] [alpha 0x5555] [cx 416] [ipeak 0x2000=0] [ipeak 0xe000=0]
    GPU ocupada: [ipeak …=1] [cx 464] [cx 416] [ipeak …=0]   (EBUSY, PLL intacto)
