# Recursive interning — design

**Status: steps 1 and 2 built (see the measurements at the end); step 3 not.** Step 2 is
the 3.1x. The goal is the ~3.2x that `T.same` costs today. Read
PERF.md's last three `same_deep` entries first; this is the design they point at.

## 1. Why, in numbers

On the compiled compiler emitting `mplc.mpl`:

- `T.same` is **70.4%** of the run, inclusive.
- A probe where `same` answers from the hash alone emits itself in **12–13s against 40–42s**.
  That is the ceiling: equality made O(1) for every caller.
- `same` is handed **320 million** pairs with equal hashes per self-emit, and every one of
  them turns out to be the same type. The cost is *confirming equal types*, each with a
  full structural walk. An unequal pair is already cheap: the hash guard rejects it.

What recursive interning costs in size was measured too. The table holds 1,811 entries
today; closed under subterms it is 1,982, and every compound type built while lowering is
4,345 distinct. Even at the ceiling that is ~6% more emitted C, so size is not the issue.

## 2. Why the previous attempts failed, and what is different here

Four attempts cached an **emission index** — a position in §9.3's table, the number emit
turns into a struct — on a type node or a field. All four lost to §5.5's rollback: a
discarded pass's entries are removed and their indices handed out again, and a type
*value* built in that pass survives the rollback still carrying them. Keeping the counter
monotonic removed index reuse but not that: a surviving value carried indices naming
padding, and the cache read "different index" as "different type".

This design caches something rollback never touches: an **identity**.

| | identity (`cid`) | emission index (§9.3) |
|---|---|---|
| what it names | a type's structure, up to what `same` ignores | a struct emit writes |
| assigned | when a node is constructed | when lowering interns it |
| table | one, global, **append-only**, never rolled back | per lowering, rolled back by `put_snap` |
| reaches the output | **never** | as a struct, named from `h` |

Because the identity table is never rolled back, a `cid` names one structure for the whole
run, garbage and all. A value surviving a rollback carries `cid`s that are still exactly
right. Because a `cid` never reaches the output, its allocation order cannot leak into
names, discriminators or anything else `test-stable` checks.

## 3. Representation

Every compound node — the nine kinds the constructors in `types.mpl` build: `block`,
`union`, `inter`, `group`, `func`, `ref`, `array`, `rec`, `over` — gains a field **`cid`**.
It is not called `id`, because `var` and `tmpl` already have an `id` meaning something
else.

- **Leaves** (`Int`, `Str`, the booleans, `unit`, `⊥`, `Float`) have fixed `cid`s.
- **`var`, `bnd`, `tmpl`** are keyed on their integer (`id`, `idx`, `id`) and get `cid`s
  from the table like any node, so every node a constructor returns has one.
- **`proto_ty`'s members** are prototypes written as literals, not constructed. They keep
  `cid = -1`, and *Equality* below says what `-1` means.

**A node is not unique; its `cid` is its class.** Two nodes may share a `cid` and still differ
in a field `same` ignores, and that is required. `same` ignores a function's `frame`
(§5.3a's closure flag) and a prop's `ty`, so those stay on the node and out of the key. A
constructor therefore returns *its own* node with the class's `cid` set. It does not return
a canonical object, which would lose the ignored fields.

## 4. The identity table

Module-level storage in `types.mpl`, with `unroll_cache` as precedent. It must be declared
**above** the constructors: a module initialises in source order, and the constructors run
during `types`' own initialisation (the init-order bug fixed in `emit_mod_init` was found
exactly this way).

A key is the node's tag, its scalars, and its children's `cid`s:

| tag | key |
|---|---|
| `block` | each field's name and `cid`, in order; each prop's name and value (`cv_eq`) — **not** the prop's `ty` |
| `group`, `union`, `over` | members' `cid`s, in order |
| `inter` | members' `cid`s **as a set** (sorted), since `same` compares intersections with `same_set` |
| `func` | params' `cid`s, result's `cid` — **not** `frame` |
| `ref` | `qual`, `kind`, inner's `cid` |
| `array`, `rec` | the child's `cid` |
| `var`, `bnd`, `tmpl` | the integer |

**That table is `same_deep`, case by case, and it has to stay so.** A field in the key that
`same` ignores splits one type into two classes: missed equalities, which are slow and
otherwise harmless. A field `same` compares and the key omits merges two types into one
class, which is a miscompile. *Validation* below tests the second direction.

Lookup is a bucket by a hash **of the key itself**, then a comparison of keys that is all
integers, plus `eq_str` on names and `cv_eq` on prop values. It never walks a child. The table
only grows: no rollback, no removal.

The bucket must be chosen by the key and not by the type's `h`, though `h` is right there and
equal classes share it. Bucketing by `h` lets everything `h` covers decide a class too, so a
key with a gap merges two types only when their `h`s collide mod the bucket count. A broken key
then almost never shows, and nothing can see it. That was step 1 as first built, and paranoid
mode reported 0 merges with field names deleted from the block key.

## 5. Equality, and the fallback

```
same (a, b) = if a.cid >= 0 and b.cid >= 0 then a.cid == b.cid
              else (today's hash guard, then same_deep)
```

`same_deep` stays. It answers for prototypes, and for any node a missed constructor path
leaves without a `cid`. That case is correct and merely slow, and paranoid mode (*Validation*)
counts it.

## 6. Lowering's table

`intern (st, t)` maps `t.cid` to an emission index through a persistent integer trie on
`lstate`, snapshotted and restored by `put_snap` exactly as the type trie is today. Emission
indices stay dense, `ty_at` is unchanged, and struct names still come from `h`. So the
emitted C should be **byte-identical**, and that is the first test.

`unroll_cache` is keyed by `same` today; it becomes a `cid` → unrolling map.

## 7. What must not change

- **A union's canonical member order.** `t_union` sorts by rendering, and that order *is*
  §7.5's discriminator. `cid`s depend on construction order, so sorting by `cid` would make
  discriminators a function of the program rather than of the type. The sort stays as it
  is.
- **`h`.** It still names structs, and still guards `same_deep` in the fallback.
- **Inference's behaviour.** Inference shares the table automatically, since its
  constructors are the same functions. It gets faster `same` too, though it is only ~2% of
  the run.

## 8. Validation

1. **Byte-identical output.** The self-emit and every fixture, straight and through
   `opt_c`. `cid`s never reach the output, so any difference is a bug.
2. **Paranoid mode**, the same instrument that found the hash collision. A build where
   `same` computes both answers and counts disagreements, in both directions, over a
   self-emit. Both counts must be 0. It also counts fallbacks (a node without a `cid`), to
   find missed constructor paths.
3. **Fixed point, rot guard, `zig build test`**, including `test-compiled-suites`.
4. **Timing**, interleaved against the committed compiler.

## 9. Steps, each regenerated and checked on its own

1. `cid` on the nodes, the identity table, the constructors filling it; `same` unchanged.
   Output byte-identical. **Measures** the table's size over a whole run *including
   inference*, and what construction now costs. Neither is known yet.
2. `same` uses `cid`s with the fallback. Paranoid mode 0/0. **Measures the speed-up**, which
   is only bounded today (ceiling 3.2x, minus step 1's construction cost).
3. Lowering's `intern` and `unroll_cache` keyed by `cid`.

Each step can stop the work: step 1 if construction is too dear, step 2 if the speed-up
does not materialise.

## 10. Risks

- **The key drifting from `same_deep`.** Mitigated by the key table above, by paranoid mode, and by
  keeping both in one file. A new type kind needs a key row, and a test that fails without
  one.
- **Memory.** One word per node, plus one table entry per distinct class for the whole run,
  inference included, with nothing freed. Step 1 measures it.
- **Stage 0.** The suites and the typecheck sweep run interpreted. Interning costs a lookup
  per construction there too, against walks it saves. Step 1 measures `test-stage1` before
  and after.
- **A constructor bypass.** A node literal written outside `types.mpl`'s constructors has
  `cid = -1` and silently takes the slow path. Paranoid mode's fallback count finds it.

## 11. Decisions for review

1. **Inference shares the table.** This falls out of using one set of constructors; not
   sharing would need two. Recommended.
2. **`same_deep` stays as the fallback permanently**, rather than being removed once every
   path has a `cid`. Recommended: the prototypes need it, and it is the reference that
   paranoid mode checks against.
3. **Paranoid mode as a committed build option** rather than a throwaway patch. **Done:** see
   *Paranoid mode* below.

## Step 1, measured

`cid` on every compound node, the identity table, and all ten compound constructors filling
it (`types.mpl`: `cid_of`, `ckey`, `cid_for`); `same` unchanged. On `mplc.mpl`:

| | committed | step 1 |
|---|---|---|
| emitted C | — | **byte-identical** (self-emit, every fixture, `lexer`, `types`) |
| self-emit, interleaved | 43.2 / 46.4 / 46.3s | 47.2 / 48.0 / 47.2s (~+5%) |
| peak memory | 1,870 MB | 2,001 MB (+7%) |
| identity classes, whole run | — | **7,729** (5,141 after inference) |
| `infer_test` under stage 0 | 2.06s | 2.58s (+25%) |

- **The table is small.** 7,729 classes for a run that does 320M deep comparisons. Sharing it
  with inference costs nothing visible: inference's classes are most of the table, and the
  table is still trivial.
- **Construction costs ~5% compiled and ~25% interpreted**, all of it overhead until step 2 makes
  `same` read the `cid`s. Step 2 has to repay that before it shows any gain. Its ceiling is the
  hash-only probe's 12–13s.
- **Stage 0 pays more** because a lookup there is interpreted work with nothing yet saved. If step
  2 does not recover it for the interpreted suites too, `test-stage1` gets slower. Step 2 should
  measure that as well.

## Step 2, measured

`same` compares classes when both types have one, and falls back to the hash guard and
`same_deep` otherwise. On `mplc.mpl`:

| | `HEAD` (before step 1) | step 2 |
|---|---|---|
| emitted C | — | **byte-identical** (self-emit, every fixture, `lexer`, `types`, `infer`) |
| self-emit, interleaved | 46.5 / 44.2 / 46.7s | **15.3 / 14.5 / 14.4s — 3.1x** |
| peak memory | 1,870 MB | 2,002 MB (+7%) |

That is within ~2s of the hash-only probe's 12–13s, which was the ceiling: almost all of what
O(1) equality can buy is bought, and step 1's construction cost is what remains of the gap.

**Paranoid mode over a whole self-emit:** 366,007,522 comparisons answered by class, **0
fallbacks** (every type compared had a class), **0 class-equal but not `same`** — the direction
that would miscompile — and **0 `same` but class-different**. The key mirrors `same_deep` exactly
on everything the compiler builds. (Built as a temporary variant of `same` reporting through
`mplc`, not committed; decision 3 is still open.)

**Stage 0 does not get the gain.** Interpreted, a lookup costs about as much as the walks it
saves on real work, and more on the short suites:

| under stage 0 | `HEAD` | step 2 |
|---|---|---|
| `emit_c` on `lexer.mpl` | 5.55s | 5.57s |
| `emit_c` on `prop_param.mpl` | 1.70s | 1.87s |
| `infer_test` | 2.27s | 2.78s |
| `lower_test`, `emit_test`, `compiler_test` | 2.02 / 5.53 / 0.11s | 2.08 / 5.76 / 0.12s |

The compiled compiler is the one that does the work; stage 0 runs the suites and the bootstrap
from scratch, and it is roughly even there.

**Step 3** — lowering's `intern` and `unroll_cache` keyed by `cid` — is now a smaller prize than
it looked: both already go through `same`, which is now O(1), so what is left in them is the trie
descent and bucket scan, not comparison.

## Paranoid mode

`T.set_paranoid (true)` makes `same` compute both answers, the class comparison and the
structural reference (`same_ref`), count where they part, and return the reference. A merge
therefore cannot cascade into further merges, and the counts stay honest. Off, it costs one
cell read per comparison, which measures as nothing. `stage1/paranoid.mpl` compiles a file
with it on and stops non-zero on any merge, and `zig build test-paranoid` runs it over the
whole compiler. It is part of `zig build test` and takes about 80s.

| over a self-emit | merges |
|---|---|
| correct key | **0** of 368,433,605 (0 fallbacks, 0 splits) |
| block field names dropped from the key, bucketed by `h` | **0**: the gap was invisible |
| the same, bucketed by the key's own hash | **46,903**, exit 134 |

The middle row is why the bucketing changed. The bottom row is the step shown to bite. A gap is
only *counted* when two merged types are actually compared. Dropping a reference's qualifier
merged nothing on this input, because the compiler never compares `&T` with `&mut T` of one
pointee; there the answer was never wrong either. So the step proves the key right for
everything the compiler compares, which is the property that matters for its own output. A key
row exercised by no input still wants a test of its own.

