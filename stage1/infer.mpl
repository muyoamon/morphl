// Stage 1's inference traversal — BOOTSTRAP.md stage 1, step 3 (part two).
//
// Computes a type for every expression, on top of the relations in types.mpl.
//
// **There are no unification variables here, and that is not a shortcut.**
// §3.4 says each parameter's default *fixes* its type, so no parameter is ever
// unannotated; §4.9 types a template body only after substitution, so a generic
// name is concrete by the time it is typed; and BOOTSTRAP.md §1.1 drops
// `$call`-time inference of `T`. The only variables the subset needs are
// §5.5's recursion placeholders — `R` — which are introduced by `$decl`,
// `$prop` and `$fwd` and discharged by `close_rec`. Inference is therefore a
// bottom-up computation plus subtype *checks*, which is complete for the
// subset and much smaller than a general constraint solver.
//
// A reported error yields `⊥`. Since `⊥` is a subtype of everything (§3.6),
// one mistake does not cascade into a second.
//
// Not yet done, and known: exhaustiveness and reachability checking (§4.7,
// §5.6), `$template`/`$specialize`, `$import`, and the mutual-recursion half of
// §5.5 — a `$fwd` slot keeps its recursion variable rather than sharing one
// system of equations with its siblings.

$decl T  $import "types"
$decl Pa $import "parser"
$decl P  $import "prelude"

$decl not P.not
$decl and P.and
$decl or  P.or

// Reading a value out of storage needs a value-expecting position (§5.4), so
// each cell type gets an identity function. See BOOTSTRAP.md §7.
$decl tval   $func ($decl x T.proto_ty) x
$decl ival   P.ival

// ---------------------------------------------------------------- environment

$decl binding $func ($decl n "", $decl t T.proto_ty) { $decl name n  $decl ty t }
$decl proto_binding $call binding ("", T.t_bot)
$decl env $specialize P.list proto_binding

$decl eval_env $func ($decl x env.node) x

$decl found $func ($decl o true, $decl t T.proto_ty) { $decl ok o  $decl ty t }

$decl lookup $func ($decl e env.node, $decl n "") $match e (
  $case {$prop tag "cons"}
    $if ($call eq_str (e.head.name, n)) ($call found (true, e.head.ty)) ($call lookup (e.tail, n)),
  $case e ($call found (false, T.t_bot))
)

// Innermost wins, so a binding is prepended.
$decl bind $func ($decl e env.node, $decl n "", $decl t T.proto_ty)
  $call env.cons ($call binding (n, t), e)

// ------------------------------------------------------------------ templates
//
// §4.9: "`body` is **not** type-checked at declaration." A template's type is
// therefore only an identity; what makes specialization possible is kept here —
// the generic names, the body, and the environment the template was written in.

$decl strs $specialize P.list ""

$decl tmpl_rec $func ($decl i 0, $decl gs strs.node, $decl bd Pa.proto_node, $decl en env.node)
  { $decl id i  $decl generics gs  $decl body bd  $decl env en }

$decl proto_tmpl $call tmpl_rec (0, strs.nil, Pa.proto_node, env.nil)
$decl tmpl_list $specialize P.list proto_tmpl

// §4.9: "Typing is memoized per **argument type**."
$decl memo_ent $func ($decl k "", $decl t T.proto_ty) { $decl key k  $decl ty t }
$decl proto_memo $call memo_ent ("", T.t_bot)
$decl memo_list $specialize P.list proto_memo

// -------------------------------------------------------------------- context

$decl ctx $func ()
  { $decl next   $mut $new 1
    $decl errs   $mut $new Pa.diags.nil
    // §4.15: the error set of the function currently being typed.
    $decl tryset $mut $new T.t_bot
    // Set while the first of the two prop passes runs, so that a diagnostic is
    // reported once — by the pass that has the resolved types.
    $decl quiet  $mut $new false
    $decl tmpls  $mut $new tmpl_list.nil
    $decl memo   $mut $new memo_list.nil }

$decl proto_ctx $call ctx ()

$decl eval_diags $func ($decl x Pa.diags.node) x
$decl eval_tmpls $func ($decl x tmpl_list.node) x
$decl eval_memo  $func ($decl x memo_list.node) x

$decl fresh $func ($decl cx proto_ctx)
  { $decl i       $call ival (cx.next)
    $decl bumped  $set cx.next ($call add (i, 1))
    $decl out     i }.out

$decl bval $func ($decl b true) b

$decl err $func ($decl cx proto_ctx, $decl m "", $decl x P.proto_span)
  { $decl noted $if ($call bval (cx.quiet)) ()
        ($set cx.errs ($call Pa.diags.cons ($call Pa.diag (m, x.line, x.col), cx.errs)))
    $decl out   T.t_bot }.out

// §5.4: a reference behaves as its pointee wherever a value is expected.
$decl deref_ty $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "ref"} $call deref_ty (t.inner),
  $case t t
)

$decl is_ref $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "ref"} true,
  $case t false
)

// ------------------------------------------------------- the recursion knot
//
// §5.5: "While typing a body that refers to a name whose type is not yet known,
// that name has placeholder type `R`. The body's type is computed as an
// expression `B(R)`; the result is `μR. B(R)`, or simply `B` if `R` does not
// occur."

$fwd occurs

$decl occurs_tys $func ($decl xs T.tys.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} $if ($call occurs (xs.head, i)) true ($call occurs_tys (xs.tail, i)),
  $case xs false
)

$decl occurs_fields $func ($decl xs T.fields.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} $if ($call occurs (xs.head.ty, i)) true ($call occurs_fields (xs.tail, i)),
  $case xs false
)

$decl occurs $func ($decl t T.proto_ty, $decl i 0) $match t (
  $case {$prop tag "var"}   $call eq_int (t.id, i),
  $case {$prop tag "block"} $call occurs_fields (t.fields, i),
  $case {$prop tag "group"} $call occurs_tys (t.items, i),
  $case {$prop tag "func"}
    $if ($call occurs_tys (t.params, i)) true ($call occurs (t.result, i)),
  $case {$prop tag "ref"}   $call occurs (t.inner, i),
  $case {$prop tag "array"} $call occurs (t.elem, i),
  $case {$prop tag "union"} $call occurs_tys (t.members, i),
  $case {$prop tag "inter"} $call occurs_tys (t.members, i),
  // A nested binder for the same id shadows this one.
  $case {$prop tag "rec"}   $if ($call eq_int (t.id, i)) false ($call occurs (t.body, i)),
  $case {$prop tag "over"}  $call occurs_tys (t.cands, i),
  $case t false
)

$decl close_rec $func ($decl t T.proto_ty, $decl i 0)
  // `μR. A | R` is `A` (see `T.drop_var`), so simplify before deciding whether
  // a binder is needed at all.
  { $decl r   $call T.drop_var (t, i)
    $decl out $if ($call occurs (r, i)) ($call T.t_rec (i, r)) r }.out

// ------------------------------------------------------------------ helpers

$decl is_form $func ($decl n Pa.proto_node, $decl k "") $match n (
  $case {$prop tag "form"} $call eq_str (n.keyword, k),
  $case n false
)

$decl op $func ($decl n Pa.proto_node, $decl i 0) $call Pa.nodes.nth (n.operands, i)

$decl name_of $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "name"} n.text,
  $case n ""
)

// §2.4 with §2.3: the syntactic shape of a group decides the count, so `()` is
// none, a group is its elements, and anything else is one.
$decl group_items $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "unit"}  Pa.nodes.nil,
  $case {$prop tag "group"} n.items,
  $case n ($call Pa.nodes.cons (n, Pa.nodes.nil))
)

// ------------------------------------------------------------------ the walk

$fwd infer

$decl infer_tys $func ($decl cx proto_ctx, $decl e env.node, $decl xs Pa.nodes.node, $decl acc T.tys.node) $match xs (
  $case {$prop tag "cons"}
    $call infer_tys (cx, e, xs.tail, $call T.tys.cons ($call infer (cx, e, xs.head), acc)),
  $case xs ($call T.tys.reverse (acc, T.tys.nil))
)

// §4.6: projection reaches `$decl` fields and props uniformly (§4.10).
$decl infer_proj_name $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node)
  { $decl tt $call deref_ty ($call infer (cx, e, n.target))
    $decl out $match tt (
        $case {$prop tag "block"}
          { $decl f $call T.find_field (tt.fields, n.field)
            $decl r $if ($call not ($call eq_str (f.name, ""))) f.ty
                { $decl p $call T.find_prop (tt.props, n.field)
                  $decl rr $if ($call not ($call eq_str (p.name, ""))) p.ty
                      ($call err (cx, $call concat ("block has no field '",
                                   $call concat (n.field, "'")), n)) }.rr }.r,
        $case tt ($call err (cx, $call concat ("cannot project '.",
                      $call concat (n.field, $call concat ("' from ", $call T.show (tt)))), n))
      ) }.out

$decl infer_proj_index $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node)
  { $decl tt $call deref_ty ($call infer (cx, e, n.target))
    $decl out $match tt (
        $case {$prop tag "group"}
          $if ($call and ($call lt (0, n.index), $call not ($call lt ($call T.tys.length (tt.items, 0), n.index))))
              ($call T.tys.nth (tt.items, $call sub (n.index, 1)))
              ($call err (cx, "group index is out of range", n)),
        $case tt ($call err (cx, $call concat ("cannot index into ", $call T.show (tt)), n))
      ) }.out

// §4.3: `$mut` requires a reference.
$decl infer_mut $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node)
  { $decl t $call infer (cx, e, $call op (n, 0))
    $decl out $match t (
        $case {$prop tag "ref"} $call T.t_ref ("mut", t.inner),
        $case t ($call err (cx, $call concat ("$mut expects storage, found ",
                     $call concat ($call T.show (t), "; only $new creates storage")), n))
      ) }.out

// §4.4: writes *through* storage; the type is the written value's.
$decl infer_set $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node)
  { $decl tgt $call infer (cx, e, $call op (n, 0))
    $decl val $call deref_ty ($call infer (cx, e, $call op (n, 1)))
    $decl out $match tgt (
        $case {$prop tag "ref"}
          $if ($call T.sub (val, tgt.inner)) val
              ($call err (cx, $call concat ("cannot write ", $call concat ($call T.show (val),
                           $call concat (" into storage of ", $call T.show (tgt.inner)))), n)),
        $case tgt ($call err (cx, $call concat ("$set needs storage on the left, found ",
                       $call T.show (tgt)), n))
      ) }.out

$decl pres $func ($decl ts T.tys.node, $decl en env.node) { $decl tys ts  $decl env en }
$decl proto_pres $call pres (T.tys.nil, env.nil)

// §3.4: "each default fixes the parameter's type."
$decl infer_params $func ($decl cx proto_ctx, $decl e env.node, $decl ps Pa.nodes.node,
                          $decl acc T.tys.node, $decl inner env.node) $match ps (
  $case {$prop tag "cons"}
    { $decl d  ps.head
      $decl ok $call is_form (d, "decl")
      $decl nm $if ok ($call name_of ($call op (d, 0))) ""
      $decl ty $if ok ($call infer (cx, e, $call op (d, 1)))
                      ($call err (cx, "$func parameters must each be a $decl", d))
      $decl out $call infer_params (cx, e, ps.tail,
                    $call T.tys.cons (ty, acc), $call bind (inner, nm, ty)) }.out,
  $case ps ($call pres ($call T.tys.reverse (acc, T.tys.nil), inner))
)

// §5.5 for a function that names itself.
//
// A bare placeholder `R` cannot be called, so binding the name to `R` and
// typing the body would report "not callable" instead of tying the knot. But
// §3.4 gives the parameter types *before* the body is typed, so the only
// unknown is the result: bind the name to `[params] -> R`, type the body, and
// close `R` over it. §5.5's own example then comes out exactly as the spec
// states it — the μ binds the *return* type, giving a list type.
$decl infer_rec_func $func ($decl cx proto_ctx, $decl e env.node, $decl nm "", $decl n Pa.proto_node)
  { $decl ps   $call group_items ($call op (n, 0))
    $decl id   $call fresh (cx)
    $decl r    $call infer_params (cx, e, ps, T.tys.nil, e)
    $decl self $call T.t_func (r.tys, $call T.t_var (id))
    $decl benv $call bind (r.env, nm, self)
    $decl saved   $call tval (cx.tryset)
    $decl cleared $set cx.tryset T.t_bot
    $decl body    $call infer (cx, benv, $call op (n, 1))
    $decl tries   $call tval (cx.tryset)
    $decl restored $set cx.tryset saved
    $decl res0 $call T.join (body, tries)
    // `μR.R` is uninhabited: a function whose only result is its own recursive
    // call never returns, so its result type is ⊥ (§3.6).
    $decl res  $if ($call T.ty_eq (res0, $call T.t_var (id))) T.t_bot ($call close_rec (res0, id))
    $decl out  $call T.t_func (r.tys, res) }.out

$decl infer_func $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node)
  { $decl ps   $call group_items ($call op (n, 0))
    $decl r    $call infer_params (cx, e, ps, T.tys.nil, e)
    // Each `$func` has its own error set (§4.15); save and restore the
    // enclosing one, since `$try` targets the *nearest* function.
    $decl saved   $call tval (cx.tryset)
    $decl cleared $set cx.tryset T.t_bot
    $decl body    $call infer (cx, r.env, $call op (n, 1))
    $decl tries   $call tval (cx.tryset)
    $decl restored $set cx.tryset saved
    // §4.15: "The enclosing function's inferred return type gains
    // `type(e) & pat` as union members." Joining with ⊥ is the identity, so a
    // function with no `$try` is unaffected.
    $decl out $call T.t_func (r.tys, $call T.join (body, tries)) }.out

$decl check_args $func ($decl cx proto_ctx, $decl e env.node, $decl ps T.tys.node,
                        $decl as Pa.nodes.node, $decl n Pa.proto_node, $decl i 1) $match as (
  $case {$prop tag "cons"} $match ps (
      $case {$prop tag "cons"}
        { $decl raw $call infer (cx, e, as.head)
          // §5.4: a parameter whose type is a reference wants storage; any
          // other parameter wants a value, so the argument dereferences.
          $decl at $if ($call is_ref (ps.head)) raw ($call deref_ty (raw))
          $decl out $if ($call T.sub (at, ps.head))
              ($call check_args (cx, e, ps.tail, as.tail, n, $call add (i, 1)))
              ($do ($call err (cx, $call concat ("argument ", $call concat ($call int_to_str (i),
                        $call concat (" is ", $call concat ($call T.show (at),
                        $call concat (", expected ", $call T.show (ps.head)))))), as.head))
                   false) }.out,
      $case ps ($do ($call err (cx, "too many arguments", n)) false)
    ),
  // Fewer arguments than parameters is fine: the defaults fill in (§3.4).
  $case as true
)

$decl infer_call $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node)
  { $decl ft   $call deref_ty ($call infer (cx, e, $call op (n, 0)))
    $decl args $call group_items ($call op (n, 1))
    $decl out $match ft (
        $case {$prop tag "func"}
          { $decl ok $call check_args (cx, e, ft.params, args, n, 1)
            $decl r  $if ok ft.result T.t_bot }.r,
        // §3.6: a call on ⊥ stays ⊥ rather than reporting a second error.
        $case {$prop tag "bottom"} T.t_bot,
        // §4.9 would infer `T` from the argument shapes; BOOTSTRAP.md §1.1
        // drops that, so the call site has to say what it means.
        $case {$prop tag "tmpl"} ($call err (cx,
            "$call on a template needs an explicit $specialize first (BOOTSTRAP.md §1.1)", n)),
        $case ft ($call err (cx, $call concat ($call T.show (ft), " is not callable"), n))
      ) }.out

// §2.2: `$if c a b` is sugar for `$match c ($case true a, $case false b)`.
$decl infer_if $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node)
  { $decl c   $call deref_ty ($call infer (cx, e, $call op (n, 0)))
    $decl chk $if ($call T.sub (c, T.t_bool)) T.t_unit
                  ($call err (cx, $call concat ("$if condition must be Bool, found ",
                                  $call T.show (c)), n))
    $decl a $call infer (cx, e, $call op (n, 1))
    $decl b $call infer (cx, e, $call op (n, 2))
    $decl out $call T.join (a, b) }.out

// §4.8a: the value is the first member; the type is the union of all of them.
$decl infer_union $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node)
  $call T.t_union ($call infer_tys (cx, e, $call group_items ($call op (n, 0)), T.tys.nil))

// §4.7: "Inside an arm, `e` (by its name) is narrowed to `type(e) & P`."
// Narrowing needs a name to rebind, which is why §4.7 reaches fields "through
// the narrowed scrutinee".
$decl narrow $func ($decl e env.node, $decl scrut Pa.proto_node, $decl t T.proto_ty) $match scrut (
  $case {$prop tag "name"} $call bind (e, scrut.text, t),
  $case scrut e
)

$decl infer_arms $func ($decl cx proto_ctx, $decl e env.node, $decl scrut Pa.proto_node,
                        $decl st T.proto_ty, $decl arms Pa.nodes.node, $decl acc T.proto_ty) $match arms (
  $case {$prop tag "cons"}
    { $decl a  arms.head
      // A pattern is a type-only position (§5.7): never evaluated, only its
      // type used — which is exactly what `infer` returns.
      $decl pt $call infer (cx, e, $call op (a, 0))
      // §4.7: narrowed to `type(e) & P` — as a selection, not an intersection.
      $decl e2 $call narrow (e, scrut, $call T.restrict (st, pt))
      $decl bt $call infer (cx, e2, $call op (a, 1))
      $decl out $call infer_arms (cx, e, scrut, st, arms.tail, $call T.join (acc, bt)) }.out,
  $case arms acc
)

$decl infer_match $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node)
  { $decl sn   $call op (n, 0)
    $decl st   $call deref_ty ($call infer (cx, e, sn))
    $decl arms $call group_items ($call op (n, 1))
    $decl out  $call infer_arms (cx, e, sn, st, arms, T.t_bot) }.out

// §4.15. The error set is inferred, not declared.
$decl infer_try $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node)
  { $decl vt $call infer (cx, e, $call op (n, 0))
    $decl pt $call infer (cx, e, $call op (n, 1))
    $decl added $set cx.tryset
        ($call T.join ($call tval (cx.tryset), $call T.restrict ($call deref_ty (vt), pt)))
    // §4.15: "otherwise the expression's value is `e`, narrowed to
    // `type(e) & ¬pat`." For a union of tag shapes — which is what every
    // fallible result is — that is exactly dropping the covered members.
    $decl out $call T.minus (vt, pt) }.out

// ------------------------------------------------ $template and $specialize

$fwd generic_names_list

$decl generic_names $func ($decl n Pa.proto_node, $decl acc strs.node) $match n (
  $case {$prop tag "name"}  $call strs.cons (n.text, acc),
  $case {$prop tag "group"} $call generic_names_list (n.items, acc),
  $case n acc
)

$decl generic_names_list $func ($decl xs Pa.nodes.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"}
    $call generic_names_list (xs.tail, $call strs.cons ($call name_of (xs.head), acc)),
  $case xs ($call strs.reverse (acc, strs.nil))
)

// §4.9: the declaration itself checks nothing. It records what specialization
// will need and hands back an identity.
$decl infer_template $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node)
  { $decl gs    $call generic_names ($call op (n, 0), strs.nil)
    $decl id    $call fresh (cx)
    $decl rec   $call tmpl_rec (id, gs, $call op (n, 1), e)
    $decl added $set cx.tmpls ($call tmpl_list.cons (rec, $call eval_tmpls (cx.tmpls)))
    $decl out   $call T.t_tmpl (id) }.out

$decl find_tmpl $func ($decl xs tmpl_list.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_int (xs.head.id, i)) xs.head ($call find_tmpl (xs.tail, i)),
  $case xs ($call tmpl_rec (-1, strs.nil, Pa.proto_node, env.nil))
)

$decl memo_find $func ($decl xs memo_list.node, $decl k "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.key, k)) ($call found (true, xs.head.ty)) ($call memo_find (xs.tail, k)),
  $case xs ($call found (false, T.t_bot))
)

$decl memo_key $func ($decl i 0, $decl ats T.tys.node, $decl acc "") $match ats (
  $case {$prop tag "cons"}
    $call memo_key (i, ats.tail, $call concat (acc, $call concat ("|", $call T.show (ats.head)))),
  $case ats ($call concat ($call int_to_str (i), acc))
)

// §4.9: "binds it to the corresponding generic name, as if `$decl T arg` were
// prepended to `body`". At the type level that is binding the name to the
// argument's type.
$decl bind_generics $func ($decl e env.node, $decl gs strs.node, $decl ats T.tys.node) $match gs (
  $case {$prop tag "cons"} $match ats (
      $case {$prop tag "cons"}
        $call bind_generics ($call bind (e, gs.head, ats.head), gs.tail, ats.tail),
      $case ats e
    ),
  $case gs e
)

$decl specialize_with $func ($decl cx proto_ctx, $decl e env.node, $decl id 0,
                             $decl argn Pa.proto_node, $decl n Pa.proto_node)
  { $decl r  $call find_tmpl ($call eval_tmpls (cx.tmpls), id)
    $decl ng $call strs.length (r.generics, 0)
    // §2.3 again: with one generic the whole operand is the argument; with
    // several it has to be a group.
    $decl args $if ($call eq_int (ng, 1))
        ($call Pa.nodes.cons (argn, Pa.nodes.nil))
        ($call group_items (argn))
    $decl na  $call Pa.nodes.length (args, 0)
    $decl ats $call infer_tys (cx, e, args, T.tys.nil)
    $decl out $if ($call not ($call eq_int (ng, na)))
        ($call err (cx, $call concat ("this template has ", $call concat ($call int_to_str (ng),
            $call concat (" generic parameters, found ", $call int_to_str (na)))), n))
        { $decl key $call memo_key (id, ats, "")
          $decl hit $call memo_find ($call eval_memo (cx.memo), key)
          $decl rr $if hit.ok hit.ty
              { $decl benv $call bind_generics (r.env, r.generics, ats)
                // Memoised *before* the body is typed, with a placeholder, so a
                // template that reaches itself terminates — §4.9: "hitting an
                // in-progress entry returns its `R`."
                $decl ph  $call T.t_var ($call fresh (cx))
                $decl m0  $set cx.memo ($call memo_list.cons ($call memo_ent (key, ph), $call eval_memo (cx.memo)))
                $decl ty0 $call infer (cx, benv, r.body)
                // §5.5 discharges the placeholder if the body reached back.
                $decl ty  $call close_rec (ty0, $call var_id (ph))
                $decl m1  $set cx.memo ($call memo_list.cons ($call memo_ent (key, ty), $call eval_memo (cx.memo)))
                $decl res ty }.res }.rr }.out

// §4.9 steps 2 and 3: type the substituted expression with ordinary rules, and
// have exactly its type.
$decl infer_specialize $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node)
  { $decl tt $call deref_ty ($call infer (cx, e, $call op (n, 0)))
    $decl out $match tt (
        $case {$prop tag "tmpl"}   $call specialize_with (cx, e, tt.id, $call op (n, 1), n),
        $case {$prop tag "bottom"} T.t_bot,
        $case tt ($call err (cx, $call concat ("$specialize expects a template, found ",
                      $call T.show (tt)), n))
      ) }.out

// ------------------------------------------------------------------- blocks

$decl bst $func ($decl e0 env.node)
  { $decl env  $mut $new e0
    $decl flds $mut $new T.fields.nil
    $decl prps $mut $new T.props.nil }

$decl proto_bst $call bst (env.nil)

$decl eval_flds $func ($decl x T.fields.node) x
$decl eval_prps $func ($decl x T.props.node) x

$decl has_field $func ($decl xs T.fields.node, $decl nm "") $match xs (
  $case {$prop tag "cons"} $if ($call eq_str (xs.head.name, nm)) true ($call has_field (xs.tail, nm)),
  $case xs false
)

$decl upd_field $func ($decl xs T.fields.node, $decl nm "", $decl ty T.proto_ty) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, nm))
        ($call T.fields.cons ($call T.field (nm, ty), xs.tail))
        ($call T.fields.cons (xs.head, $call upd_field (xs.tail, nm, ty))),
  $case xs xs
)

$decl put_field $func ($decl xs T.fields.node, $decl nm "", $decl ty T.proto_ty)
  $if ($call has_field (xs, nm)) ($call upd_field (xs, nm, ty))
      ($call T.fields.cons ($call T.field (nm, ty), xs))

// §4.10: a prop's *value* is part of the enclosing block's type. Only a literal
// initializer yields an exact value; anything else is opaque but still carries
// its type, which is what projection needs.
$decl const_of $func ($decl cx proto_ctx, $decl n Pa.proto_node) $match n (
  $case {$prop tag "int"}  $call T.cv_int (n.value),
  $case {$prop tag "str"}  $call T.cv_str (n.text),
  $case {$prop tag "bool"} $call T.cv_bool (n.value),
  $case {$prop tag "unit"} T.cv_unit,
  $case n ($call T.cv_opaque ($call fresh (cx)))
)

// §4.10: props are visible throughout their block regardless of order, so every
// prop name is bound before any of them is typed. Each starts as a recursion
// placeholder, discharged when its own initializer has been typed.
$decl prebind_props $func ($decl cx proto_ctx, $decl items Pa.nodes.node, $decl acc env.node) $match items (
  $case {$prop tag "cons"}
    { $decl it items.head
      $decl e2 $if ($call is_form (it, "prop"))
          ($call bind (acc, $call name_of ($call op (it, 0)), $call T.t_var ($call fresh (cx))))
          acc
      $decl out $call prebind_props (cx, items.tail, e2) }.out,
  $case items acc
)

$decl var_id $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "var"} t.id,
  $case t -1
)

$decl infer_decl_item $func ($decl cx proto_ctx, $decl s proto_bst, $decl it Pa.proto_node)
  { $decl nm   $call name_of ($call op (it, 0))
    $decl init $call op (it, 1)
    // §4.1: the name is in scope inside its own initializer, standing for
    // §5.5's placeholder `R`. A `$func` initializer gets the sharper treatment
    // in `infer_rec_func`, because a bare `R` is not callable.
    $decl ty $if ($call is_form (init, "func"))
        ($call infer_rec_func (cx, $call eval_env (s.env), nm, init))
        { $decl id  $call fresh (cx)
          $decl e1  $call bind ($call eval_env (s.env), nm, $call T.t_var (id))
          $decl raw $call infer (cx, e1, init)
          $decl r   $call close_rec (raw, id) }.r
    $decl bound $set s.env ($call bind ($call eval_env (s.env), nm, ty))
    // A `$fwd` already reserved this slot at its own position (§4.11), so
    // complete that one rather than appending a second.
    $decl added $set s.flds ($call put_field ($call eval_flds (s.flds), nm, ty)) }

// The type of one prop. §4.10: the initializer sees other props and enclosing
// scopes, but *not* ordered siblings — hence the prop-only environment.
$decl prop_ty $func ($decl cx proto_ctx, $decl pe env.node, $decl nm "", $decl it Pa.proto_node)
  { $decl init $call op (it, 1)
    $decl id   $call var_id ($call lookup (pe, nm)).ty
    $decl out $if ($call is_form (init, "func"))
        ($call infer_rec_func (cx, pe, nm, init))
        { $decl raw $call infer (cx, pe, init)
          $decl r   $if ($call lt (-1, id)) ($call close_rec (raw, id)) raw }.r }.out

// §4.10 says props are "typed together as one system", which is the one place
// the subset genuinely needs a fixpoint: a prop may name a *later* prop, so one
// left-to-right pass would leave that reference as a placeholder. Two passes
// resolve it — the first computes types with placeholders, the second retypes
// with the first pass's answers in scope. Each prop is still typed with its own
// name bound to its placeholder, so self-recursion still closes with μ (§5.5).
$decl prop_pass $func ($decl cx proto_ctx, $decl pe0 env.node, $decl items Pa.nodes.node, $decl acc env.node) $match items (
  $case {$prop tag "cons"}
    { $decl it items.head
      $decl nm $call name_of ($call op (it, 0))
      $decl e2 $if ($call is_form (it, "prop"))
          ($call bind (acc, nm,
              $call prop_ty (cx, $call bind (acc, nm, ($call lookup (pe0, nm)).ty), nm, it)))
          acc
      $decl out $call prop_pass (cx, pe0, items.tail, e2) }.out,
  $case items acc
)

// By the time this runs the prop's type is already resolved, so it only records
// the entry — §4.10's value for identity, plus the type for projection.
$decl infer_prop_item $func ($decl cx proto_ctx, $decl s proto_bst, $decl pe env.node, $decl it Pa.proto_node)
  { $decl nm $call name_of ($call op (it, 0))
    $decl f  $call lookup (pe, nm)
    $decl cv $call const_of (cx, $call op (it, 1))
    $decl added $set s.prps ($call T.props.cons ($call T.prop_typed (nm, cv, f.ty), $call eval_prps (s.prps)))
    $decl bound $set s.env ($call bind ($call eval_env (s.env), nm, f.ty)) }

// §4.11: reserves an ordered slot *at this position* with a placeholder type.
$decl infer_fwd_item $func ($decl cx proto_ctx, $decl s proto_bst, $decl it Pa.proto_node)
  { $decl nm $call name_of ($call op (it, 0))
    $decl ty $call T.t_var ($call fresh (cx))
    $decl bound $set s.env ($call bind ($call eval_env (s.env), nm, ty))
    $decl added $set s.flds ($call put_field ($call eval_flds (s.flds), nm, ty)) }

$decl infer_item $func ($decl cx proto_ctx, $decl s proto_bst, $decl pe env.node, $decl it Pa.proto_node)
  $if ($call is_form (it, "prop")) ($call infer_prop_item (cx, s, pe, it))
  ($if ($call is_form (it, "fwd")) ($call infer_fwd_item (cx, s, it))
  ($if ($call is_form (it, "decl")) ($call infer_decl_item (cx, s, it))
       // §3.3: other expressions run for effect and are discarded.
       ($do ($call infer (cx, $call eval_env (s.env), it)) ())))

$decl infer_items $func ($decl cx proto_ctx, $decl s proto_bst, $decl pe env.node, $decl items Pa.nodes.node) $match items (
  $case {$prop tag "cons"}
    $do ($call infer_item (cx, s, pe, items.head)) ($call infer_items (cx, s, pe, items.tail)),
  $case items ()
)

// §3.3: a block's type is the ordered list of its `$decl` slots plus its props.
$decl infer_block $func ($decl cx proto_ctx, $decl e0 env.node, $decl items Pa.nodes.node)
  { $decl pe0    $call prebind_props (cx, items, e0)
    $decl hushed $set cx.quiet true
    $decl peA    $call prop_pass (cx, pe0, items, pe0)
    $decl heard  $set cx.quiet false
    $decl pe     $call prop_pass (cx, pe0, items, peA)
    $decl s      $call bst (pe)
    $decl walked $call infer_items (cx, s, pe, items)
    $decl out    $call T.t_block ($call T.fields.reverse ($call eval_flds (s.flds), T.fields.nil),
                                  $call eval_prps (s.prps)) }.out

// ------------------------------------------------------------------ dispatch

$decl infer_form $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node)
  { $decl k n.keyword
    $decl out
      $if ($call eq_str (k, "decl"))  ($call infer (cx, e, $call op (n, 1)))
      ($if ($call eq_str (k, "new"))   ($call T.t_ref ("", $call deref_ty ($call infer (cx, e, $call op (n, 0)))))
      ($if ($call eq_str (k, "mut"))   ($call infer_mut (cx, e, n))
      ($if ($call eq_str (k, "set"))   ($call infer_set (cx, e, n))
      ($if ($call eq_str (k, "func"))  ($call infer_func (cx, e, n))
      ($if ($call eq_str (k, "call"))  ($call infer_call (cx, e, n))
      ($if ($call eq_str (k, "if"))    ($call infer_if (cx, e, n))
      ($if ($call eq_str (k, "do"))    ($do ($call infer (cx, e, $call op (n, 0)))
                                            ($call infer (cx, e, $call op (n, 1))))
      ($if ($call eq_str (k, "union")) ($call infer_union (cx, e, n))
      ($if ($call eq_str (k, "match")) ($call infer_match (cx, e, n))
      ($if ($call eq_str (k, "try"))   ($call infer_try (cx, e, n))
      ($if ($call eq_str (k, "template"))   ($call infer_template (cx, e, n))
      ($if ($call eq_str (k, "specialize")) ($call infer_specialize (cx, e, n))
           ($call err (cx, $call concat ("typing $", $call concat (k, " is not implemented yet")), n))
      ))))))))))))
  }.out

$decl infer $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node) $match n (
  // §3.1: "Literals have their base type." There are no singleton literal types.
  $case {$prop tag "int"}   T.t_int,
  $case {$prop tag "float"} T.t_float,
  $case {$prop tag "str"}   T.t_str,
  // §3.2 is the exception: `true` and `false` are distinct nullary *tag* types,
  // so a boolean literal's type is narrower than Bool.
  $case {$prop tag "bool"}  $if n.value T.t_true T.t_false,
  $case {$prop tag "unit"}  T.t_unit,
  $case {$prop tag "name"}
    { $decl f $call lookup (e, n.text)
      $decl out $if f.ok f.ty
          ($call err (cx, $call concat ("unknown name '", $call concat (n.text, "'")), n)) }.out,
  $case {$prop tag "group"} $call T.t_group ($call infer_tys (cx, e, n.items, T.tys.nil)),
  $case {$prop tag "block"} $call infer_block (cx, e, n.items),
  $case {$prop tag "proj_name"}  $call infer_proj_name (cx, e, n),
  $case {$prop tag "proj_index"} $call infer_proj_index (cx, e, n),
  $case {$prop tag "form"}  $call infer_form (cx, e, n),
  // A parse error already reported; ⊥ keeps it from cascading.
  $case n T.t_bot
)

// ------------------------------------------------------- the typed root block
//
// BOOTSTRAP.md §2's monomorphic root block, with types. §8 defines the numeric
// intrinsics as `$overload` sets; dropping float arithmetic is what lets each
// of these be a single function type.

$decl ii_i $call T.t_func ($call T.tys.cons (T.t_int, $call T.tys.cons (T.t_int, T.tys.nil)), T.t_int)
$decl ii_b $call T.t_func ($call T.tys.cons (T.t_int, $call T.tys.cons (T.t_int, T.tys.nil)), T.t_bool)
$decl ss_b $call T.t_func ($call T.tys.cons (T.t_str, $call T.tys.cons (T.t_str, T.tys.nil)), T.t_bool)
$decl ss_s $call T.t_func ($call T.tys.cons (T.t_str, $call T.tys.cons (T.t_str, T.tys.nil)), T.t_str)
$decl i_i  $call T.t_func ($call T.tys.cons (T.t_int, T.tys.nil), T.t_int)
$decl s_i  $call T.t_func ($call T.tys.cons (T.t_str, T.tys.nil), T.t_int)
$decl i_s  $call T.t_func ($call T.tys.cons (T.t_int, T.tys.nil), T.t_str)
$decl si_i $call T.t_func ($call T.tys.cons (T.t_str, $call T.tys.cons (T.t_int, T.tys.nil)), T.t_int)
$decl sii_s $call T.t_func ($call T.tys.cons (T.t_str,
                            $call T.tys.cons (T.t_int, $call T.tys.cons (T.t_int, T.tys.nil))), T.t_str)
$decl s_u  $call T.t_func ($call T.tys.cons (T.t_str, T.tys.nil), T.t_unit)
$decl s_bot $call T.t_func ($call T.tys.cons (T.t_str, T.tys.nil), T.t_bot)

// §4.15's shapes, and the `option` that §8 requires failing operations to use.
$decl t_none $call T.tag_block ("tag", "none")
$decl t_err  $call T.tag_block ("tag", "err")

$decl some_of $func ($decl t T.proto_ty)
  $call T.t_block ($call T.f1 ("v", t), $call T.p1 ("tag", $call T.cv_str ("some")))

$decl opt_int $call T.union2 (t_none, $call some_of (T.t_int))
$decl opt_str $call T.union2 (t_none, $call some_of (T.t_str))

$decl root_env
  $call bind ($call bind ($call bind ($call bind ($call bind ($call bind (
  $call bind ($call bind ($call bind ($call bind ($call bind ($call bind (
  $call bind ($call bind ($call bind ($call bind ($call bind ($call bind (
  $call bind ($call bind ($call bind ($call bind (env.nil,
    "add", ii_i), "sub", ii_i), "mul", ii_i), "div", ii_i), "mod", ii_i), "neg", i_i),
    "lt", ii_b), "eq_int", ii_b), "eq_str", ss_b), "concat", ss_s), "len", s_i),
    "slice", sii_s), "byte", si_i), "int_to_str", i_s),
    "str_to_int", $call T.t_func ($call T.tys.cons (T.t_str, T.tys.nil), opt_int)),
    "from_code", $call T.t_func ($call T.tys.cons (T.t_int, T.tys.nil), opt_str)),
    "panic", s_bot), "print", s_u),
    "read_file", $call T.t_func ($call T.tys.cons (T.t_str, T.tys.nil), opt_str)),
    "write_file", $call T.t_func ($call T.tys.cons (T.t_str, $call T.tys.cons (T.t_str, T.tys.nil)),
                                  $call T.union2 (T.t_unit, t_err))),
    "err", t_err), "none", t_none)

// ---------------------------------------------------------------------- entry

$decl result $func ($decl t T.proto_ty, $decl ds Pa.diags.node) { $decl ty t  $decl errs ds }

// §3.3: "A source file is a block."
$decl infer_file $func ($decl items Pa.nodes.node, $decl e0 env.node)
  { $decl cx $call ctx ()
    $decl t  $call infer_block (cx, e0, items)
    $decl out $call result (t, $call Pa.diags.reverse ($call eval_diags (cx.errs), Pa.diags.nil)) }.out

$decl check_source $func ($decl src "")
  { $decl p $call Pa.parse (src)
    $decl out $if ($call Pa.diags.is_nil (p.errs))
        ($call infer_file (p.exprs, root_env))
        ($call result (T.t_bot, p.errs)) }.out
