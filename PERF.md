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
  run is in. It is `Func.file`, which `makeFunc` takes from `current_file` when
  the closure is built — so for an ordinary function it is where it was written,
  and for a `$prop` of a **specialised template** it is the specialisation site,
  since §4.9 re-evaluates the body there. Hence `lower.mpl:cons` rather than
  `prelude.mpl:cons`, which is the more useful reading: it names whose data
  structure is being built.
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

## Why the type table grows: §5.5 placeholders are interned and never removed

Dumping the interned table and grouping the renderings says it outright. A
`v<N>` is a §5.5 placeholder; `fresh_var` mints a new id per derivation and
`T.same` compares ids, so `&^v26` and `&^v41` are different types that can never
share an entry:

| table | types | contain `v<N>` | share | duplicates modulo the id | share |
|---|---|---|---|---|---|
| `ir` | 439 | 128 | 29.2% | 76 | 17.3% |
| **`front`** | 1,382 | **722** | **52.2%** | **652** | **47.2%** |
| `lower` | 1,253 | 330 | 26.3% | 213 | 17.0% |

Over half of the front end's table holds a placeholder, and **47% of the whole
table is exact duplicates of each other differing only in an id** — thirty-five
separate entries for `&^v?`, seventeen copies of one cons cell, seventeen of one
list type.

Nothing removes them. `intern` is unconditional, and `take_snap`/`put_snap` roll
back the lifted functions, modules, specialisations and templates around a
discarded first pass but **not the table** — so every discarded derivation
leaves its placeholder types interned permanently. The count therefore tracks
the *number of derivations*, not the program.

That is also why closures are superadditive. By set arithmetic on the dumps:

```
front 1382 + lower 1253, shared 461  ->  UNION = 2174
half actually interned 6062          ->  3888 types exist in NEITHER alone (64%)
```

### The obvious fix does not work, and the reason is worth keeping

Canonicalising every placeholder-bearing type to one entry in `intern` (with
`canon_ty` answering for itself, since such a type has no representative). The
`ty_placeholder` stand-in was itself a `var`, so `has_var` stayed true of it and
`emit_structs`/`c_type` kept their existing skip-and-refuse behaviour.

The table shrank exactly as predicted — **`ir` 439 -> 341 (-22%), `lower`
1,253 -> 1,019 (-19%)** — and `lower.mpl` gained **three check errors**:

```
no field 'inner' common to every member of this union (§5.1)   x2
no field 'kind'  common to every member of this union (§5.1)   x1
```

Those come from `lower_proj`'s union case, which means a `$match` **narrowing
failed**: the scrutinee stayed a union where it should have narrowed to a `ref`.
So something reads a placeholder type *back from its index* and depends on its
structure — `fn_ty` reconstructing a function type from its param and result
indices is the most likely path, though which site was not established.

**The interned entry for a placeholder type is load-bearing even though the type
never reaches a layout.** Reverted.

The design that should work is a **side table**: keep placeholder types interned
exactly as today, so `ty_at`, `fn_ty` and `canon_ty` read back precisely what
they do now, but hold them apart from the main table that `find_ty` scans and
`emit_structs` walks. That halves the scan — which is where the 31% of calls
goes — without changing a single answer.

## `mplc` — and what stage 2 is worth in practice

§8's `at`, `alen`, `array` and `args` had no C backend, so no driver could be
emitted at all. With them in, `stage1/mplc.mpl` is a real command-line compiler.

**It was built without stage 0 in the loop**, which is the point. The existing
stage 2 was compiled from the *old* backend and cannot emit `args` — but it
compiles the *current* source, so it can build an array-capable successor,
provided what it emits does not itself use `args`. `selfc.mpl` reads `./target`,
so it does not:

| | | |
|---|---|---|
| `stage2c` emits `selfc.mpl` | 163s | -> `stage2b`, 712,200 bytes, has the array backend |
| `stage2b` emits `mplc.mpl` | 163s | -> **`mplc`**, 712,160 bytes |

Six minutes. The same two steps through stage 0 would have been three hours.

What it is worth on real inputs:

| input | `mplc` | stage 0 | output |
|---|---|---|---|
| `stage1/lexer.mpl` | **<1s** | — | 3,370 lines, md5 `4eb88bb4…` — **identical** |
| `stage1/types.mpl` | **1s** | **15s** | 9,387 lines — **identical** |
| `stage1/selfc.mpl` | 162s | ~5400s | 64,551 lines, and the C builds a working compiler |

The last row is the strongest check in the set. `mplc` emitting the compiler's
own driver differs from what the *old* backend emitted for the same source by
**12 diff lines in 64,551** — and all twelve are the intended change, the five
runtime lines for `mpl_argc`/`mpl_argv` and the three for the new `main`.
Nothing else moved.

**The 15x on `types.mpl` against 33x on `selfc.mpl` is worth noting.** The small
input pays stage 0's fixed ~11ms startup and `mplc`'s own process start against a
much smaller body of work, so the ratio compresses. Large workloads show the real
figure; small ones understate it.

## Stage 3 reached: the compiler is a fixed point

BOOTSTRAP's last gate is *"Stage 2 and stage 3 output identical byte-for-byte."*

| step | | |
|---|---|---|
| stage 0 emits `selfc.mpl` | 5390s, **1.15 GB** | 63,906 lines |
| `cc -O2` | | 708,016-byte binary = **stage 2** |
| **stage 2** emits `selfc.mpl` | **164s** | 63,906 lines |
| `cc -O2` | | 708,016-byte binary = **stage 3** |
| **stage 3** emits `selfc.mpl` | **178s** | 63,906 lines |

```
ba8e65e7b6ae1e0a2e350ecd3c30c0ef  selfc.c      (stage 0, interpreted)
ba8e65e7b6ae1e0a2e350ecd3c30c0ef  s2_self.c    (stage 2)
ba8e65e7b6ae1e0a2e350ecd3c30c0ef  s3_self.c    (stage 3)
```

All three agree, not just the two the gate asks for — so stage 2 also reproduces
the interpreter exactly on a 63,906-line output. The two binaries are identical
once compiled from the same *filename* (md5 `5794b478…` both ways); the earlier
difference was gcc embedding the source path. And stage 3 independently
reproduces the `lexer.mpl` reference from earlier, md5 `1ccce388…`, 3,365 lines.

**The correction worth recording: stage 3 is `cc(stage2(selfc.mpl))`, not
`cc(stage2(compiler.mpl))`.** The first attempt linked the library and got
`undefined reference to 'main'` — which is exactly what the "no top-level `$decl`
named `main`" diagnostic has been saying on every whole-compiler emit, correctly
dismissed as "not an error for a library" while simultaneously being handed to
the linker. `compiler.mpl` is §9's pipeline *as values*; the thing that is a
program is the driver, and the driver is what stage 2 *is*.

Cost of the trip, for scale: stage 0 needs **5390s** for this emit and stage 2
needs **164s** — **33x**. The 90-minute measurement cycle that shaped this entire
file is now three minutes.

## Where the compiled compiler's memory actually goes

The emitted runtime calls `mpl_alloc(sizeof(mpl_tN))` at every `$new`/`$alloc`,
so **the allocation size names the type**. Instrumenting `mpl_alloc` with a
size histogram and dumping it from `mpl_panic` — five minutes of work on the
generated C — said it outright. 20.78M allocations, 3.62 GB before the bound:

| size | calls | MB | share | what it is |
|---|---|---|---|---|
| **136** | **14,565,500** | 1,889.1 | **51.0%** | `IR.fns.node` — element `IR.fn`, 8 fields, three list nodes inline |
| **>=512** | **3,344,453** | 1,636.4 | **44.2%** | `mods_list.node` — element `mod_ent`, 7 fields, three list nodes inline |
| 64 | 983,375 | 60.0 | 1.6% | |
| 120 | 229,995 | 26.3 | 0.7% | |

Two types out of 644 are **95% of everything**, and each has exactly two
allocation sites, both reached through prelude's `cons`. Field-for-field the C
structs match `IR.fn` and `mod_ent`, which is how they were identified.

Note the shape of the difference from stage 0: compiled makes **fewer**
allocations (20.8M against 46.7M) and each is far **fatter**. Inlining trades
count for width.

### The two fixes

- **`put_lifted` was 1.5L² cells.** It turned `st.lifted` around, replaced one
  entry, and turned it back — three full rebuilds of the function table per
  lifted function, the same defect as `append_ty` and `put_mod` and the one
  left unfixed. `st.lifted` is newest first and `reserve_lifted` hands out the
  index immediately before, so the entry is at **position 0**: copy the prefix,
  share the tail, and the common case costs nothing.
- **`mod_ent`'s four list fields are boxed.** §7.2 inlines a block's fields and
  §7.5 sizes a union to its widest member, so a field holding a list embeds the
  whole node, and a node is `element + 16`. Inline, `done`/`env`/`penv` are 120
  bytes each and the entry is 496; behind `$alloc` they are 8 and it is 72 —
  **5.8x smaller**. Stage 0 never showed this because it boxes anyway: a `Value`
  is 16 bytes and anything wider goes behind a pointer, so its cons cell is 64
  bytes whatever it holds.

Both are behaviour-neutral, checked three ways: 150/150 and 100/100, all 42
fixture `cc` steps cached, and the emitted C for `ir.mpl` **byte-identical**
(11,445 lines) before and after. And both help stage 0 as well —
`lower_dump.mpl` over `lower.mpl`:

| | before | after |
|---|---|---|
| allocated | 0.23 GB | **0.19 GB** |
| time | 433s | **372s** |
| calls | 1,056,123,458 | **883,647,116** |

**The generalisable part: a stage-1 memory question is answered on the compiled
side, not the interpreted one.** Stage 0's own profile cannot separate list
specialisations — they all share prelude's single `cons` literal, so its
histogram lumps 41M cons cells into one `{head tail}` row. The compiled C
separates them by *size*, because inlining makes each specialisation a distinct
struct. The instrument that found this does not exist on the stage-0 side and
could not.

## Stage 3 is blocked, and the blocker is §7.5's layout meeting BOOTSTRAP §3

The reusable stage-2 compiler exists: `stage1/selfc.mpl` reads its target from
the file `./target`, so one binary emits C for any input without `args` (which
has no backend). Stage 0 emitted it in 85m30s / 2.65 GB as 63,843 lines, and
`cc -O2` produced a **708 KB** binary — against 2.07 MB at `-O0`. Verified under
stage 0 first: byte-identical to the reference for `lexer.mpl`.

Then it cannot emit `compiler.mpl`:

| bound | result |
|---|---|
| 4 GB | `mpl_panic("out of memory")` after 116s |
| 7 GB | `mpl_panic("out of memory")` after 239s |

**Stage 0 does the same job in 2.65 GB; compiled needs more than 7 GB.** The
cause is representational and measured, not a leak. §7.5 lays a union out as
`struct { int64_t tag; union { …all members… } }` **sized to its largest member**,
and §7.2 puts a block's fields inline — so a `P.list` cons cell holds its element
*by value*. Measured across the 32 list-node types in the compiled compiler:

| compiled list node | bytes | element |
|---|---|---|
| widest | **512** | 496 |
| next | 224 | 208 |
| next | 200 | 184 |
| median tagged union | 48 | — |
| **stage 0, any element** | **64** | boxed to 16 |

The relation is exactly `node = element + 16` — tag plus tail pointer. So the
widest list costs **8x** stage 0 per element, and cons cells are ~88% of all
allocation.

**Stage 0's boxing is what keeps its memory down.** A `Value` is 16 bytes and
anything wider goes behind a pointer, so a cons cell is 64 bytes whatever it
holds. The compiled form inlines instead — which is what makes field access free
and is the right call for speed — and with `malloc`-and-never-free (BOOTSTRAP §3)
that width is never reclaimed.

So **§7.6's regions are now on the critical path for stage 3**, having been
deferred on the grounds that stage 0 does not free either. That reasoning held
while the interpreter was the only consumer; it does not survive the compiled
side being 2.6x hungrier.

Two cheaper moves before regions, both source-level:

- **Box the wide elements.** CLAUDE.md already says "box the *list*, not its
  elements" for the recursion rule; the memory argument now points the other way
  for *wide* elements specifically. A cons holding `&^T` instead of `T` is 24
  bytes instead of 512 for the worst case here.
- **Narrow the wide unions.** The 496-byte element is one of the big ones —
  `ir.mpl`'s `proto_expr` has 23 members, and a union is as wide as its widest.

Neither is needed for stage 2, which is met. Both are needed for stage 3.

## Stage 2's gate is met: byte-for-byte

`stage1/self_emit.mpl` is §9's pipeline through `emit`, and `main` returns the
emitted C and nothing else — so stdout *is* the artifact and can be diffed.

| | |
|---|---|
| emit the driver | **87m42s, 2.65 GB**, 63,744 lines of C |
| `cc -O0 -Werror` | 0 errors, **2,065,320-byte binary** |
| stage 2 emits `stage1/lexer.mpl` | **3,365 lines / 71,854 bytes, in ~1s** |
| against stage 0's output | **byte-for-byte identical** |
| stage 2's own C, fed to `cc` | 0 errors |

Three independent paths agree on one MD5 — `1ccce388fb21a06154ffd9836003627c`:
stage 0 through `emit_c.mpl`, stage 0 through this driver, and the compiled
stage-2 binary. A fresh re-run of the binary reproduces it again.

That is BOOTSTRAP's stage-2 gate in full: *"Typechecks its own source; binary
reproduces stage 1's behavior."* Two executions of identical stage-1 source — one
interpreted by Zig, one compiled to native code through 63,744 lines of generated
C — agreeing on all 71,854 bytes of a non-trivial output.

On this workload stage 2 is **~20x**: 32.8ms against 652ms.

**What stage 3 needs, and why it is suddenly cheap.** The gate is "stage 2 and
stage 3 output identical byte-for-byte", which means stage 2 has to emit C for
`compiler.mpl` rather than for `lexer.mpl` — a one-line change to the driver's
literal path, or `args` in the backend. And at 20x, the emit that takes stage 0
**88 minutes takes stage 2 about four**. Every measurement in this file has been
gated on 7-to-90-minute runs; that constraint is about to disappear.

## Stage 2 runs, and the interpreter was worth 23x

`stage1/self.mpl` is §9's pipeline — `parse` -> `check` -> `verify` — as a program
with **no `args`**: the input path is a string literal, so nothing in it needs
`args`/`at`/`alen`, none of which has a C backend. §8's `read_file` *is* emitted,
so the file is read at run time like any other.

| | |
|---|---|
| emit | **88m42s, 2.65 GB** (cap 3.00) |
| output | **63,832 lines of C** |
| emit diagnostics | **3** — the three §6a groups whose members differ in signature. "No `main`" is gone: this driver has one |
| `cc -O0 -Werror` | **0 errors** |
| binary | **2,069,544 bytes** |
| answer on `stage1/lexer.mpl` | **91** functions lowered, 0 check errors, 0 verify errors |
| stage 0's answer | **91** |

So a natively compiled morphl compiler read 369 lines of real morphl off disk,
resolved its `$import`, inferred it, lowered it and verified the result — agreeing
with the interpreter exactly.

**And then the number this file exists for:**

| | time |
|---|---|
| stage 0, interpreted (3 samples) | 0.615 / 0.614 / 0.608s |
| stage 2, compiled (20 runs) | 0.535s total — **26.8ms each** |
| stage 0's fixed startup alone | 0.011s |

**~23x.** The estimate here was 5x: `lookup` + `eval` + `bindParams` +
`callValue` + `evalArgs` measured ~80% of interpreted time, and removing 80%
caps you at 5x. It came out at 23x because eliminating the interpreter does not
only delete that 80% — it makes the rest faster too. Compiled code indexes a
frame slot where stage 0 walks a scope chain comparing names (§7.2), holds a
record as a C struct by value where stage 0 allocates a `Block` and boxes its
values, calls directly instead of through `callValue`, and gets `cc`'s register
allocation on top. **80% of the profile was the interpretive machinery; it was
not 80% of the cost.**

One more note on the startup figure: 11ms, not the seconds one might assume from
"stage 0 parses all 8,327 lines of stage 1 at `$import` time". Parsing is cheap
— it is 15 MB of allocation at Zig speed. Interpreting is what costs.

What this is *not*: stage 2 stops at `verify`, so it cannot yet emit C and there
is no stage 3. And the driver's path is a literal, so a real command-line
compiler still wants `args`/`at`/`alen` in the backend.

## Stage 2's gate: the compiler compiles itself

`emit_c.mpl` over `compiler.mpl` — every module, transitively — then `cc` on the
result:

| | |
|---|---|
| emit | **90m40s, 2.62 GB** (cap is 3.00) |
| output | **63,599 lines of C** (55,590 at `7fd95b7`; the compiler has grown 14%) |
| emit diagnostics | **4**, all documented: "no top-level `$decl` named `main`" (not an error for a library) and three §6a groups whose members differ in signature |
| `cc -O0 -c` | **0 errors, 0 warnings** |
| object | `compiler.o`, **2,173,408 bytes**, **1,131 functions**, 642 structs, 16 undefined symbols — all libc |

Three bugs stood between the previous state and this, and all three were found by
*running* it rather than by reading:

- **`alias_at` and `emit_fwds` were not tail-recursive.** Both walk the whole type
  table with the recursive call inside a `$decl` block, and §7.7 makes that a real
  frame. They nest — `emit_fwds` holds a frame per entry *and* calls `alias_of`,
  which holds another — so 6,348 types became **8,763 nested calls and 48 MB of a
  64 MB stack**, and the run died with `call depth limit exceeded`, not OOM, at
  2.48 GB. CLAUDE.md warns about this shape twice; neither site had ever been deep
  enough to trip it until the type count quadrupled. Fixed by lifting each body
  into a helper (`alias_hit`, `emit_fwd1`).
- **`lower_top` re-bound a module with inference's type.** §4.14 makes a module a
  namespace with no layout, so lowering gives it the empty block, while inference's
  type still lists every member as a field — right for checking, not a layout.
  §9's own re-exports (`$decl ir IR`, `$decl types T`) therefore emitted a thunk
  declared to return the member block and returning the empty one. Those were the
  **only two `cc` errors in 63,609 lines**. It now binds `ty_at (st, f.result)`.

**The stack limit is a first-class constraint now, alongside the memory cap.** At
6,348 types, any O(n) non-tail walk over the type table costs ~35 MB of the 64 MB
interpreter stack, so the margin is thin by construction. A capped run reports
`OutOfMemory`; a deep one reports `call depth limit exceeded` and names the file
and line — read which one you got before reaching for memory.

What is still missing for a *runnable* stage 2 is not optimisation: every driver
opens with `$call args ()` / `$call at (argv, 0)` and none of `args`/`at`/`alen`
has a C backend. `front.mpl` shows the way round it — it embeds its input as a
string literal, and `read_file` *is* emitted — so a driver with a literal path
needs no new intrinsic at all.

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

## Five ways these measurements have lied

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
5. **A stage-1 change is compiled by stage 1, so measure it on a workload that
   contains the file you edited.** `front` does not compile `lower.mpl` and
   reported −8.8% of calls; `lower` and `half` do, and reported +9.5% and +35%.
   Measure both ways, always. (In that case the cause turned out *not* to be the
   added code — see "The side table" — but the asymmetry is real and would hide
   any regression that was.)

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

## The side table: rejected, and the reason generalises

The idea was sound and the measurement on the wrong workload said so. §9.3's
table answers two questions — "what is type `i`", which must be dense and
positional, and "have I seen this type", which needs no position because an
entry can carry its own index. Splitting them lets a scan skip the §5.5
placeholders, which are 52.2% of the front end's entries and can never match a
real type. Placeholders kept their own entries and indices, so unlike the
canonicalising attempt above nothing read back differently: `ir` stayed at 439
types with zero errors and all 42 fixture `cc` steps stayed cached.

| workload | contains `lower.mpl`? | calls | time |
|---|---|---|---|
| `front` | no | **−8.8%** | **−8%** (441s → 406s) |
| `lower` | yes | **+9.5%** | **+13%** (433s → 489s) |
| `half` | yes, + superadditively | **+35%** | **+40%** (at equal allocation) |

The first version stored `{index, type}` pairs, which cost one
`$specialize P.list proto_tyent` and **+28 types in `lower.mpl`** (1,253 →
1,281). The obvious diagnosis was that §4.9 monomorphises the optimisation's own
source into the closure being measured, so it pays for itself twice.

**That diagnosis was wrong, and the second version proved it.** Storing the same
thing as two *parallel* lists of `T.tys` and `IR.ints` — both already in the
file's surface — took the added types from 28 to **4**, and changed the
regression by nothing:

| variant | `lower` types | `lower` calls | `lower` time | `front` calls | `front` time |
|---|---|---|---|---|---|
| baseline | 1,253 | 1,056,123,458 | 433s | 1,056,067,752 | 441s |
| `{idx,ty}` pairs | 1,281 (+28) | +9.5% | **+13%** | −8.8% | −8% |
| parallel lists | 1,257 (**+4**) | +10.6% | **+12.7%** | −6.1% | −6% |

So the added code was never the cause. The real one is that **the partition's
benefit scales with the placeholder fraction, and break-even is near half**:

| closure | placeholders | result |
|---|---|---|
| `front` | 722 / 1,382 = **52.2%** | **−6 to −9%** |
| `lower` | 330 / 1,253 = **26.3%** | **+10 to +13%** |

Partitioning removes half of `front`'s scan and only a quarter of `lower`'s,
while *any* partitioned structure costs more per entry than a plain walk — the
parallel version has to `$match` two lists in lockstep, roughly doubling the
per-entry work. Below ~50% placeholders that loses.

And the reason it loses so easily is the thing to remember: `T.same` **already**
rejects a placeholder in one tag check, so the entries being skipped were the
*cheap* half of the table all along. That was visible in the very first
estimate — predicted 15–20% of calls on `front`, measured 8.8% — and should have
been read then as "the mechanism is smaller than it looks" rather than as a
magnitude error.

Both versions reverted. The three fixes that worked (`append_ty`, `with_props`,
`put_mod`) all **removed work from an existing path** rather than adding a
structure to avoid work, which on this evidence is the shape that pays.

## §6a's last refusal, and why it was never a performance question

The three "a mutually tail-recursive group whose members differ in signature is
not contified yet" diagnostics were the only place a *documented* spec guarantee
did not hold in the emitted compiler: §7.7 makes TCE mandatory, and those groups
were emitted as ordinary functions, so a deep enough input would overflow the C
stack rather than loop. They are now contified through a general path — per-member
parameter variables and an out-parameter — and `mplc.mpl` emits **zero**
diagnostics where it emitted four, `compiler.mpl` the one that is not an error.

The groups were `sub_seen`/`sub_step`/`sub_ref` (`types.mpl`'s subtyping loop, a
parameter type differing) and `join_pass`/`join_two` plus `join_all`/`join_step`
(`emit.mpl`'s O(L log n) joiner, two and three parameters against one and three).
The joiner is split into four functions precisely so that "passing the tail as a
parameter keeps every call in tail position" — and that extra parameter is what
made the signatures differ, which is what disqualified the group. **The change
made to keep the recursion in tail position is what stopped the backend
eliminating it.**

The stack limit is not the instrument for checking this, and that is worth
recording: `mplc` and its predecessor both segfault on `types.mpl` at
`ulimit -s 512`, because the compiler's stack is dominated by legitimately
non-tail recursion over the AST and the IR, and three contified groups do not
move it. What shows the difference is a fixture built for it —
`mutual_sig.mpl`, 2,000,000 alternations at `-O0`: the old backend emits no group
function and the program overflows, the new one answers 9.

The regeneration also cost one extra round trip to a mistake worth naming.
`$mut $alloc P.boolean` is storage that starts **`true`**: §4.8a makes a `$union`
evaluate to its first member and `P.boolean` is `$union (true, false)`. The flag
that selects between the two contification paths started set, so every ordinary
function took the general path's variable naming. Nothing in the checker or in
`verify` can see it — the types are identical — and it surfaced as `q-2_0` in the
C, three minutes of compiling later. For a flag that must start false, write the
union in the order you want: `$mut $alloc $union (false, true)`.

Two measurement notes came out of the work.

**Finding them needed a compiled compiler, and a driver that could speak.** The
diagnostics only appear on a whole-compiler emit, which costs stage 0 about ninety
minutes; `mplc` does it in three, but `mplc` prints *only* C, because §8 gives
`print` (stdout) and `panic` (stderr, then abort) and nothing between — a warning
would corrupt the artifact. `stage1/emit_diag.mpl` is the same pipeline with the
diagnostics on stdout and the C discarded, and it turns a ninety-minute question
into a one-second one. Worth building early for anything that reads a diagnostic
at scale.

**The refusal's message named nothing, which is the lesson.** It said that *a*
group differed in signature and not *which*, so the only way to find out was to
re-derive the tail-call SCCs by hand. Adding the member names and their signatures
to the message was the first change made and the one that made the rest cheap.
A diagnostic that reports a category rather than an instance costs whoever reads
it the entire investigation.

## The initialisation-order bug, and why nothing caught it

`mpl_init` assigned the emitted statics in index order, and a global's index is
its position among the *entry file's* top-level `$decl`s — so the entry file's
globals were assigned before every lifted function, a module's members included.
§4.14 makes `$import` evaluate the module's block where it stands, so that is
backwards: a top-level `$decl` whose initializer called into an import read a
zeroed static.

The instructive part is the instrument. Nothing in the project could see it:

- **Stage 0 does not have the bug**, so every `.mpl` file in the tree ran
  correctly and every suite passed. "It runs under the interpreter" is worth
  nothing for an ordering question the interpreter decides differently.
- **`verify` could not see it.** It checks what the tree asserts about itself, and
  the tree asserted nothing about initialisation order until this change gave it
  `fnbase` to assert.
- **`cc -Wall` could not see it.** The C is well-formed; the statics are assigned,
  just late.
- **Every emit fixture passed**, because a fixture's answer comes from `main`,
  which runs after `mpl_init` finishes. Only a top-level `$decl` that *reads*
  across the boundary is affected, and no fixture had one.
- **The compiler's own driver is immune by accident.** `mplc.mpl` does everything
  inside `main`. So the whole bootstrap — stages 1, 2 and 3, byte-identical
  outputs and all — was built on top of it without noticing.

What found it was compiling a driver that had never been compiled before, and it
presented as a **segfault on a one-line input**. `stage1/fixtures/init_order.mpl`
turns that into arithmetic: 106 correct, 101 if the ordering regresses. Making it
arithmetic needed care — the module member has to be a non-`$func` `$decl`,
because a `$func` member is a plain C function and needs no initialisation, so
nothing would be observable at all.

The lesson worth keeping: **the differential is only as strong as the shapes it
covers.** Stage 0 against stage 2 on real files had been run many times and is
the project's best check, but every one of those runs went through a driver whose
work lives in `main`. A whole class of programs — the obvious way to write a
driver — was outside every test in the project.

## Devirtualising §6a's indirect case bought no speed

Predicted a win, measured none. Worth recording because the mechanism was real
and the reasoning was the usual one.

Every indirect tail call in the emitted compiler — fifteen of them — was a call
to an aliased `not`, `and`, `or` or `isub`, which §7.3 makes a *thunk* and so a
call through a function value even though the callee is a compile-time constant.
Resolving them took the compiler's emitted C from 15 marked tail calls and 121
indirect calls to **zero of each**, and shrank it (`lexer.mpl` 3,388 → 3,323
lines, `types.mpl` 9,465 → 9,428), because an indirect call needs a temporary for
the pair and a cast where a direct one is a single line.

`and`, `or` and `not` are among the most-called things in the codebase, so this
looked like it had to pay. It did not:

| emitting | before | after |
|---|---|---|
| `types.mpl`, three runs | 0.41 / 0.39 / 0.45s | 0.45 / 0.40 / 0.39s |
| the whole compiler, once each | 185.4s | 189.2s |

Flat, within the noise this box shows. An indirect call through a static that is
written once is well predicted by the hardware, and 121 sites — however hot — are
not where 2.6e9 calls go. The change is worth having because §7.7 is mandatory
and this was the last place it did not hold for anything stage 1 contains, not
because it is faster.

The instrument that mattered was not a profiler at all: `grep -c` on the emitted
C for the marker emit already writes at each unhandled site. A backend that
*reports* where it fell short of a guarantee can be audited with a count, which
is how the fifteen were found and how they were confirmed gone.

## §6a's trampoline cost nothing, because it is emitted conditionally

The pending block, the argument union and the driver are emitted **only when the
program contains an indirect tail call**. After the alias devirtualisation the
compiler contains none, so its own C carries no trampoline at all — and
regenerating for the change reached a fixed point in *one* iteration instead of
the usual two, which is itself the evidence: the backend change is inert on its
own source.

That is worth stating as a principle rather than an accident. A backend
obligation that only some programs incur should be paid by those programs. The
alternative design BOOTSTRAP §6a anticipated — "every function returns a value or
a pending call" — would have changed all 2,266 functions' calling convention and
cost every call in every program, to serve a construct the compiler never uses.
What made the cheap version possible is letting the pending call travel *beside*
the value (a static block plus a flag) rather than inside it (a wider return
type), which needs no signature change at all.

The one thing to watch if this is ever revisited: the flag is tested after every
indirect call site and after every direct call to a reporting function. Both sets
are statically known and, in the compiler, empty. In a program that does use
function values heavily the test is a load and a well-predicted branch, and it has
not been measured — there is no workload in the tree that exercises it.

## The swing is the derivation count, and one rejected fix should be reopened

The section below records the observation; this one explains it, and the
explanation was already in this file — "Why the type table grows" says the count
"tracks the *number of derivations*, not the program", because `take_snap`/`put_snap`
roll back the lifted functions, modules, specialisations and templates around a
discarded first pass **but not the table**.

That is the whole mechanism. The retry in `lower_prop_func` fires for a member
whose first pass read an *unsettled* sibling (`lstate.nplace`), so:

- perturbing `infer.mpl`'s `ctx` changes which members read an unsettled sibling,
- which changes how many members are lowered twice,
- which changes how many discarded derivations leave placeholder types interned
  permanently,
- which is why the count is **bistable** rather than noisy: the retry set is
  discrete, so a run lands in one basin or the other.

**Correction to that last point.** It first looked as though only `mplc.mpl` showed
the swing, because `half.mpl` and `compiler.mpl` came out identical between the two
sources — but that comparison used the *new* binary, and the new binary is
insensitive to the perturbation. Re-measured against the binary that is sensitive,
**every closure containing `infer.mpl` shows it**:

| input | sensitive binary + pre-prop `infer.mpl` | + prop-check `infer.mpl` | insensitive binary, either |
|---|---|---|---|
| `typecheck.mpl` | 6,463 | 2,736 | 2,735 |
| `half.mpl` | 6,064 | 2,344 | 2,343 |
| `compiler.mpl` | 6,457 | 2,730 | 2,730 |
| `mplc.mpl` | 6,468 | 2,741 | 2,741 |

So `half.mpl` is the cheapest reproducer, not `mplc.mpl`. And the two binaries are
**byte-identical** on inputs whose closure does *not* contain `infer.mpl`
(`lexer.mpl` 69,817 bytes, `types.mpl` 187,027 — identical), diverging only on
those that do. That is a narrower and less alarming statement than "two compilers
disagree": the divergence is confined to inputs including the module that was
perturbed.

**Method note, because it cost several wrong conclusions.** Replacing the harness
binary between two A/Bs invalidates the comparison across them. This file already
warns that stage-1 sources are read at run time, so a snapshot binary captures
stage 0 only; the same trap has a second form — a *stage 2* binary captures stage
1 at the moment it was built, so measurements taken before and after installing a
new `bootstrap/mplc.c` are not comparable. Fix the binary across the whole
question, not just within each pair.

**"Which table size is canonical" is the wrong question**, and it was worth
retiring: the table holds garbage whose quantity depends on retry accidents, so
there is no canonical size. Both artifacts contain everything load-bearing — emit
skips a placeholder-bearing type (`T.has_var`) — and differ in junk plus index
renumbering. The evidence for behavioural equivalence is the fixed point and the
byte-identical differential on `lexer.mpl` and `types.mpl`, *not* the extra
typedefs being dead: sampling the μ-alias typedefs in the larger artifact shows
some referenced once elsewhere and some not at all.

**What the bigger basin costs, measured.** Stage 0 lowering `mplc.mpl` in the
6,468-type configuration, with `MORPHL_PROGRESS=4`:

| MB | elapsed | Δ per 4 MB | depth | innermost |
|---|---|---|---|---|
| 121 | 236.6s | +27.3s | 38 | `types.mpl:cons` |
| 141 | 368.8s | +58.0s | 33 | `ir.mpl:found` |
| 153 | 442.2s | +8.5s | 26 | **`ir.mpl:find_ty`** |
| 157 | 504.1s | +61.9s | 116 | `ir.mpl:e_local` |
| 161 | 574.7s | +70.6s | 167 | `lower.mpl:cons` |

Three things to take from it. It is **not a loop** — it advances, so an earlier
8h15m run of the same job would have finished eventually rather than hanging.
`find_ty` appears *by name*, which is the linear scan this file already put at
~31% of calls. And the cost per unit of allocation rises monotonically while
`depth` climbs to 167, which is the non-tail recursion over the table that
CLAUDE.md flags as a stack hazard at this size.

The sharpest single number: **161.8M calls in 574.7s = 280k calls/sec**, against
the 2.34M calls/sec this file records for a whole-compiler emit. Same machine,
same interpreter, **8x lower call throughput** — that is what the junk costs.

## Rolling the table back: done, and it was the right target

**Result.** §9.3's table is now saved in `take_snap` and restored in `put_snap`,
alongside the lifted functions, modules, specialisations and templates that were
already being rolled back:

| | at `7fd95b7` | before | **after** |
|---|---|---|---|
| whole-closure table (`mplc.mpl`) | 1,470 | 6,468 | **1,404** |
| `half.mpl`, sensitive binary + pre-prop `infer.mpl` | — | 6,064 | **1,098** |
| `half.mpl`, + prop-check `infer.mpl` | — | 2,344 | **1,101** |

So the **bistability is gone** — the two basins, 3,720 entries apart, are now 3
apart, and that residual is real source difference rather than instability. The
table is **4.6x smaller** on the full closure and lands *below* the figure from
before the regression, which settles what the 4.3x growth this file documented
actually was: the placeholder types left behind by discarded derivations.

**The one line that made the earlier attempt fail.** It died with `nth: index out
of range`, and the recorded cause — `st.sltys` holds type indices and is not
snapshotted — was not it: `lower_prop_body` already brackets slots with
`take_slots`/`restore_slots`, so the enclosing frame's slot types all predate the
snapshot. The real hazard is in `lower_prop_func`:

    $decl und   $if again ($call put_snap (st, sn)) 0
    $decl fty   $call fn_ty (st, lf0)      <- reads lf0's interned *indices*

`lf0` is the function the discarded pass built, and `fn_ty` resolves its `params`
and `result` *through the table*. Roll the table back first and those indices
dangle. Computing `fty` **before** the rollback fixes it, because a `T.proto_ty`
is structural and survives; the second pass re-interns whatever it needs. The
other two rollback sites need no change — they read `v0.ty` and `b0.val.ty`, which
are already structural.

Why discarding is sound: every type the first pass interned was derived against a
placeholder, the tree that named it is thrown away, and nothing outside the pass
holds its index — `idx` is reserved *before* `take_snap` precisely so it survives.

**What it is worth beyond the size: unmeasured, and one attempt failed to test it.**
`find_ty` is a linear scan and was ~31% of calls, so a 4.6x smaller table ought to
be proportionally cheaper per intern. The obvious A/B — stage 0 lowering
`types.mpl`, same binary, `lower.mpl` swapped — says nothing, because that closure
barely exercises the effect:

| | table | time |
|---|---|---|
| with the rollback | 207 | 133.4s |
| without | 228 | 137.5s |

A 9% smaller table and a 3% time difference on one run each is noise. The reduction
only becomes large on the *whole* closure (6,468 -> 1,404), and stage 0 on that
takes hours, so the honest position is that the speed benefit is **not
established**. Two precedents in this file argue for leaving it that way rather
than assuming: interning identifiers was predicted at 1.4-1.7x and delivered 1.05x,
and devirtualising the alias thunks removed every indirect call in the compiler and
moved the clock not at all. The size reduction and the end of the bistability are
the results; treat any speed claim as untested.

**Method: three ways the thing under test changed underneath the measurement.**
All three happened while doing this one fix, and each produced a plausible number
that meant something other than what it looked like.

1. **A stale binary.** An A/B across two harness binaries is not an A/B. Fixing the
   binary *within* each pair is not enough; it has to be fixed across the whole
   question.
2. **The fix in the input rather than the compiler.** The first attempt to test this
   change measured nothing, because the binary doing the lowering was compiled from
   the old source while the change sat in `stage1/lower.mpl` — the *input*. Stage-1
   sources are read at run time, which makes stage-0 A/Bs trivial and stage-2 A/Bs
   treacherous, because a stage-2 binary freezes stage 1 at the moment it was built.
   To test a backend change, build a binary *from* the changed source and run that.
3. **Two concurrent jobs mutating the same file.** A throughput A/B that swapped
   `lower.mpl` between fixed and unfixed ran at the same time as the stage-0
   differential, so the differential compared a fixed `mplc` against an *unfixed*
   stage 0 and reported `lexer` and `parser` as DIFFERS. The giveaway was that
   `types` — emitted after the swap had been reverted — was identical. Nothing in
   the check could have caught it, because it never looked at what source it read.

The differential now fingerprints `stage1/lower.mpl` with `md5sum` before and after
and refuses to call the result valid if it moved. Worth doing for any comparison
that reads stage-1 source: it is the only thing that distinguishes "the two
implementations disagree" from "they were not given the same program".

**Superseded below.** The two sections that follow diagnose the instability and
record the measurements that led here; they are kept for the method, not as live
guidance.

**Reopen "roll the table back".** Of the three attempts recorded here, two failed
for reasons that generalise (a placeholder's interned entry is load-bearing; a
partitioned scan costs more per entry than it saves below ~50% placeholders). The
third — rolling the table back in `take_snap`/`put_snap` — failed with `nth: index
out of range` because `st.sltys` holds type indices and was not snapshotted. That
is a missing snapshot field, not a principle, and it is the fix that matches the
diagnosis exactly: the discarded pass's entries are garbage *by construction*.
Doing it would collapse both basins into one and remove the pathology.

**Now measured.** A counter on `lstate`, bumped at each of the three `put_snap`
rollbacks, compiled into a binary so the run finishes in seconds. Same binary,
same target (`half.mpl`), only the input's `infer.mpl` differing:

| input `infer.mpl` | retries | types |
|---|---|---|
| pre-prop | **7,370** | 6,064 |
| prop-check | **6,177** | 2,344 |

The retry count differs in the predicted direction, so discarded derivations
feeding the table is confirmed, and the `take_snap` fix rests on something real.

Two results that were *not* predicted and matter for how to read it:

- **The relation is not linear.** 1,193 extra retries yield 3,720 extra types —
  ~3.1 types per marginal retry against an average of 0.8 (pre) and 0.4 (post). So
  it is not the retry *count* that swings the table but *which* members retry: a
  rollback on a member with a large derivation interns many placeholder types, one
  on a small member few. That is why the table is bistable rather than noisy — the
  step is in the identity of the retrying members, not in a smooth total.
- **6,177 retries happen in the good configuration too.** The basin we are in
  still discards ~6,000 derivations, each leaving placeholder types interned
  permanently. So rolling the table back is not only about collapsing the
  bistability; it removes junk from both basins, which is the larger prize.

**Instrument note.** The first version of this counter printed each retry as it
happened, to watch a run that might not finish. That does not work: `print` is
stdout, stdout is block-buffered when redirected, and a run killed by `timeout`
discards the buffer — 25 minutes produced a 0-byte file. There is no stderr
intrinsic to write to (§8's documented gap; `panic` aborts), so incremental
visibility from *inside* stage 1 is not available at all. Either let the run
finish, or instrument stage 0, where `MORPHL_PROGRESS` writes to fd 2 with a raw
`write` precisely so it cannot be buffered or lost.

**Still unexplained, and both are measurements rather than guesses.** A binary
built from the old source plus one unused `ctx` field is *equally* sensitive to the
input (6,064 / 2,344, identical to the unmodified one), yet adding that same field
to the input reproduced the table-size change. Sensitivity of a *binary* and
sensitivity to an *input* are different axes, and an earlier isolation here
conflated them. Whatever makes the prop-check binary insensitive is therefore not
the field.

## The type table's size swings 58% on an inert edit

Standing item in this file: the whole-compiler type table holds ~6,300 entries
where the front end alone needs ~1,470, because §5.5 placeholders are interned
unconditionally and never removed, and ~47% of the entries are duplicates modulo
placeholder id. Two attempts to attack the placeholder side were tried and
reverted (above).

**A new fact, found by accident and confirmed by a single-variable A/B against a
fixed binary: adding one *unused* field to `infer.mpl`'s `ctx` block takes the
table from 6,468 entries to 2,736**, the emitted C for `mplc.mpl` from 69,769
lines to 67,289, and the μ-alias typedefs from 4,050 to 1,562. Nothing about any
program's meaning changes: the emitted C for `lexer.mpl` and `types.mpl` stays
**byte-identical to stage 0's**, the fixed point holds, and `mplc.mpl` emits zero
diagnostics either way.

| `infer.mpl` | table | emitted lines | typedefs |
|---|---|---|---|
| committed | 6,468 | 69,769 | 4,050 |
| + one unused `ctx` field | 2,736 | 67,289 | 1,562 |
| + the §4.10 prop check (which also adds a `ctx` field) | 2,741 | 67,791 | 1,565 |

The third row is what found it. The prop check happens to add a field to `ctx`,
and the drop was initially mistaken for an effect of the check — the isolation
above is what showed the check contributes only its own 502 lines.

**Do not read this as a 58% win to bank.** What it says is that the junk half of
the table is *unstable*: its size is a function of an irrelevant detail of one
block's field count, which means `intern` is sensitive to something it should not
be. The mechanism is **not known**. `ctx` is mentioned by nearly every function in
`infer.mpl`, so its interned identity is load-bearing for a large share of the
table, but why perturbing it should *halve* the placeholder duplicates rather than
shift them is exactly the question. Until that is understood, the smaller table is
a coincidence that happens to be correct, not a design.

The lesson for method: this was found because a line count moved in the wrong
direction and got chased instead of accepted. A 1,978-line *decrease* from a
change that only adds code is the kind of discrepancy worth three minutes of A/B.

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
- devirtualising the alias thunks as a *speed* change (see above: 121 indirect
  calls removed, wall time unmoved)

## `T.same` on unions was 76% of the compiled compiler, and canonical order made
## the set comparison unnecessary

Taken on the tree at `5200da0` plus the `$if`/`$set` union-slot fix, with
`perf record -g` on `cc -O2 -g -fno-omit-frame-pointer` of `bootstrap/mplc.c`.
This is the first profile of the *compiled* compiler by time rather than by
allocation, and it is cheap — one 160s run against stage 0's ninety minutes — so
it should be the first instrument reached for from now on.

`mplc stage1/mplc.mpl`, 694,928 samples:

| symbol | before | after |
|---|---|---|
| `same` | 56.90% = 90.7s | 48.10% = **42.5s** |
| `mem_ty` | 13.06% = 20.9s | **absent** |
| `same_set` | 3.33% = 5.3s | **absent** |
| `tys.length` | 1.73% = 2.7s | **absent** |
| `same_tys` | — | 8.84% = 7.8s |
| `reaches` | 13.03% = 20.7s | 25.17% = 22.2s |
| `find_ty_at` | 2.53% = 4.0s | 4.73% = 4.2s |
| **whole emit** | **159.5s** | **88.3s** |

**1.8x, and the output is byte-identical** — 68,592 lines, `cmp` clean, which is
the only check that matters here: if a positional walk had disagreed anywhere,
`intern` would have handed out a different index and every `mpl_tN` after that
point would have moved.

The mechanism, and the arithmetic that confirms it. §3.6 makes a union a *set*, so
`same` compared two unions with `same_set` — a length check plus `subset_tys`,
which is one `mem_ty` per member and one `same` per candidate: O(n·m) on members
that may themselves be big unions. But **a union is now canonically ordered by
construction**: `t_union` is the only caller of `raw_union` and always passes
`sort_tys`. So `same_tys`, the positional walk already used for groups, `$func`
parameters and `$overload` candidates, answers the same question in O(n).
Predicted saving 69.3s, measured 71.2s — 3%.

Two things worth carrying:

- **The canonical order was introduced for §7.5's discriminators, not for this.**
  Making the member order part of the type so a tag belongs to the type rather
  than to the writing happened to make set comparison redundant. The speed was
  found afterwards, by profiling, not predicted.
- **`find_ty_at` was 2.53%, so the type-table *scan* was never the problem.** That
  is the fifth time in this codebase a structure's scan length was suspected when
  the cost was the price of one comparison — `IR.find_ty`, `append_ty`, `T.unroll`,
  `Scope.findLocal`, and now this. The scan still drives the O(T²) `same` calls
  (`intern` compares against every entry), but halving `same` is what paid.

`reaches` is now the largest single non-`same` cost — 22.2s, unchanged in absolute
terms and only larger as a share because the total shrank. It is `lower.mpl`'s
repeated graph reachability with a list-based `seen`, used to find §6a's strongly
connected components; Tarjan computes them in one pass. That is the next lever, and
after it `intern`'s O(T²) `same` calls, which want a structural hash rather than a
scan — note that holding the table newest-first was already tried and cost 30%,
because a hash is not a scan and that attempt was.

## §6a's SCC search ran two depth-first searches per *pair*, not per node

Same tree, same instrument, immediately after the `same` fix above.

`find_groups` walked `i` over all n functions, `scc_of` walked `j` over all n, and
each pair called `reaches` **twice** — so 2n² depth-first searches over the tail-call
graph, each one scanning the whole edge *list* per visited node. At n = 2,480 that is
**12.3 million** searches to find three groups.

Mutual reachability is an intersection, so it needs two searches **per node**, not per
pair: `j` is in `i`'s component exactly when `i` reaches `j` and `j` reaches `i`, and
"reaches `i`" is forward reachability on the edge list turned around. `reach_from`
accumulates the reachable set instead of answering one question about it, `rev_edges`
builds the reversed list once, and `scc_of` becomes two `mem_int` tests.

| | emit `mplc.mpl` | output |
|---|---|---|
| pairwise `reaches` | 86.5s | 68,644 lines |
| per-node `reach_from` | **62.7s** | 68,644 lines, **byte-identical** |

2n² searches → 2n, a 2,480x reduction in search count for 1.38x on the whole run —
`reaches` was 22.2s of 86.5s and it is now absent from the profile. Predicted 64.3s,
measured 62.7s, within 2.5%. `q1 == q2` byte-for-byte is the check that matters: the
same three components are found, so §6a contifies exactly what it did before.

Each search is still O(V·E), because `reach_edges` rescans the edge list per visited
node; grouping edges by source into an adjacency list would make it O(V+E). That was
**not** done, because after this change reachability does not appear in the profile at
all and there is nothing left to win there.

### Where the compiled compiler spends its time now

62.7s total, after both fixes (159.5s → 62.7s, **2.54x**):

| symbol | share | absolute |
|---|---|---|
| `same` | 64.24% | 40.3s |
| `same_tys` | 11.86% | 7.4s |
| `find_ty_at` | 6.46% | 4.1s |
| `has_var` | 2.57% | 1.6s |
| `lookup` | 1.57% | 1.0s |
| `cv_eq` | 1.45% | 0.9s |
| `find_mdone` | 1.10% | 0.7s |

Type comparison is **76%** again, and now it is unambiguously `intern`: the table is
scanned with `same` against every entry for every type interned, so it is O(T²)
comparisons with T = 6,348. `find_ty_at` at 6.46% is the scan *loop*; `same` is the
comparisons it asks for.

The fix is a **structural hash** cached on the type, making interning O(1) expected —
and note that this is *not* the thing that failed before. Holding the table
newest-first was tried and cost 30%, because it reordered a scan whose hot entries
(`Int`, `Str`, unit, the booleans) are interned first and so sit at its head. A hash
does not scan at all, so that failure does not transfer. Count it before believing it
anyway.

## A structural hash on every type: `intern`'s comparisons, 4.3x cumulative

Measured first, for once, and the measurement is what shaped the design. An
instrumented `emit_diag` counting `find_ty` calls and scan steps over `mplc.mpl`:

| | |
|---|---|
| `find_ty` calls | **1,199,073** |
| scan steps (`same` calls from the table) | **275,020,404** |
| average scan length | **229** of 6,348 entries |
| cost per comparison | **146 ns** (40.3s / 275M) |

146 ns says the comparisons were not cheap tag checks: the table is mostly *block*
types, so `same` went into `same_fields`, which does an `eq_str` per field name and
recurses into field types. So every type now carries a structural hash and `same`
settles a mismatch with one integer compare.

| | emit `mplc.mpl` | output |
|---|---|---|
| before (per-node reachability tree) | 62.7s | |
| with the `h` field but the old `same` | 68.2s | |
| with the hash guard | **37.4s** | 69,244 lines, **byte-identical** |

The `h` field costs **5.5s** on its own — every type value is one word bigger and
every constructor computes it — and the guard saves **30.8s**. Net 1.68x, and
**159.5s → 37.4s, 4.26x** over the three changes.

**The soundness condition is one-directional and it decided the whole design.**
`same (a, b)` must imply `hash_of (a) = hash_of (b)`; the converse need not hold,
since equal hashes only cost a fallthrough to the structural walk. So the hash is
built from a deliberate *coarsening* of what `same` compares, and anything `same`
ignores is excluded:

- `frame` is **not** hashed — `same`'s `func` case does not compare it, so two
  functions differing only in §5.3a's closure flag are one type.
- a field contributes its name's **length**, not its name — equal strings have equal
  lengths, so this cannot separate an equal pair.
- a prop contributes its value's **tag**, not its value — `cv_eq` requires matching
  tags, and the payload is left out rather than audited.
- a prop's `ty` is not hashed at all, because `same_props` does not compare it.

**The one real bug the audit found was intersections.** §3.6 makes an intersection a
set and it is deliberately *not* canonicalised — unlike a union, which `t_union`
sorts — so `same` compares intersections with `same_set`, order-insensitively. A
positional fold would have given two *equal* intersections different hashes, interned
one type twice, and had the backend lay out two C structs for it. `hash_tys_comm` is
a commutative fold for that case alone. It did **not** show up in the byte-identity
check, because reordered intersections do not arise while compiling the compiler —
which is exactly why it needed reasoning rather than a test run. `types_test`'s
`t66`–`t69` pin it, along with the `frame` exclusion.

Two smaller notes. `hash_of` names every compound tag rather than using a catch-all:
§4.7 narrows a catch-all to the *union* of what is left and §5.1 can only project a
common prefix, but `h` sits at a different position in each member, so `t.h` on that
union does not typecheck. And `same` had to be split into a guard plus `same_deep`
placed *after* it, because §4.10's source order will not let the guard name a
declaration below it.

### Where the compiled compiler spends its time now

37.4s, and the shape has changed — the top entry is a **contified group**, §6a
having folded `same` and `same_deep` into one function with a dispatch loop:

| symbol | share | absolute |
|---|---|---|
| `mpl_grp1` (`same` + `same_deep`) | 49.10% | 18.4s |
| `find_ty_at` | 13.10% | 4.9s |
| `hash_of` | 9.88% | 3.7s |
| `same_tys` | 5.63% | 2.1s |
| `has_var` | 5.24% | 2.0s |
| `lookup` | 2.84% | 1.1s |
| `find_mdone` | 2.02% | 0.8s |

**The constant factor is now close to the floor for a linear scan, and what is left
is the scan.** 275M iterations at ~65ns each is the call into `same`, two `hash_of`
dispatches and an integer compare — there is no structural walking left to remove.
Going further means reducing the *number* of iterations, which is a different change:
either cache each type's interned index on the node (a `$mut` field set on first
intern) or bucket the table, which needs integer arrays that BOOTSTRAP §2 does not
give stage 1 — the root block's arrays are monomorphic at `Str`.

## Rejected: caching the interned index on the type node

Built, measured, reverted. Recorded because the reasoning that motivated it is
appealing and wrong, and the shape of the error is reusable.

The idea: give every type a `$mut $alloc` cell holding its §9.3 index, so a lookup
is a field read instead of a 229-entry scan. Copying a type copies the *reference*
(§7.3), so every copy of one node shares one cell — the hash-consing arrangement
a compiler normally uses.

| | emit `mplc.mpl` |
|---|---|
| cache cells present, compiler without the cache | 34.9s |
| the cache in use | **37.1s** |

**Slower by ~2.2s**, with `c1 == c2` byte-identical so it was always *correct*. The
hit rate says why:

| `ty_find` | count |
|---|---|
| cache hits | 40,818 |
| cache misses | 880,947 |
| **hit rate** | **4.4%** |

**`ty_find`'s job is interning, and interning is by nature a question about a node
that has just been built.** Lowering derives a type bottom-up — `t_block (…)`,
`t_ref (…)` — and *then* asks whether it is already known. The node handed in is
therefore fresh every time and its cell is empty every time, so the cache pays an
allocation per type constructed and answers 4.4% of the lookups. A node cache can
only help *repeated lookups of a stored node*, which is `emit`'s pattern —
`IR.find_ty (ts, t.result)`, `(ts, xs.head.ty)`, where the node came out of the
table — and that is at most 279,583 of 1,200,953 lookups, 23%.

So the split measured beforehand was read the wrong way round. 921,370 of the
lookups being in `ty_find` said "cache here"; what it actually meant was "these are
the lookups a node cache cannot serve". **Count the hit rate, not the call count** —
a cache's value is in the hits, and the two numbers can point in opposite
directions.

Extending it to `emit` was not done. The cell cost is already sunk at construction,
so emit's reads would be upside — but ~4.2s of scan against a −2.2s floor lands
inside this box's noise (the same compiler measured 37.4s and 34.9s on comparable
input), and it needs `tsafe` plumbed through `IR.program`, which is the short-call
arity trap.

**What interning actually wants is a content-addressed map**, hash to bucket, which
is O(1) rather than a 229-entry scan. That needs integer arrays, and BOOTSTRAP §2
keeps the root block's arrays monomorphic at `Str`, so stage 1 cannot express one
today. That is the honest blocker, and it is a §8/BOOTSTRAP question rather than a
lowering one.

For the record, the staleness rule was sound and is worth keeping if this is ever
revisited: `tsafe` is the minimum `ntypes` the table has ever been rolled back to,
and a cached index is trusted only below it, because §5.5's snapshot truncates the
table and every index at or above a rollback target is handed out again.

## Per-module headers: measured as worthwhile, attempted, reverted

The whole-program header is 249 KB of the compiler's ~1.9 MB of emitted C, and every edit
regenerates it, so every output recompiles. A header per module would fix that, and the
measurement says the share each module needs is small — distinct struct names mentioned per
output, against 674 in the table:

| module | share | module | share |
|---|---|---|---|
| `lower` | 41% | `types` | 11% |
| `emit` | 28% | `parser` | 10% |
| `main` | 28% | `ir` | 9% |
| `infer` | 26% | `verify` | 8% |
| `compiler` | 5% | `lexer` | 5% |
| | | `prelude` | 0.3% |

The median module needs about 10%, and those are the types each *body* mentions — a header
needs only what its **exported signatures** name, so smaller again. Crucially a module's
header would depend on that module's code alone, because a struct's name comes from the
type's content: editing `emit.mpl` could not change `types.h`.

**Three of the five pieces worked.** Per-type include guards (`#ifndef mpl_tN_D`), which are
what make a type definable in several headers — sound precisely because a content-derived
name means two definitions under one guard *are* the same definition. A per-module type
collection (`tys_of_mod`), walking every node's `ty`, every slot and every signature. And the
restructuring itself: `mpl_rt.h` for the runtime, §4.16's declarations and §6a's driver; a
`<mod>.h` and `<mod>.c` per module; `#include` lines emitted per output, with `join_files`
dropping them for a single-artifact target, since concatenating *is* inlining an include.

**It failed on the transitive closure, and that is the thing to get right first.** Compiling
the result gave **3,196 `unknown type name` errors**. `tys_of_mod` collects the types a module
*mentions*, but a struct definition names its field types, so those need a forward
declaration present too — the set has to be closed over **both** by-value and pointer edges,
and `emit_struct_at` closes only the by-value ones (which is all it ever needed when one
header held every type). `emit_fwd1` was also left unguarded, so a repeated `typedef struct X
X;` is an error in its own right.

### Second attempt: both fixes made, and a third defect underneath

Both fixes were then made and are sound in isolation:

- **The guards were split into `_F` and `_D`.** A forward declaration and a definition are
  *different* guards for one type, because a header that needs only a pointer emits the
  typedef and not the struct — sharing one key suppresses the definition where it is wanted.
- **`close_tys` closes the set over every edge that requires a declaration** — a block's
  fields, a group's items, a union's members, a reference's pointee, an array's element, a
  `μ`'s body — to a fixed point, terminating on set *size* because the set only grows and is
  bounded by the table. §5.5 makes the reference graph cyclic, so a size test is the right
  termination condition rather than a visited check.
- Checked against an independent analysis of the same graph: for `effect.mpl`, 22 types with
  `prelude` 12, `effect_util` 6, entry 8; for `parser.mpl`, 221 with `lexer` 82, `prelude` 12,
  entry 154.

The errors fell from 3,196 to **2,735** and changed character. The remaining one is not
completeness but **ordering**: a header defines a struct with a pointer field whose typedef
is emitted in a *later* header — `mpl_t95655782043184525` is used at line 440 and declared at
2076. Separate compilation would be fine, since each header emits its own closure's typedefs
before its own definitions; the *concatenated* form is not, because header A's definitions
precede header B's declarations.

Two things follow for whoever picks this up. `mpl_rt.h` names types in §4.16's extern
declarations and §6a's driver signatures, so it needs the closure of *its own* content — the
restructure removed all type emission from it without accounting for that. And the
concatenated and split forms want *different* orderings, which the single ordering
`join_files` produces cannot satisfy: every declaration in the program must precede every
definition for concatenation, while a header must be self-contained for separate
compilation. Emitting all forward declarations in `mpl_rt.h` would fix the ordering and give
up the incrementality, since that file would then change whenever any type is added.

Reverted again, for the same reason as the first attempt: it emitted C that did not compile.
The tree is at 237/237. The measurement above still says the feature is worth having; what it
needs is that ordering question settled *first*, not another round of patching.

One design decision from the attempt is worth keeping whatever comes next. Emitting the
`#include` lines rather than leaving them to the build is right: a file that names its own
dependencies can be handed to any C compiler, and the single target that cannot use them is
the one that does not need them. §6a's driver has to stay whole-program regardless, because
its pending block is shared *state* like `mpl_argc` — a copy per file would break a chain
that crosses one.

## Where a compile's time goes, and what that says about caching it

The one number that orders the incremental-compilation work, on `stage1/types.mpl` through
stage 0:

| driver | phases | time |
|---|---|---|
| `lower_dump.mpl` | parse + infer + lower + **verify** | 47.7s |
| `emit_c.mpl` | parse + infer + lower + **emit** | 60.9s |

So **emit is at most 22% of a compile** — less than that, since the 47.7s includes a verify
pass the 60.9s does not — and parse + infer + lower is about 80%. Caching a module's
*emitted C* therefore buys a fifth of the compiler's own time plus whatever `cc` costs; it
cannot buy the rest. What would is caching the **interface** a module presents to its
importers, which §3.3 already makes a first-class thing (`check_file`'s type *is* every
top-level name with its solved type) and §5.5 already makes serialisable (a de Bruijn binder
carries no name, so a type needs no relocation on read and re-interns to the same entry
because interning is by `T.same`).

Two things still stand in the way, and neither is a performance question:

- **The IR names a function by a flat whole-program index.** `e_global` carries `fn`, a
  position in the function table, so two independently lowered modules would collide. The
  emitted *name* has not had this problem since it became `mpl_f<mod>_<rank>`; making the
  tree agree with the name is finishing that work rather than new machinery. The type table
  has the same shape of problem — an interned index is a whole-program position — so a
  cached fragment has to carry its types structurally and re-intern on load.
- **A `$template` exports its *body*, not a type.** §10.7 checks it at the
  specialization site. `P.list` is a `$template`, so **prelude's interface includes
  prelude's body and everything imports prelude** — a prelude change is genuinely a
  whole-program change. That is correct rather than broken, and it costs nothing in
  practice: prelude checks in 0.07s, so it is the one module simply not cached. It sets
  the shape of the payoff: editing a leaf (`emit.mpl`, `lower.mpl`) is one module,
  editing `types.mpl` re-checks its importers, editing `prelude.mpl` is everything.

  A non-scalar `$prop` was listed beside the template here and does not belong. Its
  value is `cv_opaque` in the block's type, which is summarisable and which `tyio`
  writes; lowering keeping the prop's *source* (`lstate.mods`) is a backend matter and
  not part of the interface.

### Step one: linkage made local

`is_exported` used to be a whole-program answer — `gref_of` walked every function body
collecting global references and `xmod_add` exported any whose module differed from the
referrer's. That is finer than the local rule (235 of 1,298 functions exported) and finer is
the defect: a module's emitted text depended on who called it. Demonstrated by A/B against a
fixed binary, on two programs differing only in the entry file:

```
$decl main $func () $if ($call P.not (false)) 7 0                        # a
$decl main $func () $if ($call P.or ($call P.not (false), false)) 7 0    # b
```

Under the old rule `prelude.c` differs between them — `mpl_fprelude_3 /* or */` is `static`
in `a` and external in `b` — which is exactly the dependency a per-module cache cannot have.
Under `IR.fn.pub` (set at the two places lowering builds a module member) the two outputs are
byte-identical, and `zig build test-stable` is that check. It also removes emit's second full
tree traversal; `xt_of`'s, for §4.16's symbols, is now the only one.

The price is `cc`'s, not morphl's. The compiler is the worst case for the new rule — it is a
library of modules, so **1,258 of 1,290** functions are members against the old rule's 235,
and only the 32 lifted lambdas and §3.3 effect functions stay `static`:

| whole compiler | old rule | local rule |
|---|---|---|
| emitted C | 2,027,093 B | 1,994,240 B |
| `static` definitions | 2,147 | 85 |
| `cc -O2` | 11.4s | 13.3s |
| binary | 995 KB | 1,145 KB |
| emitting `types.mpl` | 0.23–0.26s | 0.22–0.23s |

The text is slightly *smaller* — `static ` leaves 2,062 lines and prototypes move into the
header instead of being duplicated per output — `cc -O2` costs 17% more and the binary 15%
more, because nothing can be internalised or dropped, and run time does not move. And the
direction is not uniform: `types.mpl` as an entry file goes from 29 of 212 exported **down**
to 4, since its top-level `$decl`s are entry-file globals and nothing imports the entry file.

The check that no codegen changed: emitting `types.mpl` with each binary gives 10,448 lines
either way, and all 102 differing lines are one `static`/non-`static` pair each plus the count
comment. Three-pass regeneration reached its fixed point at pass 2 (`r2 == r3`), as a change
that alters output rather than only naming must.

### Step two: naming made local

Step one made a function's **linkage** a property of the function; this makes its **name**
a property of its source. Six identities were drawn from arrival order — the emitter's
temporary counter, the group index, a `$specialize`'s module, a `$prop`'s `cv_opaque`, a
props-bearing block literal's module, and a member's rank — and `CLAUDE.md` has the full
table and the reasoning. The measurement side:

- The decisive probe is **load order**, not contents: two programs sharing `lexer`,
  `parser` and `prelude`, with the extra import placed *before* the shared ones so every
  counter in lowering is at a different value. Placed *after*, the shared modules are
  lowered first in both and match trivially — that version of the probe reported success
  and meant nothing.
- Residue over the six fixes, on `lexer.c` + `parser.c`: whole output → 88 lines → 58 →
  6 → **0**. Each fix was located by classifying the diff rather than by reasoning about
  it.
- `prelude.c` still differs between the two programs, and that is correct: it owns the
  `P.list` specialisations and the larger program needs more element types. 23 of 39
  functions shared, **zero renamed** — the text grows by gaining instantiations, never by
  relabelling. §4.9 makes the instantiation set a whole-program fact; only its *naming*
  had to stop depending on the program.
- Emitted whole-compiler C: 1,872,192 bytes without the member-rank change against
  **1,876,011** with it, so content-derived member names cost ~0.2% here — far less than
  the +24% the struct and function renames cost earlier, because a prop index is short.

**Two process failures worth more than the numbers.** Reusing `r1`/`r2`/`r3` as artifact
names across two regeneration runs mixed binaries from different trees into one
comparison, and produced an elaborate and entirely false story about self-compilation
oscillating with period 2. And `cc ... | head; echo $?` reported `head`'s status, so a
compile that failed read as one that passed. A regeneration script now uses fresh names
per run and tests `cc`'s status explicitly. Both traps are already in `CLAUDE.md`; both
were walked into anyway.

### What a per-module interface cache is worth, measured before building one

Inference is the phase a cached interface skips, so the decomposition that matters is
`typecheck.mpl` (parse + infer, no lowering) per module against the whole closure, under
stage 0. Each figure includes the module's imports, so the third column subtracts them:

| module | closure | own body |
|---|---|---|
| prelude | 0.07s | 0.07 |
| lexer | 0.26s | 0.19 |
| parser | 0.99s | 0.73 |
| types | 2.63s | 2.56 |
| ir | 3.98s | 1.35 |
| verify | 5.33s | 1.35 |
| fold | 4.18s | 0.20 |
| infer | 8.27s | ~4.7 |
| emit | 9.45s | ~4.5 |
| compiler | 23.78s | ~8.1 |
| **mplc (whole)** | **26.85s** | 3.07 |

The marginals sum to ~26.8s against the whole closure's 26.85s, so **inference is
additive** — there is no superlinear cross-module blow-up, and skipping unchanged
modules' bodies captures nearly all of it. Re-inferring the worst single leaf is 17% of
the full run, about **6x**.

**An earlier version of this measurement was wrong and nearly got built on.** Nine
modules compiled independently summed to 6.25s against the whole closure's 36.05s, and
the 5.8x gap was read as cross-module cost. It excluded `compiler.mpl`, which carries
**634 of the whole program's 636 types** — the other two are `mplc.mpl`'s own. It is the
aggregator, not a leaf, so that was the whole program compared against its parts. Adding
it takes the union of leaves to 657 types and leaves **2** types in the closure that no
module produces alone. The real combination premium is 463 → 636, **1.37x**; the
"2.3x the sum" figure recorded earlier is dated, as that note says itself.

That comparison is only possible because step two made struct names content hashes: type
sets from *separate* compilations can now be compared by name.

**An interface needs nothing but the type, and the paragraph that used to stand here
said otherwise because of a bug in my own probe.** `check_source` takes
`(src, base, path)`; called `(src, path, …)` it resolves every `$import` against a *file*
instead of a directory, `read_module` answers "", and the import's type comes back `⊥`
with no diagnostic. From that one slip came three recorded conclusions — that an
`$import`'s field type is `!`, that a `$specialize`'s is (`tys:!`), and therefore that
the interface is not the type but inference's unexposed `cx.mods` registry plus a
per-member tag for the ~5% of members that are a `$specialize`, `$template` or `$import`.

All of it was false. Checked with the arguments the right way round, prelude's interface
taken directly and taken through an `$import` serialise to the **same 280 bytes**, props
and `copaque` identities included, and a `$specialize`'s type is the specialised block
with its props. `tyio` already writes down what a cache needs.

What survives is the §10.7 point, which is about a template's *body* rather than its
type: a module exporting a `$template` exports the body, because the body is checked at
the specialization site. There is one such module (`prelude`) and it checks in 0.07s, so
not caching it costs nothing.

The same slip had `tyio_test` round-tripping interfaces whose imports had all failed, so
its type counts were understated — lexer 73 → **83**, parser 120 → **153**, types 161 →
**219**, ir 90 → **136**, all still round-tripping clean. The larger input then found a
real defect: the chunk joiner put its recursive call inside a `$decl` block, which §7.7
makes a real frame, and `types.mpl` died with "call depth limit exceeded at 8799 nested
calls". `emit.mpl`'s joiner is split into four functions to keep every call in tail
position and carries a comment saying why; this one now is too.

### The interface cache, wired and measured

`infer.mpl` can load a module's interface from disk instead of inferring it. Off by
default (`cx.cdir` empty), because §9 makes the build a program and whether to cache is
the build's decision; `stage1/cached_check.mpl` is the build that turns it on.

| whole closure (stage 0) | time | vs uncached | hits/misses |
|---|---|---|---|
| uncached | 27.90s | — | — |
| cold, populating | 42.46s | 1.5x slower | 0 / 10 |
| warm, unchanged | **10.39s** | **2.7x** | 10 / 0 |
| warm, one leaf edited | **14.00s** | **2.0x** | 9 / 1 |

**Two wrong designs preceded this, and each was found only by measuring.**

**The encoding had no sharing.** A type is a tree and a module's interface mentions the
same types once per signature, so writing each as a tree gave `ir.mpl` a **792 KB**
interface against a 50 KB source, and `types.mpl` 560 KB — 1.43 MB over the closure.
Reading that back cost *more* than inferring, so the cache hit and lost: 12.56s cold
against **15.68s warm**. Back-references (`R<n>` for a type already written) took the
total to **32 KB, 44x smaller**, and `emit.mpl` warm from 15.68s to 6.62s. `ir`'s closure
has 136 distinct types; the information was always small.

Writer and reader number types identically because both register a type **after** its
children, so a child can never reference its parent — sound precisely because §5.5 makes
recursion explicit as `μ`, which makes a type a finite tree.

**The key was on the import's source, not its interface.** `compiler.mpl` imports
everything, so adding a *comment* to `emit.mpl` changed `emit`'s source hash, hence
`compiler`'s key, hence a miss on the most expensive module in the program: editing one
leaf cost 24.06s against 24.53s uncached — no gain at all. Keying on each import's
serialised **interface** hash fixed it (9 hits, 1 miss), because a comment does not move
an interface. It also deleted the separate fingerprint walk, which had been re-reading
and re-parsing the whole closure on every run.

**And the first interface-keyed version gave the saving straight back.** Computing a
module's own interface hash by re-running `show_ty` — chosen deliberately so the hit and
miss paths would agree by construction — cost one serialisation per module per run and
took warm from 8.52s to 24.12s. The hash is free on both paths: on a hit the string was
just read, on a miss just written. `iface_read` returns it alongside the type.

**Against the ~6x predicted from inference being additive, this is 2.0–2.7x.** The
prediction assumed skipped inference was free to replace. It is not: ~234 KB of interface
is deserialised on every run by a byte-at-a-time reader under stage 0, and the entry
file's own work is never cacheable. Both are interpreter costs of the kind stage 2 removes
~20x of, so the same cache compiled should look better — unmeasured, and not claimed.

`prelude` is deliberately not cacheable: §10.7 makes a `$template`'s body part of its
interface and a type cannot carry a body. Its importers key on its **source** hash
instead, which is conservative in the right direction — a comment in `prelude`
invalidates everything, and §10.7 makes a prelude change whole-program anyway.

### The cache compiled: the gap was interpretation

| whole closure | stage 0 | compiled | speedup |
|---|---|---|---|
| uncached | 27.90s | 0.84s | — |
| cold, populating | 42.46s | 1.278s | 1.5x slower |
| warm, unchanged | 10.39s | **0.142s** | **5.9x** |
| warm, one leaf edited | 14.00s | **0.314s** | **2.7x** |

Inference being additive predicted ~6x; under stage 0 the cache gave 2.7x, and the
shortfall was attributed to the byte-at-a-time reader and the non-cacheable entry file.
Compiled, warm is **5.9x** — so the attribution was right and the remaining gap was
interpretation, not design.

The edit case is 2.7x for a structural reason rather than an implementation one: editing
`emit.mpl` means re-inferring it, and `emit` is one of the two costliest modules in the
closure. You cannot skip work on the file you changed, so 0.314s is near the floor for
that edit.

Cold stays 1.5x slower in both, which is the one-off cost of populating.

### `mpl_init`'s module order was derived, and derived wrongly

Measuring the cache compiled is what found it. The benchmark crashed with **SIGFPE**
before printing: `mpl_init_infer()` ran before `mpl_init_types()`, so an `infer`
top-level `$decl` reached `types.mpl`'s `hmix` and computed `mod hmod` while that static
was still zero.

`mods_of` takes the order a module's functions *first appear* in the function table, and
the comment on it claimed that was §4.14's dependency order because "a module a module
imports has a lower first index". **The reverse is true.** A module's own `$import`
member reserves its index *before* the imported module's members are lifted, so an
importer always sorts ahead of its dependency — every initialiser ran before the ones it
depended on. Latent since `1311b42`; `mplc` escaped it only because `compiler.mpl`'s own
statics happen not to touch another module's during init.

`IR.program` now **carries** `mods` — the order in which each module's loading completed,
appended in lowering right after `force_props` returns, which is dependency order because
§4.14 finishes a module before the importer's next member. `emit_mod_calls` walks that,
filtered to modules that have an output so a call can never name an undefined
`mpl_init_<mod>`.

Ordering by *highest* index was the tempting shortcut and is wrong: for a module whose
last top-level item is an import, the importer's maximum index is lower than its
dependency's. The order has to be recorded, not inferred from indices.

`fold.mpl` carries the new field, which is the fourth rebuild site this stretch has
needed threading — after `pub`, `nmod` and `file`.

### A premise worth checking: the missing-module diagnostic

The plan listed "make a missing module report a diagnostic" as a small fix with
disproportionate value, on the grounds that `read_module` returning `""` produced a
silently empty module and that silence was what let four false claims survive four probes.

**The premise was wrong.** A missing module reports with a span and the resolved path, and
always did. The silence was the *drivers* throwing `r.errs` away — printing `T.show` of a
type or a round-trip count and never looking at the diagnostics. The lesson belongs to the
probe discipline already recorded here, not to the compiler.

Checking it found a real adjacent bug, though. `read_file` answers an option and both
passes flattened it to a string, so an unreadable file and an **empty** one were the same
case — and §3.3 makes an empty file a valid empty block, so importing one reported
"cannot read" for a file read perfectly well. Fixed in both passes;
`fixtures/empty_import.mpl` pins it.

### Where a compiled build actually spends its time, and the type table's trie

**Every phase share recorded above this point came from stage 0, and they do not
transfer.** Measured compiled, on the whole closure:

| phase | time | share |
|---|---|---|
| parse + infer | 0.82s | 2.0% |
| **lower** | **38.33s** | **94.6%** |
| verify | 0.62s | 1.5% |
| emit | 0.74s | 1.8% |

So "inference is ~80%" and "emit is at most 22%" are stage-0 facts. Under the
interpreter, `lookup`/`eval`/`bindParams` dominate and inference really is most of
parse+infer+lower; compiled, that overhead vanishes and **lowering is essentially the
whole compile**. This also re-reads the entries above correctly: "emitting the whole
compiler 159.5s -> 37.4s" was always parse+infer+lower+emit, and `T.same`'s hash guard,
the SCC fix and interning were all *lowering* costs. The file had been measuring
lowering and calling it emit.

It also means the interface cache's 5.9x is 5.9x of 2.0% — a full warm rebuild goes
38.69s to ~37.99s, **1.8%**. The cache works as measured; applying its speedup to a whole
build was wrong.

**`perf` on the compiled binary put 77.9% of lowering in interning**: `same` 28.9%,
`find_ty_at` 14.8%, `hash_of` 12.3%, `same_fields` 10.1%, `same_props` 7.0%, `same_tys`
4.8% — and `find_ty_at`'s callers are `find_ty` <- `ty_find` <- `intern`. With 1,199,073
lookups over an average scan of 229 of 6,348 entries, the scan alone is 275M comparisons.

**A hash trie over the table took lowering 41.4s -> 27.4s (1.51x) and the pipeline
40.5s -> 28.5s (1.42x)**, with the emitted C **byte-identical** on `lexer`, `types`,
`parser` and `ir` — the only check that counts, since §9.3 makes an index a type's
identity and one disagreement renames every `mpl_tN` after it. `find_ty_at` is gone from
the profile.

Three things about it. It is an *index*, not a replacement: the banker's queue still
answers `ty_at` and `all_types`. It is persistent, so §5.5's `put_snap` restores it by
restoring one reference — and omitting that restore would leave the index naming types a
rollback discarded, handing back an index past the end of the table. And the buckets are
**1,021**, not 1,024: `hash_of` answers a small per-tag constant for each of the nineteen
leaf types, which bucketing on the low bits directly would pile into one bucket.

**The prediction was 2.5x and the result was 1.42x, and the post-trie profile says why.**
The `same` family is still 65% — `same` 24.0%, `same_fields` 15.9%, `same_props` 11.3%,
`same_tys` 7.5%, `hash_of` 6.8%. `same` was never only the table scan; the step-count
arithmetic treated it as if it were. Reading the source found the second caller:
`unroll_find` is another linear scan keyed on `same`, and `unroll` is asked constantly —
every structural question about a type asks it first. That is the next opportunity and
the same shape as this one. It needs its own structure or the trie made generic over a
`$template`, because `types.mpl` cannot import `ir.mpl`.

### Hash-consing the comparison: built, measured, rejected

After the trie, `find_ty_at` is gone from the profile and the `same` family is still
**65%** of lowering — `same` 24.0%, `same_fields` 15.9%, `same_props` 11.3%, `same_tys`
7.5%, `hash_of` 6.8%. So `same` was never only the table scan, which is what the 2.5x
prediction for the trie assumed.

**The remaining cost is one deep comparison per successful lookup, and it is large.**
Bounded by an unsound A/B — `same` answering on the hash alone, against a fixed binary:

| | time |
|---|---|
| sound: hash guard + deep compare | 25.07s |
| hash equality only (UNSOUND) | **7.88s** |

**68% of lowering is `same_deep` verifying that two equal types really are equal.** Each
level is already hash-guarded, so the descent happens only when hashes match all the way
down — which for two equal types is the whole tree. Trusting the hash is not an option: a
collision would silently merge two distinct types, with no `cc` error, which is a
miscompile rather than the loud duplicate-definition the *naming* hash produces. The
7.88s is a ceiling, not a candidate.

**Hash-consing was the obvious fix and it does not work.** The whole mechanism was built:
a `tid` cell on the nine compound shapes, a trust floor obeying §5.5's rollback rule
(`tid_ok`, lowered in `put_snap` — the `tsafe` rule below), `set_tid` from `append_ty`, and
a fast path in all nine arms of `same_deep` where `a` and `b` are already narrowed so
`tid` costs no extra dispatch. It typechecks, and it preserves every index: emitting
`lexer` and `parser` stayed byte-identical.

It measured **slower**: 25.20s to **26.79s**. The cell costs ~1.6s — the same order as the
~2.2s the earlier node-index cache cost — and the fast path buys nothing, so it never
fires.

**The reason is a misreading of this file's own neighbour, and it is worth naming.** The
design rested on "lowering interns a field's type before the block containing it". That
sentence is about **struct emission order**: *when* a field's type is interned it gets a
lower index than its block, which is why emitting structs in index order is dependency
order. It does **not** say every subterm is interned, and in general none is — `intern` is
called on a node's type, not on each subterm. So a freshly derived parent's children carry
no id, both sides of a child comparison need one, and the guard fails every time.

That is the *same* failure as the node-index cache rejected at a 4.4% hit rate. The
distinction argued for this attempt — that it reads the **children's** indices rather than
the parent's, which are always set — is real and irrelevant, because the children are not
interned either. **Both attempts failed because interning asks about something freshly
built.** That is now the second entry of this shape; the four above it are the mirror
image, attacking a scan's *length* when the cost was per-comparison.

**What it would actually take: recursive interning** — interning every subterm as it is
built. That makes the fast path fire, and it changes what §9.3's table *is*: `all_types`
feeds `IR.program` and emit writes a struct per entry, so every intermediate type becomes
an emitted struct. A much larger change with real costs, not a tuning tweak. The 3.3x is
still there for whoever wants it.

### Caching a field's interned index: two sound guards, both defeated by rollback

The hash-consing entry above put the index on the type **node** and the fast path never
fired, because structurally equal types are distinct objects and a freshly derived
child never carries one. Putting it on the **field record** fixes that completely: a
field is built by the code that interned its type, so the index is there exactly when it
is useful — and it is free to produce, since `lower_item` already computes
`intern (st, v.ty)` for the slot two lines above where it builds the field, and throws it
away.

The prize, bounded by unsound probes against a fixed binary:

| | time |
|---|---|
| current (sound) | 25.5s |
| field comparison O(1), **no validity guard** | **16.5s** |
| child comparison O(1) everywhere | 9.6s |
| `same` on the hash alone (floor) | 7.5s |

So **1.55x** is available from this one cache, and the mechanism demonstrably works: with
no guard, the fast path fires and the time falls.

**It is defeated by how often §5.5 rolls the table back, and both sound guards were
measured.**

- **The global floor** — trust only indices below the least rollback target ever used,
  which is the `tsafe` rule recorded above when a node cache was first tried. **No gain
  at all.** `put_snap` runs on every recursive-member retry, so one early rollback at a
  low `ntypes` pins the floor near zero and nothing is ever trusted again.
- **Generation-keyed** — bump a counter on each rollback, trust only entries written in
  the current generation. **Negative: 27.0s against 25.5s.** Rollbacks are frequent
  enough that a cache is invalidated before it is used, and the two extra fields cost
  ~1.5s.

The blocker is therefore not the cache's design but that **rollbacks are frequent and
they reuse indices**. Any validity stamp written at cache time loses to that, because
whether an index is still good depends on rollbacks that have not happened yet.

**What would work: stop reusing indices.** Keep `ntypes` monotonic across a rollback while
still discarding the garbage entries. Then no index is ever stale, no guard is needed, and
the full 1.55x is available. The cost is that the table gains holes, so positional `ty_at`
breaks and needs an index-to-type map — a change to §9.3's representation, not a tuning
tweak. Note that keeping the *entries* as well was the old behaviour and was rejected for
making the table track the number of derivations rather than the program; keeping only the
*counter* monotonic is a different proposition and has not been tried.

**One coupling worth knowing before touching `T.field`.** Inference's `binding` is
`{name, ty}` and §5.1 makes it a `T.field`, which is how `prims_from` hands §2's root
block from inference to lowering with one converter. Adding a field to `T.field` breaks
that in the *wrong* direction — a two-field record is not a subtype of a three-field one —
so `binding` has to grow the same fields. It surfaced only on a whole-closure typecheck,
not on the two files that were edited.

### Monotonic `ntypes`: 1.63x, and unsound — reverted

The two entries above failed to build a validity *guard* that tolerated index reuse. This
one removed the reuse instead: `put_snap` restores the table's lists and the trie, so the
garbage a discarded pass interned is unreachable, but does **not** reset `ntypes`. An
index is then never handed out twice, a cached one is valid for the whole run, and
`both_tyid` is just "neither is -1".

It works, and it is fast:

| | time |
|---|---|
| HEAD (trie only) | 26.50s |
| monotonic `ntypes` + field `tyid` | **16.24s** |
| the unguarded probe, for reference | 15.74s |

**1.63x**, landing within 0.5s of the unguarded probe — the cache fires at full rate.
223/223 behavioural steps pass, including `test-emit`'s 23 fixtures compiled and run, and
the rollback change *in isolation* (before the cache) is byte-identical on `types`, `ir`
and `infer`, the three modules whose recursive members exercise rollback.

**And it is unsound.** Regenerating, pass 2 fails to compile:

    error: redefinition of struct or union 'struct mpl_t89297057521717570'
      struct mpl_t89297057521717570 { mpl_t4579778294262423 f0; mpl_str f1; ... };
      struct mpl_t89297057521717570 { int64_t f0;               mpl_str f1; ... };

Twelve struct names are defined twice, and the two bodies **differ** — `f0` is a block in
one and `int64_t` in the other. So these are two *different* types under one
content-hash name, which means some type's `h` no longer matches its structure. That is a
break in interning itself, not a bookkeeping slip: a parent's hash is built from its
children's, so a child must have been interned under the wrong identity.

The mechanism is **not identified**. Two candidates, neither confirmed: a field's cached
`tyid` naming an index that a rollback has since padded to `⊥`, so two fields compare
equal on indices that no longer describe them; or `seal_rec`'s re-interning of a `μ`'s
unrolling interacting with the restored trie. Both are about a cached index outliving the
entry it names, which is the same hazard the guards were for — removing index *reuse* did
not remove index *invalidation*.

**What this cost, and what it bought.** The suite did not catch it: 223 steps green,
23 fixtures compiled and run. `cc` on the whole compiler did, on the second pass — the
fourth time in this file that a C compiler re-deriving every type found what the morphl
suite could not, and the second time that a *bigger* program was the stronger test rather
than more tests. Anyone resuming this should start by finding the mechanism on the
smallest input that reproduces it, which is somewhere between the fixtures and
`mplc.mpl`; the 1.63x is real and the approach is close.

**Retracted — see the next entry.** The mechanism was found, and the 1.63x was not real:
almost all of it came from the comparisons the attempt answered wrongly.

### Monotonic `ntypes`, the mechanism: an index proves equality, not inequality

The patch above was never saved, so it was rebuilt from the description — monotonic
`ntypes` (`put_snap` restores the lists and the trie, keeps the counter, and pads the
discarded entries with `⊥`), a `tyid` on `T.field` (and on inference's `binding`, for the
coupling recorded two entries up), set where `lower_item` already interns the field's
type, and `same_fields` comparing two fields by `tyid` when both have one. The rebuild is
faithful: pass 2 fails `cc` on **the same struct**, `mpl_t89297057521717570`.

**The smallest input is one line**, `$decl M $import "infer"`:

| input | redefinitions |
|---|---|
| every stage-1 module and fixture, as the entry file | 0 (`compiler.mpl` aside) |
| every subset of `{infer, lower, emit, verify}`, imported | 2 exactly when `infer` is in it |
| each of `infer`'s own imports (`prelude`, `lexer`, `parser`, `types`, `tyio`), imported | 0 |

`infer.mpl` as the *entry* does not reproduce it and `infer` as a *module* does. That is
the whole clue: a module's members are **derived**, so §5.5 lowers recursive members
twice and rolls the first pass back — and rollback is what the patch changed.

**The mechanism.** Monotonic `ntypes` makes an index never be handed out twice, so two
fields with **equal** `tyid`s really do have one type. It does **not** make **unequal**
`tyid`s mean unequal types, and the patch assumed it did. A type is a structural value,
so one built in a pass that is then rolled back survives the rollback — `lower_prop_func`
keeps the first pass's `fty` on purpose — and its fields still carry `tyid`s naming
entries that are now `⊥` padding. When such a node is interned again, it meets a
structurally identical type whose fields carry the *live* indices, and `same_fields`
answers "different". Interning then breaks twice over:

1. **Duplicate entries.** `ty_find` misses the existing entry, `add_ty` adds a second with
   the same structure — so the same content hash, so the same C name, defined twice.
2. **`int64_t` fields.** `emit_fields` finds each field's type by a structural `find_ty`
   and writes `int64_t` when the search misses. That is why the two bodies differ: in the
   failing copy `f0` and two union members are `int64_t` where the other has blocks.

Both PERF.md candidates were close and neither was it: a cached index outliving its entry
is right, but what made it wrong was not that the entry was padded — it was that a
*different* index for the same structure was read as a different type.

**The sound version trusts the index for equality only** — equal `tyid`s answer `true`,
anything else falls through to the structural `same`. On the one-liner it removes the
redefinitions; on the whole compiler it reaches a fixed point, and it emits C
**byte-identical** to the unpatched lowering's on the same source, which says it changes
nothing but work. Interleaved, on the same box:

| self-emit of `mplc.mpl` | time |
|---|---|
| committed | 42.2 / 43.5 / 43.3s |
| sound (equality only) | 41.5 / 41.9 / 42.2s |
| the attempt as recorded (unsound) | 34.3 / 35.0 / 35.0s |

**2–3%, against 1.24x for the unsound version** (1.63x when this file first measured it,
on an older tree). So the speed was the wrong answers: the comparisons the unsound
version skipped are the stale-against-live ones, which are structurally *equal* — and an
equal comparison is a full `same_deep` walk, the expensive case, while an unequal one is
already cheap because the hash guard rejects it. Skipping them saved exactly the work
that had to be done. Reverted: 2–3% does not pay for a field on `T.field`, the matching
one on `binding`, and padding in `put_snap`.

**What this closes.** "Stop reusing indices" was this file's answer to why every cached
index lost to rollback. It removes reuse, and reuse was not the only hazard: **a type
value outlives the rollback that invalidated the indices inside it.** Any cache of
interned indices on type nodes or fields has to survive that, which none of the four
attempts does. The remaining routes are the ones already named — recursive interning
(every subterm interned as it is built, so no fresh node is ever compared deeply) or a
cheaper `same_deep` — and neither is a tuning change.

**Two habits that found it, worth keeping.** The reconstruction was confirmed by
reproducing the *exact* recorded failure, down to the struct name, before anything was
concluded from it. And the subset table — every combination of the top modules — turned
"somewhere between the fixtures and `mplc.mpl`" into one line in sixteen runs of a few
seconds each, because the compiled compiler makes each probe cheap.

### Recursive interning: the table would not grow much, and that is not the obstacle

The entry above closes the cached-index route and leaves two: recursive interning (intern
every subterm as it is built, so no fresh type ever needs a deep comparison — children
compare by index) or a cheaper `same_deep`. The worry about the first, recorded two entries
up, was size: "every intermediate type becomes an emitted struct". So it was measured
before anything was designed.

**Method.** Two numbers bound the table recursive interning would build, both on the whole
compiler (`mplc.mpl`):

- **The floor** — today's final table closed under subterms. A throwaway driver ran `check`
  and walked every entry's subterms (fields, props' types, params and results, members,
  `μ` bodies, references, arrays), deduplicating with the same trie interning uses.
- **The ceiling** — every compound type *constructed* while lowering. `types.mpl`'s nine
  compound constructors (`raw_block`, `raw_union`, `raw_inter`, `t_group`, `t_func_fr`,
  `t_ref_k`, `t_array`, `t_rec`, `t_over`) were wrapped to record each node into a global
  set (hash bucket, then `T.same`), switched on at the top of `lower_file` so inference's
  types are not counted.

| on `mplc.mpl` | entries |
|---|---|
| §9.3's table today | 1,836 |
| closed under subterms — **floor** | **1,982** (+8%) |
| compound types constructed while lowering, distinct — **ceiling** | **4,345** (~2.4x) |
| compound constructions while lowering, total | 92,542 |

(1,836 is with the instrumentation's own few types in the closure; uninstrumented the table is
1,811 and its closure 1,956 — the same +8%.) The closure splits blocks 779, unions 139, `μ` 53,
groups 1, arrays 1, functions 907, references 94, leaves 8.

**Reading it.** Almost every subterm of a final type is already interned — the closure adds
8%. The ceiling counts temporaries *and* everything built in passes §5.5 rolls back, which a
rollback truncates out of the table, so a real recursive-interning table lands between the
two. Emit writes a struct per block, union, group, `μ` or array — about 53% of entries — and
struct definitions are ~98 KB of the 2.19 MB the compiler emits. Even at the ceiling with the
same mix that is ~+140 KB, **about 6% more C**. And 92.5k constructions is 92.5k interning
lookups, each comparing children by index rather than walking them.

**So size is not what stands in the way; architecture is.** `types.mpl`'s constructors are
pure functions with no access to lowering's table, and inference builds types too, so
recursive interning means a table every type operation can reach — global, or threaded
through `T` — and a decision about whether inference shares it. That is the redesign to
scope next, together with how much of `same_deep`'s time it would actually remove, which
this does not measure: it bounds the cost of the table, not the saving.

**It found a miscompile on the way**, which is why the instrumentation is worth describing.
The recorder was `$fwd`'d beside the constructors, and its body names the global set written
further down. A `$fwd`'d function is lowered at the `$fwd`'s position, so the set's thunk —
and the trie type its initialiser names — were lifted early and out of source order, and a
module's initialiser ran in index order: the set was assigned before the value it copies,
and the first lookup dereferenced NULL. That is not an instrumentation bug. A four-line
module reproduces it — `$fwd f  $decl a 5  $decl b $call add (a, 1)  $decl f $func () b`
answered 1 where stage 0 says 6 — and the compiler's own C had three members out of order.
Fixed by ordering a module's initialiser by rank (`emit_mod_init`);
`stage1/fixtures/init_fwd.mpl` is the regression test. The measurement was rerun with the
recorder's state moved above its first use.

### What recursive interning would save: ~3.2x, because 70% of the time confirms equal types

The entry above bounds what recursive interning would *cost* in table size. This bounds what
it would *save*. Under recursive interning `T.same (a, b)` is an index comparison, so the
saving is at most what `same` and its helpers cost today. Measured two ways on the compiled
compiler emitting `mplc.mpl`:

| | result |
|---|---|
| `same` inclusive (`perf`, frame pointers) | **70.4%** — the contified `same`/`same_deep` group is 69.8% |
| committed compiler, self-emit | 40.5 / 41.4 / 42.1s |
| probe: `same` answers from the hash alone | **12.1 / 13.2 / 13.4s** |
| pairs with equal hashes that `same` was asked to confirm | 320,417,043 |
| …of which `same_deep` said were *not* the same type | 1 |

The two agree: the profile says ~70% of the run is comparing types, and making that O(1)
leaves ~30%. The last two rows say where it goes — confirming types that are almost always
equal, with a full structural walk each, since a hash mismatch already rejects the unequal
ones cheaply. That is exactly what an index comparison replaces, and it is the same lesson as
the monotonic-`ntypes` entry from the other side: the expensive comparisons are the equal
ones.

**Not counted, so 3.2x is a ceiling:** the lookup recursive interning adds at each of the
92,542 constructions, making the table reachable from `types.mpl`, and inference's
constructions if it shares the table. None looks large beside 320M deep walks, but none is
measured.

**The probe found that the structural hash is linear, so its collisions are structured.**
The one disagreement:

    (Str) -> <{tag=s"none",},{v:Int,tag=s"some",}>
    (Int) -> <{tag=s"none",},{v:Str,tag=s"some",}>

`hmix (a, b)` is `a * 31 + b` mod `hmod`, so a type's hash is a polynomial in its leaves'
hashes, and swapping `Int` (1) and `Str` (3) between two positions of equal weight leaves it
unchanged. The argument recorded with the wider `hmod` — that a birthday collision over the
table is near 1e-10 — assumes a random hash, and this is not one. For comparison it is
harmless: `same` falls back to `same_deep` on equal hashes, which is why the real compiler's
output was right and the probe's was not (it warned `cannot coerce Int to Str` and emitted
different C). For **naming** it is a latent hazard: a struct's C name comes from this hash, so
two distinct *block* types that collide would share one — loud, a `cc` redefinition, not
silent. Today's collision is between function types, which emit no struct. Recursive interning
would not depend on the hash at all, comparing children by index; a non-linear mix in `hmix`
removes the naming hazard independently, at the price of renaming every struct.

**Done: `hmix` is non-linear** — `a * 31 + b` and then a scramble by a square (`hscramble`), split
at 10⁹ so it cannot overflow, since §8's bootstrap has no bitwise operators and `mul` panics. The
pair above went from sharing 281,841,995 to 72,416,274,090,152,254 and 35,318,159,790,175,216 —
the old values also show how little of `hmod`'s range a linear fold of small leaf constants used.
Rerunning the count over a self-emit: **0 of 320,417,995** hash-equal pairs are not the same type.
Every struct is renamed and nothing else changes; the self-emit is 40.0s, the same as before.

### Lowering's three linear scans, indexed: 1.45x

With types compared by class and `has_var` a field read (INTERNING.md), a profile of the 10s
self-emit put three plain list scans in lowering at **40.6%** between them — `lookup` 19.5%
(the name environment), `find_mdone` 13.6% (a module's lowered members by name), `find_mod`
7.6% (the module list by id). Each is now indexed by a persistent trie, *beside* the list
rather than instead of it, because each list's answer is "the first match" and the index has
to give exactly that one:

- **`find_mod`** — `lstate.modix`, keyed by the id's bits, changed at the three places the list
  is (`fresh_mod_ic`, `save_mod`, `put_snap`), and in the snapshot with it.
- **`find_mdone`** — `mod_ent.dix`, keyed by the name's hash, on the entry itself so a rollback
  restores the two together; each bucket is newest first, like the list. The two rebuild sites
  carry it, and `note_prop` adds to it. `member_ir`/`member_ty` still scan, being once per
  module.
- **`lookup`** — environments stay lists (extended a binding at a time; shadowing is first
  match), but a long-lived one gets an **index entry** on top (`with_index`): slot `-7`, name
  `$index`, carrying a trie of every binding below it. A lookup that reaches one answers from
  it and stops. Placed on a module's member environment, the root block, the entry file's
  globals and each thunk member's scoped environment. A module's environment is its members
  consed onto the intrinsics, so every reference to `add` or `concat` used to walk past every
  member to reach them.

Each was built and measured separately, and after each the *committed* compiler was timed
compiling the new source — the check for the source-shape blow-up that once made lowering
`lower.mpl` run out of memory — which stayed normal (9–11s):

| self-emit of `mplc.mpl` | committed | change |
|---|---|---|
| `find_mod` indexed | 10.2–10.8s | 9.6–10.3s |
| `+ find_mdone` indexed | 10.3–10.6s | 8.8–9.3s |
| `+ lookup` indexed | 10.9–11.9s | **7.6–8.0s** |

**~1.45x** over the three; the emitted C is byte-identical at every stage. Memory rose 5.6%
(2,509 MB against 2,376 MB), most of it the per-thunk scoped environments' indexes. Since the
start of the interning work the self-emit has gone from ~45s to ~8s, **~5.7x**.

### `occurs` pruned by `pv`: 7.5%, of a 12% share

Profiled again after the indexed scans, the self-emit (~7.4s) had no single leader; the largest
group was `T.occurs` and its two list helpers at **~11.9%** of self time — the walk asking
whether placeholder `R` appears in a type. A type whose `pv` flag is false holds no placeholder
at all (INTERNING.md), so it cannot hold `R`: `occurs` now returns `false` there before
matching, and since it recurses through its children the guard prunes every such subtree too.
Exact by construction — `occurs` finds placeholders only through its `var` case, and walks the
same children `has_var` does (fields, not props' types).

| self-emit | committed | `occurs` pruned |
|---|---|---|
| interleaved | 7.21 / 7.27 / 7.53s | **6.67 / 6.99 / 6.70s** |

**~7.5%**, against a 12% share: much of the time was on types that really do hold a placeholder,
which the guard cannot skip. Output byte-identical. The share was read off *self* time, which a
deep recursion does not distort; the inclusive figures do undercount here, because the compiler's
recursion exceeds perf's 127-frame stack limit and a truncated stack never reaches `main`. The
phases were timed directly instead — parse+infer ~1.9s, lowering ~3.8s, emit ~1.6s.

### The type and function tables, indexed by position: 10%

The same profile's second group was positional indexing: `P.list.nth` over the **type table**
(7.8% of self time — lowering's `ty_at`, emit's `type_at`) and over the **function table** (3.1% —
emit's `fn_at`, and `key_at`'s parallel name list). Each lookup walked from the head to entry *i*.

- `IR.ix_put`/`ix_get` reuse the type index's own trie as an index-keyed map: entry *i* filed
  under `i mod 1021`, a leaf scanned by index, so it is right at any table size.
- **Lowering** keeps it as `lstate.tyix`, added to in `add_ty` (the table's only append) and
  saved and restored by the snapshot beside the trie interning already uses.
- **Emit** builds both indexes at the top of every `emit_program` — the types, and one trie
  holding each function with its C name — in module storage, because `type_at` and `fn_at`
  take the table rather than the state at ~40 call sites. Nothing outside `emit_program` calls
  them, and each call rebuilds both first, so one program's index never answers for another's;
  `emit_test` and `compiler_test`, which emit several programs per process, pass.

| self-emit | committed | indexed |
|---|---|---|
| interleaved | 6.81 / 6.83 / 6.91s | **6.23 / 6.30 / 6.03s** |

**~10%**, against an ~11% share; output byte-identical. The self-emit is now ~6.2s, from ~45s
before the interning work: **~7.3x**.

### Lowering is super-additive, so there is nothing per-module to cache

The interface cache works because **inference is additive**: per-module marginals sum to
~26.8s against the whole closure's 26.85s, so skipping an unchanged module skips its whole
contribution. That property is what a per-module cache *is*. Lowering was assumed to share
it and does not.

Measured compiled, one `mplc` run per module — each row is that module's whole closure, so
the rows are cumulative, not disjoint:

| closure | structs | emitted lines | time |
|---|---|---|---|
| `prelude` | — | — | 0.010s |
| `lexer` | — | — | 0.022s |
| `parser` | — | — | 0.110s |
| `types` | 78 | 10,448 | 0.212s |
| `ir` | 143 | 13,263 | 0.494s |
| `verify` | 248 | 24,518 | 0.926s |
| `emit` | 357 | 40,219 | 1.773s |
| `lower` | 404 | 40,046 | 2.387s |
| **`compiler`** | **687** | **79,077** | **25.963s** |

**Per-module marginals sum to ~5.3s; the union costs 26.0s — 4.9x super-additive.**
Subtracting each module's dependency closure from its own: prelude 0.010, lexer 0.012,
parser 0.088, types 0.202, ir 0.282, verify 0.332, emit 1.179, infer 1.404, lower 1.793.
The arithmetic is coarse, because the dependency sets overlap and the subtraction
double-counts what they share — but it errs *high*, and no reading of it approaches 26.0s.

The same fact from the other direction: **`compiler.mpl` is 1.97x `lower.mpl`'s closure in
emitted lines and 1.70x in interned types, and costs 10.9x the time.** Two points on a
curve, so the exponent (~3.5 in program size) is not a law — but the direction is not in
doubt, and it is the opposite of additive.

**The mechanism is already recorded here, applied to counts rather than to time.** §4.9
monomorphises per argument type, so the combined closure has far more distinct list element
types than any part of it — the front end interns 1,382 and `lower`'s closure 1,244 against
6,062 for the union, 2.3x their sum. §9.3 then makes interning the dominant cost, and
`same_deep` is 68% of it on types that get *deeper* as the closure grows. So the cost
compounds in two directions at once: more lookups, each comparing bigger types.

**What that rules out.** Lowering's cost does not belong to any module; it belongs to the
combination. A module keyed on its own source cannot predict what it lowers *to*, because
which specialisations it needs is a property of the whole program (§4.9) — which is the
same fact recorded above as "a template-holding module stays program-dependent, and that is
correct". So the thing step one and step two were built toward — a module's output as a
function of its own source — is true of the **text** and false of the **work**.

**And it rules out the obvious next step specifically.** Caching a module's *emitted C* is
worth emit's share of a compiled build, which is **1.8%**, and it does not avoid lowering
that module, because its importers need the type table and specialisations that lowering it
produces. The stage-0 measurement that made it look worthwhile ("emit is at most 22% of a
compile") is one of the shares this file has already corrected: it was 22% of an
*interpreted* compile.

**What is not ruled out is caching the lowered IR**, which is a different proposition and a
much larger one. The load cost is favourable by construction — 687 types read structurally
and re-interned is 687 interns against the ~1.2M a derivation performs — so the super-linear
part is exactly what a cache would skip. It needs the IR serialised (`tyio` does types
only, and the tree is several times that), function indices relocated on load, and shared
specialisations resolved against whatever the importing program needs.

**Where this leaves the ordering.** `same_deep` comes first regardless: it is 68% of
lowering with a measured 3.3x ceiling, it pays on the first build as well as every later
one, it invalidates nothing, and it attacks the very super-linearity that makes
incrementality worth having. An IR cache built on top of today's interning would be caching
a cost that should not exist.

### Where the compiled compiler's memory goes, and `put_mod`: −27%

Measured on a self-emit by instrumenting the *emitted* C (no change to `stage1/`): every
`mpl_alloc((int64_t)sizeof(T))` site counts its bytes under `T`, `mpl_alloc` allocates
through Boehm's `GC_MALLOC`, and each phase entry collects and reports what is still
reachable. The output is byte-identical to an uninstrumented run, so this is the real
workload. The instrument is `meas/instrument.py` in a session scratchpad: a sed-level
rewrite of `bootstrap/mplc.c` plus `-lgc`, cheap to recreate.

| phase | allocated | share | live at its end |
|---|---|---|---|
| parse | 0.1 MB | ~0% | 0.3 MB |
| infer | 742 MB | 22% | 116 MB |
| lower | 2,423 MB | 71% | 225 MB |
| verify | 44 MB | 1% | 257 MB |
| emit | 211 MB | 6% | 230 MB |
| **total** | **3,421 MB** | | peak live 257 MB |

**About 92% of everything allocated is garbage by the next phase boundary**, and since the
compiled runtime never frees (BOOTSTRAP §3), its peak memory is the whole 3.4 GB. By type,
the largest single item was one list:

| bytes | share | what |
|---|---|---|
| 912 MB | 26.7% | the module list, rebuilt per update (`put_mod`) — 7.0M cells of 136 B |
| 939 MB | 27.5% | untyped: strings and arrays |
| 331 MB | 9.7% | environment lists (`benv` bindings) |
| 196 MB | 5.7% | lists of types |

**`put_mod` was the O(n) update of an immutable list, again** — the shape of `append_ty`
and `put_lifted`. `save_mod` rebuilt `st.mods` up to the entry on every update, though the
list answers only `find_mod_path`, by an entry's `id` and `path`, which never change after
registration; every lookup by id already went to the `modix` trie. So `save_mod` now
updates the trie alone, the list keeps each module as registered, and the dead list-based
`find_mod` is gone.

| self-emit | before | after |
|---|---|---|
| allocated | 3,421 MB | **2,505 MB** (−27%) |
| lowering's share | 2,423 MB | 1,523 MB |
| time (mean of 5, interleaved) | 9.59 s | **8.98 s** (−6%) |

The emitted C is byte-identical everywhere. **What it says about §7.6:** the biggest cost
was an algorithm, not a lifetime, and what garbage is left is short-lived and interleaved
with live data inside one phase — so whole-phase arenas would reclaim little without
lowering being restructured to build its keepers under an outer allocator. The untyped
919 MB is the next thing to attribute, by call site, before any allocator design.

### Strings: the union sort rendered every member, every time — −32%

The 919 MB of untyped allocation left after `put_mod` was measured the same way, with each
call to a string-building runtime function tagged by the morphl function containing it (a
comma expression in callee position, so the call itself is unchanged). It was almost all
`concat` (914 MB), and two sites made most of it:

| site | bytes | what |
|---|---|---|
| `T.show`, reached from `shty_addall` | 785 MB in 189,499 sorts | `t_union` orders members by rendering |
| `c_bytes` | 116 MB in 23,940 calls of ~5 KB | a literal's octal escapes, appended one byte at a time |

**The sort was CLAUDE.md's recorded trade, and its premise did not hold.** Rendering was
chosen over a structural comparator as correct and obvious, on the reasoning that it "runs
only when a union has two or more distinct members". But `remap`, `subst` and `unroll`
rebuild unions constantly, each rebuild re-sorts, and a rendering is proportional to the
whole type — members are often big recursive unions, so a render averaged over 1 KB. The
first attribution misled, worth knowing: wrapping calls into `show` from "outside the
rendering family" charged `show`'s own helper `show_sorted_add` with 797 MB, because it
was left off the family list while the real caller was put on it. A self-call is not a
caller.

**The fix keeps the order and stops repeating the work.** A rendering is a function of the
type's class — `show` prints exactly what `same` compares — so `sort_key` renders each
class once and keeps it, in a trie by `cid` shaped like `ctable`. Member order, and so every
§7.5 discriminator, is unchanged; the emitted C is byte-identical everywhere. `c_bytes`
collects its pieces and joins them in pairs (`join_all`), CLAUDE.md's rule for exactly this.

| self-emit | before | after |
|---|---|---|
| allocated | 2,505 MB | **1,705 MB** (−32%) |
| untyped (strings, arrays) | 919 MB | 165 MB |
| live at verify | 246 MB | 266 MB (the cache, +20 MB) |
| time (mean of 5, interleaved) | 9.41 s | **8.72 s** (−7%) |

Together with `put_mod`, a self-emit allocates **half what it did (3,421 → 1,705 MB)**, and
since the compiled runtime never frees, its peak memory halves with it.

### Environment lists: two allocation patterns in lookup code — −11%

The 333 MB of environment (`benv`/binding) list cells, attributed by allocation site and
then — because most sat behind `P.list`'s one shared `cons` — by the morphl function making
each `cons` call:

| site | share | what |
|---|---|---|
| `pt_leaf`, via `pt_kid` | 102 MB | a fresh empty leaf for every absent child of the name index |
| `dx_scan` (a *lookup*) | 35% of the `cons` calls | its hit answered as a fresh one-element list |
| `pt_add`, `ix_segment`, `with_scope`, `bind_params`, … | the rest | ordinary environment growth |

**Both are lookup structures allocating on the read side.** A trie's leaf boxes its list,
and the list node holds a binding inline, so an empty leaf is 152 bytes — and `pt_kid`
made a new one for each of the two children at each of `pt_depth` levels of a fresh path.
The trie is persistent, so one empty leaf serves them all; IR's type-table trie already
shared one (`trie_empty`), and now `ptrie`, `dxtrie`, `mxtrie`, emit's `ftrie`, `ctable`'s
`ctrie` and the rendering cache do too. And nine finders in `lower.mpl` — `dx_scan`,
`find_mdone`, `find_mprop`, `find_tmpl`, `find_spec`, `find_mod_path`, `find_rcv`,
`find_fnm`, `find_fdef` — answered a hit as `cons (xs.head, nil)`, "a list of zero or one";
every caller reads only `.head`, so they return the suffix from the hit instead.

| self-emit | before | after |
|---|---|---|
| allocated | 1,705 MB | **1,516 MB** (−11%) |
| live at the end | 270 MB | 230 MB |
| time (mean of 5, interleaved) | 8.57 s | **8.29 s** (−3%) |

Byte-identical output throughout. From the start of this measurement work a self-emit has
gone from **3,421 MB to 1,516 MB (−56%)**. What is left of the environment lists is
`pt_add`, `ix_segment`, `with_scope` and `bind_params` building environments — growth, not
repeated work.

### Retries nested: a member re-lowered 2^depth times — −68%

By 1684f97 a self-emit allocated **3,264 MB, against the 1,516 MB above**, and needed more
than 4 GB of address space, so a 4 GB-capped `mplc stage1/compiler.mpl` died in emit's
output join. Measured at eleven commits with each commit's own compiler, it was no single
change: lowering grew with every feature, far faster than the source.

| commit | closure lines | infer | lower | total |
|---|---|---|---|---|
| 9541132 (above) | 17,146 | 396 MB | 977 MB | 1,516 MB |
| 70181aa (places) | 18,102 | 420 | 1,268 | 1,844 |
| b232b65 (template application) | 18,957 | 468 | 1,465 | 2,098 |
| 828c804 (std/list) | 19,530 | 489 | 1,761 | 2,419 |
| 0795113 (defer step 4) | 20,637 | 541 | 2,193 | 2,916 |
| 1684f97 | 21,251 | 553 | 2,522 | 3,264 |

Source +24%, lowering +158%. Every site in the allocation profile grew about 2.5x, which
says *more work per line*, not a worse site — and counting calls said what: `lower_prop_func`
ran **55,562 times for ~2,300 functions**, and per member the counts were powers of two
(`prop_by_id` 4,096, `unseen_props` 2,048, the leaf `digits_int` 512).

**A member's §5.5 retry rolls back and redoes everything lowered beneath it**, so a member
first reached under *d* retrying ancestors is lowered 2^d times. And nearly every member of
lowering's big recursive group retried: a member retried whenever *anything* under it read
an unsettled member. Logged, 17,007 of 17,335 retries came from a read of the member itself
or of a *descendant*, and a descendant's read has already been answered by that descendant's
own retry; a read of an *ancestor* still in progress cannot be answered by a retry at all,
since that ancestor will roll this one back and redo it once it settles.

So a member now keeps a stack of the `$func` members in progress (`lpstack`) and the
shallowest depth read unsettled under it (`minread`), and retries only when **it itself**
was read — or when a read was of something not on the stack (`nunk`), the old rule kept for
the cases it does not understand. A read of an ancestor defers to the ancestor, and the
ancestor sees it because the depth is propagated upward.

| self-emit | before | after |
|---|---|---|
| `lower_prop_func` calls | 55,562 | **4,411** |
| lowering allocates | 2,522 MB | **300 MB** (−88%) |
| total allocated | 3,264 MB | **1,042 MB** (−68%) |
| time (mean of 3, interleaved) | 21.3 s | **6.5 s** (3.3x) |
| `mplc stage1/compiler.mpl` | dies under 4 GB | runs under 2 GB |

The output is the same program: the same 2,296 functions, 2,292 of them identical modulo
counter-numbered names (`next_rank` counted every rolled-back lambda, so the numbers shrink)
and four that lost an identity union-to-union re-tag their node no longer needed.

Two things on the way are worth keeping. **The first fix was half of it**: skipping the retry
on an ancestor read alone took lowering only to 1,382 MB, with the counts still powers of two
(2,052, 1,026, 513), because a read of a *descendant* still triggered one. And **a 4 GB cap
reads as a lowering blow-up**: an hour went into bisecting what turned out to be HEAD already
needing 4–4.5 GB — `regen.sh` runs under 8 GB, and the cap, not the change, was the wall.
