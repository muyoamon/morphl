// std/test's failure path: one test passes and one does not, so the run must report the
// failure on stderr and abort (`zig build test-std` checks both). A runner whose failures
// went unnoticed would make every other test file worthless.

$decl T $import "std/test"

$decl good { $prop name "good"   $prop run $func () true }
$decl bad  { $prop name "broken" $prop run $func () $call eq (1, 2) }

$decl main $func () {
  $decl r   $call T.results ()
  $decl a   $call T.check (r, good)
  $decl b   $call T.check (r, bad)
  $decl c   $call T.expect (r, "inline", true)
  $decl ret $call T.finish (r)
}.ret
