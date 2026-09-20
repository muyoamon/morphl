// A round-trip fixture for §6a's mutual case: a tail-recursive group through
// `$fwd` is contified into one function with a state variable and one dispatch
// loop. Prints 1.
//
// §12's own even/odd. 2,000,000 alternations, and `zig build test-emit` builds
// it at -O0 — so if the recursion were still a pair of calls this would
// overflow rather than answer. §4.11's `$fwd` is what makes the group
// identifiable: its slots are completed in one block.
$fwd odd

$decl even $func ($decl n 0) $if ($call eq_int (n, 0)) 1 ($call odd  ($call sub (n, 1)))
$decl odd  $func ($decl n 0) $if ($call eq_int (n, 0)) 0 ($call even ($call sub (n, 1)))

$decl main $func () $call even (2000000)
