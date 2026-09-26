// `emit_diag <file.mpl>` — §9's pipeline through `emit`, printing the
// *diagnostics* and discarding the C.
//
// It exists because `mplc` cannot report a non-fatal diagnostic: §8 gives
// `print` (stdout) and `panic` (stderr, then abort) and nothing between, and a
// warning printed by `mplc` would corrupt the C it is emitting. So the
// diagnostics get a driver of their own, where stdout is free. Compiled, it
// answers for the whole compiler in about a second, where stage 0 needs ninety
// minutes.
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

// Everything runs inside `main`, and that is not style. A top-level `$decl` is a
// thunk assigned by `mpl_init` in index order (§4.10), and the entry file's own
// items are lifted *before* the members of the modules it imports — so a
// top-level `$decl` here that called `C.check` would read a zeroed `P` and
// segfault. `main` runs after `mpl_init` has finished, which is the only place
// an imported module is known to be initialised.
$decl main $func ()
  { $decl argv $call args ()
    $decl path $if ($call lt (0, $call alen (argv)))
        ($call P.sval ($call at (argv, 0)))
        ($call panic ("usage: emit_diag <file.mpl>"))
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
    $decl r  "" }.r
