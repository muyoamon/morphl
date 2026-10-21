// §4.15a's refusals: a `$defer` outside a block's items, in a `$new` block passed to a
// call that can hand its place back (DEFER.md step 3), and at a file's top level.
$decl f $func () $call print ($defer 3)
$decl C_k $func ($decl c $new { $decl k 0 }) c
$decl g $func () {
  $decl a   $call C_k ($new { $decl k 1  $defer $call print ("x") })
  $decl ret 0
}.ret
$defer $call print ("y")
