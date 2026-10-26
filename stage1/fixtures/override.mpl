// §4.12a's `$override x override`, the mirror of `$impl`: each prop of `override` replaces
// the one of that name `x` has, at a subtype of its type, and nothing is added.
//
// On a value — 4, 33, 30, 4, 4, 2 and 7: the replaced member answers the override's; a base
// member calling it keeps calling the base's, since binding is static; the base itself is
// untouched; the result is still a `$traitsof` the base's trait and passes the bound a
// template asks; a scalar prop is replaced too; and a base member taking a `$mut` receiver
// is reached through the result's storage, which has the base's layout and not its type.
//
// On a template — 1400, 1400, 1003 and 101: the override's props are spliced into the body
// in place of the ones they name, so the base's `has`, which needs the element's `same`
// member, is never typed at `Str` or `Int`, and the base's `count` reaches the replacement.
// The override's `step` is this file's (2 * 7 = 14), the base's `step` stays the module's
// (101), and `$specialize` at two types makes two instances. Then D3a's overload in the
// module picks the `Str` candidate, derived by an `$override` inside a template, and the
// base for a block that has `same`. Compiled only: stage 0 leaves `$override` out.

$decl U $import "override_util"

$decl shape_proto { $prop area $func () 0 }

$decl a {
  $decl w 3
  $prop k    1
  $prop area $func () $call mul (a.w, 10)
  $prop dbl  $func () $call add ($call a.area (), a.w)
}
$decl b $override a {
  $prop k    2
  $prop area $func () $call add (b.w, 1)
}

$decl area_of $template ($decl X $traitsof shape_proto) $func ($decl x X) $call x.area ()

$decl ctr $mut $alloc {
  $decl n $mut $alloc 5
  $prop bump $func () $set ctr.n ($call add (ctr.n, 2))
}
$decl ctr2 $mut $alloc $override ctr { }

$decl step $func ($decl n 0) $call mul (n, 7)

$decl sbox $override U.box {
  $prop has  $func ($decl b ($call make ("")), $decl y "") $call eq (b.item, y)
  $prop size $func ($decl b ($call make (""))) $call step (2)
}
$decl strs $specialize sbox ""

$decl ibox $override U.box {
  $prop has $func ($decl b ($call make (0)), $decl y 0) $call eq (b.item, y)
}
$decl ints $specialize ibox 0

$decl same_box { $decl v 3  $prop same $func ($decl o same_box) $call eq (same_box.v, o.v) }

// `acc` with `n` after it, a space between.
$decl w $func ($decl acc "", $decl n 0)
  $call concat (acc, $call concat ($if ($call eq ($call len (acc), 0)) "" " ", $call int_to_str (n)))

$decl main $func () {
  $decl o    $traitsof b
  $decl v1   $call b.area ()
  $decl v2   $call b.dbl ()
  $decl v3   $call a.area ()
  $decl v4   $call o.area ()
  $decl v5   $call area_of (b)
  $decl v6   b.k
  $decl bm   $call ctr2.bump ()
  $decl v7   ctr2.n
  $decl sb   $call strs.make ("hi")
  $decl t1   $call add ($call mul ($call strs.count (sb, "hi"), 100), $call strs.count (sb, "no"))
  $decl ib   $call ints.make (4)
  $decl t2   $call add ($call mul ($call ints.count (ib, 4), 10), $call ints.count (ib, 5))
  $decl db   $call ($specialize U.boxes "").make ("x")
  $decl t3   $call ($specialize U.boxes "").count (db, "x")
  $decl ob   $call ($specialize U.boxes same_box).make (same_box)
  $decl t4   $call ($specialize U.boxes same_box).count (ob, same_box)
  $decl r1   $call w ($call w ($call w ($call w ($call w ("", v1), v2), v3), v4), v5)
  $decl r2   $call w ($call w ($call w ($call w ($call w ($call w (r1, v6), v7), t1), t2), t3), t4)
  $decl ret  $call concat (r2, "\n")
}.ret
