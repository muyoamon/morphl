// The module side of `ctor_value.mpl`: a member constructor named as a value from another
// file, so its shim is placed and exported here, and its deferral counts.
$decl hits $mut $alloc 0
$decl um   $func ($decl n 0) $new { $decl v n  $defer $set hits ($call add (hits, 1)) }
