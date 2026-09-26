// A round-trip fixture for §6a's *general* case: a mutually tail-recursive group
// whose members do **not** share a signature. Prints 9.
//
// `up` takes one parameter and `down` takes two, so the fast path's one
// parameter list cannot serve both and `same_sig` refuses it. The general path
// gives each member parameter variables of its own and returns through an
// out-parameter; it is still one dispatch loop, so §7.7 holds — and `zig build
// test-emit` builds this at -O0, so if it were emitted as a pair of calls the
// 2,000,000 alternations would overflow rather than answer.
//
// `k` is load-bearing, not decoration: `up (2000001)` is 1 only if the `n` that
// `up` passed to `down` arrived in `down`'s *second* parameter. Get the q-variables
// or their order wrong and this reads a filler zero.
$fwd down

$decl up   $func ($decl n 0)
  $if ($call eq_int (n, 0)) 7 ($call down ($call sub (n, 1), n))

$decl down $func ($decl n 0, $decl k 0)
  $if ($call eq_int (n, 0)) k ($call up ($call sub (n, 1)))

// up (2000000) walks the even chain to `up 0`      -> 7
// up (2000001) walks the odd chain to `down (0, 1)` -> 1
// down (6, 5)  joins the odd chain the same way     -> 1
$decl main $func ()
  $call add ($call up (2000000), $call add ($call up (2000001), $call down (6, 5)))
