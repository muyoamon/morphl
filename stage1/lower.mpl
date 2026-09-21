// AST → typed tree (BOOTSTRAP.md stage 1): the pass between `check` and `emit`.
//
// **Where the types come from.** Inference already solved every top-level name:
// §3.3 makes a file a block, so `check_file`'s result type *is* the environment
// — each `$decl`'s name and its final type. Lowering starts from that and
// derives the rest bottom-up, which is cheap because nothing is left to solve.
// A call's result is its callee's result, a projection's is the field's, `$new`
// gives `&T`, `$if` and `$match` join their arms. There is no unification here
// and no knot to tie; that work is done.
//
// This is why `infer.mpl` did not have to be rewritten to thread a tree through
// every branch. The cost is that the two passes must agree about those derived
// types — they are re-derived, not carried — so anything subtle enough that
// re-deriving it is wrong (templates, `$try`'s error set) is not lowered here.
// §11's coverage note at the bottom says what is and is not handled.
//
// **What lowering decides**, and the AST does not say (see `ir.mpl`):
//
//   * which slot a name is, counting parameters then `$decl`s in source order;
//   * where §5.4's implicit read of storage happened, as an explicit `deref`;
//   * which calls are in tail position (§7.7), for §6a;
//   * which type each node has, as an index into the program's interned table.

$decl P  $import "prelude"
$decl T  $import "types"
$decl Pa $import "parser"
$decl IR $import "ir"

$decl not P.not
$decl and P.and

$decl strs $specialize P.list ""

$decl mem_str $func ($decl xs strs.node, $decl x "") $match xs (
  $case {$prop tag "cons"} $if ($call eq_str (xs.head, x)) true ($call mem_str (xs.tail, x)),
  $case xs false
)

// ------------------------------------------------------------------ state
//
// The interned type table, the frame counter for the function being lowered,
// and the diagnostics. Storage is widened to what gets written into it (§4.2:
// `$new` takes the type of its operand, so `$new xs.nil` would be storage only
// the empty list fits).

$decl lstate $func ()
  { $decl types  $mut $new T.tys.node
    $decl ntypes $mut $new 0
    $decl nslots $mut $new 0
    // The type of each slot allocated so far, newest first (§7.2).
    $decl sltys  $mut $new IR.ints.node
    // Identities for opaque prop values; §4.10 makes two distinct
    // function-valued props distinct types, so they must not share one.
    $decl nopaque $mut $new 0
    // Functions lifted out of `$func` literals, newest first, and the index
    // the first of them will get. The top-level `$decl`s take the indices
    // below that, in source order, so that a global's index is its position.
    $decl lifted  $mut $new IR.fns.node
    $decl nlifted $mut $new 0
    $decl fnbase  $mut $new 0
    $decl errs   $mut $new Pa.diags.node }

$decl proto_lst $call lstate ()

$decl eval_tys   $func ($decl x T.tys.node) x
$decl eval_diags $func ($decl x Pa.diags.node) x

$decl err $func ($decl st proto_lst, $decl m "", $decl x P.proto_span)
  { $decl noted $set st.errs ($call Pa.diags.cons ($call Pa.diag (m, x.line, x.col, ""),
                                                   $call eval_diags (st.errs)))
    $decl out   0 }.out

// Append, so that an index into the table stays the index it was handed out as.
// The table holds one entry per *distinct* type and a compiler has few of them,
// so walking it is cheaper than the string key a hash would need.
$decl append_ty $func ($decl xs T.tys.node, $decl t T.proto_ty)
  $call T.tys.reverse ($call T.tys.cons (t, $call T.tys.reverse (xs, T.tys.nil)), T.tys.nil)

// Interning is exact because de Bruijn binders make alpha-equivalent types
// identical (§5.5), so `T.same` is the right key and one index names one C
// struct however the type was spelled.
$decl intern $func ($decl st proto_lst, $decl t T.proto_ty)
  { $decl cur $call T.tys.val ($call eval_tys (st.types))
    $decl f   $call IR.find_ty (cur, t)
    $decl out $if f.hit f.id
        { $decl added $set st.types ($call append_ty (cur, t))
          $decl n     $set st.ntypes ($call add ($call P.ival (st.ntypes), 1))
          $decl r     f.id }.r }.out

// ------------------------------------------------------------- environment
//
// A name resolves to a frame slot, a closure capture, a top-level function, or
// a root-block intrinsic (§2.1: an intrinsic is an ordinary shadowable name, so
// this is a lookup, not a special case).

$decl bind_ent $func ($decl n "", $decl k "", $decl s 0, $decl t T.proto_ty)
  { $decl name n  $decl kind k  $decl slot s  $decl ty t }

$decl proto_bind $call bind_ent ("", "", 0, T.t_bot)
$decl benv $specialize P.list proto_bind

$decl found $func ($decl ok P.boolean, $decl b proto_bind) { $decl hit ok  $decl bnd b }

$decl lookup $func ($decl e benv.node, $decl n "") $match e (
  $case {$prop tag "cons"}
    $if ($call eq_str (e.head.name, n)) ($call found (true, e.head)) ($call lookup (e.tail, n)),
  $case e ($call found (false, proto_bind))
)

// Seeding the top-level environment.
//
// §3.3 makes a file a block, so inference's result type *is* the list of
// top-level names with their solved types — `globals_from` turns it into an
// environment directly. The root block's intrinsics (§8) are added the same
// way, as ordinary names (§2.1), because that is what they are.

$decl with_prim $func ($decl e benv.node, $decl n "", $decl t T.proto_ty)
  $call benv.cons ($call bind_ent (n, "prim", 0, t), e)

$decl with_global $func ($decl e benv.node, $decl n "", $decl i 0, $decl t T.proto_ty)
  $call benv.cons ($call bind_ent (n, "global", i, t), e)

// The root block's names, as `prim` bindings. Inference builds that block
// already (§2: the bootstrap root block), so this reuses it rather than
// restating every intrinsic's type — one list, not two.
$decl prims_from $func ($decl xs T.fields.node, $decl acc benv.node) $match xs (
  $case {$prop tag "cons"}
    $call prims_from (xs.tail, $call with_prim (acc, xs.head.name, xs.head.ty)),
  $case xs acc
)

$decl globals_from $func ($decl fs T.fields.node, $decl i 0, $decl acc benv.node) $match fs (
  $case {$prop tag "cons"}
    $call globals_from (fs.tail, $call add (i, 1),
        $call with_global (acc, fs.head.name, i, fs.head.ty)),
  $case fs acc
)

// A fresh frame slot, of a known type — the type is what the backend needs to
// declare it (§7.2).
$decl fresh_slot $func ($decl st proto_lst, $decl ty 0)
  { $decl i $call P.ival (st.nslots)
    $decl n $set st.nslots ($call add (i, 1))
    $decl t $set st.sltys ($call IR.ints.cons (ty, $call IR.ints.val (st.sltys)))
    $decl r i }.r

// Put a saved slot space back, for lowering a nested `$func` literal.
$decl restore_slots $func ($decl st proto_lst, $decl xs IR.ints.node)
  { $decl c0 $set st.nslots ($call IR.ints.length (xs, 0))
    $decl c1 $set st.sltys ($call IR.ints.reverse (xs, IR.ints.nil))
    $decl r  () }.r

// The slot types in order, and the counters reset for the next function.
$decl take_slots $func ($decl st proto_lst)
  { $decl xs $call IR.ints.reverse ($call IR.ints.val (st.sltys), IR.ints.nil)
    $decl c0 $set st.nslots 0
    $decl c1 $set st.sltys IR.ints.nil
    $decl r  xs }.r

// Lift a function out of an expression and hand back the index it will have.
$decl add_lifted $func ($decl st proto_lst, $decl f IR.proto_fn)
  { $decl i $call P.ival (st.nlifted)
    $decl n $set st.nlifted ($call add (i, 1))
    $decl l $set st.lifted ($call IR.fns.cons (f, $call IR.fns.val (st.lifted)))
    $decl r $call add ($call P.ival (st.fnbase), i) }.r

$decl fresh_opaque $func ($decl st proto_lst)
  { $decl i $call P.ival (st.nopaque)
    $decl n $set st.nopaque ($call add (i, 1))
    $decl r i }.r

// ------------------------------------------------------------------ results
//
// Lowering returns the node *and* its type: the node carries an interned index,
// which is what `emit` wants, while the type itself is what the next step of
// the derivation wants.

$decl lres $func ($decl e IR.proto_expr, $decl t T.proto_ty) { $decl ir e  $decl ty t }
$decl proto_lres $call lres ({ $prop tag "unit" $decl ty 0  $decl id 0 }, T.t_bot)

// The identity at `proto_lres`. `lower` is completed through a `$fwd`, so above
// that completion its result is still §5.5's placeholder and projecting `.ir`
// off it fails; passing it through here states the type and defers the check to
// where the knot is tied.
$decl lval $func ($decl r proto_lres) r


$decl args_res $func ($decl xs IR.exprs.node, $decl ts T.tys.node) { $decl irs xs  $decl tys ts }
$decl arms_res $func ($decl xs IR.arms.node, $decl d IR.proto_expr, $decl t T.proto_ty)
  { $decl arms xs  $decl default d  $decl ty t }
$decl binding_done $func ($decl e benv.node, $decl ts IR.ints.node) { $decl env e  $decl tys ts }

// §4.6/§5.4 applied to a function type: what a call to this yields.
$decl result_of $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "func"} ($call T.tval (t.result)),
  $case t t
)

$decl deref_ty $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "ref"} ($call T.tval (t.inner)),
  $case t t
)

// §5.4: a reference behaves as its pointee wherever a value is expected, and
// there is no way to write that in source — so it is written here.
//
// The type is bound to a name before matching on it: §4.7 narrows a scrutinee
// *by its name*, so `$match r.ty` would leave `r.ty.inner` on the whole union.
$decl as_value $func ($decl st proto_lst, $decl r proto_lres)
  { $decl t   r.ty
    $decl out $match t (
        $case {$prop tag "ref"}
          { $decl inner $call T.tval (t.inner)
            $decl v $call lres ($call IR.e_deref ($call intern (st, inner), r.ir), inner) }.v,
        $case t r
      ) }.out

// A field's layout position and type (§7.2: `$decl` order is the layout).
$decl fld_found $func ($decl ok P.boolean, $decl i 0, $decl t T.proto_ty)
  { $decl hit ok  $decl idx i  $decl ty t }

$decl find_fld $func ($decl xs T.fields.node, $decl n "", $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, n)) ($call fld_found (true, i, xs.head.ty))
        ($call find_fld (xs.tail, n, $call add (i, 1))),
  $case xs ($call fld_found (false, 0, T.t_bot))
)

// ------------------------------------------------------------------ lowering

$decl proto_form  $call Pa.n_form ("", Pa.nodes.nil, 0, 0)
$decl proto_projn $call Pa.n_projn (Pa.proto_node, "", 0, 0)

$fwd lower
$fwd lower_block
// A `$func` literal is lowered by the same code as a top-level one, and needs
// its type back to build the closure — both sit below, in the same knot (§5.5).
$fwd lower_func
$fwd fn_ty

// Arguments are a value position (§5.4), so each is read through.
$decl lower_args $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node,
                        $decl acc IR.exprs.node, $decl tys T.tys.node) $match xs (
  $case {$prop tag "cons"}
    { $decl r $call as_value (st, $call lower (st, e, xs.head, false))
      $decl out $call lower_args (st, e, xs.tail,
          $call IR.exprs.cons (r.ir, acc), $call T.tys.cons (r.ty, tys)) }.out,
  $case xs ($call args_res ($call IR.exprs.reverse (acc, IR.exprs.nil),
                            $call T.tys.reverse (tys, T.tys.nil)))
)

$decl op $func ($decl n Pa.proto_node, $decl i 0) $match n (
  $case {$prop tag "form"} $call Pa.nodes.nth (n.operands, i),
  $case n ($call Pa.n_err ("not a form", 0, 0))
)

$decl group_items $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "unit"}  Pa.nodes.nil,
  $case {$prop tag "group"} ($call Pa.nodes.val (n.items)),
  $case n ($call Pa.nodes.cons (n, Pa.nodes.nil))
)

$decl is_form $func ($decl n Pa.proto_node, $decl k "") $match n (
  $case {$prop tag "form"} ($call eq_str (n.keyword, k)),
  $case n false
)

$decl name_of $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "name"} n.text,
  $case n ""
)

// A name: §2.1 makes intrinsics ordinary names, so the only question is which
// kind of binding it found.
$decl lower_name $func ($decl st proto_lst, $decl e benv.node, $decl n Pa.proto_node)
  { $decl nm $call name_of (n)
    $decl f  $call lookup (e, nm)
    $decl out $if ($call not (f.hit))
        ($call lres ($call IR.e_unit ($call err (st, $call concat ("unknown name '",
             $call concat (nm, "'")), n)), T.t_bot))
        { $decl bt $call T.tval (f.bnd.ty)
          $decl id $call intern (st, bt)
          $decl ir $if ($call eq_str (f.bnd.kind, "local"))   ($call IR.e_local (id, f.bnd.slot))
              ($if ($call eq_str (f.bnd.kind, "capture")) ($call IR.e_capture (id, f.bnd.slot))
              ($if ($call eq_str (f.bnd.kind, "global"))  ($call IR.e_global (id, f.bnd.slot))
                   ($call IR.e_prim (id, nm))))
          $decl r  $call lres (ir, bt) }.r }.out

// §4.6 as a layout position. The target is a value position, so a reference
// target is read through first.
$decl lower_proj $func ($decl st proto_lst, $decl e benv.node, $decl n proto_projn)
  { $decl tgt $call as_value (st, $call lower (st, e, n.target, false))
    $decl tt  tgt.ty
    $decl out $match tt (
        $case {$prop tag "block"}
          { $decl f $call find_fld ($call T.fields.val (tt.fields), n.field, 0)
            $decl r $if ($call not (f.hit))
                ($call lres ($call IR.e_unit ($call err (st, $call concat ("no field '",
                     $call concat (n.field, "'")), n)), T.t_bot))
                ($call lres ($call IR.e_field ($call intern (st, f.ty), tgt.ir, f.idx), f.ty)) }.r,
        $case tt ($call lres ($call IR.e_unit ($call err (st,
            "projection needs a block", n)), T.t_bot))
      ) }.out

// §1.1 limits a prop initializer to a literal, a prop-only block, or a
// `$func`/`$template` literal. The first three have a compile-time value; the
// rest are opaque, and two distinct function-valued props are distinct types,
// so each gets its own identity.
$decl const_of $func ($decl st proto_lst, $decl n Pa.proto_node) $match n (
  $case {$prop tag "int"}  ($call T.cv_int (n.value)),
  $case {$prop tag "str"}  ($call T.cv_str (n.text)),
  $case {$prop tag "bool"} ($call T.cv_bool (n.value)),
  $case {$prop tag "unit"} T.cv_unit,
  $case n ($call T.cv_opaque ($call fresh_opaque (st)))
)

$decl mem_int $func ($decl xs IR.ints.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} $if ($call eq_int (xs.head, i)) true ($call mem_int (xs.tail, i)),
  $case xs false
)

$decl append_ints $func ($decl xs IR.ints.node, $decl ys IR.ints.node) $match xs (
  $case {$prop tag "cons"} ($call append_ints ($call IR.ints.val (xs.tail),
                                $call IR.ints.cons (xs.head, ys))),
  $case xs ys
)

// A pattern is a type-only position (§5.7) — never evaluated, only its type
// used — and §1.3 keeps it to a prop-only block, a name, or a literal. So its
// type is read straight off the syntax, with no inference needed.
$decl pat_props $func ($decl st proto_lst, $decl xs Pa.nodes.node, $decl acc T.props.node) $match xs (
  $case {$prop tag "cons"}
    $call pat_props (st, $call Pa.nodes.val (xs.tail),
        $if ($call is_form (xs.head, "prop"))
            ($call T.props.cons ($call T.prop_entry ($call name_of ($call op (xs.head, 0)),
                 $call const_of (st, $call op (xs.head, 1))), acc))
            acc),
  $case xs acc
)

$decl pattern_ty $func ($decl st proto_lst, $decl e benv.node, $decl n Pa.proto_node) $match n (
  $case {$prop tag "int"}   T.t_int,
  $case {$prop tag "str"}   T.t_str,
  $case {$prop tag "float"} T.t_float,
  // §4.7 makes a literal pattern its base type, but §3.2 makes `true` and
  // `false` two distinct nullary tag *types* — so a boolean pattern selects
  // one of them, not both. Typing it as `Bool` made the first arm claim every
  // member and the second unreachable.
  $case {$prop tag "bool"}  ($if n.value T.t_true T.t_false),
  $case {$prop tag "unit"}  T.t_unit,
  $case {$prop tag "block"}
    ($call T.t_block (T.fields.nil, $call pat_props (st, $call Pa.nodes.val (n.items), T.props.nil))),
  // §4.7's catch-all names the scrutinee, so its type is whatever that is —
  // read through, because §5.4 makes a reference transparent in a `$match`
  // scrutinee and the pattern is compared against the *value*.
  $case {$prop tag "name"}
    { $decl f $call lookup (e, $call name_of (n))
      $decl r $if f.hit ($call deref_ty ($call T.tval (f.bnd.ty))) T.t_bot }.r,
  $case n T.t_bot
)

// Which member of a union a pattern selects. §1.3 keeps a pattern to a tag
// block, so this is the member the pattern is a supertype of — and §4.7 is
// first fit, so the first such member an earlier arm has not claimed.
$decl disc_of $func ($decl ms T.tys.node, $decl pat T.proto_ty, $decl i 0,
                     $decl taken IR.ints.node, $decl acc IR.ints.node) $match ms (
  $case {$prop tag "cons"}
    $call disc_of (ms.tail, pat, $call add (i, 1), taken,
        $if ($call mem_int (taken, i)) acc
            ($if ($call T.sub (ms.head, pat)) ($call IR.ints.cons (i, acc)) acc)),
  $case ms ($call IR.ints.reverse (acc, IR.ints.nil))
)

$decl members_of $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "union"} ($call T.tys.val (t.members)),
  $case t ($call T.tys.cons (t, T.tys.nil))
)

// §4.8a's type: every member joined. Lowering a member is how its type is
// read; the tree is thrown away, which costs the slots a discarded `$decl`
// would have taken and nothing else.
$fwd union_ty

$decl union_ty $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node,
                      $decl acc T.proto_ty) $match xs (
  $case {$prop tag "cons"}
    { $decl m $call lval ($call lower (st, e, xs.head, false))
      $decl r $call union_ty (st, e, $call Pa.nodes.val (xs.tail), $call T.join (acc, m.ty)) }.r,
  $case xs acc
)

// ------------------------------------------------------------------ closures
//
// §7.3: a closure captures its bindings *by copy*, and those captures belong to
// the body rather than the type — two functions of one type are interchangeable
// however they were built. So a `$func` literal lifts to an ordinary top-level
// function whose first business is its captured copies, and the expression it
// leaves behind is the pair.
//
// Every name the body mentions is looked up in the *enclosing* environment;
// the ones bound to a slot or an existing capture are what must travel. A name
// the body rebinds is looked up too and simply never read, which costs one
// copied word and no correctness.

$fwd free_names

$decl free_names_list $func ($decl xs Pa.nodes.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"}
    $call free_names_list ($call Pa.nodes.val (xs.tail), $call free_names (xs.head, acc)),
  $case xs acc
)

$decl free_names $func ($decl n Pa.proto_node, $decl acc strs.node) $match n (
  $case {$prop tag "name"}
    $if ($call mem_str (acc, n.text)) acc ($call strs.cons (n.text, acc)),
  $case {$prop tag "form"}  ($call free_names_list ($call Pa.nodes.val (n.operands), acc)),
  $case {$prop tag "group"} ($call free_names_list ($call Pa.nodes.val (n.items), acc)),
  $case {$prop tag "block"} ($call free_names_list ($call Pa.nodes.val (n.items), acc)),
  $case {$prop tag "proj_name"}  ($call free_names (n.target, acc)),
  $case {$prop tag "proj_index"} ($call free_names (n.target, acc)),
  $case n acc
)

$decl caps $func ($decl ns strs.node, $decl e benv.node, $decl acc benv.node) $match ns (
  $case {$prop tag "cons"}
    { $decl f $call lookup (e, ns.head)
      $decl keep $if f.hit
          ($if ($call eq_str (f.bnd.kind, "local")) true
               ($call eq_str (f.bnd.kind, "capture")))
          false
      $decl r $call caps ($call strs.val (ns.tail), e,
                  $if keep ($call benv.cons (f.bnd, acc)) acc) }.r,
  $case ns acc
)

// The captured values, as expressions in the *enclosing* frame — §7.3's copy
// happens where the literal stood.
$decl cap_exprs $func ($decl st proto_lst, $decl cs benv.node, $decl acc IR.exprs.node) $match cs (
  $case {$prop tag "cons"}
    { $decl id $call intern (st, $call T.tval (cs.head.ty))
      $decl ir $if ($call eq_str (cs.head.kind, "local"))
                   ($call IR.e_local (id, cs.head.slot))
                   ($call IR.e_capture (id, cs.head.slot))
      $decl r  $call cap_exprs (st, cs.tail, $call IR.exprs.cons (ir, acc)) }.r,
  $case cs ($call IR.exprs.reverse (acc, IR.exprs.nil))
)

$decl cap_tys $func ($decl st proto_lst, $decl cs benv.node, $decl acc IR.ints.node) $match cs (
  $case {$prop tag "cons"}
    $call cap_tys (st, cs.tail,
        $call IR.ints.cons ($call intern (st, $call T.tval (cs.head.ty)), acc)),
  $case cs ($call IR.ints.reverse (acc, IR.ints.nil))
)

// Inside the lifted body the same names are captures, numbered in order.
$decl cap_env $func ($decl cs benv.node, $decl i 0, $decl acc benv.node) $match cs (
  $case {$prop tag "cons"}
    $call cap_env (cs.tail, $call add (i, 1),
        $call benv.cons ($call bind_ent (cs.head.name, "capture", i,
            $call T.tval (cs.head.ty)), acc)),
  $case cs acc
)

// §4.7 lowered to a discriminator switch (§7.5). Arms keep source order, which
// §5.6 already checked for exhaustiveness and reachability, so the last arm is
// the catch-all every `$match` must end in and becomes the default.
// §4.7: "Inside an arm, `e` (by its name) is narrowed to `type(e) & P`." The
// narrowed value needs somewhere to live, so the arm gets a slot of the member
// type and the scrutinee's name is rebound to it for the body. `slot` is -1
// when there is nothing to narrow — an unnamed scrutinee, or an arm answering
// for more than one member.
$decl narrowed $func ($decl e benv.node, $decl s 0) { $decl env e  $decl slot s }

$decl narrow_arm $func ($decl st proto_lst, $decl e benv.node, $decl nm "",
                        $decl ms T.tys.node, $decl ds IR.ints.node)
  $if ($call eq_str (nm, "")) ($call narrowed (e, -1))
  ($match ds (
      $case {$prop tag "cons"}
        { $decl rest $call IR.ints.val (ds.tail)
          $decl out $match rest (
              // More than one member: the narrowed type is their union, which
              // is what the scrutinee already has, so there is nothing to bind.
              $case {$prop tag "cons"} ($call narrowed (e, -1)),
              $case rest
                { $decl mt $call T.tys.nth (ms, ds.head)
                  $decl sl $call fresh_slot (st, $call intern (st, mt))
                  $decl r  $call narrowed (
                      $call benv.cons ($call bind_ent (nm, "local", sl, mt), e), sl) }.r
            ) }.out,
      $case ds ($call narrowed (e, -1))
    ))

$decl lower_arms $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node,
                        $decl tail P.boolean, $decl ms T.tys.node, $decl nm "",
                        $decl taken IR.ints.node, $decl acc IR.arms.node,
                        $decl ty T.proto_ty) $match xs (
  $case {$prop tag "cons"}
    { $decl pty  $call pattern_ty (st, e, $call op (xs.head, 0))
      // §4.7 is first fit, so this arm answers for every member no earlier one
      // has claimed.
      $decl ds   $call disc_of (ms, pty, 0, taken, IR.ints.nil)
      $decl nw   $call narrow_arm (st, e, nm, ms, ds)
      $decl body $call lval ($call lower (st, nw.env, $call op (xs.head, 1), tail))
      $decl ty2  $call T.join (ty, body.ty)
      $decl rest $call Pa.nodes.val (xs.tail)
      // Every arm is a case, including the last: its narrowing has to be
      // loaded like any other, and §5.6 already checked that the arms are
      // exhaustive — so the C `default` is unreachable rather than the
      // catch-all's home.
      $decl acc2 $call IR.arms.cons ($call IR.arm (ds, nw.slot, body.ir), acc)
      $decl out  $match rest (
          $case {$prop tag "cons"}
            $call lower_arms (st, e, rest, tail, ms, nm, $call append_ints (ds, taken),
                acc2, ty2),
          $case rest ($call arms_res ($call IR.arms.reverse (acc2, IR.arms.nil),
                          $call IR.e_unit ($call intern (st, T.t_unit)), ty2))
        ) }.out,
  $case xs ($call arms_res ($call IR.arms.reverse (acc, IR.arms.nil), $call IR.e_unit (0), ty))
)

// §3.2: "`$if` is `$match` over them". A boolean carries no discriminator of
// its own — its value *is* the answer — so a `$match` on one lowers to an `$if`
// rather than to a switch, and the question of which member sits at which
// index never arises.
$decl arm_for $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node,
                     $decl want T.proto_ty) $match xs (
  $case {$prop tag "cons"}
    { $decl pty $call pattern_ty (st, e, $call op (xs.head, 0))
      $decl r $if ($call T.sub (want, pty)) ($call op (xs.head, 1))
                  ($call arm_for (st, e, $call Pa.nodes.val (xs.tail), want)) }.r,
  $case xs ($call Pa.n_err ("no arm covers this boolean", 0, 0))
)

$decl lower_bool_match $func ($decl st proto_lst, $decl e benv.node, $decl scrut proto_lres,
                              $decl items Pa.nodes.node, $decl tail P.boolean)
  { $decl t $call lval ($call lower (st, e, $call arm_for (st, e, items, T.t_true), tail))
    $decl f $call lval ($call lower (st, e, $call arm_for (st, e, items, T.t_false), tail))
    $decl ty $call T.join (t.ty, f.ty)
    $decl r  $call lres ($call IR.e_if ($call intern (st, ty), scrut.ir, t.ir, f.ir), ty) }.r

$decl lower_match $func ($decl st proto_lst, $decl e benv.node, $decl n proto_form,
                         $decl tail P.boolean)
  { $decl sn    $call op (n, 0)
    $decl scrut $call as_value (st, $call lower (st, e, sn, false))
    $decl items $call group_items ($call op (n, 1))
    $decl out $if ($call T.same (scrut.ty, T.t_bool))
        ($call lower_bool_match (st, e, scrut, items, tail))
        { $decl a $call lower_arms (st, e, items, tail, $call members_of (scrut.ty),
                      $call name_of (sn), IR.ints.nil, IR.arms.nil, T.t_bot)
          $decl r $call lres (
              $call IR.e_switch ($call intern (st, a.ty), scrut.ir, a.arms, a.default), a.ty) }.r }.out

$decl lower_form $func ($decl st proto_lst, $decl e benv.node, $decl n proto_form,
                        $decl tail P.boolean)
  { $decl k n.keyword
    $decl out
      // §4.2: the only way storage exists. The operand is a value (§5.4).
      $if ($call eq_str (k, "new"))
        { $decl v  $call as_value (st, $call lower (st, e, $call op (n, 0), false))
          $decl rt $call T.t_ref ("", v.ty)
          $decl r  $call lres ($call IR.e_new ($call intern (st, rt), v.ir), rt) }.r
      // §4.3: a view, not a value — no node, only a different type.
      ($if ($call eq_str (k, "mut"))
        { $decl v  $call lval ($call lower (st, e, $call op (n, 0), false))
          $decl rt $call T.t_ref ("mut", $call deref_ty (v.ty))
          $decl r  $call lres (v.ir, rt) }.r
      // §4.4: writes *through* storage; the type is the written value's.
      ($if ($call eq_str (k, "set"))
        { $decl dst $call lval ($call lower (st, e, $call op (n, 0), false))
          $decl v   $call as_value (st, $call lower (st, e, $call op (n, 1), false))
          $decl r   $call lres ($call IR.e_set ($call intern (st, v.ty), dst.ir, v.ir), v.ty) }.r
      // §4.8b, and the whole reason it exists: the second operand stays in tail
      // position, so a loop written with `$do` keeps §7.7.
      ($if ($call eq_str (k, "do"))
        { $decl a $call lval ($call lower (st, e, $call op (n, 0), false))
          $decl b $call lval ($call lower (st, e, $call op (n, 1), tail))
          $decl r $call lres ($call IR.e_do ($call intern (st, b.ty), a.ir, b.ir), b.ty) }.r
      ($if ($call eq_str (k, "if"))
        { $decl c  $call as_value (st, $call lower (st, e, $call op (n, 0), false))
          $decl a  $call lval ($call lower (st, e, $call op (n, 1), tail))
          $decl b  $call lval ($call lower (st, e, $call op (n, 2), tail))
          $decl ty $call T.join (a.ty, b.ty)
          $decl r  $call lres ($call IR.e_if ($call intern (st, ty), c.ir, a.ir, b.ir), ty) }.r
      ($if ($call eq_str (k, "match")) ($call lower_match (st, e, n, tail))
      // §4.8a: the expression *evaluates to its first member* and has the
      // type of all of them joined. The rest are type-only positions (§5.7) —
      // lowered here only to read their types off, and their trees discarded.
      //
      // The value is then coerced to that join, because what the members have
      // in common is a union and a member of one is not yet one (§7.4).
      ($if ($call eq_str (k, "union"))
        { $decl ms  $call group_items ($call op (n, 0))
          $decl fst $call lval ($call lower (st, e, $call Pa.nodes.nth (ms, 0), false))
          $decl ty  $call union_ty (st, e, $call Pa.nodes.val (ms), T.t_bot)
          $decl id  $call intern (st, ty)
          $decl ir  $if ($call T.same (ty, fst.ty)) fst.ir ($call IR.e_copy (id, fst.ir))
          $decl r   $call lres (ir, ty) }.r
      // §4.15, the only non-local exit and only a conditional one: if the
      // value matches the pattern it returns from the enclosing `$func`, and
      // otherwise this expression carries on with what is left of its type.
      // Inference already widened the function's result to include the
      // matched member, so the return has somewhere to go.
      ($if ($call eq_str (k, "try"))
        { $decl v   $call lval ($call lower (st, e, $call op (n, 0), false))
          $decl pty $call pattern_ty (st, e, $call op (n, 1))
          $decl ds  $call disc_of ($call members_of (v.ty), pty, 0, IR.ints.nil, IR.ints.nil)
          // `type(e) & ¬pat` — what the value is once the matching member has
          // been taken away.
          $decl rest $call T.minus (v.ty, pty)
          $decl out $match ds (
              $case {$prop tag "cons"}
                ($call lres ($call IR.e_try ($call intern (st, rest), v.ir, ds.head), rest)),
              $case ds
                ($call lres ($call IR.e_unit ($call err (st,
                    "$try's pattern matches nothing in the value's type", n)), T.t_unit))
            ) }.out
      // §7.3: a `$func` literal lifts to a top-level function and leaves the
      // pair behind. Its frame is its own, so the enclosing slot space is put
      // aside and restored.
      ($if ($call eq_str (k, "func"))
        { $decl fns  $call free_names (n, strs.nil)
          $decl cs   $call caps (fns, e, benv.nil)
          $decl vals $call cap_exprs (st, cs, IR.exprs.nil)
          $decl outer $call take_slots (st)
          $decl ets  $call cap_tys (st, cs, IR.ints.nil)
          $decl lf   $call lower_func (st, $call cap_env (cs, 0, e), "lambda", n, T.t_bot, ets)
          $decl back $call restore_slots (st, outer)
          $decl idx  $call add_lifted (st, lf)
          $decl fty  $call fn_ty (st, lf)
          $decl r    $call lres ($call IR.e_closure ($call intern (st, fty), idx, vals), fty) }.r
      ($if ($call eq_str (k, "call"))
        { $decl f  $call as_value (st, $call lower (st, e, $call op (n, 0), false))
          $decl as $call lower_args (st, e, $call group_items ($call op (n, 1)),
                                     IR.exprs.nil, T.tys.nil)
          $decl ty $call result_of (f.ty)
          $decl r  $call lres ($call IR.e_call ($call intern (st, ty), f.ir, as.irs, tail), ty) }.r
        ($call lres ($call IR.e_unit ($call err (st, $call concat ("$", $call concat (k,
             " is not lowered yet")), n)), T.t_unit)))))))))))  }.out

$decl lower $func ($decl st proto_lst, $decl e benv.node, $decl n Pa.proto_node,
                   $decl tail P.boolean) $match n (
  $case {$prop tag "int"}   ($call lres ($call IR.e_int ($call intern (st, T.t_int), n.value), T.t_int)),
  $case {$prop tag "str"}   ($call lres ($call IR.e_str ($call intern (st, T.t_str), n.text), T.t_str)),
  $case {$prop tag "float"} ($call lres ($call IR.e_float ($call intern (st, T.t_float), n.text), T.t_float)),
  $case {$prop tag "bool"}
    ($call lres ($call IR.e_bool ($call intern (st, T.t_bool), n.value),
                 $if n.value T.t_true T.t_false)),
  $case {$prop tag "unit"}  ($call lres ($call IR.e_unit ($call intern (st, T.t_unit)), T.t_unit)),
  $case {$prop tag "name"}  ($call lower_name (st, e, n)),
  $case {$prop tag "proj_name"} ($call lower_proj (st, e, n)),
  $case {$prop tag "block"} ($call lower_block (st, e, $call Pa.nodes.val (n.items))),
  $case {$prop tag "form"}  ($call lower_form (st, e, n, tail)),
  $case n ($call lres ($call IR.e_unit ($call err (st,
      "this expression is not lowered yet", n)), T.t_unit))
)

// ------------------------------------------------------------------ functions
//
// §7.2's frame: the parameters take the first slots, in order, then every
// `$decl` in the body. The counter left over is the frame size.

$decl bind_params $func ($decl st proto_lst, $decl e benv.node, $decl ps Pa.nodes.node,
                         $decl ts T.tys.node, $decl acc IR.ints.node) $match ps (
  $case {$prop tag "cons"}
    { $decl nm $call name_of ($call op (ps.head, 0))
      // §3.4: "each default fixes the parameter's type". Inference already
      // solved a top-level function's, and passes it in; a `$func` literal
      // lifted out of an expression has none, so its defaults are the source.
      $decl ty $match ts (
          $case {$prop tag "cons"} ts.head,
          $case ts { $decl d $call lval ($call lower (st, e, $call op (ps.head, 1), false))
                     $decl t d.ty }.t
        )
      $decl tid $call intern (st, ty)
      $decl sl $call fresh_slot (st, tid)
      $decl e2 $call benv.cons ($call bind_ent (nm, "local", sl, ty), e)
      $decl rt $match ts ($case {$prop tag "cons"} ($call T.tys.val (ts.tail)), $case ts T.tys.nil)
      $decl r  $call bind_params (st, e2, ps.tail, rt,
                   $call IR.ints.cons (tid, acc)) }.r,
  $case ps ($call binding_done (e, $call IR.ints.reverse (acc, IR.ints.nil)))
)

// Lower one `$func` whose type inference already solved. `fty` is that type, so
// the parameter types come from it rather than from re-reading the defaults.
$decl lower_func $func ($decl st proto_lst, $decl e benv.node, $decl nm "",
                        $decl n Pa.proto_node, $decl fty T.proto_ty, $decl ev IR.ints.node)
  { $decl reset $call take_slots (st)
    $decl ps    $call group_items ($call op (n, 0))
    $decl ptys  $match fty ($case {$prop tag "func"} ($call T.tys.val (fty.params)), $case fty T.tys.nil)
    $decl b     $call bind_params (st, e, ps, ptys, IR.ints.nil)
    // The body is in tail position: it *is* the function's result (§7.7).
    $decl body  $call lval ($call lower (st, b.env, $call op (n, 1), true))
    // §4.15 widens the *inferred* result to include what `$try` can return, so
    // the declared type is the one to believe — not the body's own, which does
    // not know about the non-local exits inside it.
    $decl rty0  $match fty ($case {$prop tag "func"} ($call T.tval (fty.result)), $case fty body.ty)
    $decl rty   $call intern (st, rty0)
    $decl out   $call IR.fn (nm, b.tys, rty, $call take_slots (st), body.ir, false, false, ev) }.out

// --------------------------------------------------------------------- blocks
//
// §3.3: a block's value is its `$decl` slots in layout order; `$prop` occupies
// no space but its *value* is part of the block's type (§4.10), which is the
// only place a value appears in a type; and a non-`$decl` expression runs for
// effect and is discarded.
//
// Effects are kept in order by folding each one into the next slot's
// initializer as a `$do` — which is exactly what `$do` is for (§4.8b) and costs
// no tail position, since a slot initializer is not in one anyway.

$decl blk_acc $func ($decl sl IR.bslots.node, $decl fl T.fields.node, $decl pr T.props.node,
                     $decl en benv.node, $decl pd IR.exprs.node)
  { $decl slots sl  $decl flds fl  $decl prps pr  $decl env en  $decl pend pd }

$decl proto_blk $call blk_acc (IR.bslots.nil, T.fields.nil, T.props.nil, benv.nil, IR.exprs.nil)

// Fold the effects that ran before this initializer into it, innermost first.
$decl with_pending $func ($decl pd IR.exprs.node, $decl e IR.proto_expr, $decl t 0) $match pd (
  $case {$prop tag "cons"}
    $call with_pending ($call IR.exprs.val (pd.tail), $call IR.e_do (t, pd.head, e), t),
  $case pd e
)

$fwd lower_items

$decl lower_item $func ($decl st proto_lst, $decl a proto_blk, $decl it Pa.proto_node)
  $if ($call is_form (it, "decl"))
      { $decl nm  $call name_of ($call op (it, 0))
        $decl v   $call lval ($call lower (st, a.env, $call op (it, 1), false))
        $decl id  $call intern (st, v.ty)
        $decl ir  $call with_pending (a.pend, v.ir, id)
        $decl sl  $call fresh_slot (st, id)
        $decl r   $call blk_acc (
            $call IR.bslots.cons ($call IR.bslot (sl, ir), $call IR.bslots.val (a.slots)),
            $call T.fields.cons ($call T.field (nm, v.ty), $call T.fields.val (a.flds)),
            $call T.props.val (a.prps),
            $call benv.cons ($call bind_ent (nm, "local", sl, v.ty), $call benv.val (a.env)),
            IR.exprs.nil) }.r
  ($if ($call is_form (it, "prop"))
      // Erased from the layout, kept in the type (§4.10).
      { $decl nm $call name_of ($call op (it, 0))
        $decl cv $call const_of (st, $call op (it, 1))
        $decl r  $call blk_acc ($call IR.bslots.val (a.slots), $call T.fields.val (a.flds),
            $call T.props.cons ($call T.prop_entry (nm, cv), $call T.props.val (a.prps)),
            $call benv.val (a.env), $call IR.exprs.val (a.pend)) }.r
  ($if ($call is_form (it, "fwd"))
      { $decl e $call err (st, "$fwd is not lowered yet", it)
        $decl r a }.r
      // Runs for effect, discarded (§3.3). Held until the next slot.
      { $decl v $call lval ($call lower (st, a.env, it, false))
        $decl r $call blk_acc ($call IR.bslots.val (a.slots), $call T.fields.val (a.flds),
            $call T.props.val (a.prps), $call benv.val (a.env),
            $call IR.exprs.cons (v.ir, $call IR.exprs.val (a.pend))) }.r))

$decl lower_items $func ($decl st proto_lst, $decl a proto_blk, $decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"}
    { $decl a2 $call lower_item (st, a, xs.head)
      $decl r  $call lower_items (st, a2, $call Pa.nodes.val (xs.tail)) }.r,
  $case xs a
)

$decl lower_block $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node)
  { $decl a  $call lower_items (st, $call blk_acc (IR.bslots.nil, T.fields.nil, T.props.nil,
                                                   e, IR.exprs.nil), xs)
    $decl ty $call T.t_block ($call T.fields.reverse ($call T.fields.val (a.flds), T.fields.nil),
                              $call T.props.val (a.prps))
    $decl id $call intern (st, ty)
    $decl ir $call with_pending ($call IR.exprs.val (a.pend),
        $call IR.e_block (id, $call IR.bslots.reverse ($call IR.bslots.val (a.slots), IR.bslots.nil)), id)
    $decl r  $call lres (ir, ty) }.r

// ----------------------------------------------------------------- the file
//
// §3.3: a file is a block, so its top level is a list of `$decl`s and its
// inferred type is those names with their solved types — which is where the
// global environment comes from, in the same order.
//
// Every top-level `$decl` becomes an `IR.fn`: a `$func` literal becomes itself,
// and anything else becomes a zero-argument thunk that computes it. That keeps
// one rule for the backend — a global is a function index — and leaves the
// order they must run in as the order they appear, which §4.10 already fixes.

// §6a's cheap case needs to know whether the function tail-calls *itself*,
// which is only answerable once its own global index is known — so it is
// decided here rather than in `lower_func`.
$fwd self_tails

$decl self_tails_list $func ($decl xs IR.exprs.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call self_tails (xs.head, i)) true ($call self_tails_list ($call IR.exprs.val (xs.tail), i)),
  $case xs false
)

$decl self_tails_arms $func ($decl xs IR.arms.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call self_tails (xs.head.body, i)) true ($call self_tails_arms (xs.tail, i)),
  $case xs false
)

$decl self_tails $func ($decl e IR.proto_expr, $decl i 0) $match e (
  $case {$prop tag "call"}
    { $decl c $call IR.eval (e.callee)
      $decl r $match c (
          $case {$prop tag "global"} ($if e.tail ($call eq_int (c.fn, i)) false),
          $case c false
        ) }.r,
  // Only tail position matters, so the arms of an `$if` and the second operand
  // of a `$do` — never the condition or the first operand (§7.7).
  $case {$prop tag "if"}
    $if ($call self_tails ($call IR.eval (e.then), i)) true
        ($call self_tails ($call IR.eval (e.els), i)),
  $case {$prop tag "do"} ($call self_tails ($call IR.eval (e.then), i)),
  $case {$prop tag "switch"}
    $if ($call self_tails_arms ($call IR.arms.val (e.arms), i)) true
        ($call self_tails ($call IR.eval (e.default), i)),
  $case e false
)

// ------------------------------------------------- mutually recursive groups
//
// §6a: a direct self tail call is a loop, but a *mutual* one is not — the group
// has to become one function with a state variable and one dispatch loop. The
// group is a strongly connected component of the tail-call graph, which §4.11's
// `$fwd` guarantees is knowable: the slots are completed in one block.

$decl edge $func ($decl a 0, $decl b 0) { $decl from a  $decl to b }
$decl proto_edge $call edge (0, 0)
$decl edges $specialize P.list proto_edge

$fwd tail_targets

$decl tail_targets_arms $func ($decl xs IR.arms.node, $decl acc IR.ints.node) $match xs (
  $case {$prop tag "cons"}
    $call tail_targets_arms (xs.tail, $call tail_targets (xs.head.body, acc)),
  $case xs acc
)

// Only tail position counts (§7.7): the arms of an `$if`, the second operand
// of a `$do`, the arms and default of a `$switch`.
$decl tail_targets $func ($decl e IR.proto_expr, $decl acc IR.ints.node) $match e (
  $case {$prop tag "call"}
    { $decl c $call IR.eval (e.callee)
      $decl r $match c (
          $case {$prop tag "global"}
            $if e.tail ($if ($call mem_int (acc, c.fn)) acc ($call IR.ints.cons (c.fn, acc))) acc,
          $case c acc
        ) }.r,
  $case {$prop tag "if"}
    $call tail_targets ($call IR.eval (e.els), $call tail_targets ($call IR.eval (e.then), acc)),
  $case {$prop tag "do"} ($call tail_targets ($call IR.eval (e.then), acc)),
  $case {$prop tag "switch"}
    $call tail_targets ($call IR.eval (e.default),
        $call tail_targets_arms ($call IR.arms.val (e.arms), acc)),
  $case e acc
)

$decl add_edges $func ($decl i 0, $decl ts IR.ints.node, $decl acc edges.node) $match ts (
  $case {$prop tag "cons"}
    $call add_edges (i, ts.tail, $call edges.cons ($call edge (i, ts.head), acc)),
  $case ts acc
)

$decl collect_edges $func ($decl fs IR.fns.node, $decl i 0, $decl acc edges.node) $match fs (
  $case {$prop tag "cons"}
    $call collect_edges ($call IR.fns.val (fs.tail), $call add (i, 1),
        $call add_edges (i, $call tail_targets (fs.head.body, IR.ints.nil), acc)),
  $case fs acc
)

$fwd reaches

// Depth first, with the visited set as the termination argument — the graph is
// finite and `seen` only grows.
$decl reaches_from $func ($decl es edges.node, $decl all edges.node, $decl a 0, $decl b 0,
                          $decl seen IR.ints.node) $match es (
  $case {$prop tag "cons"}
    $if ($call eq_int (es.head.from, a))
        ($if ($call eq_int (es.head.to, b)) true
             ($if ($call reaches (all, es.head.to, b, $call IR.ints.cons (a, seen))) true
                  ($call reaches_from (es.tail, all, a, b, seen))))
        ($call reaches_from (es.tail, all, a, b, seen)),
  $case es false
)

$decl reaches $func ($decl es edges.node, $decl a 0, $decl b 0, $decl seen IR.ints.node)
  $if ($call mem_int (seen, a)) false ($call reaches_from (es, es, a, b, seen))

// Everything mutually reachable with `i`, itself included.
$decl scc_of $func ($decl es edges.node, $decl i 0, $decl j 0, $decl n 0,
                    $decl acc IR.ints.node)
  $if ($call not ($call lt (j, n))) ($call IR.ints.reverse (acc, IR.ints.nil))
      ($call scc_of (es, i, $call add (j, 1), n,
          $if ($call eq_int (i, j)) ($call IR.ints.cons (j, acc))
              ($if ($call and ($call reaches (es, i, j, IR.ints.nil),
                               $call reaches (es, j, i, IR.ints.nil)))
                   ($call IR.ints.cons (j, acc)) acc)))

// One entry per component, recorded against its lowest member so a component
// is not emitted once per member.
$decl find_groups $func ($decl es edges.node, $decl i 0, $decl n 0, $decl acc IR.groups.node)
  $if ($call not ($call lt (i, n))) ($call IR.groups.reverse (acc, IR.groups.nil))
      { $decl g $call scc_of (es, i, 0, n, IR.ints.nil)
        $decl keep $match g (
            $case {$prop tag "cons"}
              // More than one member, and this is the lowest of them.
              $if ($call eq_int (g.head, i))
                  { $decl rest $call IR.ints.val (g.tail)
                    $decl m $match rest ($case {$prop tag "cons"} true, $case rest false) }.m
                  false,
            $case g false
          )
        $decl r $call find_groups (es, $call add (i, 1), n,
                    $if keep ($call IR.groups.cons ($call IR.group_of (g), acc)) acc) }.r

$decl append_fns $func ($decl xs IR.fns.node, $decl ys IR.fns.node) $match xs (
  $case {$prop tag "cons"}
    $call IR.fns.cons (xs.head, $call append_fns ($call IR.fns.val (xs.tail), ys)),
  $case xs ys
)

$decl fns_acc $func ($decl fs IR.fns.node, $decl n 0) { $decl funcs fs  $decl count n }

// §4.11 puts a `$fwd`'s slot at the *`$fwd`'s* position, completed by a later
// `$decl` — so the items and the block's fields are not one to one, and walking
// them in lockstep would misalign every name after the first forward
// declaration. The fields are the authority on order, so this walks those and
// finds each one's completing `$decl`.
$decl find_completing $func ($decl xs Pa.nodes.node, $decl nm "") $match xs (
  $case {$prop tag "cons"}
    $if ($call and ($call is_form (xs.head, "decl"),
                    $call eq_str ($call name_of ($call op (xs.head, 0)), nm)))
        xs.head ($call find_completing ($call Pa.nodes.val (xs.tail), nm)),
  $case xs ($call Pa.n_err ("no completing $decl", 0, 0))
)

$decl lower_top $func ($decl st proto_lst, $decl e benv.node, $decl items Pa.nodes.node,
                       $decl fts T.fields.node, $decl acc IR.fns.node) $match fts (
  $case {$prop tag "cons"}
    { $decl nm   fts.head.name
      $decl fty  fts.head.ty
      $decl it   $call find_completing (items, nm)
      $decl init $call op (it, 1)
      $decl f    $if ($call is_form (init, "func"))
          ($call lower_func (st, e, nm, init, fty, IR.ints.nil))
          // A thunk: no parameters, the value as its body (§7.2's frame is
          // whatever slots the initializer needed).
          { $decl reset $call take_slots (st)
            $decl v     $call lval ($call lower (st, e, init, true))
            $decl vty   $call intern (st, v.ty)
            $decl t     $call IR.fn (nm, IR.ints.nil, vty, $call take_slots (st), v.ir, false, true,
                                IR.ints.nil) }.t
      $decl idx  $call IR.fns.length (acc, 0)
      $decl f2   $call IR.fn (f.name, f.params, f.result, f.slots, f.body,
                     $call self_tails (f.body, idx), f.thunk, f.env)
      $decl r    $call lower_top (st, e, items, $call T.fields.val (fts.tail),
                     $call IR.fns.cons (f2, acc)) }.r,
  $case fts ($call fns_acc ($call IR.fns.reverse (acc, IR.fns.nil), 0))
)

// `fty` is what `check_file` returned for this file (§3.3). Only `$decl` items
// are lowered; a top-level `$prop` or a bare expression is out of the subset
// for a program's top level and reported rather than guessed at.
// The type of a lifted function, rebuilt from the types its slots were
// interned under — lowering derives, it does not carry (§5.7).
$decl param_tys $func ($decl st proto_lst, $decl ts T.tys.node, $decl xs IR.ints.node,
                       $decl acc T.tys.node) $match xs (
  $case {$prop tag "cons"}
    $call param_tys (st, ts, xs.tail, $call T.tys.cons ($call T.tys.nth (ts, xs.head), acc)),
  $case xs ($call T.tys.reverse (acc, T.tys.nil))
)

$decl fn_ty $func ($decl st proto_lst, $decl f IR.proto_fn)
  { $decl ts $call T.tys.val ($call eval_tys (st.types))
    $decl r  $call T.t_func ($call param_tys (st, ts, $call IR.ints.val (f.params), T.tys.nil),
                 $call T.tys.nth (ts, f.result)) }.r

$decl lower_file $func ($decl st proto_lst, $decl items Pa.nodes.node, $decl fty T.proto_ty,
                        $decl prims benv.node)
  { $decl flds $match fty ($case {$prop tag "block"} ($call T.fields.val (fty.fields)), $case fty T.fields.nil)
    $decl env  $call globals_from (flds, 0, prims)
    // A global's index is its position among the top-level `$decl`s, so the
    // lifted functions take the indices after them.
    $decl based $set st.fnbase ($call T.fields.length (flds, 0))
    $decl done $call lower_top (st, env, items, flds, IR.fns.nil)
    $decl all  $call append_fns ($call IR.fns.val (done.funcs),
                   $call IR.fns.reverse ($call IR.fns.val (st.lifted), IR.fns.nil))
    $decl es   $call collect_edges (all, 0, edges.nil)
    $decl gs   $call find_groups (es, 0, $call IR.fns.length (all, 0), IR.groups.nil)
    $decl out  $call IR.program ($call T.tys.val ($call eval_tys (st.types)),
                   all, gs, 0) }.out
