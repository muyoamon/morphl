// A round-trip fixture: morphl → C → binary. 10! = 3628800.
//
// Tail-recursive on purpose — §6a's cheap case is what the backend implements,
// and `zig build test-emit` compiles this at -O0 so nothing but our own loop
// can be eliminating the recursion.
$decl fact $func ($decl n 0, $decl acc 1)
  $if ($call eq_int (n, 0)) acc ($call fact ($call sub (n, 1), $call mul (acc, n)))

$decl main $func () $call fact (10, 1)
