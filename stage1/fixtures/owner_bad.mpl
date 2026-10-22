// DEFER.md step 3's checks. §5.3a's owner rule: a value projected out of a discarded
// block may not hold a place that block owns. And what is not implemented yet: a `$new`
// block with a `$defer` passed to a call that can hand a place back (its owner depends on
// the callee), and at a file's top level. (One in an `$if` arm is `defer_arm.mpl`'s.)
$decl alias $func () {
  $decl r   { $decl x $new 5  $decl ret2 x }.ret2
  $decl ok  { $decl y $new 5  $decl ret3 $call add (y, 1) }.ret3
  $decl ret ok
}.ret
$decl id  $func ($decl c $new { $decl k 0 }) c
$decl via $func () {
  $decl a   $call id ($new { $decl k 1  $defer $call print ("v") })
  $decl ret a.k
}.ret
$decl top $new { $decl k 1  $defer $call print ("t") }
