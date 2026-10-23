// §4.15a's refusal: a `$defer` outside a block's items, here called so stage 0 meets it.
// (One at a file's top level runs at the program's exit: `top_defer.mpl`.)
$decl f $func () $call print ($defer 3)
$decl x $call f ()
