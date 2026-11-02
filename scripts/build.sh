#!/usr/bin/env bash
# Builds the compiler of the Arduino IDE for the AVR boards (Arduino UNO, Nano) as WebAssembly, from the original GNU
# sources, with Emscripten: GCC 7.3.0 with Arduino's patch (cc1plus) and GNU binutils 2.42 (as, ld, objcopy).
# The recipe follows https://github.com/ajeetjain94608/avr-toolchain-wasm (GPL-3.0).
#   bash scripts/build.sh [sources|binutils|hostlibs|gcc|install|all]     (Linux, with ~/emsdk)
# Outputs: out/<tool>.mjs + out/<tool>.wasm and out/ldscripts/.
set -euo pipefail

WORK="${AVR_WASM_WORK:-$HOME/avr-wasm}"
OUT="${OUT:-$PWD/out}"
JOBS="${JOBS:-$(nproc)}"
SUMS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/SHA256SUMS"

EMSDK_VERSION=4.0.10
GCC_V=7.3.0
BINUTILS_V=2.42
GMP_V=6.2.1
MPFR_V=4.1.0
MPC_V=1.2.1
ARDUINO_TAG=7.3.0-atmel3.6.1-arduino7
ARDUINO_PATCH=atmel-patches-gcc.7.3.0-arduino2.patch

declare -A URL=(
  [gcc]="https://ftp.gnu.org/gnu/gcc/gcc-$GCC_V/gcc-$GCC_V.tar.xz"
  [binutils]="https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILS_V.tar.xz"
  [gmp]="https://ftp.gnu.org/gnu/gmp/gmp-$GMP_V.tar.xz"
  [mpfr]="https://ftp.gnu.org/gnu/mpfr/mpfr-$MPFR_V.tar.xz"
  [mpc]="https://ftp.gnu.org/gnu/mpc/mpc-$MPC_V.tar.gz"
  [patch]="https://raw.githubusercontent.com/arduino/toolchain-avr/$ARDUINO_TAG/avr-gcc-patches/$ARDUINO_PATCH"
)

# The tools: ES modules that export a factory; the browser makes one instance per step (callMain, then drops it)
EM_LINK="-O2 -sALLOW_MEMORY_GROWTH=1 -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORT_NAME=createTool -sFORCE_FILESYSTEM=1 \
-sINVOKE_RUN=0 -sEXIT_RUNTIME=1 -sENVIRONMENT=web,worker,node -sEXPORTED_RUNTIME_METHODS=FS,callMain -sSTACK_SIZE=8MB"

# shellcheck disable=SC1091
source "$HOME/emsdk/emsdk_env.sh" > /dev/null 2>&1
[[ "$(emcc --version | head -1)" == *"$EMSDK_VERSION"* ]] || { echo "Emscripten $EMSDK_VERSION required"; exit 1; }
mkdir -p "$WORK/src" "$OUT"

# Emscripten's libc has these; libiberty's cross-compile guesses say otherwise and redefines them
export ac_cv_func_psignal=yes ac_cv_func_strsignal=yes

fetch() { # name -> a file in $WORK/src whose SHA-256 is in SHA256SUMS
  local name=$1 file base sum
  file="$WORK/src/$(basename "${URL[$name]}")"; base="$(basename "$file")"
  [[ -f "$file" ]] || wget -q -O "$file" "${URL[$name]}"
  sum="$(sha256sum "$file" | cut -d' ' -f1)"
  grep -q "^$sum  $base\$" "$SUMS" || { echo "CHECKSUM MISMATCH or unknown file: $base ($sum)"; exit 1; }
}

stage_sources() {
  cd "$WORK/src"
  for n in gcc binutils gmp mpfr mpc patch; do fetch "$n"; done
  [[ -d gcc-$GCC_V ]] || { tar xf "gcc-$GCC_V.tar.xz"; (cd "gcc-$GCC_V" && patch -p1 < "../$ARDUINO_PATCH"); }
  [[ -d binutils-$BINUTILS_V ]] || tar xf "binutils-$BINUTILS_V.tar.xz"
  [[ -d gmp-$GMP_V ]] || tar xf "gmp-$GMP_V.tar.xz"
  [[ -d mpfr-$MPFR_V ]] || tar xf "mpfr-$MPFR_V.tar.xz"
  [[ -d mpc-$MPC_V ]] || tar xf "mpc-$MPC_V.tar.gz"
}

stage_binutils() {
  rm -rf "$WORK/build-binutils"; mkdir -p "$WORK/build-binutils"; cd "$WORK/build-binutils"
  # --prefix=/sysroot (like GCC): ld finds its default scripts in /sysroot/avr/lib/ldscripts
  emconfigure "../src/binutils-$BINUTILS_V/configure" --build=x86_64-pc-linux-gnu --host=i686-pc-linux-gnu --target=avr --prefix=/sysroot \
    --disable-nls --disable-werror --disable-gdb --disable-gdbserver --disable-sim --disable-gprof --disable-gprofng \
    --disable-plugins --disable-shared --enable-static --disable-libctf --without-zstd --without-debuginfod \
    CC_FOR_BUILD=gcc CFLAGS="-O2" LDFLAGS="$EM_LINK" > configure.log 2>&1
  emmake make -j"$JOBS" all-gas all-ld all-binutils > make.log 2>&1
}

stage_hostlibs() { # GMP, MPFR, MPC for the WebAssembly host (generic C, no assembly)
  local P="$WORK/hostlibs"; rm -rf "$P" "$WORK/build-gmp" "$WORK/build-mpfr" "$WORK/build-mpc"
  mkdir -p "$WORK/build-gmp" && cd "$WORK/build-gmp"
  emconfigure "../src/gmp-$GMP_V/configure" --host=none --build=x86_64-pc-linux-gnu --disable-assembly --disable-shared --enable-static \
    --prefix="$P" CC_FOR_BUILD=gcc > configure.log 2>&1 && emmake make -j"$JOBS" install > make.log 2>&1
  mkdir -p "$WORK/build-mpfr" && cd "$WORK/build-mpfr"
  emconfigure "../src/mpfr-$MPFR_V/configure" --host=none --build=x86_64-pc-linux-gnu --disable-shared --enable-static \
    --with-gmp="$P" --prefix="$P" > configure.log 2>&1 && emmake make -j"$JOBS" install > make.log 2>&1
  mkdir -p "$WORK/build-mpc" && cd "$WORK/build-mpc"
  emconfigure "../src/mpc-$MPC_V/configure" --host=none --build=x86_64-pc-linux-gnu --disable-shared --enable-static \
    --with-gmp="$P" --with-mpfr="$P" --prefix="$P" > configure.log 2>&1 && emmake make -j"$JOBS" install > make.log 2>&1
}

stage_gcc() { # only cc1plus: the browser runs the compiler proper, as and ld itself (no gcc driver)
  local P="$WORK/hostlibs"; mkdir -p "$WORK/build-gcc"; cd "$WORK/build-gcc"
  # The configuration of Arduino's avr-gcc 7.3.0-atmel3.6.1-arduino7 (avr-gcc -v), for a 32-bit host (wasm32 is ILP32
  # like i686). --prefix=/sysroot: where the browser puts the headers and libraries, so the built-in paths resolve.
  [[ -f Makefile ]] || emconfigure "../src/gcc-$GCC_V/configure" --build=x86_64-pc-linux-gnu --host=i686-pc-linux-gnu --target=avr --prefix=/sysroot \
    --enable-fixed-point --enable-languages=c,c++ --disable-nls --disable-libssp --disable-libada --disable-shared \
    --with-avrlibc=yes --with-dwarf2 --disable-doc --disable-plugin --disable-lto --without-isl --disable-bootstrap \
    --with-gmp="$P" --with-mpfr="$P" --with-mpc="$P" \
    CC_FOR_BUILD=gcc CXX_FOR_BUILD=g++ CFLAGS="-O2" CXXFLAGS="-O2 -std=gnu++98 -Wno-register -Wno-deprecated" LDFLAGS="$EM_LINK" > configure.log 2>&1
  # the host (WebAssembly) libraries, and the build machine's own libiberty/libcpp for GCC's generator programs
  emmake make -j"$JOBS" configure-gcc all-libiberty all-libcpp all-libdecnumber all-libbacktrace \
    all-build-libiberty all-build-libcpp all-build-fixincludes > make-libs.log 2>&1
  # GCC's generator programs must be native Linux programs
  emmake make -j"$JOBS" -C gcc cc1plus CC_FOR_BUILD=gcc CXX_FOR_BUILD=g++ CFLAGS_FOR_BUILD="-O2" \
    CXXFLAGS_FOR_BUILD="-O2 -std=gnu++11" LDFLAGS_FOR_BUILD="" ZLIB="-sUSE_ZLIB=1" > make-cc1plus.log 2>&1
}

stage_install() {
  local B="$WORK/build-binutils"
  cp "$WORK/build-gcc/gcc/cc1plus" "$OUT/cc1plus.mjs"; cp "$WORK/build-gcc/gcc/cc1plus.wasm" "$OUT/cc1plus.wasm"
  cp "$B/gas/as-new" "$OUT/as.mjs";              cp "$B/gas/as-new.wasm" "$OUT/as.wasm"
  cp "$B/ld/ld-new" "$OUT/ld.mjs";               cp "$B/ld/ld-new.wasm" "$OUT/ld.wasm"
  cp "$B/binutils/objcopy" "$OUT/objcopy.mjs";   cp "$B/binutils/objcopy.wasm" "$OUT/objcopy.wasm"
  mkdir -p "$OUT/ldscripts"; cp "$B"/ld/ldscripts/avr5.* "$OUT/ldscripts/"
  ls -la "$OUT"
}

for s in "${@:-all}"; do
  case "$s" in
    all) stage_sources; stage_binutils; stage_hostlibs; stage_gcc; stage_install ;;
    sources|binutils|hostlibs|gcc|install) "stage_$s" ;;
    *) echo "unknown stage $s"; exit 1 ;;
  esac
done
