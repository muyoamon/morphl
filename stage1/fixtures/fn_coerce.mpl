// §7.4 on a function value. §5.1 lets a function stand where one of a supertype is
// expected, but the pair (§7.3) carries no signature and the call site supplies its own,
// so where the two C signatures differ the coercion goes through a shim (`emit.mpl`,
// `adapt_fn`). Without it every case below called the code pointer with the wrong
// signature, and the first crashed.
//
// The digits, in order: a `()` result (1), a prefix result (2), a member into a union
// result (4, 3), a parameter the other way round (5), a callback's callback, which needs
// a shim inside a shim (8), a join of two closure types (6), a closure stored in a wider
// function-typed cell (7), a module's own coercion (8), and a tail call through a coerced
// value, which puts §6a's trampoline in the program (9). 1243586789.

$decl U $import "fn_coerce_util"

$decl run $func ($decl f $func ($decl n 0) (), $decl n 0) $do ($call f (n)) 1

$decl first $func ($decl f $func ($decl n 0) { $decl a 0 }, $decl n 0) {
  $decl r   $call f (n)
  $decl ret r.a
}.ret

$decl pick $func ($decl f $func () $union ({ $prop tag "a" }, { $prop tag "b" $decl v 0 })) {
  $decl r   $call f ()
  $decl ret $match r ($case {$prop tag "b"} r.v, $case r 3)
}.ret

$decl feed $func ($decl f $func ($decl x { $decl a 0  $decl b 0  $decl c 0 }) 0)
  $call f ({ $decl a 5  $decl b 6  $decl c 7 })

$decl outer $func ($decl g $func ($decl h $func () { $decl a 0  $decl b 0 }) 0)
  $call g ($func () { $decl a 8  $decl b 9 })
$decl inner $func ($decl h $func () { $decl a 0 }) {
  $decl r   $call h ()
  $decl ret r.a
}.ret

$decl choose $func ($decl c $union (false, true)) {
  $decl f   $if c ($func () { $decl a 6  $decl b 1 }) ($func () { $decl a 0 })
  $decl r   $call f ()
  $decl ret r.a
}.ret

$decl cell $mut $alloc $func ($decl n 0) ()
// The cell's value, read through (§5.4).
$decl C_val $func ($decl f $func ($decl n 0) ()) f
$decl stored $func () {
  $decl w   $set cell ($func ($decl n 0) { $decl a n  $decl b n })
  $decl c   $call C_val (cell)
  $decl r   $call c (3)
  $decl ret 7
}.ret

// In tail position, through a value: the caller reports and its caller drives (§6a).
$decl via $func ($decl f $func ($decl n 0) { $decl a 0 }, $decl n 0) $call f (n)

$decl d $func ($decl acc 0, $decl x 0) $call add ($call mul (acc, 10), x)

$decl main $func () {
  $decl a   $call run ($func ($decl n 0) { $decl p n  $decl q n  $decl r n }, 4)
  $decl b   $call first ($func ($decl n 0) { $decl a $call add (n, 1)  $decl b 0  $decl c 0 }, 1)
  $decl c1  $call pick ($func () { $prop tag "b" $decl v 4 })
  $decl c2  $call pick ($func () { $prop tag "a" })
  $decl e   $call feed ($func ($decl x { $decl a 0 }) x.a)
  $decl g   $call outer (inner)
  $decl h   $call choose (true)
  $decl i   $call stored ()
  $decl j   $call U.twice (4)
  $decl k   $call via ($func ($decl n 0) { $decl a n  $decl b 0  $decl c 0 }, 9)
  $decl ret $call d ($call d ($call d ($call d ($call d ($call d ($call d ($call d (
                $call d (a, b), c1), c2), e), g), h), i), j), k.a)
}.ret
