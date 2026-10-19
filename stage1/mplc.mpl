// `mplc <file.mpl>` — a real command-line driver, emitting C on stdout — and
// `mplc <file.mpl> -o <exe> [cc args…]`, which hands the C to §9.1's `link` instead,
// with every argument after the executable passed on to `cc`. Any number of
// `-L <dir>` right after the file are §4.14's search roots, tried in order after the
// file's own directory (`Pa.resolve_import`).
//
// This is what §8's `args`, `at` and `alen` were missing a C backend for. Until
// they were emitted, no driver could be compiled at all: every one of them opens
// by reading `argv`, and `selfc.mpl` only exists because it works around that by
// reading its target out of a file.
$decl C  $import "compiler"
$decl Pa $import "parser"
$decl P  $import "prelude"

$decl argv $call args ()

$decl usage "usage: mplc <file.mpl> [-L <dir>]... [-o <exe> [cc args...]]"
$decl nargv $call alen (argv)
$decl arg_at $func ($decl i 0) $if ($call lt (i, nargv)) ($call P.sval ($call at (argv, i))) ""

$decl path $if ($call lt (0, nargv)) ($call arg_at (0)) ($call panic (usage))

// The `-L <dir>` pairs from position `i` on, in order, and where they end.
$decl lib_roots $func ($decl i 0, $decl acc Pa.pstrs.node)
  $if ($call eq_str ($call arg_at (i), "-L"))
      ($if ($call lt ($call add (i, 1), nargv))
           ($call lib_roots ($call add (i, 2), $call Pa.pstrs.cons ($call arg_at ($call add (i, 1)),
               acc)))
           ($call panic (usage)))
      ($call Pa.pstrs.reverse (acc, Pa.pstrs.nil))
$decl lib_end $func ($decl i 0)
  $if ($call eq_str ($call arg_at (i), "-L")) ($call lib_end ($call add (i, 2))) i

$decl roots $call lib_roots (1, Pa.pstrs.nil)
$decl o_at  $call lib_end (1)

// `-o <exe>`, or "" to print the C.
$decl out_path $if ($call lt ($call add (o_at, 1), nargv))
    ($if ($call eq_str ($call arg_at (o_at), "-o")) ($call arg_at ($call add (o_at, 1)))
         ($call panic (usage)))
    ($if ($call lt (o_at, nargv)) ($call panic (usage)) "")

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
           // `verify` and `link` have no source position to give (the typed tree
           // carries no spans), so a zero one is left out rather than printed.
           $call concat ($if ($call lt (0, ds.head.line))
               ($call concat (":", $call concat ($call int_to_str (ds.head.line),
                $call concat (":", $call int_to_str (ds.head.col))))) "",
           $call concat (": ", ds.head.msg)))))))),
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
// One line per diagnostic, on stderr. The file comes off the diagnostic, as
// `first_msg`'s does, and an emit diagnostic has no position (the typed tree carries
// no spans), so it has none here either.
$decl warn_all $func ($decl ds Pa.diags.node) $match ds (
  $case {$prop tag "cons"}
    $do ($call eprint ($call concat ($if ($call eq_str (ds.head.file, "")) path ds.head.file,
          $call concat ($if ($call lt (0, ds.head.line))
                            ($call concat (":", $call concat ($call int_to_str (ds.head.line),
                             $call concat (":", $call int_to_str (ds.head.col)))))
                            "",
          $call concat (": warning: ", $call concat (ds.head.msg, "\n"))))))
        ($call warn_all ($call Pa.diags.val (ds.tail))),
  $case ds ()
)

// The arguments after `-o <exe>`, which go to `cc`.
$decl xbase  $call add (o_at, 2)
$decl nextra $if ($call lt (xbase, nargv)) ($call sub (nargv, xbase)) 0
$decl extra  $call array (nextra, "")

$decl fill_extra $func ($decl i 0)
  $if ($call lt (i, nextra))
      ($do {
         $decl c   $call at (extra, i)
         $decl w   $set c ($call arg_at ($call add (i, xbase)))
         $decl ret ()
       }.ret ($call fill_extra ($call add (i, 1))))
      ()

$decl filled $call fill_extra (0)

$decl main $func () {
  $decl ckd $call C.check ($call C.parse (src, path, roots))
  $decl cd  $call Pa.diags.val (ckd.diagnostics)
  $decl nc  $call Pa.diags.length (cd, 0)
  $decl g1  $if ($call lt (0, nc)) ($call panic ($call first_msg (cd, "check", nc))) ""
  $decl bad $call C.verify (ckd.program)
  $decl nv  $call Pa.diags.length (bad, 0)
  $decl g2  $if ($call lt (0, nv)) ($call panic ($call first_msg (bad, "verify", nv))) ""
  $decl out $call C.emit (ckd.program)
  // Emit's diagnostics are not fatal — "no top-level $decl named 'main'" is not an
  // error for a library, which is most of what this compiles — and they used to be
  // invisible here, because §8 gave a program stdout (the C) and `panic` (fatal)
  // and nothing between. BOOTSTRAP §2's `eprint` is the between.
  $decl w   $call warn_all ($call Pa.diags.val (out.diagnostics))
  $decl ret $if ($call eq_str (out_path, "")) ($call C.sole_text (out)) {
    // A link failure is fatal, like a check failure: there is no executable.
    $decl lk   $call C.link (out, out_path, extra)
    $decl ld   $call Pa.diags.val (lk.diagnostics)
    $decl nl   $call Pa.diags.length (ld, 0)
    $decl g3   $if ($call lt (0, nl)) ($call panic ($call first_msg (ld, "link", nl))) ""
    $decl ret2 ""
  }.ret2
}.ret
