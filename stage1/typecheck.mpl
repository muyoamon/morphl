// Type-check a file: morphlc --run stage1/typecheck.mpl <file.mpl>
$decl I  $import "infer"
$decl Pa $import "parser"
$decl P  $import "prelude"

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))
$decl argv $call args ()
$decl path $if ($call lt (0, $call alen (argv))) ($call at (argv, 0))
    ($do ($call nl ("usage: morphlc --run stage1/typecheck.mpl <file.mpl>")) ($call panic ("no input")))

$decl r $call I.check_file (path)

$decl show_errs $func ($decl xs Pa.diags.node, $decl p "") $match xs (
  $case {$prop tag "cons"}
    $do ($call nl ($call concat (p, $call concat (":", $call concat ($call int_to_str (xs.head.line),
         $call concat (":", $call concat ($call int_to_str (xs.head.col),
         $call concat (": ", xs.head.msg)))))))) ($call show_errs (xs.tail, p)),
  $case xs ()
)
$decl a $call show_errs (r.errs, path)
$decl b $call nl ($call concat ("errors: ", $call int_to_str ($call Pa.diags.length (r.errs, 0))))
