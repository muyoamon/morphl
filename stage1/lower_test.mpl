// Tests for the lowering pass:
//
//   morphlc --run stage1/lower_test.mpl
//
// Each case parses a real `$func`, lowers it, and checks the tree — so these
// test the three things lowering decides that the source does not say: which
// slot a name is, where §5.4's implicit read of storage happened, and which
// calls are in tail position (§7.7).

$decl L  $import "lower"
$decl I  $import "infer"
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

// Parse one expression and hand back the `$func` form inside it.
$decl parse_one $func ($decl src "")
  { $decl r $call Pa.parse (src)
    $decl n $call Pa.nodes.nth ($call Pa.nodes.val (r.exprs), 0)
    $decl out n }.out

// An `Int -> Int` signature, which is the shape all of these have.
$decl ii $call T.t_func ($call T.tys.cons (T.t_int, T.tys.nil), T.t_int)

// §8's arithmetic, as ordinary names in the environment (§2.1).
$decl ii_i $call T.t_func ($call T.tys.cons (T.t_int, $call T.tys.cons (T.t_int, T.tys.nil)), T.t_int)
$decl ii_b $call T.t_func ($call T.tys.cons (T.t_int, $call T.tys.cons (T.t_int, T.tys.nil)), T.t_bool)

$decl prims $call L.with_prim ($call L.with_prim ($call L.with_prim (L.benv.nil,
    "add", ii_i), "sub", ii_i), "eq", ii_b)

$decl lower_src $func ($decl src "", $decl fty T.proto_ty, $decl env L.benv.node)
  { $decl st $call L.lstate ()
    $decl f  $call L.lower_func (st, env, "f", $call parse_one (src), fty)
    $decl out $call IR.show (f.body) }.out

// ---------------------------------------------------------------- the cases

// A parameter is slot 0, and the body is in tail position, so the call in it is
// a tail call — which is what §6a turns into a loop.
$decl t1 $call check_str ("a parameter is slot 0 and the body is a tail call",
  $call lower_src ("$func ($decl n 0) $call add (n, 1)", ii, prims),
  "(tailcall (prim add) (local 0) (int 1))")

// The same call *not* in tail position, because `$do`'s first operand is not.
$decl t2 $call check_str ("`$do`'s first operand is not in tail position",
  $call lower_src ("$func ($decl n 0) $do ($call add (n, 1)) n", ii, prims),
  "(do (call (prim add) (local 0) (int 1)) (local 0))")

// §12's counter. `n` is storage, so reading it inside `add` is §5.4's implicit
// dereference — which appears nowhere in the source and must appear here.
$decl ri $call T.t_ref ("mut", T.t_int)
$decl ref_env $call L.benv.cons ($call L.bind_ent ("n", "local", 0, ri), prims)

$decl t3 $call check_str ("reading storage becomes an explicit deref",
  { $decl st $call L.lstate ()
    $decl r  $call L.lval ($call L.lower (st, ref_env,
        $call parse_one ("$set n ($call add (n, 1))"), false))
    $decl out $call IR.show (r.ir) }.out,
  "(set (local 0) (call (prim add) (deref (local 0)) (int 1)))")

// §12's loop: both arms of an `$if` in tail position are themselves in tail
// position (§7.7), so the recursive call is a tail call and the base case is
// not a call at all.
$decl self_env $call L.benv.cons ($call L.bind_ent ("f", "global", 3, ii), prims)

$decl t4 $call check_str ("both arms of a tail `$if` stay in tail position",
  $call lower_src ("$func ($decl n 0) $if ($call eq (n, 0)) 0 ($call f ($call sub (n, 1)))",
      ii, self_env),
  "(if (call (prim eq) (local 0) (int 0)) (int 0) (tailcall (global 3) (call (prim sub) (local 0) (int 1))))")

// §4.7 lowered to a discriminator switch (§7.5). *Every* arm becomes a case,
// including the last: its narrowing has to be loaded like any other, and §5.6
// already checked exhaustiveness, so the C `default` is unreachable rather
// than the catch-all's home.
//
// The arm sets here are worth reading. A pattern is a type-only position
// (§5.7) and there is no syntax for writing a type — `1` denotes the type of
// the expression `1`, which is `Int`. §3.1 has no singleton integer types the
// way §3.2 gives `true` and `false` their own, so `$case 1` claims the whole
// scrutinee under §4.7's first fit and the arm after it claims nothing.
$decl t5 $call check_str ("every arm of a match becomes a case, the default unreachable",
  $call lower_src ("$func ($decl n 0) $match n ($case 1 10, $case n 20)", ii, prims),
  "(switch (local 0) [0 (int 10)] [ (int 20)] (unit))")

// Frame size is the slot counter left over (§7.2: a frame is the sum of its
// slots), which is what `emit` declares as C locals.
$decl t6 $call check ("the frame size is the slots the function used",
  { $decl st $call L.lstate ()
    $decl f  $call L.lower_func (st, prims, "f",
        $call parse_one ("$func ($decl a 0, $decl b 0) $call add (a, b)"),
        $call T.t_func ($call T.tys.cons (T.t_int, $call T.tys.cons (T.t_int, T.tys.nil)), T.t_int))
    // `slots` is now the *type* of each slot (§7.2), so its length is the
    // frame size the backend declares.
    $decl out $call eq_int ($call IR.ints.length ($call IR.ints.val (f.slots), 0), 2) }.out)

// Interning hands out one index per distinct type, and hands the same one back.
$decl t7 $call check ("interning is stable and by type identity",
  { $decl st $call L.lstate ()
    $decl a  $call L.intern (st, T.t_int)
    $decl b  $call L.intern (st, T.t_str)
    $decl c  $call L.intern (st, T.t_int)
    $decl out $if ($call eq_int (a, c)) ($call not ($call eq_int (a, b))) false }.out)

// §3.3: a block's value is its `$decl` slots, and a slot carries its number
// because a nested block inside an initializer takes slots of its own.
$decl t8 $call check_str ("a block lowers to its $decl slots, numbered",
  $call lower_src ("$func ($decl n 0) { $decl a n  $decl b 1 }", ii, prims),
  "(block [1 (local 0)] [2 (int 1)])")

// §4.10: a later `$decl` may name an earlier one, so the slots are read back.
$decl t9 $call check_str ("a later $decl reads an earlier slot",
  $call lower_src ("$func ($decl n 0) { $decl a n  $decl b ($call add (a, a)) }", ii, prims),
  "(block [1 (local 0)] [2 (call (prim add) (local 1) (local 1))])")

// §3.3: a non-`$decl` expression runs for effect and is discarded — folded
// into the next slot with `$do` so the order survives.
$decl t10 $call check_str ("an effect between decls keeps its place",
  $call lower_src ("$func ($decl n 0) { $call add (n, n)  $decl a 1 }", ii, prims),
  "(block [1 (do (call (prim add) (local 0) (local 0)) (int 1))])")

// §4.10: a `$prop` has no slot, so it changes the type and not the layout.
$decl t11 $call check_str ("a $prop takes no slot",
  $call lower_src ("$func ($decl n 0) { $prop tag \"cons\"  $decl a n }", ii, prims),
  "(block [1 (local 0)])")

// A whole file: each top-level `$decl` becomes a function, a `$func` literal
// as itself and anything else as a thunk, and a self-reference resolves to the
// index it was assigned.
$decl file_src $call concat ("$decl f $func ($decl n 0) $call f (n) ",
                             "$decl k 7 ")

$decl lowered $func ($decl src "")
  { $decl r  $call I.check_source (src, "", "")
    $decl a  $call Pa.parse (src)
    $decl st $call L.lstate ()
    $decl p  $call L.lower_file (st, $call Pa.nodes.val (a.exprs), r.ty,
                  $call L.prims_from ($call I.eval_env (I.root_env), L.benv.nil), "")
    $decl out p }.out

// Bound first: `$call lowered (file_src).funcs` projects off the *argument*.
$decl t12 $call check ("a file lowers to one function per top-level $decl",
  { $decl p $call lowered (file_src)
    $decl out $call eq_int ($call IR.fns.length (p.funcs, 0), 2) }.out)

$decl t13 $call check_str ("a self-reference resolves to its own global index",
  { $decl p  $call lowered (file_src)
    $decl f0 $call IR.fns.nth (p.funcs, 0)
    $decl out $call IR.show (f0.body) }.out,
  "(tailcall (global 0) (local 0))")

$decl t14 $call check ("a non-function top-level $decl becomes a thunk",
  { $decl p  $call lowered (file_src)
    $decl f1 $call IR.fns.nth (p.funcs, 1)
    $decl out $call eq_int ($call IR.ints.length (f1.params, 0), 0) }.out)

// ------------------------------------------------------ props (§4.10)
//
// A prop has no layout slot, so a projection onto one is never a field read.
// Where the answer comes from depends on what the prop's value is: a scalar is
// in the block's type, and anything else is code lowering has to still have.

$decl lower_errs $func ($decl src "")
  { $decl r  $call I.check_source (src, "", "")
    $decl a  $call Pa.parse (src)
    $decl st $call L.lstate ()
    $decl p  $call L.lower_file (st, $call Pa.nodes.val (a.exprs), r.ty,
                  $call L.prims_from ($call I.eval_env (I.root_env), L.benv.nil), "")
    $decl out $call Pa.diags.val ($call L.eval_diags (st.errs)) }.out

$decl lower_errs_at $func ($decl src "", $decl base "")
  { $decl r  $call I.check_source (src, base, "")
    $decl a  $call Pa.parse (src)
    $decl st $call L.lstate ()
    $decl p  $call L.lower_file (st, $call Pa.nodes.val (a.exprs), r.ty,
                  $call L.prims_from ($call I.eval_env (I.root_env), L.benv.nil), base)
    $decl out $call Pa.diags.val ($call L.eval_diags (st.errs)) }.out

$decl first_err $func ($decl ds Pa.diags.node) $match ds (
  $case {$prop tag "cons"} ds.head.msg,
  $case ds ""
)

$decl body_of $func ($decl src "", $decl i 0)
  { $decl p $call lowered (src)
    $decl f $call IR.fns.nth ($call IR.fns.val (p.funcs), i)
    $decl out $call IR.show ($call IR.eval (f.body)) }.out

// §4.10: "its value is part of the block's type" — so this one needs no source
// at all, and would work on a block from another file just as well.
$decl t15 $call check_str ("a scalar prop lowers to its value, straight from the type",
  $call body_of ("$decl m { $prop k 7 } $decl main $func () m.k ", 1),
  "(int 7)")

// A function-valued prop is `cv_opaque` in the type — an identity, not code —
// so this one is answered from the prop's source: lifted once, and named by
// the index it was lifted to.
$decl t16 $call check_str ("a function-valued prop lifts to a global",
  $call body_of ("$decl m { $prop f $func ($decl x 0) $call add (x, 1) } $decl main $func () $call m.f (2) ", 1),
  "(tailcall (global 2) (int 2))")

// §4.10 makes a prop visible throughout its block regardless of order, so a
// prop may name one written after it.
$decl t17 $call check_str ("a prop may name a sibling written after it",
  $call body_of ($call concat ("$decl m { $prop a $func ($decl x 0) $call b (x) ",
                     $call concat ("$prop b $func ($decl x 0) $call add (x, 1) } ",
                                   "$decl main $func () $call m.a (2) ")), 2),
  "(tailcall (global 3) (local 0))")

// A prop is compile-time and has no position, so there is nowhere to evaluate
// a capture — worth its own message, because the alternative is a silent read
// of the lifted function's own frame.
$decl t18 $call check_str ("a prop's value may not capture",
  $call first_err ($call lower_errs ($call concat (
      "$decl main $func ($decl n 0) ",
      "{ $decl m { $prop f $func ($decl x 0) $call add (x, n) } $decl r $call m.f (1) }.r "))),
  "a $prop's value may not capture 'n': a prop is compile-time (§4.10), so there is nowhere to evaluate the capture")

// The block came from a function's result, so lowering never saw its source
// and the type only kept an identity for the prop. Said plainly rather than
// answered wrongly.
$decl t19 $call check_str ("an unreachable prop value is reported, not guessed",
  $call first_err ($call lower_errs ($call concat (
      "$decl mk $func () { $prop f $func ($decl x 0) x } ",
      "$decl main $func () $call ($call mk ()).f (1) "))),
  "the value of prop 'f' is not reachable from here: it is not a scalar, and this block's source was not lowered in this file")

// -------------------------------------------------- templates (§4.9)
//
// §4.9's step 2 done by lowering: substitute, lower with ordinary rules, and
// have exactly what that produced. There is no `$template` node in the tree —
// the program is monomorphic by then, which is what makes a block type a C
// struct (§7.2).

$decl nfuncs $func ($decl src "")
  { $decl p $call lowered (src)
    $decl out $call IR.fns.length ($call IR.fns.val (p.funcs), 0) }.out

$decl box_src $call concat ("$decl box $template T { $prop wrap $func ($decl x T) { $decl v x } } ",
                            "$decl ibox $specialize box 0 ")

$decl t20 $call check_str ("a specialised template's prop lifts like any other",
  $call body_of ($call concat (box_src, "$decl main $func () $call ibox.wrap (7) "), 2),
  "(tailcall (global 3) (int 7))")

// §4.9: "Typing is memoized per argument type." Lowering memoises for a
// stronger reason — two uses at one type must *share* the lifted functions, or
// every mention would emit its own. Three specialisations at two argument
// types: the template, the three `$decl`s and `main` are five functions, and
// `wrap` adds one per *type*, not one per specialisation, so seven and not
// eight.
$decl memo_src $call concat (
  "$decl box $template T { $prop wrap $func ($decl x T) { $decl v x } } ",
  $call concat ("$decl a $specialize box 0  $decl b $specialize box 0  $decl c $specialize box \"\" ",
                // `($call f (x)).v`, not `$call f (x).v` — the latter projects
                // off the *argument* (§2.3).
                "$decl main $func () $call add (($call a.wrap (1)).v, $call add (($call b.wrap (2)).v, $call len (($call c.wrap (\"x\")).v))) "))

$decl t21 $call check ("two specialisations at one argument type share one set of functions",
  $call eq_int ($call nfuncs (memo_src), 7))

// §5.5, which lowering normally never has to apply: inference solves the knots
// and hands the answers over. Inside a specialisation there is no answer to
// read, because §4.9 made this body new — so the prop takes a placeholder, the
// body derives against it, and the binder is discharged at the end.
$decl list_src $call concat (
  "$decl list $template T { $prop nil { $prop tag \"nil\" } ",
  $call concat ("$prop node $union (nil, { $prop tag \"cons\"  $decl head T  $decl tail $new node }) ",
  $call concat ("$prop cons $func ($decl h T, $decl t node) { $prop tag \"cons\"  $decl head h  $decl tail $new t } ",
  $call concat ("$prop length $func ($decl xs node, $decl acc 0) $match xs ( ",
  $call concat ("$case {$prop tag \"cons\"} $call length (xs.tail, $call add (acc, 1)), $case xs acc ) } ",
                "$decl ints $specialize list 0 ")))))

// The `$match` walks the list, so `xs.tail` had to be projected through the
// `μ` — every structural question about a recursive type is a question about
// its unrolling, and `T.unroll` is where lowering asks it.
$decl t22 $call check_str ("a recursive prop derives its own μ and the list walks",
  $call body_of ($call concat (list_src,
      "$decl main $func () $call ints.length ($call ints.cons (7, ints.nil), 0) "), 2),
  "(tailcall (global 3) (call (global 4) (int 7) (block)) (int 0))")

// §5.5 again, from the other side: the recursion has to pass through storage
// or the type has no layout. Without the `$new` there is nothing to size.
$decl t23 $call check_str ("a recursive prop that does not go through storage is reported",
  $call first_err ($call lower_errs ($call concat (
      "$decl bad $template T { $prop node $union ({ $prop tag \"nil\" }, { $prop tag \"cons\"  $decl tail node }) } ",
      // A prop is lowered on demand, so the check fires where it is *named*.
      "$decl ints $specialize bad 0  $decl use $func () ints.node "))),
  "this recursive prop has no layout: it recurs through a value, not storage. Write $new at the recursive position (§5.5). Derived mu.<{tag=s\"nil\",},{tail:b0,tag=s\"cons\",}>")

$decl t24 $call check_str ("a $specialize of something that is not a template is reported",
  $call first_err ($call lower_errs ("$decl k 0  $decl m $specialize k 0 ")),
  "$specialize expects a template")

// ----------------------------------------------------- $import (§4.14)
//
// A module is a namespace the compiler resolves: a projection onto one names
// the global its member was lifted to, and the module has no layout at all.
// These lower a real file off disk, so they read `stage1/fixtures` the way a
// build would.

$decl lowered_at $func ($decl src "", $decl base "")
  { $decl r  $call I.check_source (src, base, "")
    $decl a  $call Pa.parse (src)
    $decl st $call L.lstate ()
    $decl p  $call L.lower_file (st, $call Pa.nodes.val (a.exprs), r.ty,
                  $call L.prims_from ($call I.eval_env (I.root_env), L.benv.nil), base)
    $decl out p }.out

$decl fx "stage1/fixtures"

$decl body_at $func ($decl src "", $decl i 0)
  { $decl p $call lowered_at (src, fx)
    $decl f $call IR.fns.nth ($call IR.fns.val (p.funcs), i)
    $decl out $call IR.show ($call IR.eval (f.body)) }.out

// A `$func` member becomes a global and the call is direct — no layout is read
// on the way, because the module has none.
$decl t25 $call check_str ("a projection onto a module names the global its member was lifted to",
  $call body_at ("$decl U $import \"import_util\"  $decl main $func () $call U.double (4) ", 1),
  "(tailcall (global 3) (int 4))")

// §4.10: a member that is not a `$func` is one cell, initialised once in
// source order — a thunk with a static, read as a global rather than recomputed.
$decl t26 $call check_str ("a non-$func member is a thunk, read as its static",
  $call body_at ("$decl U $import \"import_util\"  $decl main $func () U.bias ", 1),
  "(global 2)")

// §4.14: "Loaded once. All imports of the same resolved file yield the same
// module." Two imports, one copy of everything in it.
$decl t27 $call check ("importing one file twice loads it once",
  $call eq_int ($call IR.fns.length ($call IR.fns.val (
      ($call lowered_at ($call concat ("$decl U $import \"import_util\"  $decl V $import \"import_util\" ",
                                       "$decl main $func () $call V.double ($call U.double (1)) "), fx)).funcs), 0),
      7))

// Eager, in source order, and that is not an optimisation: §4.10 initialises a
// `$decl` once in source order, and the backend does that by assigning statics
// in index order — so `bias` has to be lifted before `biased`, which reads it.
$decl t28 $call check_str ("a member is lifted before the member that reads it",
  $call body_at ("$decl U $import \"import_util\"  $decl main $func () $call U.biased (1) ", 4),
  "(tailcall (prim add) (call (global 3) (local 0)) (global 2))")

$decl t29 $call check_str ("a file that does not exist is reported, not guessed",
  $call first_err ($call lower_errs_at ("$decl U $import \"no_such_module\"  $decl main $func () 0 ", fx)),
  "cannot read the file for $import \"no_such_module\" (stage1/fixtures/no_such_module.mpl)")

$decl done $call nl ("all lowering tests passed")
