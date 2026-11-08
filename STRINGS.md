# Strings: design note

Status: **decided, not implemented**. SPEC §8 and BOOTSTRAP §2 name `concat_all`; this note
keeps the reasoning, the measurements and the plan. STDLIB.md's D6 (the builder) is the
library half and changes with step 5.

| | question | status |
|---|---|---|
| S1 | what a `Str` is | **settled by SPEC §3.1**: immutable bytes, pointer + length, always UTF-8 |
| S2 | how text is built from many pieces | **decided**: one primitive, `concat_all`, O(L) |
| S3 | whether there is a mutable byte buffer | **decided**: no — S2 makes it unnecessary |
| S4 | the compiler's own string building | **decided**: one joiner, over S2 (steps 3–4) |

## What §3.1 and §8 give

A `Str` is immutable, two words, and always valid UTF-8; every operation counts bytes
(`concat len slice byte`), and code points are library (`std/str`'s `codes`). Two
consequences shape everything below:

- **`slice` costs nothing.** It shares the bytes, so a piece that is a slice of source text
  — most of what the lexer and the emitter hand around — is never copied until something
  joins it.
- **`concat` costs both operands.** It allocates `len a + len b` and copies both, so any
  fold over it copies the text once per step. Appending to an accumulator is O(L·n) for n
  pieces totalling L bytes (CLAUDE.md: "never build a string by appending"), and the cure the
  codebase adopted — collect pieces, fold adjacent **pairs** until one is left — is
  O(L log n): log₂ n passes, each copying the whole text.

Nothing in the language does better than O(L log n). A join in one allocation needs either
a primitive that does it, or a way to write bytes into memory and then call that memory a
`Str`, and §8 has neither: `raw_alloc` and `str_from_ptr` can make and adopt memory, but
nothing writes a byte to it, and those are FFI intrinsics that stage 0 refuses (BOOTSTRAP
§1.2), so the compiler could not use them anyway.

## What it costs today (2026-11-08)

Counted in the emitted C of the compiled compiler emitting itself (PERF.md's method: bytes
through `mpl_alloc`, `mpl_concat` made `noinline` and charged to its return address,
`-fno-ipa-icf` so gcc does not fold the three identical joiners into one), output
byte-identical to `bootstrap/mplc.c`:

| | bytes | calls |
|---|---|---|
| everything | 989.3 MB | 17.77M |
| `concat` | **171.1 MB** (17%) | 2.63M |
| — `emit`'s output join (`join_pass`/`join_two`) | **106.2 MB** | 300,822 |
| — `lexer.scan_str` | 20.7 MB | 16,825 |
| — `types.show`'s join (`ch_pass`/`ch_two`) | 11.6 MB | 49,655 |
| — the other ~2,000 sites together | ~33 MB | ~2.26M |

The output join is the one big thing. The emitted C is 5.37 MB in ~300k chunks, so its
18 passes copy it 18 times; and each pass also builds a list of half the chunks and reverses
it, ~600k more cells the table does not show. `scan_str` is quadratic in a literal's escapes
— it appends the run before each escape, then the escape — and `emit.mpl`'s `runtime_c` is
one literal of ~16 KB with hundreds of them. `show`'s join is the same pairwise fold over a
type's rendering.

And the joiner exists **three times**, byte for byte: `emit.mpl`'s, `tyio.mpl`'s and
`types.mpl`'s (`ch_*`), plus a fourth in `std/str`.

## S2. One primitive: `concat_all`

```
$call concat_all (parts)      // parts : [Str]  →  Str
```

The pieces of an array, in order, joined: one allocation of their total length and one copy
of each. `concat_all` of an empty array is `""`. No validation is needed — §3.1 makes every
piece valid UTF-8, and a concatenation of valid UTF-8 is valid — so it is as cheap as
`memcpy`.

**Why an array.** The root block cannot name a list — `P.list` is a prelude template — and
§8's arrays are generic and contiguous already (STDLIB.md P3), so `[Str]` is the one sequence
type an intrinsic can take. Filling one costs 16 bytes a piece, against the 24-byte cons cell
each piece already occupies in a chunk list.

**Why not the alternatives:**

- *A mutable byte buffer* (`buf_new`, `buf_write`, `buf_str`) would be a new kind of runtime
  value — storage whose contents change, which §5.3/§5.4 would have to type and alias — to
  get what a list of pieces and one join already give. It would also let a `Str` be made
  from bytes written one at a time, which the UTF-8 invariant (§3.1) would then have to
  check, where `concat_all` never needs to.
- *A raw-memory write* (`raw_copy (addr, s)`), with `str_from_ptr` to adopt the result:
  unsafe by declaration, a second copy and a validation pass on top, and unavailable to the
  compiler, since stage 0 has no FFI.
- *`emit` answering chunks* rather than one `Str` per output, so `mplc` prints them: it
  removes the join only where the text goes to stdout. `link` writes `<path>.c` with
  `write_file`, which takes a `Str`, and §9.1's `ofile` would change shape for every driver.
- *Overloading `concat`* with a `([Str])` candidate: one name fewer, but every `$decl c
  concat` alias becomes a group and every call site's resolution changes, for no gain over a
  name of its own.

**The name.** `concat_all` is what `std/str` already calls the same operation over a list.
Inside `std/str` the root's has to be reached before the module's own `$decl concat_all`
shadows it (CLAUDE.md: a shadowing `$decl` takes effect from its own line, and a `$func` body
naming itself is itself), so the module aliases it first, as `types.mpl` does `isub`.

## S3. No byte buffer

With S2, a builder is a list of pieces and one `concat_all`: O(L) in bytes, one cell and,
at the end, one array slot per piece. That is what a buffer would buy, without a new value
kind. STDLIB.md's D6 said "with P3, a builder over a growable byte array is better still";
it would not be — growing by doubling copies the text about twice, where `concat_all`
copies it once.

## S4. The compiler's own text

- **One joiner, in the prelude** (`P.join_chunks`, newest-first pieces in, a `Str` out):
  count the pieces, `array (n, "")`, fill from the far end, `concat_all`. `emit`, `tyio` and
  `types.show` use it, and their three copies go.
- **`scan_str`** collects its runs and escapes as pieces and joins once at the closing
  quote.
- What is *not* changed: the ~2,000 small `concat` sites, ~33 MB together, are two-operand
  appends of short strings where a join would cost more than it saves.

**Expected**: the output join from 106 MB of copying (plus ~14 MB of list cells) to one
5.4 MB copy and a 4.8 MB array; `show`'s and `scan_str`'s to a few MB; about **−130 MB of
989 MB**, with the emitted C byte-identical.

## Plan

1. **Documents** — this note, SPEC §8's Strings row, BOOTSTRAP §2's table. Done.
2. **The intrinsic**, in every place a root name lands (CLAUDE.md, "Adding a root-block
   name"): stage 0's `builtins.zig` and its test list, `infer.mpl`'s `root_env`, `emit.mpl`'s
   `prim_fn` and runtime (`mpl_concat_all`: sum the lengths, one `mpl_alloc`, `memcpy` each),
   and the root-block agreement test. Nothing in the compiler calls it yet, so this is an
   ordinary regeneration, and the committed `mplc` knows the name before step 3 needs it.
   Fixture `concat_all.mpl`: empty, one piece, many, multi-byte pieces, empty pieces, and a
   million pieces, in both stages and the differential set.
3. **The prelude's joiner**, and `emit`, `tyio` and `types.show` on it. The emitted C must
   not change by a byte; measured as above.
4. **`scan_str`** on pieces.
5. **`std/str`**: `concat_all`, `join` and the builder's `build` over the intrinsic;
   STDLIB.md's D6 updated.
