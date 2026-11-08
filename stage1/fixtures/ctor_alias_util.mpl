// `ctor_alias.mpl`'s module: a member constructor, aliased in the entry file.
$decl hits $mut $alloc 0
$decl um   $func ($decl n 0) $new { $decl v n  $defer $set hits ($call add (hits, 1)) }
