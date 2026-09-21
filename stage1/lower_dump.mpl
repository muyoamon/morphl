// Lower a file and print its program:
//
//   morphlc --run stage1/lower_dump.mpl <file.mpl>
//
// §9's pipeline stopped after `check` — which is where the typed tree is, so
// this is the view a pass author has of what they are being handed (§9.2).
$decl C  $import "compiler"
$decl IR $import "ir"
$decl T  $import "types"
$decl Pa $import "parser"
$decl P  $import "prelude"

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))

$decl argv $call args ()
$decl path $call at (argv, 0)

$decl show_fns $func ($decl fs IR.fns.node, $decl i 0) $match fs (
  $case {$prop tag "cons"}
    $do ($call nl ($call concat ($call int_to_str (i),
         $call concat (" ", $call concat (fs.head.name,
         $call concat ($call concat ("/", $call int_to_str ($call IR.ints.length (fs.head.params, 0))),
         $call concat (" slots=", $call concat ($call int_to_str ($call IR.ints.length ($call IR.ints.val (fs.head.slots), 0)),
         $call concat ("  ", $call IR.show (fs.head.body))))))))))
        ($call show_fns ($call IR.fns.val (fs.tail), $call add (i, 1))),
  $case fs ()
)

$decl show_errs $func ($decl xs Pa.diags.node, $decl what "") $match xs (
  $case {$prop tag "cons"}
    $do ($call nl ($call concat (what, $call concat (": ", xs.head.msg))))
        ($call show_errs ($call Pa.diags.val (xs.tail), what)),
  $case xs ()
)

// `read_file` answers `none | {$prop tag "some" $decl v Str}` (§8).
$decl rf  $call read_file (path)
$decl src $match rf (
  $case {$prop tag "some"} rf.v,
  $case rf ($call panic ("cannot read the file"))
)

$decl ckd $call C.check ($call C.parse (src, path))
$decl prog ckd.program
$decl bad $call C.verify (prog)

$decl e0 $call nl ($call concat ("check errors: ",
    $call int_to_str ($call Pa.diags.length ($call Pa.diags.val (ckd.diagnostics), 0))))
$decl e1 $call show_errs ($call Pa.diags.val (ckd.diagnostics), "  ")
$decl e2 $call nl ($call concat ("verify errors: ", $call int_to_str ($call Pa.diags.length (bad, 0))))
$decl e3 $call show_errs (bad, "  ")
$decl a $call nl ($call concat ("types: ", $call int_to_str ($call T.tys.length ($call T.tys.val (prog.types), 0))))
$decl b $call show_fns ($call IR.fns.val (prog.funcs), 0)
