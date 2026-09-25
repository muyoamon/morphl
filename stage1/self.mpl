// **Stage 2's driver.** §9's whole pipeline — parse, check, verify — as a
// program that can be compiled and run, with no `args`: the path is a string
// literal, so nothing here needs `args`/`at`/`alen`, none of which has a C
// backend. §8's `read_file` is emitted, so the input is read at run time like
// any other file.
//
// The answer is the number of functions the lowered program has, or minus the
// error count, so a failure is visible rather than a plausible-looking zero.
$decl C  $import "compiler"
$decl IR $import "ir"
$decl Pa $import "parser"
$decl P  $import "prelude"

$decl path "stage1/lexer.mpl"

$decl rf  $call read_file (path)
$decl src $match rf (
  $case {$prop tag "some"} rf.v,
  $case rf ($call panic ("cannot read stage1/lexer.mpl"))
)

$decl run_it $func ($decl s "")
  { $decl ckd  $call C.check ($call C.parse (s, path))
    $decl prog ckd.program
    $decl bad  $call C.verify (prog)
    $decl ne   $call Pa.diags.length ($call Pa.diags.val (ckd.diagnostics), 0)
    $decl nv   $call Pa.diags.length (bad, 0)
    $decl nf   $call IR.fns.length ($call IR.fns.val (prog.funcs), 0)
    $decl nbad $call add (ne, nv)
    $decl out  $if ($call lt (0, nbad)) ($call sub (0, nbad)) nf }.out

$decl main $func () $call run_it (src)
