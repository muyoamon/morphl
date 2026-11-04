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
#   NOT-COMPILED  the checker accepts it, mplc refuses it (whatever stage 0 says: mplc runs that
#                 checker first, so what it refuses after is lowering, verify or emit)
#   BAD-C         mplc emits C that cc refuses
#   CRASH         the compiled program dies where stage 0 answered
#   MISCOMPILE    stage 0 and the compiled program both answer, differently
#   STRICTER      stage 0 runs it, the checker refuses it
#   LENIENT       the checker accepts it, stage 0 refuses it
#   UNLINKED      the C compiles and a symbol is missing at link (a §4.16 `$extern` with no host)
#   REFUSED       NOT-COMPILED in a fixture that exists to be: `refused` below says why
#
# The first four are bugs, and any of them makes the exit status 1. The others often are not:
# STRICTER is mostly a rule only the checker has (§4.10's source order, §5.3a), and LENIENT the
# bootstrap subset, which stage 0 enforces and the checker does not (BOOTSTRAP §1.2).
#
# A program that panics agrees when the compiled one aborts too, and is a MISCOMPILE when it
# does not. Only the abort is compared: §8 asks the two to agree on *that* an intrinsic panics,
# and its text differs (`at`'s bounds); `zig build test-panic` checks the texts it pins.
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
mkdir -p "$W/run" || exit 2
# Written into the source tree (the checker's driver, the lifted copies): removed however the
# script ends.
lifted=()
trap 'rm -f stage1/.sweep_tc.mpl "${lifted[@]}"' EXIT

# The checker, compiled. typecheck.mpl does its work at the top level, which a compiled program
# runs from mpl_init, so it needs a `main` to link and does nothing in it.
key=$(cat zig-out/bin/mplc stage1/*.mpl | md5sum | cut -c1-16)
tc=$W/tc-$key
if [ ! -x "$tc" ]; then
  # Beside typecheck.mpl, so its `$import`s resolve.
  { cat stage1/typecheck.mpl; printf '\n$decl main $func () 0\n'; } > stage1/.sweep_tc.mpl
  ( ulimit -v 8000000; ./zig-out/bin/mplc stage1/.sweep_tc.mpl > "$W/tc.c" ) 2>"$W/tc.err"
  st=$?; rm -f stage1/.sweep_tc.mpl
  [ $st -eq 0 ] || { echo "sweep: mplc cannot compile the checker:"; head -3 "$W/tc.err"; exit 2; }
  cc -O1 -w -o "$tc" "$W/tc.c" || { echo "sweep: cc cannot compile the checker"; exit 2; }
fi

# A lifted copy is written beside its original, hidden from `*.mpl`: §4.14 resolves every
# `$import` from the entry file's directory, a module's own included, so a copy anywhere else
# could not load a module that imports another (`effect`, `import_order`, `module_value`).
is_lifted() { case "$(basename "$1")" in .lifted_*) return 0 ;; esac; return 1; }
orig_name() { local n; n=$(basename "$1" .mpl); printf '%s' "${n#.lifted_}"; }
if [ $lift = 1 ]; then
  for f in "${files[@]}"; do
    out=$(dirname "$f")/.lifted_$(basename "$f")
    python3 tools/lift.py "$f" "$out" && { lifted+=("$out"); files+=("$out"); }
  done
fi

# Programs mplc must refuse after the checker accepts them, and why. A lifted copy is the same.
declare -A refused=(
  [emit_err]="test-stage2: mplc fails on an emit error"
  [override_diag]="test-reject: lowering's diagnostics, mapped back from an \$override"
  [override2_diag]="test-reject: the same, two overrides down"
  [override2_dmid]="override2_diag's middle module"
  [override_diag_util]="override_diag's module, whose \$specialize specialises itself"
)
declare -A count
nbug=0
for f in "${files[@]}"; do
  b=$W/run/$(printf '%s' "$f" | tr '/.' '__')
  rm -f "$b".c "$b".o "$b".bin "$b".ccerr
  # A fixture's own flags — `// mplc-args: -L stage1/fixtures/lib` — go to all three, as
  # `mplc` takes them: after the file, and before it for stage 0, whose later arguments are
  # the program's.
  read -ra xa <<< "$(sed -n 's|^// mplc-args: *||p' "$f" | head -1)"
  s0=$( (ulimit -v 3000000; timeout 120 ./zig-out/bin/morphlc --run --main "${xa[@]}" "$f" 2>&1) )
  s0rc=$?
  s0l=$(printf '%s\n' "$s0" | tail -1)
  tcn=$( (ulimit -v 8000000; timeout 120 "$tc" "$f" "${xa[@]}" 2>&1) | grep '^errors: ' | tail -1)
  tcn=${tcn#errors: }; [ -z "$tcn" ] && tcn=crash
  mc=$( (ulimit -v 8000000; timeout 120 ./zig-out/bin/mplc "$f" "${xa[@]}") 2>&1 >"$b".c ); mcrc=$?
  mcl=$(printf '%s\n' "$mc" | grep -v 'warning: no top-level' | head -1)
  lib=0; printf '%s\n' "$mc" | grep -q "no top-level \$decl named 'main'" && lib=1
  ccrc=-; runrc=-; out=""
  if [ $mcrc -eq 0 ] && [ $lib = 1 ]; then
    if cc -O0 -w -c -o "$b".o "$b".c 2>"$b".ccerr; then ccrc=0; else ccrc=1; fi
  elif [ $mcrc -eq 0 ]; then
    # Compiled and linked apart, so a C error is told from a missing symbol. A fixture that
    # crosses §4.16 links its `<name>_host.c`; one with no host that still lacks a symbol is
    # UNLINKED, which `unlinked.mpl` is on purpose.
    host=$(dirname "$f")/$(orig_name "$f")_host.c
    [ -f "$host" ] || host=""
    # -O0, as `test-emit`: an optimising cc turns a self call into a loop itself, which
    # would hide a tail call §7.7 needed and the backend did not make.
    if ! cc -O0 -w -c -o "$b".o "$b".c 2>"$b".ccerr; then ccrc=1
    elif ! cc -O0 -w -o "$b".bin "$b".o $host 2>"$b".ccerr; then ccrc=2
    else
      ccrc=0
      out=$( (ulimit -v 8000000; timeout 120 "$b".bin) 2>&1 ); runrc=$?
      out=$(printf '%s\n' "$out" | grep -v '^timeout: ' | tail -1)
    fi
  fi
  cls=""; why=""
  s0p=$(printf '%s\n' "$s0" | grep -m1 -o 'error: panic: .*')
  if [ $s0rc -ne 0 ] && [ -n "$s0p" ] && [ "$ccrc" = 0 ] && [ $lib = 0 ]; then
    # 134 is §7.8's abort, under `timeout` as without it.
    [ "$runrc" = 134 ] || { cls=MISCOMPILE; why="stage 0 ${s0p#error: }, compiled exit $runrc: $out"; }
  elif [ "$tcn" = 0 ] && [ $mcrc -ne 0 ]; then
    cls=NOT-COMPILED; why=$mcl
    r=${refused[$(orig_name "$f")]}; [ -n "$r" ] && { cls=REFUSED; why=$r; }
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
  name=$f; is_lifted "$f" && name="$(orig_name "$f").mpl (lifted)"
  echo "$name: $cls  $why"
done
summary=""
for c in NOT-COMPILED BAD-C CRASH MISCOMPILE STRICTER LENIENT UNLINKED REFUSED; do
  [ -n "${count[$c]}" ] && summary="$summary $c ${count[$c]}"
done
echo "sweep: ${#files[@]} program(s),${summary:- all agree}"
[ $nbug -eq 0 ]
