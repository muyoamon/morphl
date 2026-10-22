// §4.15a's refusals: a `$defer` outside a block's items, and at a file's top level. (One
// in a `$new` block passed to a call that may hand it back is `defer_call.mpl`'s.)
$decl f $func () $call print ($defer 3)
$defer $call print ("y")
