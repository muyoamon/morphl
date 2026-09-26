// **Stage 2's real gate.** §9's whole pipeline — parse, check, verify, emit — as
// a program, with no `args`: the input path is a string literal, so nothing here
// needs `args`/`at`/`alen`, none of which has a C backend. §8's `read_file` is
// emitted, so the input is read at run time.
//
// `main` returns the emitted C and nothing else, so stdout *is* the artifact and
// can be diffed byte-for-byte against what stage 0 emits for the same file.
// Both are running the identical stage-1 source, so they must agree; the
// diagnostics are deliberately left out rather than interleaved, and
// `self.mpl` is what reports them.
$decl C  $import "compiler"
$decl Pa $import "parser"
$decl P  $import "prelude"

$decl path "stage1/lexer.mpl"

$decl rf  $call read_file (path)
$decl src $match rf (
  $case {$prop tag "some"} rf.v,
  $case rf ($call panic ("cannot read stage1/lexer.mpl"))
)

$decl emit_it $func ($decl s "")
  { $decl ckd $call C.check ($call C.parse (s, path))
    $decl bad $call C.verify (ckd.program)
    $decl out $call C.emit (ckd.program)
    $decl r   $call P.sval (out.text) }.r

$decl main $func () $call emit_it (src)
