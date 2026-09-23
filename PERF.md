# Performance log

Measurements are expensive here — the whole-compiler run is twenty to thirty
minutes and several of the figures below cost that each. Record them rather than
re-derive them. Every row says which tree it was taken on, because a number
without that provenance is not comparable to anything.

`CLAUDE.md` carries the *conclusions*; this file carries the numbers and how to
reproduce them.

## How to take a measurement

```
# always under the cap; never raise it, never run detached
(ulimit -v 3000000; MORPHL_STATS=1 ./zig-out/bin/morphlc --run stage1/emit_c.mpl stage1/<f>.mpl >/dev/null)
```

| variable | what it adds |
|---|---|
| `MORPHL_STATS=1` | allocation profile: totals, buckets by construct, per-function bytes, most-allocated block literals |
| `MORPHL_CALLS=1` | rank the per-function table by **calls** instead of bytes |
| `MORPHL_INCLUSIVE=<fn>` | bytes allocated between one function's entry and return, outermost activations only |
| `MORPHL_TRACE_READS=1` | one line per `read_file`, which counts module loads |

`perf record -g --call-graph=dwarf -F 199` on a ReleaseFast build for time.

## Four ways these measurements have lied

1. **A `zig build --prefix out<N>` snapshot captures stage 0 only.** Stage-1
   sources are read at *run time*, so two such binaries run whatever is in
   `stage1/` now. Comparing them to A/B a stage-1 change compares a program with
   itself. To A/B stage 1: fix the binary, edit the `.mpl`, run, restore.
2. **A capped run's block count is a constant, not a measurement** — every OOM
   reports whatever fits in the ~2.1 GB left for blocks. The only signal a
   capped run carries is *completed or not*, plus the profile up to the wall.
3. **Validate the artifact.** A run that hit the cap leaves an empty file, and
   `cc -c` on an empty file reports no errors, which reads exactly like success.
   Check line counts. Keep stderr visible — a run that failed in 3s otherwise
   looks like a fast run.
4. **Emitting a file that imports the file you edited recompiles your edit.**
   Output differing after a stage-1 change is expected, not a semantic
   regression: the extra frame slots are your new `$match` arms.

## Stage 0 throughput — measured, and flat

| quantity | value | varies with program size? |
|---|---|---|
| time per name lookup | **0.054 µs** | no (flat over a 1000x range) |
| slots compared per lookup | **~16.8** | no (16.3 / 16.8 / 17.1 / 16.8 / 15.1) |
| scopes walked per lookup | **1.35** | no |
| module loads per module | **exactly 2** | no |
| fixed startup (parsing stage 1 at `$import`) | **~15 MB** | no — constant for a 1-line input |

So the interpreter is linear and well behaved. **Time is linear in stage-1
calls**; what grows is how many the compiler makes.

## The shape of the problem: stage 1 is ~cubic in program size

Taken at `9e29dc0`-ish (before the leaf fix and the redundant-deref removal),
`emit_c.mpl` over each module. "lines" is the transitive `$import` closure.

| module | lines | types | time | alloc | blocks | lookups |
|---|---|---|---|---|---|---|
| prelude | 111 | 13 | 0.09s | 0.02 GB | 11,788 | 0.69M |
| lexer | 480 | 97 | 0.84s | 0.02 GB | 138,463 | 14.4M |
| parser | 1,096 | 257 | 6.42s | 0.05 GB | 497,243 | 124M |
| types | 1,399 | 235 | 17.70s | 0.05 GB | 624,009 | 340M |
| ir | 1,789 | 433 | 41.87s | 0.10 GB | 1,463,437 | 749M |
| verify | 3,192 | 853 | 26.44s | 0.23 GB | 3,777,217 | |
| infer | 3,662 | 866 | 59.52s | 0.25 GB | 4,053,650 | |
| emit | 4,322 | ~900 | 42.56s | 0.36 GB | 4,538,176 | |
| compiler | 8,327 | 1,470 | **OOM** | >3 GB | | |

1.28x the lines costs ~2.2x the work — an exponent near **3.2**, uniform across
functions (`cons` 2.4x, `lookup` 2.2x, `token` 2.2x). Extrapolating to 8,327
lines gives ~75 billion lookups ≈ 67 minutes, which is why the whole compiler
dies partway rather than merely being slow. Time is *not* superlinear per unit
of work; the work itself is.

## Cost tracks the interned type count, not the line count

Predicting from lines failed outright. `half.mpl` — §9.1 up to `check`, so parse
+ infer + lower — is 6,216 lines of closure, between `emit` (4,336, completes at
0.36 GB in 42.6s) and `compiler` (8,341). Interpolating on lines predicted
**~3 min and ~0.8 GB**; it **OOMed after 28m45s**, behaving like the whole
compiler rather than a midpoint.

The predictor that works is the number of types `intern` ends up holding:

| module | lines | types | emit time | alloc |
|---|---|---|---|---|
| ir | 1,789 | 432 | 41.9s | 0.10 GB |
| verify | 3,192 | 852 | 26.4s | 0.23 GB |
| infer | 3,662 | 865 | 59.5s | 0.25 GB |
| emit | 4,322 | 960 | 42.6s | 0.36 GB |
| lower | — | 1,195 | — | — |
| compiler | 8,327 | 1,470 | OOM | >3 GB |

Allocation against type count has an exponent near **1.6** from 432 to 960, and
near **3.5** from 960 to 1,470 — a knee above roughly 1,000 types. That is what
separates completing from dying: `half` adds `lower` (1,195 alone) to `infer`
(865) and lands past it; `front` (parse + infer, no `lower`, no `ir`) stops at
865 and completes.

It also explains the non-monotonicity the line-count view could not: `ir` is
1,789 lines and took 41.9s while `verify` is 3,192 lines and took 26.4s — `ir`
carries the 23-member `proto_expr` union, so its *types* are expensive even
though its lines are few. **§4.9's monomorphisation is the cost**, and the way
to make a smaller experiment is to cut type surface, not files.

## Whole compiler (`emit_c.mpl stage1/compiler.mpl`)

| tree | result |
|---|---|
| `7fd95b7` | **completes**: 18m30s, 1.57 GB, 55,590 lines (reproduced twice) |
| `45d3682` (+§4.1 rule) | OOM |
| + coercion fixes, μ alias, import fix | OOM |
| + `unroll` memo | OOM at 27m02s |
| + lazy coercion message | OOM at 28m18s |
| + inline block header, + `find_ty` digest | OOM at 24m11s |

Bisected by reverting one stage-1 file at a time against a fixed binary: **no
single change is pathological** — the §4.1 cleanup tips it and the backend work
tips it, independently. Something that completes at 1.57 GB and dies on any
modest addition was already at the wall. `ulimit -v` bounds address space, not
arena bytes, so the headroom is much smaller than 1.57-vs-3 suggests.

## Memory composition

`emit_c.mpl stage1/types.mpl`, after subtracting the ~15 MB fixed startup (which
appears as `(top level)` in the function dimension and as `slots` + `other` in
the bucket dimension — the same bytes counted two ways):

| bucket | MB | share of the part that scales |
|---|---|---|
| block | 26.2 | 68% |
| cell (80% of these are list tails) | 7.6 | 20% |
| builtin (string building) | 4.4 | 11% |

Blocks and their tail cells are **~89% of everything proportional to the work**,
and 72% of blocks are `P.list` cons cells at 64 bytes an element.

## Three quarters of all calls are §8 intrinsics

`emit_c.mpl` over `emit.mpl`, **504,229,882 calls total** (`MORPHL_CALLS=1`,
which counts builtins as well as morphl functions):

| | calls | share |
|---|---|---|
| `eq_int` | 287,202,221 | **57.0%** |
| `eq_str` | 47,550,886 | 9.4% |
| `add` | 30,909,348 | 6.1% |
| `sub`, `lt`, `len`, `byte` | 13,764,131 | 2.7% |
| **all §8 intrinsics** | **379,423,000** | **75.2%** |
| `same` + `same_fields` | 83,093,461 | 16.5% |
| everything else | ~40M | 8% |

§2.1 makes an intrinsic an ordinary shadowable name, so `$call eq_int (a, b)` is
a full call: resolve `eq_int` up the scope chain to the root block, evaluate two
arguments onto the arg stack, dispatch through `callValue`, pull both operands
out with `wantInt`, then do one machine comparison. **The operation is free; the
context around it is not**, and most of that context is a name lookup for a name
that cannot change.

This is why `Interp.lookup` is 44.7% of wall time — 287M of those resolutions
are `eq_int`. It also means resolution caching is not a 44.7% opportunity spread
thinly over the program: three quarters of it sits on a handful of root-block
names whose binding is fixed for the whole run.

## Call profile, whole compiler

| function | calls |
|---|---|
| `val` (the identity, §5.4) | 979,203,118 |
| `same` | 324,820,615 |
| `same_fields` | 191,452,684 |
| `cv_eq` | 50,371,011 |
| `cons` | 46,068,274 |

## Changes measured, source-level A/B against a fixed binary

| change | effect | kept? |
|---|---|---|
| shared `Shape` + shared prop slots + count in shape | `types.mpl` block values 349 → 162 MB | yes |
| 16-byte `Value` (box `str`/`float`/`group`) | 162 → 121 MB | yes |
| ephemeral `{…}.name` blocks | whole compiler 28.5M → 23.4M blocks, 19m48 → 18m31 | yes |
| balanced join for `say` (was quadratic `concat`) | emit `types.mpl` 0.98 → 0.21 GB | yes |
| `unroll` memo | emit `types.mpl` 0.21 → 0.07 GB, 3.06M → 0.66M blocks | yes |
| lazy coercion message (`show` was eager) | 59s → 46s (~21%); `show` inclusive 15.22 → 0.39 MB | yes |
| inline block header (8 bytes off every block) | block values 31.0 → 26.3 MB (−15%); **~8% slower, unexplained** | yes |
| leaf `same` by tag instead of `show` | ~21% | yes |
| `find_ty` structural digest | **no measurable win**; adds 81M `ty_hash` calls | **reverted** |
| drop 121 redundant `val`/`ival`/`eval_*` calls | emit `emit.mpl` 48.1s → 41.4s (**~14%**) | yes |
| intrinsic fast path (cache a call site's resolved builtin) | correct and removes 379M of 504M resolutions (`lookup` 40.9% → 27.6%); **wall-clock benefit not pinned down** — see below | yes |

## §5.4's identity calls — how many are actually needed

§5.4 derefs a reference **wherever a value is expected** (call arguments,
projection targets, `$match` scrutinees, `$set`'s RHS, `$new`'s operand) and
keeps it in three places: function results, `$decl` initializers, block fields.
The prelude's `ival`/`sval`/`val`/`tval`/`eval_*` are the escape hatch for those
three — and `val` was the most-called function in the compiler at **979M**.

Measured, not assumed: of 223 call sites, **121 were redundant**. A cell or a
boxed field passed straight to a call needs no deref, because the argument
position already provides one — verified directly:

| written | result |
|---|---|
| `$call bump (c)` where `c` is `$mut $alloc 5` | 6 |
| `$call howlong (cell)` where `cell` is `$mut $alloc ints.node` | 1 |
| `$call howlong (two.tail)` — boxed field, no `val` | 1 |

They were concentrated in the recursive list walks (`find_mod`, `find_spec`,
`find_mprop`, `find_mdone`, `find_tmpl`), which called `val` on their own tail at
every step — which is why the count reached a billion. What remains is the case
that genuinely needs it: a helper returning a boxed field from one arm and a
value from another otherwise types as `<&T, T>` and every caller fails.

Still open as a language question: whether that residue deserves a form (`$val e`)
rather than a library call, so the cost is legible instead of hidden.

## The intrinsic fast path

§2.1 makes an intrinsic an ordinary shadowable name, so every `$call eq_int
(a, b)` resolved `eq_int` up the scope chain to the **root scope** — the last
link, holding ~80 intrinsics as slots, scanned linearly. With 379M of 504M calls
being intrinsics, that was the dominant cost of the whole interpreter.

`prim_cache` remembers what a call site's callee resolved to. Sound because
§4.10 makes visibility *positional*: a node sits at one position, so the
bindings in scope where it evaluates are the same on every evaluation — a
`$func` body resolves against its finished block, an initializer against what
precedes it. `MORPHL_VERIFY_PRIM=1` re-resolves on every hit and fails on a
mismatch; clean over `prelude`, `lexer`, `parser`, `types`.

What it is worth in wall time is **unresolved**, and three separate attempts to
pin it disagreed:

| workload | without | with | ratio |
|---|---|---|---|
| `types.mpl` (42.5M calls, 0.05 GB) | 18.0–20.0s | 14.9–16.3s | **1.24x** (tight, repeatable) |
| `emit.mpl` (504M calls, 0.36 GB) | 47.9–54.2s | 1.3–16.7s | 3x–37x (wildly variable) |
| whole compiler (3 GB) | 24–28 min | 27m24s | **~1.0x** |

Every one of those runs was output-validated; the `emit.mpl` runs were checked to
`md5` and are byte-identical to the uncached output, exit 0, empty stderr — the
fast ones really do the work. Things ruled out: build differences (the last A/B
used **one binary** and a runtime flag), drift (interleaved), a large fixed cost
(`emit_c` on a one-line file is 0.01s and 3,126 calls).

What does not add up: `types.mpl` runs 42.5M calls in 18s (2.4M/s) while
`emit.mpl` runs 504M in 50s (10M/s) — the same interpreter four times slower per
call on the smaller workload. Until that is understood, no speedup figure from
`emit.mpl` should be quoted. **Treat the fast path as worth ~1.2x**, on the
evidence of the one workload whose timings are stable, and note that the whole
compiler — the case that matters — shows nothing, because it is memory-bound.

`perf` also failed here: a matched pair gave `lookup` 40.9% → 27.6%, implying
~1.17x, which happens to match `types.mpl` but not `emit.mpl`. Under
`--call-graph=dwarf` perf copies 4 KB of stack per sample; whether that distorts
these shares was not established.

## The front end compiles and runs (`stage1/front.mpl`)

§9.1's pipeline stopped at `infer` — parse + infer, no `lower`, no `ir` — as a
program, with its input embedded so the answer depends on nothing outside. It
emits, compiles under `cc -O0 -Werror`, runs, and **agrees with stage 0**.

| | |
|---|---|
| emit | 7m37s, 0.62 GB |
| output | 28,341 lines of C |
| `cc -O0 -Werror` | clean |
| answer | **3**, the same as stage 0 |
| emit diagnostics | 1 (§6a declining to contify a group whose members differ in signature) |

It took two miscompiles to get there, both of which had been sitting under the
whole-compiler runs where nothing could see them:

- a `$prop` whose value is a `$union`, replayed on its second and every later
  projection as a zeroed struct — §7.5's discriminator reading 0, which selects
  the *wrong member*. The first projection was always right, so no fixture
  caught it and `verify` cannot: it "does not re-derive each node's type from
  its children".
- §3.3's top-level expressions never lowered at all, so `parser.mpl`'s §2.2
  arity table — twenty-three `$call add_kw (…)` — was empty in the compiled
  parser, which then knew no keyword.

The second is the one worth remembering as a *measurement* lesson: it was
invisible to every check stage 0 runs, because stage 0 evaluates those items
like any others. Only compiling and running the output found it.

## The differential shrinks the loop, and that is the lesson

Two miscompiles were found by compiling `stage1/front.mpl` (parse + infer) to C
and running it against stage 0. The **first** attempt cost 7–10 minutes an
emit, which is a terrible debugging loop and tempts you into guessing.

Cutting the driver down to what actually reproduced the bug cost one edit and
took the loop to **12 seconds**:

| driver | closure | emit | reproduces |
|---|---|---|---|
| `front.mpl` | prelude, lexer, parser, types, infer | 7m14s | yes |
| parse-only | prelude, lexer, parser | **11.7s** | yes |
| lexer-only | prelude, lexer | 4s | no (agrees) |

The lexer-only run is the half that matters: it *agreed* (33 tokens both ways),
which is what localised the fault to the parser without reading any code. Then
`Pa.dump_file` — the S-expression printer stage 0's parser also has — turned
"the answer is -8" into a tree to diff, and the diff named the bug outright
(`unknown keyword '$decl'`).

**Bisect the pipeline before bisecting the source.** A 35x faster loop is worth
more than any amount of staring, and the intermediate driver is five lines.

## Hypotheses tested and rejected

Recorded so they are not retried blind.

- `IR.find_ty`'s linear scan (hash made it *worse* at 94 types; at ~900 a stored
  digest measured no better — in stage 1 a list walk costs one call per cell
  regardless, so only *skipping* the walk can pay)
- `append_ty`'s O(n) rebuild (141s vs 135s)
- `T.unroll` as a hot spot *before* it was memoised (507 real unrolls of 4,480)
- `check_unique` (stubbed at full scale: still OOM)
- the μ-alias scan (identical block count with and without)
- the group-retry predicate (old self-only test also OOMs)
- module reloading as a leak (**exactly 2 loads per module**, no cascade)
- `lookup` scan width growing with program size (flat at ~16.8)
