# 14 — USB inestable: diagnóstico de causa raíz y plan de arreglo

El USB (CDC-ECM, 192.168.7.2; lleva el log UDP:5140 y SSH) se cuelga bajo carga, muere en transfers
grandes (scp) y a veces pide reboot. Es el cuello que frena TODO el development. Causa raíz confirmada
leyendo el código (`sweet_usb.c`, patches 0072-0077, 0159, 0162, 0224).

## Causa raíz: el USB es POLLED, con la interrupción ENMASCARADA

Patch 0073 (`sweet-usb-device-ep0.patch`):
```c
dwc_wr(GEVNTSIZ, (1u << 31) | UD_EVT_SIZE);   /* interrupt masked: polled */
// "Events are polled from a kernel thread (no interrupt), like the UFS driver."
dwc_wr(DEVTEN, 0x7);
```
`ud_thread` hace `for(;;) { count = GEVNTCOUNT; procesa; GEVNTCOUNT = count; }`. El bit 31 de GEVNTSIZ
= EVNT_INTR_MASK → la IRQ del DWC3 nunca se usa. El port **no registra ninguna interrupción** (cf.
NOTES: GPU INTID 209 "an interrupt nobody handles... Nothing in this kernel registers it"): todo es polling.

## Por qué falla bajo carga
- A tasa de bulk alta, el controlador completa transfers más rápido que el poll → un evento de completado
  no se ve a tiempo → el endpoint no se re-arma → enlace muerto hasta el siguiente bus reset.
- Patch 0224 (`ud_watch`, cada 500 ms) es un curita: lee el bit HWO del TRB y "toma la frame como si el
  evento hubiera llegado". Cuenta `lost_rx/lost_tx/stale_rx` en `kern.sweet_usb_stats`. No es la cura.
- 0159/0162 arreglaron parte de la recuperación de bus reset (re-armar ep0 para SETUP, re-end de data eps),
  pero NOTES: "the USB net still dies under load at times and needs a reboot".

## CULPABLE #1 CONFIRMADO (código del port)

`sweet_usb.c` usa **un solo TRB por endpoint** (`UD_TRB_RX`/`UD_TRB_TX`) y hace **Start Transfer por
frame**, re-armando SOLO con el evento de completado:
- TX: `ud_tx_kick_locked()` → `ud_start_trb(EP_TX,...)`, `tx_busy=true`; la siguiente frame espera a que el
  evento ponga `tx_busy=false`. Evento perdido → `tx_busy` queda true para siempre → TX muerto.
- RX: un buffer, re-armado en cada completado. Evento perdido o `mbuf` alloc fail → OUT no se re-arma.
Modelo "estilo U-Boot"; Linux NUNCA lo usa para bulk (confirmado leyendo `drivers/usb/dwc3/gadget.c`).

**La cura: no depender del evento.** Ring de TRBs por endpoint + Start Transfer UNA vez + re-kick
reclamando los TRBs con HWO=0 en orden. Aunque se pierda un evento, el siguiente poll reclama todo y
sigue fluyendo.

## Diseño del fix (patch 0327, opción B — sin GIC)
1. **Ring de TRBs** por bulk ep (p.ej. 32-256), no un slot. Start Transfer UNA vez al habilitar el ep;
   TRB 255 = link TRB con HWO permanente de vuelta al 0.
2. **TX:** encolar frames como TRBs (HWO al final + barrera); `Update Transfer` (forma no-response:
   CMDACT/CMDIOC a 0) para avisar al controlador. En cada XferInProgress, reclamar TRBs HWO=0 en orden,
   liberar mbufs, re-kick si hay pendientes. Quitar el flag único `tx_busy`.
3. **RX:** N TRBs OUT siempre encolados con un POOL de buffers DMA propios; al completar, copiar a mbuf
   (o descartar si falla alloc) y **requeue inmediato** del mismo buffer; timer de reintento si el ring
   se vacía. (Arregla también el culpable #6: starvation por un alloc fallido.)
4. **Event buffer cache-coherente:** invalidar antes de leer (DMA no coherente → lecturas stale = "evento
   perdido"). Drenar GEVNTCOUNT completo; `count & 0xfffc`; tratar `count>len` como fatal → recovery.
5. **PHY:** mantener `GUSB2PHYCFG` SUSPHY(bit6) y ENBLSLPM(bit8) **en 0** (si no, los DEPCMD expiran en L1);
   considerar desactivar LPM (DCFG.LPM_CAP) para HS-only.
6. **Reset/disconnect robusto** (completar lo de 0159/0162): End Transfer de todos los eps (diferir si ep0
   no está en SETUP), fallar pendientes, ep0→SETUP (`stall_and_restart`), rehacer enable+requeue en
   SET_CONFIGURATION. Opcional: recovery estilo `dwc3_err_recovery_work` (soft disconnect→soft reset→
   re-init→reconnect) disparado por `count>len`/timeout/watchdog, en vez de pedir reboot.

Referencia Linux (en `scratchpad/dwc3_ref/drivers/usb/dwc3/`): `__dwc3_gadget_kick_transfer`,
`dwc3_gadget_ep_reclaim_completed_trb`, `dwc3_check_event_buf`/`dwc3_process_event_buf`,
`dwc3_gadget_reset_interrupt`, `dwc3_ep0_out_start`, `dwc3_prepare_last_sg` (ZLP).

## Plan de arreglo (resumen de niveles)

### A) Profundo — interrupción del DWC3 (la cura real)
1. Construir registro de IRQ en el GIC-500 (`arm,gic-v3`, dist 0xf200000) — el port no lo tiene.
2. Localizar la SPI del controlador USB (del device tree del SoC).
3. Desenmascarar: `GEVNTSIZ` sin bit 31; ISR lee/drena GEVNTCOUNT y despacha (top/bottom-half estilo Linux
   `dwc3_interrupt`/`dwc3_thread_interrupt`).
Coste alto (infra de interrupciones nueva) pero elimina la clase entera de bugs.

### B) Pragmático fuerte (sin tocar el GIC) — hacer el polling correcto
1. Hilo de polling dedicado, alta prioridad, giro continuo (no dormir entre polls bajo tráfico).
2. **Re-armar el transfer SIEMPRE al completar**, sin depender del evento: mantener el ring de TRBs
   alimentado (modelo `__dwc3_gadget_kick_transfer` de Linux); no quedar idle esperando un evento que puede
   no llegar.
3. Drenar GEVNTCOUNT completo cada poll; manejar wrap del event buffer; subir tamaño si hace falta.
4. Recuperación de bus-reset/disconnect completa (end de transfers, ep0 a SETUP, re-arm) como Linux
   `dwc3_gadget_reset_interrupt` / `dwc3_ep0_out_start`.

### Referencia (agente DWC3 en curso)
Linux `drivers/usb/dwc3/{gadget.c,ep0.c,core.c}`: manejo de eventos (GEVNTCOUNT), re-kick de transfer
(XferNotReady/XferInProgress, DEPCMD), reset de bus, ep0 SETUP, flow control bulk (ZLP, TRB chaining),
y erratas Qualcomm (GUSB2PHYCFG, soft reset DCTL CSFTRST, run/stop). → se convertirá en patch
`0327-sapphire-usb-*` para el kernel dev.

## Síntomas de referencia (NOTES)
- 313: "A big scp over the USB link stalls it (reattach)".
- 389: "The USB link stalls now and then (not a lost event: kern.sweet_usb_stats shows none)".
- 474 (0159/0162): bus reset dejó ue0 muerto; ep0 no re-armado para SETUP ("ep0 cmd 0x6 status 1").
- 489: "The USB net still dies under load at times and needs a reboot".
