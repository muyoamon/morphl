// §4.10 initialises a module's `$decl`s in source order, with its effects between them,
// however the members came to be lowered. Prints 22: `f ()` is `b + c` = 6 + 11, and
// `cell` is 5.
//
// A module's initialiser used to run in function-table order, on the claim that a
// module's members are lifted in source order. A `$fwd`'d function breaks that: it is
// lowered at the `$fwd`, and its body may name members written later, so they take
// earlier indices than members written above them. `b` was assigned before `a` and read
// 0 — no diagnostic, a wrong answer. The effect moves with it: it was placed by its
// lifted index too.
$decl U    $import "init_fwd_util"
$decl main $func () $call add ($call U.f (), U.cell)
