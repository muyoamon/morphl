// Compile a file to C with a pass in the middle:
//
//   morphlc --run stage1/opt_c.mpl <file.mpl>
//
// §9.2's build program, written out. The difference from `emit_c.mpl` is one
// line — the call to `F.fold` — which is the claim being made: a pass is
// ordinary composition, there is no registry to register with and no level to
// select, and a project that wants none of this runs `emit_c.mpl` instead.
//
// `verify` runs on both sides of the pass, because the interesting failure is
// not "the pass produced nonsense" but "the pass produced nonsense from
// something that was fine".
$decl C  $import "compiler"
$decl F  $import "fold"
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

$decl ckd  $call C.check ($call C.parse (src, path))
$decl bad0 $call C.verify (ckd.program)
$decl opt  $call F.fold (ckd.program)
$decl bad1 $call C.verify (opt)
$decl out  $call C.emit (opt)

$decl e0 $call show_errs ($call Pa.diags.val (ckd.diagnostics), "check")
$decl e1 $call show_errs (bad0, "verify (before)")
$decl e2 $call show_errs (bad1, "verify (after fold)")
$decl e3 $call show_errs ($call Pa.diags.val (out.diagnostics), "emit")
$decl e4 $call print ($call P.sval (out.text))
