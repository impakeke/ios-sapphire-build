#!/bin/bash
# HakiosMetal.bundle from source: the plug-in (userland/src/HakiosMetalCA.m) over libhakios-metal.a (make ios MESA=1,
# -DHAKIOS_CHIP_A610) and Mesa 25.0.7's compiler archives, as userland/build.sh METAL_PLUGIN=ca links them.
#
#   build-bundle.sh [OUTDIR]      (default out/bundle)
#   SRC=<tree>                    the hakios-xnu-kernel tree to build (default hakios-angel: Angel's sapphire-a610)
#   PLUGIN_OPT=-O1                the plug-in's optimisation level
#   CORE=0                        do not rebuild libhakios-metal.a
#   IOS_EXTRA="-g -O3 ..."        more flags for the core's objects (our series' Makefile only)
#   PLUGIN_EXTRA="..."            more flags for the plug-in
#   PLUGIN_SRC=<file>             another HakiosMetalCA.m than SRC's own
#   CACHE_BUILD=<string>          the compiled-stage cache's key (default: the Makefile's hash of the compiler)
set -euo pipefail
R=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$R/env.sh"
OUT=${1:-$R/out/bundle}
SRC=${SRC:-$HAKIOS}
HM=$SRC/hakios-metal
MB=$MESA_B/build-softpipe-freedreno
PLUGIN_OPT=${PLUGIN_OPT:--O1}
TARGET=(-target arm64-apple-ios16.0 -isysroot "$SDK")
mkdir -p "$OUT"

# 1. the driver's core: 12 objects into out/ios/libhakios-metal.a (hakios-metal/Makefile's own rule)
if [ "${CORE:-1}" != 0 ]; then
	extra=()
	[ -n "${CACHE_BUILD:-}" ] && extra+=("IOS_CACHE_BUILD=$CACHE_BUILD")
	[ -n "${IOS_EXTRA:-}" ] && extra+=("IOS_EXTRA=$IOS_EXTRA")
	rm -rf "$HM/out/ios"
	if grep -q 'ifeq ($(CHIP),a610)' "$HM/Makefile"; then
		# our series on upstream: the chip and the kernel's service are the Makefile's own switches
		make -C "$HM" ios MESA=1 HAKIOS="$SRC" SDK="$SDK" IOS_MESA_ROOT="$MESA_B" CHIP=a610 GPU_SERVICE=SapphireGPU \
			IOS_CXX="$LLVM/clang++ ${TARGET[*]}" IOS_AR="$LLVM/llvm-ar --format=darwin rcs" ${extra[@]+"${extra[@]}"}
	else
		# Angel's tree: nothing in it defines HAKIOS_CHIP_A610, so it rides on the compiler's name
		make -C "$HM" ios MESA=1 HAKIOS="$SRC" SDK="$SDK" IOS_MESA_ROOT="$MESA_B" \
			IOS_CXX="$LLVM/clang++ ${TARGET[*]} -DHAKIOS_CHIP_A610" IOS_AR="$LLVM/llvm-ar --format=darwin rcs" ${extra[@]+"${extra[@]}"}
	fi
fi

# 2. the plug-in and the link, in one clang run as the original (its object is a temporary: the binary's OSO stab)
MESA_LIBS=()
for a in src/compiler/air/libair.a src/freedreno/ir3/libfreedreno_ir3.a src/freedreno/isa/libir3encode.a \
    src/freedreno/isa/libir3decode.a src/compiler/isaspec/libisaspec.a src/compiler/nir/libnir.a \
    src/compiler/libcompiler.a src/freedreno/fdl/libfreedreno_layout.a \
    src/freedreno/common/libfreedreno_common.a src/util/libmesa_util.a src/util/libmesa_util_sse41.a \
    src/util/blake3/libblake3.a src/c11/impl/libmesa_util_c11.a; do
	MESA_LIBS+=("$MB/$a")
done
# the five symbols of UniXNU's Metal on Vulkan (M2V=1 links them in; without it they stay weak and looked up at run time)
WEAK=()
for s in open first_problem status formats variant_hook; do WEAK+=("-Wl,-U,_native_bridge_metal_$s"); done
"$LLVM/clang" "${TARGET[@]}" -fuse-ld=lld $PLUGIN_OPT -g ${PLUGIN_EXTRA:-} -bundle \
	-framework Foundation -framework CoreFoundation -lobjc -framework IOKit -framework IOSurface -framework Metal \
	-DHAKIOS_METAL_GPU -I"$HM/include" -o "$OUT/HakiosMetal" "${PLUGIN_SRC:-$SRC/userland/src/HakiosMetalCA.m}" \
	"$HM/out/ios/libhakios-metal.a" -lc++ "${MESA_LIBS[@]}" -lz -lm "${WEAK[@]}"
cp "$SRC/userland/src/HakiosMetal.plist" "$OUT/Info.plist"
rm -rf "$OUT/HakiosMetal.dSYM"
# 3. an ad-hoc signature (ld64.lld signs by itself only for macOS and the simulators), of the Mach-O alone: signed in a
#    directory of its own so that codesign does not take the directory for a bundle and seal Info.plist into it, with
#    the original's identifier and 4 KB pages. On Linux: ldid -S, or -Wl,-adhoc_codesign on the link line.
if command -v codesign > /dev/null; then
	T=$(mktemp -d)
	cp "$OUT/HakiosMetal" "$T/HakiosMetal"
	codesign -f -s - -i HakiosMetal --pagesize 4096 "$T/HakiosMetal" 2> /dev/null || codesign -f -s - -i HakiosMetal "$T/HakiosMetal"
	codesign -v "$T/HakiosMetal"
	cp "$T/HakiosMetal" "$OUT/HakiosMetal"
	rm -rf "$T"
fi
ls -l "$OUT/HakiosMetal"
shasum -a 256 "$OUT/HakiosMetal"
