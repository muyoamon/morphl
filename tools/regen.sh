#!/bin/bash
# Regenerate bootstrap/mplc.c to a fixed point after a change to stage1/, and install mplc.
#
#   tools/regen.sh
#
# Round 1: the installed mplc (built from the old backend) emits the new source; that C is
# compiled at -O1 into a throwaway binary, which emits again with the new backend. Round 2: that
# candidate is installed as bootstrap/mplc.c and built by `zig build stage2` (-O2, -Wall), and the
# installed mplc emits a third time. Agreement is the fixed point. A change to how names are made
# can need a further round, so the loop runs until two emits agree or MAX rounds pass, and puts
# the original bootstrap/mplc.c back on any failure.
#
# Why these levels (PERF.md, "Regeneration"): a throwaway binary is compiled once and run once, so
# what counts is cc plus one emit. -O1 is 14.7s + 6.4s against -O2's 26.5s + 5.4s; -O0 is 7.7s +
# 13.8s and overflows the default 8 MB stack, because only an optimising gcc turns C sibling calls
# into jumps. And the final -O2 build is the one `zig build stage2` has to do anyway, so the
# fixed-point check runs on it rather than on a second, identical compile.
#
# Every step's status is checked explicitly: `set -e` is ignored inside an && / || list, which once
# installed an empty bootstrap/mplc.c (CLAUDE.md).

MAX=4
cd "$(dirname "$0")/.." || exit 1
W=$(mktemp -d "${TMPDIR:-/tmp}/mplc-regen.XXXXXX") || exit 1
# The compiled compiler never frees; bound it so a runaway fails in-process (CLAUDE.md).
ulimit -v 8000000
cp bootstrap/mplc.c "$W/committed.c" || { echo "regen: cannot back up bootstrap/mplc.c"; exit 1; }

touched=0
fail() {
    echo "regen: FAIL $* (work files in $W)" >&2
    if [ $touched = 1 ]; then
        cp "$W/committed.c" bootstrap/mplc.c && zig build stage2 > /dev/null 2>&1
        echo "regen: restored bootstrap/mplc.c and mplc" >&2
    fi
    exit 1
}
emit() {  # emit <binary> <out>
    "$1" stage1/mplc.mpl > "$2" || fail "emit by $1"
    test -s "$2" || fail "$2 is empty"
}

t0=$SECONDS
emit zig-out/bin/mplc "$W/r1.c"
cc -O1 -w -o "$W/r1" "$W/r1.c" || fail "cc -O1 r1.c"
emit "$W/r1" "$W/r2.c"

n=2
while :; do
    touched=1
    cp "$W/r$n.c" bootstrap/mplc.c || fail "install r$n.c"
    zig build stage2 > "$W/stage2.log" 2>&1 || { cat "$W/stage2.log" >&2; fail "zig build stage2"; }
    emit zig-out/bin/mplc "$W/r$((n + 1)).c"
    if cmp -s "$W/r$n.c" "$W/r$((n + 1)).c"; then
        echo "regen: fixed point at round $n, $(wc -c < bootstrap/mplc.c) bytes, $((SECONDS - t0))s"
        rm -rf "$W"
        exit 0
    fi
    n=$((n + 1))
    [ $n -le $MAX ] || fail "no fixed point after $MAX rounds"
    echo "regen: r$((n - 1)).c and r$n.c differ, another round"
done
