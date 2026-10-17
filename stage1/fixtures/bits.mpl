// §8's explicit `Int` arithmetic and bitwise operators, at the edges of the range,
// in both stages: wrapping is two's complement, saturating clamps, `shl` drops the
// bits it shifts out and `shr` copies the sign in. Each intrinsic is also passed as
// a value once, which reaches the runtime's wrapper rather than the inline form.
//
// Each line is printed; the answer is a checksum of the cases that fit in a line.

$decl id $func ($decl x 0) x

$decl big   9223372036854775807
$decl small -9223372036854775808

$decl apply $func ($decl f $func ($decl a 0, $decl b 0) 0, $decl a 0, $decl b 0)
  $call f (a, b)

$decl show $func ($decl n 0) $call print ($call concat ($call int_to_str (n), " "))

$decl main $func () {
  $decl d0  $call show ($call add_wrap ($call id (big), 1))
  $decl d1  $call show ($call sub_wrap ($call id (small), 1))
  $decl d2  $call show ($call mul_wrap ($call id (big), 3))
  $decl d3  $call show ($call add_sat ($call id (big), 5))
  $decl d4  $call show ($call sub_sat ($call id (small), 5))
  $decl d5  $call show ($call mul_sat ($call id (small), 2))
  $decl d6  $call show ($call mul_sat ($call id (small), -2))
  $decl d7  $call show ($call add_sat ($call id (40), 2))
  $decl d8  $call show ($call band ($call id (12), 10))
  $decl d9  $call show ($call bor ($call id (12), 10))
  $decl d10 $call show ($call bxor ($call id (12), 10))
  $decl d11 $call show ($call band ($call id (-1), small))
  $decl d12 $call show ($call shl ($call id (1), 63))
  $decl d13 $call show ($call shl ($call id (3), 62))
  $decl d14 $call show ($call shr ($call id (-16), 2))
  $decl d15 $call show ($call shr ($call id (small), 63))
  $decl d16 $call show ($call shr ($call id (big), 62))
  $decl d17 $call show ($call apply (add_wrap, big, 2))
  $decl d18 $call show ($call apply (mul_sat, big, big))
  $decl d19 $call show ($call apply (bxor, 5, 3))
  $decl d20 $call show ($call apply (shl, 5, 1))
  $decl ret $call add ($call bor ($call shl (1, 6), $call band (7, 5)),
                $call shr ($call bxor (-1, 0), 1))
}.ret
