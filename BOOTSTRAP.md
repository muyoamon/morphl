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
| 2 | Stage 1 compiled by stage 1 under stage 0, via C | morphl | **Met.** Typechecks its own source; binary reproduces stage 1's behavior |
| 3 | Stage 2 compiling its own source again | morphl | **Met.** Stage 2 and stage 3 output identical byte-for-byte |

After stage 3 the Zig code stops growing. It is kept, not deleted: it is the reproducible bootstrap path, and §9 requires the finished compiler to evaluate build programs anyway.

### Where the bootstrap landed

`stage1/selfc.mpl` is §9's pipeline as a program — parse, check, verify, emit — reading its target path from the file `./target`, because `args` had no C backend when it was written (§7, now resolved — `stage1/mplc.mpl` takes an argument). Stage 0 emits it as **63,906 lines of C in 5,390s using 1.15 GB**; `cc -O2` gives a 708,016-byte binary, and that is **stage 2**. Stage 2 emits the same source in **164s**, `cc` gives **stage 3**, and stage 3 emits it again in 178s.

All three emissions are byte-identical — md5 `ba8e65e7b6ae1e0a2e350ecd3c30c0ef` — which is one more than the gate asks for: stage 2 reproduces the *interpreter* exactly, not merely stage 3. The two binaries are identical too, once compiled from the same filename. Stage 2 independently reproduces the reference C for `stage1/lexer.mpl`.

Stage 2 is **33x** stage 0 on that workload, against a prediction of 5x. Requirement 2 above is what earns the difference: because the source really is statically typed, `lower.mpl` resolves every name to a frame slot (§7.2) so compiled code indexes where the interpreter walks a scope chain comparing names, and §8's intrinsics emit infix where the interpreter makes a call apiece — three quarters of all calls it makes.

Two defects had to go first, both the same shape and neither visible to stage 0's own profiler: `put_lifted` rebuilt the function table three times per lifted function, and `mod_ent` held four list fields inline at 496 bytes an entry. Together they took stage 0's whole-compiler emit from 2.65 GB to 1.15 GB and unblocked stage 2, which had been failing above 7 GB. `PERF.md` has the numbers and the instrument that found them.

---

## 1. Forms

### 1.1 In the subset

| Form | Bootstrap restriction |
|---|---|
| `$decl name e` | none |
| `$prop name e` | initializer limited to literal, `true`/`false`, `$func`/`$template` literal, prop-only block, `$union`, `$specialize`, projection of a prop (this is §4.10 as written) |
| `$fwd name` | mutual recursion only; plain self-recursion does not need it (§4.1 self-reference) |
| `$new e` | none. Frame storage, and §5.3a's escape check applies — stage 1's checker must implement it |
| `$alloc e` | none. Draws from the root block's default `allocator`, which never frees (§3) |
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
| Releasing an allocator | Nothing is freed at stage 0 (§3), so the default `allocator` is malloc-and-never-free. `$alloc` itself is *in* the subset — §5.3a makes it the only way a container outlives its builder, so stage 1 cannot be written without it. |
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

**Where this landed.** The self case works end to end. The mutual case is contified as described, but **only for a group whose members share a signature** — one parameter list and one `ret` have to serve them all — and a group that does not is reported rather than mis-emitted. Three such groups remain in the compiler's own source, so §7.7 does **not** hold for them: they are emitted as ordinary functions, which is correct but is not the guarantee. The indirect case is **not** implemented. The trampoline needs every function to return "a value or a pending call", which is a whole-program calling convention this backend does not have, so an indirect tail call is emitted as a plain call carrying a marker that says so.

**And §7.7 cuts both ways in the compiler's own source.** A block around a recursive call makes it a real frame, so an O(n) walk over a table that grows with the whole program costs n frames. Two such walks over the interned type table (`alias_at`, `emit_fwds`) were written that way and nested, and at 6,348 types that was **8,763 nested calls and 48 MB of a 64 MB stack** — failing with `call depth limit exceeded`, *not* `OutOfMemory`, while still well under the memory cap. Read which of the two errors you got before concluding anything about memory.

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
  - The checker needed a bigger stack than the main thread's 8MB, so stage 0 runs the interpreter on a thread of its own with the guard's budget as an `Options` field — only the caller knows what stack it gave. **The 256MB it was first given was a misreading of my own measurement**: the depth of "over 23000 nested calls" came from a run with *tracing* on, and the tracing was the cause. `sub_seen`'s trace branch wraps the recursion in a block, and §7.7 makes a call inside a block a real frame where it had been a tail call — so the instrumentation converted every level of an eliminated recursion into a stack frame. Measured without it, checking stage 1's largest file peaks at **169 nested calls and 1.7MB**. The thread is now 64MB, about 30x headroom, and the floors dropped with it. The lesson generalises: in a language where tail calls cost nothing, a diagnostic that adds a block around the recursion does not merely slow it down, it changes its space complexity.
  - Not done, and measured: pruning the right-hand side of a check by tag *before* unrolling it — which looks sound, since a member's tag is a prop it carries as it stands (§5.1) and `subs_any_right` rejects on it anyway — gives 18 errors instead of 0, at any memory cap. The reason is not understood, and until it is, the full unrolling stays.

- **Stage 1 type-checks itself, completely.** `prelude`, `lexer`, `parser`, `types` and `infer` all report zero errors under `typecheck.mpl`, which means the checker accepts the source of the checker. The last 131 errors in `infer.mpl` were not deep: 95 of them were one mistake reported once per union member — a helper taking `Pa.proto_node` and projecting `.operands` off it, when narrowing does not cross a call — and the rest split into parameter types too narrow for what is passed (`$new xs.nil`, `$decl o true`), six forward references, and two places where a mutually recursive group's unsolved placeholder defeats narrowing. All are recorded in CLAUDE.md under *Writing morphl*, because every one of them is a trap the language sets rather than a bug in the code.

  What this does **not** yet mean is self-hosting: stage 1 is still run by stage 0's evaluator, and §9's `compiler` value and the C backend do not exist. It does mean the type system is complete enough to accept a real program of ~4500 lines, which is the thing the backend will be built on.

- **Checking the compiler went from 9GB to 1.5GB, and none of it was stage 1's fault.** Three fixes in stage 0, found by profiling rather than by reasoning about the checker:

  - **The arena reserved 2.5x what it handed out.** `std.heap.ArenaAllocator` sizes each new chunk at 1.5x everything allocated so far and keeps every earlier one, so the last chunk alone can be larger than all the live data. Since nothing is ever freed, that multiplier lands straight on the `ulimit -v`. A bump allocator over fixed 64MB chunks makes the reservation the bytes plus one chunk. `types.mpl`: 4GB to 2GB, with no change in bytes allocated.
  - **`$prop` was treated as a capture.** `mayCapture` returned true for a `$prop` anywhere in a body, so no constructor in stage 1 — every one of which builds a `{$prop tag "…" …}` — could recycle its scope. But `evalBlockExprs` forces every prop and copies its *value* into the block before returning, so the slots never outlive the scope. Only `$func` and `$template` keep a chain alive (§7.3).
  - **The first `$match` in a body poisoned recycling for the whole trampoline.** A tail-position `$do`, `$if` or `$match` stays in the *same* scope and reports `may_capture = true` because it has no callee to ask; the trampoline took that at face value and set `recyclable = false` for every later iteration. Only a tail *call* changes scope and so decides afresh. Stage 1's functions are almost all a tail-position `$match`, so this was nearly total: scope reuse went from 9M of 32M to **32,114,378 of 32,114,716**, and bytes allocated from 5.17GB to 0.80GB.

  A later fix to the trace itself found the rest of the story. `sub_seen`'s traced branch now uses `$do` (§4.8b) rather than a block, which keeps the check in tail position; the depth counter it used to restore afterwards became `goal_list.length (st.goals, 0)`, an indentation that needs no restoring, so every level can be printed under a line budget instead of only the first four. But `$do` alone did not fix it: bisecting showed the remaining depth came from `$call sub (n, 1)` inside `trace_line` resolving to **`types.mpl`'s own subtyping `sub`**, because a name in a `$func` body resolves against the finished block — so `$decl sub` shadows the intrinsic for the whole file, including functions written above it. Every trace line was running a subtype check between two Ints. `$decl isub sub` near the top captures the intrinsic, since at that point the block has no `sub` slot yet. Traced depth went from 7273 frames to **65 — the same as untraced**.

  Final: `types.mpl` 4GB → **600MB**, `infer.mpl` 9GB → **1.5GB**, both with identical results. What is left is genuine data construction — list cells, type rebuilding in `remap`, union normalisation — not interpreter overhead. `MORPHL_STATS=1` prints the profile, and its "scopes … allocated fresh" line is what found the last two.

- **Stage 1 migrated to storage-passing recursion, and it was three lines plus three helpers.** The guardedness check said 70 errors at three positions; fixing them went: `prelude.mpl`'s `list` tail (one line — 70 errors to 4, and `lexer` went clean), `parser.mpl`'s `proto_node` (five fields — `parser` clean, 17 new errors in `infer`), `types.mpl`'s `proto_ty` (nine fields and eight constructors — `types` clean, 36 new errors in `infer`). Every one of those 53 new errors was the *same* mistake in three helpers, not 53 mistakes: a function arm returning a now-boxed field gives it type `<&T, T>`, because §5.4 keeps a reference wherever nothing expects a value and a function result is such a place. `group_items`, `result_of` and one `$decl r $if ok ft.result …` — three `val`/`tval` calls — cleared all of them.

  Boxing the *list* rather than its elements is what kept this small. A cons cell holds its element inline, so its size needs the element's; one pointer in front of the list breaks that circle for every element at once, and the elements stay values. `nodes` is still a list of node values, not of references — which is what I predicted wrongly last time and what the check corrected.

  Cost: `types.mpl`'s check went from ~2GB to ~4GB, since every type constructor now allocates. Stage 0 never frees, so a `$new` per constructed type is a straight addition to peak memory.

- **§5.5 now requires recursion to pass through storage, and the check says where.** `T.unguarded` is one guard-aware traversal — it stops at a reference, an array element and a function type, and shifts the index under a nested binder — called from `close_rec`, which is where every μ in a program is tied. Across stage 1 it reports 70 errors and *every one* is a guardedness error, tracing to exactly three source positions: `prelude.mpl`'s `list` (66 of them, once per element type it is specialized with), `parser.mpl`'s `proto_node`, and `types.mpl`'s `proto_ty`. The container case is confirmed rather than predicted: `proto_node` is reported for its list's `head` as well as its `tail`, so `nodes` becomes a list of references, not merely a `$new` on the tail.

  Getting those positions readable needed the diagnostic to carry its own file. Three things were missing and all three mattered: `Pa.diag` had no `file` field, `cx` did not track the module being typed, and a `$template` did not record the file it was *written* in — so a library template's errors were reported against whichever file specialized it (§10.7). With all three, the 66 prelude errors say `prelude.mpl:50:3` instead of naming four different files, and an imported module's syntax errors keep their own line and column instead of being folded into a message against the import site.

- **Peak memory is allocation *volume*, and the volume is per-call overhead.** Nothing is ever freed (§3), so peak memory is every byte the run ever asked for. An allocation profile of checking `types.mpl` — `MORPHL_STATS=1`, which charges each byte to the innermost morphl function running — found 4GB in ~60 million allocations averaging 63 bytes, with the top entries being `same`, `occurs` and `same_fields`: functions that walk two types and should allocate nothing at all.

  Two causes, both in stage 0 rather than in the checker:

  - **A `$match` arm evaluated its pattern on every test.** §5.7 says a pattern is never evaluated, and BOOTSTRAP §1.3 limits patterns to prop-only blocks so that stage 0 need not infer anything — but `patternApplies` built the block anyway, costing a scope, a prop-slot array and a block *per arm tested*, and stage 1's matches run to thirteen arms. When every prop value is a literal, which is nearly always, the test is just "the value is a block carrying these props with these values" and needs nothing built. **4.01GB to 1.45GB**, with identical results.
  - **Most scopes are still allocated fresh**: 5.8M against 1.1M taken from the pool. Block scopes are never pooled at all, and that is where the remaining ~1.45GB sits — roughly 2.7 allocations of ~90 bytes per morphl call, times a few million calls.

  What this cost while it went unnoticed: `types.mpl` needed 6GB, and `infer.mpl` could not be checked at all. Both numbers were read as evidence about the *checker* — including, wrongly, as a runaway in the `$import` path, since a file containing only `$decl T $import "types"` exhausted memory while `types.mpl` itself checked clean. There was no import bug. It checks clean now, and so does `infer.mpl`, at 131 errors. Before drawing a conclusion from an OOM, profile it.

- **§8 cannot build a character, only read one.** `byte` reads a byte out of a `Str`, and §3.1 says a character *is* a one-code-point substring — which only helps when the character already exists somewhere. Decoding the `\u{…}` escape that §2.1 requires means producing a code point that appears nowhere in the source, so a lexer written in morphl cannot do it with §8's intrinsics. Stage 0 adds `from_code (cp)` → `none | some Str`, validating so that §3.1's always-valid-UTF-8 invariant holds. §8 needs either that intrinsic or an explicit statement that `\u{…}` decoding stays a compiler builtin.
- **Reading a value out of storage has no syntax.** `$decl y n` aliases (§5.4, and §12 says so outright), so snapshotting the contents of a cell into an immutable binding means passing it through something that expects a value. The prelude defines `ival`/`sval` identity functions for this, and stage 1's lexer needs them on almost every line that touches the cursor. §11 might want a `$copy`-style form, or §8 a blessed library identity.
- **§7.6's regions are needed by the compiled side sooner than by stage 0, which §3's reasoning did not anticipate.** §3 blesses never freeing because stage 0 never frees either — true while the interpreter was the only consumer. Compiled, §7.2 inlines a block's fields and §7.5 sizes a union to its widest member, so a `P.list` node holds its element *by value* and costs `element + 16` bytes, against stage 0's flat 64 whatever it holds: **stage 0's boxing is what keeps its memory down.** Measured on the compiled compiler, the widest list node is 512 bytes and two types out of 644 accounted for 95% of all allocation. Narrowing those two by hand is what got stage 2 under its bound; the general answer is reclamation, and it is now a stage-2 concern rather than a post-bootstrap one.
- **`args`, `at`, `alen` and `array` now have a C backend. Resolved.** They had none, so no driver could be emitted at all — every one opens `$call args ()` / `$call at (argv, 0)` — and `selfc.mpl` only existed because it worked around that by reading its target out of a file. §8's array is now a C struct of a pointer and a length, one per element type, like §3.1's `Str`; the element sits *behind* the pointer, so unlike a block's fields it embeds nothing. None of the four can be a plain C function: `at` answers a **reference** into the elements (stage 0 returns `.ref = &a.elems[i]`, and §5.4 reads it through where a value is wanted), `alen` is a field read, `array` needs the element's size, and `args` has to be built from the host's `argv` — so all four are emitted inline. `args` drops the program name, so `at (argv, 0)` is the first real argument, matching what stage 0's platform hands over. The bounds check in `at` and the negative-length check in `array` are there because stage 0 *panics* and two implementations of one intrinsic have to agree; only the message text differs. `stage1/fixtures/arrays.mpl` is the regression test. `write_file` is still unemitted and unused.

  The entry point changed with it: `int main(int argc, char **argv)`, with `mpl_argc`/`mpl_argv` set **before** `mpl_init`, because §4.10 lets a top-level `$decl` initializer read `args`.

  `stage1/mplc.mpl` is the result — `mplc <file.mpl>` emits C on stdout — and it was bootstrapped without stage 0 in the loop. The existing stage 2 was compiled from the *old* backend and cannot emit `args`, but it compiles the *current* source, so it can build an array-capable successor as long as what it emits does not itself use `args`; `selfc.mpl` reads a file, so it does not. Two 163-second steps rather than two 90-minute ones.

- **There is no way to write to stderr, so a compiled compiler can only report a diagnostic by dying.** §8 gives `print` (stdout) and `panic` (stderr, then abort), and nothing in between. `mplc` therefore aborts on a `check` or `verify` failure — correct, and it exits 134 because §7.8 makes `panic` abort — but it cannot *warn*: the §6a refusals stage 0 prints are invisible under it, because printing them would corrupt the C on stdout. This is the same root as `link` being unreachable: §9 makes `$extern` the only door to the platform and stage 1 has none. §8 wants either a stderr intrinsic or an explicit statement that diagnostics are the build program's problem (§9).
- Whether stage 1 emits one C file or one per morphl file (affects `$import` load-once semantics at the C level, not in the language).
- Whether to keep monomorphic root-block names permanently or shim them (§2, *Migration*).
