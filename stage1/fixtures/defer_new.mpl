// DEFER.md step 3: `$decl x $new { … $defer … }` in a scope. `x` owns the storage and
// dies at its block's end, so the storage's deferrals are that block's: run there, in
// reverse order among its own, and by a `$try` leaving through it. Each step appends a
// digit, so the answer is the order: 213 654 9.
//   213  the storage's deferral runs at its owner's block's end, after that block's work
//   654  by position among the block's own deferrals; it reads its fields at the end
//   9    a `$try` leaving the owner's block runs it too
$decl log  $mut $alloc 0
$decl ival $func ($decl x 0) x
$decl say  $func ($decl d 0) $set log ($call add ($call mul ($call ival (log), 10), d))
$decl four $func () {
  $decl a   {
    $decl r    $new { $decl k 1  $defer $call say (1) }
    $decl ret2 $call say (2)
  }.ret2
  $decl ret $call say (3)
}.ret
$decl order $func () {
  $defer    $call say (4)
  $decl x   $new { $decl k 5  $defer $call say (k) }
  $defer    $call say (6)
  $decl ret x.k
}.ret
$decl tr $func ($decl s "") {
  $decl x   $new { $defer $call say (9) }
  $decl n   $try ($call str_to_int (s)) none
  $decl ret n
}.ret
$decl main $func () {
  $decl a   $call four ()
  $decl b   $call order ()
  $decl d   $call tr ("x")
  $decl ret $call ival (log)
}.ret
