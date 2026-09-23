// A module whose table is built by §3.3 expressions, the way `parser.mpl`
// builds §2.2's arity table. The two `$call bump (…)` items bind nothing, so a
// member walk that looks only at the fields drops them and `total` reads 0.
//
// `snapshot` sits between them and is what pins the *order*: it reads 6 only
// if the first item ran before it and the second after, which is §4.10's
// source order applied to a module rather than to the entry file.
$decl P $import "../prelude"

$decl cell $mut $alloc 0

$decl bump $func ($decl n 0) $set cell ($call add ($call P.ival (cell), n))

$call bump (6)

$decl snapshot $call P.ival (cell)

$call bump (30)

$decl total $func () $call P.ival (cell)
