// std/test: §9's test interface and a runner for it (STDLIB.md, D8).
//
// "Tests are a structural interface: any block conforming to `$traitsof {$prop name ""
// $prop run $func () true}` (§6) … The runner is library code." A test is a block with a
// `name` and a `run` answering whether it passed — `run` answers `C.bool`, since §3.2
// makes `true` a type of its own and a test that can fail answers either. Metadata is
// more props, which the trait ignores.
//
// There is no discovery: §9 keeps reflection to the build, so a test file hands its tests
// to the runner itself. They are passed one at a time rather than as a list because a
// top-level block is storage of the outermost frame, and §5.3a keeps a trait object over
// frame storage out of `$alloc`ed storage such as a list's cells.
//
//   $decl T $import "std/test"
//   $decl adds { $prop name "adds"  $prop run $func () $call eq ($call add (1, 1), 2) }
//   $decl main $func () {
//     $decl r   $call T.results ()
//     $decl a   $call T.check (r, adds)
//     $decl ret $call T.finish (r)
//   }.ret
//
// A failure is reported on stderr as it happens and `finish` panics if there was one, so
// the exit status is the verdict (§7.8 makes that 134). Nothing is printed on success, so
// `main`'s answer — the number that passed — is the whole of stdout.

$decl C $import "std/core"

$decl proto { $prop name ""  $prop run $func () C.bool }
$decl test  $traitsof proto

// What a run has seen so far.
$decl results $func () { $decl passed $mut $alloc 0  $decl failed $mut $alloc 0 }
$decl proto_results $call results ()

$decl bump $func ($decl c $mut $alloc 0) $set c ($call add ($call C.ival (c), 1))

// The outcome of one check, recorded; answers whether it passed.
$decl record $func ($decl r proto_results, $decl name "", $decl ok C.bool)
  $if ok ($do ($call bump (r.passed)) true)
      ($do ($call eprint ($call concat ("FAIL ", $call concat (name, "\n"))))
           ($do ($call bump (r.failed)) false))

// One test, through §9's interface.
$decl check $func ($decl r proto_results, $decl t test) $call record (r, t.name, $call t.run ())

// A check written inline, for an assertion that is not worth a block of its own.
$decl expect $func ($decl r proto_results, $decl name "", $decl ok C.bool)
  $call record (r, name, ok)

// The verdict: the number that passed, or a panic naming how many did not.
$decl finish $func ($decl r proto_results) {
  $decl p   $call C.ival (r.passed)
  $decl f   $call C.ival (r.failed)
  $decl ret $if ($call eq (f, 0)) p
                ($call panic ($call concat ($call int_to_str (f), $call concat (" of ",
                     $call concat ($call int_to_str ($call add (p, f)), " checks failed")))))
}.ret
