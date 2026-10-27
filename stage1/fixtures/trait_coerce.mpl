// §7.4 through a trait object. §5.1 lets an implementation's member answer a subtype of
// the trait's member and take a supertype of its parameter, and a call through the object
// is made with the trait's signature (§6) — so where the member's C signature differs, the
// table's entry is an adapter (`emit.mpl`, `emit_tad`). Without it the member wrote a
// larger result than its caller made room for, and the heap was corrupted.
//
// The digits: a prefix result, from a module's implementation (7); a block result where the
// trait says `()`, the call still made (3); a member of a union result (4); a parameter the
// other way round (5); one implementation as two traits, adapted for one and not the other
// (8, 6); and a tail call through the object, which puts §6a's trampoline in the program
// (9). 7345869.

$decl U $import "trait_coerce_util"

$decl cnt $mut $alloc 0
$decl poke_proto { $prop poke $func ($decl n 0) () }
$decl poker $alloc { $prop poke $func ($decl n 0) $do ($set cnt n) { $decl a n  $decl b n } }
// The cell's value, read through (§5.4).
$decl P_ival $func ($decl x 0) x
$decl do_poke $func ($decl p $traitsof poke_proto) $do ($call p.poke (3)) ($call P_ival (cnt))

$decl pick_proto { $prop pick $func () $union ({ $prop tag "a" }, { $prop tag "b" $decl v 0 }) }
$decl picker $alloc { $prop pick $func () { $prop tag "b" $decl v 4 } }
$decl do_pick $func ($decl p $traitsof pick_proto) {
  $decl r   $call p.pick ()
  $decl ret $match r ($case {$prop tag "b"} r.v, $case r 0)
}.ret

$decl eat_proto { $prop eat $func ($decl x { $decl a 0  $decl b 0  $decl c 0 }) 0 }
$decl eater $alloc { $prop eat $func ($decl x { $decl a 0 }) x.a }
$decl do_eat $func ($decl p $traitsof eat_proto) $call p.eat ({ $decl a 5  $decl b 1  $decl c 1 })

$decl one_proto { $prop make $func ($decl n 0) { $decl a 0 } }
$decl two_proto { $prop make $func ($decl n 0) { $decl a 0  $decl b 0 } }
$decl thing $alloc { $prop make $func ($decl n 0) { $decl a n  $decl b n } }
$decl by_one $func ($decl p $traitsof one_proto) { $decl r $call p.make (8)  $decl ret r.a }.ret
$decl by_two $func ($decl p $traitsof two_proto) { $decl r $call p.make (6)  $decl ret r.b }.ret

// In tail position, through the object: the caller reports and its caller drives (§6a).
$decl via $func ($decl m $traitsof U.maker_proto, $decl n 0) $call m.make (n)

$decl d $func ($decl acc 0, $decl x 0) $call add ($call mul (acc, 10), x)

$decl main $func () {
  $decl a   $call U.use (U.big, 5)
  $decl b   $call do_poke (poker)
  $decl c   $call do_pick (picker)
  $decl e   $call do_eat (eater)
  $decl f   $call by_one (thing)
  $decl g   $call by_two (thing)
  $decl h   $call via (U.big, 7)
  $decl ret $call d ($call d ($call d ($call d ($call d ($call d (a, b), c), e), f), g), h.a)
}.ret
