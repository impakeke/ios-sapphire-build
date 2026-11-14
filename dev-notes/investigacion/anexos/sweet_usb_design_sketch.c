/*
 * sweet_usb.c -- corrected bulk path and init, polled, interrupt masked.
 * DESIGN SKETCH (not compiled, not a patch). Line references "L:" are Linux v6.12
 * drivers/usb/dwc3, "U:" U-Boot v2025.01 drivers/usb/dwc3.
 *
 * Rules that replace the current logic:
 *  R1  Only ud_thread touches the controller, the TRBs and the endpoint state.
 *      ud_if_output() enqueues and wakes the thread.                      (U: single threaded poll)
 *  R2  "The controller owns a transfer on this endpoint" is ONE flag, e->st. It is set by a
 *      Start Transfer that returned status 0 and cleared only by (a) an XferComplete event for
 *      that endpoint whose TRB has HWO clear, or (b) an End Transfer that has completed.
 *      HWO alone never clears it.                (L: gadget.c 3636-3649, 1603-1652; commit 51f1954ad853)
 *  R3  A TRB is written only while e->st == XS_IDLE.
 *  R4  A refused Start Transfer never drops the frame, never prints, and is followed by End Transfer.
 *  R5  DMA memory is Normal non-cacheable: no cache maintenance, no shared-line hazard.
 *                                                (L: dma_alloc_coherent, gadget.c 493, core.c 487)
 *  R6  End Transfer is waited for before the endpoint is used again.      (L: gadget.c 3865-3929, 441-443)
 *  R7  Endpoint commands are polled by spinning, never by a blocking delay(). (L: gadget.c 389-423)
 */

enum xs { XS_IDLE, XS_STARTED, XS_ENDING };

struct uep {
	enum xs   st;
	uint8_t   rsc;                  /* resource index of the last accepted Start Transfer */
	uint32_t  trb, buf;             /* DMA offsets */
	uint64_t  ready_at;             /* XS_ENDING until this absolute time */
	bool      evt_pending;          /* XferComplete seen while the TRB still had HWO (see on_xfer_complete) */
	uint64_t  evt_pending_since;
	unsigned  hwo_noevt_polls;      /* TRB written back, no event yet */
};
static struct uep E[EP_INT + 1];

/* ---- R5: memory ------------------------------------------------------------------------- */
static int
ud_dma_init(void)
{
	if (kmem_alloc_contig(kernel_map, &ud.dma, UD_SIZE, PAGE_MASK, 0, 0,
	    KMA_DATA | KMA_ZERO | KMA_PERMANENT, VM_KERN_MEMORY_IOKIT) != KERN_SUCCESS) {
		return -1;
	}
	ud.dma_pa = ptoa_64(pmap_find_phys(kernel_pmap, (addr64_t)ud.dma));
	flush_dcache64(ud.dma_pa, UD_SIZE, TRUE);               /* zeros reach DRAM, no line stays cached */
	/* the same remap IOBufferMemoryDescriptor uses; the port already maps other DMA this way
	 * (md->map(kIOMapWriteCombineCache) in SweetFramebuffer/SapphireGpu/TopazModem) */
	return IOSetProcessorCacheMode(kernel_task, ud.dma, UD_SIZE, kIOWriteCombineCache) == kIOReturnSuccess ? 0 : -1;
	/* from here on: no ud_sync() anywhere; the physmap alias of these pages is never touched */
}

/* ---- R7: endpoint command ---------------------------------------------------------------- */
static int
ud_epcmd(unsigned ep, uint32_t cmd, uint32_t p0, uint32_t p1, uint32_t p2, uint32_t *status)
{
	uint32_t phy = dwc_rd(GUSB2PHYCFG), v;

	if (phy & (GUSB2PHYCFG_SUSPHY | GUSB2PHYCFG_ENBLSLPM)) {       /* L: gadget.c 320-345 */
		dwc_wr(GUSB2PHYCFG, phy & ~(GUSB2PHYCFG_SUSPHY | GUSB2PHYCFG_ENBLSLPM));
	}
	dwc_wr(DEPCMDPAR0(ep), p0);
	dwc_wr(DEPCMDPAR1(ep), p1);
	dwc_wr(DEPCMDPAR2(ep), p2);
	dwc_wr(DEPCMD(ep), cmd | DEPCMD_CMDACT);
	uint64_t limit = mach_absolute_time() + ud.abs_2ms;
	do {                                                            /* spin: the command takes microseconds */
		v = dwc_rd(DEPCMD(ep));
	} while ((v & DEPCMD_CMDACT) && mach_absolute_time() < limit);
	if (phy & (GUSB2PHYCFG_SUSPHY | GUSB2PHYCFG_ENBLSLPM)) {       /* L: gadget.c 445-449 */
		dwc_wr(GUSB2PHYCFG, phy);
	}
	if (v & DEPCMD_CMDACT) {
		ud_note(N_CMD_TIMEOUT, ep, cmd, v);                     /* counter + latched snapshot, no printf */
		return -2;
	}
	*status = (v >> 12) & 0xf;
	return *status ? -1 : 0;
}

/* ---- R2/R3/R4: start ---------------------------------------------------------------------- */
static void ud_xfer_end(unsigned ep);

static int
ud_xfer_start(unsigned ep, uint32_t len, uint32_t ctl)
{
	struct uep *e = &E[ep];
	volatile uint32_t *t = (volatile uint32_t *)(ud.dma + e->trb);
	uint64_t bpa = ud.dma_pa + e->buf, tpa = ud.dma_pa + e->trb;
	uint32_t st = 0;

	if (e->st != XS_IDLE) {                 /* R3: never rewrite a TRB the controller may own */
		ud_note(N_START_NOT_IDLE, ep, e->st, 0);
		return -1;
	}
	t[0] = (uint32_t)bpa; t[1] = (uint32_t)(bpa >> 32); t[2] = len;
	t[3] = ctl | TRB_HWO | TRB_LST | TRB_IOC | (ep & 1 ? 0 : TRB_ISP_IMI);
	__builtin_arm_dsb(DSB_SY);              /* write-combined mapping: make the stores reach DRAM */
	int r = ud_epcmd(ep, DEPCMD_STARTTRANSFER, (uint32_t)(tpa >> 32), (uint32_t)tpa, 0, &st);
	if (r == 0) {
		e->rsc = (uint8_t)((dwc_rd(DEPCMD(ep)) >> 16) & 0x7f);
		e->st = XS_STARTED;
		e->evt_pending = false;
		e->hwo_noevt_polls = 0;
		return 0;
	}
	/* R4: refused (status 1 = No Resource: a transfer we lost track of) or timed out */
	ud_snapshot(N_START_REFUSED, ep);       /* DEPCMD, TRB as the controller left it, FIFO space, DSTS, GEVNTCOUNT */
	t[3] &= ~TRB_HWO;
	ud_xfer_end(ep);                        /* end whatever the controller holds; idle again after the settle time */
	return -1;                              /* the caller keeps its frame and retries on a later poll */
}

/* ---- R6: end ------------------------------------------------------------------------------ */
static void
ud_xfer_end(unsigned ep)
{
	struct uep *e = &E[ep];
	uint32_t st = 0;

	/* GUCTL2[14] is set at init (DWC_usb3 >= 3.10a), so CMDACT clears when the command is done
	 * (L: core.c 1383-1392); 1 ms more is what Linux gives a non-IOC End Transfer (L: gadget.c 441-443). */
	(void)ud_epcmd(ep, DEPCMD_ENDTRANSFER | DEPCMD_HIPRI_FORCERM | ((uint32_t)e->rsc << 16), 0, 0, 0, &st);
	((volatile uint32_t *)(ud.dma + e->trb))[3] &= ~TRB_HWO;       /* ForceRM leaves HWO set (L: gadget.c 1692-1695) */
	e->st = XS_ENDING;
	e->ready_at = mach_absolute_time() + ud.abs_1ms;
	e->evt_pending = false;
}

static inline bool
ud_ep_idle(struct uep *e)
{
	if (e->st == XS_ENDING && mach_absolute_time() >= e->ready_at) {
		e->st = XS_IDLE;
	}
	return e->st == XS_IDLE;
}

/* ---- completion: the event is the authority, HWO is its proof -------------------------------- */
static void ud_rx_complete(void), ud_tx_complete(void);

static void
ud_complete(unsigned ep)
{
	struct uep *e = &E[ep];
	e->st = XS_IDLE;
	e->evt_pending = false;
	e->hwo_noevt_polls = 0;
	if (ep == EP_RX) {
		ud_rx_complete();
	} else if (ep == EP_TX) {
		ud_tx_complete();
	}
}

static void
on_xfer_complete(unsigned ep, uint32_t ev)
{
	struct uep *e = &E[ep];
	volatile uint32_t *t = (volatile uint32_t *)(ud.dma + e->trb);

	if (e->st != XS_STARTED) {              /* late event of a transfer already taken or ended */
		ud_note(N_EVT_NOT_STARTED, ep, ev, e->st);
		return;
	}
	if (t[3] & TRB_HWO) {                   /* not (yet) the completion of the TRB now armed */
		ud_note(N_EVT_HWO_SET, ep, ev, t[3]);
		e->evt_pending = true;              /* resolved in ud_poll_endpoints(): taken when HWO clears, dropped after 2 ms */
		e->evt_pending_since = mach_absolute_time();
		return;
	}
	ud_complete(ep);
}

/* once per poll, after the event buffer has been drained */
static void
ud_poll_endpoints(uint32_t evcount_now)
{
	for (unsigned ep = EP_RX; ep <= EP_INT; ep++) {
		struct uep *e = &E[ep];
		volatile uint32_t *t = (volatile uint32_t *)(ud.dma + e->trb);
		if (e->st != XS_STARTED) {
			continue;
		}
		bool done = !(t[3] & TRB_HWO);
		if (e->evt_pending) {
			if (done) {
				ud_complete(ep);                    /* the event came first, the write-back after */
			} else if (mach_absolute_time() - e->evt_pending_since > ud.abs_2ms) {
				e->evt_pending = false;             /* it was a stale event */
			}
		} else if (done && evcount_now == 0) {
			/* written back and no event in the buffer: measure it, and only after 8 polls call it lost */
			if (++e->hwo_noevt_polls == 1) {
				ud_note(N_HWO_BEFORE_EVT, ep, t[3], t[2]);
			}
			if (e->hwo_noevt_polls >= 8) {
				ud_snapshot(N_EVT_LOST, ep);
				ud_complete(ep);                    /* a late event is then refused by on_xfer_complete() */
			}
		} else {
			e->hwo_noevt_polls = 0;
		}
	}
}

/* ---- TX ------------------------------------------------------------------------------------- */
static errno_t
ud_if_output(ifnet_t ifp, mbuf_t m)          /* R1: no hardware here */
{
	lck_mtx_lock(ud.lock);
	if (!ud.configured || ud.txq_count == UD_TXQ) {
		lck_mtx_unlock(ud.lock);
		mbuf_freem(m);
		ifnet_stat_increment_out(ifp, 0, 0, 1);
		return ENOBUFS;                      /* back-pressure: the log thread stops instead of spinning */
	}
	ud.txq[(ud.txq_head + ud.txq_count++) % UD_TXQ] = m;
	lck_mtx_unlock(ud.lock);
	thread_wakeup(&ud.poll_chan);            /* its own channel, not the log thread's */
	return 0;
}

static void
ud_tx_pump(void)
{
	struct uep *e = &E[EP_TX];

	if (!ud.configured || !ud_ep_idle(e)) {
		return;
	}
	if (ud.tx_len == 0) {                    /* nothing staged in UD_TX: take the next frame */
		mbuf_t m = NULL;
		lck_mtx_lock(ud.lock);
		if (ud.txq_count > 0) {
			m = ud.txq[ud.txq_head];
			ud.txq_head = (ud.txq_head + 1) % UD_TXQ;
			ud.txq_count--;
		}
		lck_mtx_unlock(ud.lock);
		if (m == NULL) {
			return;
		}
		size_t len = mbuf_pkthdr_len(m);
		if (len > ETHER_MAX_LEN - ETHER_CRC_LEN || mbuf_copydata(m, 0, len, (void *)(ud.dma + UD_TX)) != 0) {
			mbuf_freem(m);
			ud.c.tx_bad++;
			return;
		}
		mbuf_freem(m);
		if ((len % 512) == 0) {              /* same as Linux u_ether.c 567-572 */
			((uint8_t *)(ud.dma + UD_TX))[len++] = 0;
		}
		ud.tx_len = (uint32_t)len;
	}
	if (ud_xfer_start(EP_TX, ud.tx_len, TRBCTL_NORMAL) == 0) {
		ud.c.tx_started++;
	}                                        /* else: the frame stays staged; retried when the endpoint is idle again */
}

static void
ud_tx_complete(void)
{
	ud.c.tx_done++;
	ud.tx_len = 0;
	ud_tx_pump();
}

/* ---- RX ------------------------------------------------------------------------------------- */
static void
ud_rx_pump(void)
{
	if (ud.configured && ud_ep_idle(&E[EP_RX])) {
		(void)ud_xfer_start(EP_RX, UD_FRAME_MAX, TRBCTL_NORMAL);   /* 2048: a multiple of wMaxPacketSize */
	}
}

static void
ud_rx_complete(void)
{
	volatile uint32_t *t = (volatile uint32_t *)(ud.dma + UD_TRB_RX);
	uint32_t len = UD_FRAME_MAX - (t[2] & 0xffffff);

	if ((t[2] >> 28) == 0 && len >= ETHER_HDR_LEN && len <= ETHER_MAX_LEN && ud.ifp != NULL) {
		/* mbuf_gethdr + mbuf_mclget + memcpy + ifnet_input, as today */
		ud.c.rx_done++;
	} else {
		ud.c.rx_bad++;
	}
	ud_rx_pump();
}
/* no periodic "rx rearm": an armed, idle OUT endpoint needs nothing */

/* ---- bus reset, clear halt -------------------------------------------------------------------- */
static void
ud_bus_reset(void)
{
	ud_ep0_stall_and_restart();              /* ep0 first: End Transfer may not complete with a SETUP
	                                          * waiting and no SETUP TRB (L: gadget.c 3886-3897, 4035-4041) */
	for (unsigned ep = EP_RX; ep <= EP_INT; ep++) {
		if (E[ep].st == XS_STARTED) {    /* e->st is right by construction; "a DEPENDXFER command for
			                          * any active transfers" (L: gadget.c 4043-4049) */
			ud_xfer_end(ep);
		}
		uint32_t st;
		(void)ud_epcmd(ep, DEPCMD_CLEARSTALL, 0, 0, 0, &st);
	}
	dwc_wr(DALEPENA, dwc_rd(DALEPENA) & ~((1u << EP_RX) | (1u << EP_TX) | (1u << EP_INT)));
	dwc_wr(DCFG, dwc_rd(DCFG) & ~(0x7fu << 3));
	lck_mtx_lock(ud.lock);
	ud.configured = false;
	/* free the queue */
	lck_mtx_unlock(ud.lock);
	ud.tx_len = 0;
}

static void
ud_ep_reset_seq(unsigned ep)                     /* CLEAR_FEATURE(ENDPOINT_HALT), SET_INTERFACE */
{
	uint32_t st;
	if (E[ep].st == XS_STARTED) {
		ud_xfer_end(ep);
	}
	while (!ud_ep_idle(&E[ep])) {            /* control path, rare: wait the settle time here */
		ud_spin_us(50);
	}
	(void)ud_epcmd(ep, DEPCMD_CLEARSTALL, 0, 0, 0, &st);     /* after the End Transfer (L: gadget.c 2177-2196) */
	if (ep == EP_TX) {
		ud.tx_len = 0;
	}
	/* the pumps restart the endpoint on this same poll */
}

/* ---- the poll loop ------------------------------------------------------------------------------ */
static void
ud_thread(void *arg __unused, wait_result_t wr __unused)
{
	for (;;) {
		uint32_t count = dwc_rd(GEVNTCOUNT) & 0xfffc;           /* L: core.h 78 */
		if (count > UD_EVT_SIZE) {
			ud_snapshot(N_EVT_OVERFLOW, 0);
			ud_reinit();                                     /* soft disconnect, core reset, init, reconnect */
			continue;
		}
		for (uint32_t done = 0; done < count; done += 4) {
			uint32_t ev = *(volatile uint32_t *)(ud.dma + UD_EVT + ud.evt_pos);
			ud.evt_pos = (ud.evt_pos + 4) % UD_EVT_SIZE;
			ud_event(ev);                                    /* XferComplete -> on_xfer_complete() */
		}
		if (count) {
			dwc_wr(GEVNTCOUNT, count);
		}
		ud_poll_endpoints(dwc_rd(GEVNTCOUNT) & 0xfffc);
		ud_rx_pump();
		ud_tx_pump();
		/* 1 ms when idle, 125-250 us while frames are moving; ud_if_output() wakes it at once */
		uint64_t deadline = mach_absolute_time() + (ud.busy ? ud.abs_200us : ud.abs_1ms);
		(void)assert_wait_deadline(&ud.poll_chan, THREAD_UNINT, deadline);
		thread_block(THREAD_CONTINUE_NULL);
	}
}

/* ---- live log: bounded ---------------------------------------------------------------------------- */
/* per 100 ms wake: at most 16 datagrams; stop at the first sock_send() error (ENOBUFS from ud_if_output);
 * nothing reachable from ud_if_output()/ud_tx_pump() may printf more than once per second. */

/* ---- init that does not depend on what ABL did --------------------------------------------------- */
static int
ud_hw_init(void)
{
	/* 0. regulators of the HS PHY through RPM: L4A (0.88 V), L12A (1.8 V), L15A (3.3 V), XO buffer
	 *    (vendor khaje-usb.dtsi hsphy@1613000). State on a cold boot: unknown, measure first. */
	/* 1. GCC 0x1400000: GDSC 0x1a004 on; CBCR enable (bit 0) and wait CLK_OFF (bit 31) clear for
	 *    0x1a010 master, 0x1a014 sleep, 0x1a018 mock_utmi, 0x1a084 cfg_noc, 0x1a080 sys_noc,
	 *    0x1d008 ahb2phy, 0x9f000 clkref; master RCG 0x1a01c = 66.67 MHz (Linux gcc-sm6115.c 1408-1428,
	 *    vendor "qcom,core-clk-rate-hs = <66666667>"); mock_utmi 19.2 MHz. */
	/* 2. resets: GCC_USB30_PRIM_BCR 0x1a000 assert, >= 10 us, deassert (L: dwc3-qcom.c 755-763);
	 *    GCC_QUSB2PHY_PRIM_BCR 0x1c000 assert, 100-150 us, deassert (L: phy-qcom-snps-femto-v2.c 403-411). */
	/* 3. femto PHY 0x1613000 (L: qcom_snps_hsphy_init 415-465; vendor msm_hsphy_init):
	 *      CFG0(0x94)   |= UTMI_PHY_CMN_CTRL_OVERRIDE_EN (bit 1)
	 *      UTMI_CTRL5(0x50) |= POR (bit 1)
	 *      COMMON0(0x54) FSEL (6:4) = 0
	 *      COMMON1(0x58) |= PLLBTUNE (bit 5)
	 *      REFCLK_CTRL(0xa0) REFCLK_SEL (1:0) = 2
	 *      COMMON1(0x58) |= VBUSVLDEXTSEL0 (bit 4);  CTRL1(0x60) |= VBUSVLDEXT0 (bit 0)
	 *      overrides from the phone's DT (generic khaje: 0x6c = 0xa6, 0x70 = 0x85, 0x74 = 0x16)
	 *      COMMON2(0x5c) |= VREGBYPASS (bit 0)
	 *      CTRL2(0x64)  |= USB2_SUSPEND_N_SEL | USB2_SUSPEND_N (bits 3, 2)
	 *      UTMI_CTRL0(0x3c) |= SLEEPM (bit 0)
	 *      COMMON0(0x54) &= ~SIDDQ (bit 2)
	 *      UTMI_CTRL5(0x50) &= ~POR
	 *      CTRL2(0x64)  &= ~USB2_SUSPEND_N_SEL
	 *      CFG0(0x94)   &= ~UTMI_PHY_CMN_CTRL_OVERRIDE_EN
	 *    Skip all of it when the EUD enable register (0x1612000) reads non-zero (vendor msm_hsphy_init 352-355). */
	/* 4. QSCRATCH 0x4ef8800, high speed only, no SS PHY: GENERAL_CFG(0x08) |= PIPE_UTMI_CLK_DIS (bit 8);
	 *    wait; |= PIPE_UTMI_CLK_SEL | PIPE3_PHYSTATUS_SW (bits 0, 3); wait; &= ~PIPE_UTMI_CLK_DIS
	 *    (L: dwc3-qcom.c 517-532; vendor dwc3-msm.c 2064-2092). */
	/* 5. DWC3 core (L: dwc3_core_init 1313-1392):
	 *      GUSB2PHYCFG(0xc200) &= ~(SUSPHY | ENBLSLPM)     (L: core.c 751-764; sm6115.dtsi dis_u2_susphy/dis_enblslpm)
	 *      GUSB3PIPECTL(0xc2c0) &= ~SUSPHY (bit 17)
	 *      DCTL = CSFTRST, wait clear                      (L: core.c 304-355)
	 *      GCTL(0xc110): PRTCAPDIR = 2 (device)            (L: core.c 134-144)
	 *      GUCTL2(0xc19c) |= bit 14                        (L: core.c 1383-1392)
	 *      GEVNTADR/SIZ/COUNT, evt_pos = 0                 (L: core.c 544-564)
	 *      DCFG: high speed, address 0;  DEVTEN = disconnect | reset | connect done | erratic error | overflow
	 *      ep0: DEPSTARTCFG, DEPCFG, DEPXFERCFG on 0 and 1, DALEPENA = 3, SETUP TRB
	 *      QSCRATCH VBUS override, DCTL.RUN_STOP           (L: dwc3-qcom.c 119-132)
	 *    Every step that fails records which one and the registers, and the function returns that. */
	return 0;
}
