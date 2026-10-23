// DEFER.md step 3's check, §5.3a's owner rule: a value projected out of a discarded block
// may not hold a place that block owns.
$decl alias $func () {
  $decl r   { $decl x $new 5  $decl ret2 x }.ret2
  $decl ok  { $decl y $new 5  $decl ret3 $call add (y, 1) }.ret3
  $decl ret ok
}.ret
