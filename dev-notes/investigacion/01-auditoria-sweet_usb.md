# 01 — Auditoría zero-trust de `sweet_usb.c` y de la evidencia (2026-11-14)

- **Autor:** agente Claude Fable 5.2, esfuerzo máximo, unos 75 min y 156 herramientas.
- **Criterio:** confianza cero en los comentarios, commits y notas del repo. Las líneas `Lnnn` se refieren al `sweet_usb.c` reconstruido post-0328 (1241 líneas). Copia: `~/sapphire-angel/research/fuente-reconstruida/sweet_usb.post-0328.c`.
- **Anexos** (ver `INDICE.md`):
  - `anexos/sweet_usb_design_sketch.c`
  - `anexos/usbsim.py`, `anexos/storm.py`
  - `anexos/replay-parches-apply.log`
  - Lo pesado está en `~/sapphire-angel/research/auditoria-sweet_usb/`: Mach-O de expG, `ud_thread.dis`, fuentes de referencia, transcripción.

> **Corrección posterior (Experimento 1, R1 y C1, 2026-11-14).** La sección 3 atribuía la observación A en parte a un confusor de VBUS. R1 repitió la ruta de reboot **con VBUS presente** (PMIC `usb 0x10`) y falló igual, con los mismos registros. Así que el confusor queda **descartado**. Además, la ruta mala tenía **ENBLSLPM = 1** (GUSB2PHYCFG 0x2500 frente a 0x2400 en C1). La premisa de 0328 era parcialmente correcta, pero limpiar ese bit no basta. Ver `03-experimentos-y-datos.md`.

## Resultado en breve

- **B es una regresión de 0327.** La misma finalización se consume dos veces: por sondeo de HWO (`ud_reclaim_fast`, L1068-1074) y por su evento, que el manejador acepta sin comprobar nada (L881-893). El segundo consumo lanza Start Transfer sobre una transferencia viva, y el controlador responde estado 1 (No Resource).
- **El estado permanente lo crea el propio driver** (lo más probable, no observado directamente). Cada intento reescribe el TRB que posee el controlador. Si la transferencia en vuelo termina entre el volcado del TRB (L300) y la escritura de DEPCMD (L272), el controlador borra HWO del TRB recién escrito y acepta el Start sobre un TRB sin HWO. Linux usa ese estado a propósito. Ninguna ruta emite End ni Update Transfer para EP_TX.
- **`tx 2 688 980` cuenta intentos, no tramas.** Cada intento fallido imprime una línea, que el hilo de log convierte en otra trama dentro del mismo bucle.
- **No hay evidencia de que RX se parara a nivel USB.** "Host is down" y la falta de ARP se explican solo con TX muerto.
- *(Ver la corrección de arriba.)* La observación A estaba confundida: en el arranque malo el PMIC no veía VBUS (`usb 0x26`, PLUGIN a 0) desde antes del probe USB. Aun así el DWC3 estaba en valores de reset, luego el ABL no lo había tocado.
- **0328 parte de una premisa falsa en cuanto a SUSPHY**, que ya era 0. *(Corrección: ENBLSLPM sí era 1.)*
- **Afirmaciones de las notas contradichas:** "se pierden eventos", "0327 cura / es un ring", "el toolchain está roto", "el parche está probado correcto" y "`fastboot boot` brickea".
- **Todos los parches aplican.** Los 322 pasan `git apply --check` en orden, y el kernel de expG contiene 0327 y 0328 (comprobado por desensamblado). El borrador del 0329 de reclaim **no** pasaba `--check` y el CI lo habría saltado en silencio (descartado; copia en research/).

## 0. Qué se verificó y cómo

- **Replay del CI.** Sobre xnu-8796.141.3, con los `sed` de `build.sh` y los tres `*.sh`, se aplicó la serie con `git apply --check` y `git apply` en orden de glob. Aplican los 322 parches numerados. Solo se saltan cuatro parches propios de darwin-xnu-build (TrustCache, iobuffermemd_monterey, skywalk_sonoma y syntax_checker_sonoma). El `sweet_usb.c` resultante es idéntico byte a byte al reconstruido.
- **Binario.** El Mach-O del kernel se reconstruyó desde `boot_a-expG-20261113-223928.img`; el sha256 coincide. Se verificó por desensamblado:
  - `ud_epcmd` itera 5000 veces (0328).
  - `GUSB2PHYCFG` se enmascara con `~0x140`.
  - `ud_reclaim_fast` está inlineado en `ud_thread`.
  - `flush_dcache64` llama a un `flush_dcache` real; `FlushPoC_DcacheRegion` hace `dc civac` con líneas de 64 B.
  - `ml_delay_should_spin` devuelve `interval < cpu_idle_latency`.
- **Logs primarios:** el ring del arranque malo, el log UDP en vivo, la sesión del puerto 2323 y las marcas de tiempo.
- **Referencias fijadas:** Linux v6.12, U-Boot v2025.01 y el kernel de fabricante para SM6225.
- **Modelo de eventos discretos** de la ruta TX: es una comprobación de coherencia, no una prueba.

## 1. Mecanismo de B

### 1.1 Interleavings que emiten Start Transfer con una transferencia activa

| # | Ruta | Condición |
|---|---|---|
| I1 | TX, 0327 | La finalización k cae entre la lectura de GEVNTCOUNT (L1083) y la de `tt[3]` (L1070). `ud_reclaim_fast` la toma y arranca k+1. En un poll posterior, el evento de k pone `tx_busy=false` y patea (L890-891) con k+1 todavía viva. |
| I2 | TX, consecuencia | Con `tx_busy=false` y una transferencia viva, cada `ud_if_output` (L707) repite el intento. |
| I3 | TX, 0224 | `ud_watch` (L992-1000) hace lo mismo que I1 si el evento tarda más de dos vigilancias. Con 0327 no llega a dispararse. |
| I4 | TX, 0289 | `ud_ep_reset_seq(EP_TX)` (L575-581): el End Transfer se omite si `xfer_active[3]` es falso (L326), o se emite y no se espera. Después patea. |
| I5 | RX, 0327 | El reclaim (L1064-1066) rearma. El evento viejo entra en `ud_rx_done`, ve HWO puesto, espera, y `ud_rx_arm` (L625, L596) arranca sobre la transferencia viva: "ep2 cmd 0x6 status 1", luego End y reintento (L598-600). |
| I6 | RX, 0284/0289 | `ud_end_transfer` seguido de `ud_rx_arm` (L982-983, L583-585) sin esperar a que el End termine de verdad. |
| I7 | Bus reset | `ud_end_transfer` de los EP 2..5 sin `ud.lock` (L820-822), en carrera con `ud_if_output` en otra CPU. |

La ventana de I1 e I5 es lo que tarda el poll en procesar sus eventos. Puede ser de varios ms, porque `ud_rx_done` espera 100 × `delay(10)` (L618-621) y `delay()` bloquea en este port (ver D5).

### 1.2 Qué pasa cuando Start Transfer falla

1. **L678-679:** la trama ya se copió sobre `UD_TX`, pisando el buffer de la transferencia en vuelo, y el mbuf ya se liberó.
2. **L685-686:** `tx_busy=true` y `tx_frames++`, antes de conocer el resultado.
3. **L296-300:** el TRB de TX se reescribe con HWO=1 y se vuelca, aunque el controlador lo posee.
4. **L278:** `printf`.
5. **L305-307:** se retorna sin tocar `xfer_rsc` ni `xfer_active`.
6. **L688-689:** `tx_busy=false` y `break`.

Resultado neto: la trama se pierde, `tx_busy=false`, y `xfer_active[EP_TX]` queda en falso con el controlador ocupado. Por eso, después, `ud_end_transfer(EP_TX)` no hace nada, ni en el bus reset ni en clear-halt.

### 1.3 Por qué `tx_frames` llega a 2,7 M

- `tx_frames` cuenta intentos (L686).
- Cada intento fallido imprime unos 32 bytes. `printf` llega de forma síncrona a `_cnputs` y de ahí a `sweet_log_append` (`console_write` y luego `console_ring_try_empty`).
- `ud_log_thread` no sale de su bucle interno (L1141-1151) mientras haya bytes nuevos, y `ud_if_output` devuelve 0 aunque falle.
- El ciclo es: intento → línea de log → datagrama → otro intento.

Los números cuadran con esto:

- Δtx = 2 688 904 en una ventana de 190-250 s, es decir, unos 11-14 mil intentos por segundo.
- Eso son unos 86 MB de líneas idénticas en un ring de 4 MiB, donde caben 131 072. Se contaron 130 538; las 534 restantes son log posterior a la recuperación.
- **Efecto colateral:** con `ufslogsecs=1`, esos 86 MB se escribieron a UFS, y el ring perdió el volcado de registros del arranque bueno.

### 1.4 Por qué "RX también se para"

No hay dato que lo demuestre a nivel USB.

- Sin TX no salen ni ARP ni ACK.
- `rx` siguió contando: 280 antes del bloqueo y 799 al recuperar.
- "rx rearms" subió en 47, y ese contador exige que RX esté armado (L977).

Lo que el código sí le hace a RX en ese estado:

- el evento viejo (I5);
- la línea de caché compartida (D4);
- el estado muerto sin vigilancia (D7);
- contención: el hilo de log retiene `ud.lock` durante un `delay(1)` bloqueante.

Las dos líneas "ep2 cmd 0x6 status 1" del log UDP prueban que I5 ocurrió al menos dos veces.

### 1.5 Por qué el bus reset lo recupera

- `ud_bus_reset` no hace End de EP_TX, porque `xfer_active[3]` es falso (L326).
- `configured=false` (L827) hace que `ud_if_output` descarte sin imprimir (L698-702), y con eso se corta el bucle de log.
- La reenumeración emite DEPSTARTCFG(2), DEPCFG y DEPXFERCFG (L458-465), y en SET_INTERFACE un CLEARSTALL (L578).

No está verificado cuál de esos pasos libera la transferencia; no es un End explícito. "halt clears 2→4" corresponde a las dos llamadas de SET_INTERFACE por enumeración (L517-518 y L574). El host no envió CLEAR_FEATURE(HALT).

### 1.6 Cronología que reproduce los contadores

Deltas: events +1333, resets +1, rx +647, tx +2 688 904, late rx +15, rearms +47, halt clears +2.

1. **Primera enumeración:** resets=1, halt_clears=2. En la ráfaga inicial ya aparecen dos "ep3 cmd 0x6 status 1" (líneas 78-79 del log UDP), así que el fallo transitorio existe antes de la prueba.
2. **22:43:10:** lectura 1.
3. **22:44:06:** arranca el `dd` y muere en el mismo segundo. 196 608 B son seis paquetes SSH de 32 768.
4. Un poll lee GEVNTCOUNT y procesa su lote.
5. Entretanto, la trama N termina: HWO=0, se encola E_N y se libera el recurso.
6. Al final del poll, el reclaim toma N y arranca N+1 (tx+1).
7. En el poll siguiente, E_N pone `tx_busy=false` y lanza N+2. Si N+1 sigue viva, sale estado 1, se imprime una línea y N+2 se pierde. Si N+1 ya terminó, N+2 arranca y E_{N+1} repite el fallo contra N+2.
8. Mientras dura el vuelo, cada segmento TCP y cada datagrama de log repiten el fallo.
9. La transferencia en vuelo termina:
   - entre dos intentos: el siguiente arranca bien y su evento queda viejo (vuelta al paso 7);
   - dentro de un intento, después de L300 y antes de L272: el write-back borra HWO del TRB recién escrito, el Start se acepta sobre un TRB sin HWO, `tx_busy=true`, nada sale al cable y no hay evento.
10. En el poll siguiente, el reclaim ve `tx_busy && !HWO` (L1070) y lanza otro Start: estado 1, ya para siempre. El paso 8 no termina: 2,69 M intentos.
11. RX sigue armado: cada 2 s de silencio se rearma (+47) y se acumulan +15 "late rx".
12. **Antes de 22:48:18, reconexión:** resets=2, `configured=false`, reenumeración, halt_clears=4. En la ráfaga aparecen "ep3" ×3 y "ep2" ×2.

### 1.7 Lo que la carrera de 0327 no explica por sí sola

Una transferencia IN en vuelo termina en menos de 1 ms, así que la persistencia necesita una transferencia que no termine nunca. Hay dos candidatos:

- **α (el más probable):** la segunda rama del paso 9. Su premisa la documenta Linux, que arranca cada endpoint bulk con un TRB a cero (ref. [1]). Falta confirmarlo en el teléfono.
- **β:** el host deja de sondear IN. No se encontró nada en el código que lo provoque.

### 1.8 Comprobación con el modelo (asume α; "late rx" calibrado al 2 %)

| Lógica | Ejecuciones | Resultado |
|---|---|---|
| 0327 | 300 × 20 s | 300/300 terminan en rechazo permanente; tramas antes del fallo: p10 191, mediana 845, p90 2813 |
| Previa a 0327 | 20 × 20 s | 0 rechazos |
| Regla corregida (§5) | 20 × 20 s | 0 rechazos |

Lo observado (unas 140-200 tramas) cae en torno al p10. Es compatible, con n=1.

## 2. Otros defectos demostrables, por gravedad

| # | Sev. | Líneas | Defecto y escenario | Referencia |
|---|---|---|---|---|
| D1 | Crítica | 881-893, 1054-1076, 936-1005 | Dos fuentes de verdad para "terminó", sin deduplicar; HWO usado como "disponible". | Linux solo borra `TRANSFER_STARTED` con el evento [2]. Synopsys: no se puede depender de HWO [3]. |
| D2 | Crítica | 667-691 | Buffer y TRB reescritos antes de saber si el endpoint está libre; trama descartada; sin End para TX. | U-Boot devuelve `-EBUSY` [9]; Linux llama a `dwc3_stop_active_transfer` (gadget.c L1653-1660). |
| D3 | Crítica | 278, 285, 1141-1151 | `printf` en la ruta de datos realimenta el hilo de log: bucle sin fin, 86 MB a flash, ring destruido. | Ni Linux ni U-Boot imprimen por paquete. |
| D4 | Alta | 188-193, 251-255, 300 | Los TRB de ep0 OUT/IN, RX y TX comparten una línea de 64 B (0x1000-0x103f); SETUP comparte otra con el TRB de INT. `dc civac` vuelca la línea entera con la copia que tiene la CPU, así que se puede perder el write-back del controlador. Escenario: un evento de TX reescribe su TRB, y el evento de RX ve HWO=1 y pierde la trama. | Linux usa `dma_alloc_coherent` (gadget.c L493, core.c L487). U-Boot usa un pool por endpoint y vuelca antes de leer [9]. |
| D5 | Alta | 283, 328, 619 | `delay()` no gira sino que bloquea: `ml_delay_should_spin` es falso porque `cpu_idle_latency` = 0 (`SweetCPU.cpp:91`, `info = {}`). Cada `delay(1)` es un `thread_block` con `ud.lock` tomado. | Linux sondea CMDACT sin dormir [4]. U-Boot usa `udelay(1)`: "We can't sleep here" [9]. |
| D6 | Alta | 323-331 | End Transfer con ForceRM, sin CMDIOC ni GUCTL2[14]; espera 100 µs y luego Start o ClearStall; no comprueba el resultado y siempre borra `xfer_active`. | Con ForceRM no termina de inmediato ni borra HWO [5]. Linux espera 1 ms sin IOC, o el evento con IOC [4][6]. |
| D7 | Alta | 596-601 | Si el reintento de `ud_rx_arm` falla, RX queda con `xfer_active=false` y HWO=1, un estado que ninguna rama cubre: RX muerto hasta un reset. | — |
| D8 | Alta | 817-847 | El reset solo termina lo que el driver cree activo, sin lock y con ep0 al final. | Hay que hacer DEPENDXFER de toda transferencia activa, ep0 primero [7]. |
| D9 | Media | 976-987 | Rearme de RX cada 2 s con el enlace ocioso; cada uno pasa por D6 y puede acabar en D7. | — |
| D10 | Media | 571-590 | Clear-halt y SET_INTERFACE hacen End y ClearStall inmediatos dentro de un control transfer. | Linux difiere el ClearStall (gadget.c L2177-2193) y retrasa el End si ep0 no está en SETUP [8]. |
| D11 | Media | 1155-1240 | La inicialización depende de lo que dejó el ABL (§3). | — |
| D12 | Media | 904-927, 476-559 | ep0: sin SETUP_PENDING; no comprueba la dirección en XferNotReady; ignora de qué ep viene el evento; sin ZLP; ignora SET_CONFIGURATION(0); confirma aunque `ud_configure` falle. | `ep0.c` L883-889, L1128-1163. |
| D13 | Media | 1083-1094, 1201 | Máscara 0xffff en lugar de 0xfffc; no comprueba la cuenta frente al tamaño; DEVTEN sin overflow ni errático. Recorrido, wrap y volcado son correctos. | `core.h` L78; `gadget.c` L2766-2772. |
| D14 | Media | 694-710 | `ud_if_output` ejecuta órdenes al controlador, esperas bloqueantes y `printf` desde los hilos de red con el mutex tomado. | U-Boot: un solo hilo. |
| D15 | Baja | 1220-1221 | VBUS forzado para siempre: el driver no ve la desconexión. | `dwc3-qcom` lo conmuta con extcon. |
| D16 | Baja | 678, 674 | `mbuf_copydata` sin comprobar; tramas grandes descartadas sin contarlas. | — |

**Lo que está bien:**

- las máscaras de eventos;
- el relleno a 513 B (es el mismo truco de `u_ether.c` L567-572);
- el TRB de RX de 2048, múltiplo de MPS;
- los mbuf de RX, sin fugas.

## 3. La ruta de arranque (observación A)

**Lo que el driver da por hecho y no toca:**

- de GCC: GDSC, ramas, frecuencias de los RCG y resets (solo los lee, L86-103);
- el PHY HS en 0x1613000 (ni lo mapea);
- el mux de reloj pipe/UTMI en QSCRATCH `GENERAL_CFG`;
- GCTL, GUSB3PIPECTL, GUCTL2 y las FIFOs.

**Lo que sí hace:** CSFTRST, el buffer de eventos, DCFG, DEVTEN, ep0, el override de VBUS (después de ep0) y RUN_STOP. 0328 borra SUSPHY y ENBLSLPM una vez.

**Lo que falla:** en la ruta mala, el ring muestra GDSC y los 7 relojes encendidos, pero el DWC3 en valores de reset:

- GEVNTADR 0, DEVTEN 0, DALEPENA 0;
- DCFG 0x00080804, DCTL 0x00f00000;
- DSTS 0x00520004 (COREIDLE 0).

DEPSTARTCFG se completa, pero DEPCFG da timeout. Las órdenes de endpoint necesitan la señal del PHY [10]. La suposición que falla es: "el ABL deja el controlador en modo dispositivo, parado y con el PHY listo". No se sabe si falta el PHY, el mux o ambos, porque nadie lee esos registros. Eso es lo que hace ahora el parche 0329.

**PHY:** el DT del fabricante confirma que es el femto (`qcom,usb-hsphy-snps-femto` en `hsphy@1613000`) [12]. El `sm6115.dtsi` de mainline declara ahí un QUSB2, que **no vale** para SM6225.

**Inicialización mínima independiente de la ruta de arranque:**

1. Reguladores por RPM (L4A, L12A, L15A) y XO.
2. En GCC: GDSC y ramas (0x1a010, 0x1a014, 0x1a018, 0x1a084, 0x1a080, 0x1d008, 0x9f000); master a 66,67 MHz y mock_utmi a 19,2 MHz.
3. Resets: BCR del core (0x1a000) y del PHY (0x1c000) [11].
4. `qcom_snps_hsphy_init` [11], con los overrides del DT (0xa6, 0x85, 0x16 en 0x6c, 0x70, 0x74). Hay que saltarlo si EUD (0x1612000) está activo.
5. QSCRATCH `GENERAL_CFG`: PIPE_UTMI_CLK_DIS, luego SEL + PHYSTATUS_SW, luego quitar DIS [11][12].
6. En el core: SUSPHY y ENBLSLPM a 0, SUSPHY de GUSB3PIPECTL a 0, CSFTRST, PRTCAPDIR en dispositivo, GUCTL2[14], y después lo que ya se hace hoy.

## 4. Auditoría de afirmaciones

| Afirmación | Veredicto | Evidencia |
|---|---|---|
| "Se pierden eventos bajo carga" | Contradicha | `NOTES.md:389`: "not a lost event: kern.sweet_usb_stats shows none". Hoy: "without event: rx 0 tx 0". El comentario de 0224 dice "late event". |
| "0327 cura el bloqueo" / "es un ring" | Contradicha | Observación B; sigue siendo un TRB por endpoint (L190-191). |
| "0328 despierta el PHY" | Contradicha en efecto | Timeout idéntico. Corrección: ENBLSLPM era 1, no SUSPHY. |
| "El toolchain está roto (ExpB/ExpC)" | Contradicha | ExpB fue un fallo de enlazado ("NO era omagic", `build-recipes.md`). El kernel de expG, con Apple LLVM 21.0.0 y SDK 26.5, arranca iOS y enumera. ExpC: no verificado. |
| "El parche USB y la config están probados correctos" | Contradicha | Un kernel que murió en la entrada no ejecutó el parche; además está D1. |
| "`fastboot boot` brickea este ABL" | Contradicha | README (9/15/102/107), HANDOFF, RECOVERY y NOTES (194/383/466) la dan como vía normal. La prueba del fork usó un shim sin cabecera ARM64, que este ABL rechaza (`NOTES.md:466`); `fastboot boot` no escribe en flash. expG sí tiene la cabecera. No está probado que funcione hoy. |

**Parches:**

- **0224:**
  - "Transfer finished without its event": no verificada; `NOTES.md:389` la contradice.
  - "As if the event had come" es seguro: contradicha.
- **0284:**
  - El watchdog rearma RX: contradicha (L977 exige `xfer_active`).
  - "Costs nothing": contradicha (D9).
  - El Start refused se termina y se reintenta: apoyada, pero ignora el resultado (D7).
- **0289:**
  - CLEAR_FEATURE(HALT) se ignoraba: apoyada.
  - "What killed every big copy": contradicha. Un desfase de toggle se resincroniza; es inferencia del protocolo, no medida.
  - ClearStall reinicia la secuencia: apoyada.
- **0290:**
  - La traza persiste: apoyada, pero no registra los rechazos de TX y los rearmes la llenan en unos 8 min.
- **0291:**
  - Evento con HWO puesto y nada rearma: apoyada.
  - La causa sería el "write-back not visible yet": no verificada e improbable, porque D4 y la doble toma producen lo mismo.
  - "Up to 1 ms": contradicha (D5).
  - "4 x 30 MB": no verificada.
- **0327:**
  - "The handler ignores it": contradicha (L881-893).
  - "Always safe": contradicha [3].
  - "Instead of only on the event": contradicha, hace las dos cosas.
- **0328:**
  - "PHY suspended": contradicha en lo que ataca.
  - "Exactly as Linux": parcial; Linux guarda, borra y restaura en cada orden.
  - "Slow suspend clock": sin apoyo.
  - "Compiles and boots, USB not enumerating": apoyada en esa ruta.

**Notas del fork:**

- **usb-diagnostico:**
  - Polled con IRQ enmascarada: apoyada.
  - "Esa es la causa raíz": contradicha; U-Boot funciona así [9].
  - "Completa más rápido que el poll": contradicha, hay un TRB por endpoint.
  - "tx_busy true para siempre": contradicha por la firma de B.
  - "Lecturas stale": contradicha (L1085, `civac` real).
  - "Linux no usa un TRB por trama": apoyada.
  - "La cura: reclamar por HWO": contradicha [3].
- **usb-status:**
  - "El fallo es anterior al SETEPCONFIG": contradicha, es justo ese timeout.
  - Formato del ring: apoyado.
- **acceso-al-telefono:** n=1 apoyada (con la corrección de VBUS); sshd sin claves, apoyada.
- **toolchain-findings:**
  - "zig filtra -N": contradicha.
  - El ring en iosroot: apoyado.
- **build-recipes:** DXB aplica 0327 y 0328: apoyada; los `*.sh` no son idempotentes: apoyada.
- **README:** "USB no enumera": obsoleta.
- **Comentarios de 0107/0111:** "`flush_dcache` es un no-op": falso para esta build.

## 5. Diseño corregido

El boceto completo está en `anexos/sweet_usb_design_sketch.c` (no compila: es pseudo-C con referencias).

**Reglas:**

1. Solo `ud_thread` toca el controlador; `ud_if_output` encola y despierta.
2. Un único flag de propiedad por endpoint. Lo pone un Start aceptado y lo borra solo un XferComplete con HWO a 0, o un End terminado.
3. Un TRB solo se escribe en estado IDLE.
4. Un Start rechazado no pierde la trama ni imprime, y va seguido de un End.
5. DMA no cacheable (`IOSetProcessorCacheMode(..., kIOWriteCombineCache)`), sin `ud_sync`.
6. End con GUCTL2[14] y 1 ms antes de reutilizar.
7. Órdenes sondeadas girando, nunca con `delay()`.

**Estructura:**

- **Bucle:** GEVNTCOUNT & 0xfffc con comprobación de tamaño, luego despacho, poll de endpoints y las bombas de RX y TX. Espera de 1 ms en reposo y de 125-250 µs con tráfico.
- **Vigilancia de evento ausente:** solo con HWO a 0 y sin evento durante 8 polls con GEVNTCOUNT=0; cuenta como anomalía.
- **Reset:** primero ep0, luego End de todo lo STARTED, luego ClearStall.
- **Sin rearme periódico de RX.**
- **Log:** como máximo 16 datagramas por vuelta; se detiene ante ENOBUFS.

**Instrumentación** (contadores y fotos con cerrojo, las 8 primeras y la última, leídas por sysctl):

- Start rechazado: DEPCMD, las 4 palabras del TRB, GDBGFIFOSPACE, DSTS, GEVNTCOUNT y los tiempos.
- Start aceptado cuyo TRB queda sin HWO y sin evento (la firma de α).
- Evento con el endpoint no STARTED, y evento con HWO puesto.
- Polls con HWO a 0 y sin evento.
- Latencia del End.
- Periodo máximo de poll.
- Foto de arranque de GCC, DWC3, QSCRATCH, PHY y PMIC.

## 6. Experimentos decisivos (propuestos)

1. **Arranque en frío con cable**: 3 por la ruta R y 3 por la ruta C. → **Hecho en parte:** R1 y C1, ver 03.
2. **Volcado de solo lectura** en ambas rutas. → **Parche 0329** (compilando).
3. **Inicialización escalonada** ante el timeout de DEPCFG: mux, luego PHY, luego reset del core.
4. **Repetir el `dd`** con fotos y sin `printf`:
   - si es α: un "Start aceptado sin HWO y sin evento", y después solo rechazos con el FIFO de TX vacío;
   - si es β: rechazos con HWO a 1 y FIFO con datos.
5. **Sonda con el enlace atascado:** TRB válido más Update Transfer (orden 7).
   - α: sale la trama;
   - β: nada.
6. **A/B con `ud_reclaim_fast` desactivable** (`sweetusb_reclaim=0`, ya en 0329), 10 × 30 MB por sentido.
7. **Lo mismo con memoria no cacheable:** "late rx" debería ir a 0.
8. **`fastboot boot` de expG** (solo RAM).

**No verificado:**

- si fue α o β;
- qué paso libera el endpoint;
- el estado del PHY y de QSCRATCH;
- la causa de ExpC;
- la prueba de 30 MB de Angel;
- AppleUserECM ante errores;
- el texto del databook 3.30a;
- los periodos del modelo.

## Referencias

Base Linux: `https://github.com/torvalds/linux/blob/v6.12/`. Base U-Boot: `https://github.com/u-boot/u-boot/blob/v2025.01/`.

1. `gadget.c` `__dwc3_gadget_ep_enable()` L893-925: "Issue StartTransfer here with no-op TRB so we can always rely on No Response Update Transfer command."
2. `dwc3_gadget_endpoint_transfer_complete()` L3641 `dep->flags &= ~DWC3_EP_TRANSFER_STARTED;`; `__dwc3_gadget_kick_transfer()` L1620.
3. Commit 51f1954ad853 (Thinh Nguyen, Synopsys): "We can't depend on the TRB's HWO bit... A TRB is only available when the driver had processed it, not when the controller consumed and relinquished the TRB's ownership to the driver."
4. `dwc3_send_gadget_ep_cmd()` L398-402 (`DEPEVT_TRANSFER_NO_RESOURCE` → "No resource for"), `core.h` L1468, L389-423, L441-443, L320-345.
5. `__dwc3_stop_active_transfer()` L1692-1695: with ForceRM "won't clear the HWO bit... will also not complete immediately".
6. `core.c` `dwc3_core_init()` L1385-1391: ENDXFER polling, `GUCTL2_RST_ACTBITLATER`.
7. `dwc3_gadget_reset_interrupt()` L4036-4049: databook 3.30a §4.1.2 Table 4-2 "a DEPENDXFER command for any active transfers".
8. `dwc3_stop_active_transfer()` L3887-3891: Setup pending blocks End Transfer.
9. U-Boot `gadget.c`: `dwc3_gadget_uboot_handle_interrupt()` L2743-2760; `__dwc3_cleanup_done_trbs()` L1762-1772; L1850 flush; `__dwc3_gadget_kick_transfer()` L905-908 `-EBUSY`; `dwc3_stop_active_transfer()` L2058-2071; `dwc3_send_gadget_ep_cmd()` L350-359.
10. `core.c` `dwc3_hs_phy_setup()` L751-759; `gadget.c` L299-302.
11. `dwc3-qcom.c` `dwc3_qcom_select_utmi_clk()` L517-532, `vbus_override_enable()` L119-132, resets L755-763; `phy-qcom-snps-femto-v2.c` `qcom_snps_hsphy_init()` L386-469.
12. LineageOS `android_kernel_motorola_sm6225` lineage-21: `khaje-usb.dtsi` L127-150; `dwc3-msm.c` L2066-2092; `phy-msm-snps-hs.c` `msm_hsphy_init()` L344-466; `smb5-reg.h` L233-240.
13. darwin-xnu-build `build.sh` L472-478 (skip silencioso de parches).
