// §5.4 through a union of references: projecting a field off an `$if` of two `$new`s
// whose blocks differ. Each member is its own object, so lowering switches on the
// discriminator and reads each member's field where that member has it. Covers field
// types that differ (the result is their join), positions that differ, a reference beside
// a value, and the `$try` that found it: `n` is `some`, not `Int`. And a union of values
// whose members agree on the field's position but not on what precedes it (`vals`), or
// on its type (`vtypes`): §5.1's shared prefix is not the C union's there, so it takes the
// same switch — reading through the first member answered 53 for 56.
$decl ival $func ($decl x 0) x
$decl num  $func ($decl v $union (0, "")) $match v (
  $case 0 v,
  $case "" ($call len (v))
)
$decl types $func ($decl c $union (false, true)) {
  $decl q   $if c ($new { $decl k 1 }) ($new { $decl k "abc" })
  $decl ret $call num (q.k)
}.ret
$decl place $func ($decl c $union (false, true)) {
  $decl q   $if c ($new { $decl k 4 }) ($new { $decl a "x"  $decl k 5 })
  $decl ret $call ival (q.k)
}.ret
$decl mixed $func ($decl c $union (false, true)) {
  $decl q   $if c ($new { $decl k 6  $decl j 0 }) { $decl k 7 }
  $decl ret $call ival (q.k)
}.ret
$decl tried $func ($decl c $union (false, true), $decl s "") {
  $decl n   $try ($call str_to_int (s)) none
  $decl q   $if c ($new { $decl k n.v }) ($new { $decl k n })
  $decl r   q.k
  $decl ret $match r (
      $case {$prop tag "some"} r.v,
      $case 0 r
    )
}.ret
$decl vals $func ($decl c $union (false, true)) {
  $decl q   $if c { $decl a 1  $decl k 2 } { $decl a "sss"  $decl k 3 }
  $decl ret $call ival (q.k)
}.ret
$decl vtypes $func ($decl c $union (false, true)) {
  $decl q   $if c { $decl k 1 } { $decl k "ab" }
  $decl ret $call num (q.k)
}.ret
$decl un  $func ($decl r $call tried (true, "1")) $match r (
  $case {$prop tag "none"} 0,
  $case 0 r
)
$decl dig $func ($decl acc 0, $decl d 0) $call add ($call mul (acc, 10), d)
$decl main $func () {
  $decl a   $call dig (0, $call types (true))
  $decl b   $call dig (a, $call types (false))
  $decl c   $call dig (b, $call place (true))
  $decl d   $call dig (c, $call place (false))
  $decl e   $call dig (d, $call mixed (true))
  $decl f   $call dig (e, $call mixed (false))
  $decl g   $call dig (f, $call un ($call tried (true, "8")))
  $decl h   $call dig (g, $call un ($call tried (false, "9")))
  $decl i   $call dig (h, $call vals (true))
  $decl j   $call dig (i, $call vals (false))
  $decl k   $call dig (j, $call vtypes (true))
  $decl l   $call dig (k, $call vtypes (false))
  $decl ret l
}.ret
