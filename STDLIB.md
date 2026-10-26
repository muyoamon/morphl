# The standard library: design note

Status: **draft for decision.** Nothing here is implemented.

SPEC §8 draws the line: the root block holds what the language cannot express — intrinsics
and the platform's door — and "everything else — `not`, `and`, `or`, `max`, lists, maps,
formatting — is library code". §11 lists the library as deferred. This note says what it
should contain, what has to change in the compiler before it can be written well, and asks
for the decisions that shape it.

| | question | recommended |
|---|---|---|
| P | which compiler gaps come first | bounds (P2) with `map`; P7 and P8 for D3a |
| D1 | where it lives and how it is named | a `std/` directory, `$import "std/list"` |
| D2 | its relation to `stage1/prelude.mpl` | separate: the prelude stays the compiler's subset library |
| D3 | how generic code says what it needs of `T` | bounds for structure, trait objects for runtime behaviour |
| D3a | containers that differ by element type | an `$overload` of templates over a shared base, derived with a new `$override` |
| D4 | equality and formatting of blocks | a trait, written per type, generated at build time later |
| D5 | which allocator containers draw from | the root's; an `_in` variant only when measured to matter |
| D6 | how strings are built | a builder, joined pairwise |
| D7 | how failure is reported | `option` and `result` shapes `$try` already matches |
| D8 | how it is tested | compiled-only, through §9's test interface |
| D9 | how containers compose | values carrying their methods; type-changing operations as `std/seq` algorithms over capabilities |

## What exists

**The root block** (§8, BOOTSTRAP §2): `Int` and `Float` arithmetic as overloads, wrapping,
saturating and bitwise forms, `eq`, `to_int`/`to_str`/`to_float`, the `Str` primitives
(`concat len slice byte from_code`), arrays (`array at alen`), the platform (`print eprint
read_file write_file args run`), the FFI group (`str_ptr str_from_ptr array_ptr box_ptr
unbox raw_alloc raw_free`), `allocator`, `panic`, and the `err`/`none` shapes.

**`stage1/prelude.mpl`**, 116 lines inside BOOTSTRAP §1's subset: `boolean`, `not`, `and`,
`or`, the value readers `ival`/`sval`/`bval`, a `list` template with `cons`, `length`,
`reverse`, `nth` and `is_nil`, and the compiler's span and path helpers. It exists because
stage 0 must run the compiler, and it is everything the compiler needed — no `map`, no
`filter`, no string utilities beyond the primitives.

## What has to change first (P)

Measured on the current compiler:

```
$decl id $template T $func ($decl x T) x
$decl a  $call id (5)
    → "$call on a template needs an explicit $specialize first (BOOTSTRAP.md §1.1)"

$decl area_of $template (T ($traitsof shape)) $func ($decl x T) $call x.area ()
    → "$template generic parameters must be plain names"
```

- **P1. Application inference (§4.9).** **Done.** `$call t args` on a template whose body
  is a `$func` infers each generic from the parameter defaults' shapes (`Pa.app_sources`,
  shared by both passes), specialises through the explicit path — so the two share a memo
  entry and their functions — and checks the call against the result. An inferred generic
  has a type and no value, so reading one as a value (a defaulted argument, or `T` in the
  body) is reported. Stage 0 still refuses it: BOOTSTRAP §1.1 keeps it out of the subset,
  so the library's tests are compiled-only anyway (P5). `stage1/fixtures/apply.mpl`.
- **P2. Template bounds (§4.9).** **Done** (TRAITS.md, step 4): `$template ($decl K bound)`,
  checked at every specialisation; a bound is a trait to mean conformance, and an F-bound —
  `$decl K $traitsof ($specialize ord_proto K)` — says "another value of my own type".
- **P6. A member cannot take another value of its own type — a checker bug.** §4.10: "In a
  type-only position the declaring name is the block's complete type, so a member takes
  another value of its own type as `$prop same_w $func ($decl other rect) …`". Stage 1 types
  that default as the *receiver*, `&const rect`, so every call is refused:

  ```
  $decl pt { $decl x 3  $prop eq $func ($decl other pt) $call ieq (pt.x, other.x) }
  $decl p2 pt   $call pt.eq (p2)
      → "argument 1 is mu.{x:Int,eq=…}, expected &const {x:Int,eq=…}"
  ```

  Direct and through a specialised template alike. It blocks every `eq`, `compare` and `ord`
  in D4, so it comes first. **Fixed:** a member's parameter defaults are typed with the
  declaring name bound to the block, its body with it bound to the receiver
  (`stage1/fixtures/self_param.mpl`, 4111).
- **P9. Lowering a template whose body is a `$func`.** **Done**, as the block
  `{ $prop $fn <body> }` with the function read back off it — so it is lifted once per
  memo key and named and placed like `P.list`'s members.
- **P10. A local recursive `$func`.** **Done.** Inside its own body the name a block's
  `$decl` gives a `$func` is the closure over itself — its own index and captures, lowered
  twice as a self-naming prop is — so a tail call to it is a loop and a call elsewhere reuses
  its environment. Writing the test found a second bug: lowering's own `free_names` lacked
  `$alloc`'s implicit read of `allocator`, so a closure allocating from a local arena
  captured nothing and read the enclosing frame's slot from its own. A literal nested in the
  body does not see the name yet. `stage1/fixtures/local_rec*.mpl`.
- **P3. Arrays of any type.** **Done.** `array`, `at`, `alen` and `array_ptr` are bound at
  markers and each call is typed from its arguments (`infer_ffi`, `lower_ffi`), as `box_ptr`
  and `unbox` are; an array's elements are held to A0. The backend and stage 0 never
  assumed `Str` and needed nothing. `args` and `run` stay `[Str]`.
  `stage1/fixtures/arrays_any.mpl`, in both stages.
- **P4. A search root for `$import`.** **Done.** A name resolves against the entry file's
  directory, as before, then against each library root in order (`Pa.resolve_import`,
  shared by both passes, since the resolved path is a module's identity). `mplc` takes any
  number of `-L <dir>` after the file; `C.parse` takes the list. There is **no default
  root**: a compiled `mplc` cannot find its own location, since §8's `args` drops the
  program name — so `test-std` passes `-L .`, and `std/` modules import one another as
  `"std/core"`. Stage 0's loader has no roots, which costs nothing while the library is
  compiled-only (P5). `stage1/fixtures/libroot.mpl`, in `test-link`.
- **P5. Stage 0 cannot run it.** The library will use `Float`, overloads, the FFI and
  allocators, all outside BOOTSTRAP §1's subset. So its tests are compiled-only, like
  `arena.mpl`'s — which costs the stage-0/compiled differential for library code. Accepted,
  not fixed.

- **P7. Resolving an overload of templates.** §4.8 defines resolution for `$call`, by
  parameter types, and nothing says what `$specialize list Int` means when `list` is an
  overload of templates. The rule mirrors §4.8: **the first candidate whose bounds accept the
  arguments**, the bound standing where a parameter type stands, and §4.8's lint carries over
  (a candidate whose bounds are covered by an earlier one's is unreachable). Application
  inference (P1) applies it per candidate. A SPEC addition to §4.8 and §4.9. *Required by
  D3a.* **Done**, in SPEC §4.8 and §4.9 and in stage 1. Inference chooses: it asks each
  template's bounds quietly (a candidate that does not fit is not an error), and for `$call`
  it infers the generics, asks the bounds, then whether the specialised `$func` takes the
  arguments. Lowering derives its types and has no bounds to check, so it does not choose
  again. Inference records the choice per site beside `ualloc`'s facts, keyed by
  specialisation context, file and span, so a site inside a template body chooses per
  instance. Lowering registers an overload with a template among its candidates as an
  `$over` template record listing the candidates, and follows the recorded path through
  nested overloads. `stage1/fixtures/overload_tmpl.mpl` (12341381821107105, compiled only:
  stage 0 has no types to check a bound against) and `overload_tmpl_none.mpl` in
  `test-reject`. Not done: §4.8's lint for a template candidate whose bounds an earlier
  one's cover. A choice inside an instance whose argument inference closes into a `μ` only
  through a prop's type (a list wrapper) was missed by lowering, whose key had no `mu.`:
  both passes key by `T.show_key` now (`overload_tmpl_mu.mpl`, 210), which surfaced with
  `std/seq`'s algorithms over primitives.
- **P8. `$override`** (D3a): a §2.2 row of arity 2, a §4.12-style section, and support in both
  passes, on a value and on a template. Stage 0 needs it only if a stage-0 test uses it, and
  the library's tests are compiled-only (P5). *Required by D3a.* **Done**, as SPEC §4.12a.
  On a value it is `$impl`'s shape with props replaced: each must exist, at a subtype, and
  the base's members keep calling the base's. On a template it splices: the override's
  props take the body's places, the body's other members reach them (open within the body,
  which is what keeps the replaced member from ever being typed), and the override's other
  names are renamed so they resolve where the `$override` is written, never in the base's
  body. So the template case has no subtype check, there being no replaced type to compare.
  Both passes make the same rewrite (`Pa.ov_body`), with the base's items moved a million
  lines down so nothing either pass keys by position can collide with the override's; a
  diagnostic on such a line, from either pass, is mapped back and names the base's file
  (`override_diag.mpl` in `test-reject`).
  `stage1/fixtures/override.mpl` (with D3a's overload in its module, compiled only, and in
  `test-split`) and `override_bad.mpl` in `test-reject`. Stage 0 refuses the form. Not
  done: overriding a template that `$override` made.

- **P11. A receiver member reached through a parameter's type, too early, is called bare.**
  **Done.** A function whose parameter is a block type with receiver members — a list
  wrapper (D9) — reaches them through the parameter's *type*, which is inference's. When
  that is lowered before the block literal the props come from, lowering deferred the miss
  (`prop_pending`), could not know the member names its receiver, built no closure, and
  emitted a call with a `NULL` environment: a segfault in the entry file, a `cc` type error
  in a module member. Found probing D9 (`total_len ($decl xs ($call strs.empty ()))`).
  §3.4 is the fix: a default builds a value of its parameter's type, so when the type
  carries a prop whose source is not registered yet (`src_unseen`), `bind_params` lowers
  the default (type-only) before the body, which registers the literal; no other parameter
  pays for it. A deferred read that still resolves
  to a receiver member is now a diagnostic rather than a crash (`resolve_one`).
  Generic functions were never affected — a generic is lowered at specialisation, after
  the literal. `stage1/fixtures/recv_param.mpl` (3294), in both stages.

- **P12. A wrapper's member taking another wrapper left every member unsolved — a checker
  bug.** **Done.** `append ($decl ys w)` — §4.10's "another value of its own type" — inside
  `of` made `$call ($call ints.empty ()).push (3)` unprojectable: `push` answered `v1`, `of`'s
  placeholder. A block built inside its own recursive constructor closes twice, first over
  itself (the default names it) and then over the constructor, whose placeholder its members'
  results still mention — and the second close asked `occurs_own_props`, which did not see
  through the first close's `μ`. Fixed there, and `close_rec` closing over a `μ` reuses its
  binder (`μx. μy. F(x, y)` is `μy. F(y, y)`) rather than nesting two. That uncovered a second
  half: `unroll`'s memo is keyed by `same`, which ignores a prop's type, so the settled `μ` was
  handed the mid-knot one's unrolling, placeholders and all. An unrolling still holding a
  placeholder anywhere is no longer stored (`occurs_all (t, -1)`). Neither half is about
  templates. `stage1/fixtures/wrap_self.mpl` (6205), in both stages.
- **P13. Joining the receiver with another value of its type loses the members.**
  `$prop me $func ($decl o w, $decl f true) $if f w o` checks, but `$call ($call x.me (x,
  true)).get ()` is refused — "cannot project '.get' from `&const {v:Int,get=…,me=…}`" —
  where stage 0 answers. Returning `w` alone is fine; so is building a new value through the
  constructor, which is what every `std/list` method does, so nothing here needs it. Probably
  the join of the receiver (`&const` of the block) with the default's type, which is the
  block's in-progress type (§4.10). Open.

- **P14. A member whose body bound a local named like a field was refused — a lowering
  bug.** **Done.** §4.10's "a member may not capture" is checked by asking which names its
  body reads from outside itself, and that used the closure walk (`free_names`), which
  counts a name the body rebinds — harmless for a closure's capture list, a wrong refusal
  here: `{ $decl n … }` inside a member of a block with field `n`. Found writing `std/vec`'s
  `insert_at`. Subtracting every name bound inside would hide a real capture made before a
  rebinding (`{ $decl a c  $decl c 5 … }`), so `no_caps` has a scope-aware walk of its own
  (`free_sc`): a block's props are bound throughout, a `$decl` after its initializer, a
  `$func`'s parameters in its body. `lower_test`'s `t35`/`t35b` pin both directions.

## D1. Location and naming

A top-level `std/` directory of ordinary modules, imported by name:

```
$decl L $import "std/list"
$decl S $import "std/str"
```

Proposed modules, in the order they can be written:

| module | contents | needs |
|---|---|---|
| `std/core` | `max`, `min`, `option` and `result` helpers (`some`, `ok`, `fail`, `or_else`, `map_opt`) | P1 |
| `std/list` | `list T` with `map`, `filter`, `fold`, `find`, `any`, `all`, `zip`, `append`, `take`, `drop`, `sort` | P1; P2 for `sort` |
| `std/str` | a builder, `join`, `split`, `find`, `starts_with`, `trim`, code-point iteration | P3 for the byte buffer |
| `std/fmt` | formatting `Int`, `Float`, `Str` and anything with a `show` member into a builder | done |
| `std/io` | `print_line`, reading and writing whole files and lines, over the platform group | — |
| `std/vec` | a growable vector over `array` | P3 |
| `std/map` | an ordered map (sorted vecs; keys ordered by a `less` given at `new`) | done |
| `std/mem` | an arena allocator over `raw_alloc`, as `arena.mpl` does | — |
| `std/test` | a runner for §9's test interface | — |

Names are reached through the module's binding (`L.map`, `S.split`), so nothing in `std/`
is global and nothing shadows a root name. A module is a block (§4.14), so this is the
language's own namespace mechanism, not a convention layered on it.

## D2. The prelude stays separate

`stage1/prelude.mpl` serves the compiler, which stage 0 must run, so it is fixed to
BOOTSTRAP §1's subset. `std/` is for programs the compiler compiles, and should use the
whole language. Merging them would either hold `std/` to the subset or stop stage 0 running
the compiler. They stay separate until the bootstrap is retired, which is not this work.
`std/list` will look like the prelude's `list` grown up; that duplication is deliberate.

## D3. How generic code says what it needs

The split is between **typing and structure**, which is compile-time and belongs to templates,
and **runtime behaviour**, which belongs to trait objects. A bound is checked once, at
specialisation, and the body is then specialised at the concrete type, so a call inside it is
static (§6, "Bounds"). A trait object carries its implementation and dispatches through it.

- **Templates with bounds** for what a type knows about itself — `eq`, `lt`, `hash`. Checked at
  specialisation, no cost at run time. Needs P2, and P1 to be usable.

  ```
  $decl ord_proto { $prop lt $func ($decl other ord_proto) false }
  $decl max $template (T ($traitsof ord_proto))
    $func ($decl a T, $decl b T) $if ($call a.lt (b)) b a
  ```

- **Passing the operation** where the caller's ordering is not the type's own — `sort_by`,
  `find_by`. An ordinary function argument, an indirect call per use.
- **Trait objects** for heterogeneous runtime behaviour: a list of things that can each show
  themselves. A trait has no `Self` (TRAITS.md), so every member of an object is callable;
  but a trait over a concrete type fixes the argument's type, so "compare me with another of
  my own type" for *any* type is the F-bound, not an object.

**Not chosen: overloading the operation.** Making `std/core`'s `eq` an `$overload` of the
primitive equalities with a bounded template as its last candidate looks like one `find` for
every element type, and has two flaws. An overload's type is its whole ordered candidate set
(§4.8), so wherever it is held as a value — a trait member, a field, a parameter default, a
`$set` — everything meeting it must have the same combination: equality becomes one fixed
bundle every type shares, not something each type carries. And §6's extension is lexical, so a
user's `$decl eq $overload (eq_mine, C.eq)` is never seen by `std/list`'s `find`, which names
`C.eq` where it is written. A member travels with its type; an overload does not.

**What was done instead, once P7 existed:** `std/core`'s `equal` and `less` are an
`$overload` of the primitives' §8 `eq`/`lt` with the member form as the last candidate,
and the algorithms are bounded by `eq_like`/`ord_like`, a `$union` of the prototype and the
primitive examples. Neither flaw above applies, because **extension is still by member**:
the overload is closed over the primitives, which cannot carry a member, and a user's type
joins by having `eq`/`lt`, not by being added to the overload. What remains of the first
flaw is that `C.less` held as a *value* is that bundle; pass `$func ($decl a k, $decl b k)
$call C.less (a, b)`, as `std/map`'s users already do.

## D3a. Containers that differ by element type

A container whose **structure** should depend on its element type — bytes kept as a `Str`, a
vector of `Bool` as a bitset, a list of primitives that compares without a member — is an
`$overload` of templates, resolved at compile time, specific candidates first:

```
$decl list $overload (
  $template (T Str) $specialize ($override base { $prop find … byte-wise … }) T,
  $template (T Int) …,
  base)
```

The candidates are not separate implementations. They share a base and differ only where it
matters, and their **trait behaviour is the same by construction**, because the one way to
derive a candidate from the base is `$override`, which can only replace.

**`$override x override`** — new, the mirror of `$impl` (§4.12):

| | `$impl x trait override` | `$override x override` |
|---|---|---|
| each prop in `override` | must be new; one `x` already has is an error (§4.1) | must be one `x` already has |
| checked against | the named trait | the type of the member it replaces: a subtype |
| layout | `x`'s | `x`'s |
| receiver | the `$decl` over the form | the same |

- **Conformance is preserved.** No member is lost and none changes shape beyond a subtype, so
  every trait `x` conforms to, the result conforms to.
- **Identity is not.** Props are part of the type and §5.1 compares them by value, so the
  result is a distinct type and not a subtype of `x`: code asking for `x` does not take it,
  code asking for a trait or bounded by one takes both. Replacing behaviour is when identity
  should be forgotten.
- **Binding is static.** A member of `x` that calls another keeps calling `x`'s, as `$impl`
  keeps `x`'s own members on their own receiver. Open recursion would re-type `x`'s members at
  the result, which is a specialisation; a member that should use a different `eq` is
  overridden itself, or the base takes the element as a generic.
- **It applies to a template**, giving a template with the same generics and the body's props
  replaced, checked when it is specialised. This is not a convenience: §4.9 types a body after
  substitution, so `$override ($specialize base Str) …` would type `base`'s own `find` at `Str`
  — and fail on `x.eq` — before replacing it. Overriding the template means the replaced
  member is never typed at an argument it was not written for. That forces two differences
  from the value case (SPEC §4.12a): inside the body binding is open, since a sibling naming
  the replaced member must reach the replacement or the original would be typed after all,
  and there is no subtype check, since the original's type at `Str` is exactly what is never
  computed. The override's own names resolve where it is written.

**Primitives** reach the same interface either way: a candidate overrides the members that
compare, or wraps its elements with `$impl`, which costs nothing — an `$impl` over a non-block
is laid out as its base and is still that base (measured: an `Int` wrapped with a `show`
member still answers `add` and conforms to `show_proto`). Code generic over `$specialize list
T` sees one interface whatever `T` is.

Needs P7 and P8, and P1, P2, P6 under them.

## D4. Equality and formatting of blocks

§8 says "structural equality on blocks is a trait", and §9 says there is no in-language
reflection. Together those mean library code cannot derive `eq` or `show` for an arbitrary
block — it cannot see the fields. So:

- **A type opts in with a member**: `$prop eq $func ($decl other pt) …` and `$prop show
  $func () …` — the receiver is implicit (§4.10) and the declaring name in a default is the
  type itself. `std/core` gives the prototypes the bounds are made from, as F-bounded
  templates (`eq_proto T`, `ord_proto T`), and `std/fmt` gives `show_proto` (TRAITS.md) —
  `std/fmt`, not `std/core`, because `show` names `std/str`'s builder and `std/str` imports
  `std/core`. Needs P6 and P2.
- **A member named after an intrinsic shadows it inside the type**, because a prop is
  visible throughout its block: `eq`'s body calling `eq` on a field calls itself. The idiom
  is the one stage 1 already uses for `isub` — `$decl ieq eq` above the type.
- **`show` writes into a builder** (`$prop show $func ($decl b S.builder) …`) rather than
  returning a `Str`: a nested record rendering its children by `concat` is D6's O(n²) trap.
  It takes no value of its own type, so a `show` object needs no F-bound.
- **Primitives** have no props. For equality and order, `std/core`'s `equal`/`less`
  overloads give them the same interface as a member would (above); D3a is for a
  container whose *representation* should differ.
- **`eq_proto` and `ord_proto` are in `std/core`**, as F-bounded prototypes (`ord_proto`
  reuses `eq_proto`'s `eq` by projection), with `equal`, `unequal`, `less`, `less_eq`,
  `greater`, `greater_eq`, `max_ord` and `min_ord` over them. A bound is written
  `$decl T $traitsof ($specialize C.ord_proto T)`. `Int` and `Str` have no props, so they
  conform to neither; `max`/`min` are their forms. **Since P7, the comparisons take them
  too:** `equal` and `less` are an `$overload` of `int_eq`, `float_eq`, `str_eq`, `bool_eq`
  (and the `_lt` forms, `Str` by bytes) with `member_eq`/`member_lt` last, and the rest
  are bounded by `C.eq_like T`/`C.ord_like T`, a `$union` of the prototype and the
  primitives — so `$call C.max_ord (3, 9)` and `$call Q.sort (ints)` work, and a type
  with neither is refused at the call by the bound.
- **`std/list` has the bounded forms beside the `_by` ones.** `contains` and `index_of` are
  members of `list T`, template-valued so `list Int` still types, their generic read off the
  value searched for. `sort`, `is_sorted`, `max_of` and `min_of` take no element, so §4.9's
  application has nothing to read a generic from; they live in `ord_list E`, specialised
  beside `list E` (`$decl ord $specialize L.ord_list p`), whose bound is checked there.
- **Writing them by hand** is the first version, and costs a few lines per type.
- **Generating them at build time** is §9's answer to reflection — "reflection lives in the
  compiler library at build time": a build program walks the AST and writes the members. That
  is later work, once a build program exists.
- **Not chosen:** extending the `eq` intrinsic to compare blocks field by field. It would be
  convenient, and §8 rules it out by saying structural equality on blocks is a trait.
  Equality on a type is the type's decision, not the compiler's, and §8's own `Float` caveat
  shows why: field-by-field `eq` is not reflexive on a block with a `Float` in it.

## D5. Which allocator containers draw from

§7.6 resolves `allocator` where `$alloc` is written, so a list's cells come from `std/list`'s
allocator — the root's — whatever the caller has bound. A container that should draw from a
caller's arena has to take the allocator as a template generic.

Recommended: **the root's, by default, everywhere**, and an `_in` variant (`list_in T A`) for a
container only when a measurement shows a program needs it. Adding the generic to every
container now would make every use name two generics, for a benefit no program has asked for
yet — and the compiler's own measurement (STORAGE.md, C) found per-phase arenas would not have
helped it.

**`std/mem`'s arena is the first allocator.** `$decl allocator $call M.arena (cap)` binds one;
its state is its own cells, reached through the receiver (§4.10), so a program may hold as
many as it likes. Lexical resolution means it serves the `$alloc`s written in that scope and
no others — a function written elsewhere still draws from its own scope's allocator, which is
exactly why a container wanting a caller's arena needs the allocator as a generic.

## D6. Building strings

`concat` copies both operands, so building a string by appending is O(n²) — CLAUDE.md's
"never build a string by appending to an accumulator", learned from `emit.mpl`'s `say`. The
library's answer is a **builder**: chunks collected newest-first and joined by folding adjacent
pairs, O(L log n), which is exactly what the emitter does. `std/fmt` writes into one, and
`S.build` turns it into a `Str`. With P3, a builder over a growable byte array is better still
and is the second version.

§3.1 makes a `Str` UTF-8 and its operations byte-indexed; code-point iteration is library
(§8), and `std/str` provides it, decoding as `from_code` encodes.

**Done** (the first version), with `std/str_test.mpl` (28):

- **`builder ()`**: `write`, `line`, `bytes` and `build`. `write` and `line` answer unit, so
  a `show` member ending in one conforms to `std/fmt`'s `show_proto`. The pieces sit newest first in the
  builder's own `$mut $alloc` cell (D9's mutation rule), and `build` joins them pairwise and
  keeps the result as the one piece, so building again is free and writing after it carries
  on. The members are not `add` and `len`: §4.10 makes a prop visible throughout its block,
  so either name would shadow the intrinsic the members' own bodies call.
- **`concat_all`, `join (xs, sep)`**, the same pairwise join over a `std/list` list.
  `std/io`'s `unlines` is `join` now, and its own copy of the joiner is gone.
- **`split (s, sep)`** answers a list, empty pieces kept (`"a,,b"` is three); an empty `sep`
  panics. **`find (s, p, from)`** answers a byte offset as an option; **`contains`,
  `starts_with`, `ends_with`**; **`trim`, `trim_start`, `trim_end`** over ASCII white space;
  **`repeat`** by doubling.
- **`codes (s, i)`** is the code points from byte `i` as a `seq_of` sequence — decoded as it is
  walked, nothing stored but the string and the offset — so `std/seq` counts, maps and
  collects them; `code_at` and `width` are the decoding.

The byte-buffer builder waits for `std/vec`.

## D7. Reporting failure

§4.15 makes an expected failure a value and `$try` the only non-local exit. §8 says "the root
block defines `option` and `result` before any of these", but stage 1's root has only the
`none` and `err` shapes. **`std/core` defines the rest, for now.** `option T` is generic, so in
the root it would be a template — and both root blocks (`infer.mpl`'s `root_env`, stage 0's
`builtins.zig`) bind names to plain types, which cannot hold one. That is new machinery in
both stages for something a module can say. So the root keeps `none` and `err`, `std/core`
builds `some`, `is_some`, `is_none`, `or_else`, `map_opt` and `fail` on them, and the platform
group goes on answering the shapes directly. The shapes are:

- **`option`** is `none` or `{$prop tag "some" $decl v …}` — what `str_to_int` already answers.
- **`result`** is a value or `{$prop tag "err" $decl e …}`. A block with more fields is a
  subtype of a shorter one (§5.1), so `$try x err` still matches when the failure carries a
  payload — the caller decides whether to look at it.
- **Bugs panic** (§4.15): `nth` out of range, `unwrap` of `none`.

## D8. Testing

§9 makes a test any block conforming to `{$prop name ""  $prop run $func () true}`, and the
runner library code. `std/test` is that runner, and each `std/` module has a test file run by
`zig build test-std`: compiled by `mplc` and run, since stage 0 cannot run the library (P5),
and under ASan like `test-asan`. **Done**, and three things came out of writing it:

- **`run` answers `C.bool`, not `true`.** §3.2 makes `true` a type of its own, so §9's
  prototype read literally describes a test that cannot fail. §9's text may want the same
  correction.
- **A scalar trait member needed a compiler fix.** `name` is a `Str` prop, and a trait
  object's table held only functions, so inference accepted `t.name` and `verify` refused
  the tree. A scalar member now gets a zero-argument function in the table and a read
  through the object calls it (`lower.mpl`'s `scalar_fn`; `stage1/fixtures/tscalar.mpl`).
- **Tests are handed over one at a time, not as a list.** A top-level block is storage of
  the outermost frame, and §5.3a keeps a trait object over frame storage out of `$alloc`ed
  storage such as a list's cells — the rule working as written. So `T.check (r, t)` takes
  each test, a `results` record tallies them, failures go to stderr as they happen, and
  `T.finish (r)` answers the count or panics. `T.expect (r, name, ok)` is the inline form.
  Discovery stays a build-time job (§9: "reflection lives in the compiler library at build
  time"), which a build program would do by writing the `check` calls.

## D9. Containers as values with capabilities

A list today is a bare union and its operations live on the specialised module:
`$call ints.length (xs, 0)`. A bare union has no props, so it conforms to no trait, and code
generic over "any sequence" cannot be written. D9 makes a container a **value that carries
its operations**, and the operations that change the element type **free algorithms** over
any value with the right capabilities (TRAITS.md's traits, as bounds).

**Probed before writing this** (all compiled, under ASan):

1. **A list value can carry members.** `ints.of (cells)` answers a block
   `{ $decl cells c … }` whose props reach the cells through the receiver (§4.10), so
   `$call xs.push (5)`, `xs.rest ()` and `xs.is_empty ()` work on any list value. Props have no
   layout, so the wrapper is the cells' own C struct — no indirection, no allocation.
2. **`rest` returns the same wrapper type**, by calling `of` again inside the template.
3. **A partial bound needs no element type.** `$decl S $traitsof ($specialize seq_s S)`, where
   `seq_s S` lists only `is_empty` and `rest`, is checked at each call and `S` is inferred from
   the argument. The body may still use `head` and `first`, which mention the element type,
   because §4.9 types it at the concrete `S`. This answers TRAITS.md's open question about a
   generic named only inside a bound: do not name it.
4. **A template-valued member cannot read its receiver.** `map` as a member records its body
   while the wrapper is being typed, when the receiver is still §5.5's placeholder, so
   `w.cells` has nothing to project from at specialisation. So a member that introduces a type
   is not a member.
5. **Free algorithms over any sequence work.** `fold (xs, acc, f)` and `map (xs, f)` infer `S`
   from `xs` and the rest from `f`; `map` builds a `std/list` list of the result type.
6. **P11** (above): a non-generic function taking a wrapper parameter could crash. Fixed.

### The design

- **A list value is a wrapper.** `ints.of (cells)`, `ints.empty ()` and `ints.from_array (a)`
  make one; `ints.node` stays the cells' type, and `xs.cells` reaches them for code that wants
  to `$match`. **Done**, with `ints.cell` holding the same operations over bare cells, which
  the methods are written in and `std/io`'s joiner uses. `std/io` moved with it, since its API
  hands lists out and its `unlines` used `map`.
- **Its methods are the operations that keep the element type and need no generic:**
  `is_empty`, `head` (panics when empty — a bug, §4.15, like `nth`), `first` (an option),
  `rest`, `push`, `length`, `reverse`, `append`, `nth`, `take`, `drop`, `filter`, `any`, `all`,
  `find`, `sort_by`.
- **`std/seq` holds the capabilities and the free algorithms.**
  - Capabilities, each the members that do not mention the element type (point 3):
    `seq_of S { is_empty, rest }`, `sized { length }`, `indexed_of E { length, get }`. A
    capability's generics are exactly the types its members mention: `rest` answers the
    sequence, so `seq_of` is over `S`; `length` mentions nothing, so `sized` is a plain trait;
    `get` answers the element, so `indexed_of` is over `E`. An algorithm bounded by
    `indexed_of E` needs an argument that names `E`, since inference never reads a generic
    out of a bound — `search (xs, x)` has `x`. A vec conforms; a list does not (its `nth` is
    O(n), and "indexed" promises better).
  - Algorithms over any conforming `S`: `count`, `fold`, `map` (to a list), `for_each`, `any`,
    `all`, `find`, `to_list`; bounded by the element's order or equality: `contains`,
    `index_of` (`eq_like`), `sort`, `max_of`, `min_of`, `is_sorted` (`ord_like`). These
    replace `ord_list E` and the template members `contains`/`index_of`, which point 4 rules
    out as methods anyway.
  - **Done**, with `std/seq_test.mpl` (29), which runs them over a list and over a sequence
    that is not one (a countdown block). Three things the design did not say:
    - **The element type is never the algorithm's generic**, since nothing names it. Where it
      must be named, a helper takes one element as an example and reads `E` off it
      (`sorted_go`, `max_go`, `sort_as`), behind an emptiness check, as `head` panics. That
      is also where the bounds sit, so a refusal points at the helper's call inside
      `std/seq.mpl`, not at the caller's line. Since P7 an `Int`, `Float`, `Str` or `Bool`
      element is not refused: `eq_like`/`ord_like` admit the primitives, and `C.equal`/
      `C.less` pick their §8 `eq`/`lt` per instance (`seq_test`'s c30–c36).
    - **`to_list (xs, into)` takes a list to collect after**, because the result's element
      type has to come from somewhere: `$call Q.to_list (xs, $call ints.empty ())`.
    - **`search_by (xs, x, less)` and `search (xs, x)`** are binary search over `indexed_of`,
      answering the first position of `x` — the leftmost element not less than it — as an
      option. Added with `std/vec`, and the reason `indexed_of` exists. **`xs` must be
      sorted by `less`, and nothing checks it.** No trait can say "sorted": it is a fact
      about the values, not the shape, and a marker prop (`$prop sorted true`) would be a
      claim anyone can write, not a proof. Checking costs the O(n) the search avoids. What
      unsorted input gives was measured rather than assumed: a `some i` is compared with
      element `i` both ways, so it is never wrong; what is lost is completeness — over a
      scrambled 0 .. 999, 4 of the 1000 present values were found. The guarantee comes
      from a container that keeps its order by construction: `std/vec`'s `sorted_vec`.
    - **`sort` needs a `sort_by` member**, which a `std/list` list has. A capability cannot
      say so (`sort_by` mentions the element type), so it is checked when the body is typed.
- **A parameter typed "a list of T"** has an empty one as its default:
  `$decl xs ($call ints.empty ())`. A prop cannot hold it (§4.10: a call is not constant),
  so there is no `ints.t`. Needed P11, now fixed.

### Mutation

**A member cannot assign a plain field of its receiver**, even a mutable one: §4.4, "`$set`
writes *through* storage … never replaces a block field: `$set x.a 1` works if field `a` holds
storage (`$decl a $new 0`), and is an error if `a` is a value field". Checked: `$set c.n …` on
a `$mut` receiver is refused by both stages ("`$set` needs storage on the left, found Int"),
and a field holding a `$mut` cell is written through it, directly and through a trait object.
So a list stays a value — `push` answers a new list — and a container that changes in place
(`std/vec`'s growable buffer, a builder) holds its state in `$mut $alloc` cells, as
`std/mem`'s arena does.

### Decisions

| | decided |
|---|---|
| D9a | replace the module-style API |
| D9b | `std/seq` its own module |
| D9c | `is_empty`/`head`/`rest` for algorithms; `first` as the option form for callers |
| D9d | P11 first, then the list, then `std/seq`, then `std/io` migrated |

## Plan

1. P1, P3, P4, P6 and P9 are done, so nothing blocks the first modules.
2. **`std/core`, `std/list`, `std/test`, `std/io`, `std/mem`** — done, with
   `zig build test-std`.
3. **`std/str`** with the builder, and **`std/vec`** over P3 — both done.
   `std/vec`: `$specialize V.vec <example>`, then `new (cap)`, `push`
   (doubling, so amortised O(1)), `get`, `set`, `pop` (an option), `clear`, `length`,
   `capacity`, `is_empty`, `to_list`, and `items`, a `seq_of` view from the front. The array
   and the count are `$mut $alloc` cells, so every copy of a vec is the same vec — the only
   container here that changes in place. Two things the language decided: `at` answers a
   reference, which a function's result keeps (§5.4), so `get` reads through `val`, an
   identity at `T`; and a member may not capture (§4.10), so `items`'s view holds the vec as
   a field rather than closing over it. **`sorted_vec`** (`$specialize V.sorted_vec <example>`,
   then `new (less, cap)`) wraps a vec and keeps `less`'s order by construction: `insert`
   goes after equal elements, so they keep their arrival order; `remove` takes the first
   equal one out; there is no `set` and no `push`. Its `search` therefore needs no
   precondition — the same scrambled 0 .. 999 inserted, all 1000 are found — and it is an
   `indexed_of` too, so `std/seq`'s `search` works on it. `insert`/`remove` are O(n), and
   `search`, `get`, `min` and `max` O(log n) or better. `std/vec_test.mpl` is 26 now. A byte-buffer builder for `std/str` would need
   `str_from_ptr` over `array_ptr` (§4.16) to turn bytes into a `Str`; the pairwise join is
   O(L log n) already, so it waits for a measurement.
4. **P2, bounds**, then **`std/fmt`**, **`std/map`**, and `sort`. **`std/fmt` is done**
   (`std/fmt_test.mpl`, 19): every writer takes a builder first and answers unit — `int`,
   `float` (§8's shortest round-trip `to_str`), `str`, `bool`, `code` (U+FFFD for what
   `from_code` refuses), and `put`, an `$overload` of the four; `radix (b, n, base)` and `hex`,
   correct at both ends of `Int`; `pad_left`/`pad_right` in code points and `zeros` with the
   sign before them; `quoted`, a morphl string literal that reads back as its text; and
   `sep_by (b, xs, sep, f)` over any `std/seq` sequence. A block opts in with `$prop show $func
   ($decl b F.builder) …`; `show (b, x)` and `render (x)` are templates bounded by
   `show_proto`, so the call is static and `x` a value — taking a `showable` object instead
   refuses a field (a trait object refers to its value) and refuses a tail call, which a
   nested `show` ends in. `showable` is there for heterogeneous values. Not yet: a fixed
   number of decimals for a `Float`, which wants correct decimal rounding rather than
   scaling by a power of ten. `sort` is `std/seq`'s, and
   **`std/map` is done** (`std/map_test.mpl`, 16): `$specialize M.map (<key>, <value>)`, then
   `new (less)`; `put` (whether the key is new), `get` (an option), `get_or`, `has`,
   `remove`, `length`, `is_empty`, `key_at`/`value_at` by position, `min_key`/`max_key`,
   `keys`/`values` as `std/seq` sequences in key order, and `clear`. The keys sit sorted in
   one vec and the values beside them in another — `sorted_vec`'s idea, so a lookup is a
   binary search with no precondition, and two keys are one when neither is less. Not the
   balanced tree this table first named: `put`/`remove` are O(n), right for a map built
   once and read often, and a tree is the version for one that is not. It needed three
   general pieces, each in its own module: `vec`'s `insert_at`/`remove_at` (which
   `sorted_vec` now uses too), `std/seq`'s `lower_bound_by`, and `std/str`'s `compare`/
   `less`, since the root block orders numbers only. Keys ordered by their own `lt` pass
   `$func ($decl a k, $decl b k) $call C.less (a, b)`.
5. **P7, P8**, then the per-element-type candidates of D3a where a representation earns one.
6. **Docs** — SPEC §8 points to `std/`, §11 drops the library, and BOOTSTRAP notes the arrays
   generalised beyond its §2; SPEC gains §4.8's template resolution and `$override`.

## Decisions requested

| | options | recommended |
|---|---|---|
| P | which prerequisites, and in which order | P1, P3, P4, P6, P9 done; P2 before `map` |
| D1 | location and naming | `std/`, module-qualified |
| D2 | prelude and `std/` | separate |
| D3 | generic requirements | bounds; a passed function for `_by`; trait objects for heterogeneous behaviour; not an overloaded operation |
| D3a | per-element-type containers | `$overload` of templates (P7); candidates derived by `$override` (P8): replace-only, subtype-checked on a value, static binding on a value, spliced into a template's body |
| D4 | `eq` and `show` on blocks | a member per type; build-time generation later; not an intrinsic |
| D5 | container allocators | the root's; `_in` variants on measured need |
| D6 | strings | a builder |
| D7 | failure | `option` and `result` in the root, as §8 says; shapes `$try` matches |
| D8 | tests | compiled-only, `test-std`, under ASan |
| D9 | containers | decided: replace the API, `std/seq` its own module, P11 first |
