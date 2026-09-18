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

// ------------------------------------------------------------ string ordering
//
// Needed for canonical form: props and union members are sorted by name and by
// rendering respectively. §8 gives `lt` on Int only, so this is bytewise.

$decl str_lt_at $func ($decl a "", $decl b "", $decl i 0)
  $if ($call not ($call lt (i, $call len (a)))) ($call lt (i, $call len (b)))
  ($if ($call not ($call lt (i, $call len (b)))) false
  { $decl ca $call byte (a, i)
    $decl cb $call byte (b, i)
    $decl out $if ($call lt (ca, cb)) true
             ($if ($call lt (cb, ca)) false ($call str_lt_at (a, b, $call add (i, 1)))) }.out)

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
$decl cv_bool   $func ($decl x true) { $prop tag "cbool"   $decl v x }
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

// A recursion variable. §5.5's placeholder `R`, bound by `rec`.
$decl t_var $func ($decl i 0) { $prop tag "var" $decl id i }

// The type of types. Members after the first are type-only positions (§5.7),
// so they may name the constructors and lists declared below.
$decl proto_ty $union (
  t_int, t_float, t_str, t_true, t_false, t_unit, t_bot,
  $call t_var (0),
  $call raw_block (fields.nil, props.nil),
  $call t_group (tys.nil),
  $call t_func (tys.nil, proto_ty),
  $call t_ref ("", proto_ty),
  $call t_array (proto_ty),
  $call raw_union (tys.nil),
  $call raw_inter (tys.nil),
  $call t_rec (0, proto_ty),
  $call t_over (tys.nil),
  $call t_tmpl (0)
)

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
  { $prop tag "block" $decl fields fs  $decl props ps }

$decl raw_union $func ($decl ms tys.node) { $prop tag "union" $decl members ms }
$decl raw_inter $func ($decl ms tys.node) { $prop tag "inter" $decl members ms }

$decl t_group $func ($decl xs tys.node)  { $prop tag "group" $decl items xs }
$decl t_func  $func ($decl ps tys.node, $decl r proto_ty) { $prop tag "func" $decl params ps  $decl result r }

// §5.3: `qual` is "" for `&T`, "mut" for `&mut T`, "const" for `&const T`.
$decl t_ref   $func ($decl q "", $decl t proto_ty) { $prop tag "ref" $decl qual q  $decl inner t }
$decl t_array $func ($decl e proto_ty) { $prop tag "array" $decl elem e }
$decl t_rec   $func ($decl i 0, $decl b proto_ty) { $prop tag "rec" $decl id i  $decl body b }
$decl t_over  $func ($decl cs tys.node) { $prop tag "over" $decl cands cs }

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

$decl show_tys $func ($decl xs tys.node, $decl acc "", $decl first true) $match xs (
  $case {$prop tag "cons"} $call show_tys (xs.tail,
      $call concat (acc, $call concat ($if first "" ",", $call show (xs.head))), false),
  $case xs acc
)

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
  $case {$prop tag "union"}  $call concat ("<", $call concat ($call show_tys (t.members, "", true), ">")),
  $case {$prop tag "inter"}  $call concat ("^", $call concat ($call show_tys (t.members, "", true), "^")),
  $case {$prop tag "rec"}    $call concat ("mu", $call concat ($call int_to_str (t.id),
                                 $call concat (".", $call show (t.body)))),
  $case {$prop tag "over"}   $call concat ("O<", $call concat ($call show_tys (t.cands, "", true), ">")),
  $case {$prop tag "tmpl"}   $call concat ("Tmpl", $call int_to_str (t.id)),
  $case t "?"
)

$decl ty_eq $func ($decl a proto_ty, $decl b proto_ty)
  $call eq_str ($call show (a), $call show (b))

// ------------------------------------------------- unions and intersections
//
// §3.6 makes these lattice operations, so they are sets: flattened, without
// duplicates, in a fixed order. Normalising here rather than at comparison
// time is what lets `ty_eq` be a string comparison.

$decl tys_insert $func ($decl t proto_ty, $decl xs tys.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call ty_eq (t, xs.head)) xs
    ($if ($call str_lt ($call show (t), $call show (xs.head)))
         ($call tys.cons (t, xs))
         ($call tys.cons (xs.head, $call tys_insert (t, xs.tail)))),
  $case xs ($call tys.cons (t, tys.nil))
)

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

$fwd subst

$decl subst_tys $func ($decl xs tys.node, $decl i 0, $decl r proto_ty, $decl acc tys.node) $match xs (
  $case {$prop tag "cons"}
    $call subst_tys (xs.tail, i, r, $call tys.cons ($call subst (xs.head, i, r), acc)),
  $case xs ($call tys.reverse (acc, tys.nil))
)

$decl subst_fields $func ($decl xs fields.node, $decl i 0, $decl r proto_ty, $decl acc fields.node) $match xs (
  $case {$prop tag "cons"}
    $call subst_fields (xs.tail, i, r,
      $call fields.cons ($call field (xs.head.name, $call subst (xs.head.ty, i, r)), acc)),
  $case xs ($call fields.reverse (acc, fields.nil))
)

$decl subst $func ($decl t proto_ty, $decl i 0, $decl r proto_ty) $match t (
  $case {$prop tag "var"}   $if ($call eq_int (t.id, i)) r t,
  // Props hold values, never types, so they need no substitution.
  $case {$prop tag "block"} $call raw_block ($call subst_fields (t.fields, i, r, fields.nil), t.props),
  $case {$prop tag "group"} $call t_group ($call subst_tys (t.items, i, r, tys.nil)),
  $case {$prop tag "func"}  $call t_func ($call subst_tys (t.params, i, r, tys.nil), $call subst (t.result, i, r)),
  $case {$prop tag "ref"}   $call t_ref (t.qual, $call subst (t.inner, i, r)),
  $case {$prop tag "array"} $call t_array ($call subst (t.elem, i, r)),
  $case {$prop tag "union"} $call t_union ($call subst_tys (t.members, i, r, tys.nil)),
  $case {$prop tag "inter"} $call t_inter ($call subst_tys (t.members, i, r, tys.nil)),
  // A nested binder for the same variable shadows this one.
  $case {$prop tag "rec"}   $if ($call eq_int (t.id, i)) t ($call t_rec (t.id, $call subst (t.body, i, r))),
  $case {$prop tag "over"}  $call t_over ($call subst_tys (t.cands, i, r, tys.nil)),
  $case t t
)

$decl unroll $func ($decl t proto_ty) $match t (
  $case {$prop tag "rec"} $call subst (t.body, t.id, t),
  $case t t
)

// --------------------------------------------------------------- subtyping
//
// §5.1. `sub` is coinductive: before descending it records the goal, and a
// repeated goal is assumed to hold. That is what terminates on recursive types
// — the assumption is discharged by the structure around it.

$fwd sub_seen

$decl subs_all_left $func ($decl xs tys.node, $decl b proto_ty, $decl seen strs.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call sub_seen (xs.head, b, seen)) ($call subs_all_left (xs.tail, b, seen)) false,
  $case xs true
)

$decl subs_any_right $func ($decl a proto_ty, $decl ys tys.node, $decl seen strs.node) $match ys (
  $case {$prop tag "cons"}
    $if ($call sub_seen (a, ys.head, seen)) true ($call subs_any_right (a, ys.tail, seen)),
  $case ys false
)

$decl subs_all_right $func ($decl a proto_ty, $decl ys tys.node, $decl seen strs.node) $match ys (
  $case {$prop tag "cons"}
    $if ($call sub_seen (a, ys.head, seen)) ($call subs_all_right (a, ys.tail, seen)) false,
  $case ys true
)

$decl subs_any_left $func ($decl xs tys.node, $decl b proto_ty, $decl seen strs.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call sub_seen (xs.head, b, seen)) true ($call subs_any_left (xs.tail, b, seen)),
  $case xs false
)

// Elementwise, same arity (§5.1 for groups).
$decl subs_zip $func ($decl xs tys.node, $decl ys tys.node, $decl seen strs.node) $match xs (
  $case {$prop tag "cons"} $match ys (
      $case {$prop tag "cons"}
        $if ($call sub_seen (xs.head, ys.head, seen)) ($call subs_zip (xs.tail, ys.tail, seen)) false,
      $case ys false
    ),
  $case xs ($call tys.is_nil (ys))
)

// Contravariant in parameters (§5.1 for functions): the *argument* side flips.
$decl subs_zip_flipped $func ($decl xs tys.node, $decl ys tys.node, $decl seen strs.node) $match xs (
  $case {$prop tag "cons"} $match ys (
      $case {$prop tag "cons"}
        $if ($call sub_seen (ys.head, xs.head, seen)) ($call subs_zip_flipped (xs.tail, ys.tail, seen)) false,
      $case ys false
    ),
  $case xs ($call tys.is_nil (ys))
)

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

// Prefix and depth (§5.1): `T`'s fields must be an ordered *prefix* of `S`'s —
// same names at the same positions, each at a subtype. Running out of required
// fields means the prefix is satisfied; running out of `S`'s fields first means
// `T` demands more than `S` has.
$decl sub_fields $func ($decl s fields.node, $decl want fields.node, $decl seen strs.node) $match want (
  $case {$prop tag "cons"} $match s (
      $case {$prop tag "cons"}
        $if ($call eq_str (s.head.name, want.head.name))
            ($if ($call sub_seen (s.head.ty, want.head.ty, seen))
                 ($call sub_fields (s.tail, want.tail, seen))
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
$decl sub_ref $func ($decl a proto_ty, $decl b proto_ty, $decl seen strs.node)
  $if ($call eq_str (b.qual, "const")) ($call sub_seen (a.inner, b.inner, seen))
  ($if ($call eq_str (b.qual, "mut"))
       ($call and ($call not ($call eq_str (a.qual, "const")), $call ty_eq (a.inner, b.inner)))
       ($call and ($call eq_str (a.qual, ""), $call ty_eq (a.inner, b.inner))))

$decl sub_step $func ($decl a proto_ty, $decl b proto_ty, $decl seen strs.node) $match a (
  // §3.6: ⊥ is a subtype of everything.
  $case {$prop tag "bottom"} true,
  $case {$prop tag "rec"}    $call sub_seen ($call unroll (a), b, seen),
  $case {$prop tag "union"}  $call subs_all_left (a.members, b, seen),
  $case a $match b (
      $case {$prop tag "rec"}   $call sub_seen (a, $call unroll (b), seen),
      $case {$prop tag "union"} $call subs_any_right (a, b.members, seen),
      $case {$prop tag "inter"} $call subs_all_right (a, b.members, seen),
      $case b $match a (
          $case {$prop tag "inter"} $call subs_any_left (a.members, b, seen),
          $case {$prop tag "block"} $match b (
              $case {$prop tag "block"}
                $if ($call sub_fields (a.fields, b.fields, seen))
                    ($call sub_props (a.props, b.props)) false,
              $case b false
            ),
          $case {$prop tag "group"} $match b (
              $case {$prop tag "group"} $call subs_zip (a.items, b.items, seen),
              $case b false
            ),
          $case {$prop tag "func"} $match b (
              $case {$prop tag "func"}
                $if ($call subs_zip_flipped (a.params, b.params, seen))
                    ($call sub_seen (a.result, b.result, seen)) false,
              $case b false
            ),
          $case {$prop tag "ref"} $match b (
              $case {$prop tag "ref"} $call sub_ref (a, b, seen),
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

$decl sub_seen $func ($decl a proto_ty, $decl b proto_ty, $decl seen strs.node)
  { $decl sa  $call show (a)
    $decl sb  $call show (b)
    $decl key $call concat (sa, $call concat (" <: ", sb))
    $decl out $if ($call eq_str (sa, sb)) true
             ($if ($call mem_str (seen, key)) true
                  ($call sub_step (a, b, $call strs.cons (key, seen)))) }.out

$decl sub $func ($decl a proto_ty, $decl b proto_ty) $call sub_seen (a, b, strs.nil)

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
$decl keep_covered $func ($decl xs tys.node, $decl pat proto_ty, $decl acc tys.node) $match xs (
  $case {$prop tag "cons"}
    $call keep_covered (xs.tail, pat,
        $if ($call sub (xs.head, pat)) ($call tys.cons (xs.head, acc)) acc),
  $case xs acc
)

$decl restrict $func ($decl t proto_ty, $decl pat proto_ty)
  { $decl u $call unroll (t)
    $decl out $match u (
        $case {$prop tag "union"}
          { $decl kept $call keep_covered (u.members, pat, tys.nil)
            // No member selected: fall back to the general meet, which reports
            // the mismatch honestly rather than inventing a member.
            $decl r $if ($call tys.is_nil (kept)) ($call meet (t, pat)) ($call t_union (kept)) }.r,
        $case u ($call meet (t, pat))
      ) }.out

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

$decl meet $func ($decl a proto_ty, $decl b proto_ty)
  $if ($call sub (a, b)) a
  ($if ($call sub (b, a)) b
  // Two distinct base types have no common values (§5.1: they are unrelated),
  // so their intersection is uninhabited rather than merely unsatisfied.
  ($if ($call and ($call is_base (a), $call is_base (b))) t_bot
       ($call t_inter ($call tys.cons (a, $call tys.cons (b, tys.nil))))))

// -------------------------------------------------------------- convenience

$decl f1 $func ($decl n "", $decl t proto_ty) $call fields.cons ($call field (n, t), fields.nil)
$decl p1 $func ($decl n "", $decl c proto_cv) $call props.cons ($call prop_entry (n, c), props.nil)

// A prop-only block: the shape of every tag (§4.15, §12).
$decl tag_block $func ($decl n "", $decl v "")
  $call t_block (fields.nil, $call p1 (n, $call cv_str (v)))
