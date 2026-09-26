// `mplc <file.mpl>` — a real command-line driver, emitting C on stdout.
//
// This is what §8's `args`, `at` and `alen` were missing a C backend for. Until
// they were emitted, no driver could be compiled at all: every one of them opens
// by reading `argv`, and `selfc.mpl` only exists because it works around that by
// reading its target out of a file.
$decl C  $import "compiler"
$decl P  $import "prelude"

$decl argv $call args ()

$decl path $if ($call lt (0, $call alen (argv)))
    ($call P.sval ($call at (argv, 0)))
    ($call panic ("usage: mplc <file.mpl>"))

$decl rf  $call read_file (path)
$decl src $match rf (
  $case {$prop tag "some"} rf.v,
  $case rf ($call panic ($call concat ("cannot read ", path)))
)

$decl main $func ()
  { $decl ckd $call C.check ($call C.parse (src, path))
    $decl bad $call C.verify (ckd.program)
    $decl out $call C.emit (ckd.program)
    $decl r   $call P.sval (out.text) }.r
