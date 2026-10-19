// A `$func`-bodied template in a module, applied from the entry file (`apply.mpl`).
$decl twice $template T $func ($decl f $func ($decl x T) T, $decl x T) $call f ($call f (x))
