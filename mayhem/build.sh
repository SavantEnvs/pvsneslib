#!/usr/bin/env bash
#
# mayhem/build.sh - build pvsneslib's host-side converter tools for fuzzing and for the oracle.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem, offline and re-runnable.
# The tools are plain CLIs, so upstream's own Makefiles (static, -O2, no sanitizers) are not used:
# every tool is compiled here from the same sources, twice:
#   1. fuzz build   : $SANITIZER_FLAGS + SanCov + DWARF 3, linked with mayhem/cli_wrapper.c
#                     (main renamed to tool_main) -> /mayhem/<tool>
#   2. oracle build : upstream's normal -O2 flags, no sanitizer, dynamically linked, unmodified main
#                     -> mayhem/build/oracle/<tool>   (what mayhem/test.sh runs)
# The SNES-side runtime (pvsneslib/, snes-examples/) and the wla-dx / 816-tcc submodules are not
# host-fuzzable and are not built.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS

cd "$SRC"
MAYHEM="$SRC/mayhem"
FUZZ_OUT="$SRC"
OBJ="$MAYHEM/build/obj"
ORACLE="$MAYHEM/build/oracle"
mkdir -p "$OBJ" "$ORACLE"

VERSION_DEFS=(-D__BUILD_DATE='"20000101"' -D__BUILD_VERSION='"fuzz"')
# clang >= 16 makes these C99 errors; upstream's gcc-built tools rely on them.
LEGACY_C=(-Wno-implicit-function-declaration -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-incompatible-function-pointer-types)
FUZZ_CFLAGS=($SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1 -w)

# $CC/$CXX are looked up by name from PATH; nothing here is located relative to the compiler.
$CC "${FUZZ_CFLAGS[@]}" -c "$MAYHEM/cli_wrapper.c" -o "$OBJ/wrapper_c.o"
$CXX "${FUZZ_CFLAGS[@]}" -DTOOL_ARGV='char **' -c "$MAYHEM/cxx_shim.cc" -o "$OBJ/shim_char.o"
$CXX "${FUZZ_CFLAGS[@]}" -DTOOL_ARGV='const char *const *' -c "$MAYHEM/cxx_shim.cc" -o "$OBJ/shim_cchar.o"
$CC "${FUZZ_CFLAGS[@]}" -DTOOL_MAIN=tool_main_c -c "$MAYHEM/cli_wrapper.c" -o "$OBJ/wrapper_cxx.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$MAYHEM/lsan_off.cc" -o "$OBJ/lsan_off.o"

# Compile one tool's sources object by object so a UBSan check can be relaxed for one file only.
# FILE_RELAX["<basename>"]: extra flags for that source (fuzz build only). Every other source, and
# ASan everywhere, stays fully halting. Each entry fires on every shipped seed of its target:
#   shift-base  smconv/brr.cpp:470-471 and snesbrr/brr/BrrCodec.cpp:183,430-431 left-shift negative
#               16-bit PCM samples (`s1 <<= 1`, `s << range`) in the BRR codec: arithmetic on
#               two's-complement samples, well defined as C++20 and what every compiler does.
#               cute_tiled.h:1661 (in tiled.c) `0xFF << 24` on a constant int for the default alpha;
#               the result is converted straight to uint32_t.
#   null,       cute_tiled.h:3000 (in tiled.c, cute_tiled_free_map) computes offsetof as
#   object-size `&((cute_tiled_map_internal_t*)0)->map`, an address that is never dereferenced; clang
#               instruments it under both checks (object-size sees a 0-byte object at address 0) and both
#               report "member access within null pointer" on every map freed. `alignment` does not fire
#               and stays on. A real NULL or out-of-bounds access in tiled.c still faults under ASan.
declare -A FILE_RELAX=()
FILE_RELAX[brr.cpp]="-fno-sanitize=shift-base"
FILE_RELAX[BrrCodec.cpp]="-fno-sanitize=shift-base"
FILE_RELAX[tiled.c]="-fno-sanitize=null,object-size,shift-base"

# fuzz_objs <name> <compiler> <flags...> -- <sources...>   (prints the object paths)
fuzz_objs() {
  local name="$1" cc="$2"; shift 2
  local flags=() o
  while [ "$1" != "--" ]; do flags+=("$1"); shift; done; shift
  mkdir -p "$OBJ/$name"
  for f in "$@"; do
    o="$OBJ/$name/$(basename "${f%.*}").o"
    $cc "${FUZZ_CFLAGS[@]}" "${VERSION_DEFS[@]}" "${flags[@]}" ${FILE_RELAX[$(basename "$f")]:-} -Dmain=tool_main -c "$f" -o "$o"
    echo "$o"
  done
}

# build_c <name> <extra-cflags> <sources...>
build_c() {
  local name="$1" extra="$2"; shift 2
  local objs
  mapfile -t objs < <(fuzz_objs "$name" "$CC" "${LEGACY_C[@]}" $extra -- "$@")
  $CC "${objs[@]}" "$OBJ/wrapper_c.o" "$OBJ/lsan_off.o" $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS \
      -lm -lpthread -o "$FUZZ_OUT/$name"
  $CC -O2 -w "${LEGACY_C[@]}" "${VERSION_DEFS[@]}" $extra "$@" -lm -lpthread -o "$ORACLE/$name"
}
# build_cxx <name> <shim-object> <extra-cxxflags> <sources...>
build_cxx() {
  local name="$1" shim="$2" extra="$3"; shift 3
  local objs
  mapfile -t objs < <(fuzz_objs "$name" "$CXX" -fpermissive $extra -- "$@")
  $CXX "${objs[@]}" "$OBJ/$shim" "$OBJ/wrapper_cxx.o" "$OBJ/lsan_off.o" $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS \
      -lm -lpthread -o "$FUZZ_OUT/$name"
  $CXX -O2 -w "${VERSION_DEFS[@]}" -fpermissive $extra "$@" -lm -lpthread -o "$ORACLE/$name"
}

T="$SRC/tools"
build_c bin2txt       ""                                    "$T"/bin2txt/bin2txt.c
build_c gfx2snes      ""                                    "$T"/gfx2snes/*.c
build_c gfx4snes      ""                                    "$T"/gfx4snes/src/*.c
build_c fnt4snes      ""                                    "$T"/fnt4snes/src/*.c
build_c tmx2snes      ""                                    "$T"/tmx2snes/src/*.c
build_c snestools     ""                                    "$T"/snestools/*.c
build_c snesromusage  ""                                    "$T"/snesromusage/src/*.c
build_c opt816        ""                                    "$T"/816-opt/src/*.c
build_cxx smconv      shim_char.o  ""                       "$T"/smconv/*.cpp
build_cxx constify    shim_char.o  ""                       "$T"/constify/constify.cpp
build_cxx snesbrr     shim_cchar.o "-I$T/snesbrr"           "$T"/snesbrr/base/*.cpp "$T"/snesbrr/brr/*.cpp
