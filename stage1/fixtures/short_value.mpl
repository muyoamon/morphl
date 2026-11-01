// §3.4: a call that leaves off trailing arguments takes their defaults from the callee's
// definition, so the callee has to name one. A function *value* has no defaults to give
// (§7.3's pair is two words whatever the signature), so a call through one passes every
// argument. Stage 0 carries a function's defaults with its value and runs all of these;
// the compiler has nowhere to read them from, and used to refuse them only in lowering.
$decl f $func ($decl a 0, $decl b 3) $call add (a, b)
$decl g $func ($decl a "", $decl b 4) b
$decl f2 $func ($decl a 0, $decl b 4) $call sub (a, b)

$decl through_param $func ($decl h f) $call h (1)
$decl shadowed $func ($decl f $func ($decl a 0, $decl b 3) a) $call f (1)
$decl r { $decl k f }
$decl through_field $func () $call r.k (1)
$decl o $overload (f, g)
$decl through_overload $func () $call o (1)
$decl through_result $func () $call ($if ($call lt (1, 2)) f f2) (1)

// Every argument passed is fine, and so is a name for a definition.
$decl full $func ($decl h f) $call h (1, 3)
$decl named $func () { $decl h f  $decl ret $call add ($call f (1), $call h (1)) }.ret
