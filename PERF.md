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
| `MORPHL_PROGRESS=<MB>` | **heartbeat**: one stderr line every `<MB>` allocated, and a `stopped:` line saying where a capped run died |

`perf record -g --call-graph=dwarf -F 199` on a ReleaseFast build for time.

## Watching a run instead of autopsying it

A final profile says where the bytes went. It cannot say where the run *was*,
which is the only question a capped run leaves — and for a long time the answer
to "how far did it get before it OOMed" was "nobody knows". `MORPHL_PROGRESS`
is that answer. It prints one line per `<MB>` allocated:

```
[progress]      64 MB  t=     7.1s (+  3.2s)  calls=     22054626  depth=  14  in ir.mpl:cons
[progress]      80 MB  t=    12.2s (+  5.1s)  calls=     35042159  depth=  83  in lower.mpl:blk_acc
[progress]     128 MB  t=    24.8s (+  6.4s)  calls=     70682031  depth=  46  in ir.mpl:cons
stopped: out of memory after 25.1s, 0.13 GB and 71529062 calls, 64 frames deep, in `free_names` (lower.mpl)
```

Three things make it worth the two lines it cost:

- **The `+` column is the time answer.** A stretch that takes 6.4s to allocate
  16 MB is doing a great deal of computation per byte; one that takes 1.6s is
  not. Slow phases are a gap in the column rather than something to infer.
- **The file, not just the function, names the phase.** The innermost frame is
  very often `cons` and says nothing; `lower.mpl:blk_acc` versus
  `types.mpl:with_goal` versus `emit.mpl:emit_args` says which half of §9.1 the
  run is in. It is the file the function was *written* in, taken from the same
  field diagnostics use.
- **`stopped:` is recorded at the failing allocation, not at the report.** By
  the time the profile prints, the stack has unwound and `current` is back at
  the top level. The snapshot is taken in the allocator, on the first refusal —
  everything after it is unwinding.

It costs one compare per allocation when off, and nothing measurable when on
(the `half` run below took 3548s against 3595s without it). To force a quick
test of the OOM path, *lower* the cap rather than finding a bigger input:
`(ulimit -v 200000; MORPHL_PROGRESS=16 … lower_dump.mpl stage1/front.mpl)` dies
in 25 seconds.

**One trap, found the hard way: `Io.File.stderr().writer()` is positional.** It
`pwrite`s from an offset of zero, while the heartbeat appends to fd 2 with a raw
`write` — it has to, since it runs inside the allocator callback where the `Io`
instance is out of reach. So the final profile wrote back over the start of the
file and ate the first **29 of 44** heartbeats, leaving a timeline that began at
1920 MB and looked like the feature had only started working late. `main.zig`
now uses `writerStreaming` for stderr, which shares the file offset so the two
interleave in the order written. Anything else that writes to a fd this program
also writes to must do the same.

## The whole compiler completes again — and the type count has quadrupled

`lower_dump.mpl` over `emit_c.mpl`, the transitive closure of everything:

| | at `7fd95b7` | today |
|---|---|---|
| result | completes | **completes** |
| allocated | 1.40 GB | **2.51 GB** |
| interned types | 1,470 | **6,348** |
| time | 19m25s | ~82m |
| | `check errors: 0`, `verify errors: 0` | `check errors: 0`, `verify errors: 0`, 1,122 functions |

It has been OOMing on every tree since `7fd95b7`. It completes again — but the
reason it was dying is now visible, and it is not the thing this file has been
chasing. **The type count went 1,470 → 6,348, a factor of 4.3.**

The per-module counts did *not* move. Re-measured on today's tree against the
figures recorded above:

| module | recorded | today |
|---|---|---|
| `ir` | 432 | 439 |
| `infer` | 865 | 865 |

So the type *language* is unchanged and no module grew. What grew is the
**combination** — and §4.9 is why that is possible: specialisation is memoised
per interned argument type, so anything that splits type identity splits every
specialisation built on it, and that only shows in a closure large enough to
instantiate the same list at both variants.

The prime suspect is §4.2a's `kind` on `t_ref`, which landed after `7fd95b7`:
`same` compares it (§5.3 makes `&T` and `&^T` different types, correctly), so a
list of `&T` and a list of `&^T` are two specialisations where they used to be
one. That is a hypothesis, not a measurement — the test is to count how many of
the 6,348 differ only in a ref's kind.

**This is now the biggest lever by a wide margin.** Allocation against type count
has an exponent of 1.6–3.5 in the table above; 6,348 → 1,470 would be worth more
than every fix in this file put together. It also explains why memory grew only
1.8x while types grew 4.3x: the T² term is gone, so the table no longer costs
quadratically to build. Without that fix, 6,348 types would have been **40M
`cons` calls in `append_ty` alone**.

One reading note on the timeline: the last two heartbeats (+353s at depth 373,
then +613s at depth 2 in `ir.mpl:show`) are the post-lowering passes and then
`lower_dump` rendering its output — not the compiler.

## `half` completes: parse + infer + lower under the cap

§9.1 up to `check`, as a program — the driver that had never finished.

| tree | result |
|---|---|
| before this work | **OOM at 29m20s** |
| + `append_ty` as a banker's queue | OOM at 59m (~60% further into the program) |
| + `with_props` cached on the module (`penv`) | **completes: 75m40s, 2.68 GB** |
| + `put_mod` sharing the untouched tail | **completes: 75m21s, 2.22 GB** |

Three fixes, all the same shape — a table rebuilt in full to change one entry —
and all measured before and after:

| | `front` | `half` |
|---|---|---|
| before | 0.60 GB / 402s | OOM |
| `append_ty` banker's queue | 0.50 GB / 438s | OOM (60% further) |
| `with_props` → `penv` | 0.46 GB / 437s | 2.68 GB / 75m40s |
| `put_mod` shares the tail | **0.41 GB / 441s** | **2.22 GB / 75m21s** |
| total | **-32% for +9.7% wall** | **OOM → 2.22 GB of 3** |

`put_mod` itself went 81.94 MB → **29.54 MB** across the same 7,175 calls. Not
the whole 81.94, which says the average position is about a third into the table
rather than near the head — `note_prop` is not always touching the most recently
registered module. The fix cannot be worse than the old one either way, since
`p <= M`.

The type count is **identical at 6,062** before and after, which is the check
that matters: these change how often a list is rebuilt, never what it holds.

```
check errors: 0   verify errors: 0   types: 6062   901 functions lowered
```

**The type count is the whole explanation, and it is 6,062.** The front end alone
interns 1,382 and `lower.mpl`'s own closure 1,244 — the union is **2.3x their
sum**, because §4.9 monomorphises per argument type and the combined closure has
far more distinct list element types than either half. That is why `half`
behaved like the whole compiler rather than a midpoint, and why predicting from
lines was off by twenty-five fold.

It also settles why `append_ty` mattered so much more here than on the front
end. At T = 6,062 its old `sum 2k` rebuild is **36.7M `cons` calls by itself** —
more than the *entire* front-end run's 8.98M — where at T = 1,382 it was 1.9M.
A term that is quadratic in the type table is invisible on small inputs and
decisive on large ones, which is exactly the shape that makes it easy to test on
the wrong workload and dismiss.

The last heartbeat before the end is worth noting: the final 128 MB took
**540.6s against a steady ~250s**, at a call depth of **707**. That is the
post-lowering passes (`mark_self`, `collect_edges`, `find_groups`) at n = 901,
and the depth says something there recurses deeply. Not chased yet.

## What is actually left in lowering, ranked by the right instrument

`front`, with `MORPHL_CALLS=1` — the ranking that catches a scan which does not
allocate, and therefore the one the byte profile cannot give. 1,057,535,768 calls:

| function | calls | share |
|---|---|---|
| `eq_int` | 420,783,338 | **39.8%** |
| `same` | 178,279,446 | **16.9%** |
| `eq_str` | 157,696,965 | 14.9% |
| `same_fields` | 102,205,576 | 9.7% |
| `add` | 93,547,122 | 8.8% |
| `cv_eq` | 26,567,251 | 2.5% |
| `mem_ty` | 20,232,320 | 1.9% |
| `cons` | 6,809,557 | **0.6%** |
| `reaches` | 1,359,584 | **0.13%** |

`cons` is 77% of the *bytes* and 0.6% of the *calls*. Type comparison — `same`,
`same_fields`, `cv_eq`, `mem_ty`, `same_tys` — is **329M calls, 31%**, and it is
what drives most of the `eq_int`/`eq_str` above it. That is `find_ty`'s linear
scan: 169,607 interns against a table averaging ~691 entries.

Lowering's quadratic terms, all of which key off a table that grows with the
**whole program** rather than with the file being lowered:

| term | cost | status |
|---|---|---|
| `append_ty` — table rebuilt per new type | O(T²) allocations | **fixed** |
| `find_ty` — table scanned per intern | O(I·T) comparisons | live, **~31% of calls** |
| `put_mod` — module list rebuilt per prop state change | O(M · saves) | live, **17.8% of memory** |
| `put_lifted` — lifted list rebuilt **3x** per lifted function | 1.5·n² allocations | live, est. 7% of cons |
| `find_groups` — n² reachability pairs, and `and` is strict so both run | O(n²·E) | live but **negligible** |
| `lookup` — benv scan | flat at ~16.8 (measured) | linear |

**`find_groups` is the cautionary one.** Reading the source, it is n² pairs and
§7.1's strict `and` doubles the queries — and the measured call count,
1,359,584, matches that structure almost exactly (2 x 572² x 2). The structure
was right and said nothing useful: each query returns immediately because the
edge list is short, so the whole thing is 0.13% of the run. Predicting the count
from the shape is easy; predicting the cost is not.

**`put_mod` is the real one.** 81.94 MB across 7,175 calls — 17.8% of the run
and 22.5% of all cons bytes. Its comment says "the table is small — one per
block with props"; it is **865 modules** for the front end alone, rebuilt in
full every time `note_prop` changes one entry's `done` field. Same shape as the
two already fixed.

## Where `half` actually spends its hour

The surviving tail of that run, at 64 MB a line — the first timeline this
project has had of a capped run:

| MB | t | +s | in |
|---|---|---|---|
| 1920 | 2100.6s | +100.5 | `lower.mpl:cons` |
| 2048 | 2308.3s | +106.2 | `lower.mpl:cons` |
| 2112 | 2417.6s | +109.3 | `ir.mpl:cons` |
| 2368 | 2832.4s | +100.4 | `lower.mpl:bind_ent5` |
| 2560 | 3129.4s | +99.6 | `lower.mpl:cons` |
| 2752 | 3440.3s | +103.5 | `lower.mpl:lres` |
| 2816 | 3545.8s | +105.4 | `lower.mpl:bind_ent5` |

```
stopped: out of memory after 3548.1s, 2.75 GB and 8130645297 calls,
         129 frames deep, in `cons` (ir.mpl)
```

Four things this says that a final profile could not:

- **The back half of the run is flat, not decelerating.** Every step from 1920
  to 2816 MB costs 98–109 seconds, i.e. 0.63 MB/s, with no trend. The whole run
  *does* decelerate — the first 1920 MB averaged 0.91 MB/s — but by this point
  the quadratic terms have stopped growing relative to the work.
- **All fifteen samples are in `lower.mpl` or `ir.mpl`.** Parse and infer are
  long finished; the hour is lowering, and nothing else.
- **3.27 billion calls for 896 MB — 3.65M stage-1 calls per megabyte.** That is
  the number to beat, and it is a *rate*, which the totals could never give.
- **`bind_ent5` is the innermost frame in 3 of 15 samples** — which is a *hint*
  and not a measurement, and the distinction matters. Fifteen samples is far too
  few to read 3/15 as "20%"; the byte profile from the same run says `bind_ent5`
  is **172.37 MB, 6.1%**, and that is the number to use. What the heartbeat is
  good for here is direction, not magnitude: it put a four-line `benv`
  constructor in the frame often enough to be worth looking at, and the byte
  profile then says it is the third-largest row. Counting the `benv` cons cells
  with it, the environment is ~11% of the run.

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

## The type table was quadratic (`append_ty`)

§9.3's table is append-only and indexed, and appending to an index-ordered
immutable list was `reverse (cons (t, reverse (xs)))` — two full rebuilds per
**new** type. Over a program with T types that is `sum 2k` = **T² cons cells**,
and the table is the one structure that grows with the *whole* program rather
than with the file being lowered, which is why it read as superlinear the
moment another module joined the closure.

The prediction and the measurement agree to 0.15%, which is the useful part:

| front end (T = 1,382) | before | after |
|---|---|---|
| allocated | 0.60 GB | **0.50 GB** |
| `cons` calls | 8,981,698 | **7,077,228** |
| reduction | — | **1,909,924** |
| predicted (`sum 2k`, k < 1382) | — | 1,907,000 |

**The obvious repair costs 30% in time, and the reason is worth keeping.**
Holding the table newest-first makes the append one cell and reads index `i` of
`n` at position `n-1-i`. But `find_ty` *scans*, and the types asked for
constantly — `Int`, `Str`, unit, the booleans — are interned **first** and so
have the smallest indices. Newest-first moves exactly those from the head of
the scan to its tail: 145,860 of the front end's 147,242 lookups are hits, and
they went from position ~10 to ~1,372. That is 200M extra comparisons against
the 248M extra calls measured. The first diagnosis blamed `ty_at`; both moved,
but the scan is the big one.

So the table is a **banker's queue**: `tsettled` oldest-first holding indices
`0..nsettled-1`, `tpend` newest-first for O(1) append, merged when pending
outgrows settled. `nsettled` doubles at each merge, so the merges total
`1 + 3 + 7 + … ≈ 2T` cells over the run instead of T², and `find_ty` scans
settled first, putting the hot types back at the head.

| front end | baseline | newest-first | banker's queue |
|---|---|---|---|
| allocated | 0.60 GB | 0.50 GB | **0.50 GB** |
| time | 402s | 521s | **438s** |
| total calls | 1.028G | 1.276G | **1.059G** |
| types | 1,382 | 1,382 | 1,382 |

87% of the time regression comes back and all of the memory win stays. The
emitted C for all 21 fixtures is byte-identical throughout, both straight and
through `fold` — which is the check that matters, since the indices the table
hands out must not change.

**`half` still does not fit, and that is the finding.** Both the old and the new
run consume the full 3 GB, so the honest comparison is how far each got. The
lexer is the control — a fixed cost for the closure, and it is the same in both:

| at the wall | original | banker's queue |
|---|---|---|
| `advance` (lexer) | 650,151 | 657,927 (+1.2%) |
| `find_ty` | 522,075 | 828,621 (**+59%**) |
| `bind_ent5` | 1,068,101 | 1,737,887 (**+63%**) |
| `lres4` | 421,666 | 635,268 (**+51%**) |
| time to wall | 1760s | 3595s |
| `cons` share | 87.5% | 82.1% |

So the same 3 GB now buys **about 60% more of the program lowered** — a much
bigger effect than the front end's 17%, because the T² term grows with the
closure and so hurts most where the closure is biggest. It is still not enough,
and what is left is what this file already named: `cons` at 82.1% and 44.2M
`{head tail}` cells. Linked lists, not the type table.

## Hypotheses tested and rejected

Recorded so they are not retried blind.

- `IR.find_ty`'s linear scan (hash made it *worse* at 94 types; at ~900 a stored
  digest measured no better — in stage 1 a list walk costs one call per cell
  regardless, so only *skipping* the walk can pay)
- `append_ty`'s O(n) rebuild — **this rejection was wrong**, and it is the best
  example in this file of the wrong instrument. It was tested on the *clock*
  (141s vs 135s) and dismissed, but the cost was never time: it was T² cons
  cells, a fifth of everything a run allocated, and the binding constraint is
  the cap. See "The type table was quadratic" below.
- `T.unroll` as a hot spot *before* it was memoised (507 real unrolls of 4,480)
- `check_unique` (stubbed at full scale: still OOM)
- the μ-alias scan (identical block count with and without)
- the group-retry predicate (old self-only test also OOMs)
- module reloading as a leak (**exactly 2 loads per module**, no cascade)
- `lookup` scan width growing with program size (flat at ~16.8)
