// SPEC §5.3a's A0, the accepting side: storage holds no place that may end before it, so it
// may hold one that outlives it. A frame `$new` holding places made before it, a `$set` of a
// place the caller lent into a cell this call made, and a constructor keeping a place its
// caller lent, which its deferral writes through. Each aliases rather than copies, which the
// answers show. Both stages run it; stage 0 checks none of §5.3a.
$decl ival $func ($decl x 0) x

// A: 9 written through `loc` is read through `s.r`, beside storage of `s`'s own: 11.
$decl case_a $func () {
  $decl loc $mut $new 7
  $decl s   $new { $decl r loc  $decl own $mut $new 1 }
  $decl w   $set loc 9
  $decl w2  $set s.own 2
  $decl ret $call add ($call ival (s.r), $call ival (s.own))
}.ret

// B: after the `$set`, `s.r` is the caller's cell, so writing it writes `c`: 5 + 5.
$decl set_lent $func ($decl p $mut $new 0) {
  $decl s   $mut $new { $decl r $mut $new 0 }
  $decl w   $set s { $decl r p }
  $decl w2  $set s.r 5
  $decl ret $call ival (s.r)
}.ret
$decl case_b $func () {
  $decl c   $mut $new 0
  $decl x   $call set_lent (c)
  $decl ret $call add (x, $call ival (c))
}.ret

// C: the constructed block keeps the caller's cell; 8 is written through it and read, and
// the deferral, when the block's scope ends, writes 40 into the caller's cell: 8 + 40.
$decl keeper $func ($decl p $mut $new 0) $new {
  $decl r p
  $defer $set r 40
}
$decl use_k $func ($decl p $mut $new 0) {
  $decl k   $call keeper (p)
  $decl w   $set k.r 8
  $decl ret $call ival (k.r)
}.ret
$decl case_c $func () {
  $decl loc $mut $new 3
  $decl x   $call use_k (loc)
  $decl ret $call add (x, $call ival (loc))
}.ret

$decl main $func ()
  $call concat ($call int_to_str ($call case_a ()),
      $call concat ($call int_to_str ($call case_b ()), $call int_to_str ($call case_c ())))
