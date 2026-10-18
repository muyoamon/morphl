# §7.6 storage: design note

Status: **decided, not implemented.** SPEC §7.6 describes two kinds of
storage; the code has neither. `$new` and `$alloc` both compile to `mpl_alloc`, which is `malloc`
and is never freed, and there is no `allocator` name in either root block.

| | question | status |
|---|---|---|
| A0 | what a frame reference is, and where it may go | **decided**: a place, never stored |
| R | whether a function may return a place | **decided**: R2, a result may borrow |
| — | whether top-level `$new` is special | **decided**: no, it is the outermost frame |
| A | when frame storage is released, given §7.7's tail calls | **decided**: A4, a tail call may not pass its own places |
| B | what an allocator is | **decided**: B2, with §8 raw-memory intrinsics |
| C | whether the compiler itself uses allocators | not now (measured) |

## What §7.6 says, and what it leaves open

- **Frame storage** (`$new`) "is released when its scope exits", with "no allocator, no header,
  no bookkeeping and no runtime component". It is safe because §5.3a stops a frame-bound value
  outliving its scope.
- **Allocated storage** (`$alloc`) comes from `allocator`, "an ordinary name resolved lexically".
  The root block declares a default, `$decl allocator …` overrides it for everything lexically
  inside, and releasing is the author's job. `$alloc` is therefore unsafe by declaration.

Left open by that text: what "its scope" is; what a tail call, which replaces the caller's
frame (§7.7), does to it; whether a function may hand a place back; and what `allocator` is.

## Facts that shape the answer

- **Within one activation, each `$new` site runs at most once.** morphl has no loops; repetition
  is recursion, and every recursive step is a new activation. So the frame storage one
  activation can make is bounded by its function's static `$new` sites.
- **The compiler uses no `$new`.** Stage 1 contains none outside diagnostic strings: everything
  it returns was migrated to `$alloc`. The fixtures use it 15 times across 6 files. Frame storage
  is for user programs; releasing it does nothing for the compiler's memory.
- **The compiler's garbage is short-lived and interleaved** with what it keeps (PERF.md's
  instrumented self-emit: 92% of allocation garbage by the next phase boundary, at most 257 MB
  live, inside phases that build their survivors amid it).

## A0. A frame reference is a place, not a value (decided)

`$new` and `$alloc` look alike and are not.

- **`$new` makes a place.** `$decl c $new 0` binds `c` to the cell itself: the name *is* the
  storage, which lives in this activation's frame. A place can be read, written through, and
  passed down to a call, where the parameter aliases it. It is never a thing that is copied.
- **`$alloc` makes a value.** What it answers is a pointer — a reference-as-a-value — so
  `$decl xs $alloc …` is a frame binding whose content is that pointer. Storing it in a field, a
  list tail or another cell is storing a value, which is why prelude's `tail $alloc t` is fine.

**Storage never holds a place.** Only pointer values reach storage. Most of that is already
true: §5.4 reads a reference through wherever a value is expected, and the operands of `$new`,
`$alloc` and `$set` are such positions. So `$new $new 0` is one cell, and `$set p loc` copies
`loc`'s value. Measured, both stages:

```
$decl inner $func ($decl p $mut $new 0) {
  $decl loc $mut $new 7
  $decl w   $set p loc        // copies 7
  $decl w2  $set loc 9
  $decl ret 0
}.ret                          // the caller reads 7, not 9: nothing aliased
```

What is *not* yet true is a place carried **inside a value**. §5.4 keeps references in block
fields, so this type-checks with no errors today, and both stages answer 9:

```
$decl inner $func ($decl p $mut $new { $decl r $mut $new 0 }) {
  $decl loc $mut $new 7
  $decl w   $set p { $decl r loc }   // the caller's cell now holds a place in inner's frame
  $decl w2  $set loc 9
  $decl ret 0
}.ret                                 // the caller reads box.r: 9 — and once inner's frame is
                                      // released, a dangling pointer
```

**The rule:** a value that contains a place anywhere — in a field, or captured by a closure —
cannot enter storage. `$new`, `$alloc` and `$set` refuse it, whatever kind the storage is.
`T.frame_bound` is already that predicate; today it guards a function's result, `$alloc`, and
`$set` through *allocated* storage, and this extends it to `$new` and to `$set` of any kind.

```
$set p loc                          // fine: copies the value
$set p { $decl r loc }              // refused: the block would carry the place into storage
$decl b $alloc { $decl r loc }      // refused (already, today)
$decl xs $alloc { $decl head 1  $decl tail $alloc nil }   // fine: tail is a pointer value
$call f (loc)                       // fine: passing a place down
{ $decl r loc }.r                   // fine: a record used inside the activation
```

**The way out is unsafe and explicit**: §8's `box_ptr` turns a place into an address `Int`,
which is a value and may be stored, and `unbox` turns it back. A typed `$ref` was considered and
deferred until a program needs one: storing a place is meant to be rare and visibly unsafe.

## R. Returning a place: borrowing (decided, R2)

Today §5.3a refuses every function whose result contains a place. That refuses the shapes that
are sound along with the one that is not — all five of these are rejected:

| | program | sound? |
|---|---|---|
| 1 | `$func ($decl p $mut $new 0) p` — return a place you were given | yes: the caller owns it |
| 2 | `$func ($decl b { $decl r $mut $new 0 }) b.r` — a place reached through a parameter | yes |
| 3 | a local method returning `ctr.n`, `ctr` a `$new` in the enclosing function | yes |
| 4 | a method returning a field of *top-level* storage | yes |
| 5 | `$func () $new 3` — return your own place | **no** |

**The rule:** a function's result may contain a place only if that place was *not* made by this
activation's own `$new`. A place that came in — through a parameter, a capture, or a name in an
enclosing frame — is **borrowed**, and may be handed back. Inference records which parameters the
result borrows from in the function's type, as it already records which parameters escape
(`esc`), and a call's result is then a place owned by whoever owns those arguments:

```
$decl id_ref $func ($decl p $mut $new 0) p            // result borrows parameter 0

$decl main $func () {
  $decl c   $mut $new 0
  $decl d   $call id_ref (c)     // d is c's place, which main owns
  $decl w   $set d 5             // writes c
  $decl ret $call ival (c)       // 5
}.ret

$decl bad  $func () { $decl c $mut $new 0  $decl ret $call id_ref (c) }.ret
                                 // refused: the result borrows bad's own place

$decl pass $func ($decl q $mut $new 0) $call id_ref (q)
                                 // fine: borrows q, so pass borrows its parameter 0
```

- **It composes.** A borrowed result is a place like any other: A0 still keeps it out of
  storage, and the caller may return it only if it borrowed it in turn.
- **Captures and enclosing frames are borrowed**, which is what makes cases 3 and 4 work. A
  closure that captures a place is frame-bound, so it cannot outlive the activation that place
  belongs to, and anything it returns from its captures is still alive. A returned *closure*
  that captures places needs the same provenance: frame-bound only through borrowed places is
  fine, through its creator's own is not.
- **The machinery exists.** It is the escaping-parameter inference turned around: that work marks
  function- and trait-typed parameters and records which reach an escape point; this marks
  place-carrying parameters and records which reach the result — the same three typing sites,
  the same deferral for recursive calls, the same fixed point. The borrow set is part of the
  function type, as `esc` is: borrowing from fewer parameters is a subtype.
- **§7.6 needs amending.** It says "nothing is annotated and nothing is solved". Borrowing is
  still never written, but it is inferred: the single lifetime fact "the result borrows from
  these parameters", which is Rust's elision rule without the syntax.

## `$new` is the same in every frame (decided)

There is no special case for top-level storage. A file's top level is the outermost frame, and
its activation is the whole program, so `$decl counter $new 0` is a place in that frame like any
other, released when the program ends — that is, never during it. A module's top level is the
same. Case 4 above needs nothing extra under R2: a function reading `top` reads a place in an
enclosing frame, which outlives every call, so returning it is borrowing.

What differs is only the implementation, and only because of how the backend runs a top level:
its `$decl`s are initialised by thunks called from `mpl_init`, and a thunk's return is not the
top-level frame's exit. So a `$new` at top level is allocated in the program's frame — static
storage — rather than in the thunk's.

## A. Frame storage and tail calls (decided, A4)

`$new` means two things, by where it is written:

- **as a parameter's default, pass-by-reference.** `$decl c $new 0` in a parameter list asks for a
  place. The caller lends one and the function **borrows** it (§R's notion).
- **anywhere else, stack storage** owned by this activation, released when the activation ends.

A tail call ends the activation and reuses its frame (§7.7). So:

**The rule: a tail call may not pass a place this activation made.** Passing a borrowed place is
fine; passing an own one is ill-formed, and the diagnostic says what to do instead:

```
this tail call passes $new storage made in this call, and a tail call ends the call (§7.7):
allocate it with $alloc and release it when done, or make the call non-tail
```

On the five loops from the discussion (all type-check today; under A4):

```
$decl scratch $func ($decl n 0, $decl acc 0)                        // fine: values only
  $if ($call eq_int (n, 0)) acc
      ($call scratch ($call sub (n, 1), $call ival ($new $call add (acc, n))))

$decl count $func ($decl c $mut $new 0, $decl n 0)                  // fine: c is borrowed
  $if ($call eq_int (n, 0)) ($call ival (c))
      ($do ($set c ($call add ($call ival (c), 1))) ($call count (c, $call sub (n, 1))))

$decl fresh $func ($decl c $new 0, $decl n 0)                       // ill-formed: its own $new n
  $if ($call eq_int (n, 0)) ($call ival (c)) ($call fresh ($new n, $call sub (n, 1)))
```

`mixed`'s `tick` → `mixed` call and `hop`'s call through a function value are ill-formed for the
same reason as `fresh`. The rewrite the diagnostic advises:

```
$decl fresh $func ($decl c $alloc 0, $decl n 0)                     // legal: a pointer value
  $if ($call eq_int (n, 0)) ($call ival (c))
      ($do ($call allocator.free (c)) ($call fresh ($alloc n, $call sub (n, 1))))
```

**Three details.**

- **Every tail call, as language semantics.** In the emitted C only a self call, a group
  transition and a call through a function value reuse the frame; a tail call to an unrelated
  function is an ordinary C call, under which the caller's locals survive. The rule still covers
  all of them: §7.7 says every tail call replaces the frame, and if validity followed what the
  backend did, a call that closed a cycle elsewhere would make a distant, unchanged function
  ill-formed.
- **"Own" is exactly what §R infers.** A place is borrowed when it came in through a parameter or a
  capture, or lives in an enclosing frame (the file's top level included). A closure that captures
  an own place, and `$traitsof (expr)`'s fresh storage, are own. So A4 and R2 share one piece of
  inference — which places this activation made — and land together.
- **The non-tail workaround needs no allocator**: `{ $decl r $call fresh ($new n, …) }.r` runs the
  callee while this activation is alive, at a stack frame per iteration.

**What it buys.** No frame stack and no runtime component: every `$new` is a C local, and a
top-level one is a C `static`, so §7.6's "no allocator, no header, no bookkeeping and no runtime
component" stands as written. §7.7 holds without exception: a tail loop cannot carry its
activation's storage forward, so every one runs in constant space. And the cost of handing storage
down a loop moves into the source, as an `$alloc` and a `free`.

**The alternatives considered**, kept for the reasoning:

| | `fresh` | `count` | `scratch` | runtime |
|---|---|---|---|---|
| A1: release when the chain returns | grows with `n` | constant | **grows with `n`** | a frame stack |
| A2: refuse every place in a tail call | refused | **refused**: types cannot tell borrowed `c` | constant | none |
| A3: release unless the call passes a place | grows with `n` | constant | constant | a frame stack for "keep" functions |
| **A4: refuse own places in a tail call** | refused, with the `$alloc` rewrite | constant | constant | **none** |

A3 was prototyped (a frame stack with marks, reset per call site and around §6a's drive; it ran
clean under ASan and reclaimed everything at each chain's end). A4 needs none of it, because no
program it accepts can make a tail call that needs storage to survive the frame.

## B. What an allocator is (decided, B2)

```
$decl main $func () {
  $decl a   $call arena ()
  $decl r   {
    $decl allocator a                    // every $alloc lexically in here uses a
    $decl xs  $alloc { $decl head 1  $decl tail 0 }
    $decl ret $call total (xs)
  }.ret
  $decl d   $call release (a)            // xs's memory is gone; r is a plain Int
  $decl ret r
}.ret
```

**B1. Built-in arenas.** `arena ()` and `release (a)` are root-block intrinsics, and `$alloc`
becomes `mpl_alloc_in (a, sizeof (T))`. Simple and fast; no user can write an allocator.

**B2. An allocator is a trait** (chosen): any value conforming to
`$traitsof { $prop alloc $func ($decl size 0) 0  $prop free $func ($decl addr 0) () }`.
`alloc` answers an address; `free` releases one object, which is what A4's diagnostic means by
"release it when done". `$alloc e` asks the lexical `allocator` for `sizeof (T)` bytes and stores
`e` there. An arena implements `free` as nothing and releases everything at once; the root's
default implements it with `raw_free`. This is §7.6 as written: the
root's default is one implementation, and an arena or a pool is library morphl.

- The root default is recognised statically and emitted as `mpl_alloc`, so `P.list`'s cons cells
  — most of what the compiler allocates — pay no indirect call.
- **Decided: a library allocator reaches raw memory through §8.** It cannot bind libc's `malloc`
  directly: the runtime includes `<stdlib.h>`, so an `$extern "malloc"` with morphl's types
  conflicts with the header. Two ways round it:
  - **a C shim per allocator**: the library ships a `.c` file and `link`'s extra arguments
    (§9.1) compile it in. Nothing new in the language, but every allocator needs C.
  - **§8 raw-memory intrinsics** (chosen): `raw_alloc (n)` answering an address `Int`
    (0 on failure) and `raw_free (addr)`, beside `str_ptr` and `unbox` in the FFI group and
    unsafe by declaration like them. An arena is then pure morphl. It adds two root-block
    names, so the two-step bootstrap.

**Lexical, in both.** `allocator` is resolved where `$alloc` is *written*, so
`$decl allocator my_arena` in `main` does not redirect `P.list`'s cons cells, which are written in
`prelude.mpl`. §7.6 chooses that ("no implicit region parameters"); a library whose data should
land in a caller's arena takes the allocator as a template generic, or a build program replaces
the root's `allocator` for the whole program (§9).

## C. Whether the compiler should use allocators (not now)

Lowering alternates keeping and discarding within single calls — build a type, intern it (kept),
build an IR node (kept), render a memo key (garbage) — so a per-phase arena would free the
survivors with the garbage. Separating them means building every survivor under an outer
allocator, and with lexical resolution `types.mpl`'s constructors and `prelude`'s lists would
become templates over the allocator. Revisit if the compiled compiler's memory becomes the
constraint again.

## Measured reach (plan step 1)

An instrumented copy of the compiler — reporting-only probes at each `$new` and `$set` whose
value contains a place (A0), at each emitted tail call (does an argument contain a place),
and at each `new` node of frame kind — was run over all 116 files in
`stage1/` and `stage1/fixtures/`: every module, driver, test suite and fixture. Imported modules
are checked once per importer, so sites are counted unique.

| question | result |
|---|---|
| A0: programs it would newly refuse | **0** — no `$new` or `$set` anywhere stores a value carrying a place |
| R2: functions it would newly accept | 0 by construction — the corpus type-checks, so it returns no places; R2's reach is the four sound shapes in §R, all refused today |
| functions whose activation makes frame storage | **7**, all in fixtures (`storage` ×2, `alloc`, `extern`, `module_value`, `traits`, `unions`); none in the compiler |
| A4: tail calls that pass a place at all | **0** of 48,248 emitted — so none passes an own one |

A zero is evidence only if the probe can fire, so each was checked on programs written to trip
it: the §A0 block-field program reports its `$new` and its `$set`, and the §A loops report
`fresh` and `count` as passing a place and `scratch` as not — `count` included, which is the case
types alone cannot distinguish and R2's provenance does.

So A0 and A4 change nothing that exists: every current program keeps its meaning, and no tail
call in it passes a place. What they buy is for programs not yet written. The instrumentation lives in
the scratchpad only (`instr.py` applied to a copy of `stage1/`); nothing was committed.

## Plan

1. **Measure the rules' reach.** Done: see above. A0 refuses nothing that exists, and no tail call
   passes a place.
2. **A0, R2 and A4 in the checker.** One piece of inference — which places an activation made —
   serves all three: A0 tightens, R2 loosens, and A4 refuses own places in tail calls. Fixtures:
   `test-reject` cases for A0, R's case 5 and `fresh`; accepting ones for R's cases 1–4, `count`
   and `scratch`.
3. **`$new` as C locals.** Each `$new` site becomes a local in its function's frame (a C `static`
   at top level), and the slot holds its address. Fixtures: `scratch` at 2,000,000 iterations, and
   the A0 and R programs, run under the compiled backend so a wrong lifetime shows as a sanitizer
   error rather than a leak.
4. **Allocators (B2).** `raw_alloc`/`raw_free` and the root `allocator` with `alloc` and `free`
   (the two-step bootstrap), conformance in inference, the lexical allocator at each `$alloc`, the
   static fast path for the default, then a library arena with a fixture that allocates, releases
   and allocates again, and `fresh` rewritten as A4's diagnostic advises.
5. **Docs.** SPEC §5.3a and §7.6 for A0, R2, A4, uniform `$new` and B2, including the lexical
   consequence; BOOTSTRAP §3, which still says "region inference widens" where SPEC has none.
