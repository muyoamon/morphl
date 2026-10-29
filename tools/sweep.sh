#!/bin/bash
# Differential sweep: every program through stage 0, the checker, and mplc -> cc -> run, reporting
# each file where they disagree.
#
#   tools/sweep.sh [--lift] [--bugs] [file.mpl...]
#
# With no files it sweeps stage1/fixtures/*.mpl. --lift also sweeps each one with its top level
# moved into a function body (tools/lift.py), which is where most of what this has found lived: a
# name that is a global at the top level is a frame slot there. --bugs prints only the classes that
# are compiler bugs. Classes, first match wins:
#
#   NOT-COMPILED  stage 0 runs it and the checker accepts it, mplc refuses it
#   BAD-C         mplc emits C that cc refuses
#   CRASH         the compiled program dies where stage 0 answered
#   MISCOMPILE    stage 0 and the compiled program both answer, differently
#   STRICTER      stage 0 runs it, the checker refuses it
#   LENIENT       the checker accepts it, stage 0 refuses it
#   UNLINKED      the C compiles and a symbol is missing at link (a §4.16 `$extern` with no host)
#
# The first four are bugs, and any of them makes the exit status 1. The others often are not:
# STRICTER is mostly a rule only the checker has (§4.10's source order, §5.3a), and LENIENT the
# bootstrap subset, which stage 0 enforces and the checker does not (BOOTSTRAP §1.2).
#
# It tests the *installed* mplc, which is the committed backend until tools/regen.sh has run
# (CLAUDE.md): sweep after regenerating, not before. A library — mplc warns there is no `main` —
# is only compiled. The checker is typecheck.mpl compiled by that mplc, rebuilt when mplc or
# stage1/ changes. Everything runs under a memory bound (CLAUDE.md: stage 0 never frees, and a
# compiled program does not either).
cd "$(dirname "$0")/.." || exit 1
lift=0; bugs=0; files=()
for a in "$@"; do
  case "$a" in
    --lift) lift=1 ;;
    --bugs) bugs=1 ;;
    -*) echo "usage: tools/sweep.sh [--lift] [--bugs] [file.mpl...]"; exit 2 ;;
    *) files+=("$a") ;;
  esac
done
[ ${#files[@]} -eq 0 ] && files=(stage1/fixtures/*.mpl)
[ -x zig-out/bin/mplc ] && [ -x zig-out/bin/morphlc ] ||
  { echo "sweep: needs zig-out/bin/mplc and morphlc (zig build && zig build stage2)"; exit 2; }

W=${SWEEP_DIR:-${TMPDIR:-/tmp}/mpl-sweep}
mkdir -p "$W/run" "$W/lifted" || exit 2

# The checker, compiled. typecheck.mpl does its work at the top level, which a compiled program
# runs from mpl_init, so it needs a `main` to link and does nothing in it.
key=$(cat zig-out/bin/mplc stage1/*.mpl | md5sum | cut -c1-16)
tc=$W/tc-$key
if [ ! -x "$tc" ]; then
  # Beside typecheck.mpl, so its `$import`s resolve; removed however the script ends.
  trap 'rm -f stage1/.sweep_tc.mpl' EXIT
  { cat stage1/typecheck.mpl; printf '\n$decl main $func () 0\n'; } > stage1/.sweep_tc.mpl
  ( ulimit -v 8000000; ./zig-out/bin/mplc stage1/.sweep_tc.mpl > "$W/tc.c" ) 2>"$W/tc.err"
  st=$?; rm -f stage1/.sweep_tc.mpl
  [ $st -eq 0 ] || { echo "sweep: mplc cannot compile the checker:"; head -3 "$W/tc.err"; exit 2; }
  cc -O1 -w -o "$tc" "$W/tc.c" || { echo "sweep: cc cannot compile the checker"; exit 2; }
fi

if [ $lift = 1 ]; then
  rm -f "$W"/lifted/*.mpl
  for f in "${files[@]}"; do
    out=$W/lifted/$(basename "$f")
    python3 tools/lift.py "$f" "$out" && files+=("$out")
  done
fi

declare -A count
nbug=0
for f in "${files[@]}"; do
  b=$W/run/$(printf '%s' "$f" | tr '/.' '__')
  rm -f "$b".c "$b".o "$b".bin "$b".ccerr
  s0=$( (ulimit -v 3000000; timeout 120 ./zig-out/bin/morphlc --run --main "$f" 2>&1) ); s0rc=$?
  s0l=$(printf '%s\n' "$s0" | tail -1)
  tcn=$( (ulimit -v 8000000; timeout 120 "$tc" "$f" 2>&1) | grep '^errors: ' | tail -1)
  tcn=${tcn#errors: }; [ -z "$tcn" ] && tcn=crash
  mc=$( (ulimit -v 8000000; timeout 120 ./zig-out/bin/mplc "$f") 2>&1 >"$b".c ); mcrc=$?
  mcl=$(printf '%s\n' "$mc" | grep -v 'warning: no top-level' | head -1)
  lib=0; printf '%s\n' "$mc" | grep -q "no top-level \$decl named 'main'" && lib=1
  ccrc=-; runrc=-; out=""
  if [ $mcrc -eq 0 ] && [ $lib = 1 ]; then
    if cc -O0 -w -c -o "$b".o "$b".c 2>"$b".ccerr; then ccrc=0; else ccrc=1; fi
  elif [ $mcrc -eq 0 ]; then
    # Compiled and linked apart, so a C error is told from a missing symbol. A fixture that
    # crosses §4.16 links its `<name>_host.c`; one with no host that still lacks a symbol is
    # UNLINKED, which `unlinked.mpl` is on purpose.
    host=${f%.mpl}_host.c
    case "$f" in "$W"/lifted/*) host=stage1/fixtures/$(basename "${f%.mpl}")_host.c ;; esac
    [ -f "$host" ] || host=""
    if ! cc -O1 -w -c -o "$b".o "$b".c 2>"$b".ccerr; then ccrc=1
    elif ! cc -O1 -w -o "$b".bin "$b".o $host 2>"$b".ccerr; then ccrc=2
    else
      ccrc=0
      out=$( (ulimit -v 8000000; timeout 120 "$b".bin) 2>&1 ); runrc=$?
      out=$(printf '%s\n' "$out" | tail -1)
    fi
  fi
  cls=""; why=""
  if [ $s0rc -eq 0 ] && [ "$tcn" = 0 ] && [ $mcrc -ne 0 ]; then cls=NOT-COMPILED; why=$mcl
  elif [ $mcrc -eq 0 ] && [ "$ccrc" = 1 ]; then
    cls=BAD-C; why=$(grep -m1 error "$b".ccerr)
  elif [ "$ccrc" = 2 ]; then cls=UNLINKED; why=$(grep -m1 'undefined reference' "$b".ccerr)
  elif [ $lib = 1 ]; then :
  elif [ $s0rc -eq 0 ] && [ "$ccrc" = 0 ] && [ "$runrc" != 0 ]; then
    cls=CRASH; why="exit $runrc, stage 0 answered $s0l"
  elif [ $s0rc -eq 0 ] && [ "$ccrc" = 0 ] && [ "$out" != "$s0l" ]; then
    cls=MISCOMPILE; why="stage 0 $s0l, compiled $out"
  elif [ $s0rc -eq 0 ] && [ "$tcn" != 0 ]; then cls=STRICTER; why="checker: $tcn error(s)"
  elif [ $s0rc -ne 0 ] && [ "$tcn" = 0 ]; then
    cls=LENIENT; why="stage 0: $(printf '%s\n' "$s0" | grep -m1 -i error)"
  fi
  [ -z "$cls" ] && continue
  count[$cls]=$(( ${count[$cls]:-0} + 1 ))
  case $cls in NOT-COMPILED|BAD-C|CRASH|MISCOMPILE) nbug=$((nbug + 1)) ;;
    *) [ $bugs = 1 ] && continue ;; esac
  name=$f; case "$f" in "$W"/lifted/*) name="$(basename "$f") (lifted)" ;; esac
  echo "$name: $cls  $why"
done
summary=""
for c in NOT-COMPILED BAD-C CRASH MISCOMPILE STRICTER LENIENT UNLINKED; do
  [ -n "${count[$c]}" ] && summary="$summary $c ${count[$c]}"
done
echo "sweep: ${#files[@]} program(s),${summary:- all agree}"
[ $nbug -eq 0 ]
