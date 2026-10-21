# `$defer`, owners and `$free`: design note

Status: **steps 1 and 2 done** — the owner rule measured (it breaks nothing), and `$defer` for
scopes and plain values in both stages (SPEC §4.15a). Storage, owners and `$free` are not. Decided in discussion; the open points are at the
end. SPEC is unchanged until the plan's first step.

`$defer e` runs `e` when what its block became is destroyed. Because a block is scope,
record and storage at once (§4.5), "what it became" has to be defined for each, and doing so
gives morphl an **owner** for every place and a typed release for allocated storage,
**`$free r`**. Deferrals are logic, not type: frame storage needs no bookkeeping at all, and
allocated storage hands its deferrals to the allocator that made it.

## Why

Cleanup today is written by hand at every exit, and `$try` (§4.15) makes the exits
implicit: a function that opens something and has three `$try`s in it has four places to
close it. A `$defer` written once beside the acquisition covers all of them.

The difficulty is that morphl has no separate notion of an object. `{ … }` is a scope when
its items run, a record when its value is used, and storage under `$new` or `$alloc`. So
`$alloc { … $defer … }` must mean something, and the answer has to be the same rule seen
from three sides rather than three rules.

## The model

### A deferral belongs to what its block became

| the block is… | its deferrals run |
|---|---|
| a scope only: a statement, a `.ret` projection, a function body | when its scope exits |
| a plain value: `$decl w { … }`, passed, returned | when its own evaluation ends — the block's lifetime is its initialisation; the record outlives it |
| frame storage: `$new { … }` | when the place's **owner** is destroyed |
| allocated storage: `$alloc { … }` | when the storage is released by **`$free`** |

Running is the release's **trigger**, not something after it: the deferrals run while the
storage is still valid, last thing before it goes, so they may read the block's fields.

**A copy carries no deferral.** A value has no identity — returning it, passing it or
reading it out of a field copies it (§7.3) — so a deferral cannot belong to a value without
running once per copy. A plain block's deferrals have run by the time its value exists.

**Attachment to storage is syntactic.** Only a block literal that is directly the operand
of `$new` or `$alloc` (through parentheses, since `(e)` is `e`) is evaluated *into*
storage. `$new $call mk ()` stores a copy of a value whose deferrals already ran, and so does
`$new ($if c { … } { … })`. A resource constructor therefore returns storage —
`$decl open $func (…) $alloc { … $defer … }` — never a block value.

Order is reverse order of writing within a block. `$try` leaving a scope runs its pending
deferrals, since it is a return (§4.15). `panic` does not: §7.8 makes it abort.

### Owners

**A place's owner is the first `$decl` that binds it.** Before that, the place *flows* —
through parentheses, `$if`/`$match` arms, and calls that hand back the same place they were
given. After it, every other binding is an **alias**: `$decl y x`, a parameter (a borrow),
a reference copied out of a field.

**An alias may not outlive its owner.** This is a rule about references, not about
`$defer`, and it holds for every place. Today §5.3a confines a place to its *activation*;
this confines it to its *owner*:

```
$decl r {
  $decl x   $new 5                // owner: field x of this block's record
  $decl ret x                     // an alias
}.ret                             // the record is projected and discarded: x dies here
                                  // error: r would alias a place whose owner has ended
```

**A place no `$decl` captures is ephemeral**, and dies where its flow ends: at the end of
the expression that consumes it without handing it on — a call that does not return it, or
a conversion to a value.

**A record owns its fields' places**, and whatever owns the record owns them in turn: in
`$decl w { $decl n $new … }`, the place lives as long as `w`'s scope.

Memory is unchanged: frame storage is still a C local released with the activation (§7.6,
STORAGE.md step 3). The owner decides when the *place* is dead to the checker and when its
deferrals run.

### Allocators hold the deferrals

Frame storage needs no record of its deferrals: the compiler knows every `$new` site and,
from the provenance walk, its owner, and emits the deferrals at the owner's scope exit.

Allocated storage is released by `$free`, possibly far from its `$alloc`, so something must
remember. Not the type — a deferral is logic, not structure, and putting it in the type would
contradict "a copy carries none". Not a header on every allocation — most `$alloc`s, all of
stage 1's among them, never free and have no deferrals. **The allocator.** `$alloc { … $defer
… }` registers the deferrals with the allocator in scope, `allocator.defer_at (addr, fin)`,
right after `alloc`; it is a compile error if that allocator has no `defer_at`. How the
allocator remembers — a list, a side table, a header of its own — is its business. An arena
keeps a list and runs it at `reset`/`release`, so bulk release runs deferrals too.

### `$free r` and routing

`$free r` runs the deferrals registered for `r`'s storage and then calls the allocator's
`free (addr, size)`. The size comes from `r`'s pointee type, which §5.3's invariance makes
exactly the type allocated; the one covariant view, `&const T`, is refused, since ending
storage's existence is not a read. `allocator.free (addr)` stays the raw, unsafe primitive
for allocators written in the language.

**Routing is lexical, with one checked rule.** Every `$alloc` resolves `allocator` to a
binding; that is the reference's *allocator provenance*. `$free r` is legal only where
`allocator` resolves to that same binding. The idiom keeps the two together:

```
$decl work $func () {
  $decl allocator $call M.arena (65536)
  $defer          $call allocator.release ()       // registered first, runs last
  $decl buf       $alloc { … }
  $defer          $free buf                        // the arena's free, before the release
  …
}.ret
```

Freeing a parameter goes through a summary in the function type — "frees parameter *i*,
allocated by binding *B*" — checked at each call. That works when *B* is visible at the
call: the root or a module-level allocator. A local allocator cannot be named across a
function boundary, so its storage is freed in its own scope, which is the idiom anyway. A
`$free` whose reference has unknown provenance — read out of storage, or from a call with no
summary — is refused.

**Lifetime is the author's.** Storage from a local allocator outliving the allocator is the
author's error, as §7.6 already says of any reference used after its allocator released it.
Frame references cannot escape (§5.3a enforces it); allocated ones can by design — every list
cell is one — and for those the language checks routing, not lifetime.

### What an allocator provides

| member | required for |
|---|---|
| `alloc (size) -> addr` | `$alloc` (§7.6, as today) |
| `free (addr, size)` | `$free` |
| `defer_at (addr, fin)` | `$alloc` of a block with deferrals |

Everything else — `release`, `reset`, `grow`, statistics, the capability traits that let
generic code be bounded by these — is library (`std/allocator`) or the allocator's own. The
size passed to `free` lets an allocator that records nothing, a size-class pool, free without
a header of its own.

## Examples

`print` makes the order visible. ★ marks a choice that was made in discussion rather than
forced.

```
// 1. A scope: at exit, last written first.                         prints "open two one"
$decl main $func () {
  $decl a   $call print ("open ")
  $defer    $call print ("one ")
  $defer    $call print ("two ")
  $decl ret 0
}.ret

// 2. A plain value: at the end of its evaluation; a copy carries none.
$decl w   { $decl k 5  $defer $call print ("done ") }     // "done " here, once
$decl w2  w                                               // nothing, ever

// 3. `$try` runs pending deferrals; `panic` does not.
$decl f $func ($decl s "") {
  $defer    $call print ("cleanup ")
  $decl n   $try ($call str_to_int (s)) none                // on none: "cleanup ", returns
  $decl ret n
}.ret

// 4. A `$decl`'d `$new` dies with its owner's scope.                 prints "body r after"
$decl main $func () {
  $decl a   {
    $decl r    $new { $decl k 1  $defer $call print ("r ") }
    $decl ret2 $call print ("body ")
  }.ret2
  $decl ret $call print ("after ")
}.ret

// 5. Ephemeral: dies where its flow ends.                            prints "tmp next"
$decl use $func ($decl c $new { $decl k 0 }) c.k             // answers a value, not the place
$decl x   $call use ($new { $decl k 3  $defer $call print ("tmp ") })
$decl y   $call print ("next ")

// 6. Read as a value: the flow ends there.
$decl v $call C.ival ($new 0)                                 // the place dies after ival

// 7. ★ A call answering the same place passes ownership through.    prints "using a"
$decl id   $func ($decl c $new { $decl k 0 }) c
$decl main $func () {
  $decl a   $call id ($new { $decl k 7  $defer $call print ("a ") })   // a owns it
  $decl b   $call print ("using ")
  $decl ret a.k
}.ret
// With `$call g ($call id ($new …))` and g not answering it, it dies after g.

// 8. An alias may not outlive its owner — every place, deferral or not.
$decl a $new 5
$decl b a                                                     // same scope: fine
// …and the `r` example under "Owners" is refused.

// 9. ★ A record owns its fields' places.                             prints "x n"
$decl main $func () {
  $decl w   { $decl n $new { $decl k 1  $defer $call print ("n ") } }
  $decl a   $call print ("x ")
  $decl ret 0
}.ret
// A copy of w copies the reference in n: an alias, which may not outlive w.

// 10. A `$new` that never ran has no deferrals: one of A or B at p's scope end.
$decl p $if c ($new { $defer $call print ("A ") }) ($new { $defer $call print ("B ") })

// 11. ★ Nested storage: the outer block's deferrals, then its fields'.  "outer inner"
$decl o $new {
  $decl a   $new { $defer $call print ("inner ") }
  $defer    $call print ("outer ")
}

// 12. Top level: the owner's scope is the program.                   prints "hi bye"
$decl log  $new { $defer $call print ("bye\n") }
$decl main $func () $call print ("hi ")

// 13. `$alloc`: registered with the allocator, run at `$free`.
$decl open $func ($decl path "") $alloc {
  $decl fd  $call sys_open (path)
  $defer    $call sys_close (fd)        // fd is a field: fine
}
$decl f $call open ("a.txt")
$free f                                 // sys_close, then the root's free

// 14. An `$alloc` deferral may read its block's fields, not the frame it was written in:
//     it runs at `$free`, after that frame is gone — the rule a member has (§4.10).
$decl bad $func ($decl path "") $alloc {
  $decl fd  0
  $defer    $call print (path)          // error: path is a capture
}

// 15. ★ Storage never freed never runs its deferrals: leaking is the author's business.

// 16. Routing: `$free` where `allocator` is the binding that made the storage.
$decl release_it $func ($decl r $mut $alloc 0) $free r        // root's scope
$decl main $func () {
  $decl allocator $call M.arena (4096)
  $decl r   $mut $alloc 7
  $decl x   $call release_it (r)       // error: r is the arena's, release_it frees the root's
  $defer    $free r                    // fine
  $decl ret 0
}.ret

// 17. An allocator without `defer_at` cannot take a block with deferrals.
$decl allocator $call bump (4096)      // alloc and free only
$decl g $alloc { $defer … }            // error: this allocator cannot run deferrals
```

## What the current language does

- **No `$defer`, no `$free`.** Release is `allocator.free (addr)`, an `Int` address, written
  by hand.
- **`free` reaches the allocator in scope where it is written**, not the one that made the
  storage. Measured (`std/mem`'s arena allocating in `main`, the same storage freed from a
  function at the top level): `main`'s `allocator.free` calls the arena's `free`, the other
  calls `mpl_raw_free`. Under ASan an interior arena pointer is a **`bad-free`**; the
  arena's *first* allocation is its buffer's base, so freeing that one through the root is
  silent and frees the whole arena. §7.6 calls it the author's error and nothing checks it.
  Example 16's rule turns it into a compile error.
- **A place lives as long as its activation** (§5.3a, §7.6), so the `r` example under
  "Owners" is legal today. **Nothing relies on it** (plan step 1, below).

### Measured: what the owner rule breaks (plan step 1)

**Nothing.** A temporary probe in inference flagged every projection off a block literal —
the record discarded, so its fields' places die there — whose projected value holds a place
made inside that block: exactly an alias outliving its owner, whether the field itself was
the owner (`{ $decl ret $new … }.ret`) or an alias of one. It walks with nothing bound
outside the block, so "own" means made inside it, `$traitsof` of a local included. Checked
on a hand-written case first (both shapes flagged, a plain value not).

| over | `$new` in real code | hits | of which already errors |
|---|---|---|---|
| `stage1/` modules and drivers (`mplc.mpl`, the whole closure) | 0 | 0 | — |
| `std/`, every module and test | 0 | 0 | — |
| the 10 fixtures using `$new` | 45 | 4 | 4 — all `places.mpl`, the reject fixture |
| the test suites' embedded programs (`infer`, `lower`, `emit`, `ir`, `parser`) | — | 4 | 4 — `infer_test`'s `a11`, `st05`, `bw02`, `bw05` |

Every hit is a function body returning its own place, which R2 already refuses; `a14`, where
a parameter only shares the name, is correctly not flagged. So **the rule removes no program
that is accepted today** — the activation-level confinement was only ever exercised at
function boundaries. What the probe does not see are records discarded other than by
projection — a block literal passed straight to a call that hands back a place from it — and
none of the code above has that shape. The probe was not committed.

## SPEC changes

- **§2.2**: `$defer e` and `$free r`, arity 1 each. `$defer` is a block item that binds
  nothing; anywhere else it is an error.
- **A new section** (beside §4.15) for `$defer`: the four cases of the table, order,
  `$try`, `panic`, syntactic attachment, and that a copy carries none.
- **§5.3a**: owners. A place's owner is the first `$decl` binding it; an alias may not
  outlive its owner; an ephemeral place dies where its flow ends; a record owns its fields'
  places. Replaces activation-level confinement.
- **§7.6**: the allocator members (`free (addr, size)`, `defer_at`), `$free` and its routing
  rule, and that a local allocator's storage outliving it is the author's error.
- **§7.7**: nothing — a call inside a block is already never a tail call, so a pending
  deferral cannot sit in front of one. **§7.8**: `panic` runs no deferrals.

## Compiler changes

**Stage 0** (`lib/`): the two keywords in `keyword.zig`; `$defer` as a block item with a
per-scope deferral list run on every exit, `$try`'s unwinding included; `$new` blocks'
deferrals run at the owner's scope exit, which stage 0 can approximate by the place's
activation and must not run early; `$free` calling `defer_at`-registered functions then
`free`. Stage 0 checks nothing statically (BOOTSTRAP §1.3), so the new rules are stage 1's.

**Stage 1**:

- `parser.mpl` — the arity table.
- `infer.mpl` — `$defer` only as a block item; the owner rules in the provenance walk
  (`owns_x`, `cx.placed`), extended from "this activation made it" to "which `$decl` owns
  it"; a per-function summary of which parameter's place the result is, recorded in the
  function type beside `esc`; allocator provenance for every `$alloc` and the `$free`
  routing rule, with the parameter summary; `$alloc` deferrals held to a member's no-capture
  rule; `defer_at` required on the allocator.
- `lower.mpl` — a deferral as a lifted function: for a scope or a `$new` block, called at
  the exits; for an `$alloc` block, passed to `defer_at`. A flag per `$new` site that may not
  run (example 10).
- `emit.mpl` — deferrals at every exit of a scope: falling off the end, each `$try`
  return, and before a group member's `continue` where the scope ends there. `$free` as a
  call to the registered deferrals' runner and `free` with `sizeof`.
- `verify.mpl` — a deferral's function takes no parameters; `$free`'s size matches.

**Library**: `std/mem`'s arena gains `defer_at` (a list run on `reset`/`release`) and a sized
`free`; the root gains a sized `free` and, if decided, `defer_at` over a side table.

## Plan

1. **Measure the owner rule's reach** — **done**: nothing accepted today is refused by it
   (the table above). The migration is empty.
2. **SPEC**, then **`$defer` for scopes and plain values** in both stages — **done.** SPEC
   §4.15a, and the §2.2 row. A `$defer` in a block that is directly `$new`/`$alloc`
   storage, and one at a file's top level, are refused until their meaning is settled
   (`stage1/fixtures/defer_bad.mpl`, in `test-reject`). How each stage does it:
   - **Stage 0** collects a block's deferrals as it reaches them (`runDeferring`) and runs
     them in reverse when its items are done; on `error.TryReturn` it runs those
     registered so far and carries on unwinding; a `panic` is a different error and runs
     none. A block without a `$defer` pays one count.
   - **Stage 1** registers a deferral with the environment it stands in (`lstate.defers`,
     cleared at each `lower_func`, since `$try` returns from the nearest `$func`), so it
     is lowered against the names it was written among however blocks nest. At a block's
     end, `with_defers` makes the block's value the first slot of an outer block whose
     second slot runs them — appending slots would change the layout, and §3.3's trailing
     effects fold *around* a block, so they would run before its slots. A `$try` carries
     every pending deferral in a new `pre` list on its IR node, which emit runs inside the
     branch that returns.
   - `stage1/fixtures/defer.mpl` (132456876798, each step a digit, so the answer is the
     order), in both stages and the differential set.

   **It found an older `$try` bug.** A `$try` returning a member nothing else in the program
   interns — a file whose only `none` is the one `$try` returns — made emit's lookup miss,
   and its fallback injected type 0 instead: a warning, and C returning an uninitialised
   result, which `-Werror` refuses. Lowering now interns the member and a miss is an emit
   error. `stage1/fixtures/try_member.mpl` (3); the committed compiler fails it.
3. **Owners**, in the checker, with the measured migration, and **`$new` blocks'
   deferrals**.
4. **The allocator members and `$free`**, with routing and parameter summaries; `std/mem`
   updated; the root's `defer_at` if decided.
5. **`std/allocator`**: the capability traits, and whatever allocator-generic code D5's
   `_in` variants turn out to need.

Fixtures at each step, in both stages where stage 0 can run them, and under ASan; the
examples above are the first set.

## Open questions

1. **The root's `defer_at`.** A side table keyed by address lets `$alloc { … $defer … }` work
   in libraries and at the top level, where a resource constructor allocates from the root.
   The alternative is that only library allocators take deferral blocks. Leaning: the side
   table.
2. **`grow` and alignment** in the allocator interface: `std/vec` would use `grow`
   instead of allocating and copying, and alignment above 16 waits for a program that needs
   it.
3. **Example 7's boundary**: with nested calls, the place dies where its flow stops. If the
   flow passes through a call whose summary is unknown — a call through a function value —
   it must be assumed to stop there or to continue; stopping is the safe direction for the
   alias rule and the early one for deferrals.
4. **The `$defer` misuse warning**: a deferral that runs at its own block's end while that
   block's value is used afterwards is almost always a constructor written as a value. A
   warning, not an error, since it is well defined.
