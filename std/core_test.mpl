// std/core's tests, as §9's test blocks run by `std/test`: `mplc std/core_test.mpl -L .
// -o …` from the repository root. A failure is reported on stderr and aborts; `main`
// answers how many passed, which `zig build test-std` compares.

$decl C $import "std/core"
$decl T $import "std/test"

$decl idiv    $func ($decl a 0, $decl b 0)
  $if ($call eq (b, 0)) ($call C.fail ("division by zero")) ($call div (a, b))
// §4.15: `$try` hands the failure up, carrying its payload.
$decl half_of $func ($decl a 0, $decl b 0) {
  $decl q   $try ($call idiv (a, b)) err
  $decl ret $call div (q, 2)
}.ret
$decl why     $func ($decl a 0, $decl b 0) {
  $decl r   $call half_of (a, b)
  $decl ret $match r ($case {$prop tag "err"} r.e, $case r "ok")
}.ret
$decl parsed  $func ($decl s "") $call C.or_else ($call str_to_int (s), -1)

// A type with its own equality and order: by `k`, so two of one `k` are equal and ordered
// neither way, whatever their tags.
$decl ieq eq
$decl ilt lt
$decl kv $func ($decl k 0, $decl tag "") {
  $decl p   { $decl key k  $decl name tag
    $prop eq $func ($decl o p) $call ieq (p.key, o.key)
    $prop lt $func ($decl o p) $call ilt (p.key, o.key) }
  $decl ret p
}.ret
$decl doubled $func ($decl s "")
  $call C.map_opt ($call str_to_int (s), $func ($decl n 0) $call int_to_str ($call mul (n, 2)))

$decl t_not { $prop name "not"
  $prop run $func () $call C.and ($call C.not (false), $call C.not ($call C.not (true))) }
$decl t_and { $prop name "and"
  $prop run $func ()
    $call C.and ($call C.and (true, true), $call C.not ($call C.and (true, false))) }
$decl t_or  { $prop name "or"
  $prop run $func ()
    $call C.and ($call C.or (false, true), $call C.not ($call C.or (false, false))) }
$decl t_max { $prop name "max and min on Int"
  $prop run $func ()
    $call C.and ($call eq ($call C.max (3, 9), 9), $call eq ($call C.min (3, 9), 3)) }
$decl t_maxf { $prop name "max and min on Float"
  $prop run $func ()
    $call C.and ($call eq ($call C.max (2.5, -1.0), 2.5),
                 $call eq ($call C.min (2.5, -1.0), -1.0)) }
$decl t_some { $prop name "some and none"
  $prop run $func () $call C.and ($call C.is_some ($call C.some (4)), $call C.is_none (none)) }
$decl t_else { $prop name "or_else takes the value or falls back"
  $prop run $func ()
    $call C.and ($call eq ($call parsed ("42"), 42), $call eq ($call parsed ("4x"), -1)) }
$decl t_map  { $prop name "map_opt maps a value and keeps none"
  $prop run $func () $call C.and ($call eq ($call C.or_else ($call doubled ("20"), ""), "40"),
                                  $call C.is_none ($call doubled ("x"))) }
$decl t_try  { $prop name "$try passes a value on and hands a failure up"
  $prop run $func ()
    $call C.and ($call eq ($call why (8, 2), "ok"), $call eq ($call why (8, 0), "division by zero")) }
$decl t_val  { $prop name "ival reads storage"
  $prop run $func () $call eq ($call C.ival ($mut $alloc 7), 7) }
$decl t_eq   { $prop name "equal and unequal, through eq_proto"
  $prop run $func ()
    $call C.and ($call C.equal ($call kv (3, "a"), $call kv (3, "b")),
                 $call C.unequal ($call kv (3, "a"), $call kv (4, "a"))) }
$decl t_ord  { $prop name "the comparisons, through ord_proto"
  $prop run $func ()
    $call C.and ($call C.and ($call C.less ($call kv (1, ""), $call kv (2, "")),
                              $call C.greater ($call kv (2, ""), $call kv (1, ""))),
                 $call C.and ($call C.less_eq ($call kv (2, ""), $call kv (2, "")),
                              $call C.not ($call C.greater_eq ($call kv (1, ""),
                                                              $call kv (2, ""))))) }
$decl lo $call kv (1, "lo")
$decl hi $call kv (9, "hi")
$decl t_maxo { $prop name "max_ord and min_ord, and a tie keeps the first"
  $prop run $func ()
    $call C.and ($call C.and ($call eq (($call C.max_ord (lo, hi)).name, "hi"),
                              $call eq (($call C.min_ord (lo, hi)).name, "lo")),
                 $call eq (($call C.max_ord ($call kv (5, "one"), $call kv (5, "two"))).name, "one")) }

$decl main $func () {
  $decl r   $call T.results ()
  $decl a1  $call T.check (r, t_not)
  $decl a2  $call T.check (r, t_and)
  $decl a3  $call T.check (r, t_or)
  $decl a4  $call T.check (r, t_max)
  $decl a5  $call T.check (r, t_maxf)
  $decl a6  $call T.check (r, t_some)
  $decl a7  $call T.check (r, t_else)
  $decl a8  $call T.check (r, t_map)
  $decl a9  $call T.check (r, t_try)
  $decl a10 $call T.check (r, t_val)
  $decl a11 $call T.check (r, t_eq)
  $decl a12 $call T.check (r, t_ord)
  $decl a13 $call T.check (r, t_maxo)
  $decl ret $call T.finish (r)
}.ret
