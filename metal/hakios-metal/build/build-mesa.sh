#!/bin/bash
# Mesa 25.0.7's compiler archives for arm64 iOS, as hakios-xnu-kernel's tools/mk-mesa.sh builds them (same patches,
# same meson options), with what the binary 13bbd782 shows of its own build: full LTO (bitcode archives) and
# -mcpu=cortex-a73. Only the 13 static archives the Metal driver links are built, not libOSMesa.
#
#   build-mesa.sh                 into mesa/build-softpipe-freedreno (the name tools/compiler.mk expects)
#   EXTRA_C="-mcpu=cortex-a73"    flags added to the C and C++ compilers of the cross file
#   LTO=true|false                meson's b_lto
#   OPT=3                         meson's optimization level (with buildtype release: 3)
#   BUILD=<dir name>              another build directory under mesa/
set -euo pipefail
R=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$R/env.sh"
VERSION=25.0.7
SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
EXTRA_C=${EXTRA_C--mcpu=cortex-a73}
LTO=${LTO:-true}
OPT=${OPT:-3}
BUILD=${BUILD:-build-softpipe-freedreno}
PATCHDIR=${PATCHDIR:-$HAKIOS/tools/mesa}
mkdir -p "$MESA_B" "$R/dl"
cd "$MESA_B"
if [ ! -d mesa-$VERSION ]; then
	[ -f "$R/dl/mesa-$VERSION.tar.xz" ] || curl -sL --fail -o "$R/dl/mesa-$VERSION.tar.xz" https://archive.mesa3d.org/mesa-$VERSION.tar.xz
	echo "$SHA256  $R/dl/mesa-$VERSION.tar.xz" | shasum -a 256 -c - > /dev/null
	tar xJf "$R/dl/mesa-$VERSION.tar.xz"
	for p in "$PATCHDIR"/*.patch; do patch -s --no-backup-if-mismatch -d mesa-$VERSION -p1 < "$p"; done
	cat "$PATCHDIR"/*.patch | shasum -a 256 | cut -d' ' -f1 > mesa-$VERSION/.hakios-patches
fi
# the two directories kept in the repository: always the current ones
rm -rf mesa-$VERSION/src/hakios-drm mesa-$VERSION/src/compiler/air
cp -r "$PATCHDIR/hakios-drm" mesa-$VERSION/src/hakios-drm
cp -r "$PATCHDIR/air" mesa-$VERSION/src/compiler/air
if [ ! -x venv/bin/meson ]; then
	uv venv --python 3.12 venv
	VIRTUAL_ENV=$PWD/venv uv pip install -q mako pyyaml packaging meson==1.6.1
fi
extra=""
for f in $EXTRA_C; do extra="$extra, '$f'"; done
cat > cross-$BUILD.ini <<INI
[binaries]
c = ['$LLVM/clang', '-target', 'arm64-apple-ios16.0', '-isysroot', '$SDK'$extra]
cpp = ['$LLVM/clang++', '-target', 'arm64-apple-ios16.0', '-isysroot', '$SDK', '-fuse-cxa-atexit'$extra]
objc = ['$LLVM/clang', '-target', 'arm64-apple-ios16.0', '-isysroot', '$SDK'$extra]
ar = '$LLVM/llvm-ar'
ranlib = '$LLVM/llvm-ranlib'
strip = '$LLVM/llvm-strip'
pkg-config = 'false'

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[built-in options]
c_link_args = ['-fuse-ld=lld']
cpp_link_args = ['-fuse-ld=lld']
objc_link_args = ['-fuse-ld=lld']

[properties]
needs_exe_wrapper = true
INI
[ -f $BUILD/build.ninja ] || meson setup $BUILD mesa-$VERSION --cross-file cross-$BUILD.ini --wrap-mode=nofallback \
	--prefix=/redwood --libdir=lib --buildtype=release -Doptimization=$OPT -Db_ndebug=true -Db_lto=$LTO \
	-Dplatforms= -Dgallium-drivers=softpipe,freedreno -Dfreedreno-kmds=msm -Dvulkan-drivers= -Dglx=disabled -Degl=disabled -Dgbm=disabled \
	-Dosmesa=true -Dllvm=disabled -Dshared-glapi=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true \
	-Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled -Dshader-cache=disabled -Dvalgrind=disabled \
	-Dlibunwind=disabled -Dglvnd=disabled -Dvideo-codecs= -Dtools= -Dgallium-vdpau=disabled -Dgallium-va=disabled \
	-Dgallium-xa=disabled -Dlmsensors=disabled -Dbuild-tests=false > meson-setup-$BUILD.log 2>&1
ninja -C $BUILD src/compiler/air/libair.a src/freedreno/ir3/libfreedreno_ir3.a src/freedreno/isa/libir3encode.a \
	src/freedreno/isa/libir3decode.a src/compiler/isaspec/libisaspec.a src/compiler/nir/libnir.a src/compiler/libcompiler.a \
	src/freedreno/fdl/libfreedreno_layout.a src/freedreno/common/libfreedreno_common.a src/util/libmesa_util.a \
	src/util/libmesa_util_sse41.a src/util/blake3/libblake3.a src/c11/impl/libmesa_util_c11.a > ninja-$BUILD.log 2>&1
echo "build-mesa.sh: $MESA_B/$BUILD (LTO=$LTO, -O$OPT, $EXTRA_C)"
