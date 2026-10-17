// §3.1: `Int` overflow panics, and so do §8's division by zero and a shift count
// outside 0..63 — in both implementations, with one message. The argument picks the
// case; `ok` is the one that does not panic, since `mod` by -1 is 0 even at the
// bottom of the range, where C's `%` is undefined.
//
// The operands go through `id` so that nothing about them is constant.

$decl id $func ($decl x 0) x

$decl isub sub

$decl apply $func ($decl f $func ($decl a 0, $decl b 0) 0, $decl a 0, $decl b 0)
  $call f (a, b)

$decl big   9223372036854775807
$decl small -9223372036854775808

$decl pick $func ($decl k "")
  $if ($call eq_str (k, "add"))   ($call add ($call id (big), 1))
  ($if ($call eq_str (k, "sub"))  ($call sub ($call id (small), 1))
  ($if ($call eq_str (k, "mul"))  ($call mul ($call id (big), 2))
  ($if ($call eq_str (k, "div0")) ($call div ($call id (7), 0))
  ($if ($call eq_str (k, "divm")) ($call div ($call id (small), -1))
  ($if ($call eq_str (k, "mod0")) ($call mod ($call id (7), 0))
  ($if ($call eq_str (k, "neg"))  ($call neg ($call id (small)))
  // Through an alias of the overloaded intrinsic, and through it as a value.
  ($if ($call eq_str (k, "alias")) ($call isub ($call id (small), 1))
  ($if ($call eq_str (k, "value")) ($call apply (add, $call id (big), 1))
  // A shift count outside 0..63.
  ($if ($call eq_str (k, "shl"))  ($call shl (1, $call id (64)))
  ($if ($call eq_str (k, "shr"))  ($call shr (1, $call id (-1)))
       ($call mod ($call id (small), -1))))))))))))

$decl main $func () {
  $decl argv $call args ()
  $decl ret  $call pick ($call at (argv, 0))
}.ret
