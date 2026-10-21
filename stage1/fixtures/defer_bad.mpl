// §4.15a's refusals: a `$defer` outside a block's items, in a block that is `$new`
// storage (DEFER.md's steps 3 and 4), and at a file's top level.
$decl f $func () $call print ($defer 3)
$decl g $func () {
  $decl a   $new { $decl k 1  $defer $call print ("x") }
  $decl ret 0
}.ret
$defer $call print ("y")
