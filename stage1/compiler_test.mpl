// Tests for §9's pipeline:
//
//   morphlc --run stage1/compiler_test.mpl
//
// Two things are being tested, and they are the two halves of §9's revision.
// That the steps are values a build program composes (§9.1), and that a pass
// is ordinary code the compiler does not know about — which is only safe
// because `verify` can tell whether one was wrong (§9.2).

$decl C  $import "compiler"
$decl F  $import "fold"
$decl IR $import "ir"
$decl T  $import "types"
$decl Pa $import "parser"
$decl P  $import "prelude"

$decl not P.not

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))

$decl check_str $func ($decl name "", $decl got "", $decl want "")
  $if ($call eq_str (got, want))
      ($do ($call print ("ok   ")) ($call nl (name)))
      ($do ($call print ("FAIL ")) ($do ($call nl (name))
      ($do ($call nl ($call concat ("  got  ", got)))
      ($do ($call nl ($call concat ("  want ", want))) ($call panic (name))))))

$decl check $func ($decl name "", $decl ok P.boolean)
  $if ok
      ($do ($call print ("ok   ")) ($call nl (name)))
      ($do ($call print ("FAIL ")) ($do ($call nl (name)) ($call panic (name))))

$decl n_errs $func ($decl ds Pa.diags.node) $call Pa.diags.length (ds, 0)

// §9.3 lets a pass compare two indices and key a table on one, and nothing
// else — so a test may not hard-code what a node's index will be either. It
// reads it off the node, which is the only thing the rule allows.
$decl at_node $func ($decl e IR.any_node, $decl m "")
  $call concat ("f node ", $call concat ($call int_to_str (e.id), $call concat (": ", m)))

$decl first_msg $func ($decl ds Pa.diags.node) $match ds (
  $case {$prop tag "cons"} ds.head.msg,
  $case ds ""
)

// ------------------------------------------------------- the steps compose
//
// §9.1: "`parse`, `check` and `emit` are separate calls over values, not one
// opaque build." Each one is called here on the value the last returned.

$decl src "$decl main $func () $call add (1, 2)"

$decl p1 $call C.parse (src, "t.mpl")

$decl t1 $call check ("parse answers with an AST and no diagnostics",
  $call P.and ($call Pa.diags.is_nil ($call Pa.diags.val (p1.diagnostics)),
               $call not ($call Pa.nodes.is_nil ($call Pa.nodes.val (p1.ast)))))

$decl t2 $call check_str ("...and the source's path travels with it", p1.path, "t.mpl")

$decl c1 $call C.check (p1)

$decl t3 $call check ("check answers with a program and no diagnostics",
  $call Pa.diags.is_nil ($call Pa.diags.val (c1.diagnostics)))

$decl mainfn $call IR.fns.nth ($call IR.fns.val (c1.program.funcs), 0)

$decl t4 $call check_str ("...whose one function is the file's one $decl",
  mainfn.name, "main")

$decl t5 $call check ("verify accepts what check produced",
  $call Pa.diags.is_nil ($call C.verify (c1.program)))

$decl t6 $call check ("emit turns it into C",
  $call P.and ($call Pa.diags.is_nil ($call Pa.diags.val (($call C.emit (c1.program)).diagnostics)),
               $call not ($call eq_str ($call P.sval (($call C.emit (c1.program)).text), ""))))

// A file the parser rejects stops at `parse`: §4.15 makes an expected failure
// a value, so the next step is still handed a `program` — an empty one.
$decl bad_parse $call C.check ($call C.parse ("$decl", "t.mpl"))

$decl t7 $call check ("a parse error reaches check as a diagnostic, not a panic",
  $call P.and ($call not ($call Pa.diags.is_nil ($call Pa.diags.val (bad_parse.diagnostics))),
               $call IR.fns.is_nil ($call IR.fns.val (bad_parse.program.funcs))))

// ------------------------------------------------------------ a pass is code
//
// §9.2: "an optimisation is a library", and a pipeline is ordinary
// composition. `fold` is imported like any other module.

$decl opt $call F.fold (c1.program)

$decl t8 $call check_str ("a pass rewrites the tree it was handed",
  $call IR.show ($call IR.eval (($call IR.fns.nth ($call IR.fns.val (opt.funcs), 0)).body)),
  "(int 3)")

$decl t9 $call check ("...and what it produced verifies",
  $call Pa.diags.is_nil ($call C.verify (opt)))

$decl t10 $call check ("...and the compiler emits it without knowing a pass ran",
  $call Pa.diags.is_nil ($call Pa.diags.val (($call C.emit (opt)).diagnostics)))

// ------------------------------------------------------ verify earns its keep
//
// Each of these is a program a pass could hand back. None of them is something
// lowering produces, which is the point: without `verify` the first the build
// hears of any of them is wrong C, or none.

// One type, one function of one parameter whose body reads that parameter.
$decl tys1 $call T.tys.cons (T.t_int, T.tys.nil)
$decl one  $call IR.ints.cons (0, IR.ints.nil)

// One argument, so a call to `f` above has the arity it wants.
$decl one_arg $call IR.exprs.cons ($call IR.e_int (0, 0), IR.exprs.nil)

$decl prog_of $func ($decl f IR.proto_fn)
  $call IR.program (tys1, $call IR.fns.cons (f, IR.fns.nil), IR.groups.nil, 0, IR.effects.nil)

$decl fn_of $func ($decl b IR.proto_expr, $decl st P.boolean)
  $call IR.fn ("f", one, 0, one, b, st, false, IR.ints.nil)

$decl good $call prog_of ($call fn_of ($call IR.e_local (0, 0), false))

$decl t11 $call check ("a hand-built program verifies",
  $call Pa.diags.is_nil ($call C.verify (good)))

// §7.2: a frame is the sum of its slots, so a slot number naming nothing is a
// frame the backend cannot declare.
$decl no_slot  $call IR.e_local (0, 3)
$decl bad_slot $call prog_of ($call fn_of (no_slot, false))

$decl t12 $call check_str ("verify rejects a slot that names nothing",
  $call first_msg ($call C.verify (bad_slot)),
  $call at_node (no_slot, "slot index 3 names nothing"))

// §9.3, and the one a real pass breaks: inlining copies a subtree, ids and
// all. Using one node twice is exactly what that looks like from here.
$decl shared   $call IR.e_local (0, 0)
$decl dup_ids  $call prog_of ($call fn_of ($call IR.e_do (0, shared, shared), false))

$decl t13 $call check ("verify rejects two nodes sharing an index",
  $call eq_int ($call n_errs ($call C.verify (dup_ids)), 1))

// §7.7: a call marked tail whose value is still used is a `continue` out of an
// expression that had a result.
$decl marked  $call IR.e_call (0, $call IR.e_global (0, 0), one_arg, true)
$decl mistail $call prog_of ($call fn_of (
  $call IR.e_do (0, marked, $call IR.e_int (0, 1)), false))

$decl t14 $call check_str ("verify rejects a tail mark on a call whose value is used",
  $call first_msg ($call C.verify (mistail)),
  $call at_node (marked, "marked as a tail call, but its value is used where it stands (§7.7)"))

// The other direction, which is the one that matters: a call in tail position
// that is not marked is TCE not happening, and §7.7 makes it mandatory.
$decl untail $call prog_of ($call fn_of (
  $call IR.e_call (0, $call IR.e_global (0, 0), one_arg, false), true))

$decl t15 $call check ("verify rejects a tail call left unmarked",
  $call eq_int ($call n_errs ($call C.verify (untail)), 2))

// §6a's cheap case emits a loop for a `self_tail` function; one that never
// re-enters it is a loop with no back edge.
$decl no_self $call prog_of ($call fn_of ($call IR.e_local (0, 0), true))

$decl t16 $call check_str ("verify rejects self_tail on a function that has none",
  $call first_msg ($call C.verify (no_self)),
  "f: self_tail is set, but no call in the body is a direct self tail call")

// §7.3 sizes a call from the callee's own type, so an argument count that does
// not match is a C call with the wrong signature.
$decl noargs    $call IR.e_call (0, $call IR.e_global (0, 0), IR.exprs.nil, true)
$decl bad_arity $call prog_of ($call fn_of (noargs, false))

$decl t17 $call check_str ("verify rejects a call with the wrong argument count",
  $call first_msg ($call C.verify (bad_arity)),
  $call at_node (noargs, "arguments: 0 where the function takes 1"))

$decl done $call nl ("all pipeline tests passed")
