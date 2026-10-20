// P10's recursion without the arena, so both stages run it (`local_rec.mpl` has the rest):
// a `$func` a block's `$decl` binds naming itself, in tail position (a loop, 2,000,000 deep
// at -O0), outside it, and capturing its enclosing frame. 2000000 + 610 = 2000610.

$decl run $func ($decl k 0) {
  $decl sum $func ($decl n 0, $decl acc 0)
    $if ($call eq_int (n, 0)) acc ($call sum ($call sub (n, 1), $call add (acc, k)))
  $decl fib $func ($decl n 0)
    $if ($call lt (n, 2)) n ($call add ($call fib ($call sub (n, 1)), $call fib ($call sub (n, 2))))
  $decl ret $call add ($call sum (2000000, 0), $call fib (15))
}.ret

$decl main $func () $call run (1)
