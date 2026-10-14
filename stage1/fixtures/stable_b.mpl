// See `stable_a.mpl`: one more prelude member called, and `prelude.c` must not move.
$decl P    $import "../prelude"
$decl main $func () $if ($call P.or ($call P.not (false), false)) 7 0
