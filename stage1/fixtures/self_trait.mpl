// TRAITS.md, design point 7: a trait that names itself is tied by §5.5's knot. Taken while
// its block was still being typed, `$traitsof shape_proto` inside `shape_proto` captured the
// members not yet typed as ⊥ (`bigger : [!]`), and nothing conformed. Both forms close now:
// by the block's declaring name, and by a specialisation of the template being typed.
//
// 10 + 100 + 6 = 116: a shape bigger than another, through a trait whose member takes the
// trait itself; a member projecting off that parameter; and three steps through `seq`, whose
// `rest` answers its own specialisation's trait. A prototype's example of a trait-typed
// result is made from `$alloc`ed storage — `$traitsof` of a temporary is frame storage, which
// §5.3a keeps from escaping, and a template's body has no receiver to point at.

$decl ival $func ($decl x 0) x

$decl shape_proto { $prop area $func () 0
                    $prop bigger $func ($decl o $traitsof shape_proto) $union (false, true) }
$decl shape $traitsof shape_proto
$decl sq  { $decl s 3  $prop area $func () $call mul (sq.s, sq.s)
            $prop bigger $func ($decl o shape) $call lt ($call o.area (), $call sq.area ()) }
$decl rc  { $decl w 2  $decl h 5  $prop area $func () $call mul (rc.w, rc.h)
            $prop bigger $func ($decl o shape) $call lt ($call o.area (), $call rc.area ()) }
$decl wins $func ($decl a shape, $decl b shape) $if ($call a.bigger (b)) 1 0

// A member that reads its own trait's parameter through it.
$decl s2 { $decl k 1  $prop size $func () s2.k
           $prop bigger $func ($decl o $traitsof s2) $call lt ($call o.size (), s2.k) }
$decl t2 { $decl k 5  $prop size $func () t2.k  $prop bigger $func ($decl o $traitsof s2) false }

$decl seq $template T {
  $prop first $func () $union (none, { $prop tag "some"  $decl v T })
  $prop rest  $func () $traitsof $alloc ($specialize seq T)
}
$decl iseq $traitsof ($specialize seq 0)
$decl cd { $decl n $mut $alloc 3
  $prop first $func ()
    $if ($call lt (0, $call ival (cd.n))) { $prop tag "some"  $decl v $call ival (cd.n) } none
  $prop rest  $func () $do ($set cd.n ($call sub ($call ival (cd.n), 1))) ($traitsof cd) }
$decl total $func ($decl s iseq, $decl n 0, $decl acc 0)
  $if ($call eq (n, 0)) acc {
    $decl f   $call s.first ()
    $decl a2  $match f ($case {$prop tag "some"} $call add (acc, f.v), $case f acc)
    $decl ret $call total ($call s.rest (), $call sub (n, 1), a2)
  }.ret

$decl main $func () {
  $decl a   $call add ($call mul ($call wins (rc, sq), 10), $call wins (sq, rc))
  $decl b   $if ($call s2.bigger (t2)) 0 100
  $decl c   $call total (cd, 3, 0)
  $decl ret $call add ($call add (a, b), c)
}.ret
