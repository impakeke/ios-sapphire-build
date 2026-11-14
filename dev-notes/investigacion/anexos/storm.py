import usbsim, statistics as st
# distribution of frames delivered before the permanent refusal (0327 logic, calibrated parameters)
rows = [usbsim.one(seed, '0327', 20e6) for seed in range(300)]
d = sorted(r.sent for r in rows if r.zombie)
print("n", len(d), "p10", d[len(d)//10], "p25", d[len(d)//4], "p50", d[len(d)//2], "p75", d[3*len(d)//4], "p90", d[9*len(d)//10])
print("fraction with <=200 frames delivered:", sum(1 for x in d if x <= 200)/len(d))
# one run through 200 s of storm
seed = next(r for r in range(300) if 120 <= rows[r].sent <= 220)
s = usbsim.Sim(seed, '0327', usbsim.P)
for g in (s.ud_thread(), s.tcp(), s.rx_source(), s.log_thread(), s.loss_detector()): s.at(0, g)
t = 0.0
while not s.zombie:
    t += 50000.0; s.run(t)
tz = s.zombie_t
before = (s.sent, s.tx_frames, s.fail, s.stale_ev, s.late_rx)
s.run(tz + 200e6)
print("seed", seed, "zombie at %.1f ms; delivered/tx_frames/refused/stale/late_rx before:" % (tz/1000), before)
print("after 200 s more: delivered %d tx_frames %d refused %d ; console bytes produced by refusals %d (= %.1f x 4 MiB ring; ring holds at most %d such lines)" % (
    s.sent, s.tx_frames, s.fail, s.fail*32, s.fail*32/(4<<20), (4<<20)//32))
