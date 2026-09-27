// A module with a non-`$func` member, which is what makes the point: §4.10
// initialises `base` once, and the backend does that by assigning a static in
// `mpl_init`. A `$func` member would be a plain C function and would need no
// initialisation at all.
$decl base 5

$decl bump $func ($decl n 0) $call add (n, base)
