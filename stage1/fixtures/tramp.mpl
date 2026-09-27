// A round-trip fixture for §6a's **indirect** case: a tail call through a
// function *value*. Prints 21.
//
// This is the one §6a could not do. The target is unknown until run time, so
// there is no body to loop back into, and the call was emitted plainly — correct
// C, but not §7.7: a chain of them grows the stack, and at three million hops the
// program died. The backend now *reports* such a call instead of making it, and
// the driver above it runs the chain in one reused frame.
//
// **An unbounded chain is expressible, and finding that out was the point.** It
// needs a function value that leads back to itself, which needs a recursive
// function type — and §5.5 infers recursion only through *storage*, so the
// obvious ways are all rejected by the checker: a parameter default naming the
// function being declared (a value position, not a type-only one), a table of
// mutually recursive functions (`unknown name`), a `$fwd` alias (`not
// callable`). What works is a function value *in storage*, written after the
// function exists — which is how both chains below are built.
$decl P $import "../prelude"

// 1. A chain of one signature. The `$func` literal in the `$alloc` is also a
//    closure with **no captures**, which used to emit an allocation of an
//    environment struct that was never declared.
$decl cell $mut $alloc $func ($decl n 0) 0
$decl down $func ($decl n 0) $if ($call eq_int (n, 0)) 7 ($call cell ($call sub (n, 1)))
$decl w0 $set cell down

// 2. A chain that changes signature at every hop, so the driver has to choose the
//    C signature per hop rather than once — which is why the pending block
//    carries a tag and a union rather than one argument list.
$decl c1 $mut $alloc $func ($decl n 0) 0
$decl c2 $mut $alloc $func ($decl n 0, $decl m 0) 0
$decl pa $func ($decl n 0) $if ($call eq_int (n, 0)) 9 ($call c2 ($call sub (n, 1), n))
$decl pb $func ($decl n 0, $decl m 0) $call c1 (n)
$decl w1 $set c1 pa
$decl w2 $set c2 pb

// 3. One hop through a parameter — BOOTSTRAP §6a's own `apply (f, x)`, and a
//    `global` used as a value rather than called.
$decl five  $func ($decl n 0) 5
$decl apply $func ($decl f five, $decl x 0) $call f (x)

// 7 + 9 + 5 = 21, with 2,000,000 hops in each chain at -O0.
$decl main $func ()
  $call add ($call down (2000000),
      $call add ($call pa (2000000), $call apply (five, 0)))
