// Tests for stage 1's type language:
//
//   morphlc --run stage1/types_test.mpl
//
// Every expectation here is a rule from SPEC.md §5.1, §5.3 or §3.6, cited.

$decl T $import "types"
$decl P $import "prelude"

$decl not P.not
$decl and P.and

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))

$decl check $func ($decl name "", $decl ok true)
  $if ok
      ($do ($call print ("ok   ")) ($call nl (name)))
      ($do ($call print ("FAIL ")) ($do ($call nl (name)) ($call panic (name))))

$decl check_str $func ($decl name "", $decl got "", $decl want "")
  $if ($call eq_str (got, want))
      ($do ($call print ("ok   ")) ($call nl (name)))
      ($do ($call print ("FAIL "))
      ($do ($call nl (name))
      ($do ($call nl ($call concat ("       want: ", want)))
      ($do ($call nl ($call concat ("       got:  ", got)))
           ($call panic (name))))))

// Shorthands
$decl int   T.t_int
$decl str   T.t_str
$decl flt   T.t_float
$decl bot   T.t_bot
$decl unit  T.t_unit
$decl tru   T.t_true
$decl fls   T.t_false
$decl bool  T.t_bool

$decl two $func ($decl a T.proto_ty, $decl b T.proto_ty)
  $call T.tys.cons (a, $call T.tys.cons (b, T.tys.nil))

$decl three $func ($decl a T.proto_ty, $decl b T.proto_ty, $decl c T.proto_ty)
  $call T.tys.cons (a, $call T.tys.cons (b, $call T.tys.cons (c, T.tys.nil)))

$decl fld2 $func ($decl n1 "", $decl t1 T.proto_ty, $decl n2 "", $decl t2 T.proto_ty)
  $call T.fields.cons ($call T.field (n1, t1),
  $call T.fields.cons ($call T.field (n2, t2), T.fields.nil))

$decl fld2_block $func ($decl n1 "", $decl t1 T.proto_ty, $decl n2 "", $decl t2 T.proto_ty)
  $call T.t_block ($call fld2 (n1, t1, n2, t2), T.props.nil)

// ------------------------------------------------------------ canonical form

$decl t01 $call check_str ("base types render", $call T.show (int), "Int")
$decl t02 $call check_str ("bottom renders", $call T.show (bot), "!")
$decl t03 $call check_str ("Bool is the union of the two tag types (§3.2)",
  $call T.show (bool), "<false,true>")
$decl t04 $call check_str ("a block renders fields then props",
  $call T.show ($call T.t_block ($call fld2 ("a", int, "b", str), $call T.p1 ("k", $call T.cv_str ("c")))),
  "{a:Int,b:Str,k=s\"c\",}")
$decl t05 $call check_str ("a function type renders",
  $call T.show ($call T.t_func ($call two (int, str), bool)),
  "[Int,Str]-><false,true>")

// §5.1: block type *equality* is order-sensitive, because layout is (§7.2).
$decl ab $call T.t_block ($call fld2 ("a", int, "b", str), T.props.nil)
$decl ba $call T.t_block ($call fld2 ("b", str, "a", int), T.props.nil)
$decl t06 $call check ("field order changes the type",
  $call not ($call T.ty_eq (ab, ba)))

// ...but props have no layout, so their order is not part of the type.
$decl pxy $call T.t_block (T.fields.nil,
  $call T.props.cons ($call T.prop_entry ("x", $call T.cv_int (1)),
  $call T.props.cons ($call T.prop_entry ("y", $call T.cv_int (2)), T.props.nil)))
$decl pyx $call T.t_block (T.fields.nil,
  $call T.props.cons ($call T.prop_entry ("y", $call T.cv_int (2)),
  $call T.props.cons ($call T.prop_entry ("x", $call T.cv_int (1)), T.props.nil)))
$decl t07 $call check ("prop order does not change the type", $call T.ty_eq (pxy, pyx))

// §3.6: unions are sets — flattened, deduplicated, and order-insensitive.
$decl t08 $call check ("union member order does not matter",
  $call T.ty_eq ($call T.union2 (int, str), $call T.union2 (str, int)))
$decl t09 $call check ("a one-member union is that member",
  $call T.ty_eq ($call T.t_union ($call two (int, int)), int))
$decl t10 $call check ("nested unions flatten",
  $call T.ty_eq ($call T.union2 (int, $call T.union2 (str, flt)),
                 $call T.t_union ($call three (int, str, flt))))
$decl t11 $call check ("bottom is the identity for union (§3.6)",
  $call T.ty_eq ($call T.union2 (int, bot), int))
$decl t12 $call check ("an empty union is bottom", $call T.ty_eq ($call T.t_union (T.tys.nil), bot))

// -------------------------------------------------------------- subtyping

// §5.1: "Int, Float, Str are unrelated."
$decl t13 $call check ("a base type is a subtype of itself", $call T.sub (int, int))
$decl t14 $call check ("Int is not a subtype of Str", $call not ($call T.sub (int, str)))
$decl t15 $call check ("Int is not a subtype of Float", $call not ($call T.sub (int, flt)))

// §3.2: true <: Bool, false <: Bool, and Bool is not a subtype of either.
$decl t16 $call check ("true <: Bool", $call T.sub (tru, bool))
$decl t17 $call check ("false <: Bool", $call T.sub (fls, bool))
$decl t18 $call check ("Bool is not <: true", $call not ($call T.sub (bool, tru)))
$decl t19 $call check ("true is not <: false", $call not ($call T.sub (tru, fls)))

// §3.6: ⊥ is a subtype of everything, including function and block types.
$decl t20 $call check ("bottom <: Int", $call T.sub (bot, int))
$decl t21 $call check ("bottom <: a block", $call T.sub (bot, ab))
$decl t22 $call check ("Int is not <: bottom", $call not ($call T.sub (int, bot)))

// §5.1: blocks match by ordered prefix, with depth inside the prefix.
$decl abc $call T.t_block ($call T.fields.cons ($call T.field ("a", int), $call fld2 ("b", str, "c", flt)), T.props.nil)
$decl just_a $call T.t_block ($call T.f1 ("a", int), T.props.nil)
$decl t23 $call check ("a longer block is a subtype of its prefix", $call T.sub (abc, just_a))
$decl t24 $call check ("...but not the other way", $call not ($call T.sub (just_a, abc)))
// §5.1: order is part of subtyping, not only of equality.
$decl t25 $call check ("a reordered block is not a subtype in either direction",
  $call and ($call not ($call T.sub (ab, ba)), $call not ($call T.sub (ba, ab))))

// The point of prefix matching: mutual subtyping and equality coincide, so
// subtyping is antisymmetric and a canonical form means something.
$decl t25b $call check ("mutual subtyping is equality",
  $call and ($call and ($call T.sub (ab, ab), $call T.sub (ab, ab)), $call T.ty_eq (ab, ab)))
$decl t25c $call check ("a field in the wrong position is not a subtype",
  $call not ($call T.sub ($call fld2_block ("b", str, "a", int), just_a)))
$decl t25d $call check ("a prefix supertype is still a supertype",
  $call T.sub ($call fld2_block ("a", int, "b", str), just_a))
$decl t25e $call check ("...and a suffix is not",
  $call not ($call T.sub ($call fld2_block ("b", str, "a", int),
                          $call T.t_block ($call T.f1 ("a", int), T.props.nil))))
$decl t26 $call check ("a missing field is not a subtype",
  $call not ($call T.sub ($call T.t_block ($call T.f1 ("z", int), T.props.nil), just_a)))
$decl t27 $call check ("depth: a field must be a subtype",
  $call T.sub ($call T.t_block ($call T.f1 ("a", tru), T.props.nil),
               $call T.t_block ($call T.f1 ("a", bool), T.props.nil)))
$decl t28 $call check ("...and an unrelated field type is not",
  $call not ($call T.sub ($call T.t_block ($call T.f1 ("a", str), T.props.nil), just_a)))

// §5.1: "for every prop of T, S has the same prop with the same value."
$decl circle $call T.tag_block ("kind", "circle")
$decl square $call T.tag_block ("kind", "square")
$decl circle_r $call T.t_block ($call T.f1 ("r", flt), $call T.p1 ("kind", $call T.cv_str ("circle")))
$decl t29 $call check ("a tag matches itself", $call T.sub (circle_r, circle))
$decl t30 $call check ("a different tag value does not match", $call not ($call T.sub (circle_r, square)))
$decl t31 $call check ("a block without the prop does not match",
  $call not ($call T.sub (just_a, circle)))

// §5.1: groups are elementwise with the same arity.
$decl t32 $call check ("groups elementwise", $call T.sub ($call T.t_group ($call two (tru, int)),
                                                          $call T.t_group ($call two (bool, int))))
$decl t33 $call check ("arity must match",
  $call not ($call T.sub ($call T.t_group ($call two (int, int)),
                          $call T.t_group ($call three (int, int, int)))))

// §5.1: functions are contravariant in parameters, covariant in the result.
$decl t34 $call check ("covariant in the result",
  $call T.sub ($call T.t_func ($call T.tys.cons (int, T.tys.nil), tru),
               $call T.t_func ($call T.tys.cons (int, T.tys.nil), bool)))
$decl t35 $call check ("contravariant in parameters",
  $call T.sub ($call T.t_func ($call T.tys.cons (bool, T.tys.nil), int),
               $call T.t_func ($call T.tys.cons (tru, T.tys.nil), int)))
$decl t36 $call check ("...and not covariant in parameters",
  $call not ($call T.sub ($call T.t_func ($call T.tys.cons (tru, T.tys.nil), int),
                          $call T.t_func ($call T.tys.cons (bool, T.tys.nil), int))))

// §5.3: &T <: &mut T <: &const T, with invariance except through &const.
$decl r_plain $call T.t_ref ("", int)
$decl r_mut   $call T.t_ref ("mut", int)
$decl r_const $call T.t_ref ("const", int)
$decl t37 $call check ("&T <: &mut T", $call T.sub (r_plain, r_mut))
$decl t38 $call check ("&mut T <: &const T", $call T.sub (r_mut, r_const))
$decl t39 $call check ("&T <: &const T", $call T.sub (r_plain, r_const))
$decl t40 $call check ("&mut T is not <: &T", $call not ($call T.sub (r_mut, r_plain)))
$decl t41 $call check ("&const T is not <: &mut T", $call not ($call T.sub (r_const, r_mut)))

// Consequence (§10.8): a bare `&T` parameter rejects a `&mut` argument, which
// is why idiomatic code qualifies parameters.
$decl t42 $call check ("&mut is invariant, so prefix subtyping is unavailable",
  $call not ($call T.sub ($call T.t_ref ("mut", abc), $call T.t_ref ("mut", just_a))))
$decl t43 $call check ("...but &const is covariant, so it is available there — and free (§7.4)",
  $call T.sub ($call T.t_ref ("const", abc), $call T.t_ref ("const", just_a)))

// §3.6 lattice rules for unions and intersections.
$decl t44 $call check ("a union is a subtype when every member is",
  $call T.sub ($call T.union2 (tru, fls), bool))
$decl t45 $call check ("a member is a subtype of the union", $call T.sub (int, $call T.union2 (int, str)))
$decl t46 $call check ("a union is not a subtype of one member",
  $call not ($call T.sub ($call T.union2 (int, str), int)))
$decl t47 $call check ("an intersection is a subtype of each member",
  $call T.sub ($call T.meet (abc, just_a), just_a))

// §5.5: recursive types. The list from the spec's own example.
//   μR. {} | {head: Int, tail: R}
$decl cons_cell $func ($decl tail T.proto_ty)
  $call T.t_block ($call fld2 ("head", int, "tail", tail), T.props.nil)

$decl list_ty $call T.t_rec (1, $call T.union2 (unit, $call cons_cell ($call T.t_var (1))))

$decl t48 $call check_str ("the inferred list type renders",
  $call T.show (list_ty), "mu1.<(),{head:Int,tail:v1,}>")

// Equirecursive: one unrolling is the same type.
$decl t49 $call check ("a recursive type equals its unrolling",
  $call and ($call T.sub (list_ty, $call T.unroll (list_ty)),
             $call T.sub ($call T.unroll (list_ty), list_ty)))

// A two-element list is a subtype of the recursive type. This is the case that
// only terminates because `sub` assumes its goal before descending.
$decl two_elem $call cons_cell ($call cons_cell (unit))
$decl t50 $call check ("a finite list is a subtype of the recursive type",
  $call T.sub (two_elem, list_ty))
$decl t51 $call check ("unit is a subtype of the recursive type", $call T.sub (unit, list_ty))
$decl t52 $call check ("a Str-headed cell is not",
  $call not ($call T.sub ($call cons_cell ($call T.t_block ($call fld2 ("head", str, "tail", unit), T.props.nil)),
                          list_ty)))

// A recursive type whose variable is shadowed by an inner binder of the same
// id must not be substituted through.
$decl shadowed $call T.t_rec (1, $call T.t_rec (1, $call T.t_var (1)))
$decl t53 $call check ("an inner binder shadows the outer one",
  $call T.ty_eq ($call T.unroll (shadowed), $call T.t_rec (1, $call T.t_var (1))))

// ----------------------------------------------------------------- lattice

$decl t54 $call check ("join keeps the supertype", $call T.ty_eq ($call T.join (tru, bool), bool))
$decl t55 $call check ("join of unrelated types is their union",
  $call T.ty_eq ($call T.join (int, str), $call T.union2 (int, str)))
$decl t56 $call check ("join is idempotent", $call T.ty_eq ($call T.join (int, int), int))
$decl t57 $call check ("join with bottom is the other side (§3.6)",
  $call T.ty_eq ($call T.join (int, bot), int))
$decl t58 $call check ("meet keeps the subtype", $call T.ty_eq ($call T.meet (tru, bool), tru))
$decl t59 $call check ("meet of unrelated base types is bottom (§5.1)",
  $call T.ty_eq ($call T.meet (int, str), bot))
$decl t60 $call check ("meet of two blocks keeps both fields",
  $call and ($call T.sub ($call T.meet (just_a, $call T.t_block ($call T.f1 ("b", str), T.props.nil)), just_a),
             $call T.sub ($call T.meet (just_a, $call T.t_block ($call T.f1 ("b", str), T.props.nil)),
                          $call T.t_block ($call T.f1 ("b", str), T.props.nil))))

$decl done $call nl ("all type tests passed")
