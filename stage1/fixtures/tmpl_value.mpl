// §4.9: a template's body may be any expression, and one that is neither a block nor a
// `$func` is a value — lowered where each use stands (`spec_expr`), since values are not
// memoised. It was refused ("the only shape lowered so far"), though the checker accepted it.
// Each digit is one shape: an option type, a recursive generic list (§5.5's knot through
// `$alloc` in a later member), a body that evaluates its generic — two sites, one type, two
// values — and a value template written in a function, reading its frame.
$decl opt  $template T $union ({ $prop tag "none" }, { $prop tag "some" $decl v T })
$decl lst  $template T $union ({ $prop tag "nil" },
                               { $prop tag "cons" $decl h T $decl t $alloc $specialize lst T })
$decl pick $template T $union ({ $prop tag "some" $decl v T }, { $prop tag "none" })
$decl oi   $specialize opt 0
$decl li   $specialize lst 0
$decl get  $func ($decl o oi, $decl d 0) $match o ($case {$prop tag "some"} o.v, $case o d)
$decl len  $func ($decl xs li, $decl n 0)
  $match xs ($case {$prop tag "cons"} ($call len (xs.t, $call add (n, 1))), $case xs n)
$decl at   $func ($decl k 0) {
  $decl p1  $specialize pick 5
  $decl p2  $specialize pick k
  $decl box $template T $union ({ $prop tag "b" $decl v $call add (T, k) }, { $prop tag "e" })
  $decl b   $specialize box 10
  $decl ret $call add ($call mul ($call get (p1, 0), 100),
            $call add ($call mul ($call get (p2, 0), 10), $match b ($case {$prop tag "b"} b.v,
                                                                     $case b 0)))
}.ret
$decl main $func () $call add ($call mul ($call get (oi, 4), 10000),
                     $call add ($call mul ($call len (li, 3), 1000), $call at (2)))
