// An operand whose value the compiler knows without running it is still evaluated (§7.1).
// A prop's value is the type's (§4.10), so a projection onto one needs nothing from its
// target — and lowering dropped the target, so `($call mk ()).k` never ran `mk`. And a
// `$specialize` evaluates each argument once (§4.9), but a props-only body, or a `$func`
// one, binds its generic to the argument's source and reads it only for a type, so the
// argument never ran either. Each line below bumps `c` once in stage 0; compiled, every
// one above `h` did not, and the answer was 1041 for 7041.
$decl c $mut $new 0
$decl bump $func () $set c ($call add (c, 1))
$decl mk $func () $do ($call bump ()) { $prop k 5  $prop h $func ($decl n 0) $call mul (n, 2) }
$decl P $template (x) { $prop k 3  $prop f $func ($decl n 0) $call mul (n, 3) }
$decl F $template (x) $func ($decl n 0) $call add (n, 1)
$decl main $func () {
  $decl a   ($call mk ()).k
  $decl b   $call ($call mk ()).h (4)
  $decl d   ($do ($call bump ()) { $prop k 2 }).k
  $decl e   ($specialize P ($do ($call bump ()) 1)).k
  $decl f   $call ($specialize P ($do ($call bump ()) 1)).f (5)
  $decl g   $call ($specialize F ($do ($call bump ()) 1)) (6)
  $decl h   $match ($call mk ()) ($case {} 1)
  $decl ret $call add ($call mul (c, 1000), $call add ($call add (a, b), $call add (
                $call add (d, e), $call add ($call add (f, g), h))))
}.ret
