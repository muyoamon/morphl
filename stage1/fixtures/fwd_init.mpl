// §4.11's legal side: a `$fwd` name may be named before the `$decl` completing
// it, so long as nothing *evaluated* before then reaches it. Prints 126.
//
// `infer.mpl`'s `check_fwd_reads` walks each initializer between a `$fwd` and
// its completion for what running it reads, following direct calls. Every shape
// here is one that walk must let through; `fwd_uninit.mpl` holds the ones it
// must refuse. If the check grows too strict this file stops type-checking, and
// the answer pins that the program it accepts still means what it says.
$fwd even

// A function naming it, written between the two and called only after.
$decl odd $func ($decl n 0) $if ($call eq_int (n, 0)) false ($call even ($call sub (n, 1)))

// An initializer between them that calls something which does not reach it.
$decl base $call add (20, 1)

// Building a closure that names it runs nothing: `mk`'s body is a `$func`
// literal, so calling `mk` here evaluates no read of `even`.
$decl mk $func ($decl k 0) $func ($decl n 0) $if ($call even (n)) k 0
$decl later $call mk (base)

// A parameter that shares the name is not the slot.
$decl shadow $func ($decl even 0) $call add (even, 1)
$decl s1 $call shadow (4)

$decl even $func ($decl n 0) $if ($call eq_int (n, 0)) true ($call odd ($call sub (n, 1)))

// Once completed it may be called from anywhere, initializers included.
$decl e7 $if ($call odd (7)) 100 0

// 21 + 5 + 100 = 126.
$decl main $func () $call add ($call later (10), $call add (s1, e7))
