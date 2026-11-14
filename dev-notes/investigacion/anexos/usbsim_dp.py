#!/usr/bin/env python3
"""
Discrete-event model of 0330's data path v2 (sweetusb_dp=2) against an adversarial DWC3-like
controller. Derived from the audit's usbsim.py (same controller assumptions A1-A3) but modelling
the new driver state machine function by function: dp_start, dp_end, dp_end_done, dp_pump,
ud_dp_ep_event, dp_ended, dp_poll, ud_dp_thread wait/spin, ud_dp_reset_seq is not modelled.
Consistency check, NOT a proof about the hardware.

Controller (per bulk endpoint, TX = 0x81 and RX = 0x01):
  A1 one transfer resource; Start Transfer while it is held -> status 1 (No Resource), reports its index
  A2 completion: TRB write-back (HWO=0) at t; XferComplete visible at t+ev_delay; resource released at
     t+rel_delay (a Start in between is refused: the window 0327 fell into)
  A3 Start accepted on a TRB whose HWO is 0 -> resource held, nothing moves (alpha zombie)
  Adversarial extras (rates are parameters):
  X1 the event becomes visible BEFORE the write-back (p_ev_first)
  X2 the event is lost (p_lost)
  X3 a duplicate of the event arrives later (p_dup), i.e. a stale event
  X4 at a random time the controller holds a hidden transfer on TX the driver does not know (p_hidden)
  X5 End Transfer takes end_lat; CMDACT stays set meanwhile (GUCTL2[14]); with p_end_stuck it takes 8 ms
  X6 ep0 leaves its SETUP phase now and then (End Transfer deferred meanwhile)
"""
import heapq, random, sys, itertools, statistics as stt

IDLE, STARTED, ENDING = 0, 1, 2

class Ctl:
    """one endpoint of the controller"""
    def __init__(s, name):
        s.name = name; s.active = False; s.zombie = False; s.xid = 0; s.rsc = 7 if name == 'TX' else 6
        s.cmdact_until = -1.0; s.end_pending = None
        s.hwo = False; s.trb_frame = None     # TRB memory: HWO and the frame id it describes
        s.wb_frame = None                     # frame id of the last write-back
        s.release_at = None

class Sim:
    def __init__(s, seed, p):
        s.r = random.Random(seed); s.p = p; s.t = 0.0; s.q = []; s.seq = itertools.count()
        s.c = {'TX': Ctl('TX'), 'RX': Ctl('RX')}
        s.events = []                         # (visible_time, ep, kind)
        # driver state
        s.e = {ep: dict(st=IDLE, rsc=0, rsc_last=0, end_wanted=False, end_cmdact=False, hwo0_at_end=False,
                        evt_seen=False, noevt=0, noevt_since=0.0, end_t0=0.0, ready_at=0.0) for ep in ('TX', 'RX')}
        s.txq = []; s.tx_staged = None; s.next_frame = 0
        s.ep0_setup = True
        s.last_xfer = -1e9
        # accounting
        s.k = dict(start_ok=0, refused=0, timeout=0, end=0, end_deferred=0, end_timeout=0, noevt=0,
                   evt_not_started=0, evt_hwo_set=0, tx_done=0, tx_by_end=0, rx_done=0, rx_by_end=0,
                   qdrop=0, polls=0, trb_write_owned=0, start_while_active=0, ended_hidden=0)
        s.sent = {}                           # frame id -> times the controller put it on the wire
        s.driver_done = set()                 # frames the driver considers sent
        s.rx_delivered = {}                   # rx transfer id -> deliveries
        s.rx_wire = 0                         # frames the host sent and the controller accepted
        s.rx_accepted = set(); s.rx_arm_id = 0
        s.max_stall = 0.0; s.last_progress = 0.0
        s.hidden_injected = 0

    # ---------------- controller ----------------
    def cmdact(s, ep): return s.t < s.c[ep].cmdact_until

    def ctl_start(s, ep):
        c = s.c[ep]
        if c.active:
            s.k['start_while_active'] += 1
            return 1, c.rsc
        c.active = True; c.xid += 1; xid = c.xid
        if not c.hwo:
            c.zombie = True                   # A3
            return 0, c.rsc
        if ep == 'TX':
            d = s.r.uniform(*s.p['xfer'])
        else:
            d = s.r.expovariate(1.0 / s.p['rx_gap'])
        heapq.heappush(s.q, (s.t + d, next(s.seq), ('complete', ep, xid)))
        return 0, c.rsc

    def ctl_complete(s, ep, xid):
        c = s.c[ep]
        if c.xid != xid or not c.active or c.zombie or c.end_pending is not None:
            return
        p = s.p
        c.hwo = False; c.wb_frame = c.trb_frame          # A2 write-back
        if ep == 'TX':
            s.sent[c.trb_frame] = s.sent.get(c.trb_frame, 0) + 1
        else:
            s.rx_wire += 1; s.rx_accepted.add(c.trb_frame)
        ev_t = s.t + s.r.uniform(*p['ev_delay'])
        if s.r.random() < p['p_ev_first']:
            ev_t = s.t - 0.5                              # X1 (visible "before": the driver may read it first)
            c.hwo = True                                  # write-back lands a bit later
            heapq.heappush(s.q, (s.t + s.r.uniform(1, 30), next(s.seq), ('wb', ep, xid)))
        if s.r.random() >= p['p_lost']:
            s.events.append((ev_t, ep, xid))              # X2 otherwise
        if s.r.random() < p['p_dup']:
            s.events.append((ev_t + s.r.uniform(100, 3000), ep, xid))   # X3
        c.release_at = s.t + (s.r.uniform(*p['rel_delay']) if p['late_release'] else s.r.uniform(0, max(0.0, ev_t - s.t)))
        heapq.heappush(s.q, (c.release_at, next(s.seq), ('release', ep, xid)))

    def ctl_wb(s, ep, xid):
        c = s.c[ep]
        if c.xid == xid:
            c.hwo = False

    def ctl_release(s, ep, xid):
        c = s.c[ep]
        if c.xid == xid and c.end_pending is None:
            c.active = False; c.release_at = None

    def ctl_end(s, ep, rsc):
        c = s.c[ep]
        lat = s.r.uniform(*s.p['end_lat'])
        if s.r.random() < s.p['p_end_stuck']:
            lat = 8000.0
        c.cmdact_until = s.t + lat
        if c.active and rsc == c.rsc:
            c.end_pending = s.t + lat
            heapq.heappush(s.q, (s.t + lat, next(s.seq), ('end_done', ep, c.xid)))
            return 0
        return 0 if c.active else 0       # End with nothing active completes (status not modelled)

    def ctl_end_done(s, ep, xid):
        c = s.c[ep]
        if c.zombie and c.xid == 0:
            s.k['ended_hidden'] += 1
        c.active = False; c.zombie = False; c.end_pending = None; c.release_at = None
        c.xid += 1                         # a completion scheduled for the ended transfer never happens

    def inject_hidden(s):
        c = s.c['TX']
        if not c.active:
            c.active = True; c.zombie = True; s.hidden_injected += 1

    # ---------------- driver (mirrors the C) ----------------
    def advance(s, dt):
        """time passes inside the driver thread; the controller runs meanwhile"""
        end = s.t + dt
        while s.q and s.q[0][0] <= end:
            t, _, ev = heapq.heappop(s.q)
            s.t = max(s.t, t)
            s.dispatch(ev)
        s.t = end

    def dispatch(s, ev):
        kind = ev[0]
        if kind == 'complete': s.ctl_complete(ev[1], ev[2])
        elif kind == 'wb': s.ctl_wb(ev[1], ev[2])
        elif kind == 'release': s.ctl_release(ev[1], ev[2])
        elif kind == 'end_done': s.ctl_end_done(ev[1], ev[2])
        elif kind == 'tcp': s.tcp()
        elif kind == 'hidden': s.inject_hidden()
        elif kind == 'ep0': s.ep0_toggle()

    def dp_cmd_start(s, ep):
        if s.cmdact(ep):
            return -2, 0
        s.advance(s.p['cmd'])
        return s.ctl_start(ep)

    def dp_start(s, ep):
        e = s.e[ep]; c = s.c[ep]
        if e['st'] != IDLE:
            return -1
        if c.active and not c.zombie and c.release_at is None:
            pass
        # R3 check: is the controller using this TRB right now?
        if c.active and c.end_pending is None and not c.zombie and c.release_at is None:
            s.k['trb_write_owned'] += 1
        c.hwo = True
        if ep == 'RX':
            s.rx_arm_id += 1
        c.trb_frame = s.tx_staged if ep == 'TX' else ('rx', s.rx_arm_id)
        s.advance(s.r.uniform(*s.p['W']))          # TRB write .. DEPCMD write
        r, rsc = s.dp_cmd_start(ep)
        if r == 0:
            e['rsc'] = e['rsc_last'] = rsc; e['st'] = STARTED; e['end_wanted'] = False; e['noevt'] = 0
            s.k['start_ok'] += 1
            return 0
        if r == -2:
            return -1
        s.k['refused'] += 1
        e['rsc'] = rsc or e['rsc_last']
        e['st'] = STARTED; e['end_wanted'] = True; e['noevt'] = 0
        s.dp_end(ep, False)
        return -1

    def dp_end_done(s, ep):
        e = s.e[ep]; c = s.c[ep]
        e['end_cmdact'] = False
        e['hwo0_at_end'] = not c.hwo
        c.hwo = False
        e['rsc'] = 0
        e['ready_at'] = s.t + 1000.0

    def dp_end(s, ep, force):
        e = s.e[ep]
        if e['st'] != STARTED: return
        e['end_wanted'] = True
        if not force and not s.ep0_setup:
            s.k['end_deferred'] += 1; return
        if e['rsc'] == 0:
            e['rsc'] = (s.c[ep].rsc if not s.cmdact(ep) else 0) or e['rsc_last']
        e['end_t0'] = s.t
        if s.cmdact(ep):
            return
        s.ctl_end(ep, e['rsc'])
        s.k['end'] += 1
        e['st'] = ENDING; e['end_wanted'] = False; e['noevt'] = 0
        # spin up to 5 ms on CMDACT
        lim = s.t + 5000.0
        while s.cmdact(ep) and s.t < lim:
            s.advance(min(5.0, lim - s.t))
        if s.cmdact(ep):
            e['end_cmdact'] = True; s.k['end_timeout'] += 1; return
        s.dp_end_done(ep)

    def complete(s, ep):
        if ep == 'TX':
            s.driver_done.add(s.tx_staged); s.tx_staged = None; s.k['tx_done'] += 1
            s.last_xfer = s.t
        else:
            s.k['rx_done'] += 1; s.deliver_rx()

    def deliver_rx(s):
        f = s.c['RX'].wb_frame
        s.rx_delivered[f] = s.rx_delivered.get(f, 0) + 1
        s.last_xfer = s.t

    def ep_event(s, ep):
        e = s.e[ep]; c = s.c[ep]
        e['evt_seen'] = True
        if e['st'] != STARTED:
            s.k['evt_not_started'] += 1; return
        if c.hwo:
            s.k['evt_hwo_set'] += 1; return
        e['st'] = IDLE; e['end_wanted'] = False; e['noevt'] = 0
        s.complete(ep)

    def ended(s, ep):
        e = s.e[ep]
        if not e['hwo0_at_end']: return
        e['hwo0_at_end'] = False
        if ep == 'TX' and s.tx_staged is not None:
            s.driver_done.add(s.tx_staged); s.tx_staged = None; s.k['tx_by_end'] += 1
        elif ep == 'RX':
            s.k['rx_by_end'] += 1; s.deliver_rx()

    def pump(s, now0):
        for ep in ('RX', 'TX'):
            e = s.e[ep]; c = s.c[ep]
            if e['st'] == STARTED and e['end_wanted']:
                s.dp_end(ep, False)
            elif e['st'] == STARTED:
                if not c.hwo and not e['evt_seen']:
                    if e['noevt'] == 0: e['noevt_since'] = now0
                    e['noevt'] += 1
                    if e['noevt'] >= 8 and now0 - e['noevt_since'] >= 2000.0:
                        s.k['noevt'] += 1; s.dp_end(ep, False)
                else:
                    e['noevt'] = 0
            if e['st'] == ENDING:
                if e['end_cmdact']:
                    if not s.cmdact(ep): s.dp_end_done(ep)
                elif now0 >= e['ready_at']:
                    e['st'] = IDLE; s.ended(ep)
            e['evt_seen'] = False
        if s.e['RX']['st'] == IDLE:
            s.dp_start('RX')
        if s.e['TX']['st'] == IDLE:
            if s.tx_staged is None and s.txq:
                s.tx_staged = s.txq.pop(0); s.advance(s.p['copy'])
            if s.tx_staged is not None:
                s.dp_start('TX')

    def poll(s):
        now0 = s.t
        s.k['polls'] += 1
        vis = [x for x in s.events if x[0] <= s.t]
        s.events = [x for x in s.events if x[0] > s.t]
        vis.sort()
        for _, ep, _ in vis:
            s.advance(0.3)
            s.ep_event(ep)
        s.pump(now0)
        # progress watchdog for the liveness metric
        if s.k['tx_done'] + s.k['tx_by_end'] + s.k['rx_done'] + s.k['rx_by_end'] != getattr(s, '_lp', -1):
            s._lp = s.k['tx_done'] + s.k['tx_by_end'] + s.k['rx_done'] + s.k['rx_by_end']
            s.last_progress = s.t
        elif s.txq or s.tx_staged is not None:
            s.max_stall = max(s.max_stall, s.t - s.last_progress)

    def thread(s, until):
        while s.t < until:
            s.poll()
            busy = s.t - s.last_xfer < 10000.0
            if busy:
                lim = s.t + 50.0; more = False
                while s.t < lim:
                    if any(x[0] <= s.t for x in s.events): more = True; break
                    s.advance(1.0)
                if more: continue
                s.advance(125.0 + s.r.uniform(0, s.p['jitter']))
            else:
                s.advance(1000.0 + s.r.uniform(0, s.p['jitter']))

    # ---------------- environment ----------------
    def tcp(s):
        if len(s.txq) < 32:
            s.txq.append(s.next_frame); s.next_frame += 1
        else:
            s.k['qdrop'] += 1
        heapq.heappush(s.q, (s.t + s.r.uniform(*s.p['tcp_gap']), next(s.seq), ('tcp',)))

    def ep0_toggle(s):
        s.ep0_setup = not s.ep0_setup
        d = s.r.uniform(200, 2000) if not s.ep0_setup else s.r.expovariate(1.0 / s.p['ep0_gap'])
        heapq.heappush(s.q, (s.t + d, next(s.seq), ('ep0',)))

def run(seed, p, secs):
    s = Sim(seed, p)
    heapq.heappush(s.q, (0.0, next(s.seq), ('tcp',)))
    heapq.heappush(s.q, (s.r.expovariate(1.0 / p['ep0_gap']), next(s.seq), ('ep0',)))
    if p['p_hidden'] > 0:
        t = 0.0
        while True:
            t += s.r.expovariate(p['p_hidden'] / 1e6)
            if t > secs * 1e6: break
            heapq.heappush(s.q, (t, next(s.seq), ('hidden',)))
    s.thread(secs * 1e6)
    return s

BASE = dict(xfer=(30, 500), W=(1, 4), cmd=3, copy=4, rx_gap=600.0, ev_delay=(0.2, 5), rel_delay=(0.5, 20),
            end_lat=(1, 300), tcp_gap=(20, 80), jitter=100.0, ep0_gap=3e6,
            p_ev_first=0.0, p_lost=0.0, p_dup=0.0, p_hidden=0.0, p_end_stuck=0.0, late_release=False)

SCEN = {
    'nominal':   dict(),
    'ev_first':  dict(p_ev_first=0.02),
    'lost':      dict(p_lost=0.01),
    'dup':       dict(p_dup=0.02),
    'late_rel':  dict(late_release=True),
    'hidden':    dict(p_hidden=2.0),                  # ~2 hidden TX transfers per second
    'end_stuck': dict(p_hidden=2.0, p_end_stuck=0.2),
    'ep0_busy':  dict(p_hidden=2.0, ep0_gap=5000.0),
    'all':       dict(p_ev_first=0.02, p_lost=0.01, p_dup=0.02, p_hidden=2.0, p_end_stuck=0.05, ep0_gap=20000.0,
                      late_release=True),
}

def report(name, rows, secs):
    def m(f): return stt.mean(f(r) for r in rows)
    lost = [len([f for f in r.driver_done if r.sent.get(f, 0) == 0]) for r in rows]
    dup_tx = [sum(1 for f, n in r.sent.items() if n > 1) for r in rows]
    never = [len([f for f in range(r.next_frame) if f not in r.driver_done and f not in r.txq and f != r.tx_staged]) - r.k['qdrop'] * 0 for r in rows]
    rx_dup = [sum(1 for f, n in r.rx_delivered.items() if n > 1) for r in rows]
    # the transfer still armed when the run stops is in flight, not lost
    rx_missing = [len(r.rx_accepted - set(r.rx_delivered) - ({('rx', r.rx_arm_id)} if r.e['RX']['st'] != IDLE else set())) for r in rows]
    print(f"{name:10s} runs={len(rows)} {secs}s  tx/s {m(lambda r: (r.k['tx_done']+r.k['tx_by_end'])/secs):7.0f}"
          f"  rx/s {m(lambda r: (r.k['rx_done']+r.k['rx_by_end'])/secs):5.0f}"
          f"  refused {m(lambda r: r.k['refused']):6.1f} start_while_active {m(lambda r: r.k['start_while_active']):6.1f}"
          f"  noevt {m(lambda r: r.k['noevt']):5.1f} ev_not_started {m(lambda r: r.k['evt_not_started']):5.1f}"
          f" ev_hwo_set {m(lambda r: r.k['evt_hwo_set']):5.1f} end {m(lambda r: r.k['end']):6.1f}"
          f" deferred {m(lambda r: r.k['end_deferred']):5.1f} end_to {m(lambda r: r.k['end_timeout']):4.1f}")
    print(f"{'':10s} R3 violations (TRB written while owned) max {max(r.k['trb_write_owned'] for r in rows)}"
          f" | TX marked done but never on the wire: max {max(lost)} | TX sent twice: mean {stt.mean(dup_tx):.1f}"
          f" | RX delivered twice: max {max(rx_dup)} | RX accepted, not delivered: max {max(rx_missing)}"
          f" | worst stall with backlog {max(r.max_stall for r in rows)/1000:.1f} ms"
          f" | hidden injected {m(lambda r: r.hidden_injected):.1f}")

if __name__ == '__main__':
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0
    which = sys.argv[3:] or list(SCEN)
    for name in which:
        p = dict(BASE); p.update(SCEN[name])
        rows = [run(seed, p, secs) for seed in range(n)]
        report(name, rows, secs)
