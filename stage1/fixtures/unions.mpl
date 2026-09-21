// A round-trip fixture for §4.8a: `$union` *evaluates to its first member* and
// has the type of all of them joined. Prints 91.
//
// `shape` is a value of type `circle | square` whose value is `circle` — which
// is what makes `$union` a way to widen without changing anything, and why the
// members after the first are type-only positions (§5.7) that are never run.
$decl circle { $prop kind "circle"  $decl r 3 }
$decl square { $prop kind "square"  $decl w 4 }

$decl shape $union (circle, square)

$decl area $func ($decl s $union (circle, square)) $match s (
  $case {$prop kind "circle"} $call mul (s.r, s.r),
  $case {$prop kind "square"} $call mul (s.w, s.w)
)

// The same widening on storage: §4.2 gives `$new` the type of its operand, so
// this is a Bool cell holding `false` — and §3.2 makes `$if` a `$match` over
// booleans, which is how it is read back.
$decl flag $mut $new ($union (false, true))

$decl main $func ()
  $do ($set flag true)
     ($call add ($call mul ($call area (shape), 10),
                 $match flag ($case true 1, $case flag 0)))
