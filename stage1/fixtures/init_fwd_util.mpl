// A module whose members are lowered out of source order, for `init_fwd.mpl`. `f` is
// `$fwd`'d, so it is lowered at the top — and its body names `b` and `c`, which lowers
// them (and `a`, and `cell`) before the members above them in the list are reached.
// Index order is then not source order; the initialiser must still be.
$decl cell $mut $alloc 0
$fwd f
$decl a 5
// §3.3: runs after `a` and before `b`, so `cell` is 5 when `c` reads it.
$set cell ($call add (cell, a))
$decl b $call add (a, 1)
$decl c $call add (b, cell)
$decl f $func () $call add (b, c)
