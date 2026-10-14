// The module `module_value.mpl` uses as a value. One of each kind of member a
// record has to carry: a nested module, storage, a plain value, a function, and a
// scalar prop, which lives in the type rather than the layout (§4.10).
$decl Q      $import "modval_inner"
$decl cell   $mut $alloc 0
$decl k      3
$decl double $func ($decl x 0) $call add (x, x)
$prop tag "util"
