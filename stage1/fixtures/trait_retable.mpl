// §6 with §7.4: one trait object used as another. Both are `mpl_tobj`, so this was a copy —
// and a call through the result indexes the table by the target trait's member order (§6
// sorts members by name), so `b` through `$traitsof small` called `big`'s `a`. Unless the two
// traits lay their tables out alike, the coercion builds the target's table out of the
// source's, by member name (`emit.mpl`, `emit_retable`).
//
// The digits: `b` through a narrower trait (2), `c` through one whose members sit elsewhere
// (3), `c` through a function value coerced to take the wider trait, re-tabled in its shim
// (3), and two traits with one layout, copied as they are (4). 2334.

$decl big_proto   { $prop a $func () 1  $prop b $func () 2  $prop c $func () 3 }
$decl small_proto { $prop b $func () 0 }
$decl tail_proto  { $prop c $func () 0 }
$decl same_proto  { $prop a $func () 0  $prop b $func () 0  $prop c $func () 0 }

$decl thing $alloc { $prop a $func () 4  $prop b $func () 2  $prop c $func () 3 }

$decl via_small $func ($decl s $traitsof small_proto) $call s.b ()
$decl via_tail  $func ($decl s $traitsof tail_proto) $call s.c ()
$decl via_same  $func ($decl s $traitsof same_proto) $call s.a ()

$decl b_of $func ($decl o $traitsof big_proto) $call via_small (o)
$decl c_of $func ($decl o $traitsof big_proto) $call via_tail (o)
$decl a_of $func ($decl o $traitsof big_proto) $call via_same (o)
$decl call_with $func ($decl f $func ($decl o $traitsof big_proto) 0, $decl o $traitsof big_proto)
  $call f (o)

$decl d $func ($decl acc 0, $decl x 0) $call add ($call mul (acc, 10), x)

$decl main $func () {
  $decl a   $call b_of (thing)
  $decl b   $call c_of (thing)
  $decl c   $call call_with (via_tail, thing)
  $decl e   $call a_of (thing)
  $decl ret $call d ($call d ($call d (a, b), c), e)
}.ret
