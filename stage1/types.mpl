// Stage 1's type language — BOOTSTRAP.md stage 1, step 3 (part one).
//
// This file is the *representation* and the *relations*: what a type is, its
// canonical form, subtyping (§5.1), and the lattice operations of §3.6. The
// inference traversal that computes a type for every expression is the next
// step and lives on top of this.
//
// Types are prop-tagged blocks, like the AST. The rules that shape the design:
//
//   * **Order matters for equality, not for subtyping** (§5.1). A block's
//     `$decl` fields are its layout (§7.2) so their order is part of type
//     identity; props have no layout, so their order is not. Canonical form
//     therefore keeps fields in order and sorts props.
//   * **A prop's value is part of the type** (§4.10) — the only place a value
//     appears in a type, and how tags work. So props carry compile-time
//     constants, compared exactly.
//   * **Recursive types are equirecursive** (§5.5): `μR.B` is interchangeable
//     with `B[R := μR.B]`. Subtyping unrolls and assumes, which is what makes
//     the knot terminate.
//   * **Unions and intersections are sets** (§3.6), so they are normalised at
//     construction — flattened, deduplicated, sorted — which makes the
//     canonical rendering a usable equality.

$decl P $import "prelude"

$decl not P.not
$decl and P.and
$decl or  P.or

$decl strs $specialize P.list ""

// Integer subtraction, captured *now*.
//
// §2.1 makes an intrinsic an ordinary shadowable name, and `$decl sub` below
// shadows it for the whole file — not from its own line onward, because a name
// in a `$func` body resolves against the finished block, not against the
// prefix that existed when the body was written. So `$call sub (n, 1)` in any
// function here is a subtype check between two Ints, returning a Bool.
//
// This `$decl` is different: it runs at *this* point in source order (§4.10,
// no hoisting), when the block has no `sub` slot yet, so it resolves to the
// root block's intrinsic and keeps it.
$decl isub sub

// ------------------------------------------------------------------ tracing
//
// A failing subtype check is the hardest thing in the checker to reason about:
// the two types render to thousands of characters and the interesting fact is
// which *innermost* goal returned false. So the check is simply re-run with
// tracing on, and only when it has already failed — that keeps the output to
// the one goal tree that matters.
//
// `spaces` needs integer subtraction, which `$decl sub` below shadows for the
// whole file — see `isub`. Declaring these early does *not* protect them.
// §4.2 gives `$new` the type of its operand, so a bare `false` makes storage
// that only `false` fits into. `$union (false, true)` widens the type to Bool
// while keeping `false` as the value — §4.8a: the union *evaluates* to its
// first member, so member order is what picks the initial value.
$decl want_trace $mut $alloc ($union (false, true))
$decl trace_on   $mut $alloc ($union (false, true))
$decl tbudget    $mut $alloc 0
$decl bval       $func ($decl b P.boolean) b

$decl spaces $func ($decl n 0, $decl acc "")
  $if ($call lt (n, 1)) acc ($call spaces ($call isub (n, 1), $call concat (acc, ". ")))

$decl enable_trace $func () $set want_trace true

// ------------------------------------------------------------ string ordering
//
// Needed for canonical form: props and union members are sorted by name and by
// rendering respectively. §8 gives `lt` on Int only, so this is bytewise.

// Written without an enclosing block so the recursion stays in tail position
// (§7.7): a block would cost one stack frame per character, and these compare
// whole rendered types. The price is reading each byte twice.
$decl str_lt_at $func ($decl a "", $decl b "", $decl i 0)
  $if ($call not ($call lt (i, $call len (a)))) ($call lt (i, $call len (b)))
  ($if ($call not ($call lt (i, $call len (b)))) false
  ($if ($call lt ($call byte (a, i), $call byte (b, i))) true
  ($if ($call lt ($call byte (b, i), $call byte (a, i))) false
       ($call str_lt_at (a, b, $call add (i, 1))))))

$decl str_lt $func ($decl a "", $decl b "") $call str_lt_at (a, b, 0)

$decl mem_str $func ($decl xs strs.node, $decl s "") $match xs (
  $case {$prop tag "cons"} $if ($call eq_str (xs.head, s)) true ($call mem_str (xs.tail, s)),
  $case xs false
)

// -------------------------------------------------------- compile-time values
//
// What a `$prop` can hold, for the purpose of type identity (§4.10). Functions
// and templates are opaque: they get an identity number from whoever builds the
// type, since two distinct function-valued props are distinct types.

$decl cv_int $func ($decl x 0)    { $prop tag "cint"    $decl v x }
$decl cv_str $func ($decl x "")   { $prop tag "cstr"    $decl v x }
// §3.2: `true` and `false` are distinct types, so a parameter defaulted `true`
// takes only `true`. This one holds either.
$decl cv_bool   $func ($decl x P.boolean) { $prop tag "cbool"   $decl v x }
$decl cv_unit   { $prop tag "cunit" }
$decl cv_opaque $func ($decl i 0)    { $prop tag "copaque" $decl id i }

$decl proto_cv $union (
  $call cv_int (0),
  $call cv_str (""),
  $call cv_bool (true),
  cv_unit,
  $call cv_opaque (0)
)

$decl show_cv $func ($decl c proto_cv) $match c (
  $case {$prop tag "cint"}    $call concat ("i", $call int_to_str (c.v)),
  $case {$prop tag "cstr"}    $call concat ("s\"", $call concat (c.v, "\"")),
  $case {$prop tag "cbool"}   $if c.v "btrue" "bfalse",
  $case {$prop tag "cunit"}   "u",
  $case {$prop tag "copaque"} $call concat ("o", $call int_to_str (c.id)),
  $case c "?"
)

// Compared structurally, not by rendering. This used to be
// `eq_str (show_cv a, show_cv b)`, which built two strings for every answer —
// and `same_props` calls it for every prop of every block comparison, so it
// showed up as 5.6M calls and 11.2M allocations when the whole compiler was
// lowered. Same antipattern as `same`'s old leaf case.
$decl cv_eq $func ($decl a proto_cv, $decl b proto_cv) $match a (
  $case {$prop tag "cint"}
    ($match b ($case {$prop tag "cint"} ($call eq_int (a.v, b.v)), $case b false)),
  $case {$prop tag "cstr"}
    ($match b ($case {$prop tag "cstr"} ($call eq_str (a.v, b.v)), $case b false)),
  $case {$prop tag "cbool"}
    ($match b ($case {$prop tag "cbool"} ($if a.v b.v ($call not (b.v))), $case b false)),
  $case {$prop tag "cunit"}
    ($match b ($case {$prop tag "cunit"} true, $case b false)),
  // §4.10: a function-valued prop is an identity, and the identity is what
  // tells two of them apart.
  $case {$prop tag "copaque"}
    ($match b ($case {$prop tag "copaque"} ($call eq_int (a.id, b.id)), $case b false)),
  $case a false
)

// -------------------------------------------------------------------- types
//
// Leaf types first: the union below needs one of them evaluated.

$decl t_int   { $prop tag "int" }
$decl t_float { $prop tag "float" }
$decl t_str   { $prop tag "str" }
$decl t_true  { $prop tag "true" }
$decl t_false { $prop tag "false" }
$decl t_unit  { $prop tag "unit" }

// §3.6: ⊥, the type of `panic`, a subtype of everything.
$decl t_bot   { $prop tag "bottom" }

// §5.5's placeholder `R`: a type not yet solved. Its id comes from a global
// counter and is meaningful only until the knot is tied.
// §9.3's table is scanned with `same` against every entry for every type
// interned — 275,020,404 comparisons over one emit of the compiler, an average
// scan of 229 for 1,199,073 lookups, and 40.3s of a 62.7s run. So every type
// carries a structural hash, and `same` settles the common answer (a mismatch)
// with one integer compare instead of walking two records.
//
// **The hash may depend only on what `same` actually compares, and it is built
// from a deliberate *coarsening* of that.** Including something `same` ignores
// would make two equal types hash differently, intern twice, and hand the
// backend two C structs for one type — so `frame` is excluded (`same`'s `func`
// case does not compare it), a prop contributes its value's *tag* rather than
// its value (`cv_eq` is structural, so equal values share a tag), a field
// contributes its name's *length* (equal names have equal lengths), and a prop's
// `ty` is not used at all (`same_props` does not compare it). Omitting anything
// only costs a fallthrough to the structural comparison; including one thing too
// many is a miscompile.
//
// `mul` panics on overflow (§8), so the mix is modular — and the modulus is as wide
// as that allows, because the hash is also what **names** a C struct. As a filter a
// narrow modulus only costs an occasional fallthrough, but as a name a collision is
// two distinct types sharing one struct name: 30 bits gives a birthday collision
// around 2% over the compiler's 6,348 types, which is far too likely. `hmix` does
// `a * 31 + b` with `a < hmod`, so `hmod` may go up to 2^63/31 ≈ 2.97e17; at 1e17 the
// collision probability is ~1e-10, and a collision that did happen would be two
// conflicting definitions of one struct name, which `cc` rejects rather than
// miscompiles.
$decl hmod 100000000000000003
// **Non-linear, and it has to be.** This used to be `a * 31 + b` alone, which makes a
// type's hash a linear polynomial in its leaves' hashes — so swapping two leaves between
// positions of equal weight cancels exactly. `(Str) -> option Int` and `(Int) -> option
// Str` shared a hash that way (PERF.md, "What recursive interning would save"), in one of
// 320M hash-equal comparisons over a self-emit. Harmless to `same`, which walks on equal
// hashes; not to a struct's C *name*, which is this hash — two distinct blocks colliding
// would be one name for two layouts. The width of `hmod` makes a *random* collision
// negligible; it says nothing about a structured one.
//
// So every combination step is scrambled by a square, which no swap survives. §8 gives the
// bootstrap no bitwise operators and makes `mul` panic on overflow, which rules out the
// usual xor-shift mixers: the value is split at 10⁹ instead, so `lo * lo` stays below 10¹⁸.
// Scrambling at every step, rather than once at the end, is what breaks the cancellation —
// a linear inner sum scrambled afterwards would still collide wherever the sums do.
$decl hsplit 1000000000
$decl hscramble $func ($decl x 0) {
  $decl lo $call mod (x, hsplit)
  $decl hi $call div (x, hsplit)
  $decl ret $call mod ($call add ($call add ($call mul (lo, lo), lo), $call mul (hi, 1000003)),
      hmod)
}.ret

$decl hmix $func ($decl a 0, $decl b 0)
  $call hscramble ($call mod ($call add ($call mul (a, 31), $call mod (b, hmod)), hmod))

// Every byte of a string, because the hash has to be **faithful** and not merely a
// filter. Hashing a name's *length* is enough to settle a comparison — a mismatch
// falls through to the structural walk — but the same hash names the C struct, and
// there a collision is two distinct types sharing one identity. Coarsening by length
// made `{name, ty}` and `{a, bc}` collide, and `cc` reported a redefined struct.
$decl hash_str $func ($decl s "", $decl i 0, $decl acc 0)
  $if ($call lt (i, $call len (s)))
      ($call hash_str (s, $call add (i, 1), $call hmix (acc, $call byte (s, i))))
      acc

$decl t_var $func ($decl i 0) { $prop tag "var" $decl id i  $decl h $call hmix (10, i) }

// A bound recursion variable, as a de Bruijn index: `bnd 0` is the innermost
// enclosing `rec`, `bnd 1` the one outside it. Binders therefore carry no name
// at all, which makes alpha-equivalence *structural identity* — two copies of
// the same recursive type built at two declarations come out equal, and the
// assumption set in `sub` can recognise a goal it has already seen. Naming
// binders by a unique integer, which is what this replaced, cannot do that.
$decl t_bnd $func ($decl k 0) { $prop tag "bnd" $decl idx k  $decl h $call hmix (11, k) }

// The type of types.
//
// The shapes are written out rather than named through the constructors below.
// §5.7 lets a type-only position reference a declaration that is *in progress* —
// which `proto_ty` is, inside its own `$union` — but not one that has not
// started. Naming the constructors here would be the forward reference §4.11
// forbids; it only looked like it worked because a type-only position is never
// evaluated. Field orders must match the constructors exactly, since §5.1 makes
// layout part of the type.
$decl proto_ty $union (
  t_int, t_float, t_str, t_true, t_false, t_unit, t_bot,
  $call t_var (0),
  $call t_bnd (0),
 {  // §5.5: every field that reaches a type again goes through storage. A list
   // is boxed as a whole — a cons cell holds its element inline, so its size
   // needs the element's — while a `field`'s own `ty` stays inline, since by
   // then the type it names already has a size.
   $prop tag "block"
   $decl fields $alloc ($specialize P.list { $decl name ""  $decl ty proto_ty }).node
   // `value` is any compile-time value, not just unit: a prop holding a
   // function renders as `copaque`, and writing `cv_unit` here said no block
   // with such a prop was a type at all.
   $decl props $alloc ($specialize P.list {
     $decl name ""  $decl value proto_cv  $decl ty proto_ty
   }).node
   $decl h 0  $decl cid -1  $decl pv P.boolean
 },
  {
    $prop tag "group" $decl items $alloc ($specialize P.list proto_ty).node  $decl h 0
    $decl cid -1  $decl pv P.boolean
  },
  {
    $prop tag "func"  $decl params $alloc ($specialize P.list proto_ty).node
    $decl result $alloc proto_ty
    // `rmut`: a member that needs its receiver mutable (§4.10). Unlike `frame` it is part
    // of the type's identity, because it changes what can call the function.
    $decl frame  P.boolean  $decl rmut P.boolean  $decl h 0  $decl cid -1  $decl pv P.boolean
  },
 {  // §3.5: storage has a **kind** as well as a qualifier, and the two are
   // orthogonal — `$mut`/`$const` produce views and preserve the kind. Frame is
   // `""` and allocated is `"alloc"`, so a reference built without saying is
   // frame, which is what `$new` makes.
   $prop tag "ref"   $decl qual ""  $decl inner $alloc proto_ty  $decl kind ""  $decl h 0
   $decl cid -1  $decl pv P.boolean
 },
  { $prop tag "array" $decl elem $alloc proto_ty  $decl h 0  $decl cid -1  $decl pv P.boolean },
  {
    $prop tag "union" $decl members $alloc ($specialize P.list proto_ty).node  $decl h 0
    $decl cid -1  $decl pv P.boolean
  },
  {
    $prop tag "inter" $decl members $alloc ($specialize P.list proto_ty).node  $decl h 0
    $decl cid -1  $decl pv P.boolean
  },
  { $prop tag "rec"   $decl body $alloc proto_ty  $decl h 0  $decl cid -1  $decl pv P.boolean },
  {
    $prop tag "over"  $decl cands $alloc ($specialize P.list proto_ty).node  $decl h 0
    $decl cid -1  $decl pv P.boolean
  },
  { $prop tag "tmpl"  $decl id 0  $decl h 0  $decl cid -1  $decl pv P.boolean },
  {
    // §6: a trait, the type of a trait object. It binds `Self` the way `rec` binds its
    // variable, so `bnd 0` in a member's type is `Self`; members are sorted by name,
    // since props are unordered and a canonical order makes `same` positional. `frame`
    // is the trait object's kind (§3.5) — set when it refers to frame storage — and
    // is, like a function's, not part of the type's identity (§5.3a). `qual` is the
    // referent's qualifier (§6): "mut" for a trait object made from `$mut` storage, which
    // is what a member needing a mutable receiver (§4.10) is called through; "" otherwise,
    // read-only. Unlike `frame` it is identity, because it changes what may be called.
    $prop tag "trait"
    $decl members $alloc ($specialize P.list { $decl name ""  $decl ty proto_ty }).node
    $decl frame P.boolean  $decl qual ""  $decl h 0  $decl cid -1  $decl pv P.boolean
  },
  {
    // §4.12: `$impl` over a base that is not a block — its type with props added. Props
    // have no layout (§4.10), so the layout is the base's; a block base takes the props
    // into the block instead, and never reaches here.
    $prop tag "with" $decl base $alloc proto_ty
    $decl props $alloc ($specialize P.list {
      $decl name ""  $decl value proto_cv  $decl ty proto_ty
    }).node
    $decl h 0  $decl cid -1  $decl pv P.boolean
  }
)

$decl tval $func ($decl t proto_ty) t

$decl field $func ($decl n "", $decl t proto_ty) { $decl name n  $decl ty t }

// The type a compile-time value has. For everything but an opaque value it is
// determined by the value, which is why a prop's *value* alone is enough for
// type identity (§4.10, §5.1).
$decl cv_type $func ($decl c proto_cv) $match c (
  $case {$prop tag "cint"}  t_int,
  $case {$prop tag "cstr"}  t_str,
  $case {$prop tag "cbool"} $if c.v t_true t_false,
  $case {$prop tag "cunit"} t_unit,
  // A function- or template-valued prop: the producer supplies the real type.
  $case c t_bot
)

// A prop carries both its value and its type: §5.1 compares *values* for
// subtyping, while §4.6 projection needs the type. `show` renders only the
// value, since for every non-opaque value the type follows from it.
$decl prop_typed $func ($decl n "", $decl c proto_cv, $decl t proto_ty)
  { $decl name n  $decl value c  $decl ty t }

$decl prop_entry $func ($decl n "", $decl c proto_cv)
  $call prop_typed (n, c, $call cv_type (c))

$decl proto_field $call field ("", proto_ty)
$decl proto_prop  $call prop_entry ("", cv_unit)

$decl tys    $specialize P.list proto_ty
$decl fields $specialize P.list proto_field
$decl props  $specialize P.list proto_prop

// The stored hash, or a per-tag constant for the leaves — which carry nothing, so
// their tag *is* their identity and they need no field.
// Every compound tag is named rather than caught: §4.7 narrows a catch-all to the
// *union* of what is left, and §5.1 can only project a common prefix — `h` sits at
// a different position in each member, so `t.h` on that union does not typecheck.
// Naming each one narrows to a single member, where the field is reachable.
$decl hash_of $func ($decl t proto_ty) $match t (
  $case {$prop tag "int"}    1,
  $case {$prop tag "float"}  2,
  $case {$prop tag "str"}    3,
  $case {$prop tag "true"}   4,
  $case {$prop tag "false"}  5,
  $case {$prop tag "unit"}   6,
  $case {$prop tag "bottom"} 7,
  $case {$prop tag "var"}    t.h,
  $case {$prop tag "bnd"}    t.h,
  $case {$prop tag "block"}  t.h,
  $case {$prop tag "group"}  t.h,
  $case {$prop tag "func"}   t.h,
  $case {$prop tag "ref"}    t.h,
  $case {$prop tag "array"}  t.h,
  $case {$prop tag "union"}  t.h,
  $case {$prop tag "inter"}  t.h,
  $case {$prop tag "rec"}    t.h,
  $case {$prop tag "over"}   t.h,
  $case {$prop tag "tmpl"}   t.h,
  $case {$prop tag "trait"}  t.h,
  $case {$prop tag "with"}   t.h,
  $case t 0
)

// A compile-time value in full. `cv_eq` is structural and compares the payload of
// every kind — the int, the string, the bool, and a `copaque`'s identity — so all of
// it may be hashed, and all of it must be, since §5.1 makes a prop's *value* part of
// the block's type and two blocks differing only in one are distinct types needing
// distinct struct names.
$decl cv_tag_h $func ($decl c proto_cv) $match c (
  $case {$prop tag "cint"}    ($call hmix (1, $call mod (c.v, hmod))),
  $case {$prop tag "cstr"}    ($call hash_str (c.v, 0, 2)),
  $case {$prop tag "cbool"}   ($if c.v 3 4),
  $case {$prop tag "cunit"}   5,
  $case {$prop tag "copaque"} ($call hmix (6, c.id)),
  $case c 7
)

$decl hash_tys $func ($decl xs tys.node, $decl acc 0) $match xs (
  $case {$prop tag "cons"}
    $call hash_tys (xs.tail, $call hmix (acc, $call hash_of ($call tval (xs.head)))),
  $case xs acc
)

// An **intersection** is compared with `same_set`, which is order-insensitive,
// because intersections are deliberately not canonicalised — they carry no
// discriminator, so there is nothing for an order to mean. A positional fold
// would therefore give two *equal* intersections different hashes and split
// them, which is the one way this optimisation could miscompile: one type would
// intern twice and the backend would lay out two C structs for it. So the fold
// for an intersection is commutative. A union needs no such care, since
// `t_union` sorts and `same` compares its members positionally.
$decl hash_tys_comm $func ($decl xs tys.node, $decl acc 0) $match xs (
  $case {$prop tag "cons"}
    $call hash_tys_comm (xs.tail,
        $call mod ($call add (acc, $call hash_of ($call tval (xs.head))), hmod)),
  $case xs acc
)

// A field's name in full — `same_fields` compares names with `eq_str`, so every byte
// of one is something `same` compares and may be hashed.
$decl hash_fields $func ($decl xs fields.node, $decl acc 0) $match xs (
  $case {$prop tag "cons"}
    $call hash_fields (xs.tail,
        $call hmix ($call hash_str (xs.head.name, 0, acc),
                    $call hash_of ($call tval (xs.head.ty)))),
  $case xs acc
)

// A prop's `ty` is deliberately absent: `same_props` compares the name and the
// value and nothing else, so hashing the type would separate two equal types.
$decl hash_props $func ($decl xs props.node, $decl acc 0) $match xs (
  $case {$prop tag "cons"}
    $call hash_props (xs.tail,
        $call hmix ($call hash_str (xs.head.name, 0, acc),
                    $call cv_tag_h (xs.head.value))),
  $case xs acc
)

// Whether *any* placeholder survives in a type. A `$var` that is still here is by
// construction unsolved (§5.5), so such a type is not a layout and nothing at run time
// has it — which is what lets the backend skip it rather than fail on it.
//
// It was a walk of the whole type, and it became the largest cost in the compiler once
// `same` stopped being one (33.7% of a self-emit): lowering asks it of every member type
// it reads (`unsettled`). It is a property of how a type was built, like `h` and `cid`,
// so each constructor records it as `pv` from its children's, and the answer is a field
// read. It mirrors the walk it replaced exactly — a block's *fields* count and its props'
// types do not.
$decl has_var $func ($decl t proto_ty, $decl i 0) $match t (
  $case {$prop tag "var"}   true,
  $case {$prop tag "block"} t.pv,
  $case {$prop tag "group"} t.pv,
  $case {$prop tag "func"}  t.pv,
  $case {$prop tag "ref"}   t.pv,
  $case {$prop tag "array"} t.pv,
  $case {$prop tag "union"} t.pv,
  $case {$prop tag "inter"} t.pv,
  $case {$prop tag "rec"}   t.pv,
  $case {$prop tag "over"}  t.pv,
  $case {$prop tag "trait"} t.pv,
  $case {$prop tag "with"}  t.pv,
  $case t false
)

$decl has_var_tys $func ($decl xs tys.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} $if ($call has_var ($call tval (xs.head),
      0)) true ($call has_var_tys (xs.tail, 0)),
  $case xs false
)

$decl has_var_fields $func ($decl xs fields.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} $if ($call has_var ($call tval (xs.head.ty),
      0)) true ($call has_var_fields (xs.tail, 0)),
  $case xs false
)

// ------------------------------------------------------------- identity
//
// INTERNING.md, step 1. Every compound node carries a `cid`: its class under `same`,
// assigned by the constructor from one global, append-only table and never rolled back
// — which is the difference from every cached index this file and lowering have tried,
// all of which named a position in §9.3's table, the table §5.5's rollback rewrites. A
// type value that survives a rollback carries `cid`s that are still exactly right.
// Step 1 only *assigns* them; `same` does not read them yet.
//
// A `cid` is one of four classes by its value mod 4, so the kinds that need no table
// need no field: a compound node's comes from the table (0), a leaf's is fixed (1), a
// `var`'s is its id (2), a `bnd`'s its index (3). -1 is "not interned" — a prototype
// in `proto_ty`, written as a literal, or anything built from one — and a node with a
// -1 child is not interned either, so two unrelated -1s can never make a class.
$decl cid_of $func ($decl t proto_ty) $match t (
  $case {$prop tag "int"}    1,
  $case {$prop tag "float"}  5,
  $case {$prop tag "str"}    9,
  $case {$prop tag "true"}   13,
  $case {$prop tag "false"}  17,
  $case {$prop tag "unit"}   21,
  $case {$prop tag "bottom"} 25,
  $case {$prop tag "var"}    ($call add ($call mul (t.id, 4), 2)),
  $case {$prop tag "bnd"}    ($call add ($call mul (t.idx, 4), 3)),
  $case {$prop tag "block"}  t.cid,
  $case {$prop tag "group"}  t.cid,
  $case {$prop tag "func"}   t.cid,
  $case {$prop tag "ref"}    t.cid,
  $case {$prop tag "array"}  t.cid,
  $case {$prop tag "union"}  t.cid,
  $case {$prop tag "inter"}  t.cid,
  $case {$prop tag "rec"}    t.cid,
  $case {$prop tag "over"}   t.cid,
  $case {$prop tag "tmpl"}   t.cid,
  $case {$prop tag "trait"}  t.cid,
  $case {$prop tag "with"}   t.cid,
  $case t -1
)

// A class's key: what `same_deep` compares for that tag and nothing else. `kids` are the
// children's `cid`s; `names` a block's field names; `pnames` and `pvals` its props' names
// and values — never their `ty`, which `same_props` ignores. A function's `frame` is
// absent for the same reason. INTERNING.md's key table is this, row by row.
$decl cints $specialize P.list 0
$decl cvals $specialize P.list proto_cv
$decl ckey $func ($decl t 0, $decl a "", $decl b "", $decl ks cints.node, $decl ns strs.node,
                  $decl pn strs.node, $decl pv cvals.node, $decl n 0) {
  $decl tag    t  $decl s1 a  $decl s2 b  $decl kids $alloc ks  $decl names $alloc ns
  $decl pnames $alloc pn  $decl pvals $alloc pv  $decl num n
}
$decl proto_ckey $call ckey (0, "", "", cints.nil, strs.nil, strs.nil, cvals.nil, 0)
$decl cent       $func ($decl k proto_ckey, $decl c 0) { $decl key k  $decl cid c }
$decl proto_cent $call cent (proto_ckey, 0)
$decl cents      $specialize P.list proto_cent

$decl ci_eq $func ($decl xs cints.node, $decl ys cints.node) $match xs (
  $case {$prop tag "cons"} $match ys (
      $case {$prop tag "cons"} $if ($call eq_int (xs.head,
          ys.head)) ($call ci_eq ($call cints.val (xs.tail), $call cints.val (ys.tail))) false,
      $case ys false),
  $case xs ($call cints.is_nil (ys))
)
$decl cs_eq $func ($decl xs strs.node, $decl ys strs.node) $match xs (
  $case {$prop tag "cons"} $match ys (
      $case {$prop tag "cons"} $if ($call eq_str (xs.head,
          ys.head)) ($call cs_eq ($call strs.val (xs.tail), $call strs.val (ys.tail))) false,
      $case ys false),
  $case xs ($call strs.is_nil (ys))
)
$decl cv_list_eq $func ($decl xs cvals.node, $decl ys cvals.node) $match xs (
  $case {$prop tag "cons"} $match ys (
      $case {$prop tag "cons"} $if ($call cv_eq (xs.head,
          ys.head)) ($call cv_list_eq ($call cvals.val (xs.tail), $call cvals.val (ys.tail))) false,
      $case ys false),
  $case xs ($call cvals.is_nil (ys))
)
$decl ckey_eq $func ($decl a proto_ckey, $decl b proto_ckey)
  $if ($call not ($call eq_int (a.tag, b.tag))) false
  ($if ($call not ($call eq_int (a.num, b.num))) false
  ($if ($call not ($call eq_str (a.s1, b.s1))) false
  ($if ($call not ($call eq_str (a.s2, b.s2))) false
  ($if ($call not ($call ci_eq ($call cints.val (a.kids), $call cints.val (b.kids)))) false
  ($if ($call not ($call cs_eq ($call strs.val (a.names), $call strs.val (b.names)))) false
  ($if ($call not ($call cs_eq ($call strs.val (a.pnames), $call strs.val (b.pnames)))) false
       ($call cv_list_eq ($call cvals.val (a.pvals), $call cvals.val (b.pvals)))))))))

// The table: buckets by the structural hash `h`, which equal classes share because the
// hash is a sound coarsening of `same` (see `hash_of`). A persistent binary trie of
// depth 14, the shape §9.3's index already uses.
$decl ctrie $union (
  { $prop tag "leaf"   $decl items $alloc cents.node },
  { $prop tag "branch" $decl lo $alloc ctrie  $decl hi $alloc ctrie }
)
$decl ct_leaf $func ($decl xs cents.node) { $prop tag "leaf" $decl items $alloc xs }
$decl ct_branch $func ($decl l ctrie, $decl h ctrie) {
  $prop tag "branch" $decl lo $alloc l  $decl hi $alloc h
}
$decl ct_val   $func ($decl x ctrie) x
$decl ct_items $func ($decl tr ctrie)
    $match tr ($case {$prop tag "leaf"} ($call cents.val (tr.items)), $case tr cents.nil)
$decl ct_scan $func ($decl xs cents.node, $decl k proto_ckey) $match xs (
  $case {$prop tag "cons"} $if ($call ckey_eq (xs.head.key,
      k)) xs.head.cid ($call ct_scan ($call cents.val (xs.tail), k)),
  $case xs -1
)
$decl ct_find $func ($decl tr ctrie, $decl b 0, $decl k proto_ckey) $match tr (
  $case {$prop tag "branch"}
    $if ($call eq_int ($call mod (b, 2), 0)) ($call ct_find ($call ct_val (tr.lo), $call div (b, 2),
        k))
        ($call ct_find ($call ct_val (tr.hi), $call div (b, 2), k)),
  $case tr ($call ct_scan ($call ct_items (tr), k))
)
$decl ct_kid $func ($decl tr ctrie, $decl hi P.boolean) $match tr (
  $case {$prop tag "branch"} ($call ct_val ($if hi tr.hi tr.lo)),
  $case tr ($call ct_leaf (cents.nil))
)
$decl ct_add $func ($decl tr ctrie, $decl b 0, $decl d 0, $decl e proto_cent)
  $if ($call not ($call lt (d, 14))) ($call ct_leaf ($call cents.cons (e, $call ct_items (tr)))) {
    $decl lo $call ct_kid (tr, false)
    $decl hi $call ct_kid (tr, true)
    $decl up $call eq_int ($call mod (b, 2), 0)
    $decl ret  $if up ($call ct_branch ($call ct_add (lo, $call div (b, 2), $call add (d, 1), e),
        hi))
                    ($call ct_branch (lo, $call ct_add (hi, $call div (b, 2), $call add (d, 1), e)))
  }.ret

// Declared above every constructor on purpose: a module initialises in source order and
// the constructors run during `types`' own initialisation.
$decl ctable $mut $alloc ctrie
$decl cnext  $mut $alloc 0
$decl cival  $func ($decl x 0) x

// How many classes exist, for measuring (INTERNING.md, step 1).
$decl cid_count $func () $call cival (cnext)

$decl cbucket $func ($decl hv 0) $call mod ($call add ($call mod (hv, 16381), 16381), 16381)

// A key's own hash, and the bucket is chosen by it rather than by the type's `h`. That
// is what makes the key — and only the key — decide a class: bucketing by `h`, which
// also covers everything `same` compares, meant a key with a gap could merge two types
// only when their `h`s collided mod the bucket count, so a broken key almost never
// showed and paranoid mode could not see it. Dropping field names from the key merged
// nothing over a whole self-emit; bucketed by the key, it merges at once.
$decl ci_hash $func ($decl xs cints.node, $decl acc 0) $match xs (
  $case {$prop tag "cons"} $call ci_hash ($call cints.val (xs.tail), $call hmix (acc, xs.head)),
  $case xs acc
)
$decl cs_hash $func ($decl xs strs.node, $decl acc 0) $match xs (
  $case {$prop tag "cons"} $call cs_hash ($call strs.val (xs.tail), $call hash_str (xs.head, 0, acc)),
  $case xs acc
)
$decl cv_hash $func ($decl xs cvals.node, $decl acc 0) $match xs (
  $case {$prop tag "cons"} $call cv_hash ($call cvals.val (xs.tail), $call hmix (acc,
      $call cv_tag_h (xs.head))),
  $case xs acc
)
$decl ckey_hash $func ($decl k proto_ckey)
  $call cv_hash ($call cvals.val (k.pvals),
      $call cs_hash ($call strs.val (k.pnames),
          $call cs_hash ($call strs.val (k.names),
              $call ci_hash ($call cints.val (k.kids),
                  $call hash_str (k.s2, 0, $call hash_str (k.s1, 0, $call hmix (k.tag, k.num)))))))

// The class of a key, made if it is new. `ok` false — a child was not interned — gives -1.
// `hv` is unused now; it is kept so each constructor's call stays a one-line change.
$decl cid_for $func ($decl ok P.boolean, $decl hv 0, $decl k proto_ckey)
  $if ($call not (ok)) -1 {
    $decl b $call cbucket ($call ckey_hash (k))
    $decl f $call ct_find ($call ct_val (ctable), b, k)
    $decl ret $if ($call lt (-1, f)) f {
      $decl c    $call mul ($call cival (cnext), 4)
      $decl n    $set cnext ($call add ($call cival (cnext), 1))
      $decl a    $set ctable ($call ct_add ($call ct_val (ctable), b, 0, $call cent (k, c)))
      $decl ret2 c
    }.ret2
  }.ret

$decl kids_of $func ($decl xs tys.node, $decl acc cints.node) $match xs (
  $case {$prop tag "cons"} $call kids_of ($call tys.val (xs.tail),
      $call cints.cons ($call cid_of ($call tval (xs.head)), acc)),
  $case xs ($call cints.reverse (acc, cints.nil))
)
$decl kids_ok $func ($decl xs cints.node) $match xs (
  $case {$prop tag "cons"} $if ($call lt (xs.head,
      0)) false ($call kids_ok ($call cints.val (xs.tail))),
  $case xs true
)
$decl fkids_of $func ($decl xs fields.node, $decl acc cints.node) $match xs (
  $case {$prop tag "cons"} $call fkids_of ($call fields.val (xs.tail),
      $call cints.cons ($call cid_of ($call tval (xs.head.ty)), acc)),
  $case xs ($call cints.reverse (acc, cints.nil))
)
$decl fnames_of $func ($decl xs fields.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"} $call fnames_of ($call fields.val (xs.tail),
      $call strs.cons (xs.head.name, acc)),
  $case xs ($call strs.reverse (acc, strs.nil))
)
$decl pnames_of $func ($decl xs props.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"} $call pnames_of ($call props.val (xs.tail),
      $call strs.cons (xs.head.name, acc)),
  $case xs ($call strs.reverse (acc, strs.nil))
)
$decl pvals_of $func ($decl xs props.node, $decl acc cvals.node) $match xs (
  $case {$prop tag "cons"} $call pvals_of ($call props.val (xs.tail),
      $call cvals.cons (xs.head.value, acc)),
  $case xs ($call cvals.reverse (acc, cvals.nil))
)
// An intersection is a set (`same_set`), so its key is its members' `cid`s sorted.
$decl ci_insert $func ($decl x 0, $decl xs cints.node) $match xs (
  $case {$prop tag "cons"} $if ($call lt (x, xs.head)) ($call cints.cons (x, xs))
      ($call cints.cons (xs.head, $call ci_insert (x, $call cints.val (xs.tail)))),
  $case xs ($call cints.cons (x, cints.nil))
)
$decl ci_sort $func ($decl xs cints.node, $decl acc cints.node) $match xs (
  $case {$prop tag "cons"} $call ci_sort ($call cints.val (xs.tail), $call ci_insert (xs.head, acc)),
  $case xs acc
)

$decl kid1 $func ($decl t proto_ty) $call cints.cons ($call cid_of (t), cints.nil)

// Raw constructors. `raw_union`/`raw_inter` are not for general use — build
// unions with `t_union`, which normalises.
$decl raw_block $func ($decl fs fields.node, $decl ps props.node) {
  $decl hv $call hmix ($call hmix (13, $call hash_fields (fs, 0)), $call hash_props (ps, 0))
  $decl ks $call fkids_of (fs, cints.nil)
  $decl c  $call cid_for ($call kids_ok (ks), hv,
               $call ckey (1, "", "", ks, $call fnames_of (fs, strs.nil), $call pnames_of (ps,
                   strs.nil),
                           $call pvals_of (ps, cvals.nil), 0))
  $decl pvv $if ($call has_var_fields (fs, 0)) true false
  $decl n  {
    $prop tag "block" $decl fields $alloc fs  $decl props $alloc ps  $decl h hv  $decl cid c
    $decl pv pvv
  }
  $decl ret  n
}.ret

$decl raw_union $func ($decl ms tys.node) {
  $decl hv $call hmix (18, $call hash_tys (ms, 0))
  $decl ks $call kids_of (ms, cints.nil)
  $decl c   $call cid_for ($call kids_ok (ks), hv, $call ckey (6, "", "", ks, strs.nil, strs.nil,
      cvals.nil, 0))
  $decl pvv $if ($call has_var_tys (ms, 0)) true false
  $decl n   { $prop tag "union" $decl members $alloc ms  $decl h hv  $decl cid c  $decl pv pvv }
  $decl ret n
}.ret
$decl raw_inter $func ($decl ms tys.node) {
  $decl hv $call hmix (19, $call hash_tys_comm (ms, 0))
  $decl ks $call kids_of (ms, cints.nil)
  $decl c  $call cid_for ($call kids_ok (ks), hv,
               $call ckey (7, "", "", $call ci_sort (ks, cints.nil), strs.nil, strs.nil, cvals.nil,
                   0))
  $decl pvv $if ($call has_var_tys (ms, 0)) true false
  $decl n   { $prop tag "inter" $decl members $alloc ms  $decl h hv  $decl cid c  $decl pv pvv }
  $decl ret n
}.ret

$decl t_group $func ($decl xs tys.node) {
  $decl hv $call hmix (14, $call hash_tys (xs, 0))
  $decl ks $call kids_of (xs, cints.nil)
  $decl c   $call cid_for ($call kids_ok (ks), hv, $call ckey (2, "", "", ks, strs.nil, strs.nil,
      cvals.nil, 0))
  $decl pvv $if ($call has_var_tys (xs, 0)) true false
  $decl n   { $prop tag "group" $decl items $alloc xs  $decl h hv  $decl cid c  $decl pv pvv }
  $decl ret n
}.ret
// `frame` is §5.3a's closure clause. §7.3 keeps a closure's captures out of its
// *type* — that is what makes every function value two words — so a `$func`
// literal that captured a frame reference has to record that it did somewhere,
// and this is it. It is not about the parameters or the result: those are
// frame-bound or not on their own.
$decl t_func_rm $func ($decl ps tys.node, $decl r proto_ty, $decl fr P.boolean,
    $decl rm P.boolean) {
  $decl hv0 $call hmix ($call hmix (15, $call hash_tys (ps, 0)), $call hash_of (r))
  // `rmut` joins the hash and the key only when it is set, so every function type that
  // existed before it keeps its hash, its class and its struct name.
  $decl hv  $if rm ($call hmix (hv0, 7)) hv0
  // The result first, then the parameters; `frame` is not in the key (see `ckey`), and
  // `rmut` is its first string.
  $decl ks  $call cints.cons ($call cid_of (r), $call kids_of (ps, cints.nil))
  $decl c   $call cid_for ($call kids_ok (ks), hv, $call ckey (3, $if rm "m" "", "", ks, strs.nil,
      strs.nil, cvals.nil, 0))
  $decl pvv $if ($if ($call has_var_tys (ps, 0)) true ($call has_var (r, 0))) true false
  $decl n  {
    $prop tag "func" $decl params $alloc ps  $decl result $alloc r  $decl frame fr  $decl rmut rm
    $decl h hv  $decl cid c  $decl pv pvv
  }
  $decl ret n
}.ret

$decl t_func_fr $func ($decl ps tys.node, $decl r proto_ty, $decl fr P.boolean)
  $call t_func_rm (ps, r, fr, false)

$decl t_func  $func ($decl ps tys.node, $decl r proto_ty) $call t_func_fr (ps, r, false)

// The same function type, marked as needing a mutable receiver (§4.10).
$decl with_rmut $func ($decl t proto_ty) $match t (
  $case {$prop tag "func"}
    $call t_func_rm ($call tys.val (t.params), $call tval (t.result), t.frame, true),
  $case t t
)

// §5.3: `qual` is "" for `&T`, "mut" for `&mut T`, "const" for `&const T`.
// Two constructors rather than one with a default, because a *short* call is
// not the same thing as a defaulted one: inference accepts it (§3.4 fixes the
// parameter's type, not its presence) but lowering emits exactly the arguments
// written and `verify` rejects the mismatch. So the common case keeps its
// arity and the kinded case gets a name.
$decl t_ref_k $func ($decl q "", $decl t proto_ty, $decl k "") {
  $decl hv $call hmix ($call hash_str (k, 0, $call hash_str (q, 0, 16)), $call hash_of (t))
  $decl ks $call kid1 (t)
  $decl c   $call cid_for ($call kids_ok (ks), hv, $call ckey (4, q, k, ks, strs.nil, strs.nil,
      cvals.nil, 0))
  $decl pvv $if ($call has_var (t, 0)) true false
  $decl n  {
    $prop tag "ref" $decl qual q  $decl inner $alloc t  $decl kind k  $decl h hv  $decl cid c
    $decl pv pvv
  }
  $decl ret  n
}.ret

$decl t_ref   $func ($decl q "", $decl t proto_ty) $call t_ref_k (q, t, "")

// §4.2a's kind. Named rather than spelled out at each site, so the one string
// that means "allocated" lives in one place.
$decl k_alloc  "alloc"
$decl is_alloc $func ($decl k "") $call eq_str (k, k_alloc)
$decl t_array $func ($decl e proto_ty) {
  $decl hv $call hmix (17, $call hash_of (e))
  $decl ks $call kid1 (e)
  $decl c   $call cid_for ($call kids_ok (ks), hv, $call ckey (5, "", "", ks, strs.nil, strs.nil,
      cvals.nil, 0))
  $decl pvv $if ($call has_var (e, 0)) true false
  $decl n   { $prop tag "array" $decl elem $alloc e  $decl h hv  $decl cid c  $decl pv pvv }
  $decl ret n
}.ret
$decl t_rec   $func ($decl b proto_ty) {
  $decl hv $call hmix (20, $call hash_of (b))
  $decl ks $call kid1 (b)
  $decl c   $call cid_for ($call kids_ok (ks), hv, $call ckey (8, "", "", ks, strs.nil, strs.nil,
      cvals.nil, 0))
  $decl pvv $if ($call has_var (b, 0)) true false
  $decl n   { $prop tag "rec" $decl body $alloc b  $decl h hv  $decl cid c  $decl pv pvv }
  $decl ret n
}.ret
// §6. Members are sorted by name: props are unordered (§4.10), and one canonical order
// is what lets `same`, the key and the hash all be positional. Key tag 11: the member
// names and their types — never `frame`, which `same` ignores, exactly as for `func`.
// §6's members by name, for `t_trait_fr`. Insertion sort: a trait has a handful of
// members, and `str_lt` is the order `show` already uses.
$decl insert_field $func ($decl f proto_field, $decl xs fields.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call str_lt (xs.head.name, f.name))
        ($call fields.cons (xs.head, $call insert_field (f, $call fields.val (xs.tail))))
        ($call fields.cons (f, xs)),
  $case xs ($call fields.cons (f, fields.nil))
)

$decl sort_fields_go $func ($decl xs fields.node, $decl acc fields.node) $match xs (
  $case {$prop tag "cons"}
    $call sort_fields_go ($call fields.val (xs.tail), $call insert_field (xs.head, acc)),
  $case xs acc
)

$decl sort_fields $func ($decl xs fields.node) $call sort_fields_go (xs, fields.nil)

// The qualifier is keyed and hashed only when set, so a read-only trait keeps the class
// and hash it always had.
$decl t_trait_q $func ($decl ms fields.node, $decl fr P.boolean, $decl q "") {
  $decl sm  $call sort_fields (ms)
  $decl hv0 $call hmix (23, $call hash_fields (sm, 0))
  $decl hv  $if ($call eq_str (q, "")) hv0 ($call hash_str (q, 0, hv0))
  $decl ks  $call fkids_of (sm, cints.nil)
  $decl c   $call cid_for ($call kids_ok (ks), hv,
                $call ckey (11, q, "", ks, $call fnames_of (sm, strs.nil), strs.nil, cvals.nil, 0))
  $decl pvv $if ($call has_var_fields (sm, 0)) true false
  $decl n   {
    $prop tag "trait" $decl members $alloc sm  $decl frame fr  $decl qual q  $decl h hv
    $decl cid c  $decl pv pvv
  }
  $decl ret n
}.ret
$decl t_trait_fr $func ($decl ms fields.node, $decl fr P.boolean) $call t_trait_q (ms, fr, "")
$decl t_trait    $func ($decl ms fields.node) $call t_trait_fr (ms, false)

$decl t_over  $func ($decl cs tys.node) {
  $decl hv $call hmix (21, $call hash_tys (cs, 0))
  $decl ks $call kids_of (cs, cints.nil)
  $decl c   $call cid_for ($call kids_ok (ks), hv, $call ckey (9, "", "", ks, strs.nil, strs.nil,
      cvals.nil, 0))
  $decl pvv $if ($call has_var_tys (cs, 0)) true false
  $decl n   { $prop tag "over" $decl cands $alloc cs  $decl h hv  $decl cid c  $decl pv pvv }
  $decl ret n
}.ret

// A template (§4.9). Its body is *not* type-checked at declaration, so there is
// nothing structural to record here: the type is an identity, and whoever built
// it keeps the body and the environment it was written in. Two templates are
// the same type when they are the same template.
$decl t_tmpl  $func ($decl i 0) {
  $decl hv  $call hmix (12, i)
  $decl c   $call cid_for (true, hv, $call ckey (10, "", "", cints.nil, strs.nil, strs.nil,
      cvals.nil, i))
  $decl pvv $if (false) true false
  $decl n   { $prop tag "tmpl" $decl id i  $decl h hv  $decl cid c  $decl pv pvv }
  $decl ret n
}.ret

// Props have no layout (§4.10), so their order is not part of the type.
// Sorting them at construction is what makes the rendering below canonical.
$decl props_insert $func ($decl p proto_prop, $decl xs props.node) $match xs (
  $case {$prop tag "cons"} $if ($call str_lt (p.name, xs.head.name))
      ($call props.cons (p, xs))
      ($call props.cons (xs.head, $call props_insert (p, xs.tail))),
  $case xs ($call props.cons (p, props.nil))
)

$decl props_sort $func ($decl xs props.node, $decl acc props.node) $match xs (
  $case {$prop tag "cons"} $call props_sort (xs.tail, $call props_insert (xs.head, acc)),
  $case xs acc
)

$decl t_block $func ($decl fs fields.node, $decl ps props.node)
  $call raw_block (fs, $call props_sort (ps, props.nil))

// Key tag 12: the base and the props' names and values, as for a block's props — never a
// prop's `ty`, which `same_props` ignores.
$decl t_with $func ($decl b proto_ty, $decl ps props.node) {
  $decl sp  $call props_sort (ps, props.nil)
  $decl hv  $call hmix ($call hmix (25, $call hash_of (b)), $call hash_props (sp, 0))
  $decl ks  $call kid1 (b)
  $decl c   $call cid_for ($call kids_ok (ks), hv, $call ckey (12, "", "", ks, strs.nil,
                $call pnames_of (sp, strs.nil), $call pvals_of (sp, cvals.nil), 0))
  $decl pvv $if ($call has_var (b, 0)) true false
  $decl n   {
    $prop tag "with" $decl base $alloc b  $decl props $alloc sp  $decl h hv  $decl cid c
    $decl pv pvv
  }
  $decl ret n
}.ret

// --------------------------------------------------------- canonical form
//
// A string that determines the type. Used for equality, for deduplicating
// union members, and as the key of the assumption set that makes recursive
// subtyping terminate.

$fwd show

$decl show_tys $func ($decl xs tys.node, $decl acc "", $decl first P.boolean) $match xs (
  $case {$prop tag "cons"} $call show_tys (xs.tail,
      $call concat (acc, $call concat ($if first "" ",", $call show (xs.head))), false),
  $case xs acc
)

// Union and intersection members are a set, so the rendering sorts them — each
// member rendered once, then the strings ordered. That keeps `show` canonical
// (it is used as a cache key) without making construction pay for it.
$decl strs_insert $func ($decl x "", $decl xs strs.node) $match xs (
  $case {$prop tag "cons"} $if ($call str_lt (x, xs.head))
      ($call strs.cons (x, xs))
      ($call strs.cons (xs.head, $call strs_insert (x, xs.tail))),
  $case xs ($call strs.cons (x, strs.nil))
)

$decl show_sorted_add $func ($decl xs tys.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"} $call show_sorted_add (xs.tail, $call strs_insert ($call show (xs.head),
      acc)),
  $case xs acc
)

$decl join_strs $func ($decl xs strs.node, $decl acc "", $decl first P.boolean) $match xs (
  $case {$prop tag "cons"}
    $call join_strs (xs.tail, $call concat (acc, $call concat ($if first "" ",", xs.head)), false),
  $case xs acc
)

$decl show_set $func ($decl xs tys.node)
  $call join_strs ($call show_sorted_add (xs, strs.nil), "", true)

$decl show_fields $func ($decl xs fields.node, $decl acc "") $match xs (
  $case {$prop tag "cons"} $call show_fields (xs.tail,
      $call concat (acc, $call concat (xs.head.name,
      $call concat (":", $call concat ($call show (xs.head.ty), ","))))),
  $case xs acc
)

$decl show_props $func ($decl xs props.node, $decl acc "") $match xs (
  $case {$prop tag "cons"} $call show_props (xs.tail,
      $call concat (acc, $call concat (xs.head.name,
      $call concat ("=", $call concat ($call show_cv (xs.head.value), ","))))),
  $case xs acc
)

// §3.5: "written `&T` for frame and `&^T` for allocated *in diagnostics only*".
$decl show_qual $func ($decl q "", $decl k "") {
  $decl amp $if ($call is_alloc (k)) "&^" "&"
  $decl ret $if ($call eq_str (q, "")) amp
              ($call concat (amp, $if ($call eq_str (q, "mut")) "mut " "const "))
}.ret

$decl show $func ($decl t proto_ty) $match t (
  $case {$prop tag "int"}    "Int",
  $case {$prop tag "float"}  "Float",
  $case {$prop tag "str"}    "Str",
  $case {$prop tag "true"}   "true",
  $case {$prop tag "false"}  "false",
  $case {$prop tag "unit"}   "()",
  $case {$prop tag "bottom"} "!",
  $case {$prop tag "var"}    $call concat ("v", $call int_to_str (t.id)),
  $case {$prop tag "block"}  $call concat ("{", $call concat ($call show_fields (t.fields, ""),
                                 $call concat ($call show_props (t.props, ""), "}"))),
  $case {$prop tag "group"}  $call concat ("(", $call concat ($call show_tys (t.items, "", true), ")")),
  $case {$prop tag "func"}
    $call concat ($if t.rmut "mut" "", $call concat ("[", $call concat ($call show_tys (t.params, "",
        true), $call concat ("]->", $call show (t.result))))),
  $case {$prop tag "ref"}    $call concat ($call show_qual (t.qual, t.kind), $call show (t.inner)),
  $case {$prop tag "array"}  $call concat ("[]", $call show (t.elem)),
  $case {$prop tag "union"}  $call concat ("<", $call concat ($call show_set (t.members), ">")),
  $case {$prop tag "inter"}  $call concat ("^", $call concat ($call show_set (t.members), "^")),
  $case {$prop tag "bnd"}    $call concat ("b", $call int_to_str (t.idx)),
  $case {$prop tag "rec"}    $call concat ("mu.", $call show (t.body)),
  $case {$prop tag "trait"}
    $call concat ($if ($call eq_str (t.qual, "")) "" "mut ",
        $call concat ("trait{", $call concat ($call show_fields (t.members, ""), "}"))),
  $case {$prop tag "with"}
    $call concat ($call show (t.base),
        $call concat ("+{", $call concat ($call show_props (t.props, ""), "}"))),
  $case {$prop tag "over"}   $call concat ("O<", $call concat ($call show_tys (t.cands, "", true), ">")),
  $case {$prop tag "tmpl"}   $call concat ("Tmpl", $call int_to_str (t.id)),
  $case t "?"
)

// Structural equality, without rendering.
//
// `show` allocates a string proportional to the whole type, and equality is the
// hottest operation in the checker — every subtype check starts with it. This
// walks the two types together instead and stops at the first difference, so a
// mismatch costs almost nothing and nothing is allocated. Props are compared in
// order because `t_block` sorts them at construction.

$fwd same

$decl same_tys $func ($decl xs tys.node, $decl ys tys.node) $match xs (
  $case {$prop tag "cons"} $match ys (
      $case {$prop tag "cons"}
        $if ($call same (xs.head, ys.head)) ($call same_tys (xs.tail, ys.tail)) false,
      $case ys false
    ),
  $case xs ($call tys.is_nil (ys))
)

$decl same_fields $func ($decl xs fields.node, $decl ys fields.node) $match xs (
  $case {$prop tag "cons"} $match ys (
      $case {$prop tag "cons"}
        $if ($call eq_str (xs.head.name, ys.head.name))
            ($if ($call same (xs.head.ty, ys.head.ty)) ($call same_fields (xs.tail, ys.tail)) false)
            false,
      $case ys false
    ),
  $case xs ($call fields.is_nil (ys))
)

$decl same_props $func ($decl xs props.node, $decl ys props.node) $match xs (
  $case {$prop tag "cons"} $match ys (
      $case {$prop tag "cons"}
        $if ($call eq_str (xs.head.name, ys.head.name))
            ($if ($call cv_eq (xs.head.value, ys.head.value)) ($call same_props (xs.tail,
                ys.tail)) false)
            false,
      $case ys false
    ),
  $case xs ($call props.is_nil (ys))
)

$decl mem_ty $func ($decl xs tys.node, $decl t proto_ty) $match xs (
  $case {$prop tag "cons"} $if ($call same (xs.head, t)) true ($call mem_ty (xs.tail, t)),
  $case xs false
)

$decl subset_tys $func ($decl xs tys.node, $decl ys tys.node) $match xs (
  $case {$prop tag "cons"} $if ($call mem_ty (ys, xs.head)) ($call subset_tys (xs.tail, ys)) false,
  $case xs true
)

$decl same_set $func ($decl xs tys.node, $decl ys tys.node)
  $if ($call eq_int ($call tys.length (xs, 0), $call tys.length (ys, 0)))
      ($call subset_tys (xs, ys)) false

$decl same_deep $func ($decl a proto_ty, $decl b proto_ty) $match a (
  $case {$prop tag "var"} $match b ($case {$prop tag "var"} $call eq_int (a.id, b.id), $case b false),
  $case {$prop tag "block"} $match b (
      $case {$prop tag "block"}
        $if ($call same_fields (a.fields, b.fields)) ($call same_props (a.props, b.props)) false,
      $case b false
    ),
  $case {$prop tag "group"} $match b (
      $case {$prop tag "group"} $call same_tys (a.items, b.items), $case b false),
  $case {$prop tag "func"} $match b (
      $case {$prop tag "func"}
        $if ($call same_tys (a.params, b.params))
            ($if ($call same (a.result, b.result)) ($if a.rmut b.rmut ($call not (b.rmut))) false)
            false,
      $case b false
    ),
  $case {$prop tag "ref"} $match b (
      $case {$prop tag "ref"}
        $if ($call eq_str (a.qual, b.qual))
            ($if ($call eq_str (a.kind, b.kind)) ($call same (a.inner, b.inner)) false) false,
      $case b false
    ),
  $case {$prop tag "array"} $match b (
      $case {$prop tag "array"} $call same (a.elem, b.elem), $case b false),
  // §3.6 makes both of these *sets*, so membership and not order is what decides
  // equality — but a **union** is now canonically ordered by construction, and
  // that makes the set comparison unnecessary. `t_union` is the only caller of
  // `raw_union` and it always passes `sort_tys`, so two equal unions arrive with
  // their members in the same order and a positional walk answers the same
  // question `same_set` does. The difference is the cost: `same_set` is a length
  // check plus `subset_tys`, which is one `mem_ty` per member and one `same` per
  // candidate — O(n·m) on the members, each of which may itself be a big union.
  // `same_tys` is O(n). `intern` calls `same` against every table entry for every
  // type it interns, so this is the hot path of the whole compiler: `perf` on an
  // emit of the compiler put `same` at 56.9%, `mem_ty` at 13.1% and `same_set` at
  // 3.3%, against `find_ty_at`'s 2.5% — the cost was never the table scan.
  //
  // An **intersection** keeps the set comparison, because intersections are
  // deliberately not canonicalised: they carry no discriminator, so there is
  // nothing for an order to mean and `inter_addall` does not sort.
  //
  // The check that this is sound is that the emitted C stays byte-identical. If a
  // positional walk answered differently anywhere, `intern` would hand out
  // different indices and every `mpl_tN` after that point would move.
  $case {$prop tag "union"} $match b (
      $case {$prop tag "union"} $call same_tys (a.members, b.members), $case b false),
  $case {$prop tag "inter"} $match b (
      $case {$prop tag "inter"} $call same_set (a.members, b.members), $case b false),
  // No binder name to compare: two recursive types are equal exactly when
  // their bodies are, which is alpha-equivalence with nothing to do.
  $case {$prop tag "rec"} $match b (
      $case {$prop tag "rec"} $call same (a.body, b.body), $case b false),
  $case {$prop tag "bnd"} $match b (
      $case {$prop tag "bnd"} $call eq_int (a.idx, b.idx), $case b false),
  $case {$prop tag "over"} $match b (
      $case {$prop tag "over"} $call same_tys (a.cands, b.cands), $case b false),
  $case {$prop tag "tmpl"} $match b (
      $case {$prop tag "tmpl"} $call eq_int (a.id, b.id), $case b false),
  // Sorted by name at construction, so a positional walk is the set comparison; `frame`
  // is not compared (§5.3a), as for a function.
  $case {$prop tag "trait"} $match b (
      $case {$prop tag "trait"}
        $if ($call eq_str (a.qual, b.qual)) ($call same_fields (a.members, b.members)) false,
      $case b false),
  $case {$prop tag "with"} $match b (
      $case {$prop tag "with"}
        $if ($call same (a.base, b.base)) ($call same_props (a.props, b.props)) false,
      $case b false
    ),
  // The leaf types carry nothing, so equal renderings mean equal types — but
  // only once `b` is known to be one too. Reaching here says nothing about
  // `b`, and `show` of a compound renders the whole type: `same (Int, <big
  // union>)` would build that union's string to answer `false`. `intern`
  // scans its table with `same` for every type it interns, so that was
  // quadratic *and* allocating, and it dominated lowering a large file.
  $case a $match b (
      $case {$prop tag "var"}   false,
      $case {$prop tag "block"} false,
      $case {$prop tag "group"} false,
      $case {$prop tag "func"}  false,
      $case {$prop tag "ref"}   false,
      $case {$prop tag "array"} false,
      $case {$prop tag "union"} false,
      $case {$prop tag "inter"} false,
      $case {$prop tag "rec"}   false,
      $case {$prop tag "bnd"}   false,
      $case {$prop tag "over"}  false,
      $case {$prop tag "tmpl"}  false,
      $case {$prop tag "trait"} false,
      $case {$prop tag "with"}  false,
      // Both sides are leaves by now, and a leaf carries nothing — so equal
      // tags *are* equal types. This used to be `eq_str (show (a), show (b))`,
      // which renders two constants through a fifteen-arm match to compare two
      // tags: 21M calls to `show` on one emit, 10% of every call stage 0 made,
      // allocating nothing and answering a question the tags already settle.
      $case b $match a (
      $case {$prop tag "int"} ($match b ($case {$prop tag "int"} true, $case b false)),
      $case {$prop tag "float"} ($match b ($case {$prop tag "float"} true, $case b false)),
      $case {$prop tag "str"} ($match b ($case {$prop tag "str"} true, $case b false)),
      $case {$prop tag "true"} ($match b ($case {$prop tag "true"} true, $case b false)),
      $case {$prop tag "false"} ($match b ($case {$prop tag "false"} true, $case b false)),
      $case {$prop tag "unit"} ($match b ($case {$prop tag "unit"} true, $case b false)),
      $case {$prop tag "bottom"} ($match b ($case {$prop tag "bottom"} true, $case b false)),
          $case a false
        )
    )
)

// The hash decides the common case — a mismatch — with one integer compare, and
// the structural walk runs only when the hashes agree. Since the hash is a
// coarsening of what `same` compares, equal types always agree and the answer is
// unchanged; unequal types that happen to agree simply fall through, which is why
// a weak hash is sound and only a hash that separates equal types is not.
// INTERNING.md, step 2: two interned types are the same exactly when their classes are,
// so the answer is one integer comparison — where it used to confirm an equal pair with
// a full structural walk, 320M times a self-emit. A type without a class (a prototype,
// or anything built from one) falls back to the hash guard and `same_deep`, which stays
// as the reference the class key mirrors. Its children compare through here too, so
// even the fallback is shallow wherever the children are interned.
//
// **Paranoid mode** (`set_paranoid`) is the check that the key still mirrors `same_deep`:
// every comparison computes both answers and counts where they part, and returns the
// *reference* answer, so one disagreement cannot cascade into others and the counts stay
// honest. Off, it costs one read of a cell per comparison. `stage1/paranoid.mpl` runs a
// whole compile with it on, and `zig build test-paranoid` runs that over the compiler.
// Rerun it after touching a constructor's key or adding a type kind.
$decl paranoid $mut $alloc ($union (false, true))
$decl pz_class $mut $alloc 0
$decl pz_fall  $mut $alloc 0
$decl pz_merge $mut $alloc 0
$decl pz_split $mut $alloc 0
$decl pz_val   $func ($decl x 0) x
$decl pz_bump  $func ($decl c $mut $alloc 0) $set c ($call add ($call pz_val (c), 1))

$decl set_paranoid $func ($decl on ($union (false, true))) $set paranoid on

// The counts so far: comparisons answered by class, fallbacks (a side had no class),
// class-equal pairs `same_deep` calls different — a **merge**, the direction that would
// miscompile — and `same` pairs in different classes — a **split**, slow but harmless.
$decl pz_counts $func () {
  $decl class  $call pz_val (pz_class)  $decl fallbacks $call pz_val (pz_fall)
  $decl merges $call pz_val (pz_merge)  $decl splits $call pz_val (pz_split)
}

$decl same_ref $func ($decl a proto_ty, $decl b proto_ty)
  $if ($call eq_int ($call hash_of (a), $call hash_of (b))) ($call same_deep (a, b)) false

$decl same_checked $func ($decl ca 0, $decl cb 0, $decl a proto_ty, $decl b proto_ty) {
  $decl ref  $call same_ref (a, b)
  $decl both $call and ($call lt (-1, ca), $call lt (-1, cb))
  $decl k    $if both {
    $decl n    $call pz_bump (pz_class)
    $decl eq   $call eq_int (ca, cb)
    $decl d    $if eq ($if ref 0 ($call pz_bump (pz_merge))) ($if ref ($call pz_bump (pz_split)) 0)
    $decl ret2 0
  }.ret2
      ($call pz_bump (pz_fall))
  $decl ret ref
}.ret

$decl same $func ($decl a proto_ty, $decl b proto_ty) {
  $decl ca $call cid_of (a)
  $decl cb $call cid_of (b)
  $decl ret  $if ($call P.bval (paranoid)) ($call same_checked (ca, cb, a, b))
      ($if ($call and ($call lt (-1, ca), $call lt (-1, cb))) ($call eq_int (ca, cb))
           ($call same_ref (a, b)))
}.ret

$decl ty_eq $func ($decl a proto_ty, $decl b proto_ty) $call same (a, b)

// ------------------------------------------------- unions and intersections
//
// §3.6 makes these lattice operations, so they are sets: flattened, without
// duplicates, in a fixed order. Normalising here rather than at comparison
// time is what lets `ty_eq` be a string comparison.

// Adding a member deduplicates but does not sort. Sorting here meant rendering
// every member on every insertion — quadratic in the number of members and
// linear in the size of each, which is what made checking a file full of
// recursive types run out of memory. Canonical *order* is only needed when a
// type is rendered, so `show` sorts instead.
$decl tys_insert $func ($decl t proto_ty, $decl xs tys.node)
  $if ($call mem_ty (xs, t)) xs ($call tys.cons (t, xs))

$fwd union_add

$decl union_addall $func ($decl xs tys.node, $decl acc tys.node) $match xs (
  $case {$prop tag "cons"} $call union_addall (xs.tail, $call union_add (xs.head, acc)),
  $case xs acc
)

$decl union_add $func ($decl t proto_ty, $decl acc tys.node) $match t (
  $case {$prop tag "union"}  $call union_addall (t.members, acc),
  // ⊥ is the identity for union: `T | ⊥` is `T`.
  $case {$prop tag "bottom"} acc,
  $case t ($call tys_insert (t, acc))
)

// **The member list is sorted**, by the same key `show` uses — so §7.5's
// discriminator is a function of the member *set* alone, and the layout agrees
// with what a diagnostic prints.
//
// Neither was true before. `union_addall` folds left and `union_add` conses, so
// the list came out in *reverse* source order; `show_set` sorts independently, so
// a reader saw `<a,b,c>` while the machine used c=0, b=1, a=2. Worse, nothing was
// canonical: `$union (b, a)` and `$union (a, b)` built different lists and counted
// as one type only because `same` compares sets, so whichever was interned first
// governed the other — the hazard `canon_ty` exists to paper over, and the source
// of a real miscompile where lowering numbered arms one way and the backend laid
// the union out another.
//
// Sorting is not a departure from §3.6, it *implements* it. A union is a join in a
// lattice (SPEC follows Dolan and Parreaux's Simple-sub), so it has no intrinsic
// order; §7.5 needs one to lay out a discriminator, and a canonical one is the
// only kind that makes the discriminator a property of the type. Nor does it cost
// verbatim-ness: the user writes the members and the data, never the tag, and has
// no way to observe it — a compiler choice is only a verbatim concern when it
// contradicts something that was written.
//
// What the fold does that matters is unchanged: a nested union is flattened, `⊥`
// is dropped as the identity, a repeat keeps one copy. Sorting happens after, and
// only when there are two or more members — `t_union` returns early otherwise, so
// the common join of two equal types never sorts at all.
//
// Sorted by *rendering* rather than by a structural comparator. That is one `show`
// per member, which this file warns about in hot paths — and the measurement below
// is why it stands: a structural `ty_cmp` would have to mirror all nineteen kinds
// of `same` exactly, and a single case answering "equal" for types that are not
// would lose canonicity silently. Correct and measured beats fast and subtle;
// swap it for `ty_cmp` if a profile ever asks.
$decl shty       $func ($decl k "", $decl t proto_ty) { $decl key k  $decl ty t }
$decl proto_shty $call shty ("", t_bot)
$decl shtys      $specialize P.list proto_shty

$decl shty_ins $func ($decl p proto_shty, $decl xs shtys.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call str_lt (p.key, xs.head.key)) ($call shtys.cons (p, xs))
        ($call shtys.cons (xs.head, $call shty_ins (p, $call shtys.val (xs.tail)))),
  $case xs ($call shtys.cons (p, shtys.nil))
)

$decl shty_addall $func ($decl xs tys.node, $decl acc shtys.node) $match xs (
  $case {$prop tag "cons"}
    $call shty_addall (xs.tail,
        $call shty_ins ($call shty ($call show (xs.head), xs.head), acc)),
  $case xs acc
)

$decl shty_tys $func ($decl xs shtys.node, $decl acc tys.node) $match xs (
  $case {$prop tag "cons"}
    $call shty_tys ($call shtys.val (xs.tail), $call tys.cons ($call tval (xs.head.ty), acc)),
  $case xs ($call tys.reverse (acc, tys.nil))
)

$decl sort_tys $func ($decl xs tys.node)
  $call shty_tys ($call shty_addall (xs, shtys.nil), tys.nil)

$decl t_union $func ($decl xs tys.node) {
  $decl m0 $call union_addall (xs, tys.nil)
  $decl n  $call tys.length (m0, 0)
  $decl ret $if ($call eq_int (n, 0)) t_bot
           ($if ($call eq_int (n, 1)) ($call tys.nth (m0, 0))
                ($call raw_union ($call sort_tys (m0))))
}.ret

$decl union2 $func ($decl a proto_ty, $decl b proto_ty)
  $call t_union ($call tys.cons (a, $call tys.cons (b, tys.nil)))

$fwd inter_add

$decl inter_addall $func ($decl xs tys.node, $decl acc tys.node) $match xs (
  $case {$prop tag "cons"} $call inter_addall (xs.tail, $call inter_add (xs.head, acc)),
  $case xs acc
)

$decl inter_add $func ($decl t proto_ty, $decl acc tys.node) $match t (
  $case {$prop tag "inter"} $call inter_addall (t.members, acc),
  $case t ($call tys_insert (t, acc))
)

$decl has_bottom $func ($decl xs tys.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call ty_eq (xs.head, t_bot)) true ($call has_bottom (xs.tail)),
  $case xs false
)

$decl t_inter $func ($decl xs tys.node) {
  $decl m $call inter_addall (xs, tys.nil)
  $decl n $call tys.length (m, 0)
  $decl ret $if ($call has_bottom (m)) t_bot
           ($if ($call eq_int (n, 0)) t_bot
           ($if ($call eq_int (n, 1)) ($call tys.nth (m, 0)) ($call raw_inter (m))))
}.ret

// §3.2: `Bool` is the union `true | false`. It is derived, not primitive.
$decl t_bool $call union2 (t_true, t_false)

// ----------------------------------------------------- recursive unrolling
//
// §5.5: `μR. B(R)`. Unrolling substitutes the whole type for its variable,
// which is what makes `μR.{}|{head:Int,tail:R}` and its one-step expansion the
// same type.

// Does this placeholder occur in the type? Used to keep substitution from
// rebuilding subtrees it would not change — see `subst`.
$fwd occurs

$decl occurs_tys $func ($decl xs tys.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} $if ($call occurs (xs.head, i)) true ($call occurs_tys (xs.tail, i)),
  $case xs false
)

$decl occurs_fields $func ($decl xs fields.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} $if ($call occurs (xs.head.ty, i)) true ($call occurs_fields (xs.tail, i)),
  $case xs false
)

// A type with no placeholder in it at all (`has_var`, a field read since `pv`) cannot
// hold placeholder `i`, so the walk stops there — at the top and, since this recurses
// through its children, at every subtree too. It was ~12% of a self-emit as a full walk.
$decl occurs $func ($decl t proto_ty, $decl i 0)
  $if ($call not ($call has_var (t, 0))) false ($match t (
  $case {$prop tag "var"}   $call eq_int (t.id, i),
  $case {$prop tag "block"} $call occurs_fields (t.fields, i),
  $case {$prop tag "group"} $call occurs_tys (t.items, i),
  $case {$prop tag "func"}  $if ($call occurs_tys (t.params, i)) true ($call occurs (t.result, i)),
  $case {$prop tag "ref"}   $call occurs (t.inner, i),
  $case {$prop tag "array"} $call occurs (t.elem, i),
  $case {$prop tag "union"} $call occurs_tys (t.members, i),
  $case {$prop tag "inter"} $call occurs_tys (t.members, i),
  // A binder binds no *placeholder*, so there is nothing to shadow here.
  $case {$prop tag "rec"}   $call occurs (t.body, i),
  $case {$prop tag "over"}  $call occurs_tys (t.cands, i),
  $case {$prop tag "trait"} $call occurs_fields (t.members, i),
  $case {$prop tag "with"}  $call occurs (t.base, i),
  $case t false
))

// Every rewriting of a type is the same walk: rebuild each node, count the
// binders passed on the way down, and do something at a leaf. Writing that walk
// four times — once to substitute a placeholder, once to renumber, once to
// substitute a bound variable, once to bind one — costs four 12-arm matches over
// the recursive type, and this file type-checks itself, so each one is paid for
// twice. One walk with the leaf case parameterised does the lot.
//
// `d` is the number of binders enclosing the node being rewritten, which is at
// once the cutoff for renumbering, the index the bound variable being replaced
// now has, and the index a placeholder becomes when the knot is tied.
$decl rop $func ($decl k "", $decl n 0, $decl r proto_ty)
  { $decl kind k  $decl i n  $decl ty r }

// Replace the placeholder `i` by `r`. `r` is a solved type and therefore
// closed, so passing under a binder leaves it alone.
$decl rop_var   $func ($decl i 0, $decl r proto_ty) $call rop ("var", i, r)
// Add `n` to every bound variable at index `d` or above.
$decl rop_shift $func ($decl n 0)                   $call rop ("shift", n, t_bot)
// Replace the bound variable now at index `d` by `r`.
$decl rop_bnd   $func ($decl r proto_ty)            $call rop ("bnd", 0, r)
// Turn the placeholder `i` into the bound variable of a binder about to be
// wrapped around the whole type — §5.5's knot, tied.
$decl rop_abs   $func ($decl i 0)                   $call rop ("abs", i, t_bot)

// Replace every subterm equal to `r` by the bound variable of a binder about to be wrapped
// around the whole type — §4.13's "every occurrence of `e`'s type abstracted as `Self`".
// Marked by `i = -9` rather than by its kind, so the check at every node is one integer
// compare and the other rewrites pay nothing for it.
$decl rop_abst  $func ($decl r proto_ty)            $call rop ("abst", -9, r)

$decl proto_rop $call rop ("", 0, t_bot)

$fwd remap

$decl remap_tys $func ($decl xs tys.node, $decl o proto_rop, $decl d 0,
    $decl acc tys.node) $match xs (
  $case {$prop tag "cons"}
    $call remap_tys (xs.tail, o, d, $call tys.cons ($call remap (xs.head, o, d), acc)),
  $case xs ($call tys.reverse (acc, tys.nil))
)

$decl remap_fields $func ($decl xs fields.node, $decl o proto_rop, $decl d 0,
    $decl acc fields.node) $match xs (
  $case {$prop tag "cons"}
    $call remap_fields (xs.tail, o, d,
        $call fields.cons ($call field (xs.head.name, $call remap (xs.head.ty, o, d)), acc)),
  $case xs ($call fields.reverse (acc, fields.nil))
)

$decl remap_props $func ($decl xs props.node, $decl o proto_rop, $decl d 0,
    $decl acc props.node) $match xs (
  $case {$prop tag "cons"}
    $call remap_props (xs.tail, o, d,
        $call props.cons ($call prop_typed (xs.head.name, xs.head.value,
            $call remap (xs.head.ty, o, d)), acc)),
  $case xs ($call props.reverse (acc, props.nil))
)

$fwd remap_go

$decl remap $func ($decl t proto_ty, $decl o proto_rop, $decl d 0)
  $if ($call eq_int (o.i, -9))
      ($if ($call same (t, o.ty)) ($call tval ($call t_bnd (d))) ($call remap_go (t, o, d)))
      ($call remap_go (t, o, d))

$decl remap_go $func ($decl t proto_ty, $decl o proto_rop, $decl d 0) $match t (
  $case {$prop tag "var"}
    $if ($call eq_int (t.id, o.i))
        ($if ($call eq_str (o.kind, "var")) o.ty
        ($if ($call eq_str (o.kind, "abs")) ($call t_bnd (d)) t))
        t,
  $case {$prop tag "bnd"}
    $if ($call eq_str (o.kind, "shift"))
        ($if ($call lt (t.idx, d)) t ($call t_bnd ($call add (t.idx, o.i))))
    ($if ($call eq_str (o.kind, "bnd"))
         // The replacement was written outside the `d` binders it is landing
         // under, so its own free bound variables move up by `d`.
         ($if ($call eq_int (t.idx, d))
              ($if ($call eq_int (d, 0)) o.ty ($call remap (o.ty, $call rop_shift (d), 0)))
              t)
         t),
  $case {$prop tag "rec"}   $call t_rec ($call remap (t.body, o, $call add (d, 1))),
  // A binder: `Self` is index 0 inside, so everything else moves up by one.
  $case {$prop tag "trait"}
    $call t_trait_q ($call remap_fields (t.members, o, $call add (d, 1), fields.nil), t.frame,
        t.qual),
  // A prop's `ty` is rebuilt too. It is outside the type's identity (§5.1 compares a
  // prop's value), but §6's conformance reads it — so a bound variable left in it by
  // `unroll` would make a recursive block fail to conform to its own trait.
  $case {$prop tag "block"}
    $call raw_block ($call remap_fields (t.fields, o, d, fields.nil),
        $call remap_props (t.props, o, d, props.nil)),
  $case {$prop tag "group"} $call t_group ($call remap_tys (t.items, o, d, tys.nil)),
  $case {$prop tag "func"}
    $call t_func_rm ($call remap_tys (t.params, o, d, tys.nil), $call remap (t.result, o, d),
        t.frame, t.rmut),
  $case {$prop tag "ref"}   $call t_ref_k (t.qual, $call remap (t.inner, o, d), t.kind),
  $case {$prop tag "array"} $call t_array ($call remap (t.elem, o, d)),
  $case {$prop tag "union"} $call t_union ($call remap_tys (t.members, o, d, tys.nil)),
  $case {$prop tag "inter"} $call t_inter ($call remap_tys (t.members, o, d, tys.nil)),
  $case {$prop tag "over"}  $call t_over ($call remap_tys (t.cands, o, d, tys.nil)),
  $case {$prop tag "with"}
    $call t_with ($call remap (t.base, o, d), $call remap_props (t.props, o, d, props.nil)),
  $case t t
)

// Substitution rebuilds every node it walks, and rebuilding a union re-runs its
// normalisation — so walking a subtree the placeholder does not even occur in is
// pure waste, and quadratic waste at that. Checking first costs one allocation-
// free traversal and lets the unchanged subtree be shared.
$decl subst $func ($decl t proto_ty, $decl i 0, $decl r proto_ty)
  $if ($call not ($call occurs (t, i))) t ($call remap (t, $call rop_var (i, r), 0))

$decl subst_bnd $func ($decl t proto_ty, $decl k 0, $decl r proto_ty)
  $call remap (t, $call rop_bnd (r), k)



// §5.3a: "A type is **frame-bound** if a frame reference occurs anywhere in it
// — directly, in a field, behind another reference, or in a closure's
// captures." A structural check on a type already inferred: no lifetime
// variables, no annotations, nothing to solve.
//
// An *allocated* reference is still inspected, because what it holds may be
// frame storage — `&^(&T)` outlives its scope and still points at something
// that does not.
$fwd frame_bound

$decl frame_bound_tys $func ($decl xs tys.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call frame_bound (xs.head, 0)) true ($call frame_bound_tys (xs.tail, 0)),
  $case xs false
)

$decl frame_bound_fields $func ($decl xs fields.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call frame_bound (xs.head.ty, 0)) true ($call frame_bound_fields (xs.tail, 0)),
  $case xs false
)

$decl frame_bound $func ($decl t proto_ty, $decl i 0) $match t (
  $case {$prop tag "ref"}
    $if ($call is_alloc (t.kind)) ($call frame_bound (t.inner, 0)) true,
  $case {$prop tag "block"} ($call frame_bound_fields (t.fields, 0)),
  $case {$prop tag "group"} ($call frame_bound_tys (t.items, 0)),
  // §7.3 keeps captures out of the type, so the flag is the only record of
  // them. The parameters and the result are frame-bound or not on their own
  // account, and are checked where they stand.
  $case {$prop tag "func"}  t.frame,
  $case {$prop tag "array"} ($call frame_bound (t.elem, 0)),
  $case {$prop tag "union"} ($call frame_bound_tys (t.members, 0)),
  $case {$prop tag "inter"} ($call frame_bound_tys (t.members, 0)),
  $case {$prop tag "rec"}   ($call frame_bound (t.body, 0)),
  $case {$prop tag "over"}  ($call frame_bound_tys (t.cands, 0)),
  // §6: a trait object takes the kind of what it refers to, and like a closure's
  // captures that is not in the type, so the flag is the whole record of it.
  $case {$prop tag "trait"} t.frame,
  $case {$prop tag "with"}  ($call frame_bound (t.base, 0)),
  $case t false
)

// The frame reference that makes a type frame-bound, for the diagnostic. A
// whole inferred type can be thousands of characters (§10.9: field order is
// the interface, so nothing is elided), and printing one to say "there is a
// `&` in here" helps nobody. This finds the offending reference so the message
// can show that instead.
$fwd first_frame

$decl first_frame_tys $func ($decl xs tys.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} {
    $decl f   $call first_frame (xs.head, 0)
    $decl ret $if ($call same (f, t_bot)) ($call first_frame_tys (xs.tail, 0)) f
  }.ret,
  $case xs t_bot
)

$decl first_frame_fields $func ($decl xs fields.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} {
    $decl f   $call first_frame (xs.head.ty, 0)
    $decl ret $if ($call same (f, t_bot)) ($call first_frame_fields (xs.tail, 0)) f
  }.ret,
  $case xs t_bot
)

$decl first_frame $func ($decl t proto_ty, $decl i 0) $match t (
  $case {$prop tag "ref"}
    $if ($call is_alloc (t.kind)) ($call first_frame (t.inner, 0)) t,
  // §7.3 keeps a closure's captures out of its type, so there is no reference
  // in here to point at — the flag is the whole record of it, and the type
  // itself is the most specific thing there is to name.
  $case {$prop tag "func"}  $if t.frame t t_bot,
  $case {$prop tag "block"} ($call first_frame_fields (t.fields, 0)),
  $case {$prop tag "group"} ($call first_frame_tys (t.items, 0)),
  $case {$prop tag "array"} ($call first_frame (t.elem, 0)),
  $case {$prop tag "union"} ($call first_frame_tys (t.members, 0)),
  $case {$prop tag "inter"} ($call first_frame_tys (t.members, 0)),
  $case {$prop tag "rec"}   ($call first_frame (t.body, 0)),
  $case {$prop tag "over"}  ($call first_frame_tys (t.cands, 0)),
  $case {$prop tag "trait"} $if t.frame t t_bot,
  $case {$prop tag "with"}  ($call first_frame (t.base, 0)),
  $case t t_bot
)

$decl close_var $func ($decl t proto_ty, $decl i 0)
  $call t_rec ($call remap (t, $call rop_abs (i), 0))

// §5.5 makes `μR. B(R)` and its one-step unrolling the same type, and every
// structural question about a type has to ask `unroll` first — so it is asked
// constantly. Answering means rebuilding the body with the binder substituted,
// and a big recursive type is a great deal of list: emitting `types.mpl`,
// 5,769 unrollings rebuilt **149 MB**, which was 68% of everything that run
// allocated and 46% of it in `cons` alone.
//
// A `rec` node is immutable, so its unrolling never changes. Keyed by `same`,
// which is what type identity means here anyway (§5.5 makes alpha-equivalence
// structural), so handing back the entry built for a structurally equal `rec`
// is handing back the same type.
$decl unroll_ent   $func ($decl k proto_ty, $decl v proto_ty) { $decl key k  $decl val v }
$decl proto_unroll_ent $call unroll_ent (t_bot, t_bot)
$decl unrolls      $specialize P.list proto_unroll_ent
$decl unroll_cache $mut $alloc unrolls.node

$decl unroll_hit $func ($decl ok P.boolean, $decl v proto_ty) { $decl hit ok  $decl val v }

$decl unroll_find $func ($decl xs unrolls.node, $decl k proto_ty) $match xs (
  $case {$prop tag "cons"}
    $if ($call same (xs.head.key, k))
        ($call unroll_hit (($union (true, false)), $call tval (xs.head.val)))
        ($call unroll_find (xs.tail, k)),
  $case xs ($call unroll_hit (($union (false, true)), t_bot))
)

$decl unroll $func ($decl t proto_ty) $match t (
  $case {$prop tag "rec"} {
    $decl f $call unroll_find (unroll_cache, t)
    $decl ret $if f.hit ($call tval (f.val)) {
      $decl u $call subst_bnd (t.body, 0, t)
      $decl s $set unroll_cache ($call unrolls.cons ($call unroll_ent (t, u),
                  $call unrolls.val (unroll_cache)))
      $decl ret2 u
    }.ret2
  }.ret,
  $case t t
)

// §5.5: recursion must pass through storage.
//
// `μR.B` has a layout only if every occurrence of `R` is pointer-represented: a
// reference, an array element, or anywhere inside a function type — a function
// is two words whatever its signature, since §7.3 keeps captures out of the
// type. An occurrence held inline by a block field, a group element or a union
// member makes `size(R)` depend on itself, and no layout exists. The fix is
// `$new` at that position, which is the same rule as everywhere else: storage
// exists only where it was written.
$fwd unguarded

$decl unguarded_tys $func ($decl xs tys.node, $decl k 0) $match xs (
  $case {$prop tag "cons"} $if ($call unguarded (xs.head, k)) true ($call unguarded_tys (xs.tail, k)),
  $case xs false
)

$decl unguarded_fields $func ($decl xs fields.node, $decl k 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call unguarded (xs.head.ty, k)) true ($call unguarded_fields (xs.tail, k)),
  $case xs false
)

$decl unguarded $func ($decl t proto_ty, $decl k 0) $match t (
  $case {$prop tag "bnd"}   $call eq_int (t.idx, k),
  // Pointer-represented, so the recursion is bounded from here down.
  $case {$prop tag "ref"}   false,
  $case {$prop tag "array"} false,
  $case {$prop tag "func"}  false,
  // A trait object is a reference (§6), so it guards too.
  $case {$prop tag "trait"} false,
  // Props have no layout, so only the base can hold the variable inline.
  $case {$prop tag "with"}  $call unguarded (t.base, k),
  // A nested binder shifts the index of the one being tested.
  $case {$prop tag "rec"}   $call unguarded (t.body, $call add (k, 1)),
  $case {$prop tag "block"} $call unguarded_fields (t.fields, k),
  $case {$prop tag "group"} $call unguarded_tys (t.items, k),
  $case {$prop tag "union"} $call unguarded_tys (t.members, k),
  $case {$prop tag "inter"} $call unguarded_tys (t.members, k),
  $case {$prop tag "over"}  $call unguarded_tys (t.cands, k),
  $case t false
)

// True when `t` is a recursive type reached without passing through storage.
$decl unguarded_rec $func ($decl t proto_ty) $match t (
  $case {$prop tag "rec"} $call unguarded (t.body, 0),
  $case t false
)

// ------------------------------------------------- the comparison state
//
// Amadio–Cardelli: a goal `A <: B` reached again under itself is *assumed*
// rather than re-proved, which is what makes an equirecursive type terminate.
// The assumption set holds goal pairs, and a pair is recognised by `same` —
// which works because binders are de Bruijn indices, so the unrolling of a
// recursive type is literally the same value whichever route reached it.
//
// A pair is only recorded where a goal can recur, which is only under a `rec`.
// Recording on every step was measured as the checker's dominant cost.

$decl goal_ent   $func ($decl x proto_ty, $decl y proto_ty) { $decl l x  $decl r y }
$decl proto_goal $call goal_ent (t_bot, t_bot)
$decl goal_list  $specialize P.list proto_goal

$decl actx $func ($decl gs goal_list.node) { $decl goals gs }

$decl proto_actx $call actx (goal_list.nil)

$decl with_goal $func ($decl st proto_actx, $decl x proto_ty, $decl y proto_ty)
  $call actx ($call goal_list.cons ($call goal_ent (x, y), st.goals))

// `and` is strict (§8), and the left components differ far more often than the
// right ones, so the cheap comparison has to be the one that can skip the other.
$decl mem_goal $func ($decl gs goal_list.node, $decl x proto_ty, $decl y proto_ty) $match gs (
  $case {$prop tag "cons"}
    $if ($call same (gs.head.l, x))
        ($if ($call same (gs.head.r, y)) true ($call mem_goal (gs.tail, x, y)))
        ($call mem_goal (gs.tail, x, y)),
  $case gs false
)

// --------------------------------------------------------------- subtyping
//
// §5.1. `sub` is coinductive: before descending it records the goal, and a
// repeated goal is assumed to hold. That is what terminates on recursive types
// — the assumption is discharged by the structure around it.

// Used by projection typing, not by subtyping: §5.1 matches fields by position
// now, but `e.name` still looks a field up by name (§4.6).
$decl find_field $func ($decl xs fields.node, $decl n "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, n)) ($call field (n, xs.head.ty)) ($call find_field (xs.tail,
        n)),
  $case xs ($call field ("", t_bot))
)

// Does `t` mention the bound variable at index `k`, counting binders on the way down?
// §6's object safety asks it of a member's type with `k = 0`, which is `Self`.
$fwd mentions_bnd

$decl mentions_tys $func ($decl xs tys.node, $decl k 0) $match xs (
  $case {$prop tag "cons"} $if ($call mentions_bnd ($call tval (xs.head), k)) true
      ($call mentions_tys (xs.tail, k)),
  $case xs false
)

$decl mentions_fields $func ($decl xs fields.node, $decl k 0) $match xs (
  $case {$prop tag "cons"} $if ($call mentions_bnd ($call tval (xs.head.ty), k)) true
      ($call mentions_fields (xs.tail, k)),
  $case xs false
)

$decl mentions_props $func ($decl xs props.node, $decl k 0) $match xs (
  $case {$prop tag "cons"} $if ($call mentions_bnd ($call tval (xs.head.ty), k)) true
      ($call mentions_props (xs.tail, k)),
  $case xs false
)

$decl mentions_bnd $func ($decl t proto_ty, $decl k 0) $match t (
  $case {$prop tag "bnd"}   $call eq_int (t.idx, k),
  $case {$prop tag "block"}
    $if ($call mentions_fields (t.fields, k)) true ($call mentions_props (t.props, k)),
  $case {$prop tag "group"} $call mentions_tys (t.items, k),
  $case {$prop tag "func"}
    $if ($call mentions_tys (t.params, k)) true ($call mentions_bnd (t.result, k)),
  $case {$prop tag "ref"}   $call mentions_bnd (t.inner, k),
  $case {$prop tag "array"} $call mentions_bnd (t.elem, k),
  $case {$prop tag "union"} $call mentions_tys (t.members, k),
  $case {$prop tag "inter"} $call mentions_tys (t.members, k),
  $case {$prop tag "over"}  $call mentions_tys (t.cands, k),
  $case {$prop tag "rec"}   $call mentions_bnd (t.body, $call add (k, 1)),
  $case {$prop tag "trait"} $call mentions_fields (t.members, $call add (k, 1)),
  $case {$prop tag "with"}
    $if ($call mentions_bnd (t.base, k)) true ($call mentions_props (t.props, k)),
  $case t false
)

// Does placeholder `i` occur anywhere in `t`, a prop's type included? `occurs` deliberately
// skips props' types — they are outside a block's identity — but a prototype that names
// itself only in a member's parameter (§4.10's "another value of its own type") has to
// close into a μ too, or `$traitsof` would find a placeholder where `Self` should be.
$fwd occurs_all

$decl occurs_all_tys $func ($decl xs tys.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} $if ($call occurs_all ($call tval (xs.head), i)) true
      ($call occurs_all_tys (xs.tail, i)),
  $case xs false
)

$decl occurs_all_fields $func ($decl xs fields.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} $if ($call occurs_all ($call tval (xs.head.ty), i)) true
      ($call occurs_all_fields (xs.tail, i)),
  $case xs false
)

$decl occurs_all_props $func ($decl xs props.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} $if ($call occurs_all ($call tval (xs.head.ty), i)) true
      ($call occurs_all_props (xs.tail, i)),
  $case xs false
)

$decl occurs_all $func ($decl t proto_ty, $decl i 0) $match t (
  $case {$prop tag "var"}   $call eq_int (t.id, i),
  $case {$prop tag "block"}
    $if ($call occurs_all_fields (t.fields, i)) true ($call occurs_all_props (t.props, i)),
  $case {$prop tag "group"} $call occurs_all_tys (t.items, i),
  $case {$prop tag "func"}
    $if ($call occurs_all_tys (t.params, i)) true ($call occurs_all (t.result, i)),
  $case {$prop tag "ref"}   $call occurs_all (t.inner, i),
  $case {$prop tag "array"} $call occurs_all (t.elem, i),
  $case {$prop tag "union"} $call occurs_all_tys (t.members, i),
  $case {$prop tag "inter"} $call occurs_all_tys (t.members, i),
  $case {$prop tag "over"}  $call occurs_all_tys (t.cands, i),
  $case {$prop tag "rec"}   $call occurs_all (t.body, i),
  $case {$prop tag "trait"} $call occurs_all_fields (t.members, i),
  $case {$prop tag "with"}
    $if ($call occurs_all (t.base, i)) true ($call occurs_all_props (t.props, i)),
  $case t false
)

// Whether `i` occurs in the props of `t` itself, or of a block member when `t` is a union —
// where a prototype naming itself in a member's parameter puts it (§4.10). `occurs` cannot
// see it, since a prop is not layout; walking every type `close_rec` closes for it costs 5%
// of a self-emit, and nothing deeper is a prototype's own prop.
$decl occurs_own_props_tys $func ($decl xs tys.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} {
    $decl h   $call tval (xs.head)
    $decl ret $match h (
        $case {$prop tag "block"}
          $if ($call occurs_all_props (h.props, i)) true ($call occurs_own_props_tys (xs.tail, i)),
        $case h ($call occurs_own_props_tys (xs.tail, i))
      )
  }.ret,
  $case xs false
)

$decl occurs_own_props $func ($decl t proto_ty, $decl i 0) $match t (
  $case {$prop tag "block"} $call occurs_all_props (t.props, i),
  $case {$prop tag "union"} $call occurs_own_props_tys ($call tys.val (t.members), i),
  $case t false
)
// A member's type with `self` for `Self` (§6): conformance instantiates it at the
// conforming type, and a projection off a trait object at the trait itself — which is
// §5.5's unrolling, the reason a trait is a binder. Bottom when there is no such member.
$decl trait_member $func ($decl t proto_ty, $decl nm "", $decl self proto_ty) $match t (
  $case {$prop tag "trait"} {
    $decl f   $call find_field ($call fields.val (t.members), nm)
    $decl ret $if ($call eq_str (f.name, "")) t_bot ($call subst_bnd ($call tval (f.ty), 0, self))
  }.ret,
  $case t t_bot
)

$decl find_prop $func ($decl xs props.node, $decl n "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, n)) xs.head ($call find_prop (xs.tail, n)),
  $case xs ($call prop_entry ("", $call cv_opaque (-1)))
)

// §4.12: `$impl`'s type — the base's with the override's props added. A block takes them
// into the block, since a block's props are where §5.1 and §6 look; anything else is a
// `with`, and an `$impl` over one adds to the same set rather than nesting.
$decl impl_ty $func ($decl b proto_ty, $decl ps props.node) {
  $decl u   $call tval ($call unroll (b))
  $decl ret $match u (
      $case {$prop tag "block"}
        ($call tval ($call t_block ($call fields.val (u.fields),
            $call props.reverse (ps, $call props.val (u.props))))),
      $case {$prop tag "with"}
        ($call tval ($call t_with ($call tval (u.base),
            $call props.reverse (ps, $call props.val (u.props))))),
      $case u ($call tval ($call t_with (b, ps)))
    )
}.ret

// Whether a type already binds `nm` — a field or a prop — which an `$impl` adding a prop of
// that name would bind a second time (§4.1).
$decl binds_name $func ($decl b proto_ty, $decl nm "") {
  $decl u   $call tval ($call unroll (b))
  $decl ret $match u (
      $case {$prop tag "block"}
        $if ($call eq_str (($call find_field ($call fields.val (u.fields), nm)).name, ""))
            ($call not ($call eq_str (($call find_prop ($call props.val (u.props), nm)).name,
                "")))
            true,
      $case {$prop tag "with"}
        ($call not ($call eq_str (($call find_prop ($call props.val (u.props), nm)).name, ""))),
      $case u false
    )
}.ret

// The layout under a `with` (§4.12): what indexing and fields see.
$decl with_base $func ($decl t proto_ty) $match t (
  $case {$prop tag "with"} ($call tval (t.base)),
  $case t t
)

$fwd sub_seen

$decl subs_all_left $func ($decl xs tys.node, $decl b proto_ty, $decl st proto_actx) $match xs (
  $case {$prop tag "cons"}
    $if ($call sub_seen (xs.head, b, st)) ($call subs_all_left (xs.tail, b, st)) false,
  $case xs true
)

// §5.1: "for every prop of `T`, `S` has the same prop with the **same value**."
// Two blocks carrying *different* tags can therefore never be related, and that
// is decidable by reading one prop. Without this, matching a block against a
// seventeen-member union descends into all seventeen.
$decl tag_of $func ($decl t proto_ty) $match t (
  $case {$prop tag "block"} {
    $decl p  $call find_prop (t.props, "tag")
    $decl cv p.value
    $decl ret $match cv (
        $case {$prop tag "cstr"} cv.v,
        $case cv ""
      )
  }.ret,
  $case t ""
)

$decl kind_of $func ($decl t proto_ty) $match t (
  $case {$prop tag "rec"}    "rec",
  $case {$prop tag "var"}    "var",
  $case {$prop tag "bnd"}    "bnd",
  $case {$prop tag "union"}  "union",
  $case {$prop tag "inter"}  "inter",
  $case {$prop tag "block"}  "block",
  $case {$prop tag "group"}  "group",
  $case {$prop tag "func"}   "func",
  $case {$prop tag "ref"}    "ref",
  $case {$prop tag "array"}  "array",
  $case {$prop tag "trait"}  "trait",
  $case {$prop tag "with"}   "with",
  $case {$prop tag "bottom"} "!",
  $case t ($call show (t))
)

$decl desc $func ($decl t proto_ty) {
  $decl k  $call kind_of (t)
  $decl tg $call tag_of (t)
  $decl ret $if ($call eq_str (tg, "")) k
                ($call concat (k, $call concat ("[", $call concat (tg, "]"))))
}.ret

// `&` plus a one-word description of what it points at — enough to recognise
// the storage without rendering the whole type.
$decl show_frame $func ($decl t proto_ty) $match t (
  $case {$prop tag "ref"}
    $call concat ($call show_qual (t.qual, t.kind), $call desc (t.inner)),
  $case {$prop tag "func"}  "a reference captured by a closure",
  $case {$prop tag "trait"} "a trait object referring to frame storage",
  $case t ($call desc (t))
)

$decl tags_differ $func ($decl a proto_ty, $decl b proto_ty) {
  $decl ta $call tag_of (a)
  $decl tb $call tag_of (b)
  $decl ret $call and ($call and ($call not ($call eq_str (ta, "")),
                                  $call not ($call eq_str (tb, ""))),
                       $call not ($call eq_str (ta, tb)))
}.ret

$decl subst_members $func ($decl xs tys.node, $decl r proto_ty, $decl acc tys.node) $match xs (
  $case {$prop tag "cons"}
    $call subst_members (xs.tail, r, $call tys.cons ($call subst_bnd (xs.head, 0, r), acc)),
  $case xs acc
)

$decl subs_any_right $func ($decl a proto_ty, $decl ys tys.node, $decl st proto_actx) $match ys (
  $case {$prop tag "cons"}
    $if ($call tags_differ (a, ys.head)) ($call subs_any_right (a, ys.tail, st))
    ($if ($call sub_seen (a, ys.head, st)) true ($call subs_any_right (a, ys.tail, st))),
  $case ys false
)

$decl subs_all_right $func ($decl a proto_ty, $decl ys tys.node, $decl st proto_actx) $match ys (
  $case {$prop tag "cons"}
    $if ($call sub_seen (a, ys.head, st)) ($call subs_all_right (a, ys.tail, st)) false,
  $case ys true
)

$decl subs_any_left $func ($decl xs tys.node, $decl b proto_ty, $decl st proto_actx) $match xs (
  $case {$prop tag "cons"}
    $if ($call sub_seen (xs.head, b, st)) true ($call subs_any_left (xs.tail, b, st)),
  $case xs false
)

// Elementwise, same arity (§5.1 for groups).
$decl subs_zip $func ($decl xs tys.node, $decl ys tys.node, $decl st proto_actx) $match xs (
  $case {$prop tag "cons"} $match ys (
      $case {$prop tag "cons"}
        $if ($call sub_seen (xs.head, ys.head, st)) ($call subs_zip (xs.tail, ys.tail, st)) false,
      $case ys false
    ),
  $case xs ($call tys.is_nil (ys))
)

// Contravariant in parameters (§5.1 for functions): the *argument* side flips.
$decl subs_zip_flipped $func ($decl xs tys.node, $decl ys tys.node, $decl st proto_actx) $match xs (
  $case {$prop tag "cons"} $match ys (
      $case {$prop tag "cons"}
        $if ($call sub_seen (ys.head, xs.head, st)) ($call subs_zip_flipped (xs.tail, ys.tail,
            st)) false,
      $case ys false
    ),
  $case xs ($call tys.is_nil (ys))
)

// Prefix and depth (§5.1): `T`'s fields must be an ordered *prefix* of `S`'s —
// same names at the same positions, each at a subtype. Running out of required
// fields means the prefix is satisfied; running out of `S`'s fields first means
// `T` demands more than `S` has.
$decl sub_fields $func ($decl s fields.node, $decl want fields.node,
    $decl st proto_actx) $match want (
  $case {$prop tag "cons"} $match s (
      $case {$prop tag "cons"}
        $if ($call eq_str (s.head.name, want.head.name))
            ($if ($call sub_seen (s.head.ty, want.head.ty, st))
                 ($call sub_fields (s.tail, want.tail, st))
                 false)
            false,
      $case s false
    ),
  $case want true
)

// §5.1: "for every prop of `T`, `S` has the same prop with the **same value**."
// This is the tag test, at the type level.
$decl sub_props $func ($decl s props.node, $decl want props.node) $match want (
  $case {$prop tag "cons"} {
    $decl p $call find_prop (s, want.head.name)
    $decl ret $if ($call eq_str (p.name, ""))
        false
        ($if ($call cv_eq (p.value, want.head.value)) ($call sub_props (s, want.tail)) false)
  }.ret,
  $case want true
)

// §5.3: `&T <: &mut T <: &const T`. `&T` and `&mut T` are invariant in `T`;
// only `&const T` is covariant, which is why structural width subtyping on
// storage is available exclusively through read-only views.
// Parameters are declared at the *ref* shape, not at the whole type union:
// §3.4 makes a default fix its parameter's type, and a `$match` arm's narrowing
// does not cross a call boundary. `$call t_ref …` is the example expression
// whose type is exactly the member this function handles.
$decl proto_ref $call t_ref ("", proto_ty)

// §5.3: "Kind is a second dimension, orthogonal to the qualifier: `&^T <: &T`."
// Allocated storage outlives every scope, so it goes wherever frame storage
// does and never the reverse.
$decl sub_kind $func ($decl a "", $decl b "")
  $if ($call is_alloc (b)) ($call is_alloc (a)) true

$decl sub_ref $func ($decl a proto_ref, $decl b proto_ref, $decl st proto_actx)
  $if ($call not ($call sub_kind (a.kind, b.kind))) false
  ($if ($call eq_str (b.qual, "const")) ($call sub_seen (a.inner, b.inner, st))
  ($if ($call eq_str (b.qual, "mut"))
       ($call and ($call not ($call eq_str (a.qual, "const")), $call ty_eq (a.inner, b.inner)))
       ($call and ($call eq_str (a.qual, ""), $call ty_eq (a.inner, b.inner)))))

// §6: a trait object's type is a supertype of every type that conforms to it. A member
// is met by a prop of the same name whose *type* — `ty`, which `same_props` ignores — is a
// subtype of the member's with the conforming type for `Self`. Values are never compared:
// a trait says what a value can be used for, not what it is (a tag is `$match`'s concern).
$decl conforms $func ($decl ps props.node, $decl ms fields.node, $decl self proto_ty,
                      $decl b proto_ty, $decl st proto_actx) $match ms (
  $case {$prop tag "cons"} {
    $decl p   $call find_prop (ps, ms.head.name)
    $decl ret $if ($call eq_str (p.name, "")) false
        ($if ($call sub_seen ($call tval (p.ty), $call trait_member (b, ms.head.name, self), st))
             ($call conforms (ps, $call fields.val (ms.tail), self, b, st)) false)
  }.ret,
  $case ms true
)

// A trait against a trait: width, unordered. `Self` stays the bound variable on both
// sides — both views describe one referent, so it is one abstract type, not two.
$decl members_sub $func ($decl xs fields.node, $decl ms fields.node, $decl st proto_actx)
    $match ms (
  $case {$prop tag "cons"} {
    $decl f   $call find_field (xs, ms.head.name)
    $decl ret $if ($call eq_str (f.name, "")) false
        ($if ($call sub_seen ($call tval (f.ty), $call tval (ms.head.ty), st))
             ($call members_sub (xs, $call fields.val (ms.tail), st)) false)
  }.ret,
  $case ms true
)

$decl is_trait $func ($decl t proto_ty) $match t ($case {$prop tag "trait"} true, $case t false)

// §6: a mutable trait object stands where a read-only one is expected, never the reverse —
// §5.3's `&mut T <: &const T` for the referent it is.
$decl sub_tqual $func ($decl a "", $decl b "") $if ($call eq_str (b, "")) true ($call eq_str (a, b))

// The same trait read-only, which is what a value conforming by itself is checked against:
// the value is not storage, so only the read-only object can be made from it.
$decl trait_ro $func ($decl b proto_ty) $match b (
  $case {$prop tag "trait"} ($call tval ($call t_trait_fr ($call fields.val (b.members), b.frame))),
  $case b b
)

$decl sub_trait $func ($decl a proto_ty, $decl b proto_ty, $decl st proto_actx) $match b (
  $case {$prop tag "trait"} $match a (
      $case {$prop tag "trait"}
        $if ($call sub_tqual (a.qual, b.qual))
            ($call members_sub ($call fields.val (a.members), $call fields.val (b.members), st))
            false,
      $case {$prop tag "block"}
        $if ($call eq_str (b.qual, ""))
            ($call conforms ($call props.val (a.props), $call fields.val (b.members), a, b, st))
            false,
      $case {$prop tag "with"}
        $if ($call eq_str (b.qual, ""))
            ($call conforms ($call props.val (a.props), $call fields.val (b.members), a, b, st))
            false,
      // A trait object refers to its value (§6), so a reference to a conforming value
      // conforms — the coercion takes the pointer it already is. Only `$mut` storage
      // makes a mutable one.
      $case {$prop tag "ref"}
        $if ($call sub_tqual (a.qual, b.qual))
            ($call sub_seen ($call tval (a.inner), $call trait_ro (b), st)) false,
      $case {$prop tag "inter"} $call subs_any_left (a.members, b, st),
      $case a false
    ),
  $case b false
)

$decl sub_step $func ($decl a proto_ty, $decl b proto_ty, $decl st proto_actx) $match a (
  // §3.6: ⊥ is a subtype of everything.
  $case {$prop tag "bottom"} true,
  // Assume the goal, then unroll one step (§5.5 is equirecursive, so the
  // unrolled type *is* the folded one). The assumption is what stops the
  // unrolling — a type whose expansion reaches the same goal is proved, not
  // re-entered. A placeholder is left to fall through to `false`: it is
  // unrelated to everything but itself, which `same` decided already.
  $case {$prop tag "rec"}
    $if ($call mem_goal (st.goals, a, b)) true
        ($call sub_seen ($call unroll (a), b, $call with_goal (st, a, b))),
  $case {$prop tag "union"}  $call subs_all_left (a.members, b, st),
  $case a $match b (
      $case {$prop tag "rec"}
        $if ($call mem_goal (st.goals, a, b)) true
            ($call sub_seen (a, $call unroll (b), $call with_goal (st, a, b))),
      $case {$prop tag "union"} $call subs_any_right (a, b.members, st),
      $case {$prop tag "inter"} $call subs_all_right (a, b.members, st),
      $case b $if ($call is_trait (b)) ($call sub_trait (a, b, st)) ($match a (
          $case {$prop tag "inter"} $call subs_any_left (a.members, b, st),
          // §4.12 by §5.1's block rule: the props are an addition, so forgetting some is a
          // subtype — down to the base itself — and the ones kept must keep their values.
          $case {$prop tag "with"} $match b (
              $case {$prop tag "with"}
                $if ($call sub_seen (a.base, b.base, st)) ($call sub_props (a.props, b.props))
                    false,
              $case b ($call sub_seen (a.base, b, st))
            ),
          $case {$prop tag "block"} $match b (
              $case {$prop tag "block"}
                $if ($call sub_fields (a.fields, b.fields, st))
                    ($call sub_props (a.props, b.props)) false,
              $case b false
            ),
          $case {$prop tag "group"} $match b (
              $case {$prop tag "group"} $call subs_zip (a.items, b.items, st),
              $case b false
            ),
          $case {$prop tag "func"} $match b (
              // §4.10: a function that needs a mutable receiver cannot stand where one that
              // does not is expected — it would be called through a read-only one.
              $case {$prop tag "func"}
                $if ($call and (a.rmut, $call not (b.rmut))) false
                ($if ($call subs_zip_flipped (a.params, b.params, st))
                     ($call sub_seen (a.result, b.result, st)) false),
              $case b false
            ),
          $case {$prop tag "ref"} $match b (
              $case {$prop tag "ref"} $call sub_ref (a, b, st),
              $case b false
            ),
          $case {$prop tag "array"} $match b (
              // Element type is invariant: an array's references are `&mut`.
              $case {$prop tag "array"} $call ty_eq (a.elem, b.elem),
              $case b false
            ),
          // Base types are unrelated (§5.1) and equality was already checked,
          // so anything left over is not a subtype.
          $case a false
        ))
    )
)

// Indented by the number of assumptions in scope, which is how deep into
// recursive types the goal sits — and needs no counter to restore afterwards,
// which is what let the trace keep its tail calls.
$decl trace_line $func ($decl s "", $decl ind 0) {
  $decl n $call P.ival (tbudget)
  $decl ret $if ($call lt (0, n))
      ($do ($set tbudget ($call isub (n, 1)))
           ($do ($call print ($call concat ($call spaces (ind, ""), s)))
                ($call print "\n")))
      ()
}.ret

$decl sub_seen $func ($decl a proto_ty, $decl b proto_ty, $decl st proto_actx)
  // §4.8b: `$do` runs the trace line for effect and leaves the check itself in
  // tail position. A block would not — §7.7 says a call inside a block is never
  // in tail position — and this recursion is eliminated everywhere else, so
  // instrumenting it with a block did not slow the check down, it changed its
  // space complexity: ~170 frames became 23000, deep enough to hit the depth
  // guard and change which checks succeeded. That is the reason `$do` exists.
  //
  // The flag is read directly rather than through a helper: this is the
  // hottest path in the checker.
  $if trace_on
      ($do ($call trace_line ($call concat ($call desc (a), $call concat (" <: ", $call desc (b))),
                              $call goal_list.length (st.goals, 0)))
           ($if ($call same (a, b)) true ($call sub_step (a, b, st))))
      ($if ($call same (a, b)) true ($call sub_step (a, b, st)))

$decl sub $func ($decl a proto_ty, $decl b proto_ty) $call sub_seen (a, b, proto_actx)

// Re-run a check that has already failed, printing the goal tree. A no-op
// unless the driver asked for it.
$decl explain $func ($decl a proto_ty, $decl b proto_ty)
  $if ($call not ($call bval (want_trace))) () {
    // Every level is printed now, under a line budget: with the recursion's
    // tail calls intact the trace costs no stack, so there is no reason to
    // stop at the shallow goals. The innermost failing goal is the deepest
    // indented line the tree reaches.
    $decl hdr $call print "--- why not a subtype:\n"
    $decl b1  $set tbudget 400
    $decl on  $set trace_on true
    $decl r   $call sub (a, b)
    $decl off $set trace_on false
    $decl ret ()
  }.ret

// ------------------------------------------------------ lattice operations
//
// §5.2: widening never occurs, so `join` is used where the language forms a
// union — `$if`, `$match`, `$try`'s error set — and nowhere else.

$decl is_base $func ($decl t proto_ty) $match t (
  $case {$prop tag "int"}   true,
  $case {$prop tag "float"} true,
  $case {$prop tag "str"}   true,
  $case t false
)

$decl join $func ($decl a proto_ty, $decl b proto_ty)
  $if ($call sub (a, b)) b ($if ($call sub (b, a)) a ($call union2 (a, b)))

// `T & ¬P`, as far as a union can express it: drop the members `P` covers.
//
// §4.15 narrows the value of a failed `$try` this way, and §4.7 narrows a
// `$match` scrutinee across arms. There is no general complement in the type
// language — and none is needed, because every use is a union of tag shapes,
// where removing the covered members *is* the complement.
$decl remove_covered $func ($decl xs tys.node, $decl pat proto_ty, $decl acc tys.node) $match xs (
  $case {$prop tag "cons"}
    $call remove_covered (xs.tail, pat,
        $if ($call sub (xs.head, pat)) acc ($call tys.cons (xs.head, acc))),
  $case xs acc
)

// `T & P` as a narrowing, rather than as an opaque intersection.
//
// §4.7 narrows a `$match` scrutinee to `type(e) & P` inside each arm, and §4.15
// does the same for the value `$try` returns. When `T` is a union of tag shapes
// — which is what every scrutinee worth matching on is — the useful answer is
// the members `P` selects, not `T ^ P`: an intersection has no fields to
// project, so `xs.tail` inside a `$case {$prop tag "cons"}` arm would have
// nothing to read. Unrolling first is what makes this work on a recursive type.
$decl meet $func ($decl a proto_ty, $decl b proto_ty)
  $if ($call sub (a, b)) a
  ($if ($call sub (b, a)) b
  // Two distinct base types have no common values (§5.1: they are unrelated),
  // so their intersection is uninhabited rather than merely unsatisfied.
  ($if ($call and ($call is_base (a), $call is_base (b))) t_bot
       ($call t_inter ($call tys.cons (a, $call tys.cons (b, tys.nil))))))

$decl keep_covered $func ($decl xs tys.node, $decl pat proto_ty, $decl acc tys.node) $match xs (
  $case {$prop tag "cons"}
    $call keep_covered (xs.tail, pat,
        $if ($call sub (xs.head, pat)) ($call tys.cons (xs.head, acc)) acc),
  $case xs acc
)

$fwd restrict_at

$decl restrict $func ($decl t proto_ty, $decl pat proto_ty)
  // §4.7's catch-all arm narrows the scrutinee by its own type, and `T & T` is
  // `T`. Without this the common arm re-checks every member against every
  // member, which is quadratic for no information.
  $if ($call same (t, pat)) t ($call restrict_at (t, pat))

$decl restrict_at $func ($decl t proto_ty, $decl pat proto_ty) $match t (
  // Selecting does not need the type unrolled. A pattern is a tag block, and
  // §5.1 compares a block's *props* — which every member carries as it stands.
  // Unrolling first would rebuild the whole type on every `$match` arm, which
  // is quadratic in a checker that matches on a recursive type constantly.
  $case {$prop tag "rec"} {
    $decl bd t.body
    $decl ret $match bd (
        $case {$prop tag "union"} {
          $decl kept $call keep_covered (bd.members, pat, tys.nil)
          $decl ret2 $if ($call tys.is_nil (kept)) ($call meet ($call unroll (t), pat))
                      ($call t_union ($call subst_members (kept, t, tys.nil)))
        }.ret2,
        $case bd ($call meet ($call unroll (t), pat))
      )
  }.ret,
  $case {$prop tag "union"} {
    $decl kept $call keep_covered (t.members, pat, tys.nil)
    $decl ret  $if ($call tys.is_nil (kept)) ($call meet (t, pat)) ($call t_union (kept))
  }.ret,
  $case t ($call meet (t, pat))
)

// `μR. A | R` is `A`.
//
// A recursion variable that occurs as a *direct member* of the union it binds
// adds nothing: unrolling it yields `A | (A | (A | …))`, which is `A`. This
// happens to every tail-recursive accumulator — the recursive call contributes
// `R` and the base case contributes the real answer — so without this the
// inferred return type would be a recursive union instead of the base type.
$decl drop_var_members $func ($decl xs tys.node, $decl i 0, $decl acc tys.node) $match xs (
  $case {$prop tag "cons"}
    $call drop_var_members (xs.tail, i,
        $if ($call ty_eq (xs.head, $call t_var (i))) acc ($call tys.cons (xs.head, acc))),
  $case xs acc
)

$decl drop_var $func ($decl t proto_ty, $decl i 0) $match t (
  $case {$prop tag "union"} $call t_union ($call drop_var_members (t.members, i, tys.nil)),
  $case t t
)

$decl minus $func ($decl t proto_ty, $decl pat proto_ty) $match t (
  $case {$prop tag "union"} $call t_union ($call remove_covered (t.members, pat, tys.nil)),
  $case t ($if ($call sub (t, pat)) t_bot t)
)

// -------------------------------------------------------------- convenience

$decl f1 $func ($decl n "", $decl t proto_ty) $call fields.cons ($call field (n, t), fields.nil)
$decl p1 $func ($decl n "", $decl c proto_cv) $call props.cons ($call prop_entry (n, c), props.nil)

// A prop-only block: the shape of every tag (§4.15, §12).
$decl tag_block $func ($decl n "", $decl v "")
  $call t_block (fields.nil, $call p1 (n, $call cv_str (v)))
