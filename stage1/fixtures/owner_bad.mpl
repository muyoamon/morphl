// DEFER.md step 3's checks. §5.3a's owner rule: a value projected out of a discarded
// block may not hold a place that block owns. And a `$new` block with a `$defer` outside
// `$decl x $new { … }` in a scope — a record kept as a value, an ephemeral one, and
// `$alloc` (step 4) — is refused until its owner is defined.
$decl alias $func () {
  $decl r   { $decl x $new 5  $decl ret2 x }.ret2
  $decl ok  { $decl y $new 5  $decl ret3 $call add (y, 1) }.ret3
  $decl ret ok
}.ret
$decl val $func () {
  $decl w   { $decl n $new { $decl k 1  $defer $call print ("n") } }
  $decl ret 0
}.ret
$decl use $func ($decl c $new { $decl k 0 }) c.k
$decl eph $func () {
  $decl a   $call use ($new { $decl k 1  $defer $call print ("e") })
  $decl ret a
}.ret
$decl al  $func () {
  $decl y   $alloc { $decl k 1  $defer $call print ("y") }
  $decl ret 0
}.ret
