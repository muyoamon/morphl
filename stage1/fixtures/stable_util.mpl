// A module that itself imports the prelude, so `stable_c` reaches the prelude
// *through* it rather than directly — which loads it at a different position.
$decl P $import "../prelude"
$decl f $func ($decl b P.boolean) $call P.not (b)
