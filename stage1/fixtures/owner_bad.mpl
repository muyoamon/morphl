// DEFER.md step 3's checks. §5.3a's owner rule: a value projected out of a discarded
// block may not hold a place that block owns. And what is not defined yet: a `$new` block
// with a `$defer` at a file's top level. (One in an `$if` arm is `defer_arm.mpl`'s, and
// one passed to a call that may hand it back `defer_call.mpl`'s.)
$decl alias $func () {
  $decl r   { $decl x $new 5  $decl ret2 x }.ret2
  $decl ok  { $decl y $new 5  $decl ret3 $call add (y, 1) }.ret3
  $decl ret ok
}.ret
$decl top $new { $decl k 1  $defer $call print ("t") }
