// A `$match` on a type that is not a union has no discriminator, so its first arm is the
// whole answer — but the scrutinee is still an expression, evaluated as any other (§7.1).
// Emit took the first arm and dropped the scrutinee, so `bump` never ran: the compiled
// program answered 5 where stage 0 says 6.
$decl c $mut $new 0
$decl bump $func () $set c ($call add (c, 1))
$decl main $func () {
  $decl a   $match ($call bump ()) ($case 0 5)
  $decl ret $call add (a, c)
}.ret
