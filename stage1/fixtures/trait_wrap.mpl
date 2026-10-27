// §6 with §7.4: one trait object used as another whose member has another signature — a
// narrower result, a wider parameter — which the old backend refused. An entry is known only
// at run time, so the object is wrapped: its referent is the original object and its table
// the target's, of thunks that call the original's entry and coerce around it (`emit.mpl`,
// `emit_retable`, `rt_name`).
//
// The digits: a narrower result through the wrapper (5), a parameter taking a longer block
// (3), members reordered as well as adapted (4 and 1), a member taking a trait object, so the
// thunk wraps its argument in turn (6), and a module's own wrapper (8). 534168.

$decl U $import "trait_wrap_util"

// A narrower result.
$decl big_proto   { $prop make $func ($decl n 0) { $decl a 0  $decl b 0 } }
$decl small_proto { $prop make $func ($decl n 0) { $decl a 0 } }
$decl maker $alloc { $prop make $func ($decl n 0) { $decl a n  $decl b 7 } }
$decl small_a $func ($decl s $traitsof small_proto) { $decl r $call s.make (5)  $decl ret r.a }.ret
$decl by_big  $func ($decl o $traitsof big_proto) $call small_a (o)

// A parameter the other way round: the source member takes `{a}`, the target passes `{a, b, c}`.
$decl short_proto { $prop eat $func ($decl x { $decl a 0 }) 0 }
$decl long_proto  { $prop eat $func ($decl x { $decl a 0  $decl b 0  $decl c 0 }) 0 }
$decl eater $alloc { $prop eat $func ($decl x { $decl a 0 }) x.a }
$decl long_eat $func ($decl l $traitsof long_proto)
  $call l.eat ({ $decl a 3  $decl b 0  $decl c 0 })
$decl by_short $func ($decl s $traitsof short_proto) $call long_eat (s)

// Reordered as well as adapted: the source sorts `a`, `z`; the target only `z`, and narrower.
$decl two_proto { $prop a $func () 1  $prop z $func () { $decl p 0  $decl q 0 } }
$decl one_proto { $prop z $func () { $decl p 0 } }
$decl both $alloc { $prop a $func () 1  $prop z $func () { $decl p 4  $decl q 9 } }
$decl one_z  $func ($decl o $traitsof one_proto) ($call o.z ()).p
$decl by_two $func ($decl t $traitsof two_proto) $call one_z (t)
$decl two_a  $func ($decl t $traitsof two_proto) $call t.a ()

// A member taking a trait object: the target passes a `big` object where the source's member
// takes a `small` one, so the thunk wraps that argument as well.
$decl user_s_proto { $prop use $func ($decl s $traitsof small_proto) 0 }
$decl user_b_proto { $prop use $func ($decl s $traitsof big_proto) 0 }
$decl user $alloc { $prop use $func ($decl s $traitsof small_proto)
                      { $decl r $call s.make (6)  $decl ret r.a }.ret }
$decl use_b   $func ($decl u $traitsof user_b_proto) $call u.use (maker)
$decl by_user $func ($decl u $traitsof user_s_proto) $call use_b (u)

$decl wide $alloc { $prop make $func ($decl n 0) { $decl a n  $decl b 0 } }

$decl d $func ($decl acc 0, $decl x 0) $call add ($call mul (acc, 10), x)

$decl main $func () {
  $decl a   $call by_big (maker)
  $decl b   $call by_short (eater)
  $decl c   $call by_two (both)
  $decl e   $call two_a (both)
  $decl f   $call by_user (user)
  $decl g   $call U.via (wide)
  $decl ret $call d ($call d ($call d ($call d ($call d (a, b), c), e), f), g)
}.ret
