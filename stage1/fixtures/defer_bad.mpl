// §4.15a's refusals: a `$defer` outside a block's items, in an ephemeral `$new` block —
// only `$decl x $new { … }` in a scope is done (DEFER.md step 3) — and at a file's top
// level.
$decl f $func () $call print ($defer 3)
$decl C_k $func ($decl c $new { $decl k 0 }) c.k
$decl g $func () {
  $decl a   $call C_k ($new { $decl k 1  $defer $call print ("x") })
  $decl ret 0
}.ret
$defer $call print ("y")
