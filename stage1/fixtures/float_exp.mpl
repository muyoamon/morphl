// §2.1's float literals with an exponent — `1.5e3`, `2e-3`, `-6.02E+23`, `1E2` — read as the
// numbers they write, here through arithmetic on them: 1.5e3 * 2e-3 is 3, -6.02E+23 / 1e23
// is -6.02, so 3 + 60.2 + 100 is 163.2, and `to_int` truncates it to 163. Compiled only:
// stage 0 has float literals but no float arithmetic (BOOTSTRAP §1.2).
$decl a 1.5e3
$decl b 2e-3
$decl c -6.02E+23
$decl d 1E2

$decl main $func () {
  $decl x   $call add ($call mul (a, b), $call add ($call mul ($call div (c, 1e23), -10.0), d))
  $decl t   $call to_int (x)
  $decl ret $match t ($case {$prop tag "some"} t.v, $case t -1)
}.ret
