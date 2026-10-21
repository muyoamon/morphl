// DEFER.md step 3: whose a `$new` literal's storage is. Its deferrals go with it until the
// end of the block item it was made in: if what that item's `$decl` binds reaches it, that
// `$decl` owns it; otherwise it was ephemeral and they run there. Each step appends a
// digit, so the answer is the order — 345687, then 132456.
//   34   ephemeral, passed to a call answering a value: dies with its item
//   56   read as a value: the same
//   87   a record owns its field's storage, which lives as long as the record
//   132  a value block's own deferral runs at its end, its field's storage at its owner's
//   45   bound through a call answering a value: still ephemeral
//   6    a `$try` leaving while ephemeral storage is alive runs it
$decl log  $mut $alloc 0
$decl ival $func ($decl x 0) x
$decl say  $func ($decl d 0) $set log ($call add ($call mul ($call ival (log), 10), d))
$decl use  $func ($decl c $new { $decl k 0 }) c.k
$decl five $func () {
  $decl x   $call use ($new { $decl k 3  $defer $call say (3) })
  $decl y   $call say (4)
  $decl ret x
}.ret
$decl six $func () {
  $decl v   $call ival (($new { $decl k 0  $defer $call say (5) }).k)
  $decl w   $call say (6)
  $decl ret v
}.ret
$decl nine $func () {
  $decl w   { $decl n $new { $decl k 1  $defer $call say (7) } }
  $decl a   $call say (8)
  $decl ret w.n.k
}.ret
$decl ten $func () {
  $decl w   { $decl n $new { $decl k 1  $defer $call say (2) }  $defer $call say (1) }
  $decl a   $call say (3)
  $decl ret 0
}.ret
$decl eleven $func () {
  $decl q   $call use ($new { $decl k 1  $defer $call say (4) })
  $decl r   $call say (5)
  $decl ret q
}.ret
$decl twelve $func ($decl s "") {
  $decl x   $call add ($call use ($new { $decl k 1  $defer $call say (6) }),
              ($try ($call str_to_int (s)) none).v)
  $decl ret x
}.ret
$decl main $func () {
  $decl b   $call five ()
  $decl c   $call six ()
  $decl d   $call nine ()
  $decl r1  $call ival (log)
  $decl z   $set log 0
  $decl e   $call ten ()
  $decl f   $call eleven ()
  $decl g   $call twelve ("x")
  $decl ret $call add ($call mul (r1, 1000000), $call ival (log))
}.ret
