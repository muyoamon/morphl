// §5.5's knot through two functions, as a module (`mu_group_util`) and at the top level.
// Inference wrote the type several ways — `μX.<{v, k: &^[Int] -> <X, {v, k: &^[Int] -> X}>},
// {v, k: &^[Int] -> X}>` is two members that are one type, and `f`'s result was that `μ`
// beside its own first member spelt out — so the checker refused `$call a.k (4)` and emit
// laid one type out as several (`T.canon`). And at the top level `main` read `p` before
// the group was solved, so `($call p (3)).v` was a projection off `q`'s placeholder.
$decl U $import "mu_group_util"
$fwd q
$decl p $func ($decl n 0) $if ($call eq (n, 0)) { $decl v 3  $decl k $alloc q }
  ($call q ($call sub (n, 1)))
$decl q $func ($decl n 0) $if ($call eq (n, 0)) { $decl v 4  $decl k $alloc p }
  ($call p ($call sub (n, 1)))
$decl main $func () {
  $decl a   $call U.f (5)
  $decl b   $call a.k (4)
  $decl c   $call p (3)
  $decl d   $call c.k (0)
  $decl ret $call add ($call add ($call mul (a.v, 1000), $call mul (b.v, 100)),
                $call add ($call mul (c.v, 10), d.v))
}.ret
