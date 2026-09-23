// §9.1's `verify`: type-check a `program` and return diagnostics.
//
// This exists because of §9.2. A pass is ordinary user code from `program` to
// `program`, so it can be wrong, and the compiler has no way to tell a tree it
// built from one a pass handed back. `verify` is how a pipeline finds out —
// "mandatory after every pass while developing one, and usually not in a
// release build".
//
// What it checks is everything the tree asserts about *itself*:
//
//   * every index resolves — types into `program.types`, globals into
//     `program.funcs`, slots into the enclosing function's frame, captures
//     into its environment (§7.2: a frame is the sum of its slots, so a slot
//     number that names nothing is a frame the backend cannot declare);
//   * a `closure` carries exactly as many captures as its function has
//     environment entries, and a direct call passes exactly as many arguments
//     as the callee has parameters (§7.3: captures belong to the body);
//   * `tail` says what §7.7 means by tail position, and `self_tail` agrees
//     with the body — both directions, because a *missed* self tail call is
//     not a missed optimisation, it is TCE not happening;
//   * a parameter's type is the type of its frame slot (§7.2: "the parameters
//     take the first of them");
//   * node indices are distinct (§9.3). This is the one a real pass breaks: a
//     pass that duplicates a subtree — inlining, the §9.2 example — copies its
//     ids too, and every side table keyed on them then aliases.
//
// What it does not check: that each node's `ty` is the type the node's
// children *give* it. That is re-running inference over the tree, and it needs
// the subtyping judgement at every join; the local rules here are the ones that
// need no subtyping. A pass that rewrites a node's type to something unrelated
// is not caught yet.
//
// A diagnostic here has no line and column: the typed tree carries no spans —
// they were the AST's and lowering is where they stop. It names the function
// and the node's §9.3 index instead, which is what that index is for.

$decl P  $import "prelude"
$decl Pa $import "parser"
$decl T  $import "types"
$decl IR $import "ir"

$decl not P.not
$decl and P.and

// A `Bool` whose value is `false`: §4.8a makes `$union` evaluate to its first
// member, so this is `false` with room for `true` (§3.2 makes the two literals
// distinct types, so plain `false` would be storage only `false` fits).
$decl bfalse $union (false, true)
$decl bval $func ($decl b P.boolean) b

// ------------------------------------------------------------------- state

$decl vstate $func ()
  { $decl errs    $mut $alloc Pa.diags.node
    // Every node's index, in visit order; sorted at the end (§9.3 forbids
    // reading anything into the order they were handed out in, so they are
    // sorted rather than assumed).
    $decl ids     $mut $alloc IR.ints.node
    // Whether the function being walked tail-calls itself directly.
    $decl selfhit $mut $alloc bfalse }

$decl proto_vst $call vstate ()

$decl eval_diags $func ($decl x Pa.diags.node) x
$decl eval_ids   $func ($decl x IR.ints.node) x

// What the indices in the node being walked are allowed to name. `self` is the
// index of the function itself, so a call can be recognised as a self call;
// it is -1 while checking the program rather than a function.
$decl vcx $func ($decl a 0, $decl b 0, $decl c 0, $decl d 0, $decl e 0, $decl f "",
                 $decl g IR.fns.node)
  { $decl ntypes a  $decl nfuncs b  $decl nslots c  $decl nenv d  $decl self e  $decl fname f
    // The whole table, because a call has to be checked against the callee's
    // arity and a closure against its function's environment.
    $decl funcs g }

$decl proto_vcx $call vcx (0, 0, 0, 0, 0, "", IR.fns.nil)

$decl where_of $func ($decl cx proto_vcx, $decl id 0)
  $if ($call lt (id, 0)) cx.fname
      ($call concat (cx.fname, $call concat (" node ", $call int_to_str (id))))

$decl err $func ($decl st proto_vst, $decl cx proto_vcx, $decl id 0, $decl m "")
  { $decl noted $set st.errs ($call Pa.diags.cons (
        $call Pa.diag ($call concat ($call where_of (cx, id), $call concat (": ", m)), 0, 0, ""),
        $call eval_diags (st.errs)))
    $decl out 0 }.out

$decl need $func ($decl st proto_vst, $decl cx proto_vcx, $decl id 0,
                  $decl i 0, $decl n 0, $decl what "")
  $if ($call and ($call not ($call lt (i, 0)), $call lt (i, n))) 0
      ($call err (st, cx, id, $call concat (what, $call concat (" index ",
          $call concat ($call int_to_str (i), " names nothing")))))

// ------------------------------------------------------- sorting the indices
//
// Bottom-up mergesort over the list: `n log n` and tail-recursive throughout,
// where the obvious insert-and-scan is quadratic in the node count — which for
// a whole file is tens of thousands.

$decl ilists $specialize P.list IR.ints.node

// The merged prefix accumulates newest-first, so what is left of whichever
// list survives is pushed onto it in order (that is what `reverse` does) and
// the whole thing reversed once at the end.
$decl merge_rev $func ($decl a IR.ints.node, $decl b IR.ints.node, $decl acc IR.ints.node)
  $match a (
    $case {$prop tag "cons"} $match b (
      $case {$prop tag "cons"}
        $if ($call lt (b.head, a.head))
            ($call merge_rev (a, $call IR.ints.val (b.tail), $call IR.ints.cons (b.head, acc)))
            ($call merge_rev ($call IR.ints.val (a.tail), b, $call IR.ints.cons (a.head, acc))),
      $case b ($call IR.ints.reverse (a, acc))),
    $case a ($call IR.ints.reverse (b, acc))
  )

$decl merge $func ($decl a IR.ints.node, $decl b IR.ints.node)
  $call IR.ints.reverse ($call merge_rev (a, b, IR.ints.nil), IR.ints.nil)

// One bottom-up round: merge the runs pairwise. `pend` holds a run waiting for
// its partner, which is a pair of arguments rather than a look at `ls.tail` —
// matching on a boxed tail needs a block, and a block here would cost a frame
// per run (§7.7: a call inside a block is never in tail position).
$decl mpass $func ($decl ls ilists.node, $decl pend IR.ints.node, $decl has P.boolean,
                   $decl acc ilists.node)
  $match ls (
    $case {$prop tag "cons"}
      $if has ($call mpass (ls.tail, IR.ints.nil, bfalse,
                   $call ilists.cons ($call merge (pend, ls.head), acc)))
              ($call mpass (ls.tail, ls.head, true, acc)),
    $case ls ($if has ($call ilists.cons (pend, acc)) acc)
  )

// The rounds themselves: `log n` of them, so the block a two-deep match needs
// costs `log n` frames rather than `n`.
$decl msort_loop $func ($decl ls ilists.node) $match ls (
  $case {$prop tag "cons"}
    { $decl t   $call ilists.val (ls.tail)
      $decl out $match t (
        $case {$prop tag "cons"}
          $call msort_loop ($call mpass (ls, IR.ints.nil, bfalse, ilists.nil)),
        $case t ls.head) }.out,
  $case ls IR.ints.nil
)

$decl singles $func ($decl xs IR.ints.node, $decl acc ilists.node) $match xs (
  $case {$prop tag "cons"}
    $call singles ($call IR.ints.val (xs.tail),
        $call ilists.cons ($call IR.ints.cons (xs.head, IR.ints.nil), acc)),
  $case xs acc
)

$decl msort $func ($decl xs IR.ints.node) $call msort_loop ($call singles (xs, ilists.nil))

// The first repeated index in a sorted list, or -1. Indices start at 0, so -1
// is not one of them.
$decl first_dup $func ($decl xs IR.ints.node, $decl prev 0, $decl have P.boolean) $match xs (
  $case {$prop tag "cons"}
    $if ($call and (have, $call eq_int (prev, xs.head))) xs.head
        ($call first_dup ($call IR.ints.val (xs.tail), xs.head, true)),
  $case xs -1
)

// ------------------------------------------------------------- the node walk

$fwd vexpr

// `ty` then `id` are the first two fields of every node, so one function reads
// any of them (§5.1, and the upcast is free — §7.4).
$decl note $func ($decl st proto_vst, $decl cx proto_vcx, $decl n IR.any_node)
  $do ($set st.ids ($call IR.ints.cons (n.id, st.ids)))
      ($call need (st, cx, n.id, n.ty, cx.ntypes, "type"))

$decl vlist $func ($decl st proto_vst, $decl cx proto_vcx, $decl xs IR.exprs.node) $match xs (
  $case {$prop tag "cons"}
    $do ($call vexpr (st, cx, xs.head, bfalse))
        ($call vlist (st, cx, $call IR.exprs.val (xs.tail))),
  $case xs 0
)

$decl vslots $func ($decl st proto_vst, $decl cx proto_vcx, $decl xs IR.bslots.node) $match xs (
  $case {$prop tag "cons"}
    $do ($do ($call need (st, cx, xs.head.init.id, xs.head.slot, cx.nslots, "slot"))
             ($call vexpr (st, cx, xs.head.init, bfalse)))
        ($call vslots (st, cx, $call IR.bslots.val (xs.tail))),
  $case xs 0
)

// An arm's body is in tail position exactly when the `$match` is (§7.7), which
// is what makes a `$match` in tail position able to end in a tail call at all.
// An arm's slot is -1 when there is nothing to bind: §4.7 narrows to the member
// the discriminator selected, and an arm answering for *several* members
// narrows to their union, which is what the scrutinee already had. The backend
// reads -1 the same way and loads nothing, so it is a value here and not an
// index.
$decl varms $func ($decl st proto_vst, $decl cx proto_vcx, $decl xs IR.arms.node,
                   $decl tl P.boolean) $match xs (
  $case {$prop tag "cons"}
    $do ($do ($if ($call eq_int (xs.head.slot, -1)) 0
                  ($call need (st, cx, xs.head.body.id, xs.head.slot, cx.nslots, "arm slot")))
             ($call vexpr (st, cx, xs.head.body, tl)))
        ($call varms (st, cx, $call IR.arms.val (xs.tail), tl)),
  $case xs 0
)

// A call's callee, when it is a direct one. `-1` means "not a global", which
// covers a prim, a closure value and anything else §6a cannot turn into a loop.
$decl callee_fn $func ($decl e IR.proto_expr) $match e (
  $case {$prop tag "global"} e.fn,
  $case e -1
)

$decl arity_of $func ($decl cx proto_vcx, $decl i 0)
  $call IR.ints.length ($call IR.ints.val (($call IR.fns.nth ($call IR.fns.val (cx.funcs), i)).params), 0)

$decl env_of $func ($decl cx proto_vcx, $decl i 0)
  $call IR.ints.length ($call IR.ints.val (($call IR.fns.nth ($call IR.fns.val (cx.funcs), i)).env), 0)

$decl in_funcs $func ($decl cx proto_vcx, $decl i 0)
  $call and ($call not ($call lt (i, 0)), $call lt (i, cx.nfuncs))

// A top-level `$decl` that is not a `$func` is a thunk: its index names a
// static holding a value (§4.10), so a call *to* it is an indirect call
// through the function that static holds, and its own `params` — none —
// describe the thunk rather than the call. There is nothing to check the
// argument count against here.
$decl is_thunk $func ($decl cx proto_vcx, $decl i 0)
  ($call IR.fns.nth ($call IR.fns.val (cx.funcs), i)).thunk

$decl vcount $func ($decl st proto_vst, $decl cx proto_vcx, $decl id 0,
                    $decl got 0, $decl want 0, $decl what "")
  $if ($call eq_int (got, want)) 0
      ($call err (st, cx, id, $call concat (what,
          $call concat (": ", $call concat ($call int_to_str (got),
          $call concat (" where the function takes ", $call int_to_str (want)))))))

// A direct call: arity against the callee, and whether it is the self tail call
// §6a's cheap case turns into a loop.
$decl mark_self $func ($decl st proto_vst)
  { $decl m   $set st.selfhit true
    $decl out 0 }.out

$decl vcallee $func ($decl st proto_vst, $decl cx proto_vcx, $decl id 0, $decl fn 0,
                     $decl nargs 0, $decl marked P.boolean)
  $if ($call in_funcs (cx, fn))
      ($if ($call is_thunk (cx, fn)) 0
          ($do ($call vcount (st, cx, id, nargs, $call arity_of (cx, fn), "arguments"))
               ($if ($call and (marked, $call eq_int (fn, cx.self))) ($call mark_self (st)) 0)))
      0

// §7.7 decides where a tail call may be, §6a decides what to do with one. A
// mark in the wrong place is the failure a pass produces: a call the backend
// turns into `continue` from somewhere whose value is still needed.
$decl vtail $func ($decl st proto_vst, $decl cx proto_vcx, $decl id 0,
                   $decl marked P.boolean, $decl tl P.boolean)
  $if marked
      ($if tl 0 ($call err (st, cx, id,
          "marked as a tail call, but its value is used where it stands (§7.7)")))
      ($if tl ($call err (st, cx, id,
          "in tail position and not marked; §7.7 makes tail-call elimination mandatory")) 0)

$decl vexpr $func ($decl st proto_vst, $decl cx proto_vcx, $decl e IR.proto_expr,
                   $decl tl P.boolean)
  $do ($call note (st, cx, e)) ($match e (
    $case {$prop tag "local"}   ($call need (st, cx, e.id, e.slot, cx.nslots, "slot")),
    $case {$prop tag "capture"} ($call need (st, cx, e.id, e.slot, cx.nenv, "capture")),
    $case {$prop tag "global"}  ($call need (st, cx, e.id, e.fn, cx.nfuncs, "function")),

    // §7.3: the captures are the environment the body will read, so there are
    // exactly as many of them as the lifted function has entries.
    $case {$prop tag "closure"}
      $do ($do ($call need (st, cx, e.id, e.fn, cx.nfuncs, "function"))
               ($if ($call in_funcs (cx, e.fn))
                    ($call vcount (st, cx, e.id,
                        $call IR.exprs.length ($call IR.exprs.val (e.captures), 0),
                        $call env_of (cx, e.fn), "captures")) 0))
          ($call vlist (st, cx, $call IR.exprs.val (e.captures))),

    $case {$prop tag "field"} ($call vexpr (st, cx, e.target, bfalse)),
    $case {$prop tag "new"}   ($call vexpr (st, cx, e.init, bfalse)),
    $case {$prop tag "deref"} ($call vexpr (st, cx, e.src, bfalse)),
    $case {$prop tag "copy"}  ($call vexpr (st, cx, e.src, bfalse)),
    $case {$prop tag "set"}
      $do ($call vexpr (st, cx, e.target, bfalse)) ($call vexpr (st, cx, e.value, bfalse)),

    $case {$prop tag "block"} ($call vslots (st, cx, $call IR.bslots.val (e.slots))),
    $case {$prop tag "group"} ($call vlist (st, cx, $call IR.exprs.val (e.items))),

    $case {$prop tag "call"}
      $do ($do ($call vexpr (st, cx, e.callee, bfalse))
               ($call vlist (st, cx, $call IR.exprs.val (e.args))))
          ($do ($call vtail (st, cx, e.id, e.tail, tl))
               ($call vcallee (st, cx, e.id, $call callee_fn (e.callee),
                    $call IR.exprs.length ($call IR.exprs.val (e.args), 0), e.tail))),

    // The condition is evaluated where the `$if` stands; the arms are where it
    // stands, which is why both of them inherit `tl` (§7.7).
    $case {$prop tag "if"}
      $do ($call vexpr (st, cx, e.cond, bfalse))
          ($do ($call vexpr (st, cx, e.then, tl)) ($call vexpr (st, cx, e.els, tl))),

    $case {$prop tag "switch"}
      $do ($call vexpr (st, cx, e.scrut, bfalse))
          ($do ($call varms (st, cx, $call IR.arms.val (e.arms), tl))
               ($call vexpr (st, cx, e.default, tl))),

    // §4.8b: the whole point of `$do` is that its second operand keeps the
    // position the `$do` had, where a block would not.
    $case {$prop tag "do"}
      $do ($call vexpr (st, cx, e.first, bfalse)) ($call vexpr (st, cx, e.then, tl)),

    // §4.15 returns from the enclosing function when the value matches, so its
    // operand is evaluated where the `$try` stands and is not a tail call.
    $case {$prop tag "try"} ($call vexpr (st, cx, e.value, bfalse)),

    $case e 0
  ))

// ---------------------------------------------------------------- functions

$decl vints $func ($decl st proto_vst, $decl cx proto_vcx, $decl xs IR.ints.node,
                   $decl what "") $match xs (
  $case {$prop tag "cons"}
    $do ($call need (st, cx, -1, xs.head, cx.ntypes, what))
        ($call vints (st, cx, $call IR.ints.val (xs.tail), what)),
  $case xs 0
)

// §7.2: "The parameters take the first of them" — so a parameter's type is the
// type of the slot it arrives in, and a backend that declares the frame from
// `slots` and the signature from `params` gets one answer.
$decl vprefix $func ($decl st proto_vst, $decl cx proto_vcx, $decl ps IR.ints.node,
                     $decl ss IR.ints.node)
  $match ps (
    $case {$prop tag "cons"} $match ss (
      $case {$prop tag "cons"}
        $if ($call eq_int (ps.head, ss.head))
            ($call vprefix (st, cx, $call IR.ints.val (ps.tail), $call IR.ints.val (ss.tail)))
            ($call err (st, cx, -1, "a parameter's type is not its frame slot's (§7.2)")),
      $case ss ($call err (st, cx, -1, "there are more parameters than frame slots"))),
    $case ps 0
  )

// Both directions. A `self_tail` set on a function that does not tail-call
// itself makes §6a emit a loop nothing ever re-enters; one left unset on a
// function that does makes the backend emit a real call, and §7.7 says a loop
// written as recursion runs in constant space.
$decl vself $func ($decl st proto_vst, $decl cx proto_vcx, $decl flag P.boolean)
  { $decl hit $call bval (st.selfhit)
    $decl out $if hit
        ($if flag 0 ($call err (st, cx, -1,
            "a direct self tail call is not marked self_tail (§7.7, §6a)")))
        ($if flag ($call err (st, cx, -1,
            "self_tail is set, but no call in the body is a direct self tail call")) 0) }.out

$decl vfn $func ($decl st proto_vst, $decl cx0 proto_vcx, $decl f IR.proto_fn, $decl idx 0)
  { $decl slots $call IR.ints.val (f.slots)
    $decl envs  $call IR.ints.val (f.env)
    $decl cx $call vcx (cx0.ntypes, cx0.nfuncs,
                 $call IR.ints.length (slots, 0), $call IR.ints.length (envs, 0),
                 idx, f.name, $call IR.fns.val (cx0.funcs))
    $decl a $call vints (st, cx, slots, "slot type")
    $decl b $call vints (st, cx, envs, "capture type")
    $decl c $call need (st, cx, -1, f.result, cx.ntypes, "result type")
    $decl d $call vprefix (st, cx, $call IR.ints.val (f.params), slots)
    $decl e $set st.selfhit bfalse
    $decl g $call vexpr (st, cx, f.body, true)
    $decl h $call vself (st, cx, f.self_tail)
    $decl out 0 }.out

$decl vfns $func ($decl st proto_vst, $decl cx proto_vcx, $decl xs IR.fns.node, $decl i 0)
  $match xs (
    $case {$prop tag "cons"}
      $do ($call vfn (st, cx, xs.head, i))
          ($call vfns (st, cx, $call IR.fns.val (xs.tail), $call add (i, 1))),
    $case xs 0
  )

// ------------------------------------------------------------------ program

$decl vmembers $func ($decl st proto_vst, $decl cx proto_vcx, $decl xs IR.ints.node)
  $match xs (
    $case {$prop tag "cons"}
      $do ($call need (st, cx, -1, xs.head, cx.nfuncs, "group member"))
          ($call vmembers (st, cx, $call IR.ints.val (xs.tail))),
    $case xs 0
  )

$decl vgroups $func ($decl st proto_vst, $decl cx proto_vcx, $decl xs IR.groups.node)
  $match xs (
    $case {$prop tag "cons"}
      $do ($call vmembers (st, cx, $call IR.ints.val (xs.head.members)))
          ($call vgroups (st, cx, $call IR.groups.val (xs.tail))),
    $case xs 0
  )

// §9.3's rule, and the one a pass actually breaks: inlining a call copies the
// callee's subtree, ids and all, and every side table keyed on them then
// aliases two different nodes.
$decl vids $func ($decl st proto_vst, $decl cx proto_vcx)
  { $decl d $call first_dup ($call msort (st.ids), -1, bfalse)
    $decl out $if ($call lt (d, 0)) 0
        ($call err (st, cx, d,
            "two nodes share this index; §9.3 makes a node's index distinct in a program")) }.out

$decl verify $func ($decl p IR.proto_program)
  { $decl st $call vstate ()
    $decl fs $call IR.fns.val (p.funcs)
    $decl cx $call vcx ($call T.tys.length ($call T.tys.val (p.types), 0),
                 $call IR.fns.length (fs, 0), 0, 0, -1, "program", fs)
    // A program with no functions has no entry — which is what `check` returns
    // when it could not build one, and not something to report twice.
    $decl a $if ($call eq_int (cx.nfuncs, 0)) 0
                ($call need (st, cx, -1, p.entry, cx.nfuncs, "entry"))
    $decl b $call vgroups (st, cx, $call IR.groups.val (p.groups))
    $decl c $call vfns (st, cx, fs, 0)
    $decl d $call vids (st, cx)
    $decl out $call Pa.diags.reverse (st.errs, Pa.diags.nil) }.out
