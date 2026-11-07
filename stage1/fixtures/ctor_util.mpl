// `ctor.mpl`'s module: a constructor in another file, called by name and through an alias
// there, and a member thunk owning one at the program's scope.
$decl log  $mut $alloc 0
$decl ival $func ($decl x 0) x
$decl say  $func ($decl d 0) $set log ($call add ($call mul ($call ival (log), 10), d))
$decl made $func ($decl k 0) $new { $decl v k  $defer $call say (v) }
$decl loud $func ($decl s "") $new { $decl w s  $defer $call print (w) }
$decl kept $call loud ("u ")
