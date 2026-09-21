// Compile a file to C:
//
//   morphlc --run stage1/emit_c.mpl <file.mpl>
//
// §9's pipeline through `emit`, with `verify` in between — which is the shape
// §9.2 asks a build program to have while a pass is being developed, and there
// is no reason for the compiler's own driver to be less careful than that.
$decl C  $import "compiler"
$decl Pa $import "parser"
$decl P  $import "prelude"

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))

$decl show_errs $func ($decl xs Pa.diags.node, $decl what "") $match xs (
  $case {$prop tag "cons"}
    $do ($call nl ($call concat (what, $call concat (": ", xs.head.msg))))
        ($call show_errs ($call Pa.diags.val (xs.tail), what)),
  $case xs ()
)

$decl argv $call args ()
$decl path $call at (argv, 0)

$decl rf  $call read_file (path)
$decl src $match rf (
  $case {$prop tag "some"} rf.v,
  $case rf ($call panic ($call concat ("cannot read ", path)))
)

$decl ckd $call C.check ($call C.parse (src, path))
$decl bad $call C.verify (ckd.program)
$decl out $call C.emit (ckd.program)

$decl e0 $call show_errs ($call Pa.diags.val (ckd.diagnostics), "check")
$decl e1 $call show_errs (bad, "verify")
$decl e2 $call show_errs ($call Pa.diags.val (out.diagnostics), "emit")
$decl e3 $call print ($call P.sval (out.text))
