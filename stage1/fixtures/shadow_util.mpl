// The module half of `shadow_root.mpl`: `mdiff` is written above the module's own `sub`, so
// SPEC §4.1's "visible from this point onward" gives its body the root's.
$decl mdiff $func ($decl a 0, $decl b 0) $call sub (a, b)
$decl sub   $func ($decl a 0, $decl b 0) 77
