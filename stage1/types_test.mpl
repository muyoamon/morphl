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

$decl check $func ($decl name "", $decl ok P.boolean)
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
$decl int  T.t_int
$decl str  T.t_str
$decl flt  T.t_float
$decl bot  T.t_bot
$decl unit T.t_unit
$decl tru  T.t_true
$decl fls  T.t_false
$decl bool T.t_bool

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
// §7.5 lays a union out by the order of its member list, so that order has to be
// a function of the member *set* and nothing else — otherwise two spellings of one
// type disagree about their discriminators, which is a miscompile. `show` cannot
// test this, because `show_set` sorts independently and would hide the difference;
// the member list is inspected directly.
$decl first_member $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "union"} ($call T.show ($call T.tval ($call T.tys.nth (t.members, 0)))),
  $case t "(not a union)"
)
$decl u_fwd $call T.t_union ($call T.tys.cons (int, $call T.tys.cons (str, T.tys.nil)))
$decl u_rev $call T.t_union ($call T.tys.cons (str, $call T.tys.cons (int, T.tys.nil)))

$decl t03a $call check_str ("a union's member order is canonical, not written order",
  $call first_member (u_rev), "Int")
$decl t03b $call check ("...so the two spellings have the same member order",
  $call eq_str ($call first_member (u_fwd), $call first_member (u_rev)))
$decl t03c $call check ("...and they are the same type either way (§3.6)",
  $call T.same (u_fwd, u_rev))

$decl t04 $call check_str ("a block renders fields then props",
  $call T.show ($call T.t_block ($call fld2 ("a", int, "b", str), $call T.p1 ("k",
      $call T.cv_str ("c")))),
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
$decl abc    $call T.t_block ($call T.fields.cons ($call T.field ("a", int), $call fld2 ("b", str,
    "c", flt)), T.props.nil)
$decl just_a $call T.t_block ($call T.f1 ("a", int), T.props.nil)
$decl t23    $call check ("a longer block is a subtype of its prefix", $call T.sub (abc, just_a))
$decl t24    $call check ("...but not the other way", $call not ($call T.sub (just_a, abc)))
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
$decl circle   $call T.tag_block ("kind", "circle")
$decl square   $call T.tag_block ("kind", "square")
$decl circle_r $call T.t_block ($call T.f1 ("r", flt), $call T.p1 ("kind", $call T.cv_str ("circle")))
$decl t29      $call check ("a tag matches itself", $call T.sub (circle_r, circle))
$decl t30      $call check ("a different tag value does not match", $call not ($call T.sub (circle_r, square)))
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
$decl t37     $call check ("&T <: &mut T", $call T.sub (r_plain, r_mut))
$decl t38     $call check ("&mut T <: &const T", $call T.sub (r_mut, r_const))
$decl t39     $call check ("&T <: &const T", $call T.sub (r_plain, r_const))
$decl t40     $call check ("&mut T is not <: &T", $call not ($call T.sub (r_mut, r_plain)))
$decl t41     $call check ("&const T is not <: &mut T", $call not ($call T.sub (r_const, r_mut)))

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

$decl list_ty $call T.close_var ($call T.union2 (unit, $call cons_cell ($call T.t_var (1))), 1)

$decl t48 $call check_str ("the inferred list type renders",
  $call T.show (list_ty), "mu.<(),{head:Int,tail:b0,}>")

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
  $call not ($call T.sub ($call cons_cell ($call T.t_block ($call fld2 ("head", str, "tail", unit),
      T.props.nil)),
                          list_ty)))

// Unrolling the outer binder must leave a variable bound by an inner one
// alone. As de Bruijn indices that is not a name clash but an index: `b0` under
// two binders belongs to the inner one, and only `b1` would belong to the outer.
$decl shadowed $call T.t_rec ($call T.t_rec ($call T.t_bnd (0)))
$decl t53 $call check ("unrolling does not reach a variable of an inner binder",
  $call T.ty_eq ($call T.unroll (shadowed), $call T.t_rec ($call T.t_bnd (0))))
$decl t53b $call check ("...and does reach one that names the outer binder",
  $call T.ty_eq ($call T.unroll ($call T.t_rec ($call T.t_rec ($call T.t_bnd (1)))),
                 $call T.t_rec ($call T.t_rec ($call T.t_rec ($call T.t_bnd (1))))))

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
  $call and ($call T.sub ($call T.meet (just_a, $call T.t_block ($call T.f1 ("b", str),
      T.props.nil)), just_a),
             $call T.sub ($call T.meet (just_a, $call T.t_block ($call T.f1 ("b", str),
                 T.props.nil)),
                          $call T.t_block ($call T.f1 ("b", str), T.props.nil))))

$decl done $call nl ("all type tests passed")

// A union of a recursive type with one of its own members must be a subtype of
// that recursive type — this is the shape an inferred return type takes when
// one arm returns the whole type and another returns a single case.
$decl t61 $call check ("union of a rec type and its member is a subtype of it",
  $call T.sub ($call T.union2 (list_ty, two_elem), list_ty))
$decl t62 $call check ("...and each side separately",
  $call and ($call T.sub (list_ty, list_ty), $call T.sub (two_elem, list_ty)))

// Equirecursion: a member written with the recursion *expanded* must relate to
// the same member written with the bound variable. Inference produces the
// expanded form whenever it rebuilds a value of a recursive type.
$decl rec1 $call T.close_var (
  $call T.union2 ($call T.t_block ($call T.f1 ("ty", $call T.t_var (1)), T.props.nil), unit), 1)
$decl expanded_member $call T.t_block ($call T.f1 ("ty", rec1), T.props.nil)

$decl t63 $call check ("an expanded member is a subtype of its recursive type",
  $call T.sub (expanded_member, rec1))
$decl t64 $call check ("...and the recursive type accepts the union of both forms",
  $call T.sub ($call T.union2 (rec1, expanded_member), rec1))

// The shape inference actually produces: the expansion sits inside a *second*
// recursive type (a list) built from a different placeholder on each side — 126
// against 372, as two declarations would give it. Tying the knot discards those
// ids for an index, so the two lists come out as the same value.
$decl nil_ty $call T.tag_block ("tag", "nil")
$decl cons_of $func ($decl elem T.proto_ty, $decl selfid 0)
  $call T.t_block ($call fld2 ("head", elem, "tail", $call T.t_var (selfid)),
                   $call T.p1 ("tag", $call T.cv_str ("cons")))
$decl list_of $func ($decl elem T.proto_ty, $decl selfid 0)
  $call T.close_var ($call T.union2 ($call cons_of (elem, selfid), nil_ty), selfid)

$decl elem_folded $call T.t_block ($call T.f1 ("ty", $call T.t_var (119)), T.props.nil)
$decl blk_folded  $call T.t_block ($call T.f1 ("fields", $call list_of (elem_folded, 126)),
                                   $call T.p1 ("tag", $call T.cv_str ("blk")))
$decl outer $call T.close_var ($call T.union2 (blk_folded, unit), 119)

$decl elem_expanded $call T.t_block ($call T.f1 ("ty", outer), T.props.nil)
$decl blk_expanded  $call T.t_block ($call T.f1 ("fields", $call list_of (elem_expanded, 372)),
                                     $call T.p1 ("tag", $call T.cv_str ("blk")))

$decl t65 $call check ("expansion nested in a second recursive type still relates",
  $call T.sub (blk_expanded, outer))

// ----------------------------------------------- the structural hash (§3.6, §9.3)

// `same` settles a mismatch with one integer compare on a structural hash, so the
// hash may depend only on a *coarsening* of what `same` compares. The one way that
// can go wrong is a hash that separates two **equal** types: the pair would intern
// twice and the backend would lay out two C structs for one type, silently.
//
// An intersection is where it nearly did. §3.6 makes it a set and it is
// deliberately *not* canonicalised — unlike a union, which `t_union` sorts — so
// `same` compares intersections with `same_set`, order-insensitively. A positional
// fold over the members would therefore give these two different hashes. The fold
// for an intersection is commutative for exactly this reason.
$decl ia $call T.t_inter ($call T.tys.cons (int, $call T.tys.cons (str, T.tys.nil)))
$decl ib $call T.t_inter ($call T.tys.cons (str, $call T.tys.cons (int, T.tys.nil)))

$decl t66 $call check ("two intersections written in different orders are the same type",
  $call T.same (ia, ib))
$decl t67 $call check ("...and neither is equal to an intersection with a different member",
  $call not ($call T.same (ia,
      $call T.t_inter ($call T.tys.cons (int, $call T.tys.cons (unit, T.tys.nil))))))

// A union's members *are* canonical, so the same two spellings are one type with one
// member order — which is what lets `same` walk them positionally at all.
$decl t68 $call check ("a union is order-insensitive too, by being sorted",
  $call T.same ($call T.union2 (int, str), $call T.union2 (str, int)))

// `frame` is §5.3a's closure flag and `same` does not compare it, so the hash must
// not either: two functions differing only in it are one type.
$decl t69 $call check ("the closure flag is not part of type identity, nor of the hash",
  $call T.same ($call T.t_func (T.tys.nil, int),
                $call T.t_func_fr (T.tys.nil, int, true)))

$decl done_h $call nl ("all hash-invariant tests passed")

// ------------------------------------------------ the class key, row by row
//
// INTERNING.md's key table, one test per row. Two types differing in exactly one
// component the key covers must be in different classes; two differing only in one it
// deliberately ignores — a function's `frame`, a prop's `ty` — must share one. Paranoid
// mode (`zig build test-paranoid`) checks the key against `same_deep` too, but only for
// pairs the compiler happens to compare, and dropping a reference's qualifier from its key
// merged nothing it compared. These cover every row whatever any input exercises.
//
// Each asserts both `cid`s are real, and that the class and `same` say the same thing —
// so a test cannot pass by both sides falling back to the structural walk.
$decl kint T.t_int
$decl kstr T.t_str
$decl k1   $func ($decl a T.proto_ty) $call T.tys.cons (a, T.tys.nil)
$decl k2     $func ($decl a T.proto_ty, $decl b T.proto_ty) $call T.tys.cons (a,
    $call T.tys.cons (b, T.tys.nil))
$decl kfield $func ($decl n "", $decl t T.proto_ty) $call T.fields.cons ($call T.field (n, t),
    T.fields.nil)
$decl kblk   $func ($decl n "", $decl t T.proto_ty) $call T.t_block ($call kfield (n, t),
    T.props.nil)
$decl kblk2 $func ($decl n "", $decl t T.proto_ty, $decl m "", $decl u T.proto_ty)
  $call T.t_block ($call T.fields.cons ($call T.field (n, t), $call kfield (m, u)), T.props.nil)
$decl kprop $func ($decl n "", $decl c T.proto_cv, $decl t T.proto_ty)
  $call T.t_block (T.fields.nil, $call T.props.cons ($call T.prop_typed (n, c, t), T.props.nil))

$decl interned $func ($decl a T.proto_ty, $decl b T.proto_ty)
  $call P.and ($call lt (-1, $call T.cid_of (a)), $call lt (-1, $call T.cid_of (b)))
$decl differ $func ($decl a T.proto_ty, $decl b T.proto_ty)
  $call P.and ($call interned (a, b),
      $call P.and ($call P.not ($call eq_int ($call T.cid_of (a), $call T.cid_of (b))),
                   $call P.not ($call T.same (a, b))))
$decl agree $func ($decl a T.proto_ty, $decl b T.proto_ty)
  $call P.and ($call interned (a, b),
      $call P.and ($call eq_int ($call T.cid_of (a), $call T.cid_of (b)), $call T.same (a, b)))

$decl kb01 $call check ("one block built twice is one class",
  $call agree ($call kblk ("a", kint), $call kblk ("a", kint)))
$decl kb02 $call check ("block: a field's name is in the key",
  $call differ ($call kblk ("a", kint), $call kblk ("b", kint)))
$decl kb03 $call check ("block: a field's type is in the key",
  $call differ ($call kblk ("a", kint), $call kblk ("a", kstr)))
$decl kb04 $call check ("block: field order is in the key (§5.1)",
  $call differ ($call kblk2 ("a", kint, "b", kstr), $call kblk2 ("b", kstr, "a", kint)))
$decl kb05 $call check ("block: the number of fields is in the key",
  $call differ ($call kblk ("a", kint), $call kblk2 ("a", kint, "b", kint)))
$decl kb06 $call check ("block: a prop's name is in the key",
  $call differ ($call kprop ("p", $call T.cv_int (1), kint), $call kprop ("q", $call T.cv_int (1),
      kint)))
$decl kb07 $call check ("block: a prop's value is in the key (§4.10)",
  $call differ ($call kprop ("p", $call T.cv_int (1), kint), $call kprop ("p", $call T.cv_int (2),
      kint)))
$decl kb08 $call check ("block: a prop value's kind is in the key",
  $call differ ($call kprop ("p", $call T.cv_int (1), kint), $call kprop ("p", $call T.cv_str ("1"),
      kint)))
$decl kb09 $call check ("block: a prop's ty is NOT in the key (same_props ignores it)",
  $call agree ($call kprop ("p", $call T.cv_int (1), kint), $call kprop ("p", $call T.cv_int (1),
      kstr)))

$decl kg01 $call check ("group: members are in the key, in order",
  $call differ ($call T.t_group ($call k2 (kint, kstr)), $call T.t_group ($call k2 (kstr, kint))))
$decl kg02 $call check ("group: the number of members is in the key",
  $call differ ($call T.t_group ($call k2 (kint, kstr)), $call T.t_group ($call k1 (kint))))
$decl ku01 $call check ("union: members are in the key",
  $call differ ($call T.union2 (kint, kstr), $call T.union2 (kint, T.t_unit)))
$decl ki01 $call check ("intersection: members are a set, so order is NOT in the key",
  $call agree ($call T.t_inter ($call k2 ($call kblk ("a", kint), $call kblk ("b", kint))),
               $call T.t_inter ($call k2 ($call kblk ("b", kint), $call kblk ("a", kint)))))
$decl ki02 $call check ("intersection: which members is in the key",
  $call differ ($call T.t_inter ($call k2 ($call kblk ("a", kint), $call kblk ("b", kint))),
                $call T.t_inter ($call k2 ($call kblk ("a", kint), $call kblk ("c", kint)))))

$decl kf01 $call check ("func: a parameter's type is in the key",
  $call differ ($call T.t_func ($call k1 (kint), kint), $call T.t_func ($call k1 (kstr), kint)))
$decl kf02 $call check ("func: the result is in the key",
  $call differ ($call T.t_func ($call k1 (kint), kint), $call T.t_func ($call k1 (kint), kstr)))
$decl kf03 $call check ("func: the number of parameters is in the key",
  $call differ ($call T.t_func (T.tys.nil, kint), $call T.t_func ($call k1 (kint), kint)))
$decl kf04 $call check ("func: a parameter is not confused with the result",
  $call differ ($call T.t_func ($call k1 (kint), kstr), $call T.t_func ($call k1 (kstr), kint)))
$decl kf05 $call check ("func: frame is NOT in the key (§5.3a's flag is not type identity)",
  $call agree ($call T.t_func ($call k1 (kint), kint), $call T.t_func_fr ($call k1 (kint), kint,
      true)))

$decl kr01 $call check ("ref: the qualifier is in the key",
  $call differ ($call T.t_ref_k ("", kint, ""), $call T.t_ref_k ("mut", kint, "")))
$decl kr02 $call check ("ref: the kind is in the key (§3.5)",
  $call differ ($call T.t_ref_k ("", kint, ""), $call T.t_ref_k ("", kint, T.k_alloc)))
$decl kr03 $call check ("ref: the pointee is in the key",
  $call differ ($call T.t_ref_k ("", kint, ""), $call T.t_ref_k ("", kstr, "")))
$decl ka01 $call check ("array: the element is in the key",
  $call differ ($call T.t_array (kint), $call T.t_array (kstr)))
$decl kc01 $call check ("rec: the body is in the key",
  $call differ ($call T.t_rec ($call kblk ("a", $call T.t_bnd (0))), $call T.t_rec ($call kblk ("b",
      $call T.t_bnd (0)))))
$decl ko01 $call check ("over: candidates are in the key",
  $call differ ($call T.t_over ($call k1 ($call T.t_func ($call k1 (kint), kint))),
                $call T.t_over ($call k1 ($call T.t_func ($call k1 (kstr), kint)))))
$decl kt01 $call check ("tmpl: the template's id is in the key",
  $call differ ($call T.t_tmpl (1), $call T.t_tmpl (2)))
$decl kt02 $call check ("tmpl: one template is one class",
  $call agree ($call T.t_tmpl (1), $call T.t_tmpl (1)))

$decl kv01 $call check ("var: the placeholder's id is its class",
  $call differ ($call T.t_var (1), $call T.t_var (2)))
$decl kv02 $call check ("bnd: the de Bruijn index is its class",
  $call differ ($call T.t_bnd (0), $call T.t_bnd (1)))
$decl kv03 $call check ("var and bnd never share a class, whatever their numbers",
  $call differ ($call T.t_var (0), $call T.t_bnd (0)))
$decl kl01 $call check ("leaves are distinct classes",
  $call P.and ($call differ (kint, kstr), $call P.and ($call differ (T.t_true, T.t_false),
      $call differ (T.t_unit, T.t_bot))))

// §6's trait, key tag 11. Members are sorted at construction, so their order is NOT in
// the key; `frame` is NOT in the key either, exactly as for a function (§5.3a).
$decl ktr  $func ($decl n "", $decl t T.proto_ty) $call T.t_trait ($call kfield (n, t))
$decl ktr2 $func ($decl n "", $decl t T.proto_ty, $decl m "", $decl u T.proto_ty)
  $call T.t_trait ($call T.fields.cons ($call T.field (n, t), $call kfield (m, u)))

$decl ktr01 $call check ("one trait built twice is one class",
  $call agree ($call ktr ("area", kint), $call ktr ("area", kint)))
$decl ktr02 $call check ("trait: a member's name is in the key",
  $call differ ($call ktr ("area", kint), $call ktr ("size", kint)))
$decl ktr03 $call check ("trait: a member's type is in the key",
  $call differ ($call ktr ("area", kint), $call ktr ("area", kstr)))
$decl ktr04 $call check ("trait: member order is NOT in the key (props are unordered)",
  $call agree ($call ktr2 ("a", kint, "b", kstr), $call ktr2 ("b", kstr, "a", kint)))
$decl ktr05 $call check ("trait: the number of members is in the key",
  $call differ ($call ktr ("a", kint), $call ktr2 ("a", kint, "b", kint)))
$decl ktr06 $call check ("trait: frame is NOT in the key (same ignores it, as for func)",
  $call agree ($call T.t_trait_fr ($call kfield ("a", kint), true),
               $call T.t_trait_fr ($call kfield ("a", kint), false)))
$decl ktr07 $call check ("a trait is not the block with the same fields",
  $call differ ($call ktr ("a", kint), $call kblk ("a", kint)))

// `Self` is the trait's binder: `bnd 0` in a member, replaced by whatever conforms.
$decl kself $call T.t_func ($call k1 ($call T.t_bnd (0)), kint)
$decl ktr08 $call check ("trait_member puts the given type for Self",
  $call T.same ($call T.trait_member ($call ktr ("area", kself), "area", kstr),
                $call T.t_func ($call k1 (kstr), kint)))
$decl ktr09 $call check ("...and answers bottom for a member it does not have",
  $call T.same ($call T.trait_member ($call ktr ("area", kself), "size", kstr), T.t_bot))
$decl ktr10 $call check ("a trait object is frame-bound exactly when its flag says so",
  $call P.and ($call T.frame_bound ($call T.t_trait_fr ($call kfield ("a", kint), true), 0),
      $call P.not ($call T.frame_bound ($call T.t_trait_fr ($call kfield ("a", kint), false), 0))))
$decl ktr11 $call check ("a trait is a binder: an outer bound variable shifts past Self",
  $call T.same ($call T.subst_bnd ($call ktr ("m", $call T.t_bnd (1)), 0, kstr),
               $call ktr ("m", kstr)))
$decl ktr12 $call check ("a placeholder in a member is a var the trait carries",
  $call T.has_var ($call ktr ("m", $call T.t_var (7)), 0))
$decl ktr13 $call check ("trait: the qualifier IS in the key (it decides what may be called)",
  $call differ ($call T.t_trait_q ($call kfield ("a", kint), false, "mut"),
                $call T.t_trait_q ($call kfield ("a", kint), false, "")))
$decl ktr14 $call check ("a mutable trait object stands for a read-only one, not the reverse",
  $call P.and ($call T.sub ($call T.t_trait_q ($call kfield ("a", kint), false, "mut"),
                            $call ktr ("a", kint)),
      $call P.not ($call T.sub ($call ktr ("a", kint),
                                $call T.t_trait_q ($call kfield ("a", kint), false, "mut")))))

// §5.3a: the parameters a function lets escape are in its key; the marks are not.
$decl kesc $func ($decl xs T.cints.node)
  $call T.t_func_x ($call k1 kint, kint, false, false, xs, T.cints.nil)
$decl kes01 $call check ("func: the escaping parameters ARE in the key",
  $call differ ($call kesc ($call T.cints.cons (0, T.cints.nil)), $call kesc (T.cints.nil)))
$decl kes02 $call check ("func: marks are NOT in the key",
  $call agree ($call T.t_func_x ($call k1 kint, kint, false, false, T.cints.nil,
                   $call T.cints.cons (64, T.cints.nil)),
               $call kesc (T.cints.nil)))
$decl kes03 $call check ("one that lets fewer escape stands for one that lets more, not the reverse",
  $call P.and ($call T.sub ($call kesc (T.cints.nil),
                            $call kesc ($call T.cints.cons (0, T.cints.nil))),
      $call P.not ($call T.sub ($call kesc ($call T.cints.cons (0, T.cints.nil)),
                                $call kesc (T.cints.nil)))))

// §4.12's `with`, key tag 12: the base and the props' names and values.
$decl kwp  $func ($decl n "", $decl v 0)
  $call T.props.cons ($call T.prop_typed (n, $call T.cv_int (v), kint), T.props.nil)
$decl kwi01 $call check ("one with built twice is one class",
  $call agree ($call T.t_with (kint, $call kwp ("k", 1)), $call T.t_with (kint, $call kwp ("k", 1))))
$decl kwi02 $call check ("with: the base is in the key",
  $call differ ($call T.t_with (kint, $call kwp ("k", 1)), $call T.t_with (kstr, $call kwp ("k", 1))))
$decl kwi03 $call check ("with: a prop's value is in the key",
  $call differ ($call T.t_with (kint, $call kwp ("k", 1)), $call T.t_with (kint, $call kwp ("k", 2))))
$decl kwi04 $call check ("a with is not its base",
  $call differ ($call T.t_with (kint, $call kwp ("k", 1)), kint))
$decl kwi05 $call check ("...but is a subtype of it (§5.1's block rule), and not the reverse",
  $call P.and ($call T.sub ($call T.t_with (kint, $call kwp ("k", 1)), kint),
      $call P.not ($call T.sub (kint, $call T.t_with (kint, $call kwp ("k", 1))))))

// §6: conformance is subtyping against a trait — a prop of the member's name whose *type*
// fits, with the conforming type for `Self`. Values are never compared.
$decl kfn    $call T.t_func ($call k1 (kint), kstr)
$decl kop    $call T.cv_opaque (1)
$decl kname  $call ktr ("name", kfn)
$decl kshape $call ktr ("area", $call T.t_func ($call k1 ($call T.t_bnd (0)), kint))

$decl trs01 $call check ("a block with the member as a prop conforms",
  $call T.sub ($call kprop ("name", kop, kfn), kname))
$decl trs02 $call check ("...one without it does not",
  $call P.not ($call T.sub ($call kprop ("size", kop, kfn), kname)))
$decl trs03 $call check ("...nor one whose prop has the wrong type",
  $call P.not ($call T.sub ($call kprop ("name", kop, $call T.t_func ($call k1 (kstr), kstr)),
      kname)))
$decl trs04 $call check ("a prop's value is never compared: different values both conform",
  $call P.and ($call T.sub ($call kprop ("name", $call T.cv_opaque (1), kfn), kname),
               $call T.sub ($call kprop ("name", $call T.cv_opaque (2), kfn), kname)))
// The prototype idiom: a block whose prop names the block itself is a μ, and conforming
// puts that block for `Self`.
$decl kproto $call T.t_rec ($call kprop ("area", kop,
    $call T.t_func ($call k1 ($call T.t_bnd (0)), kint)))
$decl trs05 $call check ("a recursive block conforms with itself for Self",
  $call T.sub (kproto, kshape))
$decl trs06 $call check ("a reference to a conforming block conforms (a trait object refers)",
  $call T.sub ($call T.t_ref ("const", $call kprop ("name", kop, kfn)), kname))
$decl trs07 $call check ("trait width: more members is a subtype of fewer",
  $call T.sub ($call ktr2 ("name", kfn, "size", kint), kname))
$decl trs08 $call check ("...and fewer is not a subtype of more",
  $call P.not ($call T.sub (kname, $call ktr2 ("name", kfn, "size", kint))))
$decl trs09 $call check ("a union of conforming blocks conforms",
  $call T.sub ($call T.union2 ($call kprop ("name", $call T.cv_opaque (1), kfn),
                               $call kprop ("name", $call T.cv_opaque (2), kfn)), kname))
$decl trs10 $call check ("a trait is not a subtype of a block",
  $call P.not ($call T.sub (kname, $call kprop ("name", kop, kfn))))
$decl trs11 $call check ("a block's *fields* do not meet a member: a trait describes props",
  $call P.not ($call T.sub ($call kblk ("name", kfn), kname)))

// §4.10's `rmut`: part of a function's identity, unlike `frame`, and one-directional in
// subtyping — a function needing a mutable receiver does not stand for one that does not.
$decl krm  $call T.with_rmut ($call T.t_func ($call k1 (kint), kint))
$decl krm0 $call T.t_func ($call k1 (kint), kint)
$decl krm01 $call check ("func: rmut is in the key",
  $call differ (krm, krm0))
$decl krm02 $call check ("a function not needing a mutable receiver stands for one that does",
  $call T.sub (krm0, krm))
$decl krm03 $call check ("...and one needing it does not stand for one that does not",
  $call P.not ($call T.sub (krm, krm0)))

$decl done_k $call nl ("all class-key tests passed")
