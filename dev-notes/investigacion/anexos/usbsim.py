#!/usr/bin/env python3
"""
Discrete-event model of sweet_usb.c's bulk-IN (TX) path against a DWC3-like endpoint.
Purpose: consistency check of the audit's reconstruction, NOT a proof about the hardware.

Driver logic modelled line by line from sweet_usb.c (as patched through 0328):
  ud_tx_kick_locked (667-691), ud_start_trb (291-314), ud_event TX/RX (881-893),
  ud_reclaim_fast (1054-1076), ud_thread loop (1078-1105), ud_if_output (694-710),
  ud_log_thread (1117-1153).
Controller model (assumptions, see report):
  A1 one transfer resource per endpoint; Start Transfer while active -> status 1 (No Resource)
  A2 on completion: TRB written back (HWO=0), XferComplete event queued, resource released
  A3 Start Transfer accepted on a TRB whose HWO is 0 -> resource allocated, nothing moves
     ("zombie", needs Update/End Transfer)  <-- hypothesis alpha
Timing assumptions are parameters (microseconds).
"""
import heapq, random, sys, itertools

class Sim:
    def __init__(self, seed, mode, p):
        self.rng = random.Random(seed); self.mode = mode; self.p = p
        self.t = 0.0; self.q = []; self.seq = itertools.count()
        # controller
        self.active = False; self.zombie = False; self.hwo = False; self.ev = []
        self.xfer_id = 0
        # driver
        self.tx_busy = False; self.txq = 0; self.tx_frames = 0; self.sent = 0
        self.fail = 0; self.stale_ev = 0; self.late_rx = 0; self.corrupt = 0
        self.log_pending = 0; self.lock_busy = False; self.lock_wait = []
        self.zombie_t = None; self.first_fail_t = None; self.fail_at_zombie = None
        self.rx_armed = True; self.rx_backlog = 0.0; self.last_tx_trb_write = -1.0
        self.offered = 0; self.acked = 0; self.lost_known = 0; self.tcp_lost = 0
        self.started = False        # corrected-design flag
        self.pending_frame = False  # corrected design: frame kept after refused start
        self.stop = False
    def at(self, dt, gen): heapq.heappush(self.q, (self.t + dt, next(self.seq), gen))
    def run(self, until):
        while self.q and not self.stop:
            if self.q[0][0] > until: break
            t, _, g = heapq.heappop(self.q)
            self.t = t
            try:
                r = next(g)
            except StopIteration:
                continue
            if r == 'lock':
                if self.lock_busy: self.lock_wait.append(g)
                else:
                    self.lock_busy = True; self.at(0, g)
            else:
                self.at(r, g)
    def unlock(self):
        if self.lock_wait:
            g = self.lock_wait.pop(0); self.at(0, g)     # hand-off
        else:
            self.lock_busy = False
    # ---- controller ----
    def ctl_complete(self, xid):
        yield 0
        if self.xfer_id != xid or not self.active or self.zombie: return
        self.hwo = False                 # A2: write-back
        self.ev.append('TX')             # A2: event
        self.active = False              # A2: resource released
        self.sent += 1
        self.rx_backlog += 0.5           # host ACKs every other segment
    def ctl_start(self):
        if self.active: return 1         # A1
        self.active = True
        self.xfer_id += 1
        if not self.hwo:                 # A3
            self.zombie = True
            if self.zombie_t is None:
                self.zombie_t = self.t; self.fail_at_zombie = self.fail
            return 0
        d = self.rng.uniform(*self.p['xfer'])
        self.at(d, self.ctl_complete(self.xfer_id))
        return 0
    # ---- driver ----
    def kick(self):
        """ud_tx_kick_locked + ud_start_trb; caller holds the lock. Generator."""
        p = self.p
        if self.mode == 'fixed':
            # corrected rule: hardware is touched only when the endpoint is not started
            while not self.started and (self.pending_frame or self.txq > 0):
                if not self.pending_frame:
                    self.txq -= 1; self.pending_frame = True; self.tx_frames += 1
                self.hwo = True; self.last_tx_trb_write = self.t
                yield self.rng.uniform(*p['W'])
                st = self.ctl_start()
                yield p['cmd']
                if st == 0:
                    self.started = True; self.pending_frame = False
                else:
                    self.fail += 1          # frame kept, retried at next poll, no printf
                    break
            return
        while not self.tx_busy and self.txq > 0:
            self.txq -= 1
            if self.active and not self.zombie: self.corrupt += 1   # 678: buffer of the in-flight frame overwritten
            self.tx_busy = True; self.tx_frames += 1                 # 685-686
            self.hwo = True; self.last_tx_trb_write = self.t        # 296-300: TRB rewritten + shared line flushed
            yield self.rng.uniform(*p['W'])                         # 302 + 269-272
            st = self.ctl_start()
            yield p['cmd']                                          # CMDACT poll (blocking delay)
            if st != 0:
                self.tx_busy = False                                # 688
                self.fail += 1; self.tcp_lost += 1
                if self.first_fail_t is None: self.first_fail_t = self.t
                self.log_pending += 32                              # 278: printf -> console ring
                break
    def ud_thread(self):
        p = self.p
        while True:
            n = len(self.ev)                                        # 1083
            batch, self.ev = self.ev[:n], self.ev[n:]
            tx_kicked = False
            for e in batch:                                         # 1086-1093
                if e == 'TX':
                    yield 'lock'
                    if self.mode == 'fixed':
                        if self.started and not self.hwo:
                            self.started = False
                        else:
                            self.stale_ev += 1
                        yield from self.kick()
                    else:
                        if not self.tx_busy or self.hwo: self.stale_ev += 1   # bookkeeping only
                        self.tx_busy = False                        # 890 (unconditional)
                        before = self.tx_frames
                        yield from self.kick()                      # 891
                        pass
                    self.unlock()
                else:   # RX completion, e = ('RX', completion time)
                    late = self.mode != 'fixed' and self.rng.random() < p['p_late']
                    if late:
                        self.late_rx += 1                           # write-back clobbered by a TX TRB flush of the shared line
                        yield p['late_rx']                          # 618-621: 100 x delay(10), blocking
                    else:
                        yield self.rng.uniform(*p['rx'])
                    self.rx_armed = True                            # ud_rx_arm
                    if not late: self.acked = max(self.acked, e[2])
            if self.mode == '0327':                                 # 1096: ud_reclaim_fast
                yield 'lock'
                if self.tx_busy and not self.hwo:                   # 1070
                    self.tx_busy = False                            # 1072
                    yield from self.kick()                          # 1073
                self.unlock()
            if self.mode == 'fixed':
                yield 'lock'; yield from self.kick(); self.unlock()
            yield p['poll'] + self.rng.uniform(0, p['poll_jitter']) # 1103
    def output(self):
        """ud_if_output (694-710). Generator; returns via self._ok."""
        yield 'lock'
        if self.txq >= 32:
            self.unlock(); return
        self.txq += 1
        if self.mode != 'fixed':
            yield from self.kick()
        self.unlock()
    def tcp(self):
        p = self.p
        while True:
            outstanding = self.offered - self.acked - self.lost_known
            if outstanding < p['cwnd'] and self.txq < 32:
                self.offered += 1
                yield from self.output()
            yield self.rng.uniform(*p['tcp_gap'])
    def loss_detector(self):
        # frames the driver dropped are retransmitted by TCP a few ms later
        while True:
            yield self.p['rto']
            self.lost_known = self.tcp_lost
    def rx_source(self):
        while True:
            yield self.rng.uniform(*self.p['ack_delay'])
            if self.rx_armed and self.rx_backlog >= 1.0:
                self.rx_backlog -= 1.0; self.rx_armed = False
                self.ev.append(('RX', self.t, self.sent))   # cumulative ACK
    def log_thread(self):
        p = self.p
        while True:
            yield 100000.0
            while self.log_pending > 0:                             # 1141
                self.log_pending -= min(1400, self.log_pending)
                yield p['log_iter']
                yield from self.output()

P = dict(xfer=(150, 500), W=(3, 6), cmd=30, rx=(30, 80), late_rx=5000, poll=1000, poll_jitter=300,
         cwnd=10, tcp_gap=(20, 60), rto=3000, p_late=0.02, ack_delay=(100, 400), log_iter=40, false_sharing=True)

def one(seed, mode, until_us, p=P, stop_at_zombie=True):
    s = Sim(seed, mode, p)
    for g in (s.ud_thread(), s.tcp(), s.rx_source(), s.log_thread(), s.loss_detector()): s.at(0, g)
    step = 50000.0; t = 0.0
    while t < until_us:
        t += step; s.run(t)
        if stop_at_zombie and s.zombie: break
    return s

if __name__ == '__main__':
    mode = sys.argv[1]; n = int(sys.argv[2]); secs = float(sys.argv[3])
    rows = []
    for seed in range(n):
        s = one(seed, mode, secs * 1e6)
        rows.append(s)
    import statistics as st
    z = [r for r in rows if r.zombie]
    print(f"mode={mode} runs={n} horizon={secs}s")
    print(f"  runs ending in a permanently refused endpoint (zombie): {len(z)}/{n}")
    if z:
        print(f"  frames delivered before it: median {st.median(r.sent for r in z):.0f}  min {min(r.sent for r in z)}  max {max(r.sent for r in z)}")
        print(f"  refused starts before it:   median {st.median(r.fail_at_zombie for r in z):.0f}  min {min(r.fail_at_zombie for r in z)}  max {max(r.fail_at_zombie for r in z)}")
        print(f"  time to it (ms):            median {st.median(r.zombie_t for r in z)/1000:.0f}")
    print(f"  per run averages: delivered {st.mean(r.sent for r in rows):.0f}, tx_frames {st.mean(r.tx_frames for r in rows):.0f}, refused {st.mean(r.fail for r in rows):.1f}, stale events {st.mean(r.stale_ev for r in rows):.1f}, late rx {st.mean(r.late_rx for r in rows):.1f}, in-flight buffer overwrites {st.mean(r.corrupt for r in rows):.1f}")
