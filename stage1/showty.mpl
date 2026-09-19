// Print the inferred type of one top-level declaration:
//   morphlc --run stage1/showty.mpl <file.mpl> <name>
$decl I  $import "infer"
$decl T  $import "types"
$decl P  $import "prelude"

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))
$decl argv $call args ()
$decl path $call at (argv, 0)
$decl name $call at (argv, 1)

$decl r $call I.check_file (path)
$decl f $call T.find_field (r.ty.fields, name)
$decl out $if ($call eq_str (f.name, ""))
    ($call nl ("<no such declaration>"))
    ($call nl ($call T.show (f.ty)))
