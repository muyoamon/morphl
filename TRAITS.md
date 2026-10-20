# Traits without `Self`: design note

Status: **steps 1–3 done** — `Self` is gone, every member of a trait object is callable,
and a trait naming itself is tied by §5.5. Bounds in the `$decl` syntax (step 4) remain.

§6 builds a trait "over a distinguished type `Self`", and `$traitsof` makes one by abstracting
every occurrence of the value's own type into it. This note removes `Self`. A trait is its
members' signatures **as written**. "Another value of my own type" becomes an ordinary
generic of the prototype, used through §4.9's F-bound, and "any conforming value" stays
`$traitsof proto`. The object-safety rule then has nothing left to forbid, and goes too.

## Why

morphl's promise about a trait is that **every implementation of it is interchangeable**: a
trait object erases the concrete type, so its table must work whoever implemented it. A
member whose signature mentions `Self` breaks that. `pt.eq : (pt) -> Bool` and
`q.eq : (q) -> Bool` are two shapes, and no call site can be typed against both. The
object-safety rule ("a member is callable through a trait object only when `Self` appears
in neither its parameters nor its result", §6) exists only to hide that, and the current
compiler enforces it at every projection off an object, at any depth (`infer.mpl`'s
`proj_one`, `T.mentions_bnd`).

So `Self` in a trait is not a feature with a restriction; a trait whose shape depends on
its implementation is not a shape. And `$traitsof` cannot tell the two meanings apart in
the first place. It rewrites the declaring name into `Self` structurally (§10 item 10),
whether the author meant "this concrete type" or "my own type, whoever I am".

What `Self` did soundly was the *bound* case: specialised at one concrete type, "`T`'s `lt`
takes another `T`" is checkable, and it is what makes binary methods (`eq`, `lt`, `merge`)
possible. §4.9 already has the explicit form of that — the F-bound,
`$template (K ($specialize ordered K))` — so nothing is lost.

## The design

1. **A trait is its props' signatures exactly as written.** `$traitsof e` takes the name,
   type and receiver qualifier of each of `e`'s props and abstracts nothing. A parameter
   defaulted to `pt` is `pt` in the trait.
2. **Conformance is member subtyping.** `T` conforms when each member the trait describes
   is a prop of `T` whose type is a subtype of the member's — no instantiation step.
3. **Every member of a trait object is callable.** There is no object-safety rule: the
   shape no longer varies by implementation.
4. **Same-type relations are explicit generics**, through an F-bound:

   ```
   $decl eq_proto $template T { $prop eq $func ($decl other T) C.bool }

   $decl pt { $decl x 0  $decl y 0
     $prop eq $func ($decl other pt)
       $call C.and ($call ieq (pt.x, other.x), $call ieq (pt.y, other.y)) }

   $decl same_as $template ($decl T ($specialize eq_proto T))
     $func ($decl a T, $decl b T) $call a.eq (b)

   $call same_as (p, q)    // T = pt: pt conforms to eq_proto pt; a.eq is pt's own, direct
   ```

   `pt` conforms to `eq_proto pt`, not to `eq_proto Int`.
5. **"Any conforming value" is the trait object type**, as a parameter or result:

   ```
   $decl shape_proto { $prop area $func () 0
                       $prop bigger $func ($decl o $traitsof shape_proto) C.bool }
   ```

   `bigger` takes another implementation and reaches it through its members only. Writing
   `$traitsof s` inside `s`'s own block is the same thing, and is the mitigation for a
   block that wants to take "another one of me" dynamically:
   `$prop same $func ($decl o $traitsof s) …`.
6. **Generic parameters are written like `$func` parameters.** `$decl` binds a generic with
   its bound; a bare name is unbounded.

   ```
   $template T                                          // unbounded, as today
   $template ($decl K ($specialize ord_proto K))        // bounded, F-bounded here
   $template (T, $decl S ($specialize seq_of (S, T)))   // a plain one and a bounded one
   ```

   The bound plays the role of a parameter default: an example that fixes a type (§3.4),
   in a type-only position (§5.7), so it may name the generic being declared and any before
   it. It differs from a `$func` parameter list in one respect: a bare name is accepted, and
   means unbounded. §4.9's application inference is unchanged.
7. **A trait that mentions itself is tied by §5.5.** `rest () -> $traitsof seq_proto`, or
   `$traitsof s` inside `s`'s own default, names a trait while it is being made. The
   self-reference takes a placeholder, the members are typed against it, and the result is
   the recursive trait `μ`, as recursive block types already are.

## Examples

**The same source, today and after:**

```
$decl s { $decl k 1  $prop same $func ($decl o s) true }
$decl o $traitsof s
```

| | `same`'s member type | `$call o.same (s)` |
|---|---|---|
| today | `(Self) -> true` | refused: "mentions Self" |
| after | `(s) -> true` | allowed; a type conforming to `$traitsof s` must accept an `s` |

**A trait object over a concrete type is sound:**

```
$decl eq_pt $traitsof ($specialize eq_proto pt)       // trait { eq : (pt) -> Bool }
$decl tagged { $decl p pt  $decl tag ""
  $prop eq $func ($decl other pt) $call tagged.p.eq (other) }
// pt and tagged both implement eq_pt, with the same shape: whoever implements it,
// the call site passes a pt.
```

**Iteration, both ways:**

```
// Static: the container is the generic, so `rest` keeps the concrete type.
$decl seq_of $template (S, T) {
  $prop first $func () $union (none, { $prop tag "some"  $decl v T })
  $prop rest  $func () S
}
$decl count $template (T, $decl S ($specialize seq_of (S, T)))
  $func ($decl xs S, $decl n 0) …

// Dynamic: `rest` answers the trait object type, a recursive trait (design point 7).
$decl seq $template T {
  $prop first $func () $union (none, { $prop tag "some"  $decl v T })
  $prop rest  $func () $traitsof ($specialize seq T)
}
```

**Composing a bound** (§6's "a combined trait is the trait of a prototype listing both
traits' props"):

```
$decl ord_proto $template T {
  $prop eq ($specialize eq_proto T).eq
  $prop lt $func ($decl other T) C.bool
}
$decl max $template ($decl T ($specialize ord_proto T)) $func ($decl a T, $decl b T) …
```

## What the current compiler does

Measured before writing this:

- **The rule fires only at projection off a trait object**, call or value, and checks the
  member's type at any depth: `$func () { $decl inner s }` and `$func () $union (none,
  {… v s})` are refused as well as a direct `(s)`. A trait may hold such members, objects of
  it may be made and passed, and its `Self`-free members are callable.
- **A member answering the trait object type already type-checks** —
  `rest () -> $traitsof seq_proto` — and so does `$traitsof s` in `s`'s own default in the
  simplest case. A richer case does not: when the self-referencing `$traitsof` is taken
  while `s`'s members are still being typed, the trait captures them as `⊥`
  (`trait{size:[]->!,…}`) and nothing conforms. That is design point 7, unimplemented.
- **Running the dynamic case found a miscompile, unrelated to this design.** A member with a
  read-only receiver, called through a trait object, is given a *copy* of the referent made
  in the shim's frame (`mpl_env e; e.c0 = *env;`), so `$traitsof a` in `a.rest` refers to
  storage that dies with the shim. ASan: stack-use-after-return; stage 0 answers 10, the
  compiled program 2. §4.10 makes the receiver a reference, so the backend's copy is the
  bug. **Fixed:** a receiver is captured as the target's own storage, member defaults see
  the block as inference's do, and a call to a closure literal is direct rather than
  through §6a's trampoline, which would have run it after the caller's frame was gone
  (`stage1/fixtures/recv_ref.mpl`).

## SPEC changes

- **§4.9, Bounds.** The generic-parameter syntax of design point 6. The F-bound is the way to
  say "another value of the bounded type". "A trait as a bound … is satisfied by conformance
  (§6), and needs no F-bound: a trait's `Self` is the bounded type" goes: a trait as a bound
  is conformance, and a same-type relation needs the F-bound.
- **§4.13, `$traitsof`.** "with every occurrence of `e`'s type in those types abstracted as
  `Self`. Substitution is structural…" goes: the trait is the props' signatures as written,
  the receiver not counted. A `$traitsof` that names the trait being made is tied by §5.5.
- **§6.** "over a distinguished type `Self`" goes. Conformance loses "with `T` for `Self`".
  "Another value a member takes" keeps both forms and says what each means: the declaring
  name is that concrete type, `$traitsof` is any implementation, and a same-type relation is
  a generic of the prototype. The object-safety bullet goes. "Bounds" loses "a member whose
  signature mentions `Self` is callable there".
- **§10 item 10** goes: nothing is abstracted.
- **§12.** `seg.longer`'s comment ("mentions `Self` once traited, so it is callable through a
  bound, not a trait object") becomes the F-bound form, or says that through
  `$traitsof seg` it takes a `seg`.

## Compiler changes

Mostly removal:

- **`types.mpl`:** `trait_members_of` stops remapping the value's type to the binder; the
  trait's binder exists only where §5.5 ties a self-referencing trait; `trait_member`'s
  `subst_bnd` instantiation goes; conformance (`members_sub`) compares member types
  directly.
- **`infer.mpl`:** `proj_one`'s `mentions_bnd` check goes. Generic parameters accept
  `$decl name bound` (`generic_names`), and specialisation checks a bound — which is P2, the
  bounds work `STDLIB.md` already lists, now with this syntax. A `$traitsof` naming the trait
  in progress takes a placeholder.
- **`lower.mpl`:** `ltrait_of` and `T.trait_of` follow `types.mpl`; generic parameters as in
  inference.
- **Stage 0:** `$template` accepts the `$decl` form (the bound is a type-only position, so
  stage 0 binds the name and ignores the bound, as it ignores every type).
- **Tests:** `infer_test`'s `tt03` (expects `trait{eq:[b0]->true,}`) and `tt05` (the
  object-safety refusal) change meaning; new cases for a bound, an F-bound, conformance
  failure, and a recursive trait.

## Migration

Small. No stage-1 module and no fixture has a member whose signature mentions its own
block's type — `traits.mpl`, `traits_util.mpl`, `tscalar*` and `std/test`'s
`{ $prop name ""  $prop run … }` are all `Self`-free. What changes meaning is a trait over a
block whose member takes the block itself: after this, it takes *that concrete type*, and a
program meaning "another implementation" writes `$traitsof` there.

## Plan

1. **Fix the shim's receiver copy** (above). **Done.**
2. **Drop `Self`**: `$traitsof` as written, conformance as member subtyping, the object-safety
   rule gone, `tt03`/`tt05` updated. Nothing in the compiler's own source changes. **Done**
   (`stage1/fixtures/trait_written.mpl`; `types_test`'s `trs05` now pins both directions).
3. **Self-referencing traits by §5.5** (design point 7), with the `size : [] -> !` case as its
   regression test. **Done** (`stage1/fixtures/self_trait.mpl`, `infer_test`'s `tt03c`–`tt03e`):
   - **By the block's name.** While a block with a receiver name is typed, `$traitsof` of the
     name is a placeholder; a projection off it reads the block's members so far; when the
     block is done the placeholder is closed into `μ. trait_of (block)` and substituted back
     into its props (`infer.mpl`'s `close_self`).
   - **Through a specialisation.** `$traitsof ($specialize seq T)` inside `seq` reaches the
     memo's in-progress placeholder; it answers a trait placeholder recorded against it, and
     `specialize_at` closes that the same way once the body is typed.
   - **A prototype's example of a trait-typed result is made from `$alloc`ed storage**:
     `$traitsof $alloc ($specialize seq T)`. `$traitsof` of a temporary is fresh frame storage
     (§4.13), which §5.3a keeps from escaping a function, and a template's body has no
     receiver to point at. The checker said so before this step too.
   - **`T.is_trait` sees through a μ**, and emit lays a μ around a trait out as `mpl_tobj` —
     including a member type nobody interned, which `fn_sig` used to emit as `int64_t`.
   - **Lowering still derives a self-referencing trait with ⊥ inside** (`bigger : [trait{…,
     bigger : !}]`): it builds a block's trait from its props lazily, and does not re-run
     §5.5. Every trait object is `mpl_tobj` and its table is laid out by member *name*, so
     the C is right; the imprecision is in the IR's types. Lowering taking `$traitsof` sites'
     types from inference, as it takes `ualloc`'s sites, would remove it.
4. **Bounds (P2) in this syntax**, F-bounds included — then `std/core`'s `eq_proto` and
   `ord_proto`, and `STDLIB.md`'s capability traits (`sized`, `seq`, `indexed`, `builder`)
   built on them.
5. **SPEC** §4.9, §4.13, §6, §10, §12 as above, landing with step 2. **Done**, except §4.9's
   generic-parameter syntax, which lands with step 4.

## Open questions

- **Several bounded generics at once, applied.** §4.9 never infers a bound's generic from a
  call — `count (xs)` above has `T` only inside `S`'s bound. Either application learns to
  read it from the bound once `S` is known, or such a template is always specialised
  explicitly.
- **Whether a trait object of `$specialize eq_proto pt` is worth a shorthand.** Writing it
  out is explicit; a common bound may want a name.
- **Composition beyond writing the props out.** Example 4 reuses a prop by projection, which
  §4.10 allows; whether a prototype should be able to *merge* two prototypes is left for
  when the capability traits show whether it is needed.
