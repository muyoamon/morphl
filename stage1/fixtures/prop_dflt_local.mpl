// A `$func` prop written in a function may name a local for a parameter's type: a default is
// type-only where it is written (§5.7), so it is no capture of the prop (§4.10), which has
// nowhere to evaluate one. Lowering counted it as one, so a trait's prototypes declared in
// the function using them were refused — `trait_wrap.mpl` with its top level in a function.
//
// The digits: a member taking a trait object of a local prototype (3), one taking a local
// block itself (4), a member of a prototype whose own member names another local prototype
// (6), an override of a local default by a short call's wrapper that reads only what a
// wrapper can — a literal and a sibling prop (8), and the same member from a nested function
// (5). 34685.

$decl run $func () {
  $decl small_proto { $prop make $func ($decl n 0) { $decl a 0 } }
  $decl maker $alloc { $prop make $func ($decl n 0) { $decl a n  $decl b 9 } }
  $decl user $alloc { $prop use $func ($decl s $traitsof small_proto)
                        { $decl r $call s.make (3)  $decl ret r.a }.ret }
  $decl one { $prop k 4 }
  $decl reader { $prop read $func ($decl o one) o.k }
  $decl user_proto { $prop use $func ($decl s $traitsof small_proto) 0 }
  $decl twice $func ($decl u $traitsof user_proto) $call add ($call u.use (maker), 3)
  $decl dflt { $prop one_more 1
               $prop bump $func ($decl x 7, $decl y one_more) $call add (x, y) }
  $decl nested $func () $call dflt.bump (4)
  $decl d $func ($decl acc 0, $decl x 0) $call add ($call mul (acc, 10), x)
  $decl ret $call d ($call d ($call d ($call d ($call user.use (maker),
      $call reader.read (one)), $call twice (user)), $call dflt.bump ()), $call nested ())
}.ret

$decl main $func () $call run ()
