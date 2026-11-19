#!/usr/bin/env bash
#
# mayhem/test.sh - behavioral oracle for pvsneslib's host tools.
#
# Runs the normally-built, dynamically-linked tools from mayhem/build/oracle (built by build.sh, no
# sanitizers) on fixed inputs and asserts known outputs: sha256 of every produced file
# (mayhem/fixtures/golden.sha256) plus a few exact strings from the tools' own reports.
# A tool that crashes, exits early or produces different bytes fails its case.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

M="$SRC/mayhem"
ORA="$M/build/oracle"
GOLDEN="$M/fixtures/golden.sha256"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

ok()   { passed=$((passed + 1)); }
fail() { failed=$((failed + 1)); echo "FAIL: $*" >&2; }

# check <case> <file>: the file exists and its sha256 equals the golden entry "<case>/<file>".
check() {
  local case="$1" f="$2" want got
  if [ ! -f "$f" ]; then fail "$case: $f was not produced"; return; fi
  got="$(sha256sum "$f" | cut -d' ' -f1)"
  if [ "${MAYHEM_RECORD:-}" = 1 ]; then echo "$got  $case/$f"; ok; return; fi
  want="$(grep -F "  $case/$f" "$GOLDEN" | cut -d' ' -f1)"
  if [ "$got" = "$want" ]; then ok; else fail "$case/$f: sha256 $got, expected ${want:-<none>}"; fi
}

# contains <case> <needle> <haystack>
contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then ok; else fail "$1: output lacks '$2'"; fi
}

# newcase <name>: fresh working directory for a case
newcase() { mkdir -p "$WORK/$1" && cd "$WORK/$1" || exit 2; }

for t in bin2txt gfx2snes gfx4snes fnt4snes tmx2snes smconv snesbrr snestools snesromusage opt816 constify; do
  [ -x "$ORA/$t" ] || { echo "missing oracle binary $ORA/$t (mayhem/build.sh did not build it)" >&2; failed=$((failed + 1)); }
done
[ "$failed" -eq 0 ] || { emit_ctrf pvsneslib-tools "$passed" "$failed"; exit 1; }

seed() { echo "$M/$1/testsuite/$2"; }

# bin2txt: binary -> C array
newcase bin2txt; cp "$(seed bin2txt tada.brr)" tada.brr
# the tools stamp the conversion time into a header comment; drop that line before hashing
"$ORA/bin2txt" -q -cc tada.brr >/dev/null 2>&1
[ -f tada.h ] && { grep -v 'converted the ' tada.h > tada.nodate.h; check bin2txt-c tada.nodate.h; } || fail "bin2txt: tada.h was not produced"
"$ORA/bin2txt" -q -ca tada.brr >/dev/null 2>&1
[ -f tada.asm ] && { grep -v 'converted the ' tada.asm > tada.nodate.asm; check bin2txt-asm tada.nodate.asm; } || fail "bin2txt: tada.asm was not produced"

# gfx2snes: PNG / BMP / PCX -> tiles, map, palette
newcase gfx2snes_png; cp "$(seed gfx2snes_png tiles.png)" tiles.png
"$ORA/gfx2snes" -fpng -q -gs8 -pc16 -po16 -m tiles.png >/dev/null 2>&1
for f in tiles.pic tiles.map tiles.pal; do check gfx2snes_png "$f"; done
newcase gfx2snes_bmp; cp "$(seed gfx2snes_bmp sprite16.bmp)" sprite16.bmp
"$ORA/gfx2snes" -fbmp -q -gs8 -pc16 -m sprite16.bmp >/dev/null 2>&1
for f in sprite16.pic sprite16.map sprite16.pal; do check gfx2snes_bmp "$f"; done
newcase gfx2snes_pcx; cp "$(seed gfx2snes_pcx p.pcx)" p.pcx
"$ORA/gfx2snes" -fpcx -q -gs8 -pc16 -m p.pcx >/dev/null 2>&1
for f in p.pic p.map p.pal; do check gfx2snes_pcx "$f"; done

# gfx4snes: PNG / BMP -> tiles, map, palette
newcase gfx4snes_png; cp "$(seed gfx4snes_png tiles.png)" tiles.png
"$ORA/gfx4snes" -s 8 -o 16 -u 16 -e 0 -p -m -q -t png -i tiles.png >/dev/null 2>&1
for f in tiles.pic tiles.map tiles.pal; do check gfx4snes_png "$f"; done
newcase gfx4snes_bmp; cp "$(seed gfx4snes_bmp mario_sprite.bmp)" mario_sprite.bmp
"$ORA/gfx4snes" -s 8 -o 16 -u 16 -e 0 -p -m -q -t bmp -i mario_sprite.bmp >/dev/null 2>&1
for f in mario_sprite.pic mario_sprite.map mario_sprite.pal; do check gfx4snes_bmp "$f"; done

# fnt4snes: font strip -> variable-width font
newcase fnt4snes; cp "$(seed fnt4snes pvsneslibfont.png)" pvsneslibfont.png
"$ORA/fnt4snes" -q -p -i pvsneslibfont.png >/dev/null 2>&1
for f in pvsneslibfont.pic pvsneslibfont.pal pvsneslibfont.inc; do check fnt4snes "$f"; done

# tmx2snes: Tiled map -> .b16/.o16/.t16
newcase tmx2snes; cp "$(seed tmx2snes_tmx map_1_1.tmx)" map_1_1.tmx; cp "$M/fixtures/tiles.map" tiles.map
"$ORA/tmx2snes" -q -m tiles.map -i map_1_1.tmx >/dev/null 2>&1
for f in map_1_1.b16 map_1_1.o16 map_1_1.t16; do check tmx2snes "$f"; done
newcase tmx2snes_tmj; cp "$(seed tmx2snes_tmj map_1_1.tmj)" map_1_1.tmj; cp "$M/fixtures/tiles.map" tiles.map
"$ORA/tmx2snes" -q -m tiles.map -i map_1_1.tmj >/dev/null 2>&1
for f in map_1_1.b16 map_1_1.o16 map_1_1.t16; do check tmx2snes_tmj "$f"; done

# smconv: Impulse Tracker module -> SPC soundbank
newcase smconv; cp "$(seed smconv logo_pvsneslib.it)" logo.it
"$ORA/smconv" -s -o sb logo.it >/dev/null 2>&1
for f in sb.asm sb.bnk sb.h; do check smconv "$f"; done

# snesbrr: WAV <-> BRR
newcase snesbrr; cp "$(seed snesbrr_encode tada.wav)" tada.wav; cp "$(seed snesbrr_decode tada.brr)" tada.brr
"$ORA/snesbrr" -e tada.wav enc.brr >/dev/null 2>&1; check snesbrr-encode enc.brr
"$ORA/snesbrr" -d tada.brr dec.wav >/dev/null 2>&1; check snesbrr-decode dec.wav

# snestools: ROM header report and header rewrite
newcase snestools; cp "$(seed snestools r.sfc)" r.sfc
out="$("$ORA/snestools" r.sfc 2>&1)"
contains snestools "Game title    : PVSNESLIB TEST ROM" "$out"
contains snestools "Checksum      : 1234" "$out"
contains snestools "Comp Checksum : EDCB" "$out"
contains snestools "Bank size:    : LoROM" "$out"
cp r.sfc w.sfc; "$ORA/snestools" -q -hc01 -htHELLO -hS! w.sfc >/dev/null 2>&1; check snestools-rewrite w.sfc

# snesromusage: wla-dx .sym -> ROM/RAM usage report
newcase snesromusage; cp "$(seed snesromusage a.sym)" a.sym
out="$("$ORA/snesromusage" -s -g -i a.sym 2>&1)"
printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' > report.txt; check snesromusage report.txt

# 816-opt: 65c816 peephole optimizer
newcase opt816; cp "$(seed opt816 sounds.asm)" in.asm
"$ORA/opt816" -q -o out.asm -i in.asm >/dev/null 2>&1; check opt816 out.asm
if [ -f out.asm ] && [ "$(wc -l < out.asm)" -lt "$(wc -l < in.asm)" ]; then ok; else fail "opt816: output is not smaller than the input"; fi
# upstream's own 816-opt suite (perf/asmtest.py): each perf/asmtests/<case>.ps is optimized and its
# function body compared with <case>.expected; one CTRF test per case. (perf/tests/* is not run: it
# needs 816-tcc, wla-dx and a snes9x libretro core, none of which are built here.)
command -v python3 >/dev/null || { echo "python3 is required for perf/asmtest.py" >&2; exit 1; }
ncases=$(ls "$SRC"/perf/asmtests/*.ps | wc -l)
asm_out="$(python3 "$SRC/perf/asmtest.py" --opt "$ORA/opt816" 2>&1)"; asm_rc=$?
asm_ok=$(printf '%s\n' "$asm_out" | grep -c '^== .* : OK$')
asm_bad=$(printf '%s\n' "$asm_out" | grep -c '^== .* : ECHEC$')
passed=$((passed + asm_ok)); failed=$((failed + ncases - asm_ok))
if [ "$asm_bad" -gt 0 ] || [ "$asm_ok" -ne "$ncases" ] || [ "$asm_rc" -ne 0 ]; then
  echo "FAIL: perf/asmtest.py ($asm_ok/$ncases OK, rc=$asm_rc):" >&2; printf '%s\n' "$asm_out" >&2
  [ "$asm_ok" -eq "$ncases" ] && failed=$((failed + 1))
fi

# constify: move const data from .data/.ramsection to .rodata
newcase constify; cp "$M/fixtures/k.c" k.c; cp "$M/fixtures/k.asm" k.asm
out="$("$ORA/constify" -q k.c k.asm out.asm 2>&1)"
contains constify "Moved 2 variables (8 bytes)" "$out"
check constify out.asm
if [ -f out.asm ] && sed -n '/^\.SECTION "\.rodata"/,/^\.ENDS/p' out.asm | tr -d '\n' | grep -qF 'table_const:.db 1,2,3,4tccs_sine_tab:.dw 5,6'; then ok; else fail "constify: .rodata does not hold the moved tables"; fi

emit_ctrf pvsneslib-tools "$passed" "$failed"
