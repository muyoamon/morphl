// §5.4 reads a reference as its pointee wherever a value is expected, and that includes a
// union some of whose members are references: `$if c s "xyz"` with `s` storage is
// `<&Str, Str>`, which the checker used to refuse as a `Str` argument (`lower_dump.mpl`
// had one). Read as a value it is `Str`, member by member, and lowering reads it through
// with a `switch`. A function's result keeps the reference (§5.4), so `pick` and `num`
// carry the union to every position below.
$decl s $new "ab"
$decl m $mut $new 5
$decl pick $func ($decl c $union (true, false)) $if c s "xyz"
$decl num  $func ($decl c $union (true, false)) $if c m 7
$decl main $func () {
  $decl a   $call len ($call pick (true))
  $decl b   $call len ($call concat ($call pick (false), "!"))
  $decl c   $call add ($call num (true), $call num (false))
  $decl n   $call num (true)
  $decl d   $match n ($case n ($call mul (n, 2)))
  $decl e   $new ($call num (false))
  $decl w   $set m ($call add ($call num (false), 1))
  $decl f   $call len ($call concat ($if false s "q", $if true s "q"))
  $decl ret $call add ($call add ($call add (a, $call mul (b, 10)), $call mul (c, 100)),
                $call add ($call add ($call mul (d, 10000), $call mul (e, 1000000)),
                    $call add ($call mul (m, 10000000), $call mul (f, 100000000))))
}.ret
