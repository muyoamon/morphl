// ctor_top.mpl's module: a member calling a constructor through its block's field.
$decl mk  $func ($decl n 0) $new { $decl v n  $defer $call print ("c5\n") }
$decl box { $decl make mk }
$decl t   $call box.make (5)
