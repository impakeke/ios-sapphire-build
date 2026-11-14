#!/usr/bin/env python3
"""Imprime los boot-args de XNU de una imagen boot_a de sapphire (shim + payload SWEETXNU).

El cmdline del header ANDROID! (normalmente "console=null") es del ABL y no le
llega a XNU. Los boot-args reales van en el payload SWEETXNU (tools/mkpayload.py:
cmdline en +0x48, 608 bytes). Si no hay un header SWEETXNU legible (p. ej. un
payload comprimido), se busca por heurística una línea con "rd=" o "sweet".

Uso: python3 dev-notes/bootargs.py boot_a.img [--diff otra.img]
"""
import re
import sys

CMDLINE_OFF, CMDLINE_LEN = 0x48, 608


def bootargs(path):
    d = open(path, 'rb').read()
    for m in re.finditer(rb'SWEETXNU', d):
        raw = d[m.start() + CMDLINE_OFF:m.start() + CMDLINE_OFF + CMDLINE_LEN].split(b'\0')[0]
        if raw and all(32 <= c < 127 for c in raw) and b'=' in raw:
            return raw.decode(), f'SWEETXNU@{m.start():#x}'
    for m in re.finditer(rb'[ -~]{40,700}', d):
        s = m.group(0)
        if (b'rd=' in s or b'sweet' in s) and b'keepsyms' in s:
            return s.decode(), f'heuristica@{m.start():#x}'
    return None, 'no encontrado'


def as_dict(line):
    out = {}
    for tok in line.split():
        k, _, v = tok.partition('=')
        out[k] = v if _ else True
    return out


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    a, where = bootargs(sys.argv[1])
    print(f'{sys.argv[1]} [{where}]\n  {a}')
    if a:
        da = as_dict(a)
        print(f'  sweetusb={da.get("sweetusb", "(AUSENTE: sin gadget USB)")}  sweetlog={da.get("sweetlog", "(default 1)")}')
    if len(sys.argv) == 4 and sys.argv[2] == '--diff':
        b, where_b = bootargs(sys.argv[3])
        print(f'{sys.argv[3]} [{where_b}]\n  {b}')
        if a and b:
            da, db = as_dict(a), as_dict(b)
            for k in sorted(set(da) | set(db)):
                if da.get(k) != db.get(k):
                    print(f'  {k:24} {str(da.get(k, "-")):20} | {db.get(k, "-")}')
