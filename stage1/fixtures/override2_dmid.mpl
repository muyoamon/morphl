// `override2_diag.mpl`'s middle module: two `$override`s of `override_diag_util`'s template, one
// replacing `ap` with its own `$free` of a parameter, one keeping the base's.
$decl U $import "override_diag_util"
$decl mid1 $override U.box {
  $prop ap $func ($decl r $alloc 0) { $free r  $decl ret 5 }.ret
}
$decl mid2 $override U.box { $prop k 2 }
