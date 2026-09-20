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

$decl not  P.not
$decl and  P.and
$decl or   P.or

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
$decl want_trace $mut $new ($union (false, true))
$decl trace_on   $mut $new ($union (false, true))
$decl tbudget    $mut $new 0
$decl bval $func ($decl b P.boolean) b

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

$decl cv_int    $func ($decl x 0)    { $prop tag "cint"    $decl v x }
$decl cv_str    $func ($decl x "")   { $prop tag "cstr"    $decl v x }
// §3.2: `true` and `false` are distinct types, so a parameter defaulted `true`
// takes only `true`. This one holds either.
$decl cv_bool   $func ($decl x P.boolean) { $prop tag "cbool"   $decl v x }
$decl cv_unit                        { $prop tag "cunit" }
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

$decl cv_eq $func ($decl a proto_cv, $decl b proto_cv)
  $call eq_str ($call show_cv (a), $call show_cv (b))

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
$decl t_var $func ($decl i 0) { $prop tag "var" $decl id i }

// A bound recursion variable, as a de Bruijn index: `bnd 0` is the innermost
// enclosing `rec`, `bnd 1` the one outside it. Binders therefore carry no name
// at all, which makes alpha-equivalence *structural identity* — two copies of
// the same recursive type built at two declarations come out equal, and the
// assumption set in `sub` can recognise a goal it has already seen. Naming
// binders by a unique integer, which is what this replaced, cannot do that.
$decl t_bnd $func ($decl k 0) { $prop tag "bnd" $decl idx k }

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
  // §5.5: every field that reaches a type again goes through storage. A list
  // is boxed as a whole — a cons cell holds its element inline, so its size
  // needs the element's — while a `field`'s own `ty` stays inline, since by
  // then the type it names already has a size.
  { $prop tag "block"
    $decl fields $new ($specialize P.list { $decl name ""  $decl ty proto_ty }).node
    // `value` is any compile-time value, not just unit: a prop holding a
    // function renders as `copaque`, and writing `cv_unit` here said no block
    // with such a prop was a type at all.
    $decl props  $new ($specialize P.list { $decl name ""  $decl value proto_cv  $decl ty proto_ty }).node },
  { $prop tag "group" $decl items $new ($specialize P.list proto_ty).node },
  { $prop tag "func"  $decl params $new ($specialize P.list proto_ty).node  $decl result $new proto_ty },
  { $prop tag "ref"   $decl qual ""  $decl inner $new proto_ty },
  { $prop tag "array" $decl elem $new proto_ty },
  { $prop tag "union" $decl members $new ($specialize P.list proto_ty).node },
  { $prop tag "inter" $decl members $new ($specialize P.list proto_ty).node },
  { $prop tag "rec"   $decl body $new proto_ty },
  { $prop tag "over"  $decl cands $new ($specialize P.list proto_ty).node },
  { $prop tag "tmpl"  $decl id 0 }
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

// Raw constructors. `raw_union`/`raw_inter` are not for general use — build
// unions with `t_union`, which normalises.
$decl raw_block $func ($decl fs fields.node, $decl ps props.node)
  { $prop tag "block" $decl fields $new fs  $decl props $new ps }

$decl raw_union $func ($decl ms tys.node) { $prop tag "union" $decl members $new ms }
$decl raw_inter $func ($decl ms tys.node) { $prop tag "inter" $decl members $new ms }

$decl t_group $func ($decl xs tys.node)  { $prop tag "group" $decl items $new xs }
$decl t_func  $func ($decl ps tys.node, $decl r proto_ty) { $prop tag "func" $decl params $new ps  $decl result $new r }

// §5.3: `qual` is "" for `&T`, "mut" for `&mut T`, "const" for `&const T`.
$decl t_ref   $func ($decl q "", $decl t proto_ty) { $prop tag "ref" $decl qual q  $decl inner $new t }
$decl t_array $func ($decl e proto_ty) { $prop tag "array" $decl elem $new e }
$decl t_rec   $func ($decl b proto_ty) { $prop tag "rec" $decl body $new b }
$decl t_over  $func ($decl cs tys.node) { $prop tag "over" $decl cands $new cs }

// A template (§4.9). Its body is *not* type-checked at declaration, so there is
// nothing structural to record here: the type is an identity, and whoever built
// it keeps the body and the environment it was written in. Two templates are
// the same type when they are the same template.
$decl t_tmpl  $func ($decl i 0) { $prop tag "tmpl" $decl id i }

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
  $case {$prop tag "cons"} $call show_sorted_add (xs.tail, $call strs_insert ($call show (xs.head), acc)),
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

$decl show_qual $func ($decl q "")
  $if ($call eq_str (q, "")) "&" ($if ($call eq_str (q, "mut")) "&mut " "&const ")

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
  $case {$prop tag "func"}   $call concat ("[", $call concat ($call show_tys (t.params, "", true),
                                 $call concat ("]->", $call show (t.result)))),
  $case {$prop tag "ref"}    $call concat ($call show_qual (t.qual), $call show (t.inner)),
  $case {$prop tag "array"}  $call concat ("[]", $call show (t.elem)),
  $case {$prop tag "union"}  $call concat ("<", $call concat ($call show_set (t.members), ">")),
  $case {$prop tag "inter"}  $call concat ("^", $call concat ($call show_set (t.members), "^")),
  $case {$prop tag "bnd"}    $call concat ("b", $call int_to_str (t.idx)),
  $case {$prop tag "rec"}    $call concat ("mu.", $call show (t.body)),
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
            ($if ($call cv_eq (xs.head.value, ys.head.value)) ($call same_props (xs.tail, ys.tail)) false)
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

$decl same $func ($decl a proto_ty, $decl b proto_ty) $match a (
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
        $if ($call same_tys (a.params, b.params)) ($call same (a.result, b.result)) false,
      $case b false
    ),
  $case {$prop tag "ref"} $match b (
      $case {$prop tag "ref"}
        $if ($call eq_str (a.qual, b.qual)) ($call same (a.inner, b.inner)) false,
      $case b false
    ),
  $case {$prop tag "array"} $match b (
      $case {$prop tag "array"} $call same (a.elem, b.elem), $case b false),
  // §3.6 makes these *sets*, so membership decides equality, not order. That is
  // what lets construction skip sorting entirely.
  $case {$prop tag "union"} $match b (
      $case {$prop tag "union"} $call same_set (a.members, b.members), $case b false),
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
  // The leaf types carry nothing, so equal renderings mean equal types.
  $case a ($call eq_str ($call show (a), $call show (b)))
)

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

$decl t_union $func ($decl xs tys.node)
  { $decl m $call union_addall (xs, tys.nil)
    $decl n $call tys.length (m, 0)
    $decl out $if ($call eq_int (n, 0)) t_bot
             ($if ($call eq_int (n, 1)) ($call tys.nth (m, 0)) ($call raw_union (m))) }.out

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

$decl t_inter $func ($decl xs tys.node)
  { $decl m $call inter_addall (xs, tys.nil)
    $decl n $call tys.length (m, 0)
    $decl out $if ($call has_bottom (m)) t_bot
             ($if ($call eq_int (n, 0)) t_bot
             ($if ($call eq_int (n, 1)) ($call tys.nth (m, 0)) ($call raw_inter (m)))) }.out

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

$decl occurs $func ($decl t proto_ty, $decl i 0) $match t (
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
  $case t false
)

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

$decl proto_rop $call rop ("", 0, t_bot)

$fwd remap

$decl remap_tys $func ($decl xs tys.node, $decl o proto_rop, $decl d 0, $decl acc tys.node) $match xs (
  $case {$prop tag "cons"}
    $call remap_tys (xs.tail, o, d, $call tys.cons ($call remap (xs.head, o, d), acc)),
  $case xs ($call tys.reverse (acc, tys.nil))
)

$decl remap_fields $func ($decl xs fields.node, $decl o proto_rop, $decl d 0, $decl acc fields.node) $match xs (
  $case {$prop tag "cons"}
    $call remap_fields (xs.tail, o, d,
        $call fields.cons ($call field (xs.head.name, $call remap (xs.head.ty, o, d)), acc)),
  $case xs ($call fields.reverse (acc, fields.nil))
)

$decl remap $func ($decl t proto_ty, $decl o proto_rop, $decl d 0) $match t (
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
  $case {$prop tag "block"} $call raw_block ($call remap_fields (t.fields, o, d, fields.nil), t.props),
  $case {$prop tag "group"} $call t_group ($call remap_tys (t.items, o, d, tys.nil)),
  $case {$prop tag "func"}
    $call t_func ($call remap_tys (t.params, o, d, tys.nil), $call remap (t.result, o, d)),
  $case {$prop tag "ref"}   $call t_ref (t.qual, $call remap (t.inner, o, d)),
  $case {$prop tag "array"} $call t_array ($call remap (t.elem, o, d)),
  $case {$prop tag "union"} $call t_union ($call remap_tys (t.members, o, d, tys.nil)),
  $case {$prop tag "inter"} $call t_inter ($call remap_tys (t.members, o, d, tys.nil)),
  $case {$prop tag "over"}  $call t_over ($call remap_tys (t.cands, o, d, tys.nil)),
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

// `μR. B(R)`, built from a body that still mentions the placeholder `R`.
$decl close_var $func ($decl t proto_ty, $decl i 0)
  $call t_rec ($call remap (t, $call rop_abs (i), 0))

$decl unroll $func ($decl t proto_ty) $match t (
  $case {$prop tag "rec"} $call subst_bnd (t.body, 0, t),
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

$decl goal_ent $func ($decl x proto_ty, $decl y proto_ty) { $decl l x  $decl r y }
$decl proto_goal $call goal_ent (t_bot, t_bot)
$decl goal_list $specialize P.list proto_goal

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
    $if ($call eq_str (xs.head.name, n)) ($call field (n, xs.head.ty)) ($call find_field (xs.tail, n)),
  $case xs ($call field ("", t_bot))
)

$decl find_prop $func ($decl xs props.node, $decl n "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, n)) xs.head ($call find_prop (xs.tail, n)),
  $case xs ($call prop_entry ("", $call cv_opaque (-1)))
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
  $case {$prop tag "block"}
    { $decl p  $call find_prop (t.props, "tag")
      $decl cv p.value
      $decl out $match cv (
          $case {$prop tag "cstr"} cv.v,
          $case cv ""
        ) }.out,
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
  $case {$prop tag "bottom"} "!",
  $case t ($call show (t))
)

$decl desc $func ($decl t proto_ty)
  { $decl k  $call kind_of (t)
    $decl tg $call tag_of (t)
    $decl out $if ($call eq_str (tg, "")) k
                  ($call concat (k, $call concat ("[", $call concat (tg, "]")))) }.out

$decl tags_differ $func ($decl a proto_ty, $decl b proto_ty)
  { $decl ta $call tag_of (a)
    $decl tb $call tag_of (b)
    $decl out $call and ($call and ($call not ($call eq_str (ta, "")),
                                    $call not ($call eq_str (tb, ""))),
                         $call not ($call eq_str (ta, tb))) }.out

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
        $if ($call sub_seen (ys.head, xs.head, st)) ($call subs_zip_flipped (xs.tail, ys.tail, st)) false,
      $case ys false
    ),
  $case xs ($call tys.is_nil (ys))
)

// Prefix and depth (§5.1): `T`'s fields must be an ordered *prefix* of `S`'s —
// same names at the same positions, each at a subtype. Running out of required
// fields means the prefix is satisfied; running out of `S`'s fields first means
// `T` demands more than `S` has.
$decl sub_fields $func ($decl s fields.node, $decl want fields.node, $decl st proto_actx) $match want (
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
  $case {$prop tag "cons"}
    { $decl p $call find_prop (s, want.head.name)
      $decl out $if ($call eq_str (p.name, ""))
          false
          ($if ($call cv_eq (p.value, want.head.value)) ($call sub_props (s, want.tail)) false) }.out,
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

$decl sub_ref $func ($decl a proto_ref, $decl b proto_ref, $decl st proto_actx)
  $if ($call eq_str (b.qual, "const")) ($call sub_seen (a.inner, b.inner, st))
  ($if ($call eq_str (b.qual, "mut"))
       ($call and ($call not ($call eq_str (a.qual, "const")), $call ty_eq (a.inner, b.inner)))
       ($call and ($call eq_str (a.qual, ""), $call ty_eq (a.inner, b.inner))))

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
      $case b $match a (
          $case {$prop tag "inter"} $call subs_any_left (a.members, b, st),
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
              $case {$prop tag "func"}
                $if ($call subs_zip_flipped (a.params, b.params, st))
                    ($call sub_seen (a.result, b.result, st)) false,
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
        )
    )
)

// Indented by the number of assumptions in scope, which is how deep into
// recursive types the goal sits — and needs no counter to restore afterwards,
// which is what let the trace keep its tail calls.
$decl trace_line $func ($decl s "", $decl ind 0)
  { $decl n $call P.ival (tbudget)
    $decl out $if ($call lt (0, n))
        ($do ($set tbudget ($call isub (n, 1)))
             ($do ($call print ($call concat ($call spaces (ind, ""), s)))
                  ($call print "\n")))
        () }.out

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
  $if ($call not ($call bval (want_trace))) ()
      // Every level is printed now, under a line budget: with the recursion's
      // tail calls intact the trace costs no stack, so there is no reason to
      // stop at the shallow goals. The innermost failing goal is the deepest
      // indented line the tree reaches.
      { $decl hdr $call print "--- why not a subtype:\n"
        $decl b1  $set tbudget 400
        $decl on  $set trace_on true
        $decl r   $call sub (a, b)
        $decl off $set trace_on false
        $decl out () }.out

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
  $case {$prop tag "rec"}
    { $decl bd t.body
      $decl out $match bd (
          $case {$prop tag "union"}
            { $decl kept $call keep_covered (bd.members, pat, tys.nil)
              $decl r $if ($call tys.is_nil (kept)) ($call meet ($call unroll (t), pat))
                          ($call t_union ($call subst_members (kept, t, tys.nil))) }.r,
          $case bd ($call meet ($call unroll (t), pat))
        ) }.out,
  $case {$prop tag "union"}
    { $decl kept $call keep_covered (t.members, pat, tys.nil)
      $decl r $if ($call tys.is_nil (kept)) ($call meet (t, pat)) ($call t_union (kept)) }.r,
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
