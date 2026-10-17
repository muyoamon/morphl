// §3.1's `Float` and §8's overloads on it, compiled: arithmetic, `mod`, `neg`, `lt`
// and `eq` at their `Float` candidates, `to_float`, `to_int` (with `none` out of range
// and for NaN) and `to_str`, a float field, an intrinsic passed where a `Float`
// function is expected, and an overloaded intrinsic bound as a value and called at
// both candidates. Stage 0 leaves `Float` out of its subset (BOOTSTRAP §1.2), so this
// fixture is compiled-only.
//
// It prints what `to_str` gives, which round-trips: `0.1 + 0.2` is not `0.3`, and
// 10^30 built by multiplying is one ulp short of the literal. `mod` is exact, so the
// remainder of that by 7 is exactly 1.
//
// -3 + -1 + 123 + 0 + 1 + 7 + -1 + 0 = 126.

$decl say $func ($decl s "") $call print ($call concat (s, " "))

$decl b2i $func ($decl c $union (false, true)) $if c 1 0

$decl apply $func ($decl f $func ($decl x 0.5, $decl y 0.5) 0.5, $decl a 0.5, $decl b 0.5)
  $call f (a, b)

$decl pt { $decl x 1.5  $decl y -2.0 }

$decl big $func ($decl x 0.5, $decl n 0)
  $if ($call eq_int (n, 0)) x ($call big ($call mul (x, 10.0), $call sub (n, 1)))

$decl trunc $func ($decl x 0.5) {
  $decl o   $call to_int (x)
  $decl ret $match o ($case {$prop tag "some"} o.v, $case o -1)
}.ret

// Both candidates of `sub`, through one name.
$decl fsub sub

$decl main $func () {
  $decl d0  $call say ($call to_str ($call add (0.1, 0.2)))
  $decl d1  $call say ($call to_str ($call div (1.0, 4.0)))
  $decl d2  $call say ($call to_str ($call mod (-7.5, 2.0)))
  $decl d3  $call say ($call to_str ($call neg (pt.y)))
  $decl d4  $call say ($call to_str ($call to_float (7)))
  $decl d5  $call say ($call to_str ($call apply (mul, 1.5, 4.0)))
  $decl d6  $call say ($call to_str ($call fsub (1.0, 0.25)))
  $decl d7  $call say ($call to_str ($call big (1.0, 30)))
  $decl d8  $call say ($call to_str ($call mod ($call big (1.0, 30), 7.0)))
  // §8: Float arithmetic does not panic — division by zero is an infinity.
  $decl d9  $call say ($call to_str ($call div (1.0, 0.0)))
  $decl r0  $call trunc (-3.99)
  $decl r1  $call trunc ($call big (1.0, 19))
  $decl r2  $call trunc (123.9)
  $decl r3  $call b2i ($call lt (0.5, 0.25))
  $decl r4  $call b2i ($call eq ($call add (0.5, 0.25), 0.75))
  $decl r5  $call fsub (10, 3)
  $decl nan $call div (0.0, 0.0)
  $decl r6  $call trunc (nan)
  // ...and NaN is unordered and not equal to itself, so both of these are 0.
  $decl r7  $call add ($call b2i ($call lt (nan, 1.0)), $call b2i ($call eq (nan, nan)))
  $decl ret $call add ($call add ($call add (r0, r1), $call add (r2, r3)),
                $call add ($call add (r4, r5), $call add (r6, r7)))
}.ret
