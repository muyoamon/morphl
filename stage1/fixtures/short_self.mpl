// A short call to a local `$func` takes the omitted defaults from its definition
// (`short_local.mpl`), and two ways of reaching one had no definition attached: its own
// name inside its body, and a `$fwd`'d name before the `$decl` completing it. Both were
// refused as calls through a function value, which only lifting `defaults.mpl` into a
// function showed (tools/sweep.sh --lift).
//
// Answer 43607: `outer (3)` is 3000 + 10 * 9 + 10 and `outer (40)` 40000 + 10 * 46 + 47.
// `down` runs 1,000,000 deep, so its short self-call must stay a tail call (§7.7).
$decl outer $func ($decl k 0) {
  // A short self-call whose default reads the frame, in tail position.
  $decl down $func ($decl n 0, $decl acc k) $if ($call eq_int (n, 0)) acc
      ($call down ($call sub (n, 1)))
  // A short call to a `$fwd`'d function before its `$decl`, from a closure too.
  $fwd h
  $decl early $func () $call h (1)
  $decl h $func ($decl a 0, $decl b ($call add (k, 5))) $call add (a, b)
  $decl later $func ($decl g 0) $call add (g, $call h (2))
  $decl ret $call add ($call mul (1000, $call down (1000000)),
              $call add ($call mul (10, $call early ()), $call later (0)))
}.ret
$decl main $func () $call add ($call outer (3), $call outer (40))
