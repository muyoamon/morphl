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

// §4.7 lowered to a discriminator switch (§7.5): the last arm is the catch-all
// §4.7 requires, so it becomes the default rather than an arm.
$decl t5 $call check_str ("a match lowers to a switch with the catch-all as default",
  $call lower_src ("$func ($decl n 0) $match n ($case 1 10, $case n 20)", ii, prims),
  "(switch (local 0) [0 (int 10)] (int 20))")

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
                  $call L.prims_from ($call I.eval_env (I.root_env), L.benv.nil))
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

$decl done $call nl ("all lowering tests passed")
