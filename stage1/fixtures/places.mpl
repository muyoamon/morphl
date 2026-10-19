// §5.3a's provenance (STORAGE.md), the refusing side: a place this call made may not be
// returned (§R), stored inside a value (A0), or passed by a tail call (A4) — including a
// trait object §6's coercion makes over this call's own storage. Each is a
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

// §6's coercion makes a trait object referring to the argument's own storage. A tail call
// through a function value ends this call before the callee runs (§6a's trampoline), and
// a cell the caller lent outlives it.
$decl shape { $prop area $func () 0 }
$decl seven { $decl v 7  $prop area $func () seven.v }
$decl k     $mut $alloc $func ($decl t $traitsof shape, $decl n 0) 0
$decl hop   $func ($decl r seven, $decl n 0) $call k (r, n)
$decl stash $func ($decl c $mut $new $traitsof shape, $decl r seven) {
  $decl w   $set c r
  $decl ret 0
}.ret

// A borrowed trait result over this call's own local is this call's own place; and a join
// is frame-bound if either arm is, whichever arm that is.
$decl bigger $func ($decl a $traitsof shape, $decl b $traitsof shape)
  $if ($call lt ($call a.area (), $call b.area ())) b a
$decl own_big $func () {
  $decl loc { $prop area $func () 5 }
  $decl ret $call bigger ($traitsof loc, $traitsof seven)
}.ret
$decl own_arm $func ($decl c $union (false, true)) {
  $decl loc { $prop area $func () 5 }
  $decl ret $if c ($traitsof loc) ($traitsof seven)
}.ret
