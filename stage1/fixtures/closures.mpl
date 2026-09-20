// A round-trip fixture for §7.3: a function value is a code pointer and an
// environment, two words whatever its signature, and captures are copied where
// the literal stood. Prints 42.
//
// `adder` returns a closure over `n`, so the value outlives the frame `n` lived
// in — which is exactly what capture *by copy* is for (§7.3: "No closure ever
// points into a dead frame").
$decl adder $func ($decl n 0) $func ($decl m 0) $call add (n, m)

// A function-typed parameter: §7.3 keeps captures out of the type, so any
// function of this type fits and the call goes through the pair.
$decl apply $func ($decl f $func ($decl m 0) 0, $decl x 0) $call f (x)

$decl main $func () $call apply ($call adder (40), 2)
