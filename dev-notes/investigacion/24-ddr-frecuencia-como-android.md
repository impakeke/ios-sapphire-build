# 24 — El DDR a las frecuencias de Android: escalado de relojes del RPM y gobernador del DDR

Cómo se decide la frecuencia del DDR en el SM6225 «khaje» (familia bengal/SM6115) de este teléfono, qué hace Android y
qué hace el kernel del port, y el diseño y los parches (0360 en adelante, fuera del repo) para que bajo iOS el DDR
recorra las mismas filas que bajo Android con una lógica equivalente, apagado por defecto y con vuelta atrás.
Informe del 14 de noviembre de 2026 sobre la serie `xnu/patches/` hasta 0353 (xnu-8796.141.3). Antecedentes:
[11](11-gpu-relojes-bus-vs-android.md) §4.5 y §10, [17](17-gpu-escalado-termica-ddr.md) §4.3 y §8 (0347),
[22](22-blur-de-coreanimation.md) §3.1, [16](16-planificador-e-hilos.md) §3.4 y [03](03-experimentos-y-datos.md) M10, M24.

Convenciones: **[O]** = observación leída en una fuente primaria (código, binario, DT, documento), **[M]** = medida en
el teléfono, **[H]** = hipótesis o inferencia; «no verificado» cuando no hay ni lo uno ni lo otro. **DT:N** = línea N de
`~/sapphire-angel/research/metal/relojes/dtb/merged-khaje24a-sapphire.dts`. Material pesado en
`~/sapphire-angel/research/metal/ddr/` (§2).

## 1. Resumen

1. **[O] El DDR lo mueve el RPM, no el sistema operativo:** el SO vota el reloj del BIMC (`clk2` 0, clave «KHz») y el
   RPM elige la fila del plan (200; 547,2; 768; 1017,6; 1555,2; 1804,8; 2092,8 MHz). Hasta que el SO enciende el
   escalado de relojes del RPM («Enab» = 1 en `clk0` 2, que el firmware de Qualcomm llama `/clk/dcvs.ena`), el RPM no
   aplica votos de tasa (§3).
2. **[M] Bajo iOS el DDR está en 1555,2 MHz porque ahí lo deja el XBL** («Bootup frequency set to», [O] en su código)
   y nada en este kernel enciende el escalado: el RPM acepta votos de 1 761 719, 2 042 969 y 2 147 483 647 kHz y el
   DDR no se mueve (§3.2, §4.3).
3. **[O] Android en este teléfono** (binario `clk-smd-rpm.ko` desensamblado): BIMC a `INT_MAX` en el set activo,
   «Enab» en reposo y activo, y XO, CNOC, SNOC y QUP con votos de mantenimiento; después cada consumidor vota sus buses
   por interconexión. Linux mainline traspasa además todos los relojes a `INT_MAX` antes del «Enab» (§3.3, §3.4).
4. **[O] La política de Android** (§4): memlat (sus monitores *compute*: frecuencia × ocupación de cada CPU) no deja
   bajar de 547,2 MHz con una CPU despierta y pide 2092,8 con un A73 ocupado; kgsl pide 2092,8 con la GPU en sus dos
   niveles altos; bwmon sube con el tráfico de las CPU. En reposo con la pantalla encendida, 547,2; con carga, 2092,8.
5. **Comunidad** (§5): Linux mainline y postmarketOS (SM6115/SM6225) encienden el escalado tras el traspaso; topaz-woa
   y los ports de XNU de SM6225 no; tres ports de XNU en MSM8996/8998 lo encienden tras el traspaso, y uno registra el
   BIMC de 648 a 902 MHz con él y ningún cambio sin él [S].
   El coste de un cambio de frecuencia publicado va de < 1 µs (lado DRAM, LPDDR4 con FSP) a 10-30 µs (SoC).
6. **El peligro de encenderlo** (§7.4, §9): con el escalado activo, un bus del RPM que nadie vota se apaga; en iOS
   ningún driver vota sus buses (CNOC, SNOC, MMRT…), así que hay que votarlos antes.
7. **Parches** (§7; fuera del repo, `ddr/parches-nuevos/`): **0360** empareja cada respuesta del RPM con su petición
   («msg#»); **0361** enciende el escalado tras traspasar todos los buses a `INT_MAX` y el BIMC a su fila actual (el
   DDR no se mueve en el cambio), y añade un gestor del DDR con la GPU (0347), suelo, tope, bajada con retardo y tope
   térmico; **0362** añade la entrada de las CPU como los monitores *compute* de memlat. Todo apagado por defecto
   (`kern.sweet_bus_scale=0`), con lectura (`kern.sweet_bus_clocks`, `kern.sweet_bus_stats`) y vuelta atrás.
8. **Verificación en anfitrión** (§8): aplican en orden sobre 0353; sintaxis sin errores ni avisos nuevos; un arnés
   que compila el código real contra un modelo del RPM pasa 144 comprobaciones, entre ellas que **los 56 bytes de cada
   petición son los de Linux v6.12 y los del Android de stock**.
9. **Siguiente:** el protocolo de §10 en el teléfono (solo lectura → escalado con el DDR quieto → filas a mano → gestor
   → suelo de Android), con `kern.sweet_ddr_khz`, `memlat`, las pasadas del Centro de Control y la temperatura.

## 2. Material y método

| Clave | Qué | Dónde (`~/sapphire-angel/research/metal/`) |
|---|---|---|
| **L** | Linux v6.12 (mainline): `clk-smd-rpm.c`, `icc-rpm.c`, `sm6115.c` | `relojes/ref/linux/` |
| **L+** | Linux v6.12: `smd-rpm.c`, `smd-rpm.h`, `icc-rpm-clocks.c`, `interconnect/qcom/smd-rpm.c`, `qcom_glink_native.c`, `qcom_glink_rpm.c`, `interconnect/core.c` | `ddr/ref/linux-v6.12/` (`raw.githubusercontent.com/torvalds/linux/v6.12/...`, sha256 en `SHA256SUMS`) |
| **MI** | Kernel de Xiaomi `topaz-t-oss` @ `345999da` (msm-5.15, mismo SoC): `clk-smd-rpm.c`, `icc-rpm.c`, `bengal.c`, `debugcc-khaje.c`, `gcc-khaje.c`, `dcvs/*` | `relojes/ref/downstream/` |
| **MI+** | El mismo árbol: `drivers/rpmsg/rpm-smd.c`, `include/soc/qcom/rpm-smd.h`, `interconnect/qcom/icc-rpm.h` | `ddr/ref/downstream-topaz/` |
| **KO** | Módulos del `vendor_boot_b` de este teléfono (5.15.94): `clk-smd-rpm.ko`, `rpm-smd.ko`, `qnoc-bengal.ko`, `icc-rpm.ko`, `bwmon.ko`, `memlat.ko`, `qcom-dcvs.ko` | `relojes/vendor_ramdisk/lib/modules/` |
| **X** | Árbol del port a 0353: `kernel-gpu/parches-nuevos/work/xnu` (a 0342) + 0343-0353 de `xnu/patches/` con `git apply`, un commit por parche; las líneas X:N de este informe son del commit de 0353 (`f7b23db`), y 0360-0362 van encima | `ddr/xnu-0353/` |
| **AND** | Política de Android en este teléfono, XBL y `rpm.mbn` (agente de esta investigación): notas, descargas con su procedencia, guiones, volcados | `ddr/android/` (`NOTAS.md`) |
| **LIT** | Literatura y comunidad (agente de esta investigación): notas, clones fijados, guiones | `ddr/literatura/` (`NOTAS.md`) |
| **P** | Parches 0360-0362, el árbol con un commit por parche, el arnés y su log | `ddr/parches-nuevos/`, `ddr/xnu-0353/`, `ddr/work/harness/` |

Del teléfono, en solo lectura y sin escribir ninguna sysctl: `sysctl -n` de `kern.sweet_*` existentes (14 nov, kernel con la imagen `boot_a` en uso, boot-args con `gpu_vco2=1 gpu_mhz=820`; `kern.sweet_ddr_khz` = 1555210; el módem y el IPA en marcha). El ring del log no se puede leer con la raíz
montada (`/dev/ufsroot0`: *Resource busy*, igual que en 11 §2).

## 3. Quién mueve el DDR en esta plataforma (mecanismo)

### 3.1 La cadena

1. **[O] El DDR es un recurso del RPM.** Su reloj es el recurso `clk2` («mem clk», `QCOM_SMD_RPM_MEM_CLK` =
   0x326b6c63) id 0, el `bimc_clk` de `clk-smd-rpm` (MI `clk-smd-rpm.c:1125`; L `clk-smd-rpm.c:468`; KO
   `holi_bimc_clk`: tipo 0x326b6c63, clave 0x007a484b «KHz», id 0, tasa inicial `INT_MAX`). El sistema operativo no
   programa el controlador de memoria: manda al RPM una frecuencia en kHz y el RPM elige la fila del plan.
2. **[O] El plan del DDR** tiene siete filas: 200; 547,2; 768; 1 017,6; 1 555,2; 1 804,8 y 2 092,8 MHz (DT:7648-7649,
   `ddr-freq-table` en kHz redondeados: 200000 … 2092000; y la tabla de `xbl_a`, 11 §10.1).
3. **[O] El valor que vota Android para el BIMC es `ib / 8`** con `ib` en kB/s: el driver de interconexión agrega por
   proveedor `max(Σab × util / canales, máx ib) / buswidth` (MI `icc-rpm.c:132-151`) con el `buswidth` 8 del nodo `ebi`
   (17 §3.1) y lo pasa a `clk-smd-rpm`, que lo manda en kHz redondeando hacia arriba (MI `clk-smd-rpm.c:231-235`). Las tablas de bus de Android
   (kgsl, 17 §3.1) votan un 97,7 % de 8 bytes por ciclo de cada fila: el RPM toma la fila que cubre el voto [H, sin la
   fuente del RPM; coherente con todas las tablas del DT].
4. **[O] La frecuencia en curso se lee** en el periodo del bloque `mccc` (0x447d200 + 0x20, en ps; DT:6311-6315;
   `clk-debug.c` de MI: `f = 10¹² / periodo`), lo que hace `kern.sweet_ddr_khz` (0343).

### 3.2 El escalado de relojes del RPM

- **[O] Mientras el sistema operativo no lo activa, el RPM no aplica los votos de frecuencia.** Linux lo dice en el
  comentario de `struct rpm_smd_clk_desc`: los relojes de interconexión se «arrancan» (voto al máximo) «so that they
  don't get gated between clk_smd_rpm_enable_scaling() and interconnect driver initialization» (L
  `clk-smd-rpm.c:173-185`, comentario en :177-180). El interruptor es el recurso `clk0` («misc clk», 0x306b6c63) id 2
  (`QCOM_RPM_SCALING_ENABLE_ID`), clave «Enab» (0x62616e45), valor 1, primero en el set de reposo y luego en el activo
  (L `clk-smd-rpm.c:402-429`; MI `clk-smd-rpm.c:395-423`; L+ `include/linux/soc/qcom/smd-rpm.h`). El firmware de
  Qualcomm lo llama «DCVS enable»: la cadena `/clk/dcvs.ena` está en el `ClockDxe` del UEFI de SM6225 (tapas), que la
  define como (`clk0`, 2, «Enab») con estado inicial 0, y en el `rpm.mbn` de este modelo (§5.3).
- **[M] Coherente con lo medido:** con el kernel 0353, el RPM acepta (respuesta 0) votos del BIMC de 1 761 719,
  2 042 969 y 2 147 483 647 kHz y el DDR sigue en 1 555 210 kHz 20 ms después (03 M24; `kern.sweet_gpu_ddr_stats` el
  14 nov a las 14:49, hora del teléfono: «votes 4 … last vote 2147483647 kHz (answer 0): DDR 1555210 kHz before,
  1555210 kHz 20 ms after»).
- **[H] Consecuencia de activarlo:** cada reloj de bus del RPM pasa a valer el agregado de los votos de todos los
  maestros (APSS, módem, ADSP…). Un reloj que nadie vota se apaga o baja al mínimo; si es el de un bus por el que el
  procesador accede a registros, el siguiente acceso cuelga sin pánico. De ahí el traspaso previo (§3.3).

### 3.3 Lo que hace Android en este teléfono al arrancar (verificado en el binario)

`clk-smd-rpm.ko` del teléfono, `rpm_smd_clk_probe` (desensamblado de KO, direcciones del módulo):

1. 0x940-0x974: `msm_rpm_send_message(set 0 = activo, "clk2", 0, {KHz, 4, 0x7fffffff})`: **el BIMC al máximo en el
   set activo** (es `clk_vote_bimc(INT_MAX)` de MI `clk-smd-rpm.c:425-443, 1394-1400`).
2. 0x99c-0x9ec: busca `qcom,hw-clk-handoff`; el DT de este teléfono no lo tiene (nodo `rpmcc`, DT:6257-6260), así que
   no hay traspaso del resto de relojes.
3. 0x9f0-0xa40: `msm_rpm_send_message(1 = reposo, "clk0", 2, {Enab, 4, 1})` y, si devuelve 0, el mismo mensaje con
   set 0: **el escalado, en reposo y en activo**.
4. 0xac0-0xb8c: registra los relojes y deja votos de mantenimiento en el set activo: XO (`bi_tcxo_ao`) encendido,
   `cnoc_a`, `snoc_a` y `qup_a` a 19,2 MHz (`clk_set_rate(…, 0x124f800)`); MI `clk-smd-rpm.c:1441-1459`.

Después, el driver de interconexión (`qnoc-bengal.ko`, MI `bengal.c`) vota los seis relojes de bus que tienen
proveedor (BIMC, CNOC, SNOC, QUP, MMRT, MMNRT; DT:3227-3285, los seis con `qcom,keepalive`): mientras no han arrancado
todos los consumidores (`qp->init`) los mantiene al máximo en el set activo, y al final (`qnoc_sync_state`) los deja en
lo que agreguen los consumidores, nunca por debajo de 19,2 MHz en el set activo (MI `icc-rpm.c:153-178`,
`bengal.c:1638-1677`; `RPM_CLK_MIN_LEVEL` = 19 200 000 Hz en MI+ `icc-rpm.h:22`).

**[O] Los votos del set de reposo no salen al momento en Android:** `rpm-smd.ko` los guarda en un árbol y los manda
justo antes de que el clúster entre en reposo profundo (MI+ `rpm-smd.c` `msm_rpm_smd_buffer_request` :662-702,
`msm_rpm_send_data` :1267-1270, `msm_rpm_flush_requests` :708-747; KO `rpm-smd.ko` tiene esos símbolos y
`rpm_smd_power_cb`). El «Enab» del set de reposo llega al RPM la primera vez que el APSS duerme.

### 3.4 Lo que hace Linux mainline (v6.12) para sm6115

`rpm_smd_clk_probe` (L `clk-smd-rpm.c:1257-1339`): traspaso de **todos** los relojes de la tabla del SoC y de los de
interconexión (`clk_smd_rpm_handoff`: `INT_MAX` o 1 si es una rama, en el set activo y en el de reposo, L :189-210),
después el escalado (reposo y activo). Para sm6115 los de interconexión son BIMC, CNOC, MMNRT, MMRT, QUP y SNOC
(`sm_qnoc_icc_clks`, L :568-575). Los seis proveedores de `sm6115.c` llevan `keep_alive` (L `sm6115.c:1215-1390`):
el set activo nunca baja de 19,2 MHz (`ICC_BUS_CLK_MIN_RATE`, L `icc-rpm.c:51`, :382-383).

### 3.5 El protocolo, byte a byte

Transporte GLINK sobre la RAM de mensajes del RPM (0x45f0000, 0x7000 bytes, DT:6394-6397; tabla de contenidos «grt0»
en los últimos 256 bytes con las FIFO «ap2r» y «r2ap», L+ `qcom_glink_rpm.c:25-31, 213-280`; timbre en el registro IPC
del APCS, 0xf111000 + 8, bit 0, DT:6400-6404 y `mboxes = <… 0>` DT:6536). Canal «rpm_requests», sin *intents*.

Una petición de un par clave-valor ocupa 56 bytes en la FIFO:

| Desplazamiento | Campo | Valor | Fuente |
|---|---|---|---|
| 0 | `cmd` (u16), `param1` (u16) | 9 (`TX_DATA`), lcid | L+ `qcom_glink_native.c:209, 1516-1517` |
| 4 | `param2` | 0 (iid; canal sin *intents*) | :1518 |
| 8 | `chunk_size`, `left_size` | 40, 0 | :1519-1520 |
| 16 | `service_type`, `length` | 0x00716572 «req», 32 | L+ `smd-rpm.c:80, 120-121` |
| 24 | `msg_id`, `flags` | contador, 0 activo / 1 reposo | :123-124 |
| 32 | `type`, `id`, `data_len` | recurso, id, 12 | :125-127 |
| 44 | `key`, `nbytes`, `value` | p. ej. «KHz», 4, kHz | `struct clk_smd_rpm_req` |
| 56 | (relleno a 8) | — | L+ `qcom_glink_rpm.c:189-191` |

La respuesta es otro `TX_DATA` con «req» y una lista de mensajes: «msg#» con el `msg_id` y, si se rechaza, «err» con
un texto («resource does not exist» → `-ENXIO`, otro → `-EINVAL`; L+ `smd-rpm.c:147-193`). Android usa el formato V0,
el mismo: el nodo `qcom,rpm-smd` no tiene `reg` (DT:3763-3769), así que `rpm-smd.c` no lee «rev1» y se queda en V0
(MI+ `rpm-smd.c:1572-1611`); su cabecera V0 (`struct rpm_message_header_v0`, :155-162) tiene los mismos campos en el
mismo orden.

## 4. La política de Android: quién pide qué fila

Fuente: `~/sapphire-angel/research/metal/ddr/android/NOTAS.md` (agente de esta investigación; cada punto lleva allí su
archivo:línea, dirección del binario o línea del DT). Los módulos `qcom-dcvs.ko`, `bwmon.ko` y `memlat.ko` del teléfono
coinciden con MI en cada constante, desplazamiento de registro y paso de agregado comprobados, y son idénticos byte a
byte a los de `Evolution-X-Devices/device_xiaomi_sapphire-kernel@e813901` (sus §1).

### 4.1 Cómo se agrega

- **[O]** `qcom-dcvs` toma, para el DDR, `ib` = máximo de bwmon, memlat y `boost_freq`, redondeado hacia arriba a
  `ddr-freq-table` (DT:7649), y `ab` = suma; lo pasa a interconexión como `ib` = kHz × 8 kB/s (MI `dcvs.c:263-339`,
  `dcvs_icc.c:32`). Sus votos llevan la etiqueta 3 y cuentan **solo en el set activo**; kgsl (A610 sin GMU) y la
  pantalla van sin etiqueta y cuentan en los dos sets (MI `icc-rpm.c:80-83`).
- **[O]** `boost_freq` arranca en el máximo y el *post-boot* de stock lo suelta en `sys.boot_completed`
  (`init.kernel.post_boot-bengal.sh:335-338`): durante el arranque de Android el DDR está a 2092,8 MHz.
- El RPM recibe por proveedor `max(Σab × 1,53 / canales, máx ib) / 8` (BIMC con `qcom,util-factor` 153, DT:3280).

### 4.2 Los que piden

| Quién | Qué mide | Qué pide | Fuente |
|---|---|---|---|
| memlat, monitores *compute* (silver, gold) | Por CPU, frecuencia × fracción ocupada (muestra de 8 ms) | Primera fila de su `qcom,cpufreq-memfreq-tbl` que no queda por debajo; nunca menos de 547 000 kHz | [O] MI `memlat.c:689-705`; DT:7712-7726 |
| memlat, monitores silver y gold | Igual, solo CPU con instrucciones por fallo de L2 (evento 0x17 del PMU, `L2D_CACHE_REFILL`) ≤ 400 | Sus tablas (más altas a frecuencia media) | [O] DT:7698-7710 |
| bwmon4 | Bytes del puerto de las CPU hacia el EBI, en unidades de 64 KiB, por ventana de 4 ms (ajuste de stock) | `ib` = pico × 100 / 85; `ab` redondeado a 190 MiB/s; zonas 762…7980 | [O] MI `bwmon.c:475-658`; *post-boot* de stock |
| kgsl | Nivel de la GPU | `ib` de `qcom,bus-table-ddr` por nivel (17 §3.1); 2092,8 MHz en los niveles 0-1 | [O] DT:7953 |
| Pantalla (SDE) | — | `ib` 2,4 GB/s al encender; después `ab` del HAL con `ib` 0 | [O] DT:15212; CLO `sde_core_perf.c:684-760` |
| UFS, cámara, IPA, vídeo | Su tráfico | UFS HS-G3 2 carriles `ab` 4,19 GB/s (≈ 1017,6 tras × 1,53); cámara `ib` ≥ 3 GB/s | [O] DT |
| HAL de energía | Toque, arranque de app | QTI: `min_freq` de bwmon 768 000 al tocar; libperfmgr: `boost_freq` 1 555 000 al tocar, 2 092 000 3 s al lanzar | [O] configuraciones; cuál lleva este Android: no verificado |
| Térmica | — | Nada limita el DDR desde el espacio de usuario; `rpm-smd-cdev` queda en la banda 2 | [O] |

### 4.3 Filas y niveles por escenario

**[O]** Plan del XBL de este teléfono (tabla B, xbl+0xC810; filas de 20 bytes: kHz, habilitada, nivel de `vddcx`, de
`vddmx`, PLL): 12 filas, 7 habilitadas, que son las del DT. La tabla del BIMC del RPM (`rpm.mbn` de los paquetes de
firmware de Xiaomi para este modelo, `RPM.BF.1.10-00218`, archivo 0x30C50) tiene 11 niveles **sin banderas**: 200,
300, 451,2, 547,2, 681,6, 768, 1017,6, 1353,6, 1555,2, 1804,8 y 2092,8 MHz. Que ese `rpm.mbn` sea el del teléfono no
está verificado (no hay copia de la partición `rpm`).

| Fila | DDR (MHz) | Periodo `mccc` (ps) | Voto del BIMC que la elige (kgsl, `ib`/8, kHz) | Quién la pide en Android |
|---|---|---|---|---|
| 0 | 200 | 5000 | 195 313 | Solo el set de reposo (pantalla a 60 Hz con todas las CPU dormidas) [H] |
| 1 | 547,2 | 1827,5 | 534 180 | Suelo de memlat con cualquier CPU despierta: reposo con la pantalla encendida |
| 2 | 768 | 1302,1 | 750 000 | Toque con el HAL QTI; A53 ocupado al 80 % |
| 3 | 1017,6 | 982,7 | 993 164 | A53 al máximo; UFS en carga |
| 4 | 1555,2 | 643,0 | 1 518 555 | Donde lo deja el XBL; GPU a 785 MHz |
| 5 | 1804,8 | 554,1 | 1 761 719 | GPU a 1025 MHz; A73 ocupado ≤ 2208 MHz efectivos |
| 6 | 2092,8 | 477,8 | 2 042 969 | GPU a 1114,8/1260 MHz; un A73 ocupado (a 2400 o a 2803,2 MHz); arranque de Android |

**Niveles esperados en Android** [O política; H en el redondeo del RPM]: en reposo con la pantalla encendida, **547,2
MHz** (suelo de memlat); con un hilo ocupando un A73 (tope de 2400 MHz), **2092,8** (y 1804,8 si el núcleo está
ocupado menos del ~92 %); con la GPU en sus dos niveles altos, **2092,8** aunque las CPU duerman; la pantalla sola,
547,2 recién encendida y 200-547,2 después según la frecuencia de refresco. Bajo iOS hoy: 1555,2 siempre [M].

**[O] El XBL deja el DDR en 1 555 200 kHz:** `va 0xC23D770` fija `min(fila más alta, 0x17BB00)` y escribe «Bootup
frequency set to %u» y, antes de saltar, «DDR Frequency, %d MHz» (agente B, §4.3; desensamblado en
`ddr/android/work/xbl/fw_key_disasm_xbl_a.txt:344-400`). Es exactamente lo medido bajo iOS (643 ps): el kernel del
port nunca ha movido el DDR. El XBL publica además en el ítem 603 de SMEM (+0xC0) la dirección 0x0447D220, el
registro de periodo que lee 0343.

## 5. Literatura y comunidad

Fuente: `~/sapphire-angel/research/metal/ddr/literatura/NOTAS.md` (agente de esta investigación; citas con URL, commit
y página; clones en `literatura/clones/`). Lo que este informe usa:

### 5.1 Coste de un cambio de frecuencia

- **[O] Lado DRAM (LPDDR4/4X):** con dos *Frequency Set Points* (MR13 OP[6] FSP-WR, OP[7] FSP-OP) el cambio es una
  escritura de MR13 más tFC, sin reentrenar; tFC_short/middle ≥ 200 ns, tFC_long ≥ 250 ns, tVRCG 200/100 ns (Micron
  z32m Rev F p. 205, tabla 136; Micron z42m p. 200; Nanya NT6AN p. 192: n = 3 hojas de datos). Con siete filas hay que
  reescribir el FSP inactivo antes de cada cambio: ~0,5 µs del lado DRAM [H]. El estándar JESD209-4 no se pudo leer
  (jedec.org devolvió 403).
- **[O] Lado SoC (ninguna cifra de Qualcomm):** SysScale (Haj-Yahya et al., ISCA 2020) < 10 µs; David et al. (ICAC
  2011) < 20 µs estimados; Linux i915 bloquea la memoria 10-30 µs por cambio de SAGV (`skl_watermark.c:105-133` en
  v7.3); AMD presupone 11,65 µs con LPDDR4 (`dcn20_fpu.c:952-987`); Tegra30 espera el cambio hasta 100 µs y Tegra210
  separa cambios ≥ 100 µs; una patente de NVIDIA habla de «decenas de microsegundos» [S].
- **Ventanas de decisión publicadas:** 4 ms (icc-bwmon), 5 ms (MemScale), 8 ms (memlat de stock), 12 ms (ACTMON de
  Tegra), 20 ms (MIF del Pixel 7), 30 ms (SysScale). [H] El coste de un cambio es < 1 % de cualquiera de ellas; lo que
  pide es histéresis para no oscilar, no ventanas largas. 0361 mide el de este teléfono (§8, `sw_us`).

### 5.2 Gobernadores

- **[O]** memlat y bw_hwmon nacieron en el kernel de Qualcomm (CodeAurora), no en LKML; mainline tiene
  `drivers/soc/qcom/icc-bwmon.c` (2022), con el mismo bloque y un binding que lo describe como el monitor del tráfico
  de las CPU hacia la memoria. En sm6115 mainline, `pmu@1b8e300` (`qcom,sm6115-cpu-bwmon`) vota el camino
  `MASTER_AMPSS_M0 → SLAVE_EBI_CH0` con una tabla OPP de 200 a 1804 MHz (sin la fila de 2092,8 de khaje).

### 5.3 Fuera de Android en SM6115/SM6225

| Sistema | ¿Activa el escalado del RPM? | Detalle | Nivel |
|---|---|---|---|
| Linux mainline (sm6115) y el kernel SM6225 de postmarketOS (gitlab.nura.eco `sm6225-mainline`, `b8463e4b`, `qcom,rpmcc-sm6115`) | **Sí**, en cada arranque | Traspaso a `INT_MAX` de todos los relojes del RPM en activo y reposo, «Enab» en reposo y en activo, interconexión con mínimo de 19,2 MHz en activo | [O] código; ninguna medida publicada de la frecuencia del DDR: no verificado que escale |
| topaz-woa (Windows en el Redmi Note 12 4G) | **No** | Vota el BIMC a mano (`drivers/TopazRpm/driver.c:448-451`, `bfe5c15f`) y no mide el DDR | [O] |
| UEFI de Qualcomm para SM6225 (tapas) | **No** | `ClockDxe` define `/clk/dcvs.ena` = (`clk0`, id 2, «Enab») con estado inicial 0; el `ClockDxe.patched.efi` comunitario ni define los recursos del RPM | [O] (comprobado aquí: la cadena está en `ClockDxe.efi` de tapas) |
| Kernels Android de la comunidad (bengal/khaje) | Sí | Heredan la secuencia de Qualcomm sin cambios | [O] |

El nombre que da el firmware de Qualcomm a `clk0` id 2 es «DCVS enable»: la cadena `/clk/dcvs.ena` está en el
`ClockDxe` de tapas y en el `rpm.mbn` de este modelo (comprobado aquí con `grep`/`strings`).

### 5.4 Otros ports de XNU con RPM por SMD/GLINK

| Port (SoC) | Commit | «Enab» | BIMC | Lee el DDR | Lo que registran sus autores |
|---|---|---|---|---|---|
| joranv1/ios-sailfish (MSM8996) | `6f27e41f` | Sí, tras traspaso de 22 recursos (`0147-…:52-125`) | Sí | Sí (mux de depuración de GCC) | Sin «Enab», el DDR sigue en 1016 MHz tras un voto aceptado de 1804 [S] |
| JeyKul/ios-b0s, rama taimen (MSM8998) | `a35fb7c1` | Sí, tras traspaso (`0224-…:150-170`) | Sí | Sí | Con traspaso y «Enab», BIMC de 648 a 902 MHz y memcpy de ~0,8 a 1,09 GB/s; pantalla y UFS sin efectos [S] |
| MC-XiaoXiao/ios_sagit (MSM8998) | `673f8507` | Sí, tras reenviar los valores heredados (`RPMClockHandoff.h:112-149`) | Sí | No | Añade la clave «max» por si un límite heredado recorta el voto [S] |
| AdyaGMD/ios-spes (SM6225) | `bdc2682e` | No | Sí | No | Voto aceptado, «DDR barely matters» medido como tiempo de GPU [S] |
| soumarcelino/fiio-jm21-xnu, MakrSas/ios-topaz (SM6225) | `6f8cb222`, `e4772911` | No | No | No | — |
| Angelpro09xd/ios-sapphire (origen de este port) | `341d7b02` | Solo a mano (op 6) | Solo a mano | No | Dice que con «Enab» y todo votado alto memcpy no cambió (2,2-2,5 GB/s); no midió el DDR [S] |

**Lo que matiza la hipótesis** (ninguno la contradice): (1) los mantenedores de Linux escriben que tras «Enab» todo
reloj sin voto del procesador se apaga y «the system will inevitably die» (`d6edc31f` y la carta de la serie v7) [S]:
de ahí el traspaso de 0361; (2) en firmware antiguo del RPM (msm8226/msm8974) el escalado va antes del traspaso y el
orden contrario reinicia el equipo (`e9a2db5c`) [S]; en los SoC nuevos, y en el `clk-smd-rpm.ko` de este teléfono, el
orden es traspaso → escalado [O]; (3) si tras «Enab» el DDR no sigue al voto, la causa siguiente a mirar es un límite
«max» heredado (clave 0x0078616d), que el UEFI de tapas añade a sus peticiones escalares en el set activo [O en
`NpaDxe`, efecto en el RPM no verificado]; (4) la memcpy de un solo núcleo no distingue frecuencias del DDR (16 §7).

## 6. Lo que hace hoy el kernel del port

### 6.1 El cliente del RPM (`TopazModem.cpp`, árbol X)

- **Transporte** (X `TopazModem.cpp:10916-11150`): el de `qcom_glink_rpm.c` escrito a mano. Lee la tabla de
  contenidos, pone a cero `head` de TX y `tail` de RX («as Linux: a fresh link»), negocia la versión y abre
  «rpm_requests» con lcid 1; los datos que llegan se procesan por sondeo (`rpm_poll`, 1 ms entre vueltas) solo mientras
  alguien espera una respuesta.
- **Mensajes**: `rpm_kvp` (un par clave-valor, :11238-11263) y `rpm_ldo` (tres pares para un LDO, :11202-11230), con
  la cabecera de §3.5; `msg_id` empieza en 1 y lo comparten los dos.
- **Exportados**: `topaz_rpm_vote(set, tipo, id, clave, valor)` y `topaz_rpm_ldo` (:11278-11306), con un candado
  (`rpm_lock`) que crea el primero que llama; espera la respuesta hasta ~1 s y devuelve 0, −2 (rechazado: «err»), −3
  (FIFO llena), −4 (sin respuesta) o −5 (canal sin abrir).
- **Votos que hace hoy** (inventario de llamadas en X):

| Quién | Recurso | Set | Valor | Cuándo |
|---|---|---|---|---|
| `SapphireGpu.cpp` (0204, 0337, 0345) | `rwcx` 0 «vlvl», `rwmx` 0 «vlvl» | activo | nivel del raíl | al encender la GPU y al cambiar de nivel |
| `SapphireGpu.cpp` (0347) | `clk2` 0 «KHz» (BIMC) | activo | `ib/8` del nivel; `INT_MAX` al apagarlo | solo con `kern.sweet_gpu_ddr` |
| `TopazModem.cpp` `ipa_hw_init` | `ipa` 0 «KHz» | activo y reposo | 100 000 | antes de arrancar el módem |
| `SweetQsee.cpp` | `ce` 0 «KHz» | activo | 192 000 | al empezar la secuencia de la huella |
| `TopazModem.cpp`, `SweetQsee.cpp`, `sweet_cam.c`, `sweet_bt.c` | LDO (`ldoa` 4, 9, 14, 18…) | activo (y reposo el 14) | µV, mA | al encender cada periférico |
| `kern.sweet_audio` op 6 (manual) | `clk2`, `clk1`, `clk0` («Enab»), `qup`, `ipa`, `mmxi`, `ce`, `rwcx` | el que se pida | el que se pida | a mano |

- **[O] Nada manda «Enab» en el arranque ni en ningún camino automático**; solo la vía manual (op 6) podría. Ningún
  código vota `clk1` (SNOC, CNOC, periféricos, LPASS), `qup`, `mmxi` (MMRT, MMNRT), `clk0` 0/1 (XO, QDSS).

### 6.2 Defectos del cliente

1. **La respuesta no se empareja con la petición** (X `TopazModem.cpp:11020-11041`): `rpm_answer` mira «err» pero no
   «msg#»; si una respuesta llega tarde (después de los ~1 s de espera, −4), la siguiente petición toma esa respuesta
   como suya, y el desfase sigue en las siguientes. Linux tampoco empareja, pero espera 5 s (L+ `smd-rpm.c:17, 134`).
   **0360** espera la respuesta cuyo «msg#» es el de la petición y descarta las demás contándolas.
2. **La vía del LDO14 del audio puede ir sin candado** (X `TopazModem.cpp:12334-12341`): toma `rpm_lock` solo si ya
   existe; si es la primera usuaria del RPM, escribe en la FIFO sin candado mientras otro hilo podría crear el candado
   y escribir a la vez. **0360** crea el candado siempre antes de usarlo.
3. **0347 con el escalado activado sería peligroso:** `kern.sweet_gpu_ddr=0` vota `INT_MAX` (X `SapphireGpu.cpp:4479-4481`),
   que con el escalado apagado no hace nada pero con él encendido llevaría el DDR al máximo para siempre. Y dos
   clientes del APSS votando el mismo recurso se pisan: el RPM guarda un voto por maestro y recurso. **0361** hace pasar
   el voto de 0347 por el gestor: igual que antes mientras el escalado no se ha encendido, y como entrada de la GPU
   (con `INT_MAX` = retirarla) después.
4. **Sondeo grueso:** `rpm_poll` duerme 1 ms entre miradas, así que cada voto cuesta al menos 1 ms aunque el RPM
   conteste en microsegundos. **0360** mira cada 10 µs los primeros 200 µs.

### 6.3 ¿Duerme alguna vez el APSS?

**[O] No.** Este kernel nunca apaga un núcleo: sin `CPU_SUSPEND` ni `CPU_OFF` de PSCI (X `osfmk/arm64/cpu.c:482-490`;
`SweetCPU.cpp` solo usa `CPU_ON`; el `SYSTEM_SUSPEND` de `machine_routines_asm.s:847-857` está bajo
`APPLEVIRTUALPLATFORM`). [H] El RPM pasa un maestro a su set de reposo cuando el subsistema le avisa de que duerme;
el APSS de iOS no avisa nunca, así que lo que se vote en el set de reposo no se aplica mientras corre este kernel.

## 7. Diseño

Tres parches, en `~/sapphire-angel/research/metal/ddr/parches-nuevos/`, que aplican en orden sobre la serie a 0353:

| Parche | Qué | Control | sha256 (prefijo) |
|---|---|---|---|
| 0360 | Cliente del RPM: cada respuesta se empareja con su petición por «msg#»; sondeo fino los primeros 200 µs; candado siempre; contadores | (siempre activo; no cambia los bytes) | `db629e2a` |
| 0361 | Escalado de relojes del RPM con traspaso previo, gestor del DDR (GPU vía 0347, suelo, tope, histéresis, tope térmico), medición de buses y del cambio | `kern.sweet_bus_scale` (0 por defecto), `kern.sweet_bus_clocks`, `_bus_hold`, `_bus_vote`, `kern.sweet_ddr_set`, `_ddr_gov`, `_ddr_floor`, `_ddr_cap`, `_ddr_down_ms`, `_ddr_gov_ms`, `_ddr_temp_max`, `kern.sweet_bus_stats` | `34412914` |
| 0362 | Entrada de las CPU al gestor, como los monitores *compute* de memlat | `kern.sweet_ddr_cpu` (1), `_ddr_cpu_ms` (100), `kern.sweet_ddr_cpu_stats` | `cc6ce81b` |

Sin escribir `kern.sweet_bus_scale=1` el kernel se comporta como 0353 salvo lo de 0360 (emparejamiento y sondeo), y
los votos de 0347 salen al RPM igual que antes (byte a byte, §8). No hay boot-arg: cuando una configuración esté
probada con n ≥ 3, se fija con un guion de `/redwood/boot.d/` como `kern.sweet_fb_queue` (`OPERACION.md` §9.1).

### 7.1 El interruptor (0361, `kern.sweet_bus_scale=1`)

En este orden, bajo `bus_lock`, y nada más tras el primer paso que falle:

1. Mide los buses y el DDR (`kern.sweet_bus_clocks`: entradas del multiplexor de depuración de GCC de
   `debugcc-khaje.c`, CNOC 0x1c, SNOC 0x7, IPA 2x 0xcd, CPUSS GNOC 0xb1, `disp_hf_axi` 0x40 (rama del MMRT a la
   pantalla), núcleo QUP 2x 0x71, UFS AXI 0x116, USB30 maestro 0x60, `bimc_gpu_axi` 0x97; el DDR por `mccc`).
2. XO encendido en el set activo (el mantenimiento de stock, `bi_tcxo_ao`).
3. **Traspaso** de cada reloj con tasa de la tabla de khaje, set activo y luego de reposo, como
   `clk_smd_rpm_handoff()`: `snoc_periph` (`clk1` 0), CNOC (`clk1` 1), SNOC (`clk1` 2), `snoc_lpass` (`clk1` 5), QUP,
   MMNRT (`mmxi` 0), MMRT (`mmxi` 1), IPA, CE1 a `INT_MAX` (`kern.sweet_bus_hold=0`, por defecto); con `=1`, CNOC, SNOC
   y MMRT a lo medido + 2 % (nunca por debajo de los 100 MHz de IPA ni de los 192 MHz de CE1 que votan otros drivers
   del port), el resto a `INT_MAX`.
4. El BIMC en los dos sets al voto de la fila en que corre el DDR (1 518 555 kHz para 1555,2): **el DDR no se mueve en
   el cambio**.
5. «Enab» en el set de reposo y luego en el activo.
6. Mide otra vez a los 20 ms y escribe antes → después en el log y en `kern.sweet_bus_stats`.

Estados (`kern.sweet_bus_scale`): 0 nunca activado; 1 activado; 2 activado con el DDR de vuelta en la fila del cambio
(escribir 0; 1 reanuda sin mensajes nuevos); −1 falló un paso anterior a «Enab» (nada cambió; 1 reintenta); −2 el
«Enab» del set activo no tuvo respuesta buena (estado del RPM desconocido hasta reiniciar; el gestor no vota).

**Por qué no se manda «Enab» = 0 para volver atrás:** Linux nunca lo envía y lo que hace el RPM con él no está
documentado; volver a la fila del arranque con el voto (estado 2) deja los relojes como estaban, y reiniciar lo deshace
todo.

**Qué recursos no se traspasan y por qué:** QDSS (`clk0` 1: CoreSight; Android no lo vota al arrancar y en este kernel
nada usa CoreSight: `coresight_base` solo se mapea con `cpu-impl-reg`/`coresight-reg` en el árbol de Apple y la
depuración solo en `APPLE_ARM64_ARCH_FAMILY`, X `osfmk/arm64/cpu.c:262-293, 1322-1331` [H, no medido]) y los búferes de
XO de RF (`clka` 4/5: sin escalado; los votan el módem y la radio).

### 7.2 El gestor del DDR (0361 + 0362, `kern.sweet_ddr_gov=1`)

Un hilo del kernel cada `kern.sweet_ddr_gov_ms` (20 ms):

- **Entradas**, en votos del BIMC: la GPU (0347 con `kern.sweet_gpu_ddr=1`: el `ib`/8 de kgsl para el nivel en curso;
  llega en el momento del cambio de nivel, no espera al hilo) y las CPU (0362).
- **Fila** = la que cubre la mayor entrada, nunca por debajo de `kern.sweet_ddr_floor` ni por encima de
  `kern.sweet_ddr_cap` (tasas del DDR: 1 555 200 y 2 092 800 por defecto). **El suelo por defecto es la fila de hoy:
  activar el gestor nunca baja el DDR**; el suelo de Android con la pantalla encendida es 547 200 (§4.3), un paso
  aparte del protocolo.
- **Subir** en cuanto una entrada lo pide; **bajar** tras `kern.sweet_ddr_down_ms` (100) pidiendo menos.
- **Temperatura:** con algún sensor de TSENS ≥ `kern.sweet_ddr_temp_max` (95 °C, el disparo de stock de la GPU) el DDR
  no pasa de la fila del cambio, hasta 5 °C por debajo. Android no limita el DDR por temperatura desde el espacio de
  usuario (§4.2); este tope es propio y conservador.
- **Votos del gestor solo en el set activo** (como los de qcom-dcvs); el set de reposo conserva el traspaso.
- `kern.sweet_ddr_set=<fila>` (con el gestor parado) pone una fila a mano y mide el cambio; 0 vuelve a la del cambio.

**Entrada de las CPU (0362).** Los monitores *compute* de memlat: por CPU, frecuencia × fracción ocupada; tabla del
DT (gold: 1056 → 547, 1344 → 768, 1766,4 → 1017, 2208 → 1804, 2803,2 → 2092 MHz; silver: 1190,4 → 547, 1516,8 → 768,
1804,8 → 1017); la mayor, nunca menos de 547 000. En XNU las CPU 0-3 son los A73 a 2803,2 MHz fijos y las 4-7 los A53
a 1900,8 (16 §1; 11 §12). La ocupación sale de la contabilidad del planificador (`processor_info`,
`PROCESSOR_CPU_LOAD_INFO`, ticks de 10 ms), así que la ventana es de 100 ms en vez de los 8 ms del PMU de stock. No se
reproducen los dos monitores que miran fallos de caché (necesitan el PMU por CPU) ni bwmon (§7.5).

### 7.3 Reposo y pantalla apagada

- **[O] El APSS no duerme nunca en este kernel** (§6.3): el RPM no aplica su set de reposo. Los votos de reposo del
  traspaso solo importarían si un kernel futuro apagara clústeres; el gestor no los toca.
- **[O] Con la pantalla «apagada» el DPU sigue barriendo:** `RequestPowerChange(0)` manda DCS 0x28 al panel y pinta de
  negro el frame que se barre (X `SweetFramebuffer.cpp:1383-1400, 3729-3760`); el temporizador del INTF no se para. El
  tráfico del barrido (1080 × 2400 × 4 B × 120 Hz = 1,24 GB/s) sigue: el suelo con la pantalla apagada es el mismo que
  encendida. `sweet_fb_panel_off` (X `SweetFramebuffer.cpp:82`) está disponible si un día el barrido se para.
- Con la pantalla apagada la GPU queda ociosa (con 0346, a 320 MHz: voto de 547,2) y las CPU casi ociosas: el gestor
  baja al suelo.

### 7.4 Votos de mantenimiento: lo mínimo frente a lo seguro

Android puede activar el escalado con solo el BIMC al máximo porque cada consumidor vota sus buses justo después
(§3.3). En iOS los consumidores ya funcionan y no votan; el mínimo correcto sería, por bus, el agregado de los
consumidores activos con las tablas de `bengal.c` (UFS, USB, pantalla, GPU, IPA, audio, QUP), nunca menos de
19,2 MHz. Sin esas tablas medidas, 0361 traspasa todo a `INT_MAX` (lo que hace Linux y lo que el modelo de §8 verifica
sin riesgo) o a lo medido (+2 %); bajar un bus concreto es un paso aparte con `kern.sweet_bus_vote`, de uno en uno.

| Bus del RPM | Quién lo usa en el port | Si se queda sin voto |
|---|---|---|
| CNOC (`clk1` 1) | Acceso a registros de casi todo (UFS, USB, GPU, pantalla, QUP) | Cuelgue al siguiente acceso [H, fuerte] |
| SNOC (`clk1` 2), `snoc_periph` (`clk1` 0) | Datos de UFS y USB hacia el BIMC; periféricos | E/S parada o cuelgue |
| BIMC (`clk2` 0) | Todo el tráfico a DDR (CPU, GPU, pantalla, DMA) | El sistema muere |
| MMRT (`mmxi` 1) | Lectura del framebuffer por el DPU | Pantalla con *underrun* o parada |
| MMNRT (`mmxi` 0) | Cámara, vídeo (`sweet_cam`) | Cámara parada |
| QUP | Núcleo de los QUP (I2C/SPI: táctil, amplificadores) | Táctil o audio parados |
| `snoc_lpass` (`clk1` 5) | Tráfico del LPASS (ADSP, audio) | Audio |
| IPA | Datos del módem (`kern.sweet_ipa_stats`: el módem y el IPA corren) | Datos móviles; TopazModem vota 100 MHz en los dos sets |
| CE1 | Criptografía de TrustZone (QSEE, huella) | Llamada a TZ colgada; SweetQsee vota 192 MHz solo en activo |

### 7.5 bwmon: diseño, no implementado

El contador de bwmon4 (registros en el agente B §2.2: `MON2_EN` 0x01B8E5A0, `MON2_SW` ventana en ticks de 19,2 MHz,
`MON2_THRES_HI/MED/LO`, `MON2_ZONE_ACTIONS` = 0x95250901, `MON2_ZONE_MAX(z)` 0x01B8E5E0 + 4z, en unidades de 64 KiB)
da el pico de tráfico CPU → EBI por ventana. Diseño para un 0363: sin interrupción (`MON_INT_EN` = 0), ventana de 4 ms,
lectura y borrado de `MON2_ZONE_MAX` en cada periodo del gestor, el algoritmo de `get_bw_and_set_irq` con los ajustes
de stock (`io_percent` 85, `hist_memory` 20, `up_scale` 250, `down_thres` 80, `bw_step` 190) y la entrada como votos
del BIMC (umbrales de stock: 547,2 desde ~950 MiB/s, 768 desde 2660, 1017,6 desde 3800, 1555,2 desde 4940, 1804,8
desde 7600, 2092,8 desde 8930). Antes de programarlo, un paso de solo lectura (leer `MON2_EN` y `MON2_SW` por
`kern.sweet_ipa_peek`) para confirmar que el bloque responde sin reloj propio (su nodo del DT no tiene `clocks`,
DT:7675-7686) [H].

### 7.6 Lo que no se reproduce de Android, y por qué

| De Android | Aquí | Motivo |
|---|---|---|
| memlat sobre fallos de L2 (PMU) | No | Hace falta programar el PMU en cada CPU; la entrada *compute* da la misma fila con la CPU ocupada |
| bwmon | No (diseño en §7.5) | Programar un bloque nuevo; se prueba aparte |
| Votos por consumidor (UFS, pantalla…) | Traspaso fijo | Ningún driver del port vota sus buses |
| Impulsos del HAL de energía | No | Dependen de qué HAL lleva el Android (no verificado) |
| Set de reposo con todo apagado | No aplica | El APSS no duerme |
| Suelo 547,2 en reposo | Configurable (`kern.sweet_ddr_floor=547200`) | Por defecto 1555,2 hasta medir la pantalla y la temperatura |

## 8. Verificación (en anfitrión)

Material: `~/sapphire-angel/research/metal/ddr/` (árbol `xnu-0353/` con un commit por parche; arnés en `work/harness/`).

1. **`git apply --check` y `git apply` en orden** de 0360, 0361 y 0362 sobre una copia limpia del árbol a 0353
   (0001-0353 de `xnu/patches/`): pasan, y el resultado es idéntico byte a byte a los fuentes que prueba el arnés.
   0354-0359 (otro trabajo) no existían al cerrar este informe: **repetir la comprobación sobre la serie completa
   antes de subir** (los tres tocan `TopazModem.cpp` en la sección del RPM y después de `topaz_rpm_ldo`, y 0361 dos
   puntos de `SapphireGpu.cpp`: tras la sysctl `kern.sweet_gpu_temp` y en `ddr_vote()`).
2. **`clang++ -fsyntax-only`** de `TopazModem.cpp` y `SapphireGpu.cpp` con los stubs de
   `kernel-gpu/verificacion/` (`syn.sh`): 0 errores. Con `-Wall -Wextra`: 23 y 36 avisos, los mismos que en 0353;
   ninguno en el código nuevo.
3. **Arnés** (`harness/harness0361.cpp`, `gen.sh`; 144 comprobaciones, 0 fallos; log en `harness/harness0361.log`):
   compila **sin cambios** la sección del RPM de `TopazModem.cpp` del árbol (cliente GLINK, 0360, 0361, 0362),
   `qcom_rpm_smd_write()` y `glink_rpm_tx_write()` de Linux v6.12 y la cabecera V0 de `rpm-smd.c` de MI (rangos de
   líneas comprobados por `gen.sh`), contra un modelo del RPM: RAM de mensajes con tabla de contenidos y dos FIFO,
   saludo GLINK, peticiones «req» con respuestas «msg#»/«err», interruptor de escalado, buses con niveles y DDR con
   tiempo de cambio. Supuestos del modelo (no verificados: no hay fuente del RPM): con el escalado apagado no aplica
   votos de tasa; los guarda y los aplica al llegar «Enab» en el set activo; un bus sin voto se apaga; el DDR toma la
   primera fila que cubre el mayor voto.

| Prueba | Qué comprueba |
|---|---|
| T1 | **Los 56 bytes de una petición son iguales** en el port, en Linux v6.12 y en el Android de stock (V0), salvo el `msg_id`, para 8 casos (BIMC, «Enab» de reposo y activo, `clk1` a `INT_MAX`, MMRT en reposo, IPA, `rwcx`, XO); el «Enab» activo suelto apaga en el modelo los buses sin voto |
| T2 | Orden del interruptor (XO; cada traspaso activo y reposo; BIMC; «Enab» reposo; «Enab» activo), formato de cada mensaje, ningún bus por debajo de su tasa de arranque, el DDR en su fila |
| T3 | Traspaso medido con la medida un 0,5 % baja: ningún bus por debajo |
| T4 | Un traspaso rechazado: no sale «Enab», estado −1, el segundo intento pasa |
| T5 | «Enab» activo sin respuesta: estado −2; desde ahí ningún voto de 0347 llega al RPM |
| T6 | Una respuesta tardía que llega durante la espera siguiente se descarta (0360), y el rechazo de la siguiente se informa como rechazo |
| T7 | DDR a mano: filas, tiempo hasta verlo en `mccc`, solo set activo, cambio lento contado como no visto, otro maestro que lo mantiene arriba |
| T8 | Gestor: GPU sube al momento, baja a los 100 ms, suelo, tope, tope térmico con 5 °C de histéresis, retirada con `INT_MAX`, vuelta a la fila del cambio al pararlo |
| T9 | Vuelta (0): DDR a la fila del cambio, estado 2, votos de 0347 no reenviados, 1 reanuda sin mensajes |
| T10 | Con el escalado apagado, 0347 sale igual que antes (mismo mensaje, también `INT_MAX`) |
| T11 | Un traspaso a mano: los dos sets, nunca por debajo de 19,2 MHz ni de los votos de otros drivers, errores |
| T12 | CPU (0362): todas ociosas → 547,2; un A73 ocupado → 2092,8; un A73 al 70 % → 1804,8; un A53 ocupado → 1017,6; entrada apagada → el suelo |

La petición del BIMC del port, tal como sale a la FIFO (T1):
`09000100 00000000 28000000 00000000 72657100 20000000 01000000 00000000 636c6b32 00000000 0c000000 4b487a00 04000000 db2b1700`
(`TX_DATA`, lcid 1, iid 0, 40 + 0; «req», 32; `msg_id` 1, set 0; «clk2», id 0, 12; «KHz», 4, 1 518 555).

**Lo que el arnés no puede decidir:** cómo redondea el RPM (los votos del gestor son los de kgsl, 97,7 % de una fila
habilitada, y caen en la misma fila con cualquier redondeo hacia arriba; §4.3), cuánto tarda de verdad un cambio, si
el RPM recorta con un «max» heredado, y las tasas reales de los buses al arrancar. Eso es del protocolo (§10).

## 9. Riesgos, síntomas y recuperación

Sin perro guardián que reinicie (SweetWatchdog no arma ninguno): **un cuelgue sin pánico exige reinicio físico**; un
pánico vuelve a fastboot con `sweet_reboot=2`. Reiniciar deshace todo (el RPM vuelve al estado del arranque).

| Paso | Riesgo | Síntoma | Qué lo limita | Recuperación |
|---|---|---|---|---|
| `kern.sweet_bus_clocks` (primera lectura) | Una entrada nueva del multiplexor de GCC no accesible | Cuelgue al leer | Solo escribe registros de depuración de GCC, como 0343 (ya leído en M10) | Reinicio físico; no repetir |
| Interruptor (`=1`) | Un bus que el port usa y que no está en el traspaso | Cuelgue (CNOC) o periférico parado | Traspaso de todos los relojes con tasa de khaje a `INT_MAX` | Reinicio físico |
| Interruptor | El RPM rechaza un traspaso | Estado −1, log con el recurso | Nada se envía tras el fallo | Ninguna (nada cambió) |
| Interruptor | «Enab» activo sin respuesta | Estado −2 | El gestor no vota | Reinicio |
| Buses a `INT_MAX` | Más consumo y calor | `kern.sweet_thermal` | `kern.sweet_bus_hold=1` o `kern.sweet_bus_vote` | `kern.sweet_bus_vote` o reinicio |
| DDR a 1804,8/2092,8 | Una fila nunca usada bajo iOS da errores de memoria | Pánicos, corrupción, cuelgue | Android la usa en este mismo teléfono; se sube de fila en fila | Reinicio; `kern.sweet_ddr_cap=1555200` |
| DDR a 547,2-1017,6 | Ancho de banda corto para la pantalla a 120 Hz más GPU | Parpadeo, líneas, frames tarde | Suelo por defecto 1555,2; bajar es un paso aparte | `kern.sweet_ddr_set=0` o `kern.sweet_ddr_floor=1555200` |
| Gestor | Oscila | `kern.sweet_bus_stats` (subidas/bajadas, tiempo por fila) | Bajada con 100 ms de retardo | `kern.sweet_ddr_gov=0` |
| Gestor | Calor con el DDR alto | `kern.sweet_thermal` | Tope a la fila del cambio desde 95 °C | `kern.sweet_ddr_cap` |
| `kern.sweet_bus_vote` | Bajar un bus por debajo de lo que necesita su consumidor | Como el interruptor | Una herramienta: un bus cada vez | Volver a subirlo; reinicio |
| `kern.sweet_audio` op 6 | Con el escalado activado, un voto manual del BIMC pisa al gestor hasta su siguiente cambio | DDR distinto del esperado | — | No usar op 6 con el gestor activo |

## 10. Protocolo de prueba (para el coordinador)

Kernel de CI con 0360-0362 encima de la serie (0354-0359 incluidos); comprobar en el log del CI que se aplicaron
(`dev-notes/fetch-ci-kernel.sh` con `PATCH=0360`, `0361`, `0362`). Boot-args de siempre (`gpu_vco2=1 gpu_mhz=820`…),
`/redwood/boot.d/80-gfx.sh` como hoy y el driver Metal en uso (`driver-en-uso.sh`). Todo por `ssh sapphire` con
`PATH=/var/jb/usr/bin:/var/jb/usr/sbin:$PATH`. **Una sola escritura por paso, y leer antes de seguir.** Cualquier
cuelgue: reinicio físico y anotar en qué paso; no repetir ese paso sin un cambio.

### 10.0 Solo lectura (sin mensajes al RPM)

    sysctl -n kern.sweet_bus_scale            # 0
    sysctl -n kern.sweet_ddr_khz              # 1555210
    sysctl -n kern.sweet_bus_clocks           # tres veces (~0,3 s cada una): cnoc, snoc, ipa_2x, cpuss_gnoc, disp_hf_axi, qup, ufs, usb, bimc_gpu, ddr
    sysctl -n kern.sweet_bus_stats            # "scaling 0"; contadores del cliente del RPM
    sysctl -n kern.sweet_thermal; uptime

Parada: si la primera lectura de `kern.sweet_bus_clocks` congela, el interruptor (que mide igual) tampoco se usa
hasta quitar esa medida. Anotar las tasas de arranque de cada bus (n = 3).

**Línea base** con el DDR en 1555,2 (n = 3 cada una):
- Memoria, en un A73: `/var/root/hilos/spawnfg /var/root/hilos/memlat -q ui -n 3 curve` (latencia aleatoria y
  secuencial a 4 y 64 MB; 16 §3.4).
- GPU: las trazas del Centro de Control como en 03 M24 (`metal_trace=frame`, abrir y cerrar capturando 45 command
  buffers; tiempo de GPU por frame de animación) a 820 MHz (`kern.sweet_gpu_khz=820000`).
- Temperatura en calma tras 10 min: `kern.sweet_thermal`.

### 10.1 El escalado, con todo al máximo y el DDR quieto

    sysctl -w kern.sweet_bus_scale=1; echo $?     # 0
    sysctl -n kern.sweet_bus_stats                # "scaling 1 (hold mode 0)", xo 0, Enab sleep 0 active 0, todos los holds (0); ddr 1555210 -> 1555210
    sysctl -n kern.sweet_ddr_khz                  # 1555210
    sysctl -n kern.sweet_bus_clocks               # cada bus >= su tasa de 10.0

Comprobar a continuación: la pantalla se mueve (`homeswipe.sh 4`), el táctil, la sesión SSH (USB), los datos
(`kern.sweet_modem_stats` y `kern.sweet_ipa_stats` avanzan), UFS (`dd if=/dev/zero of=/var/tmp/t bs=1048576
count=64; sync; rm /var/tmp/t`) y la temperatura a los 10 min. **Parada:** cualquier bus por debajo de su tasa de
arranque, el DDR fuera de 1555210, un estado −1/−2, un periférico parado. Repetir en tres arranques (n = 3).

### 10.2 El DDR a mano, fila a fila

    sysctl -w kern.sweet_ddr_set=1804; sysctl -n kern.sweet_ddr_khz       # 1804800
    sysctl -n kern.sweet_bus_stats       # "switch us last N" (tiempo del voto a verlo en mccc), "answer us"
    sysctl -w kern.sweet_ddr_set=2092; sysctl -n kern.sweet_ddr_khz       # 2092800

- **Si el DDR no se mueve** con el escalado activado: anotar; la causa siguiente es un límite «max» heredado (§5.4),
  que estos parches no tocan.
- A 2092,8: `memlat` (n = 3), trazas del Centro de Control (n = 3) y temperatura, frente a la línea base.
- Coste del cambio: 1555 → 1804 → 2092 → 1804 → 1555 tres veces, leyendo `switch us` y `answer us` tras cada uno.
- Bajar: `1017`, `768`, `547`, con `homeswipe.sh 4` y el Centro de Control en cada fila (líneas, parpadeo, frames
  tarde). **No probar 200** con la pantalla encendida (Android solo lo usa en el set de reposo).
- Vuelta: `sysctl -w kern.sweet_ddr_set=0` (1555210).

### 10.3 El gestor

    sysctl -w kern.sweet_gpu_ddr=1          # 0347: la GPU como entrada
    sysctl -w kern.sweet_ddr_gov=1
    sleep 10; sysctl -n kern.sweet_bus_stats; sysctl -n kern.sweet_ddr_cpu_stats

Esperado con la GPU fija a 820 MHz: entrada de la GPU 1 761 719 → 1804,8; con un A73 ocupado (el hilo de render
durante `homeswipe`), 2092,8; quieto, el suelo (1555,2). Con el gobernador de la GPU (`kern.sweet_gpu_gov=1`) en
reposo la GPU vota 547,2 y manda el suelo. Medir: trazas del Centro de Control (n = 3), `tools/perf/ab.sh` con
`homeswipe`, `kern.sweet_bus_stats` (tiempo en cada fila, subidas y bajadas) y temperatura.

Después, **el suelo de Android**: `sysctl -w kern.sweet_ddr_floor=547200`; en calma debe quedar en 547,2. Mirar la
pantalla quieta y en movimiento a 120 Hz y la temperatura en calma a los 10 min frente al suelo de 1555,2 (17 §4.4:
iOS está ~20 °C por encima de Android en reposo).

### 10.4 Opcional: los buses a su tasa de arranque

Uno cada vez, con las tasas de 10.0: `sysctl -w kern.sweet_bus_vote="snoc <kHz>"`, comprobar periféricos, y lo mismo
con `cnoc`, `mmrt`, … Quita el consumo extra de tener los buses a `INT_MAX`.

### 10.5 Vuelta atrás y qué anotar

`sysctl -w kern.sweet_ddr_gov=0` (el DDR vuelve a la fila del cambio), `sysctl -w kern.sweet_bus_scale=0` (estado 2),
o reiniciar (todo como al arrancar). En 03, una entrada por sesión: fecha y hora, imagen (run de CI y sha), ruta de
arranque, boot-args, driver, estado de partida (`kern.sweet_thermal`, carga), y por paso los valores leídos con su n.

**Para saber si sirve:** (1) `kern.sweet_ddr_khz` sigue a los votos tras el interruptor (lo decisivo); (2) la latencia
de `memlat` a 64 MB y las pasadas a resolución completa del Centro de Control bajan con el DDR a 2092,8 frente a
1555,2 (22 §6.1 predice hasta un −20 % en las de sysmem si mandan los bytes de DRAM); (3) con el gestor y el suelo de
547,2, la temperatura en calma baja.

## 11. Afirmaciones heredadas contrastadas

| Afirmación | Dónde | Veredicto |
|---|---|---|
| Votar el BIMC «is taken and changes nothing» | descripciones de 0203/0204 | Coherente: [M] voto aceptado y DDR quieto (03 M24 y la lectura de hoy); la causa es el escalado apagado [O Linux, MI, KO; H en el RPM] |
| «Con "Enab" y todo votado alto memcpy no cambió (2,2-2,5 GB/s)» | origen del port (Angelpro09xd) | No decide nada: no se midió el DDR, y la memcpy de un núcleo no distingue frecuencias del DDR (16 §7) |
| «Android fija el DDR en 2092,8 MHz con la GPU en sus dos niveles altos» | 11 §4.5, 17 §1 | [O] DT y kgsl; no medido en Android (sin root, `devfreq` no es legible) |
| «En qué fila deja el DDR el XBL no sale de la tabla» | 11 §10.1 | Sale del código: 1555,2 MHz («Bootup frequency set to», agente B §4.3) [O], coincide con [M] |
| «El plan del DDR son siete filas» | 11, 17, DT | Es la tabla B de cuatro del XBL; el código toma por defecto la A (681,6 en lugar de 547,2) y elige B según un fusible no leído [O/H]; el DT coincide con B |
| «El BIMC del RPM tiene las mismas siete filas» | (implícito en 17 §3.1) | Su tabla tiene 11 niveles sin banderas [O, `rpm.mbn` de los paquetes de Xiaomi; que sea el del teléfono, no verificado]; los votos de kgsl caen en filas habilitadas con redondeo hacia arriba |
| «Bajo iOS la pantalla tampoco vota» | 11 §10.5 | Cierto; y en Android la pantalla no vota 1,6 GB/s de `ib` en el kernel: 2,4 GB/s al encender y después `ab` del HAL (agente B §2.5) [O] |

## 12. Estado al cerrar (14 de noviembre de 2026)

**Hecho.** Mecanismo y política leídos en fuentes primarias (Linux, MI, módulos y DT del teléfono, XBL, `rpm.mbn` de
los paquetes de Xiaomi, UEFI de tapas); literatura y comunidad (§5); auditoría del cliente del RPM (§6); 0360-0362 en
`ddr/parches-nuevos/`, aplicados en orden sobre 0353, compilados en sintaxis sin avisos nuevos y verificados en el
arnés (144 comprobaciones, 0 fallos). Ningún parche está en `xnu/patches/`; ninguno se ha probado en el teléfono.

**Sin hacer.** El protocolo (§10); repetir `git apply --check` sobre la serie con 0354-0359; bwmon (§7.5, diseño);
los monitores de memlat que miran fallos de caché (PMU); votos por consumidor en lugar del traspaso fijo (§7.4); leer
el fusible QFPROM 0x01B46030 (tabla del plan) y obtener el `rpm.mbn` del propio teléfono; si tras «Enab» el DDR no
sigue al voto, el límite «max» (§5.4).
