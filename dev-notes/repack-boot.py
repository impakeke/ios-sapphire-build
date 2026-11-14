#!/usr/bin/env python3
"""Mete un kernel XNU nuevo en una boot_a buena de sapphire, sin tocar nada más.

  repack-boot.py --base BUENA.img --kernel kernel.development.sweet -o nueva.img
                 [--cmdline-file F] [--set clave=valor ...] [--unset clave ...]
                 [--zero-tail] [--extract-kernel K.macho]

Formato (ver tools/mkpayload.py, shim/loader.c, dev-notes/shim-build-mac.sh):

  boot v4: página 0 = header "ANDROID!" (header_size 1584), luego el campo
  kernel (padding a 4K), luego el ramdisk (0x61 bytes, cpio vacío) y nada más
  (signature_size 0, sin footer AVB).
  campo kernel = shim (Image arm64: "ARM\\x64" en +56, image_size u64 en +16
  = tamaño total) truncado en _end y rellenado a 4K + payload SWEETXNU
  (header, segmentos del Mach-O, ADT). loader.c busca el payload justo en
  ALIGN(_end, 4K), así que el shim se reutiliza byte a byte, con su relleno.

Qué se reutiliza de la base: header de la boot (solo cambia kernel_size), shim
completo, ramdisk, ADT (blob idéntico) y, salvo --cmdline-file/--set/--unset,
los boot-args. El payload se arma con tools/mkpayload.build(), igual que el
build normal.

Lo que hay en la base después del ramdisk (hasta ~0x1fec05c) es basura vieja
de la partición (el dump es la partición entera de 128 MiB); el ABL no lo lee.
Por defecto se conserva tal cual para que la ida y vuelta sea idéntica, pero
la zona que ocupaban kernel+ramdisk de la base se pone a cero donde la imagen
nueva no la usa. --zero-tail pone a cero todo lo que sigue al ramdisk.

Autocomprobaciones (cualquier fallo => exit != 0):
  (a) ida y vuelta: base -> Mach-O extraído -> repack con el mismo cmdline
      == base, byte a byte;
  (b) "ARM\\x64" en +56 y image_size == shim + payload; shim, ramdisk, ADT y
      header idénticos a la base salvo kernel_size;
  (c) dev-notes/bootargs.py sobre la salida imprime el cmdline esperado;
  (d) LC_UUID del Mach-O dentro del payload de salida == el del --kernel.
"""
import argparse
import hashlib
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.append(os.path.join(REPO, 'tools'))
import mkpayload  # noqa: E402

PAGE = 4096
BOOT_MAGIC = b'ANDROID!'
V4_HEADER_SIZE = 1584
ARM64_MAGIC = b'ARM\x64'
SWEET = b'SWEETXNU'
CMDLINE_OFF, CMDLINE_LEN = 0x48, 608
SEG_TABLE = 0x2a8
SPLASH_ARG_LEN = len(' sweet_splash=0x') + 16 + 1	# lo que loader.c añade si hay splash
LC_SEGMENT_64, LC_UUID = 0x19, 0x1b


class CheckError(Exception):
	pass


def die(msg):
	print(f'ERROR: {msg}', file=sys.stderr)
	sys.exit(1)


def pg(n):
	return (n + PAGE - 1) & ~(PAGE - 1)


# ---------------------------------------------------------------- boot v4

def parse_boot(img):
	if img[:8] != BOOT_MAGIC:
		raise CheckError('la base no empieza por ANDROID!')
	ksize, rsize, osver, hsize = struct.unpack_from('<4I', img, 8)
	hver, = struct.unpack_from('<I', img, 40)
	sigsize, = struct.unpack_from('<I', img, V4_HEADER_SIZE - 4)
	if hver != 4 or hsize != V4_HEADER_SIZE:
		raise CheckError(f'no es boot v4 (header_version {hver}, header_size {hsize})')
	if sigsize:
		raise CheckError(f'boot_signature_size {sigsize}: no soportado')
	koff = PAGE
	roff = koff + pg(ksize)
	end = roff + pg(rsize)
	if end > len(img):
		raise CheckError('kernel+ramdisk no caben en la imagen base')
	return dict(kernel=img[koff:koff + ksize], ramdisk=img[roff:roff + rsize],
		    kernel_size=ksize, ramdisk_size=rsize, content_end=end,
		    cmdline=img[44:44 + 1536].split(b'\0')[0].decode(errors='replace'))


def build_boot(base, kernel, zero_tail=False):
	"""Imagen v4 = base con kernel_size y bytes del kernel cambiados."""
	b = parse_boot(base)
	out = bytearray(base)
	struct.pack_into('<I', out, 8, len(kernel))
	roff = PAGE + pg(len(kernel))
	end = roff + pg(b['ramdisk_size'])
	if end > len(base):
		raise CheckError(f'la imagen nueva ocupa {end:#x} > partición {len(base):#x}')
	clear_to = len(base) if zero_tail else max(end, b['content_end'])
	out[PAGE:clear_to] = bytes(clear_to - PAGE)
	out[PAGE:PAGE + len(kernel)] = kernel
	out[roff:roff + b['ramdisk_size']] = b['ramdisk']
	return bytes(out)


# ---------------------------------------------------------------- shim + payload

def split_kernel(kblob):
	if kblob[56:60] != ARM64_MAGIC:
		raise CheckError(f'magic en +56 = {kblob[56:60].hex()}, se esperaba ARM\\x64')
	isz, = struct.unpack_from('<Q', kblob, 16)
	if isz != len(kblob):
		raise CheckError(f'image_size {isz:#x} != tamaño del campo kernel {len(kblob):#x}')
	# El shim contiene el literal "SWEETXNU" (loader.c); el payload está en un borde de 4K.
	for off in range(PAGE, len(kblob), PAGE):
		if kblob[off:off + 8] == SWEET and struct.unpack_from('<I', kblob, off + 8)[0] == 1:
			return kblob[:off], kblob[off:]
	raise CheckError('no hay payload SWEETXNU alineado a 4K detrás del shim')


def parse_payload(p):
	if p[:8] != SWEET:
		raise CheckError('payload sin magic SWEETXNU')
	ver, nsegs = struct.unpack_from('<II', p, 8)
	virt_base, entry, adt_off, adt_size, kend, phys_base, mem_size = struct.unpack_from('<7Q', p, 0x10)
	raw_cl = p[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN]
	cmdline = raw_cl.split(b'\0')[0]
	if any(raw_cl[len(cmdline):]):
		raise CheckError('bytes no nulos tras el NUL del cmdline: no se podría reproducir')
	segs = [struct.unpack_from('<4Q', p, SEG_TABLE + 32 * i) for i in range(nsegs)]
	expect_len = adt_off + adt_size + (-(adt_off + adt_size) & 0xf)
	if expect_len != len(p):
		raise CheckError(f'payload mide {len(p):#x}, mkpayload daría {expect_len:#x}')
	return dict(version=ver, nsegs=nsegs, virt_base=virt_base, entry=entry, adt_off=adt_off,
		    adt_size=adt_size, kernel_end=kend, phys_base=phys_base, mem_size=mem_size,
		    cmdline=cmdline.decode(), segs=segs, adt=p[adt_off:adt_off + adt_size])


def macho_cmds(hdr):
	magic, _, _, _, ncmds, _, _, _ = struct.unpack_from('<8I', hdr, 0)
	if magic != 0xfeedfacf:
		raise CheckError('no es un Mach-O de 64 bits')
	off = 32
	for _ in range(ncmds):
		cmd, size = struct.unpack_from('<II', hdr, off)
		yield cmd, off, size
		off += size


def macho_uuid(buf):
	for cmd, off, _ in macho_cmds(buf):
		if cmd == LC_UUID:
			return bytes(buf[off + 8:off + 24])
	return None


def extract_macho(p, info):
	"""Reconstruye el Mach-O (como audit/kern/extract_kernel.py), ya con fixups resueltos."""
	_, _, toff, tsize = info['segs'][0]
	hdr = p[toff:toff + tsize]
	msegs = []
	for cmd, off, _ in macho_cmds(hdr):
		if cmd == LC_SEGMENT_64:
			name = hdr[off + 8:off + 24].split(b'\0')[0].decode()
			msegs.append((name,) + struct.unpack_from('<4Q', hdr, off + 24))
	buf = bytearray(max(fo + fs for _, _, _, fo, fs in msegs))
	used = set()
	for name, vmaddr, vmsize, fileoff, filesize in msegs:
		if not vmsize:		# mkpayload no los copia (p. ej. __CTF): quedan a cero
			continue
		hit = [i for i, s in enumerate(info['segs']) if s[0] == vmaddr and s[1] == vmsize and i not in used]
		if not hit:
			raise CheckError(f'segmento {name} no está en el payload')
		used.add(hit[0])
		_, _, poff, psize = info['segs'][hit[0]]
		if psize != filesize:
			raise CheckError(f'{name}: filesize {filesize:#x} != {psize:#x} en el payload')
		buf[fileoff:fileoff + filesize] = p[poff:poff + psize]
	extra = [i for i in range(info['nsegs']) if i not in used]
	if extra:
		raise CheckError(f'el payload base tiene segmentos que no son del Mach-O (¿--ramdisk?): {extra}')
	return bytes(buf)


def make_payload(kernel_path, adt_blob, cmdline, tmpdir):
	adt_path = os.path.join(tmpdir, 'adt.bin')
	with open(adt_path, 'wb') as f:
		f.write(adt_blob)
	blob, info = mkpayload.build(kernel_path, adt_path, cmdline)
	return blob, info


def assemble_kernel(shim, payload):
	if len(shim) % PAGE:
		raise CheckError('el shim no acaba en borde de 4K')
	k = bytearray(shim + payload)
	struct.pack_into('<Q', k, 16, len(k))	# image_size, como shim-build-mac.sh
	return bytes(k)


# ---------------------------------------------------------------- cmdline

def edit_cmdline(line, sets, unsets):
	toks = line.split()

	def key(t):
		return t.partition('=')[0]
	for k in unsets:
		toks = [t for t in toks if key(t) != k]
	for kv in sets:
		k = key(kv)
		idx = [i for i, t in enumerate(toks) if key(t) == k]
		if idx:
			toks[idx[0]] = kv
			toks = [t for i, t in enumerate(toks) if i not in idx[1:]]
		else:
			toks.append(kv)
	return ' '.join(toks)


def cmdline_dict(line):
	return {t.partition('=')[0]: t.partition('=')[2] if '=' in t else True for t in line.split()}


# ---------------------------------------------------------------- pipeline

def repack(base, kernel_path, cmdline, zero_tail, tmpdir):
	b = parse_boot(base)
	shim, payload = split_kernel(b['kernel'])
	info = parse_payload(payload)
	newp, _ = make_payload(kernel_path, info['adt'], cmdline, tmpdir)
	kernel = assemble_kernel(shim, newp)
	return build_boot(base, kernel, zero_tail)


def check_output(out, base, kernel_path, cmdline, out_path):
	"""(b), (c), (d) más coherencia con la base."""
	b, o = parse_boot(base), parse_boot(out)
	hb, ho = bytearray(base[:PAGE]), bytearray(out[:PAGE])
	struct.pack_into('<I', hb, 8, 0)
	struct.pack_into('<I', ho, 8, 0)
	if hb != ho:
		raise CheckError('header v4 distinto de la base fuera de kernel_size')
	if o['ramdisk'] != b['ramdisk']:
		raise CheckError('ramdisk distinto')
	k = o['kernel']
	# (b)
	if k[56:60] != ARM64_MAGIC:
		raise CheckError('(b) falta ARM\\x64 en +56')
	isz, = struct.unpack_from('<Q', k, 16)
	if isz != len(k):
		raise CheckError(f'(b) image_size {isz:#x} != shim+payload {len(k):#x}')
	shim_b, pay_b = split_kernel(b['kernel'])
	shim_o, pay_o = split_kernel(k)
	if len(shim_o) != len(shim_b) or shim_o[:16] + shim_o[24:] != shim_b[:16] + shim_b[24:]:
		raise CheckError('(b) shim distinto de la base (fuera de image_size)')
	ib, io = parse_payload(pay_b), parse_payload(pay_o)
	if io['adt'] != ib['adt']:
		raise CheckError('ADT distinto de la base')
	if (io['phys_base'], io['mem_size']) != (ib['phys_base'], ib['mem_size']):
		raise CheckError('phys_base/mem_size distintos de la base')
	if io['adt_off'] & 7:
		raise CheckError('adt_off no alineado a 8 (loader.c lo rechaza)')
	if io['cmdline'] != cmdline:
		raise CheckError('cmdline del payload distinto del pedido')
	print(f'  (b) OK  ARM\\x64@56, image_size={isz:#x} == shim {len(shim_o):#x} + payload {len(pay_o):#x}; '
	      'shim/ADT/ramdisk/header iguales a la base')
	# (c)
	r = subprocess.run([sys.executable, os.path.join(HERE, 'bootargs.py'), out_path],
			   capture_output=True, text=True)
	lines = r.stdout.splitlines()
	got = lines[1][2:] if len(lines) > 1 and lines[1].startswith('  ') else None
	if r.returncode or got != cmdline:
		raise CheckError(f'(c) bootargs.py imprime {got!r}\n    se esperaba     {cmdline!r}')
	print(f'  (c) OK  bootargs.py: {lines[0].split()[-1]} cmdline esperado')
	# (d)
	want = macho_uuid(open(kernel_path, 'rb').read())
	_, _, toff, tsize = io['segs'][0]
	got_uuid = macho_uuid(pay_o[toff:toff + tsize])
	if want is None or got_uuid != want:
		raise CheckError(f'(d) LC_UUID salida {got_uuid and got_uuid.hex()} != kernel {want and want.hex()}')
	print(f'  (d) OK  LC_UUID {fmt_uuid(want)}')
	return io


def fmt_uuid(u):
	h = u.hex().upper()
	return f'{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}'


def describe_diff(a, b, limit=20):
	n = min(len(a), len(b))
	diffs = [i for i in range(n) if a[i] != b[i]]
	msg = [f'  {len(diffs)} bytes distintos (tamaños {len(a):#x} / {len(b):#x})']
	for i in diffs[:limit]:
		msg.append(f'    {i:#010x}: base {a[i]:02x} salida {b[i]:02x}')
	return '\n'.join(msg)


def main():
	ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
	ap.add_argument('--base', required=True, help='boot_a buena (solo lectura)')
	ap.add_argument('--kernel', help='Mach-O nuevo (kernel.development.sweet)')
	ap.add_argument('-o', '--out', help='imagen de salida')
	ap.add_argument('--cmdline-file', help='boot-args desde un fichero (en vez de los de la base)')
	ap.add_argument('--set', action='append', default=[], metavar='K=V', help='poner/cambiar un boot-arg (flags con guion: --set=-v)')
	ap.add_argument('--unset', action='append', default=[], metavar='K', help='quitar un boot-arg (flags con guion: --unset=-v)')
	ap.add_argument('--zero-tail', action='store_true', help='poner a cero todo lo que sigue al ramdisk')
	ap.add_argument('--extract-kernel', metavar='OUT', help='solo escribir el Mach-O de la base y salir')
	a = ap.parse_args()

	base = open(a.base, 'rb').read()
	print(f'base   {a.base}\n       sha256 {hashlib.sha256(base).hexdigest()}  {len(base):#x} bytes')
	try:
		b = parse_boot(base)
		shim, payload = split_kernel(b['kernel'])
		info = parse_payload(payload)
		base_macho = extract_macho(payload, info)
	except CheckError as e:
		die(f'base: {e}')
	print(f'       shim {len(shim):#x}, payload {len(payload):#x} ({info["nsegs"]} segs, ADT {info["adt_size"]:#x} '
	      f'@{info["adt_off"]:#x}), ramdisk {b["ramdisk_size"]:#x}, contenido hasta {b["content_end"]:#x}')
	if a.extract_kernel:
		open(a.extract_kernel, 'wb').write(base_macho)
		print(f'Mach-O de la base -> {a.extract_kernel} (UUID {fmt_uuid(macho_uuid(base_macho))})')
		return
	if not (a.kernel and a.out):
		die('hacen falta --kernel y -o')
	if os.path.abspath(a.out) == os.path.abspath(a.base):
		die('-o no puede ser la base')

	cmdline = info['cmdline']
	if a.cmdline_file:
		cmdline = ' '.join(open(a.cmdline_file).read().split())
	cmdline = edit_cmdline(cmdline, a.set, a.unset)
	if len(cmdline.encode()) > CMDLINE_LEN - 1:
		die(f'cmdline de {len(cmdline)} bytes > {CMDLINE_LEN - 1} (mkpayload lo truncaría)')

	with tempfile.TemporaryDirectory(prefix='repack-boot-') as tmp:
		try:
			# (a) ida y vuelta con el kernel sacado de la propia base
			kpath = os.path.join(tmp, 'base.macho')
			open(kpath, 'wb').write(base_macho)
			rt = repack(base, kpath, info['cmdline'], False, tmp)
			if rt != base:
				raise CheckError('(a) la ida y vuelta NO es idéntica:\n' + describe_diff(base, rt))
			print('  (a) OK  ida y vuelta base -> Mach-O -> repack idéntica byte a byte')

			out = repack(base, a.kernel, cmdline, a.zero_tail, tmp)
			part = a.out + '.part'	# solo se renombra a -o si pasan todas las comprobaciones
			with open(part, 'wb') as f:
				f.write(out)
			io = check_output(out, base, a.kernel, cmdline, part)
			os.replace(part, a.out)
		except (CheckError, AssertionError, ValueError, struct.error) as e:
			if os.path.exists(a.out + '.part'):
				os.unlink(a.out + '.part')
			die(f'{type(e).__name__}: {e}')

	if len(cmdline) + SPLASH_ARG_LEN > CMDLINE_LEN:
		print(f'AVISO: cmdline de {len(cmdline)} caracteres > {CMDLINE_LEN - SPLASH_ARG_LEN}: loader.c no tendrá sitio '
		      'para añadir " sweet_splash=0x..." (xnu no pintará la imagen de arranque)', file=sys.stderr)
	before, after = cmdline_dict(info['cmdline']), cmdline_dict(cmdline)
	changed = [k for k in sorted(set(before) | set(after)) if before.get(k) != after.get(k)]
	print('boot-args cambiados: ' + (', '.join(f'{k}: {before.get(k, "-")} -> {after.get(k, "-")}' for k in changed)
				        if changed else 'ninguno'))
	print(f'kernel {a.kernel}\n       entry {io["entry"]:#x}  kernel_end {io["kernel_end"]:#x}  '
	      f'payload {len(out) and parse_boot(out)["kernel_size"] - len(shim):#x}  '
	      f'fin de contenido {parse_boot(out)["content_end"]:#x} / {len(out):#x}')
	print(f'salida {a.out}\nsha256 {hashlib.sha256(out).hexdigest()}')


if __name__ == '__main__':
	main()
