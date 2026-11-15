#!/bin/bash
# macOS/zig port of shim/build.sh — Recipe C (zig/clang keeping the upstream flat layout).
# Fixes found vs a naive zig port: keep the arm64 Image header (_head, no GC), no NEON, no jump tables.
set -euo pipefail
cd "$(dirname "$0")"
ZIG="$HOME/sapphire-build/zig-macos-x86_64-0.13.0/zig"
CC="$ZIG cc -target aarch64-freestanding-none"
CFLAGS="-mcpu=generic+el3-neon-fp_armv8 -O2 -g0 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -fno-jump-tables -Wall -Wextra"
mkdir -p out

python3 gen_splash.py splash/splash.png out/splash.bin

for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c splash.c splash_data.S; do
	$CC $CFLAGS -c "$f" -o "out/${f%.*}.o"
done

cat > out/compat.c <<'EOF'
typedef unsigned long size_t;
int strcmp(const char *a,const char *b){while(*a&&*a==(char)*b){a++;b++;}return (unsigned char)*a-(unsigned char)*b;}
int strncmp(const char *a,const char *b,size_t n){while(n&&*a&&*a==(char)*b){a++;b++;n--;}return n?(unsigned char)*a-(unsigned char)*b:0;}
size_t strlen(const char *s){const char *p=s;while(*p)p++;return (size_t)(p-s);}
int memcmp(const void *a,const void *b,size_t n){const unsigned char *x=a,*y=b;for(;n;n--,x++,y++)if(*x!=*y)return *x-*y;return 0;}
EOF
$CC $CFLAGS -c out/compat.c -o out/compat.o

# keep the arm64 Image header (_head) and do NOT gc-sections (else .text.head / the ARM\x64 magic is dropped)
$CC $CFLAGS -static -Wl,-T,shim.ld -Wl,--build-id=none -Wl,-e,_head -Wl,--no-gc-sections \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o out/splash.o out/splash_data.o out/compat.o \
	-o out/shim.elf

$ZIG objcopy -O binary out/shim.elf out/Image

size=$(python3 - out/shim.elf <<'PY'
import struct,sys
f=open(sys.argv[1],'rb').read()
e_shoff=struct.unpack_from('<Q',f,0x28)[0]; e_shentsize=struct.unpack_from('<H',f,0x3a)[0]; e_shnum=struct.unpack_from('<H',f,0x3c)[0]
secs=[struct.unpack_from('<IIQQQQIIQQ',f,e_shoff+i*e_shentsize) for i in range(e_shnum)]
sym=[s for s in secs if s[1]==2][0]; stroff=secs[sym[6]][4]; val=None
for o in range(sym[4],sym[4]+sym[5],sym[9]):
    st_name,st_info,st_other,st_shndx,st_value,st_size=struct.unpack_from('<IBBHQQ',f,o)
    e=f.index(b'\0',stroff+st_name)
    if f[stroff+st_name:e]==b'_end': val=st_value
assert val is not None,'_end not found'
print('%x'%val)
PY
)
size=$((16#$size))
truncate -s "$size" out/Image

if [ -n "${1:-}" ]; then
	truncate -s $(( (size + 0xfff) & ~0xfff )) out/Image
	cat "$1" >> out/Image
	python3 -c 'import os,struct,sys; f=open(sys.argv[1],"r+b"); f.seek(16); f.write(struct.pack("<Q", os.path.getsize(sys.argv[1])))' out/Image
fi

( cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc 2>/dev/null | gzip -9 > ../ramdisk.bin )

python3 "$HOME/sapphire-build/mkbootimg.py" --header_version 4 --kernel out/Image --ramdisk out/ramdisk.bin \
	--os_version 13.0.0 --os_patch_level 2025-01 --cmdline "console=null" -o out/shim-boot.img

echo "=== GATES ==="
python3 - out/Image out/shim.elf <<'PY'
import struct,sys
img=open(sys.argv[1],'rb').read()
magic=img[56:60]
print("gate1 magic@56:", magic.hex(), "->", "OK (ARM\\x64)" if magic==b'ARM\x64' else "FAIL")
isz=struct.unpack_from('<Q',img,16)[0]
print("gate2 image_size@16: 0x%x  filesize: 0x%x  ->"%(isz,len(img)), "OK" if isz==len(img) else "FAIL")
PY
ls -l out/Image out/shim-boot.img
