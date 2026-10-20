// TRAITS.md: a trait is its props' signatures as written. A parameter defaulted to the
// declaring name is that concrete type in the trait, and a member taking another
// implementation says so with `$traitsof`. There is no `Self`, so every member of every
// trait object is callable — before, `$call o.same (p)` was refused ("mentions Self").
//
// 1 + 20 + 200 = 221: a member taking its own block's type, through an object; and a
// member taking any implementation of another trait, called through objects of two types.
// (A trait taking *itself* — `bigger ($decl o $traitsof shape_proto)` inside `shape_proto` —
// is TRAITS.md's step 3.)

$decl ieq eq

$decl pt  { $decl x 3  $decl y 4
  $prop same $func ($decl other pt)
    $if ($call ieq (pt.x, other.x)) ($call ieq (pt.y, other.y)) false
}
$decl pt_t $traitsof pt

$decl area_proto  { $prop area $func () 0 }
$decl sized       $traitsof area_proto
$decl shape_proto { $prop area $func () 0
                    $prop bigger $func ($decl o sized) $union (false, true) }
$decl shape $traitsof shape_proto
$decl sq  { $decl s 3  $prop area $func () $call mul (sq.s, sq.s)
            $prop bigger $func ($decl o sized) $call lt ($call o.area (), $call sq.area ()) }
$decl rc  { $decl w 2  $decl h 5  $prop area $func () $call mul (rc.w, rc.h)
            $prop bigger $func ($decl o sized) $call lt ($call o.area (), $call rc.area ()) }

$decl same_via $func ($decl o pt_t, $decl p pt) $call o.same (p)
$decl wins     $func ($decl a shape, $decl b sized) $if ($call a.bigger (b)) 1 0

$decl main $func () {
  $decl s1  $if ($call same_via (pt, pt)) 1 0
  $decl s2  $call mul ($call wins (rc, sq), 20)
  $decl s3  $call mul ($call add ($call wins (sq, rc), 2), 100)
  $decl ret $call add ($call add (s1, s2), s3)
}.ret
