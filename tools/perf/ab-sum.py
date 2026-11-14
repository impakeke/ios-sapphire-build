#!/usr/bin/env python3
"""ab-sum.py consola.txt...: resume las lineas 'fps:' de HakiosMetal de los periodos con movimiento."""
import re, sys
for f in sys.argv[1:]:
    cb = secs = ont = late = stall = draws = 0; cpu_us = gpu = 0.0; made = []; c2c = []; n = 0
    L = open(f, errors='replace').read().split('\n')
    for i, l in enumerate(L):
        m = re.search(r'frames/s over ([\d.]+) s \((\d+) presented, (\d+) command buffers\); GPU busy (\d+) ms.*commit to completion ([\d.]+) ms', l)
        if not m: continue
        g = re.search(r'(\d+) on time.*?(\d+) a frame late.*?(\d+) stalls.*made to committed ([\d.]+) ms.*?(\d+) draw calls, (\d+) us', L[i + 1] if i + 1 < len(L) else '')
        if not g: continue
        ncb = int(m.group(3))
        if ncb < 30 * float(m.group(1)) / 2: continue      # periodo sin movimiento sostenido (< 15 buffers/s)
        n += 1; secs += float(m.group(1)); cb += ncb; gpu += int(m.group(4)); c2c.append(float(m.group(5)))
        ont += int(g.group(1)); late += int(g.group(2)); stall += int(g.group(3)); made.append(float(g.group(4)))
        draws += int(g.group(5)); cpu_us += int(g.group(5)) * int(g.group(6))
    if not n: print(f, 'sin periodos con movimiento'); continue
    print('%-28s periodos %2d  %5.1f buffers/s  a tiempo %3d / tarde %3d / paradas %3d  draws/buf %5.1f  CPU/draw %3.0f us  hecho->commit %4.1f ms  commit->fin %4.1f ms  GPU %3.0f%%'
          % (f.split('/')[-1], n, cb / secs, ont, late, stall, draws / cb, cpu_us / draws, sum(made) / n, sum(c2c) / n, gpu / secs / 10))
