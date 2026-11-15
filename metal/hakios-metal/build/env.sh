# source this: the rebuild's toolchain (clang/lld 18.1.8 from conda-forge, the theos iPhoneOS16.5 SDK)
R=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
export R
export LLVM=$R/llvm18/bin
export SDK=$R/theos-sdks/iPhoneOS16.5.sdk
export HAKIOS=$R/hakios-angel
export MESA_B=$R/mesa
export PATH=$R/bin:$MESA_B/venv/bin:$R/hosttools/bin:$LLVM:$PATH
