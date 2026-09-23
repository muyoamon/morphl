// Constant folding, as §9.2 means it: an ordinary module that happens to
// export a `program -> program` function.
//
// Nothing here is privileged. It imports `ir` the way any project would, it is
// not registered anywhere, and the compiler does not know it ran — §9.2 makes
// that last part a constraint on the *compiler*: `emit` stays correct on
// unoptimised input, so a build that does not call this one simply gets the
// arithmetic at runtime.
//
// It is also the smallest pass that runs into all three of §9.3's rules:
//
//   * it rebuilds nodes, so every node it makes takes a **fresh index** — a
//     copied id would alias two nodes in every side table;
//   * it keeps each node's `ty`, because folding `add(1, 2)` to `3` does not
//     change the type, and inventing an index into `program.types` from here
//     would name whatever happened to be there;
//   * it carries nothing in the tree. There is nothing to carry, which is the
//     easy case — a pass with analysis results keeps them beside it (§9.3: a
//     field added to a node is dropped by §7.4's prefix copy on the way in).
//
// `verify` is what says whether it got those right, which is the point of
// having it (§9.2: "mandatory after every pass while developing one").

$decl P  $import "prelude"
$decl IR $import "ir"

$decl or P.or

// ------------------------------------------------------------- the fold rule

$decl prim_name $func ($decl e IR.proto_expr) $match e (
  $case {$prop tag "prim"} e.name,
  $case e ""
)

$decl is_int $func ($decl e IR.proto_expr) $match e (
  $case {$prop tag "int"} true,
  $case e false
)

$decl int_val $func ($decl e IR.proto_expr) $match e (
  $case {$prop tag "int"} e.v,
  $case e 0
)

// §8's arithmetic, and only the part that cannot fail: `div` by a constant
// zero would have to become a panic rather than a value, and a pass that turns
// a program into one that aborts is not the same program.
$decl foldable $func ($decl op "")
  $call or ($call eq_str (op, "add"),
      $call or ($call eq_str (op, "sub"), $call eq_str (op, "mul")))

$decl apply $func ($decl op "", $decl a 0, $decl b 0)
  $if ($call eq_str (op, "add")) ($call add (a, b))
      ($if ($call eq_str (op, "sub")) ($call sub (a, b)) ($call mul (a, b)))

// ------------------------------------------------------------- the traversal

$fwd fold_expr

$decl fold_list $func ($decl xs IR.exprs.node, $decl acc IR.exprs.node) $match xs (
  $case {$prop tag "cons"}
    $call fold_list ($call IR.exprs.val (xs.tail),
        $call IR.exprs.cons ($call fold_expr (xs.head), acc)),
  $case xs ($call IR.exprs.reverse (acc, IR.exprs.nil))
)

$decl fold_slots $func ($decl xs IR.bslots.node, $decl acc IR.bslots.node) $match xs (
  $case {$prop tag "cons"}
    $call fold_slots ($call IR.bslots.val (xs.tail),
        $call IR.bslots.cons ($call IR.bslot (xs.head.slot, $call fold_expr (xs.head.init)), acc)),
  $case xs ($call IR.bslots.reverse (acc, IR.bslots.nil))
)

$decl fold_arms $func ($decl xs IR.arms.node, $decl acc IR.arms.node) $match xs (
  $case {$prop tag "cons"}
    $call fold_arms ($call IR.arms.val (xs.tail),
        $call IR.arms.cons ($call IR.arm ($call IR.ints.val (xs.head.discs), xs.head.slot,
            $call fold_expr (xs.head.body)), acc)),
  $case xs ($call IR.arms.reverse (acc, IR.arms.nil))
)

// A rebuilt call, folded if both operands came back constant. The fold happens
// *after* the operands are folded, so `add (add (1, 2), 3)` collapses in one
// pass rather than needing the pipeline to run this twice.
$decl fold_call $func ($decl t 0, $decl f IR.proto_expr, $decl xs IR.exprs.node,
                       $decl tl P.boolean)
  { $decl op  $call prim_name (f)
    $decl two $call eq_int ($call IR.exprs.length (xs, 0), 2)
    $decl hit $if two
        ($if ($call foldable (op))
             ($call P.and ($call is_int ($call IR.exprs.nth (xs, 0)),
                           $call is_int ($call IR.exprs.nth (xs, 1))))
             false)
        false
    $decl out $if hit
        ($call IR.eval ($call IR.e_int (t, $call apply (op,
            $call int_val ($call IR.exprs.nth (xs, 0)),
            $call int_val ($call IR.exprs.nth (xs, 1))))))
        ($call IR.eval ($call IR.e_call (t, f, xs, tl))) }.out

// Every node is rebuilt, so every node gets a fresh index (§9.3). `IR.eval` is
// what makes the arms join: each constructor gives its own block type, and
// passing through a parameter typed `proto_expr` is where they meet (§5.1).
$decl fold_expr $func ($decl e IR.proto_expr) $match e (
  $case {$prop tag "field"}
    ($call IR.eval ($call IR.e_field (e.ty, $call fold_expr (e.target), e.index))),
  $case {$prop tag "new"}   ($call IR.eval ($call IR.e_new (e.ty, $call fold_expr (e.init)))),
  $case {$prop tag "deref"} ($call IR.eval ($call IR.e_deref (e.ty, $call fold_expr (e.src)))),
  $case {$prop tag "copy"}  ($call IR.eval ($call IR.e_copy (e.ty, $call fold_expr (e.src)))),
  $case {$prop tag "set"}
    ($call IR.eval ($call IR.e_set (e.ty, $call fold_expr (e.target), $call fold_expr (e.value)))),
  $case {$prop tag "block"}
    ($call IR.eval ($call IR.e_block (e.ty, $call fold_slots ($call IR.bslots.val (e.slots), IR.bslots.nil)))),
  $case {$prop tag "group"}
    ($call IR.eval ($call IR.e_group (e.ty, $call fold_list ($call IR.exprs.val (e.items), IR.exprs.nil)))),
  $case {$prop tag "closure"}
    ($call IR.eval ($call IR.e_closure (e.ty, e.fn,
        $call fold_list ($call IR.exprs.val (e.captures), IR.exprs.nil)))),
  $case {$prop tag "call"}
    ($call fold_call (e.ty, $call fold_expr (e.callee),
        $call fold_list ($call IR.exprs.val (e.args), IR.exprs.nil), e.tail)),
  $case {$prop tag "if"}
    ($call IR.eval ($call IR.e_if (e.ty, $call fold_expr (e.cond),
        $call fold_expr (e.then), $call fold_expr (e.els)))),
  $case {$prop tag "switch"}
    ($call IR.eval ($call IR.e_switch (e.ty, $call fold_expr (e.scrut),
        $call fold_arms ($call IR.arms.val (e.arms), IR.arms.nil), $call fold_expr (e.default)))),
  $case {$prop tag "do"}
    ($call IR.eval ($call IR.e_do (e.ty, $call fold_expr (e.first), $call fold_expr (e.then)))),
  $case {$prop tag "try"}
    ($call IR.eval ($call IR.e_try (e.ty, $call fold_expr (e.value), e.disc))),
  // Every leaf: a literal, a slot, a global, a prim. Nothing to rebuild, so
  // the node keeps the index it had.
  $case e ($call IR.eval (e))
)

// ------------------------------------------------------------------ the pass

$decl fold_fn $func ($decl f IR.proto_fn)
  $call IR.fn (f.name, f.params, f.result, f.slots, $call fold_expr (f.body),
      f.self_tail, f.thunk, f.env)

$decl fold_fns $func ($decl xs IR.fns.node, $decl acc IR.fns.node) $match xs (
  $case {$prop tag "cons"}
    $call fold_fns ($call IR.fns.val (xs.tail), $call IR.fns.cons ($call fold_fn (xs.head), acc)),
  $case xs ($call IR.fns.reverse (acc, IR.fns.nil))
)

// §9.2: "a pipeline is ordinary composition". This is the whole interface.
$decl fold $func ($decl p IR.proto_program)
  $call IR.program (p.types, $call fold_fns ($call IR.fns.val (p.funcs), IR.fns.nil),
      p.groups, p.entry)
