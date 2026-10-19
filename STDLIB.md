# The standard library: design note

Status: **draft for decision.** Nothing here is implemented.

SPEC §8 draws the line: the root block holds what the language cannot express — intrinsics
and the platform's door — and "everything else — `not`, `and`, `or`, `max`, lists, maps,
formatting — is library code". §11 lists the library as deferred. This note says what it
should contain, what has to change in the compiler before it can be written well, and asks
for the decisions that shape it.

| | question | recommended |
|---|---|---|
| P | which compiler gaps come first | application inference and `$func`-bodied templates, polymorphic arrays, an import search root; bounds with `map` |
| D1 | where it lives and how it is named | a `std/` directory, `$import "std/list"` |
| D2 | its relation to `stage1/prelude.mpl` | separate: the prelude stays the compiler's subset library |
| D3 | how generic code says what it needs of `T` | bounds for structure, trait objects for runtime behaviour |
| D3a | containers that differ by element type | an `$overload` of templates over a shared base, derived with a new `$override` |
| D4 | equality and formatting of blocks | a trait, written per type, generated at build time later |
| D5 | which allocator containers draw from | the root's; an `_in` variant only when measured to matter |
| D6 | how strings are built | a builder, joined pairwise |
| D7 | how failure is reported | `option` and `result` shapes `$try` already matches |
| D8 | how it is tested | compiled-only, through §9's test interface |

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

- **P1. Application inference (§4.9), which stage 1 does not implement.** Without it every
  generic call is `$call ($specialize L.map Int Str) (xs, f)`, and a library of generic
  functions is unusable in practice. §4.9 specifies it narrowly — one level of parameter
  default shapes, first match wins, nothing deeper — which keeps it implementable. *Required.*
- **P2. Template bounds (§4.9), which the parser refuses.** `$template (K ($traitsof ord))`
  is how `map` says its keys compare and how `eq` and `show` are reached generically. A call
  through a generic already resolves statically to the argument type's member once the
  template is specialised, so the bound is a check, not a new mechanism. Without it `map` and
  `sort` still work — §4.9 types the body after substitution — but a missing member is
  reported inside `std/`, not at the caller. *Wanted before `map` and `sort` ship; not
  blocking.*
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
- **P9. Lowering a template whose body is a `$func`.** Inference accepts `$decl max
  $template T $func (…) …`; lowering refuses its `$specialize` — "this template's body is not
  a block with props or $decls, which is the only shape lowered so far". The block form
  (`$template T { $prop max $func (…) … }`, reached as `($specialize m Int).max`) works today,
  so the library can be written that way meanwhile, but §4.9's application inference (P1) is
  defined for exactly the `$func` form. *Required with P1.*
- **P3. Arrays of any type.** The root's `array`, `at` and `alen` are monomorphic at `Str`
  (BOOTSTRAP §2 kept them so for stage 0), so a vector, a hash map, sorting `Int`s or a byte
  buffer cannot be written. §8 already gives the polymorphic form — `$call array (n,
  example)` — and `unbox` shows how a polymorphic intrinsic is typed (a marker binding,
  typed at the call). *Required.*
- **P4. A search root for `$import`.** `$import` resolves relative to the importing file
  only, so there is nowhere for `std/` to be found from. §4.14 says "the build program
  supplies the resolver (search roots and an explicit name→file map)". The smallest version:
  `mplc` tries the importing file's directory, then a library root (`-L <dir>`, defaulting to
  the `std/` beside the compiler). Stage 0 needs the same rule for its tests. *Required.*
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
  D3a.*
- **P8. `$override`** (D3a): a §2.2 row of arity 2, a §4.12-style section, and support in both
  passes, on a value and on a template. Stage 0 needs it only if a stage-0 test uses it, and
  the library's tests are compiled-only (P5). *Required by D3a.*

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
| `std/fmt` | formatting `Int`, `Float`, `Str` and anything with a `show` member into a builder | P2 |
| `std/io` | `print_line`, reading and writing whole files and lines, over the platform group | — |
| `std/vec` | a growable vector over `array` | P3 |
| `std/map` | an ordered map (a balanced tree, keys bounded by `ord`) | P2 |
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
  themselves. Not for `eq` or `lt`: §6's object safety refuses a member that mentions `Self`
  through a trait object, and the current compiler does — "member 'eq' mentions Self, so it is
  not callable through a trait object (§6)". `show` is object-safe, so it works both ways.

**Not chosen: overloading the operation.** Making `std/core`'s `eq` an `$overload` of the
primitive equalities with a bounded template as its last candidate looks like one `find` for
every element type, and has two flaws. An overload's type is its whole ordered candidate set
(§4.8), so wherever it is held as a value — a trait member, a field, a parameter default, a
`$set` — everything meeting it must have the same combination: equality becomes one fixed
bundle every type shares, not something each type carries. And §6's extension is lexical, so a
user's `$decl eq $overload (eq_mine, C.eq)` is never seen by `std/list`'s `find`, which names
`C.eq` where it is written. A member travels with its type; an overload does not.

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
  member is never typed at an argument it was not written for.

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
  type itself, which `$traitsof` abstracts to `Self`. `std/core` gives the prototypes the
  bounds are made from (`eq_proto`, `show_proto`, `ord_proto`). Needs P6.
- **A member named after an intrinsic shadows it inside the type**, because a prop is
  visible throughout its block: `eq`'s body calling `eq` on a field calls itself. The idiom
  is the one stage 1 already uses for `isub` — `$decl ieq eq` above the type.
- **`show` writes into a builder** (`$prop show $func ($decl b S.builder) …`) rather than
  returning a `Str`: a nested record rendering its children by `concat` is D6's O(n²) trap.
  The builder is not `Self`, so `show` stays object-safe.
- **Primitives** have no props; D3a is how a container over them gets the same interface.
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

## D6. Building strings

`concat` copies both operands, so building a string by appending is O(n²) — CLAUDE.md's
"never build a string by appending to an accumulator", learned from `emit.mpl`'s `say`. The
library's answer is a **builder**: chunks collected newest-first and joined by folding adjacent
pairs, O(L log n), which is exactly what the emitter does. `std/fmt` writes into one, and
`S.build` turns it into a `Str`. With P3, a builder over a growable byte array is better still
and is the second version.

§3.1 makes a `Str` UTF-8 and its operations byte-indexed; code-point iteration is library
(§8), and `std/str` provides it, decoding as `from_code` encodes.

## D7. Reporting failure

§4.15 makes an expected failure a value and `$try` the only non-local exit. §8 says "the root
block defines `option` and `result` before any of these", but stage 1's root has only the
`none` and `err` shapes, so one of two things has to happen: the root gains the two names, or
`std/core` defines them. The root is recommended, because §8 puts them there so that the
platform group can answer them. Either way the shapes are:

- **`option`** is `none` or `{$prop tag "some" $decl v …}` — what `str_to_int` already answers.
- **`result`** is a value or `{$prop tag "err" $decl e …}`. A block with more fields is a
  subtype of a shorter one (§5.1), so `$try x err` still matches when the failure carries a
  payload — the caller decides whether to look at it.
- **Bugs panic** (§4.15): `nth` out of range, `unwrap` of `none`.

## D8. Testing

§9 makes a test any block conforming to `{$prop name ""  $prop run $func () true}`, and the
runner library code. `std/test` is that runner, and each `std/` module has a test file run by
`zig build test-std`: compiled by `mplc` and run, since stage 0 cannot run the library (P5),
and under ASan like `test-asan`.

## Plan

1. **P1 with P9, P3, P4** — application inference and the `$func`-bodied template it needs,
   polymorphic arrays, the import search root. (P6 is done.)
2. **`std/core`, `std/list`, `std/io`, `std/mem`, `std/test`** — what needs only P1. `test-std`
   with them.
3. **`std/str`** with the builder, and **`std/vec`** over P3.
4. **P2, bounds**, then **`std/fmt`**, **`std/map`**, and `sort`.
5. **P7, P8**, then the per-element-type candidates of D3a where a representation earns one.
6. **Docs** — SPEC §8 points to `std/`, §11 drops the library, and BOOTSTRAP notes the arrays
   generalised beyond its §2; SPEC gains §4.8's template resolution and `$override`.

## Decisions requested

| | options | recommended |
|---|---|---|
| P | which prerequisites, and in which order | P1 with P9, P3, P4 first (P6 done); P2 before `map` |
| D1 | location and naming | `std/`, module-qualified |
| D2 | prelude and `std/` | separate |
| D3 | generic requirements | bounds; a passed function for `_by`; trait objects for heterogeneous behaviour; not an overloaded operation |
| D3a | per-element-type containers | `$overload` of templates (P7); candidates derived by `$override` (P8): replace-only, subtype-checked, static binding, applicable to a template |
| D4 | `eq` and `show` on blocks | a member per type; build-time generation later; not an intrinsic |
| D5 | container allocators | the root's; `_in` variants on measured need |
| D6 | strings | a builder |
| D7 | failure | `option` and `result` in the root, as §8 says; shapes `$try` matches |
| D8 | tests | compiled-only, `test-std`, under ASan |
