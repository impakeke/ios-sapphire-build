#!/usr/bin/env python3
"""symb.py psamp.txt bundle: perfil por imagen y por función (self/total) de las muestras de psamp."""
import sys, subprocess, bisect, collections
f, bundle = sys.argv[1], sys.argv[2]
imgs = []; samples = []; cache = 0
for l in open(f):
    p = l.split()
    if p[0] == 'I': imgs.append((int(p[1], 16), p[2] if len(p) > 2 else '?'))
    elif p[0] == 'C': cache = int(p[1], 16)
    elif p[0] == 'S': samples.append([int(x, 16) for x in p[2:]])
imgs.sort(); bases = [b for b, _ in imgs]
hb = next(b for b, n in imgs if 'HakiosMetal' in n)
syms = []
for l in subprocess.run(['nm', '-n', bundle], capture_output=True, text=True).stdout.splitlines():
    p = l.split(None, 2)
    if len(p) == 3 and p[1] in 'tT': syms.append((int(p[0], 16), p[2]))
dem = subprocess.run(['c++filt'], input='\n'.join(s for _, s in syms), capture_output=True, text=True).stdout.splitlines()
syms = [(a, d) for (a, _), d in zip(syms, dem)]; saddr = [a for a, _ in syms]
hend = hb + 0x900000
def name(pc):
    if hb <= pc < hend:
        i = bisect.bisect_right(saddr, pc - hb) - 1
        return 'HM:' + (syms[i][1][:110] if i >= 0 else '?')
    if pc >= cache and cache:
        i = bisect.bisect_right(bases, pc) - 1
        return 'SC:' + imgs[i][1].split('/')[-1] + ('+%x' % ((pc - imgs[i][0]) & ~0x3f) if len(sys.argv) > 3 else '')
    i = bisect.bisect_right(bases, pc) - 1
    return 'IM:' + (imgs[i][1].split('/')[-1] if i >= 0 else '?')
def img(pc): n = name(pc); return 'HakiosMetal' if n.startswith('HM:') else n[3:].split('+')[0]
busy = [s for s in samples if s and not any(img(pc) == 'libsystem_kernel.dylib' for pc in s[:1])]
kern = collections.Counter()
for s in samples:
    if s and img(s[0]) == 'libsystem_kernel.dylib':
        # primer marco fuera de libsystem_kernel
        for pc in s[1:]:
            if img(pc) != 'libsystem_kernel.dylib': kern[name(pc - 4)] += 1; break
print('muestras %d, en usuario %d (%.1f%%), en trap/kernel %d' % (len(samples), len(busy), 100 * len(busy) / len(samples), len(samples) - len(busy)))
print('\n== llamadas al kernel (primer marco de usuario), % de todas las muestras')
for k, v in kern.most_common(14): print('%6.2f%%  %s' % (100 * v / len(samples), k))
N = len(busy)
ci = collections.Counter(img(s[0]) for s in busy)
print('\n== imagen (self), % del tiempo de usuario')
for k, v in ci.most_common(12): print('%6.2f%%  %s' % (100 * v / N, k))
self_ = collections.Counter(name(s[0]) for s in busy)
print('\n== self')
for k, v in self_.most_common(40): print('%6.2f%%  %s' % (100 * v / N, k))
tot = collections.Counter()
for s in busy:
    for n in set(name(pc - 4) for pc in s[1:]) | {name(s[0])}:
        if n.startswith('HM:'): tot[n] += 1
print('\n== total (inclusive), solo HakiosMetal')
for k, v in tot.most_common(60): print('%6.2f%%  %s' % (100 * v / N, k))
# quién llama a malloc/memmove/memset
for target in ('libsystem_malloc.dylib', 'libsystem_platform.dylib'):
    who = collections.Counter()
    for s in busy:
        if img(s[0]) == target:
            for pc in s[1:]:
                if img(pc - 4) not in (target, 'libc++abi.dylib', 'libc++.1.dylib', 'libsystem_c.dylib'): who[name(pc - 4)] += 1; break
    print('\n== quien llama a %s' % target)
    for k, v in who.most_common(15): print('%6.2f%%  %s' % (100 * v / N, k))
