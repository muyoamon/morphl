// A **reusable** stage-2 compiler. The input path is read from the file
// `target` in the working directory, so one binary can emit C for any file
// without `args`, which has no backend (§8's `args`/`at`/`alen` are not
// emitted). `read_file` is emitted, so both the target name and the source
// itself are read at run time.
//
// `main` returns the emitted C and nothing else, so stdout is the artifact and
// can be diffed byte-for-byte.
$decl C  $import "compiler"
$decl P  $import "prelude"

$decl tf  $call read_file ("target")
$decl raw $match tf (
  $case {$prop tag "some"} tf.v,
  $case tf ($call panic ("cannot read ./target"))
)

// One trailing newline stripped, so `echo <path> > target` works.
$decl chomp $func ($decl s "")
  { $decl n $call len (s)
    $decl r $if ($call lt (0, n))
        ($if ($call eq_int ($call byte (s, $call sub (n, 1)), 10))
             ($call slice (s, 0, $call sub (n, 1))) s)
        s }.r

$decl path $call chomp (raw)

$decl rf  $call read_file (path)
$decl src $match rf (
  $case {$prop tag "some"} rf.v,
  $case rf ($call panic ("cannot read the target named by ./target"))
)

$decl emit_it $func ($decl s "", $decl p "")
  { $decl ckd $call C.check ($call C.parse (s, p))
    $decl bad $call C.verify (ckd.program)
    $decl out $call C.emit (ckd.program)
    $decl r   $call P.sval (out.text) }.r

$decl main $func () $call emit_it (src, path)
