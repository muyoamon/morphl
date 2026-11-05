#!/bin/bash
# Generated programs through the differential sweep:
#
#   tools/fuzz.sh [count] [seed]
#
# tools/gen.py writes `count` random well-typed programs (default 40) from `seed` (default 1)
# into the sweep's work directory, and tools/sweep.sh runs each through stage 0, the checker
# and mplc, top level and lifted, printing only the classes that are bugs. A program that
# turns one up is kept there: rerun its seed to get it back.
#
# A program using `$override`, which stage 0 leaves out, has a reference with the override
# written out (`<name>_ref.mpl`); the sweep checks the reference against stage 0, and this
# checks mplc answers the two alike — OVERRIDE-DIFF when it does not.
cd "$(dirname "$0")/.." || exit 1
n=${1:-40}; seed=${2:-1}
W=${SWEEP_DIR:-${TMPDIR:-/tmp}/mpl-sweep}
G=$W/gen-$seed
rm -rf "$G" && python3 tools/gen.py "$G" "$n" "$seed" || exit 2
tools/sweep.sh --lift --bugs "$G"/*.mpl; st=$?
answer() {
  ( ulimit -v 8000000; timeout 120 ./zig-out/bin/mplc "$1" > "$2.c" ) 2>/dev/null &&
    cc -O0 -w -o "$2" "$2.c" 2>/dev/null && ( ulimit -v 8000000; timeout 120 "$2" ) 2>&1 | tail -1
}
np=0; nd=0
for r in "$G"/*_ref.mpl; do
  [ -f "$r" ] || continue
  p=${r%_ref.mpl}.mpl; np=$((np + 1))
  a=$(answer "$p" "$G/.pa"); b=$(answer "$r" "$G/.pb")
  if [ -z "$a" ] || [ "$a" != "$b" ]; then
    nd=$((nd + 1)); echo "$(basename "$p"): OVERRIDE-DIFF  mplc ${a:-(none)}, reference ${b:-(none)}"
  fi
done
echo "fuzz: $np override pair(s), ${nd} differ"
[ $st -eq 0 ] && [ $nd -eq 0 ]
