// Type-check a file, printing a goal tree for every subtype check that fails:
//   morphlc --run stage1/trace.mpl <file.mpl>
$decl I  $import "infer"
$decl T  $import "types"
$decl Pa $import "parser"
$decl P  $import "prelude"

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))
$decl on $call T.enable_trace ()

$decl argv $call args ()
$decl path $call at (argv, 0)
$decl r $call I.check_file (path)
$decl out $call nl ($call concat ("errors: ", $call int_to_str ($call Pa.diags.length (r.errs, 0))))
