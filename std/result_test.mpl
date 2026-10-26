// std/result's tests, as §9's test blocks run by `std/test`: `mplc std/result_test.mpl -L .
// -o …` from the repository root. A failure is reported on stderr and aborts; `main`
// answers how many passed, which `zig build test-std` compares.

$decl C $import "std/core"
$decl R $import "std/result"
$decl T $import "std/test"

$decl ires $specialize R.result (0, "")
// Both sides `Str`, which is why the members are tag blocks.
$decl sres $specialize R.result ("", "")

$decl parse $func ($decl s "") {
  $decl o   $call str_to_int (s)
  $decl ret $match o ($case {$prop tag "some"} $call ires.ok (o.v), $case o $call ires.err (s))
}.ret

// §4.15: `$try` hands the failure up, payload and all.
$decl doubled $func ($decl s "") {
  $decl r   $try ($call parse (s)) err
  $decl ret $call mul (r.v, 2)
}.ret
$decl why $func ($decl s "") {
  $decl r   $call doubled (s)
  $decl ret $match r ($case {$prop tag "err"} r.e, $case r "ok")
}.ret

// A function over the bare union takes a result.
$decl tag_of $func ($decl r $union ({ $prop tag "ok" $decl v 0 }, { $prop tag "err" $decl e "" }))
  $match r ($case {$prop tag "ok"} "ok", $case r "err")

// An arm's narrowed member keeps the methods.
$decl via_arm $func ($decl s "") {
  $decl r   $call parse (s)
  $decl ret $match r (
    $case {$prop tag "ok"}  $call r.unwrap (),
    $case {$prop tag "err"} $call len ($call r.unwrap_err ()))
}.ret

$decl twice  $func ($decl n 0) $call int_to_str ($call mul (n, 2))
$decl length $func ($decl s "") $call len (s)

$decl t_ok  { $prop name "ok answers its value"
  $prop run $func () {
    $decl r   $call ires.ok (5)
    $decl ret $call C.and ($call C.and ($call r.is_ok (), $call C.not ($call r.is_err ())),
                           $call C.and ($call eq ($call r.value_or (0), 5),
                                        $call eq ($call r.unwrap (), 5)))
  }.ret }
$decl t_err { $prop name "err answers its failure"
  $prop run $func () {
    $decl r   $call ires.err ("bad")
    $decl ret $call C.and ($call C.and ($call r.is_err (), $call eq ($call r.value_or (7), 7)),
                           $call C.and ($call eq ($call r.error_or (""), "bad"),
                                        $call eq ($call r.unwrap_err (), "bad")))
  }.ret }
$decl t_join { $prop name "a function answering either is one result type"
  $prop run $func ()
    $call C.and ($call eq ($call ($call parse ("42")).value_or (-1), 42),
                 $call eq ($call ($call parse ("4x")).error_or (""), "4x")) }
$decl t_try { $prop name "$try passes a value on and hands a failure up"
  $prop run $func ()
    $call C.and ($call eq ($call why ("21"), "ok"), $call eq ($call why ("z"), "z")) }
$decl t_bare { $prop name "a result passes where the bare union is expected"
  $prop run $func ()
    $call C.and ($call eq ($call tag_of ($call parse ("1")), "ok"),
                 $call eq ($call tag_of ($call parse ("x")), "err")) }
$decl t_arm { $prop name "a narrowed member keeps the methods"
  $prop run $func ()
    $call C.and ($call eq ($call via_arm ("9"), 9), $call eq ($call via_arm ("abc"), 3)) }
$decl t_wrap { $prop name "wrap puts the methods on a bare union"
  $prop run $func ()
    $call eq ($call ($call ires.wrap ({ $prop tag "ok" $decl v 3 })).unwrap (), 3) }
$decl t_same { $prop name "one type on both sides"
  $prop run $func ()
    $call C.and ($call eq ($call ($call sres.ok ("a")).unwrap (), "a"),
                 $call eq ($call ($call sres.err ("b")).error_or (""), "b")) }
$decl t_map { $prop name "map changes the value and keeps a failure"
  $prop run $func () {
    $decl a   $call ires.map ($call parse ("21"), twice)
    $decl b   $call ires.map ($call parse ("q"), twice)
    $decl ret $call C.and ($call eq ($call a.value_or (""), "42"),
                           $call eq ($call b.error_or (""), "q"))
  }.ret }
$decl t_merr { $prop name "map_err changes the failure and keeps a value"
  $prop run $func () {
    $decl a   $call ires.map_err ($call parse ("abcd"), length)
    $decl b   $call ires.map_err ($call parse ("6"), length)
    $decl ret $call C.and ($call eq ($call a.error_or (0), 4), $call eq ($call b.value_or (0), 6))
  }.ret }

$decl main $func () {
  $decl r   $call T.results ()
  $decl a1  $call T.check (r, t_ok)
  $decl a2  $call T.check (r, t_err)
  $decl a3  $call T.check (r, t_join)
  $decl a4  $call T.check (r, t_try)
  $decl a5  $call T.check (r, t_bare)
  $decl a6  $call T.check (r, t_arm)
  $decl a7  $call T.check (r, t_wrap)
  $decl a8  $call T.check (r, t_same)
  $decl a9  $call T.check (r, t_map)
  $decl a10 $call T.check (r, t_merr)
  $decl ret $call T.finish (r)
}.ret
