// `override2_diag.mpl`'s middle module: two `$override`s of `override_diag_util`'s template, one
// replacing `ap` with its own short call through a function value, one keeping the base's.
$decl U $import "override_diag_util"
$decl mid1 $override U.box {
  $prop ap $func ($decl g ($func ($decl a 0, $decl b 3) a)) $call g (5)
}
$decl mid2 $override U.box { $prop k 2 }
