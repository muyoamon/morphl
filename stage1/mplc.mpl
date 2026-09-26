// `mplc <file.mpl>` — a real command-line driver, emitting C on stdout.
//
// This is what §8's `args`, `at` and `alen` were missing a C backend for. Until
// they were emitted, no driver could be compiled at all: every one of them opens
// by reading `argv`, and `selfc.mpl` only exists because it works around that by
// reading its target out of a file.
$decl C  $import "compiler"
$decl Pa $import "parser"
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

// The first diagnostic, formatted like stage 0's. `Pa.diag` carries the file
// that raised it, which need not be the file `mplc` was pointed at (§10.7: a
// `$template`'s body is checked at the specialization site).
$decl first_msg $func ($decl ds Pa.diags.node, $decl what "", $decl n 0)
  $match ds (
    $case {$prop tag "cons"}
      ($call concat (what, $call concat (": ", $call concat ($call int_to_str (n),
           $call concat (" error(s), first at ",
           $call concat ($if ($call eq_str (ds.head.file, "")) path ds.head.file,
           $call concat (":", $call concat ($call int_to_str (ds.head.line),
           $call concat (":", $call concat ($call int_to_str (ds.head.col),
           $call concat (": ", ds.head.msg))))))))))),
    $case ds ($call concat (what, ": failed"))
  )

// **A compiler that cannot compile must not print C and exit 0.** It used to:
// `mplc` returned only `out.text`, so a program that did not typecheck got 202
// lines of plausible C, an exit status of 0, and nothing on stderr. §8's `panic`
// is the only route to stderr that is emitted (`mpl_panic_str` writes and
// aborts), so that is what a check or verify failure takes.
//
// Emit diagnostics are deliberately *not* fatal: the three §6a groups are a
// documented refusal and "no top-level `$decl` named `main`" is not an error for
// a library, which is most of what this compiles.
$decl main $func ()
  { $decl ckd $call C.check ($call C.parse (src, path))
    $decl cd  $call Pa.diags.val (ckd.diagnostics)
    $decl nc  $call Pa.diags.length (cd, 0)
    $decl g1  $if ($call lt (0, nc)) ($call panic ($call first_msg (cd, "check", nc))) ""
    $decl bad $call C.verify (ckd.program)
    $decl nv  $call Pa.diags.length (bad, 0)
    $decl g2  $if ($call lt (0, nv)) ($call panic ($call first_msg (bad, "verify", nv))) ""
    $decl out $call C.emit (ckd.program)
    $decl r   $call P.sval (out.text) }.r
