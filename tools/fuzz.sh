#!/bin/bash
# Generated programs through the differential sweep:
#
#   tools/fuzz.sh [count] [seed]
#
# tools/gen.py writes `count` random well-typed programs (default 40) from `seed` (default 1)
# into the sweep's work directory, and tools/sweep.sh runs each through stage 0, the checker
# and mplc, top level and lifted, printing only the classes that are bugs. A program that
# turns one up is kept there: rerun its seed to get it back.
cd "$(dirname "$0")/.." || exit 1
n=${1:-40}; seed=${2:-1}
W=${SWEEP_DIR:-${TMPDIR:-/tmp}/mpl-sweep}
G=$W/gen-$seed
rm -rf "$G" && python3 tools/gen.py "$G" "$n" "$seed" || exit 2
exec tools/sweep.sh --lift --bugs "$G"/*.mpl
