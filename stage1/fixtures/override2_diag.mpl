// A diagnostic in a template made by two `$override`s is at the file and line it was written
// at (§4.12a): one shift down is the template it overrode — `override2_dmid.mpl`'s `mid1` —
// and two shifts down the base, `override_diag_util.mpl`. Both are a `$free` of a parameter,
// which only lowering refuses (DEFER.md).

$decl M $import "override2_dmid"

$decl top1 $override M.mid1 { $prop k 3 }
$decl top2 $override M.mid2 { $prop k 3 }
$decl B1   $specialize top1 0
$decl B2   $specialize top2 0

$decl main $func () $call add ($call B1.ap ($alloc 0), $call B2.ap ($alloc 0))
