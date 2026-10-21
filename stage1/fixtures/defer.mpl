// §4.15a's `$defer`, in a scope and in a plain value. Each step appends a digit to `log`,
// so the answer is the order things ran in: 132 45 687 67 98.
//   132  a scope: at its end, last registered first
//   45   a plain value: at the end of its own evaluation, and a copy carries none
//   687  a `$try` that does not return: both deferrals, at the end
//   67   one that returns: only the deferral registered before it
//   98   nested scopes, innermost first; a deferral reads the scope as it is at the end
$decl log  $mut $alloc 0
$decl ival $func ($decl x 0) x
$decl say  $func ($decl d 0) $set log ($call add ($call mul ($call ival (log), 10), d))

$decl one $func () {
  $decl a   $call say (1)
  $defer    $call say (2)
  $defer    $call say (3)
  $decl ret 0
}.ret

$decl two $func () {
  $decl w   { $decl k 5  $defer $call say (4) }
  $decl w2  w
  $decl b   $call say (5)
  $decl ret $call add (w.k, w2.k)
}.ret

$decl three $func ($decl s "") {
  $decl a   $call say (6)
  $defer    $call say (7)
  $decl n   $try ($call str_to_int (s)) none
  $defer    $call say (8)
  $decl ret n
}.ret

$decl four $func () {
  $decl c   $mut $alloc 1
  $defer    $call say ($call ival (c))
  $decl i   {
    $defer     $call say (9)
    $decl ret2 0
  }.ret2
  $decl w   $set c 8
  $decl ret 0
}.ret

$decl main $func () {
  $decl a   $call one ()
  $decl b   $call two ()
  $decl c   $call three ("42")
  $decl d   $call three ("x")
  $decl e   $call four ()
  $decl ret $call ival (log)
}.ret
