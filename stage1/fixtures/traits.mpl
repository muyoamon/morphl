// §6, §4.12 and §4.13 end to end: a trait object is a reference to its referent and the
// implementation its calls dispatch to, made by coercion, by `$traitsof`, or from an
// `$impl`'d value, and called through with the referent as the receiver.
//
// 37 + 7 + 12 + 2 + 4 + 25 = 87.

$decl ival $func ($decl x 0) x

$decl shape_proto { $prop area $func () 0 }

// `rect`'s and `sq`'s members reach their receiver by the declaring name (§4.10).
$decl rect { $decl w 3  $decl h 4
  $prop area $func () $call mul (rect.w, rect.h)
}
$decl sq { $decl side 5
  $prop area $func () $call mul (sq.side, sq.side)
}

// Both conform, so each coerces to a trait object at the call — two implementations
// behind one parameter type.
$decl total $func ($decl a $traitsof shape_proto, $decl b $traitsof shape_proto)
  $call add ($call a.area (), $call b.area ())

$decl one $func ($decl s $traitsof shape_proto) $call s.area ()

// `Int` has no props; `$impl` gives this value the member, and it is still an `Int`.
$decl n   7
$decl n_s $impl n ($traitsof shape_proto) { $prop area $func () $call add (n_s, 0) }

// Storage of trait type holds trait objects, and `$set` replaces the whole object.
$decl cur $mut $alloc $traitsof shape_proto

// A trait object of `$mut` storage refers to it: its member's receiver is the storage, so
// a write through the object is seen through the name.
$decl counter $mut $alloc { $decl n $mut $alloc 0
  $prop bump $func () $set counter.n ($call add ($call ival (counter.n), 1))
}
$decl cnt $traitsof counter

// §4.7: a trait object is not inspected, so the catch-all is the arm.
$decl m $func ($decl s $traitsof shape_proto) $match s ($case s $call s.area ())

$decl main $func () {
  $decl s1  $call total (rect, sq)
  $decl s2  $call one (n_s)
  $decl w   $set cur rect
  $decl s3  $call cur.area ()
  $decl b   $do ($call cnt.bump ()) ($call cnt.bump ())
  $decl s4  $call ival (counter.n)
  // §4.13: an expression operand is placed in fresh frame storage.
  $decl s5  $call one ($traitsof { $prop area $func () 4 })
  $decl s6  $call m (sq)
  $decl ret $call add ($call add ($call add (s1, s2), $call add (s3, s4)), $call add (s5, s6))
}.ret
