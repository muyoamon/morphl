# §7.6 storage: design note

Status: **implemented**. All five plan steps are done; SPEC §3.5, §4.2, §4.2a, §5.3a, §7.6
and §10 state the result, and this note keeps the reasoning and the measurements. §R3,
constructing calls, came later with a plan of its own, and it is in too, its first cut's
refusals included.

When this was written, SPEC §7.6 described two kinds of storage and the code had neither:
`$new` and `$alloc` both compiled to `mpl_alloc`, which is `malloc` and was never freed, and
there was no `allocator` name in either root block.

| | question | status |
|---|---|---|
| A0 | what a frame reference is, and where it may go | **decided**: a place, never stored |
| R | whether a function may return a place | **decided**: R2, a result may borrow |
| — | whether top-level `$new` is special | **decided**: no, it is the outermost frame |
| R3 | whether a function may construct into its caller's frame | **implemented**: yes, when its body *is* the `$new` |
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

## R3. Constructing calls (implemented)

R2 refuses case 5, `$func () $new 3`, and it is right to: the place dies with the activation
that made it. But that leaves the language without a way to make a value with storage and
deferrals — an owned string, a file handle, a buffer — from a function, short of `$alloc` and a
`free` the author must remember. The workaround found so far is a value template:
`$template k $new { … }` is frame storage of the scope `$specialize` stands in (SPEC §4.9), so
`$specialize owned 3` is an inline constructor. It works in all three implementations
(`tmpl_own.mpl`), and it is the wrong tool: a template's purpose is making a specialised *type*
from an expression, not building a concrete value.

**The rule: a function whose body is a `$new` constructs into its caller.** The caller provides
the storage, and the call is frame storage of the scope it stands in — exactly as if that `$new`
were written at the call site:

```
$decl mk $func ($decl k 0) $new { $decl v k  $defer $call say (v) }

$decl user $func () {
  $decl a   {
    $decl s    $call mk (1)          // s owns the place, as it would own a $new written here
    $decl ret2 $call say (2)
  }.ret2                             // say (1) runs here, after say (2)
  $decl ret $call say (3)
}.ret                                // log: 213
```

Everything after the call follows from "a `$new` written there", and needs no rule of its own:
the caller's `$decl` owns the place or it is ephemeral and dies at the item's end (SPEC
§4.15a); it may be lent to a callee; R2 refuses returning it from a function that is not itself a
constructor, and A4 refuses passing it in a tail call, because it is the caller's *own* place.

### Only the syntactic shape constructs

The body must **be** the `$new` — `$new e`, `$mut $new e` or `$const $new e` — or a bare tail
call to another constructor. A place that merely *flows* to the result does not qualify:

```
$decl mk2 $func ($decl k 0) {        // still refused, by R2, with today's message
  $decl s   $new { $decl v k }
  $decl ret s
}.ret
```

Accepting `mk2` would turn every frame leak R2 refuses today into a constructor without a word:
whether a function constructed would follow where its references happen to go. With the shape
rule, constructing is visible in the source and R2 stays exactly as written. It also removes
every question of ownership *inside* the constructor: no `$decl` there binds the place, so there
is no owner to hand over and no alias to excuse, and since each activation runs the one literal,
its deferrals are one set known at compile time — no run-time flag, no drop pointer.

It costs little, because a block's items can do any work: set-up that would follow the `$new`
moves inside it.

```
$decl from $func ($decl src "") $new {
  $decl n   $call len (src)
  $decl p   $call raw_alloc (n)
  $decl w   $call copy_into (p, src)        // initialisation is an item, not a later $set
  $defer    $call raw_free (p)
}
```

### A constructed block's deferrals read only the block and what is global

They run when the *caller's* owner dies, long after the constructor's frame has gone, so they
may name the block's own bindings, top-level bindings and the root block — never a parameter or
a local of the constructor. Its field initialisers may read anything, since they run during
construction:

```
$decl bad $func ($decl k 0) $new { $decl v k  $defer $call say (k) }    // refused: k
$decl ok  $func ($decl k 0) $new { $decl v k  $defer $call say (v) }    // keep it as a field
```

A0 makes this the whole rule rather than an approximation: storage never holds a place, so a
constructed block cannot keep a borrowed place for its deferral to read either. Stage 0 already
fails the first at run time ("unknown name 'k'"); the checker refuses it statically.

### Forwarding: a tail call to a constructor constructs

```
$decl mk0      $func () $call mk (0)                       // a default
$decl from_len $func ($decl s "") $call mk ($call len (s)) // an adapter
```

The caller of `mk0` holds the slot; `mk0` answers the block `mk` built, and the caller stores
it there. A4 is not involved, since the slot belongs to `mk0`'s caller.
A constructor's deferral set is a property of the function, so the caller runs it directly:
`mk0`'s is `mk`'s. Without forwarding every wrapper, default or overload would repeat the
literal.

### Calling convention and type

The plan was a hidden destination after `env`, `T *dst`, for the `$new` to write through. What
was built is simpler and means the same: **the constructor answers its block by value, and the
caller makes the storage** by wrapping the call in the `$new` node it stands for — a C local
`n<id>`, or a thunk's `static`, exactly as a `$new` written there is. No address has to cross
the call, because nothing in a block can name its own place while it is being built: the
place exists only once the `$new` has its value. So emit and §7.3's calling convention are
untouched, and a forwarding body is an ordinary tail call answering what its callee answers.
The function type still records that it constructs — a flag beside `esc`, part of identity
and of subtyping — since the caller must make the storage. A constructing function **used as
a value** is refused for now, for the same reason a short call must name a definition (SPEC
§3.4): a call through a value cannot know to make it.

### What the first cut leaves out

| shape | first cut | later |
|---|---|---|
| body is `$new`, `$mut $new` or `$const $new` | **constructs** | |
| body is a bare tail call to a constructor | **constructs** | |
| `$if`/`$match` arms, each the same constructor | refused | maybe: one deferral set |
| arms with different literals or storage types | refused | likely never: branch in a field |
| a `$try` among the literal's items | refused | **constructs, and can fail** (step 6) |
| a constructor used as a value | refused | a shim, and §6a's pending block saying it constructs |

**Arms** would bring back what the shape rule removed. Two literals of one storage type have two
deferral sets, so the callee would have to write a drop pointer beside the slot for the caller to
test; two storage types (`<&A, &B>`) have no single slot at all. A branch inside one literal does
the same job with one set, the field telling the deferral what to do:

```
$decl pick $func ($decl c true) $new {
  $decl p   $if c ($call raw_alloc (8)) 0
  $defer    $if ($call eq (p, 0)) () ($call raw_free (p))
}
```

**`$try`** was the case worth having next — a constructor that can fail (open, parse,
allocate), and step 6 below is what it became:

```
$decl parse $func ($decl src "") $new {
  $decl p   $call raw_alloc (16)
  $defer    $call raw_free (p)
  $decl n   $try ($call str_to_int (src)) none     // may leave half built
  $decl w   $call store (p, n)
}
```

On failure the block is half built in the caller's slot, which is still alive. SPEC §4.15a runs
the deferrals registered before the `$try` (`raw_free (p)`), in the constructor, and that is
sound; the constructor answers `none`. Its result widens to `<&T, none>` (§4.15), so the type
must say which member is constructed, and the caller runs the drop only when its owner holds
that member — a tag read, not an address compare. Stage 0 agreed already, as a probe showed: it
runs the registered deferrals and finds no place in `none`.

### What changes in SPEC

- §5.3a, the second rule: a result may hold only borrowed places, **except** that a function
  whose body is a `$new`, or a tail call to such a function, constructs: its result is frame
  storage of the scope the call stands in, and the call is a `$new` written there.
- §4.15a: a constructed block's deferrals may name only its own bindings and what is global; the
  owner list's "a call that hands it back" gains the constructing call.
- §3.4 and §7.6: the function type records that it constructs, and the caller's slot and its
  address passed to the constructor (§7.3's two-word value is untouched, since value use is
  refused).
- §4.9: unchanged. A value template's `$new` stays the caller's frame storage, as fixed in
  08eb63e, but the idiom for a constructor is a function.

### Plan

1. **SPEC**, as above.
2. **Checker.** Done. The shape test on a `$func` body (beside `func_close`, at all three typing sites:
   `infer_func`, `infer_rec_func`, `infer_fwd_body`); the flag on `t_func`; R2's exemption; the
   call site as an own place in `owns_form`, as `$specialize`'s is; the deferral-scope rule; and
   the refusals in the table. The flag is `2000` in `esc`, rendered `ctor`, so it joins
   identity, hash and key the way `nonroot`'s `1000` does and changes no other type. It found
   one more refusal the table lacked: a call to a constructor made while its type is still a
   placeholder — through a `$fwd`, or from its own body — reads as an ordinary call, so a
   wrapper forwarding to it lost the flag and its callers accepted a dangling place
   (`cx.ctorpend`). And stage 0 pooled a call's scope that a constructed block's deferral
   still reads through: `$defer` now counts for `mayCapture`. Until step 3, lowering
   refused a constructor ("not lowered yet"). `ctor_bad.mpl` is the `test-reject` case.
3. **Lowering.** Done. A constructor's body answers the block's value (`ctor_body`), with its
   deferrals taken off the stack: they are lifted into `drop`, a function of the block's
   fields lowered once in the constructor's own module and environment, every field rebound
   to a parameter (`build_drop`). The caller wraps the call in the `$new` node
   (`ctor_site`): with deferrals, in the `$new` literal's shape — its address saved for
   `own_inits`, a flag in an arm — and registers `drop (s.f0, s.f1, …)`, `s` the value saved
   before the `$new` took it, tagged with the call's position, which `flows_form` answers as
   a `$new` literal's. So the owner walk, `$try`, ephemeral release, a call that may hand it
   back and a top-level owner (`ctor_in` beside `Pa.storage_defers`) all decide it unchanged.
   Saving the value is what keeps stage 0's reading: a deferral reads its block's bindings as
   they were built, and `$set` on `$mut` storage afterwards does not change them. A forwarding
   body is recognised at its call (`ctorfwd`, the call's file and span) and answers the value
   in tail position. Records (`st.ctors`, in the snapshot) are by global index — an alias
   thunk of a constructor is registered as it (`ctor_alias`) — or by a block-local
   function's `ldef_ent` id; a call to a constructor not yet lowered is refused, which
   §5.3a's own refusal of a call before the type is known makes unreachable in practice.
4. **Emit.** Nothing: see "Calling convention and type". `drop` is exported and named from the
   constructor and its literal's position, since a call in any module's output may want it.
5. **Fixtures.** Done: `ctor.mpl` (with `ctor_util.mpl`) has `tmpl_own.mpl`'s seven cases as
   functions and the shapes R3 adds — forwarding, an alias, `$mut` set after it was built, an
   ephemeral one, one in an arm, one through a call that may hand it back, two fields read by
   one deferral, a block's own constructor, another module's, and top-level owners in both
   files — in both stages, compiled, folded, split and under ASan. `ctor_bad.mpl` is the
   `test-reject` side.
6. **A `$try` in the block.** Done. The checker's refusal is gone, and nothing replaced it:
   the deferral rule, R2's exemption and the caller's own-place rules hold as they were, and
   §4.15 widens the constructor's result as any function's. Lowering's `$try` already runs
   every deferral on the stack, and the block's are there, tagged, while it is lowered — so a
   failure runs what was registered before it, in the constructor. The record carries what
   the constructor answers (`res`, the block joined with each `$try`'s exit) and what the call
   is (`out`, the reference joined with the same). A call to one that can fail is a switch
   (`ctor_site`): the block's member goes into the `$new` and sets the flag `drop` is guarded
   by — the arm-flag machinery, always on here — and every other member is answered into
   `out` by an arm of its own. The tag read is the switch itself. `ctor_try.mpl` is the
   fixture: before and after the `$try`, forwarding, two exits, no deferral, ephemeral, an
   arm and a top-level owner, in both stages and under ASan.

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
2. **A0, R2 and A4 in the checker.** Done. Provenance is a walk over the function's source
   (`owns_x`), not a mark on types: `join` and `union_add` keep one of two equal types whole,
   so a mark would be dropped in the unsound direction. A0 also let `T.frame_bound` stop at
   every reference, which kept asking it at every argument level in time. Fixtures:
   `borrow.mpl` (accepted, both stages) and `places.mpl` (five refusals, in `test-reject`).
3. **`$new` as C locals.** Done. Each frame-kind `new` site is a local `n<id>` named by its
   node's §9.3 index, declared with the slots — at the top of the function or of a group
   member's `case`, never where the `$new` stands, since a place made in an `$if` arm is used
   after it — and a thunk's is `static`. `frame.mpl` covers a 2,000,000-iteration loop, a cell
   made in an arm and used after it, a group's cells and top-level storage, and runs in a
   20 MB cap that the old `mpl_alloc` could not meet even at 60 MB. Every fixture also runs
   under AddressSanitizer with use-after-return detection, and UBSan (`zig build test-asan`),
   checked to catch a dangling local made through `box_ptr`/`unbox`. The compiler's own C is
   unchanged: it uses no `$new`.
4. **Allocators (B2).** Done. `raw_alloc`/`raw_free` are §8 intrinsics; the root `allocator` is
   bound at a marker type (`T.ffi_alloc`) whose `alloc` and `free` are those two. `$alloc` from
   the root stays `mpl_alloc`; from any other allocator it is the prim `alloc_in (member,
   value)`, the member called with the storage's size — an ordinary call node, so no tree walker
   had to learn a new kind. An allocator is an ordinary block whose members name their receiver,
   so the call is resolved statically and needs no trait object. **Which `$alloc` sites use a
   non-root allocator is decided by inference**, in §4.10's source order, and handed to lowering
   (`ualloc`, by file short name, line and column): lowering binds an entry file's globals up
   front, and resolving the name itself made an initializer written *above* `$decl allocator`
   draw from it while inference said the root. No two-step bootstrap was needed: the compiler's
   source calls none of the new names. Fixtures: `arena.mpl` (a morphl arena, reset and reused)
   and `alloc_free.mpl` (A4's rewrite freeing through the root allocator, under a 20 MB cap a
   million unreleased cells cannot meet), both compiled-only.
5. **Docs.** Done. SPEC §3.5, §4.2 and §4.2a describe a place and a pointer value; §7.6 is
   rewritten around the activation, the top level as the outermost frame, tail calls, and an
   allocator as a value with `alloc` resolved in source order where `$alloc` is written, with
   the lexical consequence for libraries; §10's item 16 admits the one inferred fact. BOOTSTRAP
   §3 no longer cites region inference, which SPEC has none of.
