#!/bin/bash
# HakiosMetal.bundle for sapphire (Adreno 610) from source, from nothing: the toolchain, the SDK, Mesa, the driver.
# macOS x86_64 or arm64; on Linux the same steps with the distribution's clang-18/lld-18 (see the report, section 6).
#
#   receta.sh              everything, into this directory; what is already there is left alone
#   SRC_KIND=propio        (default) upstream oosexgang/hakios-xnu-kernel at 63fc2b4 + patches/a610/*.patch
#   SRC_KIND=opcional      ... + patches/opcional/*.patch (metal.args, hakios_metal_cb_wait_scheduled)
#   SRC_KIND=angel         Angelpro09xd/hakios-xnu-kernel sapphire-a610 (bd4c247): what the binary 13bbd782 was built from
#
# Dependencies it fetches (versions pinned):
#   clang, clang++, ld64.lld, llvm-ar 18.1.8      conda-forge (micromamba), osx-64 or osx-arm64
#   bison 3.8, flex 2.6, m4                       conda-forge (macOS's own bison 2.3 cannot read Mesa's grammars)
#   iPhoneOS16.5.sdk                              github.com/theos/sdks at 0222fd5 (SDKSettings: iOS 16.4)
#   Mesa 25.0.7                                   archive.mesa3d.org, sha256 592272df...f8a6
#   meson 1.6.1, mako, pyyaml, packaging          a Python 3.12 venv (uv)
# Needs on the machine: git, curl, make, ninja, uv, python3, shasum; codesign (macOS) or ldid (Linux) to sign.
set -euo pipefail
R=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$R"
SRC_KIND=${SRC_KIND:-propio}
PLAT=osx-64
[ "$(uname -m)" = arm64 ] && PLAT=osx-arm64

# 1. the compiler and the linker: LLVM 18.1.8 (the binary's LC_BUILD_VERSION names LLD 18.1.8)
if [ ! -x llvm18/bin/clang ]; then
	mkdir -p tools
	[ -x tools/micromamba ] || { curl -sL --fail -o tools/micromamba \
		https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-$PLAT; chmod +x tools/micromamba; }
	export MAMBA_ROOT_PREFIX=$R/mamba-root
	tools/micromamba create -y -q -p "$R/llvm18" -c conda-forge --override-channels --platform $PLAT \
		clang=18.1.8 clangxx=18.1.8 lld=18.1.8 llvm-tools=18.1.8
	tools/micromamba create -y -q -p "$R/hosttools" -c conda-forge --override-channels --platform $PLAT bison flex m4
	# conda's own libc++ headers would take the SDK's place (clang prefers <prefix>/include/c++/v1): the binary was built
	# against the SDK's libc++ 15 (its symbols carry the ABI tag v15006)
	[ -d llvm18/include/c++ ] && mv llvm18/include/c++ llvm18/include/c++.conda-libcxx-apartado
fi

# 2. the SDK: theos's iPhoneOS16.5.sdk (the binary's LC_BUILD_VERSION says sdk 16.4, which is this SDK's own version)
if [ ! -d theos-sdks/iPhoneOS16.5.sdk/usr/include ]; then
	git clone -q --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git theos-sdks
	git -C theos-sdks sparse-checkout set iPhoneOS16.5.sdk
fi

# 3. the source tree
case "$SRC_KIND" in
angel)
	SRC=$R/hakios-angel
	[ -d "$SRC" ] || { git clone -q https://github.com/Angelpro09xd/hakios-xnu-kernel "$SRC"; git -C "$SRC" checkout -q bd4c247; } ;;
propio|opcional)
	SRC=$R/hakios-upstream
	if [ ! -d "$SRC" ]; then
		git clone -q https://github.com/oosexgang/hakios-xnu-kernel "$SRC"
		git -C "$SRC" checkout -q -b sapphire-a610-propio 63fc2b4633bac3af8e57dadab9f5a8d4cb940438
		git -C "$SRC" -c user.name=ios-sapphire -c user.email=research@localhost am -q "$R"/patches/a610/*.patch
		if [ "$SRC_KIND" = opcional ]; then
			git -C "$SRC" checkout -q -b opcional-puerto
			git -C "$SRC" -c user.name=ios-sapphire -c user.email=research@localhost am -q "$R"/patches/opcional/*.patch
		fi
	fi ;;
*) echo "receta.sh: SRC_KIND=$SRC_KIND?"; exit 1 ;;
esac

# 4. Mesa's compiler archives (full LTO, -O3, -mcpu=cortex-a73: what the binary's Mesa part shows), with the patches
#    and the AIR front end of the tree being built
[ -f mesa/build-lto-O3-a73/src/compiler/air/libair.a ] || PATCHDIR=$SRC/tools/mesa BUILD=build-lto-O3-a73 ./build-mesa.sh
ln -sfn build-lto-O3-a73 mesa/build-softpipe-freedreno

# 5. the driver's core, the plug-in, the link and the signature
case "$SRC_KIND" in
angel)    SRC=$SRC ./build-bundle.sh "$R/out/angel-src" ;;
propio)   SRC=$SRC IOS_EXTRA="-g" ./build-bundle.sh "$R/out/propio" ;;
opcional) SRC=$SRC IOS_EXTRA="-g" ./build-bundle.sh "$R/out/propio-args" ;;
esac
