// Half of `test-stable`: the same import, called differently. `prelude.c` must come out
// byte-identical for this and `stable_b.mpl`, because §4.14 makes linkage a property of
// the module rather than of its callers. `stable_b` additionally calls `P.or`, which is
// exactly what used to flip that member from `static` to external and rewrite this
// module's output from outside it.
$decl P $import "../prelude"
$decl main $func () $if ($call P.not (false)) 7 0
