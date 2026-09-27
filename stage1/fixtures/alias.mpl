// A round-trip fixture for §6a's indirect case, the part of it that is not
// really indirect. Prints 42.
//
// A top-level `$decl` that is not a `$func` lowers to a thunk (§7.3: its index
// names a *static*, not something to call), so a call through it is a call
// through a function *value* — which §6a cannot turn into a loop, because the
// target is unknown until run time. Except that here it is not unknown: the
// static is assigned once from a single node, so the callee is a compile-time
// constant and the backend resolves it.
//
// Every one of the fifteen indirect tail calls in the compiler's own emitted C
// was one of these, and none was a genuinely dynamic target. The three shapes:
$decl P $import "../prelude"

// an alias of a *function*,
$decl myor P.or

// an alias of an *intrinsic* — §8's operators are emitted infix when called, so
// resolving this one turns the call back into `a - b` rather than a call at all.
// This is the `$decl isub sub` idiom, for keeping an operator a file shadows,
// and an alias-of-a-function test alone does not catch it,
$decl isub sub

// and an alias of an alias, which has to be followed rather than resolved once.
$decl myor2 myor

// Both bodies are a whole function body, so both calls are in tail position.
$decl pick $func ($decl a P.boolean, $decl b P.boolean) $call myor2 (a, b)
$decl dec  $func ($decl n 0) $call isub (n, 1)

// Deep, and `zig build test-emit` builds it at -O0: `dec` is called 2,000,000
// times, so if resolving it got the operands or the target wrong the answer
// moves rather than the program merely being slow.
$decl countdown $func ($decl n 0) $if ($call eq_int (n, 0)) 7 ($call countdown ($call dec (n)))

// 30 + 7 + 5 = 42.
$decl main $func ()
  $call add ($if ($call pick (false, true)) 30 0,
      $call add ($call countdown (2000000), $call dec (6)))
