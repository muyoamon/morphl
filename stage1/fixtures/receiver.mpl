// §4.10's receiver: inside a member, the name of the `$decl` holding its block is the
// value the member was reached through. A member that names it is a closure over it, so
// it reaches the right value however it was reached.
//
// 12 + 12 + 10 + 2 + 12 = 48.

$decl ival $func ($decl x 0) x

$decl rect { $decl w 3  $decl h 4
  $prop area $func () $call mul (rect.w, rect.h)
}

// A member taken as a value is a closure over its receiver.
$decl apply $func ($decl f $func () 0) $call f ()

// A block declared inside a function: its receiver is a local, which a prop could not
// otherwise reach — a prop cannot capture.
$decl local $func ($decl k 0) {
  $decl r { $decl v k
    $prop twice $func () $call add (r.v, r.v)
  }
  $decl ret $call r.twice ()
}.ret

// `$mut` storage: the receiver is the reference, so a write through it is seen.
$decl counter $mut $alloc { $decl n $mut $alloc 0
  $prop bump $func () $set counter.n ($call add ($call ival (counter.n), 1))
}

// A copy reaches the member through itself.
$decl rc rect

$decl main $func () {
  $decl s1 $call rect.area ()
  $decl s2 $call apply (rect.area)
  $decl s3 $call local (5)
  $decl s4 $do ($call counter.bump ()) ($do ($call counter.bump ()) ($call ival (counter.n)))
  $decl s5 $call rc.area ()
  $decl ret $call add ($call add ($call add (s1, s2), $call add (s3, s4)), s5)
}.ret
