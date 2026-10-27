// §3.6: "A value enters a union as its most specific member." A value of neither member's
// exact type that is a subtype of both goes in the one below the other — here `spe`, which
// extends `gen` — whatever their order in the union. First fit by position took `gen`, which
// sorts first (§7.5's order is by rendering), and the extra fields were lost.
//
// 1 for `spe`, 2 for `gen`: a value extending `spe` (1), one extending only `gen` (2), and
// `spe` itself (1). 121.

$decl gen { $prop t "x"  $decl a 0 }
$decl spe { $prop t "x"  $decl a 0  $decl z 0 }

$decl which $func ($decl u $union (gen, spe)) $match u ($case spe 1, $case u 2)

$decl main $func () {
  $decl v1  { $prop t "x"  $decl a 1  $decl z 2  $decl q 3 }
  $decl v2  { $prop t "x"  $decl a 1  $decl y 2 }
  $decl a   $call which (v1)
  $decl b   $call which (v2)
  $decl c   $call which (spe)
  $decl ret $call add ($call mul ($call add ($call mul (a, 10), b), 10), c)
}.ret
