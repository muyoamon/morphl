// Lower a file and print its program:
//
//   morphlc --run stage1/lower_dump.mpl <file.mpl>
//
// The pipeline §9 calls parse / check / emit, minus the emit.
$decl I  $import "infer"
$decl L  $import "lower"
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

// `read_file` answers `none | {$prop tag "some" $decl v Str}` (§8).
$decl rf  $call read_file (path)
$decl src $match rf (
  $case {$prop tag "some"} rf.v,
  $case rf ($call panic ("cannot read the file"))
)
$decl r   $call I.check_source (src, $call P.dirname (path), path)
$decl ast $call Pa.parse (src)

$decl st  $call L.lstate ()
// §2's root block, straight from inference: a `binding` is `{name, ty}`, which
// is a `T.field`, so the same converter reads both (§5.1, prefix identity).
$decl prims $call L.prims_from ($call I.eval_env (I.root_env), L.benv.nil)
$decl prog $call L.lower_file (st, $call Pa.nodes.val (ast.exprs), r.ty, prims)

// Lowering a file inference rejected would be lowering nonsense, so say so.
$decl e0 $call nl ($call concat ("check errors: ",
    $call int_to_str ($call Pa.diags.length (r.errs, 0))))
$decl e1 $call nl ($call concat ("lower errors: ",
    $call int_to_str ($call Pa.diags.length ($call L.eval_diags (st.errs), 0))))
$decl a $call nl ($call concat ("types: ", $call int_to_str ($call T.tys.length (prog.types, 0))))
$decl b $call show_fns ($call IR.fns.val (prog.funcs), 0)
