// §4.9's application: `$call t args` on a template whose body is a `$func` means `$call
// ($specialize t inferred) args`, each generic read off one parameter default's shape —
// the argument's type for a default that is exactly `T`, a parameter or the result of
// the argument's function type for a `$func` default mentioning `T`. Before it, every
// such call was refused, and the `$specialize` of a `$func` body did not lower.
//
// 5 + 5 + 42 + 100 + 2000000 + 6 + 80 + 13 = 2000251: `id` at two types, `apply` with
// `A` and `B` read off its function argument, an explicit `$specialize` of a `$func`
// body, a template applying itself in tail position (2,000,000 deep at -O0, so a call
// that is not a loop overflows), a generic known only from a function's result, a
// module's template, and a closure inside a specialisation capturing its parameter.

$decl U   $import "apply_util"
$decl ieq eq

$decl id    $template T $func ($decl x T) x
$decl apply $template (A, B) $func ($decl f $func ($decl a A) B, $decl x A) $call f (x)
$decl inc   $func ($decl n 0) $call add (n, 1)
$decl count $template T $func ($decl n 0, $decl x T, $decl acc 0)
  $if ($call ieq (n, 0)) acc ($call count ($call sub (n, 1), x, $call add (acc, 1)))
$decl run   $template R $func ($decl g $func () R) $call g ()
$decl adder $template T $func ($decl k T) $func ($decl y T) $call add (k, y)

$decl main $func () {
  $decl a   $call id (5)
  $decl b   $call len ($call id ("hello"))
  $decl c   $call apply (inc, 41)
  $decl d   $call ($specialize id 0) (100)
  $decl e   $call count (2000000, "s", 0)
  $decl f   $call run ($func () 6)
  $decl g   $call U.twice ($func ($decl x 0) $call mul (x, 2), 20)
  $decl h   $call ($call adder (10)) (3)
  $decl ret $call add ($call add ($call add (a, b), $call add (c, d)),
                       $call add ($call add (e, f), $call add (g, h)))
}.ret
