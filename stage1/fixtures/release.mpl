// DEFER.md step 5, SPEC §4.15a: an ephemeral place is released where it is consumed, and
// a block lives no longer than what holds it. Storage with a deferral used where there is
// no block item — a function body that is not a block — used to have its deferral run after
// the body's tail call in stage 0, a frame kept per iteration of a loop, and dropped by the
// compiled program. Each case appends digits to `log`, so the answer is the order.
$decl log  $mut $alloc ""
$decl sval $func ($decl x "") x
$decl say  $func ($decl d 0) $set log ($call concat ($call sval (log), $call int_to_str (d)))
$decl peek $func ($decl r $new { $decl v 0 }) $call add (r.v, 1)
$decl ok   $func ($decl r $new { $decl v 0 }) $call eq (r.v, r.v)

// A: `$do`'s first operand, released before the tail call after it. 12
$decl case_a $func () $do ($call peek ($new { $decl v 1  $defer $call say (v) })) ($call say (2))
// B: a tail call's argument, consumed by the call inside it. 34
$decl case_b $func () $call say ($call peek ($new { $decl v 3  $defer $call say (v) }))
// C: an `$if`'s condition, before the arm. 56
$decl case_c $func () $if ($call ok ($new { $decl v 5  $defer $call say (v) }))
                          ($call say (6)) ($call say (0))
// D: a `$match`'s scrutinee, before the arm. 78
$decl case_d $func () $match ($call peek ($new { $decl v 7  $defer $call say (v) })) (
  $case 0 ($call say (8))
)
// E: a projection, inside an item: before the call its value goes on to. 9 then 10
$decl case_e $func () {
  $decl a   $call say ($call add (($new { $decl v 9  $defer $call say (v) }).v, 1))
  $decl ret 0
}.ret
// F: an arm's storage with no item to clear its flag: only the arm that ran. 1 then 3
$decl case_f $func ($decl c $union (true, false))
  $do ($call peek ($if c ($new { $decl v 1  $defer $call say (v) })
                         ($new { $decl v 2  $defer $call say (v) })))
      ($call say (3))
// G: a loop, one per iteration, each released before it recurses — constant space, 200000
// deep at -O0, where a frame per iteration would overflow.
$decl count $mut $alloc 0
$decl ival  $func ($decl x 0) x
$decl tick  $func ($decl d 0) $set count ($call add ($call ival (count), d))
$decl loop  $func ($decl n 0) $if ($call eq (n, 0)) ($call ival (count))
    ($do ($call peek ($new { $decl v 1  $defer $call tick (v) })) ($call loop ($call sub (n, 1))))

$decl main $func () {
  $decl a   $call case_a ()
  $decl b   $call case_b ()
  $decl c   $call case_c ()
  $decl d   $call case_d ()
  $decl e   $call case_e ()
  $decl f   $call case_f (true)
  $decl g   $call case_f (false)
  $decl n   $call loop (200000)
  $decl ret $call concat ($call sval (log), $call concat (" ", $call int_to_str (n)))
}.ret
