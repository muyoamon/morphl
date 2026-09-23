// The compiler's *front* end as a program: parse and infer, nothing else.
//
// §9.1's pipeline stopped at `infer`, which is what a tool that only reports
// type errors wants. The point of stopping here is the import closure: no
// `lower`, so no §4.9 monomorphisation and none of `ir.mpl`'s tree — and the
// interned type count, not the line count, is what decides what a run costs.
$decl P  $import "prelude"
$decl Pa $import "parser"
$decl T  $import "types"
$decl I  $import "infer"

// A morphl program as a string, so the answer depends on nothing outside.
$decl src $call concat ("$decl twice $func ($decl n 0) $call add (n, n) ",
          $call concat ("$decl four $call twice (2) ",
                        "$decl main $func () $call twice (four) "))

// The number of top-level names inference solved, or minus the error count —
// so a failure is visible rather than a plausible-looking zero.
$decl front $func ($decl s "")
  { $decl p    $call Pa.parse (s)
    $decl its  $call Pa.nodes.val (p.exprs)
    $decl r    $call I.infer_file (its, I.root_env, "", "")
    $decl nerr $call Pa.diags.length ($call Pa.diags.val (r.errs), 0)
    $decl ty   $call T.tval (r.ty)
    $decl nfld $match ty (
        $case {$prop tag "block"} ($call T.fields.length ($call T.fields.val (ty.fields), 0)),
        $case ty -1
      )
    $decl out  $if ($call lt (0, nerr)) ($call sub (0, nerr)) nfld }.out

$decl main $func () $call front (src)
