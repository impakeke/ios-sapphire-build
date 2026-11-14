# 05 — Parche 0330: ruta de datos USB v2 (`sweetusb_dp=2`) — 2026-11-14

- **Autor:** agente Claude Opus 5.5 (64 herramientas, unos 26 min), con el diseño de la auditoría (01 §5).
- **Verificado de forma independiente** (sesión principal): 0329 + 0330 pasan `git apply --check` y `apply` en orden sobre el post-0328 reconstruido (2187 líneas).
- **No probado todavía** en el teléfono. Compilación en CI pendiente.

## Elección: dos rutas en el mismo kernel

- **Bloque nuevo:** todo lo nuevo va en un bloque contiguo.
- **Fuera del bloque** solo hay ocho desvíos `if (ud_dp)`, en estos puntos de entrada:
  - `ud_notify_connected`
  - `ud_configure` (no arma RX)
  - `ud_ep_reset_seq`
  - `ud_if_output`
  - `ud_bus_reset`
  - `ud_event` (ep ≥ 2)
  - `gadget_start` (boot-args, init, elección de hilo)
  - el tope del hilo de log
- **Cambio que corre siempre:** `kern.sweet_usb_stats` lee los TRB en los nuevos offsets cuando dp=2.
- **dp=0:** se comporta igual que 0329.

## Diseño implementado (dp=2)

- **Un solo dueño.** `ud_dp_thread` es el único que toca controlador, TRB y estado. `ud_if_output` solo encola bajo `ud.lock`, marca `kick` y despierta al hilo. Devuelve ENOBUFS si la cola está llena o el dispositivo no está configurado.
- **Estado por endpoint de datos (RX/TX/INT).** Transiciones:
  - IDLE → STARTED: con el Start.
  - STARTED → IDLE: **solo** con un XferComplete cuyo TRB tiene HWO=0.
  - STARTED → ENDING: con un End (ForceRM, sin IOC).
  - ENDING → IDLE: cuando CMDACT se libera, más 1 ms medido antes del vaciado de eventos de esa vuelta. Los eventos viejos se descartan mientras el endpoint sigue en ENDING.
- **Fuera:** 0327 (reclaim por HWO), `ud_watch` y el rearme periódico de RX.
- **Escrituras.** El TRB y el buffer (UD_TX y la notificación) se escriben **solo en IDLE**.
- **Start rechazado o con timeout.** Se registra un contador y una foto (DEPCMD, las 4 palabras del TRB, DSTS y GEVNTCOUNT). La trama queda preparada, sin printf, y se emite un End con el índice que devuelve el rechazo (Linux gadget.c 433-434), o con el último índice aceptado si ese vale 0.
- **End diferido** mientras ep0 no esté en SETUP (gadget.c 3886-3897), salvo en bus reset y clear-halt.
- **Comandos de endpoint.**
  - GUCTL2[14] se activa si GSNPSID ≥ 3.10a.
  - CMDACT se sondea girando con `mach_absolute_time`: 2 ms para Start y 5 ms para End. Si no termina, se resuelve en vueltas posteriores.
  - Nunca `delay()` y nunca con `ud.lock` tomado.
  - SUSPHY y ENBLSLPM quedan a 0 en cada comando.
- **TRB y DMA (D4).**
  - Los TRB de RX, TX e INT están en 0x1400, 0x1440 y 0x1480, cada uno en su propia línea de 64 B.
  - La DMA se mapea como Normal **no cacheable** con `ml_io_map_unmappable(pa, 16K, VM_WIMG_WCOMB)` tras un flush. Va en kernel_map, no en el io_submap.
  - Con `sweetusb_dpnc=0` queda cacheable, con clean/invalidate por línea.
- **Firma α.** STARTED con HWO=0 y sin evento durante 8 vueltas y 2 ms: se cuenta, se toma foto y se emite End. La trama se contabiliza a partir del TRB.
- **Bus reset.** ep0 primero. Después, End de todo lo STARTED y espera; ClearStall si estaba configurado y el End terminó; DALEPENA; `configured=false`; y se vacía la cola.
- **Clear-halt / SET_INTERFACE.** End, espera y ClearStall; el rearme va 1 ms después.
- **Eventos.**
  - `GEVNTCOUNT & 0xfffc`. Si la cuenta supera el tamaño, se registra una anomalía con foto.
  - `dmb` antes de devolver la cuenta.
  - Con tráfico (últimos 10 ms): gira hasta 50 µs y luego duerme 125 µs. En reposo duerme 1 ms.
  - Los despertares no se pierden: `clear_wait` si ya hubo `kick`.
- **Log.** Máximo 16 datagramas por despertar; para en el primer error.
- **printf.** Nunca en la ruta de datos. Solo en init, en los primeros 200 eventos de control y en un resumen cada 30 s.
- **sysctl `kern.sweet_usb_dp`.**
  - Configuración (nc, actbitlater, GSNPSID, GUCTL2) y estado y TRB de cada endpoint.
  - Start: ok, refused, timeout, cmd_busy.
  - End: issued, deferred, timeout, y latencia en µs (máx, última, suma).
  - Eventos: noevt(α), hwo0_noevt_polls, evt_not_started, evt_hwo_set, buserr, anomalías de evcount.
  - Tramas: tx/rx done y by_end, qdrop, bad.
  - `poll_max_us`.
  - Fotos con cerrojo (las 8 primeras y la última) bajo seqlock.

## Invariantes (argumentados por el autor)

- **I1. Escritor único.** El hilo USB es el único que escribe en registros, TRB, buffers y `dp.*`. `ud_if_output` solo toca la cola bajo el lock, más `kick` y el wakeup. El log solo hace `sock_send`. El sysctl solo lee.
- **I2. HWO=0 por sí solo nunca libera.** Para pasar a IDLE hace falta un evento con HWO=0, o End completado + 1 ms + vaciado.
- **I3.** Solo se escribe en IDLE. HWO se pone a 0 a mano solo después de que el End se completa.
- **I4.** Ningún comando se emite con CMDACT puesto.
- **I5.** Ninguna trama se pierde por un rechazo. Los descartes de bus reset y clear-halt se cuentan.
- **I6.** Con `ud.lock` tomado: ni comandos, ni giros, ni `delay`, ni printf.
- **I7.** Todo giro está acotado.
- **I8. Vivacidad.**
  - STARTED sale por evento, por α o por rechazo + End.
  - ENDING sale cuando CMDACT se libera.
  - Excepciones (contadas): β (HWO=1 sin evento porque el host no sondea), un End que nunca termina, y ep0 que nunca vuelve a SETUP.
- **I9.** Un evento viejo nunca libera la transferencia siguiente.

## Verificación hecha por el autor

1. 0329 y luego 0330: `git apply --check` y `apply` OK. El resultado es idéntico byte a byte al árbol de trabajo.
2. **Compilación.**
   - `clang -fsyntax-only` (Apple clang 21) contra las cabeceras reales de XNU del replay, con `KERNEL`, `XNU_KERNEL_PRIVATE`, `BSD_KERNEL_PRIVATE`, `__arm64__` y `ARM64_BOARD_CONFIG_SWEET`: **0 errores**. Se comprobó inyectando un error que el bloque nuevo se compila de verdad.
   - Con las WARNFLAGS de XNU no aparecen clases de aviso nuevas.
   - **El enlazado no se verificó** (`ml_io_map_unmappable`, `clear_wait`, `current_thread`).
3. **Modelo DES** de la máquina nueva con un controlador adversarial (`~/sapphire-angel/research/auditoria-sweet_usb/sim/usbsim_dp.py`).
   - Escenarios: A1-A3, más eventos antes del write-back, eventos perdidos, duplicados, recurso tardío, transferencias ocultas, End atascado 8 ms y ep0 fuera de SETUP. 20 × 5 s cada uno, 9 escenarios en total.
   - Resultado: 0 escrituras de TRB poseído, 0 TX falsas, 0 duplicados, 0 RX perdidas o duplicadas. Bloqueo máximo con cola: 0,5 ms (nominal) y 10 ms ("todo junto").
   - "Nominal": ~2850 TX/s y ~1480 RX/s, 0 rechazos.
   - "Todo junto": 1743 TX/s, 1449 rechazos y 203 α, todos recuperados sin pérdida.
   - Es una comprobación de coherencia, no una prueba.
4. **Relectura adversarial.** Se añadió un `dmb` antes de devolver GEVNTCOUNT y se movieron los `DP_TRB_*` antes del sysctl.

## Riesgos y limitaciones conocidos

- **DMA no cacheable.** Es la primera vez que se usa `ml_io_map_unmappable` sobre DRAM gestionada en este port (antes solo sobre el carveout del splash). Si falla: `sweetusb_dpnc=0`. Los alias cacheables siguen existiendo, como en Linux.
- **ep0 sin cambios.** Sigue usando `delay(1)` y `delay(100)` (bloquea solo en las transferencias de control). En modo cacheable, los TRB OUT e IN de ep0 comparten línea.
- **Índice de recurso 0 tras un rechazo.** Si el último índice aceptado no coincide, queda un ciclo rechazo/End cada ~1 ms. Está contado y sin tormenta de printf.
- **Transferencia oculta en el controlador.** Puede perder o duplicar una trama de TX (TCP lo recupera).
- **SET_CONFIGURATION con un End atascado.** Emitiría DEPCFG encima. Es raro y se ve en `end_timeout`.
- **Arquitectura.** Sigue siendo un TRB por endpoint, sin ring. El giro de 50 µs gasta CPU mientras hay tráfico.
- **Snapshot sin GDBGFIFOSPACE**, porque leerlo requiere escribir un selector.
- **Lectura de las estadísticas con dp=2.**
  - En `kern.sweet_usb_stats`, `tx` cuenta tramas completadas, no intentos.
  - `tx_busy` y `xfer_active` no tienen sentido.
  - `sweetusb_reclaim` se ignora.
- **Longitud del cmdline.** Si supera 575 caracteres, el shim deja de pasar `sweet_splash` (lo dice el empaquetador). Para el A/B, que todas las variantes tengan la misma longitud.

## Boot-args para el A/B (mismo kernel, `sweetusb=2`)

| Variante | Boot-args | Para qué |
|---|---|---|
| A | `sweetusb_dp=0 sweetusb_reclaim=1` | ruta actual (debería reproducir B) |
| A' | `sweetusb_dp=0 sweetusb_reclaim=0` | 0329 sin 0327 |
| B | `sweetusb_dp=2` | ruta nueva, DMA no cacheable |
| B' | `sweetusb_dp=2 sweetusb_dpnc=0` | aísla el efecto de no cacheable (los "late rx" deberían bajar a 0) |

- Para comparar solo la ruta de datos, correr también A y B con `sweetusblog=0`: en A, el bucle printf → log forma parte del fallo.
- Leer `sysctl kern.sweet_usb_dp` y `kern.sweet_usb_stats` antes y después de cada copia de 30 MB.

**Qué buscar en `kern.sweet_usb_dp`:**

| Firma | Señal |
|---|---|
| α | `noevt-alpha n>0` con TRB HWO=0 |
| β | STARTED con HWO=1, sin eventos y con la cola llena |
| Rechazos | las fotos de start-refused |

**Árbol de trabajo:** `/private/tmp/claude-501/-Users-allen/023de825-673e-4660-ae00-c398ca82af1e/scratchpad/usb0330`. Se copió a `~/sapphire-angel/research/parche-0330/`.
