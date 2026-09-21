// Type-check a file: morphlc --run stage1/typecheck.mpl <file.mpl>
//
// §9's pipeline, stopped after `check`: a driver is a build program that calls
// the compiler library and prints what came back (§9.1).
$decl C  $import "compiler"
$decl Pa $import "parser"
$decl P  $import "prelude"

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))

$decl argv $call args ()
$decl path $if ($call lt (0, $call alen (argv))) ($call at (argv, 0))
    ($do ($call nl ("usage: morphlc --run stage1/typecheck.mpl <file.mpl>")) ($call panic ("no input")))

$decl rf  $call read_file (path)
$decl src $match rf (
  $case {$prop tag "some"} rf.v,
  $case rf ($call panic ($call concat ("cannot read ", path)))
)

$decl r $call C.infer ($call C.parse (src, path))

$decl show_errs $func ($decl xs Pa.diags.node, $decl p "") $match xs (
  $case {$prop tag "cons"}
    // The diagnostic names its own file; `p` is only the fallback for one that
    // predates the stamp.
    $do ($call nl ($call concat ($if ($call eq_str (xs.head.file, "")) p xs.head.file,
         $call concat (":", $call concat ($call int_to_str (xs.head.line),
         $call concat (":", $call concat ($call int_to_str (xs.head.col),
         $call concat (": ", xs.head.msg)))))))) ($call show_errs (xs.tail, p)),
  $case xs ()
)
$decl ds $call Pa.diags.val (r.diagnostics)
$decl a $call show_errs (ds, path)
$decl b $call nl ($call concat ("errors: ", $call int_to_str ($call Pa.diags.length (ds, 0))))
