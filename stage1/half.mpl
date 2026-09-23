// The compiler's front half as a *program*: parse, infer, lower.
//
// §9.1's pipeline up to `check`, with no `verify` and no `emit`, so the import
// closure stops before the backend. The point is to compile a runnable piece of
// stage 1 to C and have it produce the same answer under both implementations —
// which is BOOTSTRAP's stage-2 gate in miniature.
$decl P  $import "prelude"
$decl Pa $import "parser"
$decl T  $import "types"
$decl I  $import "infer"
$decl IR $import "ir"
$decl L  $import "lower"

// A morphl program, as a string, so the answer depends on nothing outside.
$decl src $call concat ("$decl twice $func ($decl n 0) $call add (n, n) ",
          $call concat ("$decl four $call twice (2) ",
                        "$decl main $func () $call twice (four) "))

$decl lowered $func ($decl s "")
  { $decl p    $call Pa.parse (s)
    $decl its  $call Pa.nodes.val (p.exprs)
    $decl r    $call I.infer_file (its, I.root_env, "", "")
    $decl nerr $call Pa.diags.length ($call Pa.diags.val (r.errs), 0)
    // A negative answer reports the error count, so a failure is visible
    // rather than silently zero.
    $decl out  $if ($call lt (0, nerr)) ($call sub (0, nerr))
        { $decl st    $call L.lstate ()
          $decl prims $call L.prims_from (I.root_env, L.benv.nil)
          $decl prog  $call L.lower_file (st, its, $call T.tval (r.ty), prims, "")
          $decl n     $call IR.fns.length ($call IR.fns.val (prog.funcs), 0)
          $decl z     n }.z }.out

$decl main $func () $call lowered (src)
