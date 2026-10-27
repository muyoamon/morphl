// `fn_coerce.mpl`'s module: a coercion of its own, so its output carries a shim.
$decl each $func ($decl f $func ($decl n 0) (), $decl n 0) $do ($call f (n)) n
$decl twice $func ($decl n 0)
  $call each ($func ($decl k 0) { $decl a k  $decl b k  $decl c k }, $call add (n, n))
