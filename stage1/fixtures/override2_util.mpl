// `override2.mpl`'s module: a template, and an `$override` of it naming this file's `helper`.
$decl helper $func () 10

$decl base $template T {
  $prop one $func ($decl x T) 1
  $prop two $func ($decl x T) 2
  $prop sum $func ($decl x T) $call add ($call one (x), $call two (x))
}
$decl mid $override base {
  $prop one $func ($decl x 0) $call helper ()
}
