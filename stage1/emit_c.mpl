// Compile a file to C:
//
//   morphlc --run stage1/emit_c.mpl <file.mpl>
//
// §9's pipeline minus the link step: parse, check, lower, emit.
$decl I  $import "infer"
$decl L  $import "lower"
$decl E  $import "emit"
$decl IR $import "ir"
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

$decl r   $call I.check_source (src, $call P.dirname (path), path)
$decl ast $call Pa.parse (src)
$decl st  $call L.lstate ()
$decl prims $call L.prims_from ($call I.eval_env (I.root_env), L.benv.nil)
$decl prog  $call L.lower_file (st, $call Pa.nodes.val (ast.exprs), r.ty, prims)

$decl est $call E.estate ()
$decl c   $call E.emit_program (est, prog)

$decl e0 $call show_errs (r.errs, "check")
$decl e1 $call show_errs ($call L.eval_diags (st.errs), "lower")
$decl e2 $call show_errs ($call E.emit_errs (est), "emit")
$decl out $call print (c)
