// §4.8's `$overload`: first fit by argument type, a candidate that is itself an overload,
// an overload passed where one function type is expected, and `x.i` naming a candidate.
// It runs under both stages, so they must agree on which candidate each call takes.
//
// 42 + 3 + 100 + 2 + 5 + 10 + 200 = 362.

$decl fi $func ($decl n 0) $call add (n, 1)
$decl fs $func ($decl s "") $call len (s)
$decl o  $overload (fi, fs)

$decl fb $func ($decl b $union (true, false)) $if b 100 200
$decl o2 $overload (fb, o)

$decl apply $func ($decl k $func ($decl s "") 0) $call k ("hello")

$decl main $func () {
  $decl a   $call o (41)
  $decl b   $call o ("abc")
  $decl c   $call o2 (true)
  $decl d   $call o2 ("xy")
  $decl e   $call apply (o)
  $decl f   $call o.1 (9)
  $decl g   $call o2 (false)
  $decl ab  $call add (a, b)
  $decl cd  $call add (c, d)
  $decl ret $call add ($call add (ab, cd), $call add ($call add (e, f), g))
}.ret
