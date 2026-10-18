// §5.3a's provenance (STORAGE.md), the refusing side: a place this call made may not be
// returned (§R), stored inside a value (A0), or passed by a tail call (A4). Each is a
// static rule stage 0 does not check, so only stage 1 is asked to refuse.

$decl ival $func ($decl x 0) x
$decl id_ref $func ($decl p $mut $new 0) p

// Returned: its own `$new`, the same lent to a call that hands it back, and a closure
// capturing it.
$decl own  $func () $new 3
$decl bad  $func () { $decl c $mut $new 0  $decl ret $call id_ref (c) }.ret
$decl clo  $func () { $decl c $mut $new 0  $decl ret $func () $call ival (c) }.ret

// Stored: a block carrying a place, into a cell.
$decl keep $func () {
  $decl loc $mut $new 7
  $decl b   $mut $new { $decl r loc }
  $decl ret 0
}.ret

// Passed by a tail call: the next iteration reuses this frame.
$decl fresh $func ($decl c $new 0, $decl n 0)
  $if ($call eq_int (n, 0)) ($call ival (c)) ($call fresh ($new n, $call sub (n, 1)))
