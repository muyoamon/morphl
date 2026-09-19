# morphl — Bootstrap Plan

*Companion to `SPEC.md` (Draft 4). Where this document and the spec disagree about the language, the spec wins; this document only restricts.*

## The two requirements

The bootstrap subset is the intersection of two constraints, and every choice below follows from one of them:

1. **Stage 0 must be able to run it.** Stage 0 is a dynamically-evaluating interpreter in Zig with no static type checking. Anything that requires inference to *execute* is out.
2. **It must be fully valid statically-typed morphl.** Stage 2 is the stage-1 compiler compiling its own source with real type checking. Anything that merely "runs under the interpreter" but would not typecheck is a trap that detonates at stage 2.

Requirement 2 is the one that bites. It is why `$union` stays in (recursive AST types need it) even though a dynamic interpreter has no use for it, and why the style rules in §4 are not optional.

## Stages

| Stage | What it is | Written in | Gate |
|---|---|---|---|
| 0 | Lexer, parser, dynamic evaluator, bootstrap root block | Zig 0.16 | Runs every example in `SPEC.md` §12 that fits the subset |
| 1 | The real compiler: lexer, parser, inference, C backend | morphl (this subset) | Runs under stage 0 |
| 2 | Stage 1 compiled by stage 1 under stage 0, via C | morphl | Typechecks its own source; binary reproduces stage 1's behavior |
| 3 | Stage 2 compiling its own source again | morphl | **Stage 2 and stage 3 output identical byte-for-byte** |

After stage 3 the Zig code stops growing. It is kept, not deleted: it is the reproducible bootstrap path, and §9 requires the finished compiler to evaluate build programs anyway.

---

## 1. Forms

### 1.1 In the subset

| Form | Bootstrap restriction |
|---|---|
| `$decl name e` | none |
| `$prop name e` | initializer limited to literal, `true`/`false`, `$func`/`$template` literal, prop-only block, `$union`, `$specialize`, projection of a prop (this is §4.10 as written) |
| `$fwd name` | mutual recursion only; plain self-recursion does not need it (§4.1 self-reference) |
| `$new e` | none. Nothing is ever freed — every allocation is root-region (see §3) |
| `$mut e` | none |
| `$set target e` | none |
| `$func params body` | none. Closures need no restriction: capture is by copy and bindings are immutable, so no closure can point into a dead frame (§7.3) |
| `$call f args` | `f` must not be a template (see `$specialize`) |
| `$match e arms` | patterns restricted — §1.3. **Must end in a catch-all** — §4 |
| `$case pat body` | as above |
| `$if c a b` | none |
| `$do e1 e2` | none. This is how loops are written |
| `$union members` | allowed anywhere, including the recursive type-only form. Stage 0 evaluates member 1 and **never inspects the rest** (§4.8a), so recursive members cost the interpreter nothing |
| `$template T body` | single name only, **no bounds** (`$template (T bound)` is out), no self-specialization |
| `$specialize t args` | **always explicit.** Never rely on `$call`-time inference of `T` (§4.9) |
| `$import "name"` | none. Load-once, cycles are an error |
| `$try e pat` | `pat` restricted to `err` / `none` / another prop-tagged block — §1.3 |

### 1.2 Out of the subset

| Excluded | Why, and what to write instead |
|---|---|
| `$overload` | The bootstrap root block is monomorphic (§2), so no overload set ever exists. Removes first-fit type-level resolution *and* the `R`-as-`⊥` rule (§5.5) from stage 0 entirely |
| `$impl`, `$traitsof` | A compiler needs no traits. Removes witnesses, F-bounded conformance, and fat-reference dispatch |
| `$extern` | Stage 0 provides I/O as opaque builtins instead (§2). Keeps the platform out of the bootstrap |
| `$const`, all `&const` | Nothing in stage 1 needs a read-only view. (This exclusion used to be justified by fat references; under §5.1's prefix rule a `&const` upcast is free and thin, so the reason is now only that it is unused.) Use `&T` or `$mut`. |
| `Float` arithmetic | A compiler needs no float math. Float *literals* are carried through as their source text `Str` and converted by the backend when emitting C — so the lexer still lexes them |
| `allocator`, regions | Nothing is freed at stage 0 (§3) |
| `sendable`, threads | Not needed to compile a file |
| Implicit `$specialize` via `$call` | Requires parameter-default shape matching (§4.9) — inference work, in stage 0 |
| Template bounds | Requires subtype checking, which stage 0 does not have |

### 1.3 Pattern restriction (the important one)

Type-only positions (§5.7) hold expressions that are **never evaluated** — only their static type is used. Stage 0 has no inference, so it cannot compute a pattern's type in general. Every pattern in bootstrap source must therefore be one of exactly four shapes, each testable against a runtime value with no inference and no recursion:

1. **Prop-only block literal** — `{$prop tag "call"}`. Test: value carries that prop with that value. This is the workhorse; all AST dispatch uses it.
2. **A name bound to a prop-only block** — `err`, `none`, or a locally declared tag prop. Same test.
3. **An `Int` or `Str` literal** — `$case 0`, `$case ""`. Test: value's base type. This is how `Int`-vs-`Str` dispatch is written (§4.7: a literal pattern is its base type, not a singleton).
4. **A `true` or `false` literal** — `$case true`. Test: the **exact tag**, not the base type. This is the one asymmetry with shape 3, and it comes from §3.2: `true` and `false` are distinct nullary tag types, whereas §3.1 gives `Int` and `Str` no singleton literal types at all. Without this shape `$if` could not be sugar for `$match` and §8's `not` would be unwritable, so it is required, not optional.
5. **A bare name whose type is the scrutinee's full type** — the catch-all (§4.7).

Nothing else. In particular **a pattern may never reference a recursive `$union` name**, because resolving that needs the μR knot of §5.5. Declaring such a union is fine; matching *on* one is not.

Shapes 2 and 5 need no separate mechanism: a name pattern tests the scrutinee against the structural shape of whatever the name is bound to, so when it names the scrutinee it matches by construction, exactly as §4.7 describes.

Two consequences of that, both of which bite in practice:

- **A catch-all needs a name to point at.** §4.7's idiom is `$match x ($case x …)`, which only works when the scrutinee *is* a name. Matching on an expression means binding it first — and `$decl` preserves references (§5.4), so binding storage gives a pattern that tests `&T` against `T` and never matches. Either bind a value, or dispatch with `$if` instead of `$match`.
- **A `$union`-typed name is not a dynamic catch-all.** `$case some_union_name` has the whole union as its *static* type, but stage 0 has only the value, which §4.8a makes the union's *first member*. So it matches that member alone. Stage 1 will get this right because it will have types; stage-0 source must not rely on it.

Consequence for the AST representation: every node is a block with a `$prop tag "…"` discriminator, and all dispatch is shape 1. That is the intended style anyway (§12's tagged-block example).

---

## 2. The bootstrap root block

Stage 0's root block is **not** the root block of §8, and it does not pretend to be. It is monomorphic, and it provides the platform as builtins rather than through `$extern`.

| Group | Names |
|---|---|
| Int arithmetic | `add sub mul div mod neg lt` — `Int` only; overflow panics |
| Comparison | `eq_int eq_str` — no polymorphic `eq` |
| Strings | `concat len slice byte` — byte units, as §8 |
| Conversion | `int_to_str` , `str_to_int` → `none` or `{$prop tag "some" $decl v 0}` so `$try x none` works |
| Characters | `from_code (cp)` → `none \| some Str`. **An addition to §8, not an implementation of it** — see §7 |
| Arrays | `array at alen` — as §8; `at` returns a base+index handle |
| Control | `panic` |
| Shapes | `err none` — prop-tagged blocks, per §4.15 |
| Platform | `print read_file write_file args` — opaque Zig builtins, reached through an interface the driver supplies (see below) |

**Platform shapes.** §8 requires failing operations to return `option`/`result` rather than panic, which fixes these signatures:

- `read_file (path)` → `none | {$prop tag "some" $decl v Str}`. A missing file *and* non-UTF-8 contents both give `none`. That is not defensiveness: §3.1 makes `Str` always valid UTF-8, and §4.16 says bytes arriving from outside "become a `Str` only through a validating library function returning `option Str`".
- `write_file (path, contents)` → `() | err`, so a caller writes `$try ($call write_file (p, s)) err` and the error set is inferred (§4.15).
- `args ()` → an array of `Str`: the arguments after the input file, i.e. the *program's* arguments rather than the compiler's. A zero-arity function, so a program that never asks pays nothing, and a fresh array per call since §8's arrays are `&mut [T]`.

The evaluator holds these as an injected interface and never opens a file itself — the same arrangement as the `$import` resolver, and for the same reason: §4.16 puts the platform in a per-target root block, not in the language.

**Migration.** Stage-1 source calls these names directly, so nothing in it changes when the real root block arrives: keep a small `boot.mpl` prelude that re-exports `add_int`-style names in terms of real overloaded intrinsics once `$overload` exists. Monomorphic names in stage-1 source are a deliberate, cheap-to-undo commitment.

---

## 3. What stage 0 must implement anyway

Not everything is deferrable. These are load-bearing:

- **Tail-call elimination (§7.7).** Loops *are* recursion; without TCE, any loop in stage-1 source blows the stack. Implement a trampoline in the evaluator from the start. Tail positions: `$func` body, `$match` arms in tail position, the second operand of `$do` in tail position, transitively — and never a call inside a block.
- **Structural value tags (§7.5).** Every value carries enough shape to answer the four pattern tests, *including prop names and values*, since a prop's value is part of block type identity (§4.10).
- **`$try` unwinding (§4.15).** Exits to the nearest enclosing `$func`; blocks, `$do`, arms, and groups are transparent.
- **`$fwd` slots.** Reserve the slot with an uninitialized marker; reading it before its completing `$decl` is an error. Dynamically this is easy — by the time a `$func` body runs, the `$decl` has executed.
- **Load-once `$import` (§4.14)** with a resolved-path cache and cycle detection.
- **`$new` cells, never freed.** §7.6 says region inference *widens* rather than fails, so "everything in the root region" is a spec-legal stage 0 — it leaks, and that is the blessed failure mode.

Two implementation notes that save real work:

- **Block records can be shared, not copied.** §4.5 says copying a block copies its fields, but `$decl` bindings are immutable and only `$new` cells are mutable, so structural sharing of the record is unobservable. Do not deep-copy blocks.
- **`$union` needs no shape analysis.** Evaluate member 1, discard the rest unexamined. This is what keeps recursive type declarations free.

---

## 4. Style rules for stage-1 source

These exist because stage 0 does not check what stage 2 will. Violating one produces source that runs fine for months and then fails to compile at stage 2.

1. **Every `$match` ends in a catch-all arm** naming the scrutinee. Stage 0 cannot verify exhaustiveness (§4.7 requires it); a trailing catch-all makes exhaustiveness unconditional, and stops dynamic first-fit from falling off the end.
2. **Every `$match` arm and `$overload`-free dispatch is ordered specific-first.** First fit is semantic (§10.6).
3. **Qualify parameters that are written through** as `$mut $new …`. Bare `&T` is the most capable type and rejects `&mut` arguments (§5.3, §10.8) — stage 0 won't notice, stage 2 will.
4. **Return values via `{ … $decl r e }.r`.** A block never yields its last expression (§3.3).
5. **Sequence effects with `$do`, not with block position**, wherever a tail call must follow an effect (§4.8b).
6. **Compiler source files are ASCII.** `slice` takes byte offsets and panics if one splits a code point (§8). The *input* the lexer reads may be arbitrary UTF-8 — handle it with `byte`.
7. **No name shadows a root-block name.** Intrinsics are ordinary shadowable values (§2.1), which makes accidental shadowing silent. Don't.

---

## 5. Build order for stage 0

1. Lexer. Fixed token set from §2.1: `Int`, `Float` (text), `Str` with `\n \t \\ \"` and `\u{…}`, name, `$name`, `(` `)` `{` `}` `,` `;`, `.name` / `.1`, `//` and non-nesting `/* */`. `;` is whitespace with no meaning. Identifiers may not start with `$`; nothing special-cases `add` or `print`.
2. Parser. Table-driven off §2.2 — each `$kw` reads exactly its arity. Fold `(e)` to `e`, unify `()` and `{}` as unit, bind postfix projection tightest. No precedence machinery exists.
3. Evaluator, per §3.
4. Root block, per §2.
5. **Gate:** every §12 example inside the subset runs. `while`, the `$fwd` even/odd pair, tagged-block dispatch, and error propagation are the four that matter.

`zig_rewrite`'s `lib/lexer/lexer.zig` is worth reading for step 1, but it predates Draft 4 — it emits whitespace as tokens and knows nothing of `$`-keyword arity.

## 6. Error reporting, from the first line

There is no annotation syntax, so every type in every diagnostic is one the compiler inferred and the user never wrote. Diagnostics must point at **expressions**. Carry a span on every AST node in stage 0 and on every type node in stage 1's inference engine from the beginning — provenance is extremely expensive to retrofit into a Simple-sub-style solver.

## 6a. Tail calls lower to loops

§7.7 makes tail-call elimination mandatory, and C gives no such guarantee, so stage 1's backend has to produce the guarantee itself. **Decision: a tail call becomes a loop.**

- **A direct self tail call** becomes `while (1) { … }` with `continue`. The one hazard is that parameters must be updated *in parallel*: compute every new argument into a temporary first, then assign, or a call like `$call f (b, a)` corrupts `b` before reading it.
- **A direct mutual tail call** (§12's `even`/`odd`, reached through `$fwd`) is not a self loop. When the whole mutually-tail-recursive group is statically known — which `$fwd` guarantees, since the slots are completed in one block — the group merges into a single C function with a `state` variable and one dispatch loop, and each tail call assigns the next state and `continue`s. This is the standard contification, and `$fwd` is what makes the group identifiable.
- **An indirect tail call**, through a function *value* rather than a name, cannot become a loop: the target is unknown until run time. `$func ($decl f $func () 0) $call f ()` is a legal tail call and §7.7 covers it. These fall back to a **trampoline**: the call returns a thunk to a driver loop. Portable C, no reliance on a particular compiler.

Not chosen, and why: clang's `musttail` would handle every case including indirect ones, but it ties the bootstrap to one compiler and to one attribute's availability per target, against §9's expectation that a target needs only a root block and a C compiler.

What this means before the backend exists: the two morphl functions the toolchain leans on hardest — `scan` in the lexer and `block_items` in the parser — are direct self tail calls, so they land in the cheap case. Nothing written so far needs the trampoline.

## 7. Open bootstrap questions

- **Subtyping needed a goal-level assumption set, and binder identity was what blocked it. Resolved.** `sub` used to assume pairs of *recursion variables* — two integers, allocation-free — which closes the loop only when both sides are folded the same way. It could not close a goal that recurs through a recursive type unfolded *structurally* (`X <: μ…` reducing to itself), which inference produces whenever it rebuilds a value of a recursive type. That was the whole of the 9 errors left in `types.mpl`.

  Amadio–Cardelli's assumption set is over goals for exactly that reason, but adding one was measured as *worse* — 12 errors in ~6GB against 9 in ~2GB — because the real obstacle was underneath it. A μ binder took its id from a global counter, so the same type inferred at two declarations came out as `mu126` and `mu372` and compared unequal: goals could not repeat, so assuming them bought nothing. An alpha-normal form was tried at four insertion points and every one made things worse, because numbering binders by depth from the root is context-dependent and destroys the value *sharing* that equality was leaning on instead:

  | canonicalise at | `parser.mpl` | `types.mpl` |
  | --- | --- | --- |
  | (baseline) | 0 | 9 |
  | `close_rec`, i.e. stored types | 32 | 113 |
  | `sub` entry | 19 | — |
  | `ty_eq` | 0 | 18 |
  | `$specialize` memo key | 0 | 17 |

  The fix is the representation. A binder carries no id, and a variable names the number of binders between it and its binder (`t_bnd`). Alpha-equivalence is then structural identity, `same` recognises it for nothing, and the assumption set holds goal pairs — Amadio–Cardelli as written. **`types.mpl`: 9 errors to 0.**

  Three things fell out of it:

  - The four walks that rewrote a type — substitute a placeholder, renumber, substitute a bound variable, bind one — are *one* walk with the leaf case parameterised (`remap`). All four count binders on the way down and differ only at a leaf, and writing them separately cost four 12-arm matches in a file that type-checks itself, which was enough on its own to exhaust memory.
  - The checker needed a real stack. `sub` descends structurally through a recursive type and that recursion is not in tail position, so §7.7 cannot eliminate it. Stage 0 now runs the interpreter on a 256MB thread, which moved the reportable depth from 476 nested calls to over 23000; the guard's budget is an `Options` field, since only the caller knows what stack it gave. Before this, tracing a failing check used enough extra stack to change the answer.
  - Not done, and measured: pruning the right-hand side of a check by tag *before* unrolling it — which looks sound, since a member's tag is a prop it carries as it stands (§5.1) and `subs_any_right` rejects on it anyway — gives 18 errors instead of 0, at any memory cap. The reason is not understood, and until it is, the full unrolling stays.

- **Peak memory is allocation *volume*, and the volume is per-call overhead.** Nothing is ever freed (§3), so peak memory is every byte the run ever asked for. An allocation profile of checking `types.mpl` — `MORPHL_STATS=1`, which charges each byte to the innermost morphl function running — found 4GB in ~60 million allocations averaging 63 bytes, with the top entries being `same`, `occurs` and `same_fields`: functions that walk two types and should allocate nothing at all.

  Two causes, both in stage 0 rather than in the checker:

  - **A `$match` arm evaluated its pattern on every test.** §5.7 says a pattern is never evaluated, and BOOTSTRAP §1.3 limits patterns to prop-only blocks so that stage 0 need not infer anything — but `patternApplies` built the block anyway, costing a scope, a prop-slot array and a block *per arm tested*, and stage 1's matches run to thirteen arms. When every prop value is a literal, which is nearly always, the test is just "the value is a block carrying these props with these values" and needs nothing built. **4.01GB to 1.45GB**, with identical results.
  - **Most scopes are still allocated fresh**: 5.8M against 1.1M taken from the pool. Block scopes are never pooled at all, and that is where the remaining ~1.45GB sits — roughly 2.7 allocations of ~90 bytes per morphl call, times a few million calls.

  What this cost while it went unnoticed: `types.mpl` needed 6GB, and `infer.mpl` could not be checked at all. Both numbers were read as evidence about the *checker* — including, wrongly, as a runaway in the `$import` path, since a file containing only `$decl T $import "types"` exhausted memory while `types.mpl` itself checked clean. There was no import bug. It checks clean now, and so does `infer.mpl`, at 131 errors. Before drawing a conclusion from an OOM, profile it.

- **§8 cannot build a character, only read one.** `byte` reads a byte out of a `Str`, and §3.1 says a character *is* a one-code-point substring — which only helps when the character already exists somewhere. Decoding the `\u{…}` escape that §2.1 requires means producing a code point that appears nowhere in the source, so a lexer written in morphl cannot do it with §8's intrinsics. Stage 0 adds `from_code (cp)` → `none | some Str`, validating so that §3.1's always-valid-UTF-8 invariant holds. §8 needs either that intrinsic or an explicit statement that `\u{…}` decoding stays a compiler builtin.
- **Reading a value out of storage has no syntax.** `$decl y n` aliases (§5.4, and §12 says so outright), so snapshotting the contents of a cell into an immutable binding means passing it through something that expects a value. The prelude defines `ival`/`sval` identity functions for this, and stage 1's lexer needs them on almost every line that touches the cursor. §11 might want a `$copy`-style form, or §8 a blessed library identity.

- Whether stage 1 emits one C file or one per morphl file (affects `$import` load-once semantics at the C level, not in the language).
- Whether to keep monomorphic root-block names permanently or shim them (§2, *Migration*).
