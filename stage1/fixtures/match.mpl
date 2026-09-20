// A round-trip fixture for §4.7 and §7.5: `$match` is the one construct that
// reads runtime type information, and a union value carries a discriminator so
// it can. Straight from §12's "Tagged blocks and match". Prints 25.
$decl circle { $prop kind "circle"  $decl r 3 }
$decl square { $prop kind "square"  $decl w 4 }

// §4.7: inside an arm the scrutinee is narrowed to `type(s) & P`, which is what
// lets `s.r` reach a field only the circle has.
$decl area $func ($decl s $union (circle, square)) $match s (
  $case {$prop kind "circle"} $call mul (s.r, s.r),
  $case {$prop kind "square"} $call mul (s.w, s.w)
)

$decl main $func () $call add ($call area (circle), $call area (square))
