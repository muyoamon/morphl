// A round-trip fixture for §4.15: `$try` is the language's only non-local exit,
// and only a conditional one. Prints 5.
//
// `quarter` halves twice; each `$try` returns `none` from *quarter* the moment
// a halving fails, so the second never runs on an odd number. Nothing declares
// that failure — §4.15 widens quarter's inferred result to include it, which is
// why the C function returns a union.
$decl half $func ($decl n 0)
  $if ($call eq_int ($call mod (n, 2), 0)) ($call div (n, 2)) none

$decl quarter $func ($decl n 0)
  { $decl h $try ($call half (n)) none
    $decl out $try ($call half (h)) none }.out

// §4.7 is how the caller consumes it: a literal pattern is its base type, so
// `$case 0` selects the Int member and narrows `r` to it.
$decl or_zero $func ($decl n 0)
  { $decl r $call quarter (n)
    $decl out $match r ($case {$prop tag "none"} 0, $case 0 r) }.out

$decl main $func () $call add ($call or_zero (20), $call or_zero (6))
