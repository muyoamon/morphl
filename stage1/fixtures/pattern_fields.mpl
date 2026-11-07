// §4.7: "a pattern is any expression, never evaluated", so a block pattern may require a
// field. Lowering read a block pattern's props alone (BOOTSTRAP §1.3 keeps stage 0's to
// props), so `{$decl v 0}` was the pattern `{}`: it claimed every block member, `none`
// included, and `r.v` in its arm was refused although inference had accepted it. Stage 0
// keeps a block pattern to props, so this is compiled only.
//
// 7145: 7 and 1 from a reference union `<&{v}, none>` matched on its field first, then 4
// and 5 from a value union `<{a, b}, {a}>`, where the longer pattern must leave `{a}`.

$decl boxed $func ($decl c $union (false, true)) {
  $decl r   $if c ($new { $decl v 7 }) none
  $decl ret $match r ($case {$decl v 0} r.v, $case {$prop tag "none"} 1)
}.ret

$decl wide $func ($decl c $union (false, true)) {
  $decl r   $if c { $decl a 3  $decl b 4 } { $decl a 5 }
  $decl ret $match r ($case {$decl a 0  $decl b 0} r.b, $case {$decl a 0} r.a)
}.ret

$decl main $func ()
  $call add ($call add ($call mul ($call boxed (true), 1000), $call mul ($call boxed (false), 100)),
             $call add ($call mul ($call wide (true), 10), $call wide (false)))
