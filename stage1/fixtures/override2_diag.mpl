// A diagnostic in a template made by two `$override`s is at the file and line it was written
// at (§4.12a): one shift down is the template it overrode — `override2_dmid.mpl`'s `mid1` —
// and two shifts down the base, `override_diag_util.mpl`. Both are the short call through a
// function value that only lowering refuses (§3.4).

$decl M $import "override2_dmid"

$decl top1 $override M.mid1 { $prop k 3 }
$decl top2 $override M.mid2 { $prop k 3 }
$decl B1   $specialize top1 0
$decl B2   $specialize top2 0

$decl f $func ($decl a 0, $decl b 3) $call add (a, b)

$decl main $func () $call add ($call B1.ap (f), $call B2.ap (f))
