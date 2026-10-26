// An overload of templates none of whose candidates fits (STDLIB.md, P7) is reported at
// the use, for `$specialize` and for `$call` alike — a candidate's own failing bound is
// not, since not fitting is how first fit moves on. Stage 0 refuses the `$specialize`.
$decl named_proto { $prop name $func () 0 }
$decl by_int   $template ($decl T 0) { $prop d 1 }
$decl by_named $template ($decl T $traitsof named_proto) { $prop d 2 }
$decl kind     $overload (by_int, by_named)
$decl s        $specialize kind "x"

$decl twice $template ($decl T 0) $func ($decl x T) $call mul (x, 2)
$decl calls $overload (twice, by_int)
$decl t     $call calls ("s")
