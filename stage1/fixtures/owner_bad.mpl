// DEFER.md step 3's checks. §5.3a's owner rule: a value projected out of a discarded
// block may not hold a place that block owns. And what is not implemented yet: a `$new`
// block with a `$defer` in an `$if` arm (it needs a flag per site), passed to a call that
// can hand a place back (its owner depends on the callee), and at a file's top level.
$decl alias $func () {
  $decl r   { $decl x $new 5  $decl ret2 x }.ret2
  $decl ok  { $decl y $new 5  $decl ret3 $call add (y, 1) }.ret3
  $decl ret ok
}.ret
$decl arm $func ($decl c $union (false, true)) {
  $decl p   $if c ($new { $decl k 1  $defer $call print ("a") }) ($new { $decl k 2 })
  $decl ret 0
}.ret
$decl id  $func ($decl c $new { $decl k 0 }) c
$decl via $func () {
  $decl a   $call id ($new { $decl k 1  $defer $call print ("v") })
  $decl ret a.k
}.ret
$decl top $new { $decl k 1  $defer $call print ("t") }
