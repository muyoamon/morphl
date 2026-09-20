// Tests for stage 1's typed tree:
//
//   morphlc --run stage1/ir_test.mpl
//
// The point is not the printer. It is that the shapes the backend will consume
// can actually be built, and that the three things the AST does not carry —
// resolved slots, explicit dereferences, marked tail calls — have somewhere to
// go. Each case is a §12 example lowered by hand, which is also the shape the
// lowering pass has to produce.

$decl IR $import "ir"
$decl T  $import "types"
$decl P  $import "prelude"

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

// Type ids, as the interning table would hand them out.
$decl t_int 0
$decl t_ref 1
$decl t_bool 2

// §12, "Counter and aliasing":
//
//   $decl n $mut $new 0
//   $set n ($call add (n, 1))
//
// `n` is slot 0. The `n` inside `add` is §5.4's implicit read of storage, which
// the source cannot write and the tree must: it is a `deref`.
$decl counter $call IR.e_set (t_int,
  $call IR.e_local (t_ref, 0),
  $call IR.e_call (t_int, $call IR.e_prim (t_int, "add"),
      $call IR.exprs.cons ($call IR.e_deref (t_int, $call IR.e_local (t_ref, 0)),
          $call IR.exprs.cons ($call IR.e_int (t_int, 1), IR.exprs.nil)),
      false))

$decl t1 $call check_str ("a counter lowers to a set through storage",
  $call IR.show (counter),
  "(set (local 0) (call (prim add) (deref (local 0)) (int 1)))")

// §12, "A loop". The recursive call is in tail position (§7.7), which §6a turns
// into `while (1)` with the parameters updated in parallel — so the tree has to
// say so, and `show` renders it differently for exactly that reason.
$decl loop_body $call IR.e_if (t_int,
  $call IR.e_call (t_bool, $call IR.e_prim (t_bool, "eq"),
      $call IR.exprs.cons ($call IR.e_local (t_int, 0),
          $call IR.exprs.cons ($call IR.e_int (t_int, 0), IR.exprs.nil)), false),
  $call IR.e_int (t_int, 0),
  $call IR.e_call (t_int, $call IR.e_global (t_int, 7),
      $call IR.exprs.cons ($call IR.e_call (t_int, $call IR.e_prim (t_int, "sub"),
          $call IR.exprs.cons ($call IR.e_local (t_int, 0),
              $call IR.exprs.cons ($call IR.e_int (t_int, 1), IR.exprs.nil)), false),
          IR.exprs.nil),
      true))

$decl t2 $call check ("a tail call is marked as one",
  $call eq_str ($call IR.show (loop_body),
    "(if (call (prim eq) (local 0) (int 0)) (int 0) (tailcall (global 7) (call (prim sub) (local 0) (int 1))))"))

// `slots` is the type of each frame slot (§7.2), and `thunk` distinguishes a
// top-level value from a zero-argument `$func` (§4.10).
$decl loop_fn $call IR.fn ("loop", $call IR.ints.cons (t_int, IR.ints.nil), t_int,
    $call IR.ints.cons (t_int, IR.ints.nil), loop_body, true, false)

$decl t3 $call check ("a self-tail-recursive function is flagged for §6a's loop",
  loop_fn.self_tail)

// §4.7 lowered: §7.5 gives a union value a discriminator, and §1.3 keeps a
// pattern to a tag block, so an arm is a discriminator test and nothing else.
$decl sw $call IR.e_switch (t_int,
  $call IR.e_local (t_int, 0),
  // An arm carries the *set* of discriminators it answers for (§4.7, first
  // fit), not one — several members can share a body.
  $call IR.arms.cons ($call IR.arm ($call IR.ints.cons (0, IR.ints.nil), 1,
      $call IR.e_int (t_int, 10)), IR.arms.nil),
  $call IR.e_int (t_int, 20))

$decl t4 $call check_str ("a match lowers to a discriminator switch",
  $call IR.show (sw), "(switch (local 0) [0 (int 10)] (int 20))")

// §7.3: a closure is a code pointer and an environment, and the captures are
// *expressions* evaluated where the `$func` literal stood — capture by copy.
$decl clo $call IR.e_closure (t_int, 3,
  $call IR.exprs.cons ($call IR.e_local (t_int, 2), IR.exprs.nil))

$decl t5 $call check_str ("a closure carries its captures, not its type",
  $call IR.show (clo), "(closure 3 (local 2))")

// Interning: the table is keyed by `T.same`, which is exact because de Bruijn
// binders make alpha-equivalent types identical (§5.5).
$decl table $call T.tys.cons (T.t_int, $call T.tys.cons (T.t_str, T.tys.nil))

$decl t6 $call check ("interning finds a type already in the table",
  { $decl f $call IR.find_ty (table, T.t_str)
    $decl out $if f.hit ($call eq_int (f.id, 1)) false }.out)

$decl t7 $call check ("...and reports a miss with the next free index",
  { $decl f $call IR.find_ty (table, T.t_float)
    $decl out $if f.hit false ($call eq_int (f.id, 2)) }.out)

// A recursive type interns as one entry however it was built, which is what
// makes an index a C struct name.
$decl list_a $call T.close_var ($call T.union2 (T.t_unit,
  $call T.t_block ($call T.f1 ("next", $call T.t_ref ("", $call T.t_var (5))), T.props.nil)), 5)
$decl list_b $call T.close_var ($call T.union2 (T.t_unit,
  $call T.t_block ($call T.f1 ("next", $call T.t_ref ("", $call T.t_var (99))), T.props.nil)), 99)

$decl t8 $call check ("two spellings of one recursive type intern to one entry",
  { $decl f $call IR.find_ty ($call T.tys.cons (list_a, T.tys.nil), list_b)
    $decl out $if f.hit ($call eq_int (f.id, 0)) false }.out)

$decl done $call nl ("all typed-tree tests passed")
