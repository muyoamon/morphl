// `prop_cap_scope.mpl`'s module: a top-level `helper`, which is a global here and nowhere else.
$decl helper $func () 10

$decl base $template T {
  $prop one $func ($decl x T) 1
  $prop sum $func ($decl x T) $call one (x)
}
