// std/core's tests: `mplc std/core_test.mpl -L . -o …`, from the repository root. A
// failing check panics with its name; `main` answers how many passed, which the build
// compares, so a run that stopped early cannot pass (`zig build test-std`).

$decl C $import "std/core"

$decl check $func ($decl name "", $decl ok C.bool) $if ok 1 ($call panic ($call concat ("FAIL ", name)))

$decl idiv     $func ($decl a 0, $decl b 0)
  $if ($call eq (b, 0)) ($call C.fail ("division by zero")) ($call div (a, b))
// §4.15: `$try` hands the failure up, carrying its payload.
$decl half_of  $func ($decl a 0, $decl b 0) {
  $decl q   $try ($call idiv (a, b)) err
  $decl ret $call div (q, 2)
}.ret
$decl why      $func ($decl a 0, $decl b 0) {
  $decl r   $call half_of (a, b)
  $decl ret $match r ($case {$prop tag "err"} r.e, $case r "ok")
}.ret
$decl parsed   $func ($decl s "") $call C.or_else ($call str_to_int (s), -1)

$decl main $func () {
  $decl b1  $call check ("not", $call C.and ($call C.not (false), $call C.not ($call C.not (true))))
  $decl b2  $call check ("and is strict but right", $call C.not ($call C.and (true, false)))
  $decl b3  $call check ("or",
                $call C.and ($call C.or (false, true), $call C.not ($call C.or (false, false))))
  $decl n1  $call check ("max on Int", $call eq ($call C.max (3, 9), 9))
  $decl n2  $call check ("min on Int", $call eq ($call C.min (3, 9), 3))
  $decl n3  $call check ("max on Float", $call eq ($call C.max (2.5, -1.0), 2.5))
  $decl n4  $call check ("min on Float", $call eq ($call C.min (2.5, -1.0), -1.0))
  $decl o1  $call check ("some is some", $call C.is_some ($call C.some (4)))
  $decl o2  $call check ("none is none", $call C.is_none (none))
  $decl o3  $call check ("or_else takes the value", $call eq ($call parsed ("42"), 42))
  $decl o4  $call check ("or_else falls back", $call eq ($call parsed ("4x2"), -1))
  $decl om  $call C.map_opt ($call str_to_int ("20"),
                $func ($decl n 0) $call int_to_str ($call mul (n, 2)))
  $decl o5  $call check ("map_opt maps a value", $call eq ($call C.or_else (om, ""), "40"))
  $decl on  $call C.map_opt ($call str_to_int ("x"), $func ($decl n 0) $call int_to_str (n))
  $decl o6  $call check ("map_opt keeps none", $call C.is_none (on))
  $decl r1  $call check ("$try passes a value on", $call eq ($call why (8, 2), "ok"))
  $decl r2  $call check ("$try hands the failure up", $call eq ($call why (8, 0), "division by zero"))
  $decl v1  $call check ("ival reads storage", $call eq ($call C.ival ($mut $alloc 7), 7))
  $decl ret $call add ($call add ($call add ($call add (b1, b2), $call add (b3, n1)),
                                 $call add ($call add (n2, n3), $call add (n4, o1))),
                       $call add ($call add ($call add (o2, o3), $call add (o4, o5)),
                                 $call add ($call add (o6, r1), $call add (r2, v1))))
}.ret
