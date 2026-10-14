// A module member with a default, for `defaults.mpl`. The default names a sibling,
// so it has to be evaluated in this module's scope, not the caller's.
$decl base 7
$decl g    $func ($decl x 0, $decl y base) $call mul (x, y)
