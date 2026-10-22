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
$decl Y  $import "tyio"
$decl P  $import "prelude"

$decl not P.not
$decl and P.and
$decl or  P.or

// Reading a value out of storage needs a value-expecting position (§5.4), so
// each cell type gets an identity function. See BOOTSTRAP.md §7.
$decl tval $func ($decl x T.proto_ty) x
$decl ival P.ival

// ---------------------------------------------------------------- environment

$decl binding $func ($decl n "", $decl t T.proto_ty) { $decl name n  $decl ty t }
$decl proto_binding $call binding ("", T.t_bot)
$decl env     $specialize P.list proto_binding

$decl eval_env $func ($decl x env.node) x

$decl var_id $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "var"} t.id,
  $case t -1
)

// `T.tval` for the same reason as `group_items`: a function result is a place
// where a reference stays a reference (§5.4), and `result` is storage now, so
// without it this arm and the next would give the function a union type.
$decl result_of $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "func"} ($call T.tval (t.result)),
  $case t t
)

$decl found $func ($decl o P.boolean, $decl t T.proto_ty) { $decl ok o  $decl ty t }

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

$decl join_strs $func ($decl xs strs.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"} ($call join_strs (xs.tail, $call strs.cons (xs.head, acc))),
  $case xs acc
)


// `file` is the file the template was *written* in. §10.7 checks a template
// body only at specialization, which routinely happens in another file after an
// `$import`, and a node carries a line and column but not a file — so without
// this a diagnostic from a library template is reported against whichever file
// happened to use it. Stage 0 carries the same field on a `$func` for the same
// reason (see `Func.file` in lib/interp/value.zig).
// `ctg` is §4.9's compile-time generics: the ones whose value reaches a prop, each
// with the prop it reaches. Computed at the declaration (`ctg_fix`).
// `bounds` is each generic's bound in order, unit when it has none (§4.9).
$decl tmpl_rec_c $func ($decl i 0, $decl gs strs.node, $decl bd Pa.proto_node, $decl en env.node,
                        $decl fl "", $decl cg Pa.ctgs.node, $decl bs Pa.nodes.node)
  { $decl id i  $decl generics gs  $decl body bd  $decl env en  $decl file fl  $decl ctg cg
    $decl bounds bs }
$decl tmpl_rec $func ($decl i 0, $decl gs strs.node, $decl bd Pa.proto_node, $decl en env.node,
                      $decl fl "")
  $call tmpl_rec_c (i, gs, bd, en, fl, Pa.ctgs.nil)

$decl proto_tmpl $call tmpl_rec (0, strs.nil, Pa.proto_node, env.nil, "")
$decl tmpl_list  $specialize P.list proto_tmpl

// §4.9: "Typing is memoized per **argument type**."
$decl memo_ent   $func ($decl k "", $decl t T.proto_ty) { $decl key k  $decl ty t }
$decl proto_memo $call memo_ent ("", T.t_bot)
$decl memo_list  $specialize P.list proto_memo

// TRAITS.md, design point 7, through §4.9: a `$traitsof` of a specialisation still being
// typed (`$traitsof ($specialize seq T)` inside `seq`) is answered by the trait placeholder
// `rt`, recorded against the memo's placeholder `ph`; `specialize_at` closes it.
$decl st_pair  $func ($decl p 0, $decl r 0) { $decl ph p  $decl rt r }
$decl st_pairs $specialize P.list ($call st_pair (0, 0))

// §4.14: "**Loaded once.** All imports of the same resolved file yield the same
// block", and "**Cycles are an error.**" `state` is "loading" while a module is
// being typed, which is what turns a cycle into a diagnostic instead of a hang.
// `ifh` is the hash of this module's **serialised interface**, which is what an
// importer's cache key is built from. Keying on an import's *source* instead was the
// defect that made the cache worthless for a real build: `compiler.mpl` imports
// everything, so a comment added to `emit.mpl` changed `emit`'s source hash, hence
// `compiler`'s key, hence a miss on the most expensive module in the program — and
// editing one leaf cost as much as compiling from scratch (24.06s against 24.53s).
// An interface hash does not move for a comment, so the importer hits.
$decl mod_ent_h $func ($decl k "", $decl st "", $decl t T.proto_ty, $decl h 0)
  { $decl key k  $decl state st  $decl ty t  $decl ifh h }
$decl mod_ent $func ($decl k "", $decl st "", $decl t T.proto_ty)
  $call mod_ent_h (k, st, t, 0)
$decl proto_mod $call mod_ent ("", "", T.t_bot)
$decl mod_list  $specialize P.list proto_mod

// §4.11 + §5.5: a `$fwd` name and the placeholder standing for its result.
$decl fwd_ent   $func ($decl n "", $decl i 0) { $decl name n  $decl id i }
$decl proto_fwd $call fwd_ent ("", 0)
$decl fwd_list  $specialize P.list proto_fwd

// §4.16 rule 2 asks "which `$func` literal did this value come from", so what a
// `$decl` of a literal records is the **literal**, not a verdict about it. The
// capture analysis is two AST walks and is wanted only for an argument that
// actually crosses into C, which in a program with no `$extern` is none.
$decl fnlit_ent   $func ($decl n "", $decl l Pa.proto_node) { $decl name n  $decl lit l }
$decl proto_fnlit $call fnlit_ent ("", Pa.proto_node)
$decl fnlit_list  $specialize P.list proto_fnlit

$decl find_fnlit $func ($decl xs fnlit_list.node, $decl nm "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, nm)) xs.head
        ($call find_fnlit ($call fnlit_list.val (xs.tail), nm)),
  $case xs ($call fnlit_ent ("", Pa.proto_node))
)

$decl find_fwd $func ($decl xs fwd_list.node, $decl nm "") $match xs (
  $case {$prop tag "cons"} $if ($call eq_str (xs.head.name, nm)) xs.head ($call find_fwd (xs.tail, nm)),
  $case xs ($call fwd_ent ("", -1))
)

// §5.5: "The resulting constraint (e.g. `R <: Int`) is checked after the knot
// is tied; failure is reported at the recursive call." A check against a type
// that still mentions an unresolved placeholder is parked here and re-run once
// the system is solved. `line`/`col` come first so this carries a span (§5.1).
$decl def_ent $func ($decl l 0, $decl c 0, $decl m "", $decl a T.proto_ty, $decl b T.proto_ty)
  { $decl line l  $decl col c  $decl msg m  $decl sub a  $decl sup b }
$decl proto_def $call def_ent (0, 0, "", T.t_bot, T.t_bot)
$decl def_list  $specialize P.list proto_def


// One equation of the system: this placeholder resolves to this type.
$decl res_ent   $func ($decl i 0, $decl t T.proto_ty) { $decl id i  $decl ty t }
$decl proto_res $call res_ent (0, T.t_bot)
$decl res_list  $specialize P.list proto_res

// -------------------------------------------------------------------- context

// A call recorded against a function still being typed (§5.3a): the callee's
// placeholder result, the argument's position and what was passed, and the body it was
// made in.
// An open function body: its serial, the depth its body is typed at, and its key — the
// `$func` form's file and span, which a second typing of the same block finds again.
$decl fframe       $func ($decl fs 0, $decl fd 0, $decl fk "")
  { $decl ser fs  $decl depth fd  $decl key fk }
$decl proto_fframe $call fframe (0, 0, "")
$decl fframes      $specialize P.list proto_fframe

$decl pesc_ent $func ($decl pid 0, $decl pi 0, $decl px Pa.proto_node, $decl pr T.proto_ty,
    $decl pw T.proto_ty, $decl po 0, $decl pk fframes.node)
  { $decl id pid  $decl i pi  $decl x px  $decl raw pr  $decl want pw  $decl own po  $decl stk pk }
$decl proto_pesc $call pesc_ent (0, 0, Pa.proto_node, T.t_bot, T.t_bot, 0, fframes.nil)
$decl pesc_list  $specialize P.list proto_pesc

// A parameter found to escape after its function had already closed: its key and index,
// for the next typing of the block to fold in (`func_close`, `infer_block`).
$decl hint_ent   $func ($decl hk "", $decl hj 0) { $decl key hk  $decl j hj }
$decl proto_hint $call hint_ent ("", 0)
$decl hint_list  $specialize P.list proto_hint

$decl ctx $func () {
  $decl next   $mut $alloc 1
  // §4.2 types storage from its operand, so `$new xs.nil` is storage only the
  // empty list fits into. `node` *is* the list type and still evaluates to
  // nil (§4.8a: a union evaluates to its first member), so it widens the
  // storage to what gets written without changing what it starts as.
  $decl errs   $mut $alloc Pa.diags.node
  // §4.15: the error set of the function currently being typed.
  $decl tryset $mut $alloc T.proto_ty
  // Set while the first of the two prop passes runs, so that a diagnostic is
  // reported once — by the pass that has the resolved types.
  $decl quiet $mut $alloc ($union (false, true))
  $decl tmpls $mut $alloc tmpl_list.node
  $decl memo  $mut $alloc memo_list.node
  $decl mods  $mut $alloc mod_list.node
  $decl defer $mut $alloc def_list.node
  // Where `$import` resolves from. §4.14 makes import names logical and hands
  // resolution to the build program; this is the stage-1 stand-in.
  $decl base   $mut $alloc ""
  // The library roots `$import` falls back to, in order (`Pa.resolve_import`).
  $decl roots  $mut $alloc strs.node
  // The file currently being typed. A diagnostic belongs to the file whose
  // source raised it, which is not the file the checker was invoked on as
  // soon as anything is imported.
  $decl file   $mut $alloc ""
  // Which `$specialize` body is being typed, as §4.9's memo key — "" at a file's
  // top level. It exists so a compile-time identity can be a function of its
  // *source* rather than of a counter: `specialize_with` retargets `cx.file` to the
  // **template's** file while typing the body, so (file, span) is identical for
  // every instantiation and could not tell `$specialize P.list Int` from
  // `$specialize P.list Str`. Their props are `cv_opaque`, `same_props` compares
  // values, and two props-only blocks with equal props are one type — so without
  // this the two specialisations would compare **equal**. Saved and restored around
  // the body exactly as `file` is.
  $decl sctx   $mut $alloc ""
  // ------------------------------------------------- the interface cache (§9)
  //
  // Where a module's serialised interface is kept, or "" for **off** — which is the
  // default, so the compiler behaves exactly as before unless a driver asks. §9 makes
  // the build a program, so whether to cache is the build's decision and not the
  // compiler's; what the compiler supplies is the hook.
  $decl cdir  $mut $alloc ""
  $decl nhit  $mut $alloc 0
  $decl nmiss $mut $alloc 0
  // §4.10's compile-time names: every `$prop` bound anywhere, and every
  // `$template` generic. A prop initializer may name one of these and nothing
  // else — a parameter or a `$decl` is an enclosing *runtime* binding, and
  // §4.10 requires the initializer to be "fully evaluable by the compiler".
  //
  // It only ever grows: a name that has gone out of scope stays in the set, so
  // the check can be too permissive but never too strict. That is the safe
  // direction — a missed report rather than a rejected valid program — and it
  // avoids a save/restore discipline over a mutable context that is otherwise
  // append-only.
  $decl ctnames $mut $alloc strs.node
  // How many `$func` bodies enclose the expression being typed. §4.15 makes
  // `$try` outside one a compile error — it returns from "the nearest enclosing
  // `$func`", and at a file's top level or in a prop initializer there is none.
  //
  // Bumped at **all three** places a `$func` body is typed (`infer_func`,
  // `infer_rec_func`, `infer_fwd_body`). Two of them are indented alike and the
  // third is not, which is how a first attempt at this patched two and silently
  // missed one — the exact shape of no-op this file warns about twice.
  $decl fdepth  $mut $alloc 0
  // The key (`fn_key_of`) of the body of the `$func` being typed: §5.3a's owner rule
  // (`owner_check`) leaves a function's own body to R2.
  $decl fbody   $mut $alloc ""
  // DEFER.md: names freed in the function being typed — by `$free`, or passed where a
  // callee frees them — as "depth|name", "|!" appended when not through the root.
  // `func_close` turns its own depth's parameters into `128 + i` in the function's type.
  $decl freed   $mut $alloc strs.node
  // Calls whose callee's result may be storage from an allocator other than the root
  // (its type has 1000), by `fn_key_of` — `root_res` asks.
  $decl nonroot $mut $alloc strs.node
  // How many specialisations are being typed, one inside another. §4.9: "A chain
  // of *distinct* argument types is unbounded; there is a fixed instantiation
  // depth limit and exceeding it is an error." Self-specialisation made the chain
  // reachable; without the limit a template that specialises itself at a growing
  // type would not terminate.
  $decl sdepth  $mut $alloc 0
  // How many times a specialisation has been answered with an entry still in
  // progress — §4.9's "hitting an in-progress entry returns its `R`". Compared
  // across a body's first pass to learn whether the body reached itself.
  $decl sreach  $mut $alloc 0
  // §4.10's receiver: the `$decl` whose initializer is the block about to be typed —
  // its name, its qualifier, and the block literal's span, which is how `infer_block`
  // knows it is that block. `rname` is "" when there is none.
  $decl rname   $mut $alloc ""
  $decl rqual   $mut $alloc ""
  $decl rline   $mut $alloc -1
  $decl rcol    $mut $alloc -1
  // §4.12: an `$impl`'s base, and the span of its override block. That block's receiver is
  // the `$impl`'s result, base and props together, so `infer_block` builds the receiver's
  // type from this when — and only when — it is typing the block at that span.
  $decl rbase   $mut $alloc T.proto_ty
  $decl rbline  $mut $alloc -1
  $decl rbcol   $mut $alloc -1
  // TRAITS.md, design point 7: while a block with a receiver name is typed, `$traitsof` of
  // that name is §5.5's placeholder `stid` — not a trait built from members still being
  // typed, which captured them as ⊥. `stblk` is the block so far, which a projection off
  // the placeholder reads its members from; `stuse` says the placeholder was reached, so
  // `infer_block` closes it into the recursive trait when the block is done.
  $decl stname  $mut $alloc ""
  $decl stid    $mut $alloc -1
  $decl stuse   $mut $alloc $union (false, true)
  $decl stblk   $mut $alloc T.proto_ty
  $decl strps   $mut $alloc st_pairs.node
  // §5.3a for parameters: how many marked parameters are in scope — so a program with
  // none pays nothing for the walks — and the marks that have reached an escape point,
  // each `depth * 64 + index`, until the function at that depth takes its own.
  $decl nmark   $mut $alloc 0
  $decl escd    $mut $alloc T.cints.node
  // §5.3a's borrowing for function- and trait-typed parameters: the marks that reached a
  // function's *result* (`brwd`), which make those parameters borrowed rather than
  // escaping; and, while one call's arguments are checked, the marks and frame-boundness
  // of the arguments its result borrows (`bmarks`, `bframe`).
  $decl brwd    $mut $alloc T.cints.node
  $decl bmarks  $mut $alloc T.cints.node
  $decl bframe  $mut $alloc $union (false, true)
  // Calls to a function still being typed, whose escaping parameters are not known yet:
  // checked when it closes (`func_close`). Function bodies are numbered in the order
  // they start, so one body's own calls — and its nested ones' — are a range.
  $decl pesc    $mut $alloc pesc_list.node
  $decl fser    $mut $alloc 0
  $decl curfn   $mut $alloc 0
  // The function bodies open now, innermost first, and the hints found so far.
  $decl fstack  $mut $alloc fframes.node
  $decl hints   $mut $alloc hint_list.node
  // Functions whose type is still a placeholder, by name and placeholder: a `$decl` of a
  // `$func` while its body is typed, and a `$fwd` until its completion. A call is deferred
  // only to one of these *by name* — a placeholder result alone is not an identity, since
  // a function returning a call to another shares that one's.
  $decl inprog  $mut $alloc hint_list.node
  // §4.16 rule 2. The section makes capture-freeness "a property of the
  // *expression* in the argument position", holding "when the compiler can see
  // which `$func` literal the value came from" — so the check is syntactic, and
  // these three sets are what it can see.
  //
  // `extnames` is the names bound to an `$extern`, which is how a call site
  // knows it is crossing into C: §4.16's signature is an ordinary `$func` type
  // and carries nothing to say so. `cffns` maps a name to the `$func` **literal**
  // its `$decl` gave it — the literal itself, not a verdict about it, since the
  // capture analysis is two AST walks and is wanted only for an argument that
  // actually crosses. `topnames` is the names bound at a file's top
  // level, which lowering lifts to globals — reading one is not a capture
  // (§7.3), so they are what the captured set is taken modulo.
  //
  // All three grow and never shrink, like `ctnames` above, and all three err
  // the same way: `topnames` too large, or `cffns` answering for a name that is
  // no longer the one in scope, means a capture missed,
  // which §5.3a's scope-blind `Pa.bound_names` already accepts as the right
  // direction. `extnames` too large is the one that could reject a valid
  // program, and takes a call to an unrelated name spelled like an extern.
  $decl extnames $mut $alloc strs.node
  $decl cffns    $mut $alloc fnlit_list.node
  $decl topnames $mut $alloc strs.node
  // §5.3a's provenance (`owns_x`): the positions — file, line and column — of call results
  // and arguments whose type contains a place. It is the one type fact the provenance walk
  // needs. Grows and never shrinks: a position typed more than once (a specialised body)
  // is recorded if any typing found a place, which can only make the walk stricter.
  $decl placed   $mut $alloc strs.node
  // §7.6: the `$alloc` sites whose `allocator` is not the root's, by file short name, line
  // and column. Inference decides it, in §4.10's source order, and hands the set to
  // lowering, whose entry-file globals are bound up front and so could not decide it the
  // same way (`lower_ok`).
  $decl ualloc   $mut $alloc strs.node
  // §6's coercion of a value — not a reference — to a trait parameter: the object refers to
  // the argument's own storage, a name's slot or fresh frame storage, rather than to a
  // place the argument holds. By position, for `owns_arg`.
  $decl slotref  $mut $alloc strs.node
}

$decl proto_ctx $call ctx ()

$decl eval_diags $func ($decl x Pa.diags.node) x
$decl eval_tmpls $func ($decl x tmpl_list.node) x
$decl eval_memo  $func ($decl x memo_list.node) x
$decl eval_mods  $func ($decl x mod_list.node) x
$decl eval_fwds  $func ($decl x fwd_list.node) x
$decl eval_res   $func ($decl x res_list.node) x
$decl eval_defer $func ($decl x def_list.node) x
$decl sval       P.sval

$decl fresh $func ($decl cx proto_ctx) {
  $decl i      $call ival (cx.next)
  $decl bumped $set cx.next ($call add (i, 1))
  $decl ret    i
}.ret

$decl bval $func ($decl b P.boolean) b

$decl err $func ($decl cx proto_ctx, $decl m "", $decl x P.proto_span) {
  $decl noted $if ($call bval (cx.quiet)) ()
      ($set cx.errs ($call Pa.diags.cons ($call Pa.diag (m, x.line, x.col, cx.file), cx.errs)))
  $decl ret   T.t_bot
}.ret

// §5.5: park a check whose types still mention an unresolved placeholder. It is
// re-run once the knot is tied, and reported then if it fails.
$decl defer_check $func ($decl cx proto_ctx, $decl a T.proto_ty, $decl b T.proto_ty,
                         $decl m "", $decl x P.proto_span) {
  $decl noted $set cx.defer ($call def_list.cons ($call def_ent (x.line, x.col, m, a, b),
                                                  $call eval_defer (cx.defer)))
  $decl ret T.t_unit
}.ret

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

// §5.5's occurrence check. It belongs to the type language, so it lives in
// `types.mpl` — lowering needs it too, now that a specialised template's types
// are derived rather than handed over (§4.9).
$decl occurs T.occurs

$fwd hfv

$decl hfv_tys $func ($decl xs T.tys.node) $match xs (
  $case {$prop tag "cons"} $if ($call hfv (xs.head)) true ($call hfv_tys (xs.tail)),
  $case xs false
)

$decl hfv_fields $func ($decl xs T.fields.node) $match xs (
  $case {$prop tag "cons"} $if ($call hfv (xs.head.ty)) true ($call hfv_fields (xs.tail)),
  $case xs false
)

// Does the type still mention a placeholder that nothing has resolved? A
// variable bound by an enclosing `rec` is not one — that knot is already tied —
// and now it is not a `var` either: tying the knot turns it into a de Bruijn
// index, so every `var` left is by construction unresolved.
$decl hfv $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "var"}   true,
  $case {$prop tag "rec"}   $call hfv (t.body),
  $case {$prop tag "block"} $call hfv_fields (t.fields),
  $case {$prop tag "group"} $call hfv_tys (t.items),
  $case {$prop tag "func"}  $if ($call hfv_tys (t.params)) true ($call hfv (t.result)),
  $case {$prop tag "ref"}   $call hfv (t.inner),
  $case {$prop tag "array"} $call hfv (t.elem),
  $case {$prop tag "union"} $call hfv_tys (t.members),
  $case {$prop tag "inter"} $call hfv_tys (t.members),
  $case {$prop tag "over"}  $call hfv_tys (t.cands),
  $case t false
)

$decl has_free_var $func ($decl t T.proto_ty) $call hfv (t)

// Every `μ` in a program is tied here, so this is where §5.5's rule that
// recursion must pass through storage is enforced: the type is reported if its
// own binder is reachable without going through a reference. Inference is still
// total — the type is returned either way — and what failed is the layout of
// the type it produced, not the inference of it.
$decl close_rec $func ($decl cx proto_ctx, $decl t T.proto_ty, $decl i 0, $decl x P.proto_span) {
  // `μR. A | R` is `A` (see `T.drop_var`), so simplify before deciding whether
  // a binder is needed at all.
  $decl r   $call T.drop_var (t, i)
  // A prop's type counts as well: a prototype naming itself only in a member's parameter
  // (§4.10) is recursive, and `$traitsof` needs the μ to find `Self` in it.
  $decl ret $if ($if ($call occurs (r, i)) true ($call T.occurs_own_props (r, i))) {
    // Closing over a type that is already a `μ` reuses its binder, since `μx. μy. F(x, y)`
    // is `μy. F(y, y)`: the placeholder is the whole result, and so is the `μ`'s own
    // variable. A list wrapper's `of` is the case (`T.occurs_own_props`), and two binders
    // for one type would make it two types.
    $decl m     $match r (
        $case {$prop tag "rec"} ($call T.t_rec ($call T.remap (r.body, $call T.rop_abs (i), 0))),
        $case r ($call T.close_var (r, i))
      )
    $decl noted $if ($call T.unguarded_rec (m))
        ($call err (cx, $call concat (
            "this recursive type has no layout: it recurs through a value, not storage. Write $new at the recursive position (§5.5). Inferred ",
            $call T.show (m)), x))
        T.t_bot
    $decl ret2   m
  }.ret2
      r
}.ret

// ------------------------------------------------------------------ helpers

// A parameter's type is the type of its default (§5.7), and narrowing does not
// cross a call: a helper handed a `$match` arm's already-narrowed node still
// sees the whole `proto_node` union unless its parameter says otherwise. These
// are the shapes the helpers below are only ever called with.
$decl proto_form  $call Pa.n_form ("", Pa.nodes.nil, 0, 0)
$decl proto_projn $call Pa.n_projn (Pa.proto_node, "", 0, 0)
$decl proto_proji $call Pa.n_proji (Pa.proto_node, 0, 0, 0)

$decl is_form $func ($decl n Pa.proto_node, $decl k "") $match n (
  $case {$prop tag "form"} $call eq_str (n.keyword, k),
  $case n false
)

// Total, because a caller walking a list of block items has only `$if
// is_form (…)` to go on and §4.7 narrows a `$match` scrutinee, not an `$if`
// condition. Anything without operands answers with an error node, which keeps
// inference total (§5.5) rather than turning a caller's mistake into a halt.
$decl op $func ($decl n Pa.proto_node, $decl i 0) $match n (
  $case {$prop tag "form"} $call Pa.nodes.nth (n.operands, i),
  $case n ($call Pa.n_err ("not a form", 0, 0))
)

$decl name_of $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "name"} n.text,
  $case n ""
)

// §4.14's operand is a string literal, not a name — a different node shape
// carrying a field of the same name.
$decl str_of $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "str"} n.text,
  $case n ""
)

// §2.4 with §2.3: the syntactic shape of a group decides the count, so `()` is
// none, a group is its elements, and anything else is one.
// §5.4 keeps a reference where nothing expects a value, and a function result
// is such a place — so returning the boxed `items` from one arm and a fresh
// list from another would give this a union type. `val` is the value-expecting
// position that settles it.
$decl group_items $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "unit"}  Pa.nodes.nil,
  $case {$prop tag "group"} ($call Pa.nodes.val (n.items)),
  $case n ($call Pa.nodes.cons (n, Pa.nodes.nil))
)

// ------------------------------------------------------- the typed root block
//
// BOOTSTRAP.md §2's monomorphic root block, with types. §8 defines the numeric
// intrinsics as `$overload` sets; dropping float arithmetic is what lets each
// of these be a single function type.

$decl ii_i $call T.t_func ($call T.tys.cons (T.t_int, $call T.tys.cons (T.t_int, T.tys.nil)),
    T.t_int)
$decl ii_b $call T.t_func ($call T.tys.cons (T.t_int, $call T.tys.cons (T.t_int, T.tys.nil)),
    T.t_bool)
$decl ss_b $call T.t_func ($call T.tys.cons (T.t_str, $call T.tys.cons (T.t_str, T.tys.nil)),
    T.t_bool)
$decl ss_s $call T.t_func ($call T.tys.cons (T.t_str, $call T.tys.cons (T.t_str, T.tys.nil)),
    T.t_str)
$decl i_i $call T.t_func ($call T.tys.cons (T.t_int, T.tys.nil), T.t_int)
$decl s_i $call T.t_func ($call T.tys.cons (T.t_str, T.tys.nil), T.t_int)
$decl i_s $call T.t_func ($call T.tys.cons (T.t_int, T.tys.nil), T.t_str)
$decl si_i $call T.t_func ($call T.tys.cons (T.t_str, $call T.tys.cons (T.t_int, T.tys.nil)),
    T.t_int)
$decl sii_s $call T.t_func ($call T.tys.cons (T.t_str,
                            $call T.tys.cons (T.t_int, $call T.tys.cons (T.t_int,
                                T.tys.nil))), T.t_str)
$decl s_u   $call T.t_func ($call T.tys.cons (T.t_str, T.tys.nil), T.t_unit)
$decl s_bot $call T.t_func ($call T.tys.cons (T.t_str, T.tys.nil), T.t_bot)

// §4.15's shapes, and the `option` that §8 requires failing operations to use.
$decl t_none $call T.tag_block ("tag", "none")
$decl t_err  $call T.tag_block ("tag", "err")

$decl some_of $func ($decl t T.proto_ty)
  $call T.t_block ($call T.f1 ("v", t), $call T.p1 ("tag", $call T.cv_str ("some")))

$decl opt_int $call T.union2 (t_none, $call some_of (T.t_int))
$decl opt_str $call T.union2 (t_none, $call some_of (T.t_str))

// §8's numeric intrinsics are overloads over `(Int,Int)` and `(Float,Float)`, with no
// implicit conversion; `eq`, `to_int` and `to_str` are overloaded too. The bootstrap's own
// monomorphic names (`eq_int`, `eq_str`, `int_to_str`, `str_to_int`) stay beside them.
$decl ff_f $call T.t_func ($call T.tys.cons (T.t_float, $call T.tys.cons (T.t_float, T.tys.nil)),
    T.t_float)
$decl ff_b $call T.t_func ($call T.tys.cons (T.t_float, $call T.tys.cons (T.t_float, T.tys.nil)),
    T.t_bool)
$decl bb_b $call T.t_func ($call T.tys.cons (T.t_bool, $call T.tys.cons (T.t_bool, T.tys.nil)),
    T.t_bool)
$decl f_f  $call T.t_func ($call T.tys.cons (T.t_float, T.tys.nil), T.t_float)
$decl i_f  $call T.t_func ($call T.tys.cons (T.t_int, T.tys.nil), T.t_float)
$decl f_s  $call T.t_func ($call T.tys.cons (T.t_float, T.tys.nil), T.t_str)
$decl s_oi $call T.t_func ($call T.tys.cons (T.t_str, T.tys.nil), opt_int)
$decl f_oi $call T.t_func ($call T.tys.cons (T.t_float, T.tys.nil), opt_int)
$decl ov2  $func ($decl a T.proto_ty, $decl b T.proto_ty)
  $call T.t_over ($call T.tys.cons (a, $call T.tys.cons (b, T.tys.nil)))
$decl num2 $call ov2 (ii_i, ff_f)
$decl cmp2 $call ov2 (ii_b, ff_b)
$decl num1 $call ov2 (i_i, f_f)
$decl eq4  $call T.t_over ($call T.tys.cons (ii_b, $call T.tys.cons (ff_b,
               $call T.tys.cons (ss_b, $call T.tys.cons (bb_b, T.tys.nil)))))
$decl toint $call ov2 (s_oi, f_oi)
$decl tostr $call ov2 (i_s, f_s)

// §8's arrays are polymorphic, so `array`, `at`, `alen` and `array_ptr` are bound at
// markers (`T.ffi_array` and the rest) and each call is typed in `infer_ffi`. `args` and
// `run` are `[Str]`: what the host hands over is strings. §7.6 makes `at` return a
// base+index handle rather than an interior pointer, which is a reference — so reading
// one is §5.4's transparency, and `$decl p $call at (a, 0)` binds a reference, not a copy.
$decl arr_str $call T.t_array (T.t_str)
$decl args_t  $call T.t_func (T.tys.nil, arr_str)

// §8's FFI addresses are `Int`s — §3.1 has one integer type, and an address is one
// as far as `$extern`'s ABI mapping is concerned. `str_ptr` is monomorphic; `box_ptr`,
// `unbox` and `array_ptr` are bound at markers and typed in `infer_ffi`.

// `str_from_ptr (addr, n)`: §4.16's "bytes received from C become a `Str` only
// through a validating library function returning `option Str`".
$decl strf_t  $call T.t_func ($call T.tys.cons (T.t_int, $call T.tys.cons (T.t_int, T.tys.nil)),
                  opt_str)

// §8's raw memory, for an allocator written in morphl (§7.6): `raw_alloc (n)` answers an
// address, 0 when none is to be had, and `raw_free (addr)` gives one back.
$decl ralloc_t $call T.t_func ($call T.tys.cons (T.t_int, T.tys.nil), T.t_int)
$decl rfree_t  $call T.t_func ($call T.tys.cons (T.t_int, T.tys.nil), T.t_unit)
// DEFER.md: the root's `defer_at (addr, fin)`, the runtime's table `raw_free` runs.
$decl rdefer_t $call T.t_func ($call T.tys.cons (T.t_int, $call T.tys.cons (
                   $call T.t_func (T.tys.nil, T.t_unit), T.tys.nil)), T.t_unit)

// BOOTSTRAP §2's `run (argv)`: the process's exit status, or `none` when it could
// not be started.
$decl run_t   $call T.t_func ($call T.tys.cons (arr_str, T.tys.nil), opt_int)

$decl root_env
  $call bind ($call bind ($call bind ($call bind ($call bind ($call bind (
  $call bind ($call bind ($call bind (
  $call bind ($call bind ($call bind ($call bind ($call bind ($call bind (
  $call bind ($call bind ($call bind ($call bind ($call bind (
  $call bind ($call bind ($call bind ($call bind (
  $call bind (
  $call bind ($call bind ($call bind ($call bind ($call bind ($call bind (
  $call bind ($call bind ($call bind ($call bind ($call bind ($call bind (
  $call bind ($call bind ($call bind ($call bind ($call bind ($call bind (
  $call bind ($call bind ($call bind ($call bind ($call bind ($call bind (
  $call bind ($call bind (env.nil,
    "add", num2), "sub", num2), "mul", num2), "div", num2), "mod", num2), "neg", num1),
    "lt", cmp2), "eq", eq4), "to_float", i_f), "to_int", toint), "to_str", tostr),
    "str_ptr", s_i), "str_from_ptr", strf_t), "array_ptr", T.ffi_aptr), "box_ptr", T.ffi_box), "unbox", T.ffi_unbox),
    "run", run_t), "raw_alloc", ralloc_t), "raw_free", rfree_t), "allocator", T.ffi_alloc),
    "add_wrap", ii_i), "sub_wrap", ii_i), "mul_wrap", ii_i),
    "add_sat", ii_i), "sub_sat", ii_i), "mul_sat", ii_i),
    "band", ii_i), "bor", ii_i), "bxor", ii_i), "shl", ii_i), "shr", ii_i),
    "eq_int", ii_b), "eq_str", ss_b), "concat", ss_s), "len", s_i),
    "slice", sii_s), "byte", si_i), "int_to_str", i_s),
    "str_to_int", $call T.t_func ($call T.tys.cons (T.t_str, T.tys.nil), opt_int)),
    "from_code", $call T.t_func ($call T.tys.cons (T.t_int, T.tys.nil), opt_str)),
    "panic", s_bot), "print", s_u), "eprint", s_u),
    "read_file", $call T.t_func ($call T.tys.cons (T.t_str, T.tys.nil), opt_str)),
    "write_file", $call T.t_func ($call T.tys.cons (T.t_str, $call T.tys.cons (T.t_str, T.tys.nil)),
                                  $call T.union2 (T.t_unit, t_err))),
    "array", T.ffi_array), "at", T.ffi_at), "alen", T.ffi_alen), "args", args_t),
    "err", t_err), "none", t_none)

// ------------------------------------------------------------------ the walk

$fwd infer

$decl infer_tys $func ($decl cx proto_ctx, $decl e env.node, $decl xs Pa.nodes.node,
    $decl acc T.tys.node) $match xs (
  $case {$prop tag "cons"}
    $call infer_tys (cx, e, xs.tail, $call T.tys.cons ($call infer (cx, e, xs.head), acc)),
  $case xs ($call T.tys.reverse (acc, T.tys.nil))
)

// §4.6: projection reaches `$decl` fields and props uniformly (§4.10).

$fwd proj_one

$decl proj_members $func ($decl cx proto_ctx, $decl ms T.tys.node, $decl fld "",
                          $decl n Pa.proto_node, $decl acc T.proto_ty) $match ms (
  $case {$prop tag "cons"}
    $call proj_members (cx, ms.tail, fld, n, $call T.join (acc, $call proj_one (cx, ms.head, fld,
        n))),
  $case ms acc
)

$decl needs_mut $func ($decl t T.proto_ty) $match t ($case {$prop tag "func"} t.rmut, $case t false)

// A member off the self-trait placeholder, read from the block typed so far — the same
// members the trait will have once it is closed (`close_self`). ⊥ before the block's type
// exists, which is the provisional pass's, whose diagnostics are swallowed.
$decl proj_self $func ($decl cx proto_ctx, $decl fld "", $decl n Pa.proto_node) {
  $decl tr  $call T.trait_of ($call T.tval (cx.stblk), false, "")
  $decl ret $match tr (
      $case {$prop tag "trait"} {
        $decl f    $call T.find_field (tr.members, fld)
        $decl ret2 $if ($call eq_str (f.name, ""))
            ($call err (cx, $call concat ("this trait has no member '", $call concat (fld, "'")), n))
            ($call T.trait_member (tr, fld, $call T.t_var ($call ival (cx.stid))))
      }.ret2,
      $case tr T.t_bot)
}.ret

$decl proj_one $func ($decl cx proto_ctx, $decl tt T.proto_ty, $decl fld "",
    $decl n Pa.proto_node) $match tt (
  $case {$prop tag "block"} {
    $decl f $call T.find_field (tt.fields, fld)
    $decl ret $if ($call not ($call eq_str (f.name, ""))) f.ty {
      $decl p $call T.find_prop (tt.props, fld)
      $decl ret2 $if ($call not ($call eq_str (p.name, ""))) p.ty
          ($call err (cx, $call concat ("block has no field '",
                       $call concat (fld, "'")), n))
    }.ret2
  }.ret,
  // A union is usable wherever all of its members are (§5.1), so a field that
  // every member carries is projectable from the union itself — which is the
  // whole point of every node beginning with the same `line`/`col` prefix.
  // A member without the field reports on its own behalf.
  $case {$prop tag "union"} $call proj_members (cx, tt.members, fld, n, T.t_bot),
  // Projection is the one place a recursive type has to be looked inside.
  $case {$prop tag "rec"}   $call proj_one (cx, $call T.unroll (tt), fld, n),
  // §6: a trait object is read through its members, every one of them: a trait is its
  // members' signatures as written, so every implementation has its shape (TRAITS.md).
  $case {$prop tag "trait"} {
    $decl f   $call T.find_field (tt.members, fld)
    $decl ret $if ($call eq_str (f.name, ""))
        ($call err (cx, $call concat ("this trait has no member '", $call concat (fld, "'")), n))
        ($if ($call P.and ($call needs_mut ($call T.tval (f.ty)), $call eq_str (tt.qual, "")))
             ($call err (cx, $call concat ("member '", $call concat (fld,
                 "' needs a mutable receiver, and this trait object is read-only (§4.10, §6)")),
                 n))
             ($call T.trait_member (tt, fld, tt)))
  }.ret,
  // §4.12: an added prop, or else whatever the base has.
  $case {$prop tag "with"} {
    $decl p   $call T.find_prop ($call T.props.val (tt.props), fld)
    $decl ret $if ($call eq_str (p.name, "")) ($call proj_one (cx, $call T.tval (tt.base), fld, n))
                  ($call T.tval (p.ty))
  }.ret,
  // The self-trait placeholder (design point 7): its members are the block's so far.
  $case {$prop tag "var"}
    $if ($call eq_int (tt.id, $call ival (cx.stid))) ($call proj_self (cx, fld, n))
        ($call err (cx, $call concat ("cannot project '.",
            $call concat (fld, $call concat ("' from ", $call T.show (tt)))), n)),
  $case tt ($call err (cx, $call concat ("cannot project '.",
                $call concat (fld, $call concat ("' from ", $call T.show (tt)))), n))
)

$decl is_block_node $func ($decl n Pa.proto_node)
  $match n ($case {$prop tag "block"} true, $case n false)

// §5.3a's owners (DEFER.md): a value projected out of a block literal that is discarded
// may not hold a place one of that block's fields owns. Below, beside the walk it uses.
$fwd owner_check

// §7.6: the root `allocator`'s members are §8's raw-memory intrinsics.
$decl infer_proj_name $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_projn) {
  $decl t   $call deref_ty ($call infer (cx, e, n.target))
  $decl oc  $call owner_check (cx, n)
  $decl ret $if ($call T.same (t, T.ffi_alloc))
      ($if ($call eq_str (n.field, "alloc")) ralloc_t
      ($if ($call eq_str (n.field, "free")) rfree_t
      ($if ($call eq_str (n.field, "defer_at")) rdefer_t
           ($call err (cx, $call concat ("the root allocator has no member '",
                $call concat (n.field, "'; it has alloc, free and defer_at (§7.6)")), n)))))
      ($call proj_one (cx, t, n.field, n))
}.ret

$decl infer_proj_index $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_proji) {
  $decl tt $call T.with_base ($call deref_ty ($call infer (cx, e, n.target)))
  $decl ret $match tt (
      $case {$prop tag "group"}
        $if ($call and ($call lt (0, n.index), $call not ($call lt ($call T.tys.length (tt.items,
            0), n.index))))
            ($call T.tys.nth (tt.items, $call sub (n.index, 1)))
            ($call err (cx, "group index is out of range", n)),
      // §4.8: an overload is its group of candidates, and `x.i` names one.
      $case {$prop tag "over"}
        $if ($call and ($call lt (0, n.index), $call not ($call lt ($call T.tys.length (tt.cands,
            0), n.index))))
            ($call T.tys.nth (tt.cands, $call sub (n.index, 1)))
            ($call err (cx, "overload index is out of range", n)),
      $case tt ($call err (cx, $call concat ("cannot index into ", $call T.show (tt)), n))
    )
}.ret

// §5.3a's closure clause: "A `$func` literal that captures a frame reference is
// itself frame-bound, so a closure cannot carry one out either (§7.3)."
//
// §7.3 keeps captures out of the function *type* — that is what makes every
// function value two words — so the fact has to be recorded on the type by
// hand, and `t_func`'s `frame` flag is where. What a literal captures is the
// free names of its body, less the names bound inside it and less its own
// parameters; `Pa.bound_names` is deliberately scope-blind, so a name both
// captured and shadowed deeper in is missed rather than wrongly reported.
$decl param_names $func ($decl ps Pa.nodes.node, $decl acc Pa.pstrs.node) $match ps (
  $case {$prop tag "cons"} {
    $decl nm $if ($call is_form (ps.head, "decl"))
                 ($call name_of ($call op (ps.head, 0))) ""
    $decl a2  $if ($call eq_str (nm, "")) acc ($call Pa.pstrs.cons (nm, acc))
    $decl ret $call param_names ($call Pa.nodes.val (ps.tail), a2)
  }.ret,
  $case ps acc
)

$decl caps_frame $func ($decl cx proto_ctx, $decl e env.node, $decl ns Pa.pstrs.node,
                        $decl skip Pa.pstrs.node) $match ns (
  $case {$prop tag "cons"} {
    $decl skipped $call Pa.mem_pstr (skip, ns.head)
    $decl f       $if skipped ($call found (false, T.t_bot)) ($call lookup (e, ns.head))
    $decl hit     $if f.ok ($call T.frame_bound (f.ty, 0)) false
    $decl ret     $if hit true ($call caps_frame (cx, e, $call Pa.pstrs.val (ns.tail), skip))
  }.ret,
  $case ns false
)

// §4.16 rule 2: "C callbacks must be capture-free." §7.3 keeps captures out of
// the type, so the rule is stated on the *expression* in the argument position —
// it "holds when the compiler can see which `$func` literal the value came from,
// and a closure arriving through a mutable function slot is rejected because it
// cannot be seen". Everything below is that sentence made mechanical.
$decl in_strs $func ($decl xs strs.node, $decl n "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head, n)) true ($call in_strs (xs.tail, n)),
  $case xs false
)

// §4.13: `$traitsof e` makes a trait object referring to `e`, or — when `e` is not a name
// or a reference — to fresh frame storage holding its value, as `$new e` would. Its type is
// `e`'s props' signatures with `e`'s own type abstracted as `Self`.
// Whether the object made is frame-bound (§5.3a): a reference has its own kind; a name
// bound in a function frame is frame; anything else is `$new`'s frame storage there.
$decl traitsof_frame $func ($decl cx proto_ctx, $decl x Pa.proto_node, $decl t0 T.proto_ty)
    $match t0 (
  $case {$prop tag "ref"} ($call not ($call T.is_alloc (t0.kind))),
  $case t0 $if ($call eq_int ($call ival (cx.fdepth), 0)) false
      ($match x (
          $case {$prop tag "name"} ($call not ($call in_strs ($call strs.val (cx.topnames), x.text))),
          $case x true))
)

// §6's coercion makes a trait object referring to the value, so a value that is not
// already one must be referable — a name or a reference — since §5.4 never turns a value
// into storage implicitly. "" when the coercion is fine or is not one.
$decl coerce_why $func ($decl x Pa.proto_node, $decl raw T.proto_ty, $decl want T.proto_ty) {
  $decl v   $call deref_ty (raw)
  $decl ret $if ($call and ($call T.is_trait (want), $call not ($call T.is_trait (v))))
      ($match raw (
          $case {$prop tag "ref"} "",
          $case raw $match x (
              $case {$prop tag "name"} "",
              $case x "a trait object refers to its value, so this must be a name or a reference (§6); $traitsof makes one from an expression"
            )
        ))
      ""
}.ret

// Both below, beside the helpers they need.
$fwd infer_traitsof_of
$fwd infer_traitsof_ty

$decl self_trait_at $func ($decl cx proto_ctx, $decl x Pa.proto_node) $match x (
  $case {$prop tag "name"}
    $if ($call eq_str ($call sval (cx.stname), "")) false
        ($call eq_str (x.text, $call sval (cx.stname))),
  $case x false
)

$decl infer_traitsof $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form)
  $if ($call self_trait_at (cx, $call op (n, 0)))
      ($do ($set cx.stuse true) ($call T.t_var ($call ival (cx.stid))))
      ($call infer_traitsof_of (cx, e, n))

// Whether `id` is a specialisation's placeholder still in the memo, and the trait
// placeholder already recorded for it, or -1.
$decl memo_has_var $func ($decl xs memo_list.node, $decl id 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_int ($call var_id (xs.head.ty), id)) true ($call memo_has_var (xs.tail, id)),
  $case xs false
)
$decl rt_for $func ($decl xs st_pairs.node, $decl ph 0) $match xs (
  $case {$prop tag "cons"} $if ($call eq_int (xs.head.ph, ph)) xs.head.rt ($call rt_for (xs.tail, ph)),
  $case xs -1
)
$decl spec_self_trait $func ($decl cx proto_ctx, $decl ph 0) {
  $decl have $call rt_for ($call st_pairs.val (cx.strps), ph)
  $decl rt   $if ($call lt (-1, have)) have ($call fresh (cx))
  $decl put  $set cx.strps ($if ($call lt (-1, have)) ($call st_pairs.val (cx.strps))
                 ($call st_pairs.cons ($call st_pair (ph, rt), cx.strps)))
  $decl ret  $call T.t_var (rt)
}.ret

$decl infer_traitsof_of $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl x   $call op (n, 0)
  $decl t0  $call infer (cx, e, x)
  $decl t   $call deref_ty (t0)
  $decl pv  $call var_id (t)
  $decl ret $if ($if ($call lt (-1, pv)) ($call memo_has_var ($call eval_memo (cx.memo), pv)) false)
      ($call spec_self_trait (cx, pv)) ($call infer_traitsof_ty (cx, x, t0, t, n))
}.ret

$decl infer_traitsof_ty $func ($decl cx proto_ctx, $decl x Pa.proto_node, $decl t0 T.proto_ty,
                               $decl t T.proto_ty, $decl n proto_form) {
  $decl fr  $call traitsof_frame (cx, x, t0)
  // §6: "one made from `$mut` storage is mutable".
  $decl tr  $call T.tval (t0)
  $decl q   $match tr ($case {$prop tag "ref"} ($if ($call eq_str (tr.qual, "mut")) "mut" ""),
                       $case tr "")
  $decl tt  $call T.trait_of (t, fr, q)
  $decl ret $if ($call T.is_trait (tt)) tt
      ($call err (cx, $call concat ("$traitsof needs a block, found ", $call T.show (t)), n))
}.ret

// §4.12: every member the trait describes, each at a subtype of the trait's member type.
// No defaults, so a missing member is an error.
$decl impl_members $func ($decl cx proto_ctx, $decl ms T.fields.node, $decl ps T.props.node,
    $decl tr T.proto_ty, $decl rt T.proto_ty, $decl n proto_form) $match ms (
  $case {$prop tag "cons"} {
    $decl nm   ms.head.name
    $decl p    $call T.find_prop (ps, nm)
    $decl want $call T.trait_member (tr, nm, tr)
    $decl chk  $if ($call eq_str (p.name, ""))
        ($call err (cx, $call concat ("this $impl does not implement '", $call concat (nm,
            "', and a trait has no defaults (§4.12)")), n))
        ($if ($call T.sub ($call T.tval (p.ty), want)) T.t_unit
             ($do ($call T.explain ($call T.tval (p.ty), want))
                  ($call err (cx, $call concat ("member '", $call concat (nm, $call concat (
                      "' of this $impl is ", $call concat ($call T.show ($call T.tval (p.ty)),
                      $call concat (", but the trait wants ", $call T.show (want)))))), n))))
    $decl ret  $call impl_members (cx, $call T.fields.val (ms.tail), ps, tr, rt, n)
  }.ret,
  $case ms T.t_unit
)

// ...and nothing else, and nothing the base already binds (§4.1).
$decl impl_extras $func ($decl cx proto_ctx, $decl ps T.props.node, $decl ms T.fields.node,
    $decl bt T.proto_ty, $decl n proto_form) $match ps (
  $case {$prop tag "cons"} {
    $decl nm   ps.head.name
    $decl chk  $if ($call T.binds_name (bt, nm))
        ($call err (cx, $call concat ("'", $call concat (nm,
            "' is already bound by the $impl's base, so this binds it twice (§4.1)")), n))
        ($if ($call eq_str (($call T.find_field (ms, nm)).name, ""))
             ($call err (cx, $call concat ("'", $call concat (nm,
                 "' is not a member of the trait this $impl implements (§4.12)")), n))
             T.t_unit)
    $decl ret  $call impl_extras (cx, $call T.props.val (ps.tail), ms, bt, n)
  }.ret,
  $case ps T.t_unit
)

// §4.12: `$impl x trait override` is `x`'s value at `x`'s type with `override`'s props
// added. `trait` is type-only (§5.7). The override's receiver is the result, which is why
// its block is told the base before it is typed.
$decl infer_impl $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl bt  $call deref_ty ($call infer (cx, e, $call op (n, 0)))
  $decl tr  $call T.tval ($call infer (cx, e, $call op (n, 1)))
  $decl ov  $call op (n, 2)
  $decl sp  $call P.span_of (ov)
  $decl sb  $do ($set cx.rbase bt) ($do ($set cx.rbline sp.line) ($set cx.rbcol sp.col))
  $decl ot  $call T.tval ($call infer (cx, e, ov))
  // `{}` is `()` (§2.1), so an empty override arrives as unit, with no props.
  $decl ok  $match ot (
      $case {$prop tag "block"} ($call T.fields.is_nil ($call T.fields.val (ot.fields))),
      $case {$prop tag "unit"}  true,
      $case ot false
    )
  $decl ps  $match ot ($case {$prop tag "block"} ($call T.props.val (ot.props)), $case ot T.props.nil)
  $decl rt  $call T.impl_ty (bt, ps)
  $decl ret $if ($call not (ok))
      ($call err (cx, "an $impl's override is a block of props only (§4.12)", n))
      ($match tr (
          $case {$prop tag "trait"} {
            $decl ms   $call T.fields.val (tr.members)
            $decl a    $call impl_members (cx, ms, ps, tr, rt, n)
            $decl b    $call impl_extras (cx, ps, ms, bt, n)
            $decl ret2 rt
          }.ret2,
          $case tr ($call err (cx, $call concat ("an $impl implements a trait, and this is ",
              $call concat ($call T.show (tr), " — write $traitsof (§4.12)")), n))
        ))
}.ret

// The first name a `$func` literal captures, or "". A free name of the body is a
// capture unless the literal binds it — a parameter, or a `$decl` inside — or it
// is a **global**: a file top-level `$decl` or a root-block intrinsic, which §7.3
// reaches through a static rather than through the environment word.
$decl first_cap $func ($decl cx proto_ctx, $decl ns Pa.pstrs.node, $decl skip Pa.pstrs.node)
  $match ns (
    $case {$prop tag "cons"} {
      $decl nm ns.head
      $decl gl $call lookup (root_env, nm)
      $decl ok $if ($call Pa.mem_pstr (skip, nm)) true
                   ($if ($call in_strs ($call strs.val (cx.topnames), nm)) true gl.ok)
      $decl ret  $if ok ($call first_cap (cx, $call Pa.pstrs.val (ns.tail), skip)) nm
    }.ret,
    $case ns ""
  )

$decl lit_caps $func ($decl cx proto_ctx, $decl n Pa.proto_node) {
  $decl ps   $call group_items ($call op (n, 0))
  $decl free $call Pa.free_names ($call op (n, 1), Pa.pstrs.nil)
  $decl shad $call Pa.bound_names ($call op (n, 1), $call param_names (ps, Pa.pstrs.nil))
  $decl ret  $call first_cap (cx, free, shad)
}.ret

// "Can the compiler see which `$func` literal this came from?" A literal, yes. A
// name bound to one by a `$decl`, yes — `cffns` is that set. Anything else is no,
// and that is the whole of what rule 2 rejects: a call's result, a projection, a
// read through a `$mut` slot. There is no partial answer, which is the point —
// captures are by copy and static per literal, so seeing the literal is seeing
// the captured set.
$decl cb_ok $func ($decl cx proto_ctx, $decl a Pa.proto_node) $match a (
  $case {$prop tag "form"}
    $if ($call eq_str (a.keyword, "func")) ($call eq_str ($call lit_caps (cx, a), "")) false,
  $case {$prop tag "name"} {
    $decl f $call find_fnlit ($call fnlit_list.val (cx.cffns), a.text)
    $decl ret $if ($call eq_str (f.name, "")) false
                ($call eq_str ($call lit_caps (cx, f.lit), ""))
  }.ret,
  $case a false
)

$decl cb_why $func ($decl cx proto_ctx, $decl a Pa.proto_node) $match a (
  $case {$prop tag "form"}
    $if ($call eq_str (a.keyword, "func"))
        ($call concat ("it captures ", $call lit_caps (cx, a)))
        "the compiler cannot see which $func literal it is",
  $case {$prop tag "name"} {
    $decl f $call find_fnlit ($call fnlit_list.val (cx.cffns), a.text)
    $decl ret $if ($call eq_str (f.name, ""))
                ($call concat (a.text, " is not a $decl of a $func literal"))
                ($call concat (a.text, $call concat (" captures ",
                    $call lit_caps (cx, f.lit))))
  }.ret,
  $case a "the compiler cannot see which $func literal it is"
)

$decl is_fn_ty $func ($decl t T.proto_ty) $match t ($case {$prop tag "func"} true, $case t false)

$decl tys_head $func ($decl ts T.tys.node) $match ts (
  $case {$prop tag "cons"} ($call T.tval (ts.head)),
  $case ts T.t_bot
)

$decl tys_rest $func ($decl ts T.tys.node) $match ts (
  $case {$prop tag "cons"} ($call T.tys.val (ts.tail)),
  $case ts T.tys.nil
)

// Applied only where the callee is an extern, because it is only there that §7.3's
// pair has nowhere to go — an ordinary morphl call carries the environment word.
$decl chk_cbs $func ($decl cx proto_ctx, $decl ts T.tys.node, $decl as Pa.nodes.node)
  $match as (
    $case {$prop tag "cons"} {
      $decl pt  $call deref_ty ($call tys_head (ts))
      $decl bad $if ($call is_fn_ty (pt)) ($call not ($call cb_ok (cx, as.head))) false
      $decl rep $if bad ($call err (cx,
                    $call concat ("a callback passed to C must be capture-free (§4.16 rule 2): ",
                        $call cb_why (cx, as.head)), as.head)) T.t_unit
      $decl ret   $call chk_cbs (cx, $call tys_rest (ts), $call Pa.nodes.val (as.tail))
    }.ret,
    $case as T.t_unit
  )

$decl extern_callee $func ($decl cx proto_ctx, $decl c Pa.proto_node) $match c (
  $case {$prop tag "name"} ($call in_strs ($call strs.val (cx.extnames), c.text)),
  $case {$prop tag "form"} ($call eq_str (c.keyword, "extern")),
  $case c false
)

// §5.3a: "A frame-bound type may not appear in a function's result, and a
// frame-bound value may not be written into storage that is not itself
// frame-bound." That is the whole rule — a structural check on types already
// inferred, with nothing to solve.
//
// The fix is always the same, so the message says it: make the storage
// `$alloc` (§4.2a). It cannot yet name the `$new` the reference came from,
// which §5.3a asks for; that needs provenance the type does not carry.
// A parameter's mark reaching an escape point is not an error here: it makes that
// parameter escape, and the caller is checked instead (§5.3a, `arg_escapes`).
// The marks a function's result carries: its parameters it borrows (§5.3a).
$decl note_borrows $func ($decl cx proto_ctx, $decl t T.proto_ty)
  $if ($call lt (0, $call ival (cx.nmark)))
      ($set cx.brwd ($call T.ci_union ($call T.marks_of (t, T.cints.nil),
          $call T.cints.val (cx.brwd))))
      ($call T.cints.val (cx.brwd))

$decl note_marks $func ($decl cx proto_ctx, $decl t T.proto_ty)
  $if ($call lt (0, $call ival (cx.nmark)))
      ($set cx.escd ($call T.ci_union ($call T.marks_of (t, T.cints.nil),
          $call T.cints.val (cx.escd))))
      ($call T.cints.val (cx.escd))

$decl escapes $func ($decl cx proto_ctx, $decl t T.proto_ty, $decl what "",
                     $decl n Pa.proto_node)
  $if ($call T.frame_bound (t, 0))
      ($call err (cx, $call concat (what, $call concat (" holds frame storage (",
           $call concat ($call T.show_frame ($call T.first_frame (t, 0)),
           "), which cannot outlive the scope its $new made it in. Write $alloc there instead (§4.2a, §5.3a)"))), n))
      ($do ($call note_marks (cx, t)) t)

// The mark of parameter `i` of the function whose body is at depth `d`.
$decl pmark $func ($decl d 0, $decl i 0) $call add ($call mul (d, 64), i)

$decl mres       $func ($decl en env.node, $decl k 0, $decl sr 0, $decl up 0, $decl fk "")
  { $decl env en  $decl n k  $decl ser sr  $decl outer up  $decl key fk }
$decl proto_mres $call mres (env.nil, 0, 0, 0, "")

$decl fn_key_of $func ($decl cx proto_ctx, $decl n Pa.proto_node) {
  $decl sp  $call P.span_of (n)
  $decl ret $call concat ($call sval (cx.file), $call concat (":", $call concat (
                $call int_to_str (sp.line), $call concat (":", $call int_to_str (sp.col)))))
}.ret

// A body starts: it takes the next serial and becomes the current one, and — only if it
// marked a parameter, since only then can a mark name it — joins the stack under its key.
$decl open_body $func ($decl cx proto_ctx, $decl e env.node, $decl k 0, $decl fn Pa.proto_node) {
  $decl up  $call ival (cx.curfn)
  $decl sr  $call add ($call ival (cx.fser), 1)
  $decl a   $set cx.fser sr
  $decl b   $set cx.curfn sr
  $decl fk  $if ($call lt (0, k)) ($call fn_key_of (cx, fn)) ""
  $decl c   $set cx.fstack ($if ($call lt (0, k))
                ($call fframes.cons ($call fframe (sr, $call add ($call ival (cx.fdepth), 1), fk),
                    cx.fstack))
                ($call fframes.val (cx.fstack)))
  $decl ret $call mres (e, k, sr, up, fk)
}.ret


// §5.3a: each parameter whose type can carry something frame-bound is rebound, for the
// body, at its type marked with the parameter (`T.mark_deep`). The function's own type
// keeps the unmarked ones.
$decl mark_params $func ($decl cx proto_ctx, $decl ps Pa.nodes.node, $decl ts T.tys.node,
    $decl e env.node, $decl i 0, $decl k 0, $decl fn Pa.proto_node) $match ps (
  $case {$prop tag "cons"} $match ts (
      $case {$prop tag "cons"} {
        $decl nm   $if ($call is_form (ps.head, "decl")) ($call name_of ($call op (ps.head, 0))) ""
        $decl t    $call T.tval (ts.head)
        $decl ok   $if ($call eq_str (nm, "")) false ($call T.markable (t))
        $decl e2   $if ok ($call bind (e, nm, $call T.mark_deep (t,
                       $call pmark ($call add ($call ival (cx.fdepth), 1), i)))) e
        $decl ret2 $call mark_params (cx, $call Pa.nodes.val (ps.tail), $call T.tys.val (ts.tail),
                       e2, $call add (i, 1), $if ok ($call add (k, 1)) k, fn)
      }.ret2,
      $case ts {
        $decl c    $set cx.nmark ($call add ($call ival (cx.nmark), k))
        $decl ret2 $call open_body (cx, e, k, fn)
      }.ret2
    ),
  $case ps {
    $decl c   $set cx.nmark ($call add ($call ival (cx.nmark), k))
    $decl ret $call open_body (cx, e, k, fn)
  }.ret
)

// This function's escaping parameters out of what has reached an escape point, removed
// from it: an outer function's marks stay for that function to take.
$decl esc_split $func ($decl xs T.cints.node, $decl d 0, $decl mine T.cints.node,
    $decl rest T.cints.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_int ($call div (xs.head, 64), d))
        ($call esc_split ($call T.cints.val (xs.tail), d,
            $call T.cints.cons ($call sub (xs.head, $call mul (d, 64)), mine), rest))
        ($call esc_split ($call T.cints.val (xs.tail), d, mine,
            $call T.cints.cons (xs.head, rest))),
  $case xs { $decl own mine  $decl others rest }
)

// Borrows are kept in a function type's `esc` beside its escapes, as `64 + i` for "the
// result borrows parameter `i`": a mark's parameter index is below 64 (`pmark`), so
// nothing that asks whether `i` escapes can mistake one for the other.
$decl brw_take $func ($decl cx proto_ctx, $decl d 0) {
  $decl sp  $call esc_split ($call T.cints.val (cx.brwd), d, T.cints.nil, T.cints.nil)
  $decl put $set cx.brwd sp.others
  $decl ret sp.own
}.ret

$decl with_brw $func ($decl es T.cints.node, $decl bs T.cints.node) $match bs (
  $case {$prop tag "cons"}
    $call with_brw ($if ($call T.ci_mem (es, $call add (64, bs.head))) es
                        ($call T.cints.cons ($call add (64, bs.head), es)),
        $call T.cints.val (bs.tail)),
  $case bs ($call T.ci_sort (es, T.cints.nil))
)

$decl esc_take $func ($decl cx proto_ctx, $decl d 0) {
  $decl sp  $call esc_split ($call T.cints.val (cx.escd), d, T.cints.nil, T.cints.nil)
  $decl put $set cx.escd sp.others
  $decl ret $call T.ci_sort (sp.own, T.cints.nil)
}.ret

// What a `$func` literal's captures carry, by the same free-names walk as `caps_frame`.
$decl caps_marks $func ($decl cx proto_ctx, $decl e env.node, $decl ns Pa.pstrs.node,
                        $decl skip Pa.pstrs.node, $decl acc T.cints.node) $match ns (
  $case {$prop tag "cons"} {
    $decl skipped $call Pa.mem_pstr (skip, ns.head)
    $decl f       $if skipped ($call found (false, T.t_bot)) ($call lookup (e, ns.head))
    $decl a2      $if f.ok ($call T.marks_of ($call T.tval (f.ty), acc)) acc
    $decl ret     $call caps_marks (cx, e, $call Pa.pstrs.val (ns.tail), skip, a2)
  }.ret,
  $case ns acc
)

// §5.3a at the end of a `$func`, shared by the three places one is typed (`infer_func`,
// `infer_rec_func`, `infer_fwd_body`) — a rule put in only some of them has looked like a
// no-op here before. The result is an escape point; the parameters whose marks reached
// any escape point in the body are this function's `esc`; and its own marks are removed
// from what it hands on, or they would name whatever is typed at this depth next.
$fwd arg_escapes_at

// Whether passing this argument to an escaping parameter could matter: it is frame-bound,
// or it may carry a parameter's mark.
$decl may_escape $func ($decl cx proto_ctx, $decl x Pa.proto_node, $decl raw T.proto_ty,
    $decl want T.proto_ty)
  $if ($call T.frame_bound (raw, 0)) true
  ($if ($if ($call T.is_trait (want)) ($call not ($call T.is_trait ($call deref_ty (raw)))) false)
       ($call traitsof_frame (cx, x, raw))
  ($if ($call lt (0, $call ival (cx.nmark)))
       ($call not ($call T.cints.is_nil ($call T.marks_of (raw, T.cints.nil)))) false))

// The calls recorded against this function (its placeholder result `id`), checked now
// its escaping parameters are known. A call made in this body or one nested in it may
// make this function's own parameters escape, which can enlarge the set — so this runs
// to a fixed point, each call checked once. One made elsewhere — another `$fwd` member
// that has already closed — is still refused if frame-bound, but its parameters' marks
// have nobody left to attribute them to, so they are not noted.
// Whether the body with this serial is still open.
$decl ser_open $func ($decl xs fframes.node, $decl sr 0) $match xs (
  $case {$prop tag "cons"} $if ($call eq_int (xs.head.ser, sr)) true ($call ser_open (xs.tail, sr)),
  $case xs false
)

$decl frame_at $func ($decl xs fframes.node, $decl d 0) $match xs (
  $case {$prop tag "cons"} $if ($call eq_int (xs.head.depth, d)) xs.head ($call frame_at (xs.tail, d)),
  $case xs proto_fframe
)

$decl pop_frame $func ($decl xs fframes.node) $match xs (
  $case {$prop tag "cons"} ($call fframes.val (xs.tail)),
  $case xs xs
)

$decl in_prog $func ($decl xs hint_list.node, $decl nm "", $decl id 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call and ($call eq_int (xs.head.j, id), $call eq_str (xs.head.key, nm))) true
        ($call in_prog (xs.tail, nm, id)),
  $case xs false
)

$decl drop_prog $func ($decl xs hint_list.node, $decl id 0, $decl acc hint_list.node) $match xs (
  $case {$prop tag "cons"}
    $call drop_prog (xs.tail, id,
        $if ($call eq_int (xs.head.j, id)) acc ($call hint_list.cons (xs.head, acc))),
  $case xs acc
)

$decl callee_name $func ($decl n Pa.proto_node) $match n ($case {$prop tag "name"} n.text, $case n "")

$decl has_hint $func ($decl xs hint_list.node, $decl k "", $decl j 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call and ($call eq_str (xs.head.key, k), $call eq_int (xs.head.j, j))) true
        ($call has_hint (xs.tail, k, j)),
  $case xs false
)

// Each mark a deferred argument carries goes to its function: noted as usual while that
// body is open, or kept as a hint for the next typing of the block once it has closed —
// a `$fwd` member that called a later one, or a body nested in one.
$decl route_marks $func ($decl cx proto_ctx, $decl ms T.cints.node, $decl stk fframes.node)
    $match ms (
  $case {$prop tag "cons"} {
    $decl m    ms.head
    $decl dd   $call div (m, 64)
    $decl fr   $call frame_at (stk, dd)
    $decl j    $call sub (m, $call mul (dd, 64))
    $decl open $call ser_open ($call fframes.val (cx.fstack), fr.ser)
    $decl put  $if open ($set cx.escd ($call T.ci_union ($call T.cints.cons (m, T.cints.nil),
                   $call T.cints.val (cx.escd))))
                   ($call T.cints.val (cx.escd))
    $decl h    $set cx.hints ($if ($call or (open, $call eq_str (fr.key, "")))
                   ($call hint_list.val (cx.hints))
                   ($if ($call has_hint (cx.hints, fr.key, j)) ($call hint_list.val (cx.hints))
                        ($call hint_list.cons ($call hint_ent (fr.key, j), cx.hints))))
    $decl ret  $call route_marks (cx, $call T.cints.val (ms.tail), stk)
  }.ret,
  $case ms 0
)

// The calls recorded against this function (its placeholder result `id`), checked now
// its escaping parameters are known: a frame-bound argument to one is refused, and what
// the argument carries is routed (`route_marks`). That can enlarge the set — a self-call
// passing the function's own parameter on — so `pesc_fix` runs this to a fixed point,
// each call checked once.
$decl pesc_run $func ($decl cx proto_ctx, $decl xs pesc_list.node, $decl id 0,
    $decl mine T.cints.node, $decl keep pesc_list.node) $match xs (
  $case {$prop tag "cons"} {
    $decl x    xs.head
    $decl due  $if ($call eq_int (x.id, id)) ($call T.ci_mem (mine, x.i)) false
    $decl chk  $if due
                   ($call arg_escapes_at (cx, x.x, x.raw, x.want, $call add (x.i, 1), false, -1))
                   x.raw
    $decl rt   $if due ($call route_marks (cx, $call T.marks_of (x.raw, T.cints.nil), x.stk)) 0
    $decl ret2 $call pesc_run (cx, $call pesc_list.val (xs.tail), id, mine,
                   $if due keep ($call pesc_list.cons (x, keep)))
  }.ret2,
  $case xs ($set cx.pesc keep)
)

$decl pesc_fix $func ($decl cx proto_ctx, $decl id 0, $decl d 0, $decl mine T.cints.node) {
  $decl run  $call pesc_run (cx, $call pesc_list.val (cx.pesc), id, mine, pesc_list.nil)
  $decl more $call esc_take (cx, d)
  $decl all  $call T.ci_sort ($call T.ci_union (more, mine), T.cints.nil)
  $decl ret  $if ($call T.cints.is_nil (more)) mine ($call pesc_fix (cx, id, d, all))
}.ret

// What earlier typings of this block found about this function's parameters too late.
$decl hints_for $func ($decl xs hint_list.node, $decl k "", $decl acc T.cints.node) $match xs (
  $case {$prop tag "cons"}
    $call hints_for (xs.tail, k, $if ($call eq_str (xs.head.key, k))
        ($call T.ci_union ($call T.cints.cons (xs.head.j, T.cints.nil), acc)) acc),
  $case xs acc
)

// ------------------------------------------- §5.3a: own places, borrowed places
//
// A frame reference is a *place* (§7.6): storage in the activation that made it. A place
// that came in — through a parameter, a capture, or a name in an enclosing frame, the
// file's top level included — is **borrowed**; one this activation's own `$new` made is
// **own**. A function may return a borrowed place but not an own one, and a tail call,
// which ends the activation (§7.7), may not pass an own one.
//
// Which places are own is a question about the *source*, so it is answered by a walk over
// a function's body (`owns_x`) rather than by the type: a type says a value holds a place
// and not whose. The one type fact the walk needs — does this call's result, or this
// argument as passed, contain a place — is recorded by inference as it goes (`placed`).
// The walk errs one way only: anything it cannot see through counts as own, so it can
// refuse a valid program but never accept a dangling one.

$decl note_placed $func ($decl cx proto_ctx, $decl n Pa.proto_node, $decl t T.proto_ty)
  $if ($call T.frame_bound (t, 0))
      ($set cx.placed ($call strs.cons ($call fn_key_of (cx, n), $call strs.val (cx.placed))))
      ($call strs.val (cx.placed))

$decl placed_at $func ($decl cx proto_ctx, $decl n Pa.proto_node)
  $call in_strs ($call strs.val (cx.placed), $call fn_key_of (cx, n))

// What the walk knows about a name: whether this activation binds it, and whether it is a
// place this activation made.
$decl own_ent   $func ($decl n "", $decl o P.boolean) { $decl name n  $decl own o }
$decl proto_own $call own_ent ("", false)
$decl owns      $specialize P.list proto_own

$decl own_of_name $func ($decl e owns.node, $decl n "") $match e (
  $case {$prop tag "cons"}
    $if ($call eq_str (e.head.name, n)) e.head.own ($call own_of_name (e.tail, n)),
  $case e false
)

$decl bound_here $func ($decl e owns.node, $decl n "") $match e (
  $case {$prop tag "cons"} $if ($call eq_str (e.head.name, n)) true ($call bound_here (e.tail, n)),
  $case e false
)

// A function's parameters: bound here, and borrowed.
$decl own_params $func ($decl xs Pa.pstrs.node, $decl acc owns.node) $match xs (
  $case {$prop tag "cons"}
    $call own_params ($call Pa.pstrs.val (xs.tail),
        $call owns.cons ($call own_ent (xs.head, false), acc)),
  $case xs acc
)

$decl node_val $func ($decl x Pa.proto_node) x

$fwd owns_x

$decl owns_any $func ($decl cx proto_ctx, $decl e owns.node, $decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call owns_x (cx, e, xs.head)) true ($call owns_any (cx, e, $call Pa.nodes.val (xs.tail))),
  $case xs false
)

// An argument, as passed. One coerced to a trait object (`slotref`) refers to its own
// storage: a name's slot, own when the name is bound here, or fresh frame storage, always
// own. Anything else is what it holds.
$decl owns_arg $func ($decl cx proto_ctx, $decl e owns.node, $decl x Pa.proto_node)
  $if ($call in_strs ($call strs.val (cx.slotref), $call fn_key_of (cx, x)))
      ($match x ($case {$prop tag "name"} ($call bound_here (e, x.text)), $case x true))
      ($call owns_x (cx, e, x))

$decl owns_args $func ($decl cx proto_ctx, $decl e owns.node, $decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call owns_arg (cx, e, xs.head)) true
        ($call owns_args (cx, e, $call Pa.nodes.val (xs.tail))),
  $case xs false
)

$decl owns_arms $func ($decl cx proto_ctx, $decl e owns.node, $decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call owns_x (cx, e, $call op (xs.head, 1))) true
        ($call owns_arms (cx, e, $call Pa.nodes.val (xs.tail))),
  $case xs false
)

// A block's items, in order: each `$decl` adds its name, own when its initializer is. A
// `$fwd` counts as own until its completion is seen, which is the conservative direction.
$decl blk_res $func ($decl en owns.node, $decl o P.boolean) { $decl env en  $decl own o }

$decl owns_items $func ($decl cx proto_ctx, $decl e owns.node, $decl xs Pa.nodes.node,
                        $decl o P.boolean) $match xs (
  $case {$prop tag "cons"}
    $if ($call is_form (xs.head, "decl")) {
      $decl ow  $call owns_x (cx, e, $call op (xs.head, 1))
      $decl ret $call owns_items (cx,
          $call owns.cons ($call own_ent ($call name_of ($call op (xs.head, 0)), ow), e),
          $call Pa.nodes.val (xs.tail), $if o true ow)
    }.ret
    ($if ($call is_form (xs.head, "fwd"))
        ($call owns_items (cx,
            $call owns.cons ($call own_ent ($call name_of ($call op (xs.head, 0)), true), e),
            $call Pa.nodes.val (xs.tail), o))
        ($call owns_items (cx, e, $call Pa.nodes.val (xs.tail), o))),
  $case xs ($call blk_res (e, o))
)

// A `$func` literal holds a place when it captures one, and captures are copies (§7.3), so
// what it holds is exactly the places its free names are bound to here.
$decl owns_names $func ($decl e owns.node, $decl xs Pa.pstrs.node, $decl skip Pa.pstrs.node)
  $match xs (
    $case {$prop tag "cons"}
      $if ($if ($call Pa.mem_pstr (skip, xs.head)) false ($call own_of_name (e, xs.head))) true
          ($call owns_names (e, $call Pa.pstrs.val (xs.tail), skip)),
    $case xs false
  )

$decl owns_func $func ($decl e owns.node, $decl x Pa.proto_node) {
  $decl ps   $call group_items ($call op (x, 0))
  $decl free $call Pa.free_names ($call op (x, 1), Pa.pstrs.nil)
  $decl shad $call Pa.bound_names ($call op (x, 1), $call param_names (ps, Pa.pstrs.nil))
  $decl ret  $call owns_names (e, free, shad)
}.ret

$decl owns_form $func ($decl cx proto_ctx, $decl e owns.node, $decl x Pa.proto_node) {
  $decl k   $match x ($case {$prop tag "form"} x.keyword, $case x "")
  $decl ret $if ($call eq_str (k, "new")) true
      ($if ($call eq_str (k, "alloc")) false
      // §4.13: `$traitsof` of a name refers to that name's storage, which is this frame's
      // if the name is bound here; of anything else, to fresh frame storage.
      ($if ($call eq_str (k, "traitsof")) {
         $decl a    $call node_val ($call op (x, 0))
         $decl ret2 $match a ($case {$prop tag "name"} ($call bound_here (e, a.text)), $case a true)
       }.ret2
      // A call's result holds a place only if its type says so (`placed`), and then it is
      // own if the callee or an argument is: §R makes a callee's result places borrowed
      // from what it was given, never its own.
      ($if ($call eq_str (k, "call"))
          ($if ($call placed_at (cx, x))
               ($if ($call owns_x (cx, e, $call op (x, 0))) true
                    ($call owns_args (cx, e, $call group_items ($call op (x, 1)))))
               false)
      ($if ($call eq_str (k, "if"))
          ($if ($call owns_x (cx, e, $call op (x, 1))) true ($call owns_x (cx, e, $call op (x, 2))))
      ($if ($call eq_str (k, "do")) ($call owns_x (cx, e, $call op (x, 1)))
      ($if ($call eq_str (k, "match")) ($call owns_arms (cx, e, $call group_items ($call op (x, 1))))
      ($if ($call eq_str (k, "set")) ($call owns_x (cx, e, $call op (x, 1)))
      ($if ($call P.or ($call eq_str (k, "try"), $call P.or ($call eq_str (k, "mut"),
               $call P.or ($call eq_str (k, "const"), $call eq_str (k, "impl")))))
          ($call owns_x (cx, e, $call op (x, 0)))
      ($if ($call eq_str (k, "union"))
          ($call owns_any (cx, e, $call group_items ($call op (x, 0))))
      ($if ($call eq_str (k, "func")) ($call owns_func (e, x))
           false))))))))))
}.ret

$decl owns_x $func ($decl cx proto_ctx, $decl e owns.node, $decl x Pa.proto_node) $match x (
  $case {$prop tag "name"}  ($call own_of_name (e, x.text)),
  $case {$prop tag "group"} ($call owns_any (cx, e, $call Pa.nodes.val (x.items))),
  $case {$prop tag "block"} {
    $decl r   $call owns_items (cx, e, $call Pa.nodes.val (x.items), false)
    $decl ret r.own
  }.ret,
  // `{ … $decl ret e }.ret` is how a value is returned (§3.3), so a projection off a block
  // literal looks at the one field it reads.
  $case {$prop tag "proj_name"} {
    $decl tg   $call node_val (x.target)
    $decl ret  $match tg (
        $case {$prop tag "block"} {
          $decl r    $call owns_items (cx, e, $call Pa.nodes.val (tg.items), false)
          $decl ret2 $call own_of_name (r.env, x.field)
        }.ret2,
        $case tg ($call owns_x (cx, e, tg))
      )
  }.ret,
  $case {$prop tag "proj_index"} ($call owns_x (cx, e, $call node_val (x.target))),
  $case {$prop tag "form"} ($call owns_form (cx, e, x)),
  $case x false
)

// The record a projection reads from is discarded there, and with it the places its
// fields own: a projected value holding one would alias a place whose owner has ended.
// The walk starts with nothing bound outside the block, so "own" means made in it.
// A function's body is left to R2, which reports it in its own terms.
$decl owner_check $func ($decl cx proto_ctx, $decl n proto_projn) {
  $decl tg  $call node_val (n.target)
  $decl ret $match tg (
      $case {$prop tag "block"}
        $if ($call eq_str ($call fn_key_of (cx, n), $call sval (cx.fbody))) ()
        {
          $decl r    $call owns_items (cx, owns.nil, $call Pa.nodes.val (tg.items), false)
          $decl ret2 $if ($call own_of_name (r.env, n.field))
              ($do ($call err (cx, $call concat ("'", $call concat (n.field,
                  "' holds a place owned by this block, which ends here: an alias may not outlive its owner (§5.3a)")), n)) ())
              ()
        }.ret2,
      $case tg ()
    )
}.ret

// §7.7's tail positions: a function's body, the arms of an `$if` or a `$match` in one, and
// the second operand of a `$do`. A block is never one — a call inside a block is not in
// tail position — so the only names a tail position binds are `$match`'s narrowings,
// which are the scrutinee's.
$decl tail_arg_err $func ($decl cx proto_ctx, $decl x Pa.proto_node)
  $do ($call err (cx, "this tail call passes $new storage made in this call, and a tail call ends the call (§7.7): allocate it with $alloc and release it when done, or make the call non-tail", x)) ()

// §6's coercion makes a trait object referring to the argument's own storage, which a
// tail call ends just as it ends a `$new`'s.
$decl tail_obj_err $func ($decl cx proto_ctx, $decl x Pa.proto_node)
  $do ($call err (cx, "this tail call makes a trait object referring to storage of this call (§6), and a tail call ends the call (§7.7): pass a reference the caller lent, or $alloc storage, or make the call non-tail", x)) ()

$decl tail_args $func ($decl cx proto_ctx, $decl e owns.node, $decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"}
    $do ($if ($call placed_at (cx, xs.head))
             ($if ($call owns_arg (cx, e, xs.head))
                  ($if ($call in_strs ($call strs.val (cx.slotref), $call fn_key_of (cx, xs.head)))
                       ($call tail_obj_err (cx, xs.head)) ($call tail_arg_err (cx, xs.head))) ())
             ())
        ($call tail_args (cx, e, $call Pa.nodes.val (xs.tail))),
  $case xs ()
)

$fwd tail_check

$decl tail_arms $func ($decl cx proto_ctx, $decl ie env.node, $decl e owns.node,
                       $decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"}
    $do ($call tail_check (cx, ie, e, $call op (xs.head, 1)))
        ($call tail_arms (cx, ie, e, $call Pa.nodes.val (xs.tail))),
  $case xs ()
)

// An `$extern` is C (§4.16) and an intrinsic is inline: neither is an activation that
// replaces this one, so a place passed to either outlives the call as any argument does.
// An intrinsic is a name that resolves to the root block's own binding: not rebound in
// this body, and bound outside it at the root's type.
$decl tail_callee_ok $func ($decl cx proto_ctx, $decl ie env.node, $decl e owns.node,
                            $decl c Pa.proto_node) {
  $decl nm  $call callee_name (c)
  $decl ret $if ($call extern_callee (cx, c)) true
      ($if ($call eq_str (nm, "")) false
      ($if ($call bound_here (e, nm)) false {
         $decl f    $call lookup (ie, nm)
         $decl r    $call lookup ($call eval_env (root_env), nm)
         $decl ret2 $if ($call and (f.ok, r.ok)) ($call T.same (f.ty, r.ty)) false
       }.ret2))
}.ret

$decl tail_check $func ($decl cx proto_ctx, $decl ie env.node, $decl e owns.node,
                        $decl x Pa.proto_node)
  $if ($call is_form (x, "call"))
      ($if ($call tail_callee_ok (cx, ie, e, $call op (x, 0))) ()
           ($call tail_args (cx, e, $call group_items ($call op (x, 1)))))
  ($if ($call is_form (x, "if"))
      ($do ($call tail_check (cx, ie, e, $call op (x, 1)))
           ($call tail_check (cx, ie, e, $call op (x, 2))))
  ($if ($call is_form (x, "do")) ($call tail_check (cx, ie, e, $call op (x, 1)))
  ($if ($call is_form (x, "match"))
       ($call tail_arms (cx, ie, e, $call group_items ($call op (x, 1))))
       ())))

// DEFER.md: this function's parameters it frees, as `128 + i`, from the names `note_freed`
// recorded at its depth — which it takes, so a sibling at the same depth starts clean. Only
// through the root: which allocator is not in the type, and a caller must be able to check
// its argument came from the same one. A name that is not a parameter was this function's
// own storage, whose routing lowering checks.
$decl freed_idx $func ($decl ps Pa.pstrs.node, $decl nm "", $decl i 0) $match ps (
  $case {$prop tag "cons"}
    $if ($call eq_str (ps.head, nm)) i
        ($call freed_idx ($call Pa.pstrs.val (ps.tail), nm, $call add (i, 1))),
  $case ps -1
)
$decl freed_go $func ($decl cx proto_ctx, $decl xs strs.node, $decl pre "", $decl ps Pa.pstrs.node,
                      $decl n Pa.proto_node, $decl keep strs.node, $decl acc T.cints.node)
    $match xs (
  $case {$prop tag "cons"} {
    $decl h    xs.head
    $decl mine $if ($call lt ($call len (pre), $call len (h)))
                   ($call eq_str ($call slice (h, 0, $call len (pre)), pre)) false
    $decl rest $if mine ($call slice (h, $call len (pre), $call len (h))) ""
    $decl bang $if mine ($call lt (1, $call len (rest))) false
    $decl tl   $if bang ($call slice (rest, $call sub ($call len (rest), 2), $call len (rest))) ""
    $decl nonr $call eq_str (tl, "|!")
    $decl nm   $if nonr ($call slice (rest, 0, $call sub ($call len (rest), 2))) rest
    $decl ix   $if mine ($call freed_idx (ps, nm, 0)) -1
    $decl e    $if ($if nonr ($call lt (-1, ix)) false)
        ($do ($call err (cx, $call concat ("this function frees its parameter '", $call concat (nm,
            "' through an allocator other than the root's, which a caller cannot check yet (DEFER.md)")), n)) ())
        ()
    $decl have $call T.ci_mem (acc, $call add (128, ix))
    $decl a2   $if ($if ($call lt (-1, ix)) ($call not (have)) false)
                   ($call T.cints.cons ($call add (128, ix), acc)) acc
    $decl ret  $call freed_go (cx, $call strs.val (xs.tail), pre, ps, n,
                   $if mine keep ($call strs.cons (h, keep)), a2)
  }.ret,
  $case xs ($do ($set cx.freed ($call strs.reverse (keep, strs.nil))) acc)
)
$decl freed_take $func ($decl cx proto_ctx, $decl d 0, $decl ps Pa.nodes.node,
                        $decl n Pa.proto_node)
  $call T.ci_sort ($call freed_go (cx, $call strs.val (cx.freed),
      $call concat ($call int_to_str (d), "|"),
      $call Pa.pstrs.reverse ($call param_names (ps, Pa.pstrs.nil), Pa.pstrs.nil), n, strs.nil,
      T.cints.nil), T.cints.nil)

// DEFER.md: `1000` in a function's type says its result may be storage from an allocator
// other than the root's — so a caller cannot route a `$free` of it to the root. Stated as
// the lack of a guarantee, not as one, because fewer entries make a subtype: a function
// that does guarantee root storage must be usable where one that does not is expected.
// Only a result that is itself allocated storage asks, and the answer is "root" only when
// the source shows it: an `$alloc` from the root, a call whose callee guarantees it, an
// `$if` of two such, or the field of a block projected on the spot that is one.
$fwd root_res
$decl root_item $func ($decl xs Pa.nodes.node, $decl nm "") $match xs (
  $case {$prop tag "cons"}
    $if ($if ($call is_form (xs.head, "decl"))
             ($call eq_str ($call name_of ($call op (xs.head, 0)), nm)) false)
        ($call op (xs.head, 1)) ($call root_item ($call Pa.nodes.val (xs.tail), nm)),
  $case xs ($call Pa.n_err ("", 0, 0))
)
$decl is_err_node $func ($decl n Pa.proto_node) $match n ($case {$prop tag "error"} true, $case n false)
$decl binds_alloc $func ($decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"}
    $if ($if ($call is_form (xs.head, "decl"))
             ($call eq_str ($call name_of ($call op (xs.head, 0)), "allocator")) false)
        true ($call binds_alloc ($call Pa.nodes.val (xs.tail))),
  $case xs false
)
$decl root_res $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node,
                      $decl rb P.boolean, $decl ds Pa.nodes.node) $match n (
  $case {$prop tag "form"}
    $if ($call eq_str (n.keyword, "alloc")) {
      $decl f    $call lookup (e, "allocator")
      $decl ret2 $if rb false ($if f.ok ($call T.same (f.ty, T.ffi_alloc)) true)
    }.ret2
    ($if ($call P.or ($call eq_str (n.keyword, "mut"), $call eq_str (n.keyword, "const")))
         ($call root_res (cx, e, $call op (n, 0), rb, ds))
    ($if ($call eq_str (n.keyword, "if"))
         ($if ($call root_res (cx, e, $call op (n, 1), rb, ds))
              ($call root_res (cx, e, $call op (n, 2), rb, ds)) false)
    ($if ($call eq_str (n.keyword, "call"))
         ($call not ($call in_strs ($call strs.val (cx.nonroot), $call fn_key_of (cx, n))))
         false))),
  $case {$prop tag "proj_name"} {
    $decl tg   $call node_val (n.target)
    $decl ret2 $match tg (
        $case {$prop tag "block"} {
          $decl its  $call Pa.nodes.val (tg.items)
          $decl init $call root_item (its, n.field)
          $decl ret3 $if ($call is_err_node (init)) false
              ($call root_res (cx, e, init, $if rb true ($call binds_alloc (its)), its))
        }.ret3,
        $case tg false
      )
  }.ret2,
  $case {$prop tag "name"} {
    $decl init $call root_item (ds, n.text)
    $decl ret2 $if ($call is_err_node (init)) false ($call root_res (cx, e, init, rb, ds))
  }.ret2,
  $case n false
)
$decl nonroot_res $func ($decl cx proto_ctx, $decl e env.node, $decl res T.proto_ty,
                         $decl body Pa.proto_node) {
  $decl r   $call tval (res)
  $decl al  $match r ($case {$prop tag "ref"} ($call T.is_alloc (r.kind)), $case r false)
  $decl ret $if al ($if ($call root_res (cx, e, body, false, Pa.nodes.nil)) T.cints.nil
                        ($call T.cints.cons (1000, T.cints.nil)))
                T.cints.nil
}.ret

$decl func_close $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node,
    $decl ps Pa.nodes.node, $decl tys T.tys.node, $decl res0 T.proto_ty, $decl mr proto_mres,
    $decl id -1) {
  $decl mk   mr.n
  $decl d    $call add ($call ival (cx.fdepth), 1)
  $decl lim  $call mul (d, 64)
  // §5.3a with §R's borrowing: a result may hold a place only if this call did not make
  // it, and (A4) a tail call may not pass one it did. Both read the body's provenance,
  // with the parameters bound here and borrowed.
  $decl own0 $call own_params ($call param_names (ps, Pa.pstrs.nil), owns.nil)
  $decl esc  $if ($call T.frame_bound (res0, 0))
                 ($if ($call owns_x (cx, own0, $call op (n, 1)))
                      ($call err (cx, $call concat ("this function's result holds frame storage made in this call (",
                           $call concat ($call T.show_frame ($call T.first_frame (res0, 0)),
                           "), which ends when it returns; return a place the caller passed in, or $alloc storage (§5.3a)")), n))
                      ($do ($call note_borrows (cx, res0)) res0))
                 ($do ($call note_borrows (cx, res0)) res0)
  $decl tc   $call tail_check (cx, e, own0, $call op (n, 1))
  // ...and its closure clause: a literal that captured frame storage is itself
  // frame-bound, so returning *it* is an escape too — caught one level out.
  $decl free $call Pa.free_names ($call op (n, 1), Pa.pstrs.nil)
  $decl shad $call Pa.bound_names ($call op (n, 1), $call param_names (ps, Pa.pstrs.nil))
  $decl capf $call caps_frame (cx, e, free, shad)
  $decl on   $call lt (0, $call ival (cx.nmark))
  $decl capm $if on ($call caps_marks (cx, e, free, shad, T.cints.nil)) T.cints.nil
  $decl took  $call esc_take (cx, d)
  $decl mine0 $if ($call lt (0, mk))
                  ($call T.ci_sort ($call hints_for ($call hint_list.val (cx.hints), mr.key, took),
                      T.cints.nil))
                  took
  $decl mine $if ($call lt (id, 0)) mine0 ($call pesc_fix (cx, id, d, mine0))
  $decl res  $if on ($call T.unmark (res0, lim)) res0
  $decl off  $set cx.nmark ($call sub ($call ival (cx.nmark), mk))
  $decl back $set cx.curfn mr.outer
  $decl pop  $set cx.fstack ($if ($call lt (0, mk))
                  ($call pop_frame ($call fframes.val (cx.fstack))) ($call fframes.val (cx.fstack)))
  // A parameter whose marks reached only the result is borrowed: the caller gets it back,
  // owned by whoever owned the argument (`infer_call`), rather than losing it (§5.3a).
  $decl brws $call brw_take (cx, d)
  $decl frd  $call freed_take (cx, d, ps, n)
  $decl nrr  $call nonroot_res (cx, e, res, $call op (n, 1))
  $decl all  $call T.ci_sort ($call T.ci_union (frd, $call T.ci_union (nrr, mine)), T.cints.nil)
  $decl ret  $call T.t_func_esc (tys, res, capf, $call with_brw (all, brws),
                 $call T.keep_below (capm, lim, T.cints.nil))
}.ret

// A call passing an argument to a parameter the callee lets escape (§5.3a): refused if
// the argument is frame-bound, and an escape of the caller's own parameter if it carries
// one's mark. A trait object made at the call is frame-bound as `$traitsof` would be.
$decl arg_escapes $func ($decl cx proto_ctx, $decl x Pa.proto_node, $decl raw T.proto_ty,
    $decl want T.proto_ty, $decl i 0)
  $call arg_escapes_at (cx, x, raw, want, i, true, -1)

// `marks` false: refuse a frame-bound argument and note nothing. `lim` keeps only marks
// below it, for a deferred check whose nested bodies have already closed.
$decl arg_escapes_at $func ($decl cx proto_ctx, $decl x Pa.proto_node, $decl raw T.proto_ty,
    $decl want T.proto_ty, $decl i 0, $decl marks P.boolean, $decl lim 0) {
  $decl v   $call deref_ty (raw)
  $decl fb  $if ($call T.frame_bound (raw, 0)) true
                ($if ($call and ($call T.is_trait (want), $call not ($call T.is_trait (v))))
                     ($call traitsof_frame (cx, x, raw)) false)
  $decl ret $if fb
      ($call err (cx, $call concat ("argument ", $call concat ($call int_to_str (i),
           " refers to frame storage, and this function lets that parameter escape (§5.3a); pass $alloc storage instead")), x))
      ($if marks
           ($do ($if ($call lt (lim, 0)) ($call note_marks (cx, raw))
                     ($call note_marks (cx, $call T.unmark (raw, lim)))) raw)
           raw)
}.ret

// §4.3: `$mut` requires a reference.
// §4.3: `$mut` and `$const` make a view of storage at their qualifier.
$decl infer_mut $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form, $decl q "") {
  $decl t $call T.tval ($call infer (cx, e, $call op (n, 0)))
  $decl ret $match t (
      // §5.3: a view preserves the kind — `$mut` of allocated storage is
      // still allocated.
      $case {$prop tag "ref"} $call T.t_ref_k (q, t.inner, t.kind),
      $case t ($call err (cx, $call concat ("$", $call concat (q, $call concat (" expects storage, found ",
                   $call concat ($call T.show (t), "; only $new creates storage")))), n))
    )
}.ret

// §4.4: writes *through* storage; the type is the written value's.
// A file's short name: its basename without `.mpl`, the trade lowering's `mod_short`
// makes too, so the two passes name a position the same way.
$decl short_of $func ($decl path "") {
  $decl sl $call P.last_slash (path, 0, -1)
  $decl b  $if ($call lt (sl, 0)) path
               ($call slice (path, $call add (sl, 1), $call len (path)))
  $decl n  $call len (b)
  $decl ret  $if ($call lt (4, n))
      ($if ($call eq_str ($call slice (b, $call sub (n, 4), n), ".mpl"))
           ($call slice (b, 0, $call sub (n, 4))) b)
      b
}.ret

// §7.6: `$alloc` draws from the `allocator` in lexical scope. The root's needs nothing; any
// other must have an `alloc` member taking a size and answering an address (§8's raw
// memory, as `raw_alloc` does), which is all `$alloc` asks of it.
$decl alloc_conforms $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl f   $call lookup (e, "allocator")
  $decl ret $if ($call not (f.ok)) T.t_unit
      ($if ($call T.same (f.ty, T.ffi_alloc)) T.t_unit {
         $decl sp   $call P.span_of (n)
         $decl key  $call concat ($call short_of ($call sval (cx.file)), $call concat (":",
                        $call concat ($call int_to_str (sp.line), $call concat (":",
                        $call int_to_str (sp.col)))))
         $decl rec  $set cx.ualloc ($call strs.cons (key, $call strs.val (cx.ualloc)))
         $decl m    $call Pa.n_projn ($call Pa.n_name ("allocator", sp.line, sp.col), "alloc",
                        sp.line, sp.col)
         $decl mt   $call deref_ty ($call infer (cx, e, m))
         $decl ret2 $if ($call T.sub (mt, ralloc_t)) T.t_unit
             ($call err (cx, $call concat ("the allocator in scope cannot serve $alloc: its alloc is ",
                  $call concat ($call T.show (mt), ", which must take a size and answer an address (§7.6)")), n))
       }.ret2)
}.ret

// §4.15a: the first `$defer` among a block's items, or the empty node.
$decl first_defer $func ($decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call is_form (xs.head, "defer")) xs.head ($call first_defer ($call Pa.nodes.val (xs.tail))),
  $case xs Pa.proto_node
)
$decl defers_in $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "block"} ($call first_defer ($call Pa.nodes.val (n.items))),
  $case n Pa.proto_node
)
$decl is_defer $func ($decl n Pa.proto_node) $call is_form (n, "defer")

// A block evaluated *into* storage runs its deferrals when the storage's owner dies
// (DEFER.md step 3, which lowering and stage 0 decide) — or, for `$alloc`, when it is freed
// (step 4): `$alloc` hands them to the allocator, `allocator.defer_at (addr, fin)`, and the
// allocator's `free` runs them. So the allocator in scope must have a `defer_at`, which the
// root's has not yet (DEFER.md, open question 1), and the deferrals — run at `$free`, long
// after this frame — may name only the block's own fields and what is global, as a member
// may (§4.10).
// The names a block's `$defer`s read.
$decl dfr_free_go $func ($decl xs Pa.nodes.node, $decl acc Pa.pstrs.node) $match xs (
  $case {$prop tag "cons"}
    $call dfr_free_go ($call Pa.nodes.val (xs.tail),
        $if ($call is_form (xs.head, "defer")) ($call Pa.free_names ($call op (xs.head, 0), acc)) acc),
  $case xs acc
)
$decl dfr_free $func ($decl b Pa.proto_node) $match b (
  $case {$prop tag "block"} ($call dfr_free_go ($call Pa.nodes.val (b.items), Pa.pstrs.nil)),
  $case b Pa.pstrs.nil
)

// Whether a member is a function of two parameters, as `free` and `defer_at` must be.
$decl two_params $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "func"} ($call eq_int ($call T.tys.length ($call T.tys.val (t.params), 0), 2)),
  $case t false
)

// An `$alloc` block's deferrals run at `$free`, after the frame that wrote them is gone.
$decl alloc_caps $func ($decl cx proto_ctx, $decl b Pa.proto_node, $decl d Pa.proto_node) {
  $decl cap $call first_cap (cx, $call dfr_free (b), $call Pa.bound_names (b, Pa.pstrs.nil))
  $decl ret $if ($call eq_str (cap, "")) ()
      ($do ($call err (cx, $call concat ("an $alloc block's deferral runs at $free, after this frame is gone: it may name only the block's fields and globals (§4.10), not '",
           $call concat (cap, "'")), d)) ())
}.ret

$decl alloc_defer $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form,
                         $decl d Pa.proto_node) {
  $decl f   $call lookup (e, "allocator")
  $decl b   $call op (n, 0)
  $decl root $if f.ok ($call T.same (f.ty, T.ffi_alloc)) true
  $decl ret $if root ($call alloc_caps (cx, $call op (n, 0), d))
      {
        $decl sp   $call P.span_of (n)
        $decl m    $call Pa.n_projn ($call Pa.n_name ("allocator", sp.line, sp.col), "defer_at",
                       sp.line, sp.col)
        $decl mt   $call deref_ty ($call infer (cx, e, m))
        $decl ok   $call two_params (mt)
        $decl e1   $if ok ()
            ($do ($call err (cx, $call concat ("the allocator in scope cannot run an $alloc block's deferrals: its defer_at is ",
                 $call concat ($call T.show (mt), ", which must take an address and a function (DEFER.md)")), d)) ())
        $decl ret2 $call alloc_caps (cx, b, d)
      }.ret2
}.ret


$decl storage_defer $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl d   $call defers_in ($call op (n, 0))
  $decl ret $if ($if ($call is_defer (d)) ($call eq_str (n.keyword, "alloc")) false)
      ($call alloc_defer (cx, e, n, d)) ()
}.ret

// A `$new` block with a `$defer` whose deferrals would outlive where `n` stands: one not
// inside a block projected on the spot, which runs them at its own end, nor inside a
// `$func`, which is another activation. The empty node when there is none.
$fwd bare_storage
$decl bare_any $func ($decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"} {
    $decl h   $call bare_storage (xs.head)
    $decl ret $if ($call is_defer (h)) h ($call bare_any ($call Pa.nodes.val (xs.tail)))
  }.ret,
  $case xs Pa.proto_node
)
$decl bare_storage $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "form"}
    $if ($call eq_str (n.keyword, "func")) Pa.proto_node
    ($if ($call eq_str (n.keyword, "new")) {
       $decl d    $call defers_in ($call op (n, 0))
       $decl ret2 $if ($call is_defer (d)) d ($call bare_any ($call Pa.nodes.val (n.operands)))
     }.ret2
     ($call bare_any ($call Pa.nodes.val (n.operands)))),
  $case {$prop tag "block"}      ($call bare_any ($call Pa.nodes.val (n.items))),
  $case {$prop tag "group"}      ($call bare_any ($call Pa.nodes.val (n.items))),
  $case {$prop tag "proj_name"}
    $if ($call is_block_node (n.target)) Pa.proto_node ($call bare_storage (n.target)),
  $case {$prop tag "proj_index"} ($call bare_storage (n.target)),
  $case n Pa.proto_node
)

// DEFER.md step 3: a `$new` literal with deferrals passed to a call whose result can hold
// a place. Which place comes back is decided inside the callee, so "is the result's
// `$decl` the storage's owner" has no answer the source gives — and stage 0, deciding at
// run time, would give one the compiler could not match. Refused until a function's type
// records which parameters' places its result is. A call whose result holds no place
// cannot hand the storage back, so there it is plainly ephemeral.
$decl call_storage $func ($decl cx proto_ctx, $decl n proto_form, $decl r T.proto_ty)
  $if ($call T.frame_bound (r, 0)) {
    $decl d    $call bare_any ($call group_items ($call op (n, 1)))
    $decl ret2 $if ($call is_defer (d))
        ($do ($call err (cx, "$defer in a $new block passed to a call that can hand a place back is not implemented yet: its owner depends on the callee (DEFER.md)", d)) ())
        ()
  }.ret2 ()

// An `$if` or `$match` arm runs only when taken, and its storage's deferrals would run
// regardless — that needs a flag per site (DEFER.md, example 10), so it is refused.
$decl arm_storage $func ($decl cx proto_ctx, $decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"} {
    $decl d   $call bare_storage (xs.head)
    $decl e   $if ($call is_defer (d))
        ($do ($call err (cx, "$defer in a $new block in an $if or $match arm is not implemented yet (DEFER.md)", d)) ())
        ()
    $decl ret $call arm_storage (cx, $call Pa.nodes.val (xs.tail))
  }.ret,
  $case xs ()
)
$decl case_bodies $func ($decl xs Pa.nodes.node, $decl acc Pa.nodes.node) $match xs (
  $case {$prop tag "cons"}
    $call case_bodies ($call Pa.nodes.val (xs.tail),
        $call Pa.nodes.cons ($call op (xs.head, 1), acc)),
  $case xs acc
)

// A name freed here, for `func_close` to find among this function's parameters.
$decl note_freed $func ($decl cx proto_ctx, $decl x Pa.proto_node, $decl root P.boolean)
  $match x (
    $case {$prop tag "name"}
      $do ($set cx.freed ($call strs.cons ($call concat ($call int_to_str ($call ival (cx.fdepth)),
               $call concat ("|", $call concat (x.text, $if root "" "|!"))),
               $call strs.val (cx.freed))))
          (),
    $case x ()
  )

// What a borrowed argument lends the call's result: its marks, and whether it is
// frame-bound — directly, or as the trait object §6's coercion makes over frame storage.
$decl note_barg $func ($decl cx proto_ctx, $decl x Pa.proto_node, $decl raw T.proto_ty,
                       $decl p T.proto_ty) {
  $decl m   $set cx.bmarks ($call T.ci_union ($call T.marks_of (raw, T.cints.nil),
                $call T.cints.val (cx.bmarks)))
  $decl fb  $if ($call T.frame_bound (raw, 0)) true
                ($if ($call T.is_trait (p))
                     ($if ($call T.is_trait ($call deref_ty (raw))) false
                          ($call traitsof_frame (cx, x, raw)))
                     false)
  $decl ret $if fb ($set cx.bframe true) false
}.ret

$decl mark_all $func ($decl t T.proto_ty, $decl ms T.cints.node) $match ms (
  $case {$prop tag "cons"} $call mark_all ($call T.mark_deep (t, ms.head), $call T.cints.val (ms.tail)),
  $case ms t
)

// `T.join`, keeping both sides' parameter marks (§5.3a): of two equal types it keeps one
// whole, and a mark only the other carried would be a parameter's flow lost — `bigger`
// returning `$if c b a` would borrow one parameter instead of both. Only while marks are
// being tracked, since walking for them costs a pass over each type.
$decl join_m $func ($decl cx proto_ctx, $decl a T.proto_ty, $decl b T.proto_ty) {
  $decl r   $call T.join (a, b)
  $decl ret $if ($call lt (0, $call ival (cx.nmark)))
      ($call mark_all (r, $call T.ci_union ($call T.marks_of (a, T.cints.nil),
          $call T.marks_of (b, T.cints.nil))))
      r
}.ret

// §5.3a's A0: storage never holds a place. A place used where a value is wanted is read
// through (§5.4), so `$new $new 0` is one cell and `$set p loc` copies; what this refuses
// is a place carried *inside* a value — in a field, or captured by a closure.
$decl no_place $func ($decl cx proto_ctx, $decl v T.proto_ty, $decl n Pa.proto_node)
  $if ($call T.frame_bound (v, 0))
      ($call err (cx, $call concat ("storage cannot hold a place: this value holds frame storage (",
           $call concat ($call T.show_frame ($call T.first_frame (v, 0)),
           "), and only a pointer value may be stored (§5.3a); store $alloc storage instead")), n))
      v

$decl infer_new $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl v   $call deref_ty ($call infer (cx, e, $call op (n, 0)))
  $decl chk $call no_place (cx, v, n)
  $decl ret $call T.t_ref ("", v)
}.ret

$decl infer_set $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl tgt $call T.tval ($call infer (cx, e, $call op (n, 0)))
  $decl x   $call op (n, 1)
  $decl raw $call infer (cx, e, x)
  $decl val $call deref_ty (raw)
  $decl ret $match tgt (
      $case {$prop tag "ref"} {
        // §6: storing into trait storage makes a trait object referring to the value — so it
        // must be referable, and storage that outlives its frame (§5.3a) cannot hold one that
        // refers to frame storage.
        $decl cw   $call coerce_why (x, raw, tgt.inner)
        $decl fr   $call P.and ($call P.not ($call T.is_trait (val)),
                       $call traitsof_frame (cx, x, raw))
        $decl ret2 $if ($call not ($call eq_str (cw, ""))) ($call err (cx, cw, x))
            ($if ($call P.and ($call T.is_trait (tgt.inner), fr))
                 // §5.3a's A0, for storage of either kind: a trait object referring to frame
                 // storage is a place, and storage never holds one — a frame cell the caller
                 // lent outlives this call as surely as allocated storage does.
                 ($if ($call T.is_alloc (tgt.kind))
                      ($call err (cx, "this trait object would refer to frame storage, which allocated storage outlives (§5.3a); store a reference to $alloc storage instead", x))
                      ($call err (cx, "storage cannot hold a place: this trait object would refer to frame storage (§6, §5.3a); store a reference to $alloc storage instead", x)))
        // §5.3: `&const T` is a read-only view, so nothing writes through it. Nothing in
        // stage 1 did — `$const` is outside the bootstrap subset — until §4.10 made a
        // member's receiver one, which is what makes a member that writes need `$mut`.
        $if ($call eq_str (tgt.qual, "const"))
            ($call err (cx, "$set through a read-only reference (§5.3)", n))
        ($do ($if ($call T.is_alloc (tgt.kind))
                 ($call escapes (cx, val, "this value", n)) ($call no_place (cx, val, n)))
        ($if ($call T.sub ($if ($call T.is_trait (tgt.inner)) raw val, tgt.inner)) val
            ($if ($call or ($call has_free_var (val), $call has_free_var (tgt.inner)))
                ($do ($call defer_check (cx, val, tgt.inner, "cannot write ", n)) val)
                ($call err (cx, $call concat ("cannot write ", $call concat ($call T.show (val),
                             $call concat (" into storage of ", $call T.show (tgt.inner)))), n))))))
      }.ret2,
      $case tgt ($call err (cx, $call concat ("$set needs storage on the left, found ",
                     $call T.show (tgt)), n))
    )
}.ret

$decl pres       $func ($decl ts T.tys.node, $decl en env.node) { $decl tys ts  $decl env en }
$decl proto_pres $call pres (T.tys.nil, env.nil)

// §3.4: "each default fixes the parameter's type."
// §4.1: a name is bound once in a block.
//
// Two items binding one name are not shadowing — they are two *fields*, and
// the block answers for them differently depending on where you stand: §7.2
// makes the slots the layout, so a name inside the block resolves to the last
// slot binding it while §4.6's projection finds the first. §4.11 already says
// "exactly one" `$decl` completes a `$fwd`; this is the same rule everywhere
// else. Shadowing across *nested* blocks is untouched.
$decl binder_name $func ($decl n Pa.proto_node)
  $if ($call is_form (n, "decl")) ($call name_of ($call op (n, 0)))
  ($if ($call is_form (n, "fwd"))  ($call name_of ($call op (n, 0)))
  ($if ($call is_form (n, "prop")) ($call name_of ($call op (n, 0)))
       ""))

$decl binder_kind $func ($decl n Pa.proto_node)
  $if ($call is_form (n, "decl")) "decl"
  ($if ($call is_form (n, "fwd"))  "fwd"
  ($if ($call is_form (n, "prop")) "prop"
       ""))

// Does anything *before* this item already bind `nm`? The one legal repeat is
// a `$fwd` completed by a `$decl` (§4.11), so that pair — and only that pair —
// is skipped. Asking at the later item reports each offender once, where
// scanning forwards from the earlier one reports `$fwd x  $decl x  $fwd x`
// twice for the same position.
$decl has_earlier $func ($decl nm "", $decl k "", $decl seen Pa.nodes.node) $match seen (
  $case {$prop tag "cons"}
    $if ($call eq_str ($call binder_name (seen.head), nm))
        ($if ($call and ($call eq_str ($call binder_kind (seen.head), "fwd"),
                         $call eq_str (k, "decl")))
             ($call has_earlier (nm, k, seen.tail))
             true)
        ($call has_earlier (nm, k, seen.tail)),
  $case seen false
)

$decl check_unique $func ($decl cx proto_ctx, $decl items Pa.nodes.node,
                          $decl seen Pa.nodes.node, $decl what "") $match items (
  $case {$prop tag "cons"} {
    $decl it items.head
    $decl nm $call binder_name (it)
    $decl said $if ($call eq_str (nm, "")) T.t_bot
        ($if ($call has_earlier (nm, $call binder_kind (it), seen))
             ($call err (cx, $call concat ("'", $call concat (nm,
                 $call concat ("' is already ",
                 $call concat (what, "; a name is bound once (4.1) - rename one of them")))), it))
             T.t_bot)
    $decl ret  $call check_unique (cx, items.tail, $call Pa.nodes.cons (it, seen), what)
  }.ret,
  $case items ()
)

// §4.11: "References to `name` before its completing `$decl` are allowed only
// inside a `$func` or `$template` body." A `$fwd` reserves a slot and nothing
// fills it until the completing `$decl` runs (§4.10's source order), so this is
// a rule about *evaluation*, and the syntactic reading of it is not enough: the
// read can be inside a `$func` body that an initializer between the two *calls*.
//
//   $fwd f
//   $decl g $func () $call f ()
//   $decl x $call g ()        // runs g, which reads f's empty slot
//   $decl f $func () 7
//
// Stage 0 refuses that at run time ("'f' is not initialized yet"). Nothing here
// did, and the compiled backend answered 7 — it emits a `$decl` of a `$func` as a
// plain C function, so there is no empty slot to read — while the value case
// read a static assigned at the `$fwd`'s position. One program, two meanings.
//
// So each item between a `$fwd` and its completing `$decl`, the completing one
// included, is walked for what *evaluating* it reads: everything but the bodies
// of the forms that defer (`fwd_lazy`), and through every direct call to a
// `$func` literal this block binds by name, transitively. A read of a pending
// name anywhere on that walk is reported at the item.
//
// It errs permissive, the direction `ctnames` and §5.3a's `bound_names` already
// take: a call through anything but a name bound in this block — a parameter, a
// projection, a function in storage — is not followed, and a name bound anywhere
// inside the walked expression is not counted, without regard to nesting. A
// missed report, never a rejected valid program. Control flow is *not* modelled:
// an `$if` arm that would read the slot is reported whether or not it is taken,
// which is exactly how the syntactic half of the rule already treats a direct
// reference, so the two halves agree.
$decl fwd_hit $func ($decl n "", $decl v "") { $decl name n  $decl via v }
$decl no_hit  $call fwd_hit ("", "")
// One walk's visited set, so a call graph with a cycle or a diamond is walked
// once per function rather than once per path.
$decl fwd_st       $func () { $decl seen $mut $alloc Pa.pstrs.node }
$decl proto_fwd_st $call fwd_st ()

// Forms whose operands do not run when the form is evaluated: a `$func` body
// runs when called, a `$template` when specialized, and the rest are
// compile-time or type-only (§5.7). `$import` is here because §4.14 lowers a
// module against the root block alone, so it cannot name an importer's slot.
$decl fwd_lazy $func ($decl k "")
  $if ($call eq_str (k, "func")) true
  ($if ($call eq_str (k, "template")) true
  ($if ($call eq_str (k, "specialize")) true
  ($if ($call eq_str (k, "prop")) true
  ($if ($call eq_str (k, "fwd")) true
  ($if ($call eq_str (k, "impl")) true
  ($if ($call eq_str (k, "traitsof")) true
  ($if ($call eq_str (k, "extern")) true
  ($call eq_str (k, "import")))))))))

// §4.8a evaluates a `$union` to its first member; the rest are type-only (§5.7)
// and may name a declaration in progress.
$decl union_first $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "group"}
    $if ($call eq_int ($call Pa.nodes.length (n.items, 0), 0)) ($call Pa.n_err ("", 0, 0))
        ($call Pa.nodes.nth (n.items, 0)),
  $case n n
)

// While the walk's group is solved its results are §5.5 placeholders, and
// projecting `.name` off one fails; an identity at the intended type defers it.
$decl hit_val $func ($decl h no_hit) h

$fwd fwd_reach

$decl fwd_reach_list $func ($decl xs Pa.nodes.node, $decl pend Pa.pstrs.node,
    $decl fns fnlit_list.node,
                            $decl bound Pa.pstrs.node, $decl st proto_fwd_st, $decl via "")
                                $match xs (
  $case {$prop tag "cons"} {
    $decl h   $call hit_val ($call fwd_reach (xs.head, pend, fns, bound, st, via))
    $decl ret $if ($call eq_str (h.name, ""))
        ($call fwd_reach_list (xs.tail, pend, fns, bound, st, via)) h
  }.ret,
  $case xs no_hit
)

// The callee of a `$call` runs its body now. A `$func` literal in callee
// position is followed as it stands; a name is followed when this block binds
// it to a literal and nothing inside the walk rebinds it.
$decl fwd_follow $func ($decl c Pa.proto_node, $decl pend Pa.pstrs.node, $decl fns fnlit_list.node,
                        $decl bound Pa.pstrs.node, $decl st proto_fwd_st, $decl via "")
  $if ($call is_form (c, "func"))
      ($call fwd_reach ($call op (c, 1), pend, fns, $call Pa.bound_names (c, bound), st, via)) {
        $decl nm $call name_of (c)
        $decl f  $call find_fnlit (fns, nm)
        $decl go $call and ($call not ($call eq_str (f.name, "")),
                 $call and ($call not ($call Pa.mem_pstr (bound, nm)),
                            $call not ($call Pa.mem_pstr (st.seen, nm))))
        $decl ret $if go
            ($do ($set st.seen ($call Pa.pstrs.cons (nm, st.seen)))
                 ($call fwd_reach ($call op (f.lit, 1), pend, fns,
                                   $call Pa.bound_names (f.lit, Pa.pstrs.nil), st, nm)))
            no_hit
      }.ret

$decl fwd_reach_call $func ($decl c Pa.proto_node, $decl ops Pa.nodes.node,
    $decl pend Pa.pstrs.node,
                            $decl fns fnlit_list.node, $decl bound Pa.pstrs.node,
                            $decl st  proto_fwd_st, $decl via "") {
  $decl h   $call hit_val ($call fwd_reach_list (ops, pend, fns, bound, st, via))
  $decl ret $if ($call eq_str (h.name, "")) ($call fwd_follow (c, pend, fns, bound, st, via)) h
}.ret

$decl fwd_reach $func ($decl n Pa.proto_node, $decl pend Pa.pstrs.node, $decl fns fnlit_list.node,
                       $decl bound Pa.pstrs.node, $decl st proto_fwd_st, $decl via "") $match n (
  $case {$prop tag "name"}
    $if ($call and ($call Pa.mem_pstr (pend, n.text), $call not ($call Pa.mem_pstr (bound,
        n.text))))
        ($call fwd_hit (n.text, via)) no_hit,
  $case {$prop tag "group"}      ($call fwd_reach_list (n.items, pend, fns, bound, st, via)),
  $case {$prop tag "block"}      ($call fwd_reach_list (n.items, pend, fns, bound, st, via)),
  $case {$prop tag "proj_name"}  ($call fwd_reach (n.target, pend, fns, bound, st, via)),
  $case {$prop tag "proj_index"} ($call fwd_reach (n.target, pend, fns, bound, st, via)),
  $case {$prop tag "form"}
    $if ($call fwd_lazy (n.keyword)) no_hit
    // A `$case` pattern is type-only (§5.7); only the arm runs.
    ($if ($call eq_str (n.keyword, "case"))
         ($call fwd_reach ($call Pa.nodes.nth (n.operands, 1), pend, fns, bound, st, via))
    ($if ($call eq_str (n.keyword, "union"))
         ($call fwd_reach ($call union_first ($call Pa.nodes.nth (n.operands, 0)), pend, fns, bound,
             st, via))
    ($if ($call eq_str (n.keyword, "call"))
         ($call fwd_reach_call ($call Pa.nodes.nth (n.operands, 0), n.operands, pend, fns, bound,
             st, via))
         ($call fwd_reach_list (n.operands, pend, fns, bound, st, via))))),
  $case n no_hit
)

$decl fwd_msg $func ($decl h no_hit)
  $if ($call eq_str (h.via, ""))
      ($call concat ("'", $call concat (h.name,
          "' is read before the $decl completing its $fwd has run (§4.11); until then only a $func or $template body may name it")))
      ($call concat ("'", $call concat (h.name,
          $call concat ("' is read before the $decl completing its $fwd has run (§4.11): this runs first and reaches a call to '",
          $call concat (h.via, "', whose body reads it")))))

// Every `$decl name $func …` in the block: the bodies a call by name can reach.
$decl decl_fns $func ($decl items Pa.nodes.node, $decl acc fnlit_list.node) $match items (
  $case {$prop tag "cons"}
    $call decl_fns (items.tail,
      // Nested, not `and`: `and` is strict and `op` on a `$fwd` has no operand 1.
      $if ($call is_form (items.head, "decl"))
          ($if ($call is_form ($call op (items.head, 1), "func"))
               ($call fnlit_list.cons ($call fnlit_ent ($call name_of ($call op (items.head, 0)),
                                                        $call op (items.head, 1)), acc))
               acc)
          acc),
  $case items acc
)

$decl fwd_drop $func ($decl xs Pa.pstrs.node, $decl nm "", $decl acc Pa.pstrs.node) $match xs (
  $case {$prop tag "cons"}
    $call fwd_drop (xs.tail, nm, $if ($call eq_str (xs.head, nm)) acc ($call Pa.pstrs.cons (xs.head,
        acc))),
  $case xs acc
)

$decl has_fwd $func ($decl items Pa.nodes.node) $match items (
  $case {$prop tag "cons"} $if ($call is_form (items.head, "fwd")) true ($call has_fwd (items.tail)),
  $case items false
)

// `pend` is the `$fwd` names seen and not yet completed. A `$prop` is skipped:
// it is compile-time and sees only props (§4.10), never an ordered slot.
$decl check_fwd_go $func ($decl cx proto_ctx, $decl items Pa.nodes.node, $decl fns fnlit_list.node,
                          $decl pend Pa.pstrs.node) $match items (
  $case {$prop tag "cons"} {
    $decl it items.head
    $decl nm $call binder_name (it)
    $decl k  $call binder_kind (it)
    // A `$defer` runs when the block is done (§4.15a), after every completion in it.
    $decl live $call and ($call not ($call eq_str (k, "fwd")),
               $call and ($call not ($call eq_str (k, "prop")),
               $call and ($call not ($call is_form (it, "defer")),
                          $call lt (0, $call Pa.pstrs.length (pend, 0)))))
    $decl e    $if ($call eq_str (k, "decl")) ($call op (it, 1)) it
    $decl h    $if live
        ($call fwd_reach (e, pend, fns, $call Pa.bound_names (e, Pa.pstrs.nil), $call fwd_st (),
            ""))
        no_hit
    $decl said $if ($call eq_str (h.name, "")) T.t_bot ($call err (cx, $call fwd_msg (h), it))
    $decl p2   $if ($call eq_str (k, "fwd")) ($call Pa.pstrs.cons (nm, pend))
                   ($if ($call eq_str (k, "decl")) ($call fwd_drop (pend, nm, Pa.pstrs.nil)) pend)
    $decl ret  $call check_fwd_go (cx, items.tail, fns, p2)
  }.ret,
  $case items ()
)

// Most blocks have no `$fwd`, and those cost one scan.
$decl check_fwd_reads $func ($decl cx proto_ctx, $decl items Pa.nodes.node)
  $if ($call has_fwd (items))
      ($call check_fwd_go (cx, items, $call decl_fns (items, fnlit_list.nil), Pa.pstrs.nil))
      ()

$decl infer_params_go $func ($decl cx proto_ctx, $decl e env.node, $decl ps Pa.nodes.node,
                             $decl acc T.tys.node, $decl inner env.node) $match ps (
  $case {$prop tag "cons"} {
    $decl d  ps.head
    $decl ok $call is_form (d, "decl")
    $decl nm $if ok ($call name_of ($call op (d, 0))) ""
    $decl ty $if ok ($call infer (cx, e, $call op (d, 1)))
                    ($call err (cx, "$func parameters must each be a $decl", d))
    $decl ret $call infer_params_go (cx, e, ps.tail,
                  $call T.tys.cons (ty, acc), $call bind (inner, nm, ty))
  }.ret,
  $case ps ($call pres ($call T.tys.reverse (acc, T.tys.nil), inner))
)

// §3.4 makes the parameter list a group of `$decl`s, so §4.1's one binding per
// name reaches it: two parameters of one name take two frame slots (§7.2) and
// the second hides the first, so the argument passed for the first can never
// be read. The check lives here rather than at the call sites because a `$func`
// is typed in three places (`infer_func`, `infer_rec_func`, `infer_fwd_body`)
// and putting a rule in only one of them has looked like a no-op twice before.
$decl infer_params $func ($decl cx proto_ctx, $decl e env.node, $decl ps Pa.nodes.node,
                          $decl acc T.tys.node, $decl inner env.node) {
  $decl uniq $call check_unique (cx, ps, Pa.nodes.nil, "a parameter of this $func")
  $decl ret  $call infer_params_go (cx, e, ps, acc, inner)
}.ret

// §5.5 for a function that names itself.
//
// A bare placeholder `R` cannot be called, so binding the name to `R` and
// typing the body would report "not callable" instead of tying the knot. But
// §3.4 gives the parameter types *before* the body is typed, so the only
// unknown is the result: bind the name to `[params] -> R`, type the body, and
// close `R` over it. §5.5's own example then comes out exactly as the spec
// states it — the μ binds the *return* type, giving a list type.
//
// `pe` is where the parameter defaults are typed, when that differs from `e`: a
// member's (§4.10, `recv_one`), whose defaults see the declaring name as the block's
// type and whose body sees it as the receiver. Empty means `e`.
$decl infer_rec_func $func ($decl cx proto_ctx, $decl e env.node, $decl nm "",
    $decl n Pa.proto_node, $decl pe env.node) {
  $decl ps       $call group_items ($call op (n, 0))
  $decl id       $call fresh (cx)
  $decl penv     $if ($call env.is_nil (pe)) e pe
  $decl r        $call infer_params (cx, penv, ps, T.tys.nil, e)
  $decl mr       $call mark_params (cx, ps, r.tys, r.env, 0, 0, n)
  $decl self     $call T.t_func (r.tys, $call T.t_var (id))
  $decl benv     $call bind (mr.env, nm, self)
  $decl going    $set cx.inprog ($call hint_list.cons ($call hint_ent (nm, id), cx.inprog))
  $decl saved    $call tval (cx.tryset)
  $decl cleared  $set cx.tryset T.t_bot
  $decl din      $set cx.fdepth ($call add ($call ival (cx.fdepth), 1))
  // §5.3a's owner rule leaves this body's own projection to R2 (`owner_check`).
  $decl fb0      $call sval (cx.fbody)
  $decl fb1      $set cx.fbody ($call fn_key_of (cx, $call op (n, 1)))
  $decl body     $call infer (cx, benv, $call op (n, 1))
  $decl fb2      $set cx.fbody fb0
  $decl dout     $set cx.fdepth ($call sub ($call ival (cx.fdepth), 1))
  $decl tries    $call tval (cx.tryset)
  $decl restored $set cx.tryset saved
  $decl res0     $call join_m (cx, body, tries)
  $decl gone     $set cx.inprog ($call drop_prog ($call hint_list.val (cx.inprog), id,
                     hint_list.nil))
  // `μR.R` is uninhabited: a function whose only result is its own recursive
  // call never returns, so its result type is ⊥ (§3.6).
  $decl res  $if ($call T.ty_eq (res0, $call T.t_var (id))) T.t_bot ($call close_rec (cx, res0, id,
      n))
  // §5.3a — see `func_close`. A top-level `$decl` of a `$func` is typed here rather than
  // in `infer_func`, because its own name has to be bound while its body is typed (§5.5).
  $decl ret  $call func_close (cx, e, n, ps, r.tys, res, mr, id)
}.ret

$decl infer_func $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl ps $call group_items ($call op (n, 0))
  $decl r  $call infer_params (cx, e, ps, T.tys.nil, e)
  $decl mr $call mark_params (cx, ps, r.tys, r.env, 0, 0, n)
  // Each `$func` has its own error set (§4.15); save and restore the
  // enclosing one, since `$try` targets the *nearest* function.
  $decl saved    $call tval (cx.tryset)
  $decl cleared  $set cx.tryset T.t_bot
  $decl din      $set cx.fdepth ($call add ($call ival (cx.fdepth), 1))
  // §5.3a's owner rule leaves this body's own projection to R2 (`owner_check`).
  $decl fb0      $call sval (cx.fbody)
  $decl fb1      $set cx.fbody ($call fn_key_of (cx, $call op (n, 1)))
  $decl body     $call infer (cx, mr.env, $call op (n, 1))
  $decl fb2      $set cx.fbody fb0
  $decl dout     $set cx.fdepth ($call sub ($call ival (cx.fdepth), 1))
  $decl tries    $call tval (cx.tryset)
  $decl restored $set cx.tryset saved
  // §4.15: "The enclosing function's inferred return type gains
  // `type(e) & pat` as union members." Joining with ⊥ is the identity, so a
  // function with no `$try` is unaffected.
  $decl res  $call join_m (cx, body, tries)
  // §5.3a's first clause — the frame this `$func` returns to is gone by the time the
  // caller has the value — and the rest of it, in `func_close`.
  $decl ret  $call func_close (cx, e, n, ps, r.tys, res, mr, -1)
}.ret

// ----------------------------------------------------------------- §4.8 overloads

$decl is_over $func ($decl t T.proto_ty) $match t ($case {$prop tag "over"} true, $case t false)

// An argument as a parameter of type `p` sees it: storage where `p` wants storage or a
// trait object (§5.4, §6), a value everywhere else.
$decl arg_as $func ($decl p T.proto_ty, $decl raw T.proto_ty)
  $if ($call or ($call is_ref (p), $call T.is_trait (p))) raw ($call deref_ty (raw))

$fwd over_fits

// §4.8: whether an argument fits a parameter — an overload argument fits when one of its
// candidates does, and §5.5 lets an argument still holding a placeholder fit anything
// (it resolves "as if it were ⊥", and the constraint is checked once the knot is tied).
$decl arg_fits $func ($decl p T.proto_ty, $decl raw T.proto_ty) {
  $decl a   $call arg_as (p, raw)
  $decl ret $if ($call has_free_var (a)) true
      ($if ($call T.sub (a, p)) true
      ($if ($call and ($call is_over (a), $call not ($call is_over (p))))
           ($call over_fits (p, a)) false))
}.ret

// The first candidate of overload `o` that parameter `p` accepts, or ⊥ (§4.8).
$decl cand_for $func ($decl cs T.tys.node, $decl p T.proto_ty) $match cs (
  $case {$prop tag "cons"}
    $if ($call T.sub ($call T.tval (cs.head), p)) ($call T.tval (cs.head))
        ($call cand_for ($call T.tys.val (cs.tail), p)),
  $case cs T.t_bot
)

$decl over_fits $func ($decl p T.proto_ty, $decl o T.proto_ty) $match o (
  $case {$prop tag "over"}
    $call not ($call T.same ($call cand_for ($call T.tys.val (o.cands), p), T.t_bot)),
  $case o false
)

// Every argument fits its parameter, and there are no more arguments than parameters
// (fewer is fine: the defaults fill in, §3.4).
$decl args_fit $func ($decl ps T.tys.node, $decl rs T.tys.node) $match rs (
  $case {$prop tag "cons"} $match ps (
      $case {$prop tag "cons"}
        $if ($call arg_fits ($call T.tval (ps.head), $call T.tval (rs.head)))
            ($call args_fit ($call T.tys.val (ps.tail), $call T.tys.val (rs.tail))) false,
      $case ps false),
  $case rs true
)

// §4.8: the **first** candidate whose parameters accept the arguments, left to right; a
// candidate that is itself an overload fits if any of its own do. ⊥ when none does.
$decl pick_cand $func ($decl cs T.tys.node, $decl rs T.tys.node) $match cs (
  $case {$prop tag "cons"} {
    $decl c   $call T.unroll ($call deref_ty ($call T.tval (cs.head)))
    $decl hit $match c (
        $case {$prop tag "func"} $if ($call args_fit ($call T.tys.val (c.params), rs)) c T.t_bot,
        $case {$prop tag "over"} ($call pick_cand ($call T.tys.val (c.cands), rs)),
        $case c T.t_bot
      )
    $decl ret $if ($call T.same (hit, T.t_bot)) ($call pick_cand ($call T.tys.val (cs.tail), rs))
                  hit
  }.ret,
  $case cs T.t_bot
)

// Each argument's type, as written, typed once: an overloaded call chooses its candidate
// from these and `check_typed` checks them against it.
$decl arg_types $func ($decl cx proto_ctx, $decl e env.node, $decl as Pa.nodes.node,
    $decl acc T.tys.node) $match as (
  $case {$prop tag "cons"}
    $call arg_types (cx, e, $call Pa.nodes.val (as.tail),
        $call T.tys.cons ($call infer (cx, e, as.head), acc)),
  $case as ($call T.tys.reverse (acc, T.tys.nil))
)

// §4.8's lint: a candidate whose parameters are a subtype of an earlier one's is never
// chosen, since first fit takes the earlier one for every argument it accepts.
$decl covers $func ($decl a T.tys.node, $decl b T.tys.node) $match b (
  $case {$prop tag "cons"} $match a (
      $case {$prop tag "cons"}
        $if ($call T.sub ($call T.tval (b.head), $call T.tval (a.head)))
            ($call covers ($call T.tys.val (a.tail), $call T.tys.val (b.tail))) false,
      $case a false),
  $case b ($call T.tys.is_nil (a))
)

$decl shadowed_by $func ($decl earlier T.tys.node, $decl c T.proto_ty) $match earlier (
  $case {$prop tag "cons"} {
    $decl x   $call T.unroll ($call T.tval (earlier.head))
    $decl y   $call T.unroll (c)
    $decl hit $match x (
        $case {$prop tag "func"} $match y (
            $case {$prop tag "func"}
              ($call covers ($call T.tys.val (x.params), $call T.tys.val (y.params))),
            $case y false),
        $case x false
      )
    $decl ret $if hit true ($call shadowed_by ($call T.tys.val (earlier.tail), c))
  }.ret,
  $case earlier false
)

$decl lint_cands $func ($decl cx proto_ctx, $decl ns Pa.nodes.node, $decl ts T.tys.node,
    $decl seen T.tys.node) $match ns (
  $case {$prop tag "cons"} $match ts (
      $case {$prop tag "cons"} {
        $decl t   $call T.tval (ts.head)
        $decl chk $if ($call shadowed_by ($call T.tys.reverse (seen, T.tys.nil), t))
            ($call err (cx, "this candidate is never chosen: an earlier one accepts every argument it does, and §4.8 is first fit", ns.head))
            T.t_unit
        $decl ret $call lint_cands (cx, $call Pa.nodes.val (ns.tail), $call T.tys.val (ts.tail),
                      $call T.tys.cons (t, seen))
      }.ret,
      $case ts ()),
  $case ns ()
)

// §4.8: `$overload cands` is the group at run time, and its type marks it an overload set,
// ordered as written.
$decl infer_overload $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl cs  $call group_items ($call op (n, 0))
  $decl ts  $call arg_types (cx, e, cs, T.tys.nil)
  $decl lnt $call lint_cands (cx, cs, ts, T.tys.nil)
  $decl ret $call T.t_over (ts)
}.ret

$decl ts_rest $func ($decl xs T.tys.node) $match xs (
  $case {$prop tag "cons"} ($call T.tys.val (xs.tail)),
  $case xs xs
)

// One argument against its parameter: §6's coercion, §5.3a's escape, a deferred call
// against a function still being typed, §4.8's overload resolution, and the subtype check
// — or §5.5's deferral of it while a knot is open. False on an error.
$decl check_one $func ($decl cx proto_ctx, $decl p T.proto_ty, $decl x Pa.proto_node,
                       $decl raw T.proto_ty, $decl i 0, $decl es T.cints.node, $decl pd -1) {
  $decl at0 $call arg_as (p, raw)
  // §4.8: an overload passed where one type is expected resolves to the first
  // candidate the parameter accepts; passed to an overload parameter it stays one.
  $decl at  $if ($call and ($call is_over (at0), $call not ($call is_over (p))))
                ($match at0 (
                    $case {$prop tag "over"} ($call cand_for ($call T.tys.val (at0.cands), p)),
                    $case at0 at0))
                at0
  $decl why $call concat ("argument ", $call concat ($call int_to_str (i), " is "))
  // What is passed holds a place when the parameter takes storage and the argument is
  // one, or when the value read through it holds one (§5.4) — recorded for `owns_x`.
  // A value coerced to a trait object passes the object, which refers to the value's own
  // storage (`tobj_of`): frame-bound as `traitsof_frame` says, and own as `owns_arg` says.
  $decl tco $if ($call T.is_trait (p))
                ($call P.and ($call not ($call T.is_trait ($call deref_ty (raw))),
                              $match raw ($case {$prop tag "ref"} false, $case raw true)))
                false
  $decl pl  $if tco
                ($if ($call traitsof_frame (cx, x, raw))
                     ($set cx.placed ($call strs.cons ($call fn_key_of (cx, x),
                          $call strs.val (cx.placed))))
                     ($call strs.val (cx.placed)))
                ($call note_placed (cx, x, $match p ($case {$prop tag "ref"} raw,
                                                     $case p ($call deref_ty (raw)))))
  $decl sr  $if tco ($set cx.slotref ($call strs.cons ($call fn_key_of (cx, x),
                                                        $call strs.val (cx.slotref))))
                ($call strs.val (cx.slotref))
  $decl cw  $call coerce_why (x, raw, p)
  $decl ae  $if ($call T.ci_mem (es, $call sub (i, 1))) ($call arg_escapes (cx, x, raw, p, i)) raw
  // §5.3a's borrowing: an argument whose parameter the callee's result borrows lends what
  // it carries to the result — and for a callee still being typed, whose borrows are not
  // known yet, every function- or trait-typed argument does, which can only be stricter.
  $decl bw  $if ($if ($call T.ci_mem (es, $call add (63, i))) true
                     ($if ($call lt (-1, pd)) ($call T.markable (p)) false))
                ($call note_barg (cx, x, raw, p)) ()
  // DEFER.md: the callee frees this parameter (through the root), so a name passed here
  // is freed by this function too.
  $decl fr  $if ($call T.ci_mem (es, $call add (127, i))) ($call note_freed (cx, x, true)) ()
  // A callee still being typed: its escaping parameters come later (`func_close`).
  // Only an argument that could be refused or could carry a mark is worth keeping,
  // and nearly none is — keeping every one made each closing function rescan them.
  $decl rec $set cx.pesc ($if ($if ($call lt (pd, 0)) true
                                   ($call not ($call may_escape (cx, x, raw, p))))
                              ($call pesc_list.val (cx.pesc))
                ($call pesc_list.cons ($call pesc_ent (pd, $call sub (i, 1), x, raw,
                    p, $call ival (cx.curfn), $call fframes.val (cx.fstack)), cx.pesc)))
  $decl ret $if ($call not ($call eq_str (cw, "")))
      ($do ($call err (cx, cw, x)) false)
      ($if ($call T.sub (at, p)) true
      // §5.5: a constraint on an unresolved `R` is checked after the knot is tied, not
      // now — otherwise every call inside a recursive group would fail against its own
      // placeholder.
      ($if ($call or ($call has_free_var (at), $call has_free_var (p)))
          ($do ($call defer_check (cx, at, p, why, x)) true)
          ($do ($call T.explain (at, p))
               ($do ($call err (cx, $call concat (why, $call concat ($call T.show (at),
                         $call concat (", expected ", $call T.show (p)))), x))
                    false))))
}.ret

$decl check_args $func ($decl cx proto_ctx, $decl e env.node, $decl ps T.tys.node,
                        $decl as Pa.nodes.node, $decl n Pa.proto_node, $decl i 1,
                        $decl es T.cints.node, $decl pd -1) $match as (
  $case {$prop tag "cons"} $match ps (
      $case {$prop tag "cons"}
        $if ($call check_one (cx, ps.head, as.head, $call infer (cx, e, as.head), i, es, pd))
            ($call check_args (cx, e, ps.tail, as.tail, n, $call add (i, 1), es, pd)) false,
      $case ps ($do ($call err (cx, "too many arguments", n)) false)
    ),
  // Fewer arguments than parameters is fine: the defaults fill in (§3.4).
  $case as true
)

// The same, against types already inferred — an overloaded call types its arguments
// once, to choose a candidate (§4.8), and checks them against it without typing again.
$decl check_typed $func ($decl cx proto_ctx, $decl ps T.tys.node, $decl as Pa.nodes.node,
                         $decl rs T.tys.node, $decl n Pa.proto_node, $decl i 1,
                         $decl es T.cints.node) $match as (
  $case {$prop tag "cons"} $match ps (
      $case {$prop tag "cons"}
        $if ($call check_one (cx, ps.head, as.head, $call T.tys.nth (rs, 0), i, es, -1))
            ($call check_typed (cx, ps.tail, as.tail, $call ts_rest (rs), n, $call add (i, 1),
                es)) false,
      $case ps ($do ($call err (cx, "too many arguments", n)) false)
    ),
  $case as true
)

// Below `specialize_with`, which it needs.
$fwd infer_apply

$decl infer_call_std $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl ft   $call deref_ty ($call infer (cx, e, $call op (n, 0)))
  $decl args $call group_items ($call op (n, 1))
  $decl ret $match ft (
      $case {$prop tag "func"} {
        $decl rv $call T.tval (ft.result)
        $decl pd $match rv (
            $case {$prop tag "var"}
              $if ($call in_prog ($call hint_list.val (cx.inprog),
                       $call callee_name ($call op (n, 0)), rv.id)) rv.id -1,
            $case rv -1)
        $decl ok $call check_args (cx, e, ft.params, args, n, 1, $call T.cints.val (ft.esc), pd)
        // DEFER.md: a callee still being typed has no answer yet, which counts as "may".
        $decl nr0 $call T.ci_mem ($call T.cints.val (ft.esc), 1000)
        $decl nr $if ($if nr0 true ($call lt (-1, pd)))
                     ($do ($set cx.nonroot ($call strs.cons ($call fn_key_of (cx, n),
                              $call strs.val (cx.nonroot))))
                          ()) ()
        $decl cb $if ($call extern_callee (cx, $call op (n, 0)))
            ($call chk_cbs (cx, $call T.tys.val (ft.params), args)) T.t_unit
        // A `$decl` initializer keeps a reference (§5.4), and `result` is
        // storage now, so the type has to be taken out of it here.
        $decl ret2  $if ok ($call T.tval (ft.result)) T.t_bot
      }.ret2,
      // §4.8: the first candidate accepting the arguments, then checked as an ordinary call.
      $case {$prop tag "over"} {
        $decl rs   $call arg_types (cx, e, args, T.tys.nil)
        $decl c    $call pick_cand ($call T.tys.val (ft.cands), rs)
        $decl ret2 $match c (
            $case {$prop tag "func"} {
              $decl ok   $call check_typed (cx, $call T.tys.val (c.params), args, rs, n, 1,
                             $call T.cints.val (c.esc))
              $decl ret3 $if ok ($call T.tval (c.result)) T.t_bot
            }.ret3,
            $case c ($call err (cx, $call concat ("no candidate of ", $call concat ($call T.show (ft),
                " accepts these arguments (§4.8)")), n))
          )
      }.ret2,
      // §3.6: a call on ⊥ stays ⊥ rather than reporting a second error.
      $case {$prop tag "bottom"} T.t_bot,
      // §4.9: application infers the generics from the argument shapes. Stage 0 does
      // not (BOOTSTRAP.md §1.1 keeps it out of the subset), and stage 1 never relies on it.
      $case {$prop tag "tmpl"} ($call infer_apply (cx, e, ft.id, args, n)),
      $case ft ($call err (cx, $call concat ($call T.show (ft), " is not callable"), n))
    )
}.ret

// §2.2: `$if c a b` is sugar for `$match c ($case true a, $case false b)`.

// §8's `box_ptr` and `unbox`, which the root block binds at marker types because
// it cannot say "for any T" (`T.ffi_box`). Recognised by name *and* marker, so a
// user's own `unbox` shadows the intrinsic as it shadows any other.
$decl ffi_which $func ($decl e env.node, $decl c Pa.proto_node) {
  $decl nm  $call callee_name (c)
  $decl f   $call lookup (e, nm)
  $decl ret $if ($call not (f.ok)) ""
      ($if ($call and ($call eq_str (nm, "box_ptr"), $call T.same (f.ty, T.ffi_box))) nm
      ($if ($call and ($call eq_str (nm, "unbox"), $call T.same (f.ty, T.ffi_unbox))) nm
      ($if ($call and ($call eq_str (nm, "array"), $call T.same (f.ty, T.ffi_array))) nm
      ($if ($call and ($call eq_str (nm, "at"), $call T.same (f.ty, T.ffi_at))) nm
      ($if ($call and ($call eq_str (nm, "alen"), $call T.same (f.ty, T.ffi_alen))) nm
      ($if ($call and ($call eq_str (nm, "array_ptr"), $call T.same (f.ty, T.ffi_aptr))) nm
           ""))))))
}.ret

$decl is_bot_ty $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "bottom"} true,
  $case t false
)

// The element type of an array argument, or ⊥ after reporting what it was instead.
$decl arr_elem $func ($decl cx proto_ctx, $decl t T.proto_ty, $decl w "", $decl n Pa.proto_node) {
  $decl u   $call T.unroll (t)
  $decl ret $match u (
      $case {$prop tag "array"} ($call T.tval (u.elem)),
      $case {$prop tag "bottom"} T.t_bot,
      $case u ($call err (cx, $call concat (w, $call concat (" takes an array, found ",
                  $call T.show (u))), n)))
}.ret

$decl want_int $func ($decl cx proto_ctx, $decl t T.proto_ty, $decl what "", $decl n Pa.proto_node)
  $if ($call T.sub (t, T.t_int)) true
      ($do ($call err (cx, $call concat (what, $call concat (" is ", $call concat ($call T.show (t),
               ", expected Int"))), n)) false)

// §8's arrays: `array (n, example)` is `n` copies of the example, `[T]` at its type, and
// what it holds is storage — so A0 holds for it as for `$alloc` (§5.3a): no place inside.
// `at (a, i)` is the element's storage, `&mut T`; `alen (a)` and `array_ptr (a)` are `Int`.
$decl infer_arr $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form, $decl w "",
                       $decl args Pa.nodes.node, $decl na 0) {
  $decl need $if ($call or ($call eq_str (w, "array"), $call eq_str (w, "at"))) 2 1
  $decl ret  $if ($call not ($call eq_int (na, need)))
      ($call err (cx, $call concat (w, $call concat (" takes ", $call concat ($call int_to_str (need),
          $if ($call eq_int (need, 1)) " argument" " arguments"))), n))
      ($if ($call eq_str (w, "array")) {
         $decl k    $call want_int (cx, $call deref_ty ($call infer (cx, e,
                        $call Pa.nodes.nth (args, 0))), "array's length", n)
         $decl v    $call deref_ty ($call infer (cx, e, $call Pa.nodes.nth (args, 1)))
         $decl np   $call no_place (cx, v, n)
         $decl ret2 $if k ($call T.t_array (v)) T.t_bot
       }.ret2 {
         $decl el   $call arr_elem (cx, $call deref_ty ($call infer (cx, e,
                        $call Pa.nodes.nth (args, 0))), w, n)
         $decl ok   $if ($call eq_str (w, "at"))
                        ($call want_int (cx, $call deref_ty ($call infer (cx, e,
                             $call Pa.nodes.nth (args, 1))), "at's index", n)) true
         $decl ret2 $if ($call is_bot_ty (el)) T.t_bot
                        ($if ($call eq_str (w, "at")) ($if ok ($call T.t_ref ("mut", el)) T.t_bot)
                             T.t_int)
       }.ret2)
}.ret

// `box_ptr (r)`: the address of storage, so the argument must be a reference and is
// not read through. `unbox (addr, example)`: the reference at an address, typed by
// the example — allocated and writable, because what it points at is the C side's
// and outside every frame (§4.16 rule 1: unsafe by declaration).
$decl infer_ffi $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form, $decl w "") {
  $decl args $call group_items ($call op (n, 1))
  $decl na   $call Pa.nodes.length (args, 0)
  $decl ret  $if ($if ($call eq_str (w, "box_ptr")) false ($call not ($call eq_str (w, "unbox"))))
      ($call infer_arr (cx, e, n, w, args, na))
      ($if ($call eq_str (w, "box_ptr"))
      ($if ($call eq_int (na, 1)) {
         $decl t    $call T.unroll ($call infer (cx, e, $call Pa.nodes.nth (args, 0)))
         $decl ret2 $match t (
             $case {$prop tag "ref"} T.t_int,
             $case t ($call err (cx, $call concat ("box_ptr takes storage, found ",
                 $call T.show (t)), n)))
       }.ret2 ($call err (cx, "box_ptr takes one argument, the storage", n)))
      ($if ($call eq_int (na, 2)) {
         $decl a    $call deref_ty ($call infer (cx, e, $call Pa.nodes.nth (args, 0)))
         $decl ok   $if ($call T.sub (a, T.t_int)) true
             ($do ($call err (cx, $call concat ("unbox's address is ", $call concat (
                  $call T.show (a), ", expected Int")), n)) false)
         $decl v    $call deref_ty ($call infer (cx, e, $call Pa.nodes.nth (args, 1)))
         // §5.3a's A0 holds for C's memory too: what `unbox` names is storage.
         $decl np   $call no_place (cx, v, n)
         $decl ret2 $if ok ($call T.t_ref_k ("mut", v, T.k_alloc)) T.t_bot
       }.ret2 ($call err (cx, "unbox takes two arguments, an address and an example", n))))
}.ret

$decl infer_call $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl w   $call ffi_which (e, $call op (n, 0))
  // This call's own borrow record, saved and restored around it so a call nested in an
  // argument keeps its own.
  $decl sm  $call T.cints.val (cx.bmarks)
  $decl sf  $call P.bval (cx.bframe)
  $decl z1  $set cx.bmarks T.cints.nil
  $decl z2  $set cx.bframe false
  $decl r0  $if ($call eq_str (w, "")) ($call infer_call_std (cx, e, n))
                ($call infer_ffi (cx, e, n, w))
  // A result that borrows a frame-bound argument is frame-bound, and carries what the
  // argument carried — so the caller's own §5.3a sees where it came from.
  $decl bm  $call T.cints.val (cx.bmarks)
  $decl r1  $if ($call P.bval (cx.bframe)) ($call T.make_frame (r0)) r0
  $decl r   $call mark_all (r1, bm)
  $decl b1  $set cx.bmarks sm
  $decl b2  $set cx.bframe sf
  $decl pl  $call note_placed (cx, n, r)
  $decl ow  $call call_storage (cx, n, r)
  $decl ret r
}.ret
$decl infer_if $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl c   $call deref_ty ($call infer (cx, e, $call op (n, 0)))
  $decl chk $if ($call T.sub (c, T.t_bool)) T.t_unit
            ($if ($call has_free_var (c))
                ($call defer_check (cx, c, T.t_bool, "$if condition is ", n))
                ($call err (cx, $call concat ("$if condition must be Bool, found ",
                                $call T.show (c)), n)))
  $decl a   $call infer (cx, e, $call op (n, 1))
  $decl b   $call infer (cx, e, $call op (n, 2))
  $decl ret $call join_m (cx, a, b)
}.ret

// §4.8a: the value is the first member; the type is the union of all of them.
$decl infer_union $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form)
  $call T.t_union ($call infer_tys (cx, e, $call group_items ($call op (n, 0)), T.tys.nil))

// §4.7: "Inside an arm, `e` (by its name) is narrowed to `type(e) & P`."
// Narrowing needs a name to rebind, which is why §4.7 reaches fields "through
// the narrowed scrutinee".
$decl narrow $func ($decl e env.node, $decl scrut Pa.proto_node, $decl t T.proto_ty) $match scrut (
  $case {$prop tag "name"} $call bind (e, scrut.text, t),
  $case scrut e
)

// §4.7 is **first fit**, so an arm whose pattern covers the *whole* scrutinee type
// leaves every arm after it dead. That is worth reporting, because it is almost
// always one mistake: a pattern is a type-only position (§5.7) and there is no
// syntax for writing a type, so `$case 1` denotes the *type* of `1` — `Int` — and
// claims every integer. The intended `$match n ($case 1 …, $case n …)` then answers
// the first arm for every `n`, and nothing said so.
//
// The test is against the whole scrutinee, not against what earlier arms left, and
// that distinction is the whole design of the check. "This arm exhausts the
// remainder" is true of the *last meaningful* arm of every correct `$match` —
// §5.6 requires exhaustiveness and BOOTSTRAP §1.3 makes a trailing catch-all the
// idiom throughout stage 1, so a catch-all that the types say is unreachable is
// the normal shape of working code. Only an arm that covers everything *by itself*
// is evidence of the error, and no correct arm of a partitioning `$match` does.
//
// It therefore does not catch a merely duplicated arm (`$case A …, $case A …`).
// Reporting that needs "what the earlier arms left", which is exactly the test that
// fires on every catch-all — so it is left out rather than made noisy.
// An arm whose pattern no member of the scrutinee's union is of can never run (§4.7 picks
// an arm by the member the discriminator names). It is the other half of the check above,
// and as surely a mistake: usually a misspelt tag — `{$prop tag "err"}` against AST nodes
// tagged `"error"` compiled to a C `switch` arm with no `case`, which is how it was found.
// Only a union asks: a `$match` on anything else has no discriminator, and its first arm
// always wins. A type still holding §5.5's placeholder is not judged, since subtyping
// against one is provisional. A pattern naming storage — the `$case x` catch-all with `x`
// bound to a `$mut` cell — is read through, as the scrutinee is: a `$decl` keeps the
// reference (§5.4), and it was the reference type that made such an arm look dead.
$decl none_sub $func ($decl xs T.tys.node, $decl pt T.proto_ty) $match xs (
  $case {$prop tag "cons"}
    $if ($call T.sub ($call T.tval (xs.head), pt)) false
        ($call none_sub ($call T.tys.val (xs.tail), pt)),
  $case xs true
)
$decl dead_arm $func ($decl st T.proto_ty, $decl pt T.proto_ty) {
  $decl u   $call T.unroll (st)
  $decl ret $if ($if ($call has_free_var (st)) true ($call has_free_var (pt))) false
      ($match u ($case {$prop tag "union"} ($call none_sub ($call T.tys.val (u.members), pt)),
                 $case u false))
}.ret

$decl infer_arms $func ($decl cx proto_ctx, $decl e env.node, $decl scrut Pa.proto_node,
                        $decl st T.proto_ty, $decl arms Pa.nodes.node, $decl acc T.proto_ty)
                            $match arms (
  $case {$prop tag "cons"} {
    $decl a  arms.head
    // A pattern is a type-only position (§5.7): never evaluated, only its
    // type used — which is exactly what `infer` returns.
    $decl pt   $call infer (cx, e, $call op (a, 0))
    $decl rest $call Pa.nodes.val (arms.tail)
    $decl dead $if ($call Pa.nodes.is_nil (rest)) 0
        ($if ($call T.same (pt, st))
             ($do ($call err (cx, "this arm's pattern is the whole scrutinee type, so the arms after it cannot be reached (§4.7 is first fit). A pattern is a *type* (§5.7): `$case 1` means Int, not the value 1", a)) 0)
             0)
    // §4.7: "A trait object is not inspected." Its referent's type is erased, so an arm is
    // decided here: a supertype of the trait always matches and leaves nothing for the arms
    // after it, and anything else never matches. Either way the arm sees the trait object.
    $decl tro $call T.is_trait (st)
    $decl nom $if tro 0
        ($if ($call dead_arm (st, $call deref_ty (pt)))
             ($do ($call err (cx, $call concat ("this arm's pattern, ", $call concat ($call T.show (pt),
                  ", is no member of the scrutinee's type, so the arm can never run (§4.7) — is a tag misspelt?")), a)) 0)
             0)
    $decl tok $if tro ($call T.sub (st, pt)) false
    $decl tck $if tro
        ($if tok
             ($if ($call or ($call Pa.nodes.is_nil (rest), $call T.same (pt, st))) 0
                  ($do ($call err (cx, "this arm always matches a trait object (§4.7), so the arms after it cannot be reached", a)) 0))
             ($do ($call err (cx, "a trait object is not inspected (§4.7): this pattern is not a supertype of its trait, so the arm can never match; match on a union holding it, or ask it through a member", a)) 0))
        0
    // §4.7: narrowed to `type(e) & P` — as a selection, not an intersection.
    $decl e2  $call narrow (e, scrut, $if tro st ($call T.restrict (st, pt)))
    $decl bt  $call infer (cx, e2, $call op (a, 1))
    $decl ret $call infer_arms (cx, e, scrut, st, rest, $call join_m (cx, acc, bt))
  }.ret,
  $case arms acc
)

$decl infer_match $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl sn   $call op (n, 0)
  $decl st   $call deref_ty ($call infer (cx, e, sn))
  $decl arms $call group_items ($call op (n, 1))
  $decl ret  $call infer_arms (cx, e, sn, st, arms, T.t_bot)
}.ret

// §4.15. The error set is inferred, not declared.
$decl infer_try $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  // §4.15: "Outside a `$func` (file top level, prop initializer) it is a compile
  // error." `$try` returns from the nearest enclosing `$func`, and there is none
  // — so nothing rejected it, and such a program was refused only *incidentally*,
  // by the backend failing to coerce the matched member into the thunk's result
  // type. That message named the symptom and not the rule.
  $decl here $if ($call lt (0, $call ival (cx.fdepth))) T.t_bot
      ($call err (cx, "$try is only valid inside a $func: it returns from the nearest enclosing one, and a file's top level or a $prop initializer has none (§4.15)", n))
  $decl vt $call infer (cx, e, $call op (n, 0))
  $decl pt $call infer (cx, e, $call op (n, 1))
  $decl added $set cx.tryset
      ($call T.join (cx.tryset, $call T.restrict ($call deref_ty (vt), pt)))
  // §4.15: "otherwise the expression's value is `e`, narrowed to
  // `type(e) & ¬pat`." For a union of tag shapes — which is what every
  // fallible result is — that is exactly dropping the covered members.
  $decl ret $call T.minus (vt, pt)
}.ret

// ------------------------------------------------ $template and $specialize

$fwd generic_names_list

$decl generic_names $func ($decl n Pa.proto_node, $decl acc strs.node) $match n (
  $case {$prop tag "name"}  $call strs.cons (n.text, acc),
  $case {$prop tag "group"} $call generic_names_list (n.items, acc),
  // `($decl K bound)`, one bounded generic (§4.9).
  $case {$prop tag "form"}  $call strs.cons ($call Pa.generic_name (n), acc),
  $case n acc
)

$decl generic_names_list $func ($decl xs Pa.nodes.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"}
    $call generic_names_list (xs.tail, $call strs.cons ($call Pa.generic_name (xs.head), acc)),
  $case xs ($call strs.reverse (acc, strs.nil))
)

// **A compile-time identity is a function of where it is written, not of a counter.**
// `fresh (cx)` hands out positions in load order, so a template id and a prop's
// `cv_opaque` id both moved when anything ahead of them changed — and both end up in
// a module's *interface* (`list:Tmpl9`, `{box=o4,}`), which makes a serialised
// interface unstable across programs and a per-module cache unable to hit. This is
// the same correction lowering's `const_of` took; inference's was missed because the
// two are separate functions of the same name.
//
// A tag per kind keeps the two spaces apart, and the hash is wide (§9.3's `hmod`), so
// a collision between two distinct constructs is not a practical concern — and would
// be loud rather than silent, since `find_tmpl` looks a template up by id.
// The file's **short** name, not `cx.file`. §4.14 makes every import of one file the
// same module, but the path a module is reached by is the importer's business —
// `stage1/prelude.mpl` and `./stage1/prelude.mpl` are the same file, and hashing the
// spelling gave them different ids, so an interface would have depended on where its
// importer sat. The first cut of this did exactly that: the load-order dependency was
// gone and a path-spelling one had replaced it.
//
// It collapses two modules that share a basename in different directories, which is
// the trade lowering's `mod_short` already makes for the same reason.

$decl ct_id $func ($decl cx proto_ctx, $decl tag 0, $decl n Pa.proto_node) {
  $decl sp $call P.span_of (n)
  $decl h0 $call T.hash_str ($call sval (cx.sctx), 0,
               $call T.hash_str ($call short_of ($call sval (cx.file)), 0, tag))
  $decl ret  $call T.hmix ($call T.hmix (h0, sp.line), sp.col)
}.ret

$decl is_var_ty $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "var"} true,
  $case t false
)

// §4.9's self-specialisation: `$decl list $template T { … $specialize list T … }`.
// A `$decl`'s name inside its own initializer is §5.5's placeholder `R` — and the
// template's body is typed only at specialisation, in the environment recorded
// here, so `list` in it was still `R` then and `$specialize` refused it ("expects a
// template, found v1"). But a template's identity is where it is written
// (`ct_id`, tag 7), not anything its body determines, so it is known before the
// body is recorded: the name is bound to the template itself, and the knot is
// tied by §4.9's memo, which hands back the in-progress entry's `R`.
$decl self_tmpl_env $func ($decl cx proto_ctx, $decl e env.node, $decl nm "",
    $decl init Pa.proto_node)
  $call bind (e, nm, $call T.t_tmpl ($call ct_id (cx, 7, init)))

$decl find_tmpl $func ($decl xs tmpl_list.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_int (xs.head.id, i)) xs.head ($call find_tmpl (xs.tail, i)),
  $case xs ($call tmpl_rec (-1, strs.nil, Pa.proto_node, env.nil, ""))
)

// The compile-time generics of the template a `$specialize`'s target names, by
// position — the resolver `Pa.ct_generics` asks for. The target is typed quietly:
// this runs at the declaration, and the `$specialize` will be typed, and report,
// at specialisation. The template being declared answers from `cur`, the fixpoint's
// current guess, since its record does not exist yet.
$decl ctg_target $func ($decl cx proto_ctx, $decl e env.node, $decl own 0, $decl gs strs.node,
                        $decl cur Pa.ctgs.node, $decl x Pa.proto_node) {
  $decl q0   $call bval (cx.quiet)
  $decl hush $set cx.quiet true
  $decl tt   $call deref_ty ($call infer (cx, e, x))
  $decl back $set cx.quiet q0
  $decl ret $match tt (
      $case {$prop tag "tmpl"}
        $if ($call eq_int (tt.id, own)) ($call Pa.ctg_mask (gs, cur, Pa.pstrs.nil)) {
          $decl r    $call find_tmpl (cx.tmpls, tt.id)
          $decl ret2 $call Pa.ctg_mask (r.generics, r.ctg, Pa.pstrs.nil)
        }.ret2,
      $case tt Pa.pstrs.nil
    )
}.ret

// A self-specialising template passes its own generics to itself, so whether one
// is compile-time can depend on whether another is: iterate until the set stops
// growing. It only grows, and it has at most one entry per generic.
$decl ctg_fix $func ($decl cx proto_ctx, $decl e env.node, $decl own 0, $decl gs strs.node,
                     $decl body Pa.proto_node, $decl cur Pa.ctgs.node, $decl k 0) {
  $decl rs $func ($decl x Pa.proto_node) $call ctg_target (cx, e, own, gs, cur, x)
  $decl nx $call Pa.ct_generics (body, gs, rs)
  $decl ret $if ($call or ($call eq_int ($call Pa.ctgs.length (nx, 0), $call Pa.ctgs.length (cur,
      0)),
                          $call lt (k, 1)))
      nx ($call ctg_fix (cx, e, own, gs, body, nx, $call sub (k, 1)))
}.ret

// §4.9: the declaration itself checks nothing. It records what specialization
// will need and hands back an identity.
$decl infer_template $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl gs    $call generic_names ($call op (n, 0), strs.nil)
  // A generic a prop reads is compile-time by definition (§4.9), and every
  // `$specialize` of this template is held to a constant argument for it — so in
  // the body, reading one is reading a constant, and `ct_init` may say so.
  $decl ctg $set cx.ctnames ($call join_strs (gs, cx.ctnames))
  $decl id  $call ct_id (cx, 7, n)
  $decl cg    $call ctg_fix (cx, e, id, gs, $call op (n, 1), Pa.ctgs.nil,
                  $call strs.length (gs, 0))
  $decl rec   $call tmpl_rec_c (id, gs, $call op (n, 1), e, $call sval (cx.file), cg,
                  $call Pa.generic_bounds ($call op (n, 0)))
  $decl added $set cx.tmpls ($call tmpl_list.cons (rec, cx.tmpls))
  $decl ret   $call T.t_tmpl (id)
}.ret

$decl memo_find $func ($decl xs memo_list.node, $decl k "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.key, k)) ($call found (true, xs.head.ty)) ($call memo_find (xs.tail,
        k)),
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

// §4.11: each reserves its layout slot here and is completed by exactly one
// later `$decl`. Without them these are plain forward references — they work
// at run time, because the slot is filled long before the call, but §4.10 is
// strictly source order and the checker is right to refuse them.
$fwd infer_fwd_body
$fwd infer_block

// §4.9: "its value joins the argument types in the memo key." A literal is keyed by
// its text; any other constant by where it is written, which can split two equal
// constants into two types but never merge two different ones. Lowering builds the
// same string (`lower.mpl`'s `spec_vals`), because the key is what every identity
// in the body is minted from.
$decl ct_vals $func ($decl cx proto_ctx, $decl gs strs.node, $decl args Pa.nodes.node,
                     $decl cg Pa.ctgs.node, $decl acc "") $match gs (
  $case {$prop tag "cons"} $match args (
    $case {$prop tag "cons"} {
      $decl p  $call Pa.ctg_prop (cg, gs.head)
      $decl lk $call Pa.lit_key (args.head)
      $decl v  $if ($call eq_str (p, "")) ""
                   ($if ($call eq_str (lk, ""))
                        ($call concat ("=@", $call int_to_str ($call ct_id (cx, 3, args.head))))
                        ($call concat ("=", lk)))
      $decl ret  $call ct_vals (cx, gs.tail, $call Pa.nodes.val (args.tail), cg, $call concat (acc,
          v))
    }.ret,
    $case args acc),
  $case gs acc
)

// A compile-time generic bound to a literal is replaced by it (`Pa.subst_lit`), so
// the value is in the props — and so in the type.
$decl subst_ct $func ($decl body Pa.proto_node, $decl gs strs.node, $decl args Pa.nodes.node,
                      $decl cg Pa.ctgs.node) $match gs (
  $case {$prop tag "cons"} $match args (
    $case {$prop tag "cons"}
      $call subst_ct (
          $if ($call and ($call not ($call eq_str ($call Pa.ctg_prop (cg, gs.head), "")),
                          $call not ($call eq_str ($call Pa.lit_key (args.head), ""))))
              ($call Pa.subst_lit (body, gs.head, args.head)) body,
          gs.tail, $call Pa.nodes.val (args.tail), cg),
    $case args body),
  $case gs body
)

// Defined below `ct_init`, which it needs.
$fwd ct_args_check

// The template `id` at argument types `ats`. `args` are the argument expressions an
// explicit `$specialize` wrote, which its compile-time generics are read from; an
// application (§4.9, `infer_apply`) has none and infers no compile-time generic, so it
// passes the empty list and every use of `args` below is the identity on it.
// Design point 7's closing step: `μ. trait_of (t)` with the placeholder bound, and the
// placeholder replaced by it throughout `t`'s props.
$decl close_self $func ($decl t T.proto_ty, $decl id 0) {
  $decl tr  $call T.trait_of (t, false, "")
  $decl mu  $call T.t_rec ($call T.remap (tr, $call T.rop_abs (id), 0))
  $decl ret $call T.remap (t, $call T.rop_var (id, mu), 0)
}.ret

// §4.9: "At specialization, `type(arg) <: type(bound)` is checked first and reported as
// such." Each bound is typed with the generics bound to the arguments, which is what makes
// an F-bound work — `$decl K $traitsof ($specialize ord_proto K)` names `K` itself — and in
// the template's own environment, where it was written. Not checked while a placeholder is
// involved (§5.5): the check would be against a type not yet solved. Answers whether every
// bound held; when one did not, the body is not typed, so the bound is what is reported.
$decl is_unit_node $func ($decl b Pa.proto_node) $match b ($case {$prop tag "unit"} true, $case b false)

$decl check_bounds $func ($decl cx proto_ctx, $decl benv env.node, $decl gs strs.node,
                          $decl bs Pa.nodes.node, $decl ats T.tys.node, $decl n Pa.proto_node)
    $match gs (
  $case {$prop tag "cons"} $match bs (
    $case {$prop tag "cons"} $match ats (
      $case {$prop tag "cons"} {
        $decl b    bs.head
        $decl bt   $if ($call is_unit_node (b)) T.t_bot ($call deref_ty ($call infer (cx, benv, b)))
        $decl live $if ($call is_unit_node (b)) false
                       ($call not ($call or ($call has_free_var (ats.head),
                                            $call has_free_var (bt))))
        $decl ok   $if live ($call T.sub (ats.head, bt)) true
        $decl say  $if ok T.t_unit
            ($do ($call T.explain (ats.head, bt))
                 ($call err (cx, $call concat ("the argument for '", $call concat (gs.head,
                     $call concat ("' does not satisfy its bound: ", $call concat ($call T.show (ats.head),
                     $call concat (" is not ", $call concat ($call T.show (bt), " (§4.9)")))))), n)))
        $decl rest $call check_bounds (cx, benv, gs.tail, $call Pa.nodes.val (bs.tail), ats.tail, n)
        $decl ret  $if ok rest false
      }.ret,
      $case ats true),
    $case bs true),
  $case gs true
)

$decl specialize_at $func ($decl cx proto_ctx, $decl e env.node, $decl id 0,
                           $decl args Pa.nodes.node, $decl ats T.tys.node,
                           $decl n Pa.proto_node) {
  $decl r  $call find_tmpl (cx.tmpls, id)
  $decl bc $call check_bounds (cx, $call bind_generics (r.env, r.generics, ats), r.generics,
               r.bounds, ats, n)
  $decl ret $if ($call not (bc)) T.t_bot {
        $decl chk  $call ct_args_check (cx, e, r.generics, args, r.ctg)
        $decl key  $call concat ($call memo_key (id, ats, ""), $call ct_vals (cx, r.generics, args,
            r.ctg, ""))
        $decl hit  $call memo_find (cx.memo, key)
        $decl deep $call lt (63, $call ival (cx.sdepth))
        $decl ret2 $if hit.ok
            ($do ($set cx.sreach ($if ($call is_var_ty (hit.ty))
                      ($call add ($call ival (cx.sreach), 1)) ($call ival (cx.sreach))))
                 hit.ty)
            ($if deep
            ($call err (cx, "$specialize: the instantiation depth limit (64) is exceeded — a chain of distinct argument types (§4.9)", n)) {
              $decl din  $set cx.sdepth ($call add ($call ival (cx.sdepth), 1))
              $decl benv $call bind_generics (r.env, r.generics, ats)
              // The body's spans are the template's file, not this one.
              $decl outer   $call sval (cx.file)
              $decl entered $set cx.file r.file
              // The body's compile-time identities belong to *this* instantiation.
              $decl souter $call sval (cx.sctx)
              $decl sent   $set cx.sctx key
              // Memoised *before* the body is typed, with a placeholder, so a
              // template that reaches itself terminates — §4.9: "hitting an
              // in-progress entry returns its `R`."
              $decl ph $call T.t_var ($call fresh (cx))
              $decl m0 $set cx.memo ($call memo_list.cons ($call memo_ent (key, ph),
                  $call eval_memo (cx.memo)))
              $decl r0 $call ival (cx.sreach)
              // A value, not the cell: `$decl` keeps a reference (§5.4), and
              // restoring the cell to itself would keep the first pass's errors.
              $decl e0   $call Pa.diags.val (cx.errs)
              $decl body $call subst_ct (r.body, r.generics, args, r.ctg)
              $decl ty0  $call infer (cx, benv, body)
              // §5.5 discharges the placeholder if the body reached back.
              $decl ty1r $call close_rec (cx, ty0, $call var_id (ph), n)
              // And a `$traitsof` of this specialisation inside its own body (design
              // point 7) is closed the same way, into the trait of what it became.
              $decl rtv  $call rt_for ($call st_pairs.val (cx.strps), $call var_id (ph))
              $decl ty1  $if ($call lt (-1, rtv)) ($call close_self (ty1r, rtv)) ty1r
              // A body that reached itself saw `R` there, and `R` cannot be
              // projected from — `($specialize box T).mk` inside `box` failed. So it
              // is typed once more against the first pass's answer, which is what a
              // block's props do (`infer_block`'s two passes), and only the second
              // pass speaks. One that did not reach itself is typed once.
              $decl again $call lt (r0, $call ival (cx.sreach))
              $decl ty $if again {
                $decl back $set cx.errs e0
                $decl m2   $set cx.memo ($call memo_list.cons ($call memo_ent (key, ty1),
                               $call eval_memo (cx.memo)))
                $decl ret4   $call infer (cx, benv, body)
              }.ret4
                  ty1
              $decl left  $set cx.file outer
              $decl sleft $set cx.sctx souter
              $decl m1    $set cx.memo ($call memo_list.cons ($call memo_ent (key, ty),
                  $call eval_memo (cx.memo)))
              $decl dout $set cx.sdepth ($call sub ($call ival (cx.sdepth), 1))
              $decl ret3 ty
            }.ret3)
      }.ret2
}.ret

$decl specialize_with $func ($decl cx proto_ctx, $decl e env.node, $decl id 0,
                             $decl argn Pa.proto_node, $decl n Pa.proto_node) {
  $decl r  $call find_tmpl (cx.tmpls, id)
  $decl ng $call strs.length (r.generics, 0)
  // §2.3 again: with one generic the whole operand is the argument; with
  // several it has to be a group.
  $decl args $if ($call eq_int (ng, 1))
      ($call Pa.nodes.cons (argn, Pa.nodes.nil))
      ($call group_items (argn))
  $decl na  $call Pa.nodes.length (args, 0)
  $decl ats $call infer_tys (cx, e, args, T.tys.nil)
  $decl ret $if ($call not ($call eq_int (ng, na)))
      ($call err (cx, $call concat ("this template has ", $call concat ($call int_to_str (ng),
          $call concat (" generic parameters, found ", $call int_to_str (na)))), n))
      ($call specialize_at (cx, e, id, args, ats, n))
}.ret

// §4.9: "If a template's body is a `$func`, then `$call t args` means `$call
// ($specialize t inferred) args`." Each generic is read off the argument types where
// `Pa.app_sources` says, the template is specialised at those exactly as an explicit
// `$specialize` would be — so the two share a memo entry — and the call is then checked
// against the specialised signature, with the arguments typed once, as an overloaded
// call does. "Application never infers a compile-time generic."
$decl app_ty $func ($decl cx proto_ctx, $decl s Pa.proto_app_src, $decl rs T.tys.node,
                    $decl g "", $decl n Pa.proto_node) {
  $decl at  $if ($call lt (-1, s.arg))
                ($if ($call lt (s.arg, $call T.tys.length (rs, 0))) ($call T.tys.nth (rs, s.arg))
                     T.t_bot) T.t_bot
  $decl ft  $call T.unroll ($call deref_ty (at))
  $decl got $if ($call eq_int (s.kind, 0)) at
      ($match ft (
        $case {$prop tag "func"}
          $if ($call eq_int (s.kind, 2)) ($call T.tval (ft.result))
              ($if ($call lt (s.pos, $call T.tys.length ($call T.tys.val (ft.params), 0)))
                   ($call T.tys.nth ($call T.tys.val (ft.params), s.pos)) T.t_bot),
        $case ft T.t_bot))
  $decl why $if ($call lt (s.arg, 0)) "no parameter default is shaped by it"
                ($if ($call lt (s.arg, $call T.tys.length (rs, 0)))
                     "its argument is not a function of that shape" "its argument is not passed")
  $decl ret $if ($call is_bot_ty (got))
      ($call err (cx, $call concat ("cannot infer '", $call concat (g, $call concat ("' from this call: ",
          $call concat (why, "; write the $specialize (§4.9)")))), n))
      got
}.ret

$decl app_tys $func ($decl cx proto_ctx, $decl ss Pa.app_srcs.node, $decl rs T.tys.node,
                     $decl gs strs.node, $decl n Pa.proto_node, $decl acc T.tys.node) $match ss (
  $case {$prop tag "cons"} $match gs (
    $case {$prop tag "cons"}
      $call app_tys (cx, $call Pa.app_srcs.val (ss.tail), rs, gs.tail, n,
          $call T.tys.cons ($call app_ty (cx, ss.head, rs, gs.head, n), acc)),
    $case gs ($call T.tys.reverse (acc, T.tys.nil))),
  $case ss ($call T.tys.reverse (acc, T.tys.nil))
)

$decl has_bot $func ($decl ts T.tys.node) $match ts (
  $case {$prop tag "cons"} $if ($call is_bot_ty (ts.head)) true ($call has_bot (ts.tail)),
  $case ts false
)

$decl infer_apply $func ($decl cx proto_ctx, $decl e env.node, $decl id 0,
                         $decl args Pa.nodes.node, $decl n Pa.proto_node) {
  $decl r   $call find_tmpl (cx.tmpls, id)
  $decl rs  $call arg_types (cx, e, args, T.tys.nil)
  $decl ret $if ($call not ($call is_form (r.body, "func")))
      ($call err (cx, "$call on a template needs its body to be a $func, which §4.9 infers its generics from; write the $specialize", n))
      ($if ($call not ($call Pa.ctgs.is_nil (r.ctg)))
      ($call err (cx, "this template has a compile-time generic, which application never infers; write the $specialize (§4.9)", n)) {
        $decl ats  $call app_tys (cx, $call Pa.app_sources (r.body, r.generics, Pa.app_srcs.nil),
                       rs, r.generics, n, T.tys.nil)
        $decl ft   $if ($call has_bot (ats)) T.t_bot
                       ($call deref_ty ($call specialize_at (cx, e, id, Pa.nodes.nil, ats, n)))
        $decl ret2 $match ft (
            $case {$prop tag "func"} {
              $decl ok   $call check_typed (cx, $call T.tys.val (ft.params), args, rs, n, 1,
                             $call T.cints.val (ft.esc))
              $decl ret3 $if ok ($call T.tval (ft.result)) T.t_bot
            }.ret3,
            $case ft T.t_bot)
      }.ret2)
}.ret

// §4.9 steps 2 and 3: type the substituted expression with ordinary rules, and
// have exactly its type.
$decl infer_specialize $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl tt $call deref_ty ($call infer (cx, e, $call op (n, 0)))
  $decl ret $match tt (
      $case {$prop tag "tmpl"}   $call specialize_with (cx, e, tt.id, $call op (n, 1), n),
      $case {$prop tag "bottom"} T.t_bot,
      $case tt ($call err (cx, $call concat ("$specialize expects a template, found ",
                    $call T.show (tt)), n))
    )
}.ret

// -------------------------------------------------------------- $import (§4.14)

// §8's `read_file` answers an option, and **flattening it to a string loses the one
// distinction that matters**: a file that could not be read and a file that is empty
// both became `""`, so importing an empty module reported "cannot read" for a file that
// was read perfectly well. §3.3 makes a file a block and §2.1 makes `{}` and `()` the
// same value, so an empty file is a valid empty module — not an error.
//
// Kept for the callers that only want the text and have already established the file is
// there; `load_module` matches the option itself.
$decl read_module $func ($decl path "") {
  $decl r $call read_file (path)
  $decl ret $match r (
      $case {$prop tag "some"} r.v,
      $case r ""
    )
}.ret

$decl mod_find $func ($decl xs mod_list.node, $decl k "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.key, k)) xs.head ($call mod_find (xs.tail, k)),
  $case xs ($call mod_ent ("", "", T.t_bot))
)

// ------------------------------------------------- the interface cache (§9)
//
// §3.3 makes a module's interface a **type** — `check_file` answers every top-level
// name with its solved type — and `tyio` writes one down and reads it back. So an
// unchanged module need not be inferred again: load its interface instead. Inference
// is ~80% of a compile and is **additive** across modules (per-module marginals sum to
// 26.8s against the whole closure's 26.85s), so this is where the time is.
//
// What makes it sound is that the interface is now a function of the module's source
// alone: linkage comes from the function, naming from the source, and inference's
// template and `cv_opaque` ids from where they are written. Before those, a stored
// interface moved with load order and no key could hit.
//
// `prelude` is the one module deliberately *not* cacheable — §10.7 checks a
// `$template`'s body at the specialization site, so a module exporting one exports its
// body rather than a type. It is also the cheapest module there is (0.07s), so the
// exception costs nothing.

// The names a file imports, at its top level: `$decl X $import "y"`, or a bare
// `$import` standing for effect. Found by scanning the parse, which is all that is
// needed: the imports have to be loaded before the importer's key can be computed, and
// loading one from its interface file is cheap.
$decl import_of $func ($decl n Pa.proto_node)
  $if ($call is_form (n, "import")) ($call str_of ($call op (n, 0)))
      ($if ($call is_form (n, "decl"))
           ($if ($call is_form ($call op (n, 1), "import"))
                ($call str_of ($call op ($call op (n, 1), 0))) "")
           "")

$decl imports_of $func ($decl xs Pa.nodes.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"} {
    $decl nm  $call import_of (xs.head)
    $decl a2  $if ($call eq_str (nm, "")) acc ($call strs.cons (nm, acc))
    $decl ret $call imports_of ($call Pa.nodes.val (xs.tail), a2)
  }.ret,
  $case xs ($call strs.reverse (acc, strs.nil))
)

// One file per (module, fingerprint), so a changed module simply misses rather than
// overwriting what another program still wants.
$decl iface_file $func ($decl cx proto_ctx, $decl key "", $decl h 0)
  $call concat ($call sval (cx.cdir), $call concat ("/",
      $call concat ($call short_of (key), $call concat (".",
      $call concat ($call int_to_str (h), ".iface")))))

$decl iface_write $func ($decl cx proto_ctx, $decl key "", $decl h 0, $decl str "") {
  $decl w $call write_file ($call iface_file (cx, key, h), str)
  // A failed write is not an error: the cache is an optimisation, and a build that
  // cannot write one must still compile.
  $decl ret $match w ($case {$prop tag "err"} 0, $case w 0)
}.ret

// What a load produced: the type, the hash of its serialised interface, and whether it
// came from disk. The hash travels with it so that **`show_ty` is never called twice** —
// on a hit the string was just read, on a miss it was just written. Re-serialising to
// get the hash instead cost a `show_ty` per module per run and took the warm whole-
// closure run from 8.5s to 24.1s, which is the entire saving.
$decl ires $func ($decl t T.proto_ty, $decl h 0, $decl ok P.boolean)
  { $decl ty t  $decl ifh h  $decl hit ok }
$decl proto_ires $call ires (T.t_bot, 0, false)

$decl iface_read $func ($decl cx proto_ctx, $decl key "", $decl h 0) {
  $decl rf $call read_file ($call iface_file (cx, key, h))
  $decl ret $match rf (
      $case {$prop tag "some"}
        ($call ires ($call T.tval (($call Y.read_ty (rf.v, 0)).val),
             $call T.hash_str (rf.v, 0, 19), true)),
      $case rf proto_ires
    )
}.ret

// §10.7 makes a `$template`'s body part of its module's interface, and a type cannot
// carry a body — so a module exporting one is never cached. `prelude` is the only such
// module in stage 1 and checks in 0.07s, so the exception is free. Asked by short name
// rather than by scanning for `$template`, because the scan would have to parse the
// module to answer and the answer is needed before the parse is worth doing.
$decl cacheable $func ($decl key "")
  $call not ($call eq_str ($call short_of (key), "prelude"))

$decl cache_on $func ($decl cx proto_ctx)
  $call not ($call eq_str ($call sval (cx.cdir), ""))

// A module's syntax errors are its own: they keep their line and column and
// carry its path, rather than being folded into a message against the import.
$decl note_mod_errs $func ($decl cx proto_ctx, $decl xs Pa.diags.node, $decl path "",
    $decl n Pa.proto_node) $match xs (
  $case {$prop tag "cons"} {
    $decl noted $set cx.errs ($call Pa.diags.cons (
        $call Pa.diag (xs.head.msg, xs.head.line, xs.head.col, path), $call eval_diags (cx.errs)))
    $decl ret   $call note_mod_errs (cx, xs.tail, path, n)
  }.ret,
  $case xs T.t_bot
)

$fwd need_module

// Each import loaded, and its interface hash mixed in. This is what the importer's
// cache key is made of, and the imports have to be loaded first for it to exist — which
// costs nothing on a warm run, since loading one is reading a few KB.
$decl key_imports $func ($decl cx proto_ctx, $decl ns strs.node, $decl n Pa.proto_node,
                         $decl acc 0) $match ns (
  $case {$prop tag "cons"} {
    $decl k   $call Pa.resolve_import ($call sval (cx.base), $call strs.val (cx.roots), ns.head)
    $decl ld  $call need_module (cx, k, ns.head, n)
    $decl h   ($call mod_find ($call eval_mods (cx.mods), k)).ifh
    $decl ret $call key_imports (cx, $call strs.val (ns.tail), n, $call T.hmix (acc, h))
  }.ret,
  $case ns acc
)

$decl load_module $func ($decl cx proto_ctx, $decl key "", $decl nm "", $decl n Pa.proto_node) {
  $decl marked $set cx.mods
      ($call mod_list.cons ($call mod_ent (key, "loading", T.t_bot), $call eval_mods (cx.mods)))
  $decl rf $call read_file (key)
  // On the option, not on the text: an empty file is a valid empty module (§3.3).
  // Matched on `some` rather than on a catch-all, because §4.7's catch-all pattern is
  // a *name* and so denotes the whole scrutinee — it does not narrow, and `rf.v` is
  // not reachable through it.
  $decl ty $match rf (
      $case {$prop tag "some"} {
        $decl src rf.v
        $decl p   $call Pa.parse (src)
        // A module's own syntax errors are reported against the import site,
        // tagged with the module's path: the diagnostic type carries a line
        // and column but not a file.
        $decl r $if ($call Pa.diags.is_nil (p.errs)) {
          // §4.14: "A file sees the root block plus what it imports,
          // nothing else" — so the module is typed in the root
          // environment, never in the importer's.
          //
          // Or not typed at all: with the cache on, a fingerprint that names an
          // interface already on disk is loaded instead, and this module's body is
          // never inferred. A miss infers it and writes the interface for next
          // time. `cacheable` excludes `prelude`, whose `$template` makes its
          // interface its body (§10.7).
          $decl ok  $call and ($call cache_on (cx), $call cacheable (key))
          // The imports first, whether or not this module is cacheable: they are
          // what the key is made of, and inferring this body would load them
          // anyway.
          $decl ih  $if ($call cache_on (cx))
                        ($call key_imports (cx, $call imports_of (p.exprs, strs.nil), n,
                             $call T.hash_str (src, 0, 17)))
                        0
          $decl got $if ok ($call iface_read (cx, key, ih)) proto_ires
          $decl cnt $if got.hit ($set cx.nhit ($call add ($call ival (cx.nhit), 1)))
                        ($if ok ($set cx.nmiss ($call add ($call ival (cx.nmiss), 1))) 0)
          $decl res $if got.hit got {
            $decl outer   $call sval (cx.file)
            $decl entered $set cx.file key
            $decl t       $call infer_block (cx, root_env, p.exprs, P.proto_span)
            $decl left    $set cx.file outer
            // Serialised once: written if this module is cacheable, and hashed
            // either way, because an importer's key needs the hash even for a
            // module whose interface is not stored. A module that is not
            // cacheable falls back to its *source* hash, which is
            // conservative — a comment in `prelude` invalidates everything —
            // and right, since §10.7 makes a prelude change whole-program.
            $decl str   $if ok ($call Y.show_ty (t)) ""
            $decl wrote $if ok ($call iface_write (cx, key, ih, str)) 0
            $decl h       $if ok ($call T.hash_str (str, 0, 19))
                              ($call T.hash_str (src, 0, 23))
            $decl ret4       $call ires (t, h, false)
          }.ret4
          $decl ret3 res
        }.ret3 {
          $decl e    $call note_mod_errs (cx, p.errs, key, n)
          $decl ret3 $call ires ($call T.tval (e), 0, false)
        }.ret3
        $decl ret2 r
      }.ret2,
      $case rf {
        $decl e $call err (cx, $call concat ("cannot read the file for $import \"",
            $call concat (nm, $call concat ("\" (", $call concat (key, ")")))), n)
        $decl ret2 $call ires ($call T.tval (e), 0, false)
      }.ret2
    )
  $decl done $set cx.mods
      ($call mod_list.cons ($call mod_ent_h (key, "done", $call T.tval (ty.ty), ty.ifh),
           $call eval_mods (cx.mods)))
  $decl ret $call T.tval (ty.ty)
}.ret

// §4.14: "Loads a source file as a block ... the type is that block's type."
// Loaded once, keyed on the resolved path (§4.14). Shared by the import expression and
// by `key_imports`, which needs an import's interface before the importer has a key.
$decl need_module $func ($decl cx proto_ctx, $decl key "", $decl nm "", $decl n Pa.proto_node) {
  $decl hit $call mod_find ($call eval_mods (cx.mods), key)
  $decl ret $if ($call eq_str (hit.state, "done")) ($call T.tval (hit.ty))
           ($if ($call eq_str (hit.state, "loading"))
                ($call err (cx, $call concat ("import cycle: \"", $call concat (nm,
                    "\" is already being loaded; make one module a $template over the other")), n))
                ($call load_module (cx, key, nm, n)))
}.ret

$decl infer_import $func ($decl cx proto_ctx, $decl n proto_form) {
  $decl nm  $call str_of ($call op (n, 0))
  $decl key $call Pa.resolve_import ($call sval (cx.base), $call strs.val (cx.roots), nm)
  $decl ret $call need_module (cx, key, nm, n)
}.ret

// ------------------------------------------------------------------- blocks

$decl bst $func ($decl e0 env.node) {
  $decl env  $mut $alloc e0
  $decl flds $mut $alloc T.fields.node
  $decl prps $mut $alloc T.props.node
  // §5.5: "`$fwd` slots share one system of equations."
  $decl fwds $mut $alloc fwd_list.node
  $decl res  $mut $alloc res_list.node
}

$decl proto_bst $call bst (env.nil)

// Reserved here rather than with the others above: a `$fwd` slot is typed where
// the `$fwd` stands (§4.11), so the completing `$decl`'s parameters can only
// name what is already in scope at *that* point — and this one takes a `bst`.
$fwd prebind_one

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
  // Where it is written, and in which specialisation — see `ct_id`.
  $case n ($call T.cv_opaque ($call ct_id (cx, 3, n)))
)

// §4.10: props are visible throughout their block regardless of order, so every
// prop name is bound before any of them is typed. Each starts as a recursion
// placeholder, discharged when its own initializer has been typed.
$decl prebind_props $func ($decl cx proto_ctx, $decl items Pa.nodes.node,
    $decl acc env.node) $match items (
  $case {$prop tag "cons"} {
    $decl it items.head
    $decl nm $call name_of ($call op (it, 0))
    $decl ct $if ($call is_form (it, "prop"))
        ($set cx.ctnames ($call strs.cons (nm, cx.ctnames))) ()
    $decl e2 $if ($call is_form (it, "prop"))
        ($call bind (acc, nm, $call T.t_var ($call fresh (cx))))
        acc
    $decl ret $call prebind_props (cx, items.tail, e2)
  }.ret,
  $case items acc
)


$decl recv_save $func ($decl n "", $decl q "", $decl l 0, $decl c 0)
  { $decl name n  $decl qual q  $decl line l  $decl col c }

$decl proto_recv $call recv_save ("", "", -1, -1)

$decl recv_set $func ($decl cx proto_ctx, $decl r proto_recv) {
  $decl a   $set cx.rname r.name
  $decl b   $set cx.rqual r.qual
  $decl c   $set cx.rline r.line
  $decl ret $set cx.rcol r.col
}.ret

$decl recv_of $func ($decl nm "", $decl init Pa.proto_node) {
  $decl b   $call Pa.recv_target (init)
  $decl sp  $call P.span_of (b)
  $decl ret $if ($call is_block_node (b))
                ($call recv_save (nm, $call Pa.recv_qual (init), sp.line, sp.col)) proto_recv
}.ret

$decl infer_decl_item $func ($decl cx proto_ctx, $decl s proto_bst, $decl it Pa.proto_node) {
  $decl nm   $call name_of ($call op (it, 0))
  $decl init $call op (it, 1)
  // §4.1: the name is in scope inside its own initializer, standing for
  // §5.5's placeholder `R`. A `$func` initializer gets the sharper treatment
  // in `infer_rec_func`, because a bare `R` is not callable.
  // A `$fwd` for this name already bound it to `[params] -> R` (§5.5), so the
  // body is typed against that placeholder and its resolution recorded as one
  // equation of the group's system.
  $decl fe $call find_fwd (s.fwds, nm)
  $decl ty $if ($call lt (-1, fe.id))
      ($call infer_fwd_body (cx, s.env, init, fe.id))
      ($if ($call is_form (init, "func"))
          ($call infer_rec_func (cx, s.env, nm, init, env.nil))
      ($if ($call is_form (init, "template"))
          ($call infer (cx, $call self_tmpl_env (cx, s.env, nm, init), init)) {
            $decl id  $call fresh (cx)
            $decl e1  $call bind (s.env, nm, $call T.t_var (id))
            // §4.10: if the initializer is a block, its members' receiver is `nm`.
            $decl old $call recv_save ($call sval (cx.rname), $call sval (cx.rqual),
                          $call ival (cx.rline), $call ival (cx.rcol))
            $decl set $call recv_set (cx, $call recv_of (nm, init))
            $decl raw $call infer (cx, e1, init)
            $decl put $call recv_set (cx, old)
            $decl ret $call close_rec (cx, raw, id, it)
          }.ret))
  $decl done $set cx.inprog ($if ($call lt (-1, fe.id))
                ($call drop_prog ($call hint_list.val (cx.inprog), fe.id, hint_list.nil))
                ($call hint_list.val (cx.inprog)))
  $decl eqn $if ($call lt (-1, fe.id))
      ($set s.res ($call res_list.cons ($call res_ent (fe.id, $call result_of (ty)),
                                        $call eval_res (s.res))))
      ()
  // §4.16 rule 2's three sets — see `ctx`. `topnames` is guarded on `fdepth`
  // because a `$decl` inside a `$func` body takes a frame slot (§7.2) and
  // reading it *is* a capture, while a file top-level one is lifted to a global.
  //
  // The condition is inside the `$set`, not around it, and that is not a style
  // choice. `$if c ($set …) ()` has arms of two *different* types, so §3.6 joins
  // them into a union and §7.5 gives the slot a discriminator and a payload — for
  // a value nothing reads, since these three exist only for the store. Worse, the
  // block copies every slot into its result, so the unit path copies a payload it
  // never wrote: `cc -Wall` reports exactly that, and it was the only warning in
  // the compiler's own C. Storing unconditionally — the same list back when the
  // test fails — makes both arms one type, and the union, the tag and the copy
  // all go away.
  $decl xn $set cx.extnames ($if ($call is_form (init, "extern"))
      ($call strs.cons (nm, cx.extnames)) ($call strs.val (cx.extnames)))
  $decl cf $set cx.cffns ($if ($call is_form (init, "func"))
      ($call fnlit_list.cons ($call fnlit_ent (nm, init), cx.cffns))
      ($call fnlit_list.val (cx.cffns)))
  $decl tn $set cx.topnames ($if ($call eq_int ($call ival (cx.fdepth), 0))
      ($call strs.cons (nm, cx.topnames)) ($call strs.val (cx.topnames)))
  $decl bound $set s.env ($call bind (s.env, nm, ty))
  // A `$fwd` already reserved this slot at its own position (§4.11), so
  // complete that one rather than appending a second.
  $decl added $set s.flds ($call put_field (s.flds, nm, ty))
}

$decl mem_str $func ($decl xs strs.node, $decl n "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head, n)) true ($call mem_str (xs.tail, n)),
  $case xs false
)

// §4.10's list of what a prop initializer may be, made real.
//
// The section says two things that cannot both hold: `e` "must be **fully
// evaluable by the compiler** … Never `$new`, never `$call`", and an initializer
// "may reference other props and **enclosing scopes**". A parameter is an
// enclosing scope and is not evaluable by the compiler.
//
// "Fully evaluable" has to win, because the section's central claim rests on it:
// "a prop's value is part of the enclosing block's type", and §5.1 matches props
// by *value equality* — so a prop naming a parameter would give its block a
// different type per call, which is not a type. So the enclosing-scope clause is
// read as *enclosing compile-time* bindings, which `cx.ctnames` tracks.
//
// Nothing enforced this before. `$prop bad $call f ()` type-checked and stage 0
// evaluated the call at run time; `$prop tag x` over a parameter type-checked,
// ran as a per-call field in stage 0, and was refused by lowering at each *use*
// with a message about the backend's difficulty rather than about the rule.
// "a block made only of props" — one with a `$decl` has a layout, so it is a
// runtime value and cannot be a compile-time constant.
$decl props_only $func ($decl items Pa.nodes.node) $match items (
  $case {$prop tag "cons"}
    $if ($call is_form (items.head, "prop")) ($call props_only ($call Pa.nodes.val (items.tail)))
        false,
  $case items true
)

// §4.10's "never a block with a `$decl`", applied through a `$specialize`: the
// template's body, if the target names one. Asked quietly, like `ctg_target` — the
// `$specialize` itself is typed, and reports, as the prop's initializer.
$decl spec_runtime_body $func ($decl cx proto_ctx, $decl e env.node, $decl x Pa.proto_node) {
  $decl q0   $call bval (cx.quiet)
  $decl hush $set cx.quiet true
  $decl tt   $call deref_ty ($call infer (cx, e, x))
  $decl back $set cx.quiet q0
  $decl ret $match tt (
      $case {$prop tag "tmpl"} {
        $decl r $call find_tmpl (cx.tmpls, tt.id)
        $decl b r.body
        $decl ret2 $match b (
            $case {$prop tag "block"} ($call not ($call props_only ($call Pa.nodes.val (b.items)))),
            $case b false
          )
      }.ret2,
      $case tt false
    )
}.ret

// §4.10's constant expressions, as a reason: "" when `n` is one, and otherwise what
// to say it is not. Judged after specialisation, so a `$specialize` is constant when
// its arguments are and its body is made only of props.
$fwd ct_why

$decl ct_why_list $func ($decl cx proto_ctx, $decl pe env.node, $decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"} {
    $decl w   $call ct_why (cx, pe, xs.head)
    $decl ret $if ($call eq_str (w, "")) ($call ct_why_list (cx, pe,
        $call Pa.nodes.val (xs.tail))) w
  }.ret,
  $case xs ""
)

// "Each argument of a `$specialize` inside a constant expression is evaluated, so it
// must be a name or a constant expression." A name of any binding: reading one does
// nothing, and its value cannot reach the prop unless the generic it is passed to is
// compile-time — and then that `$specialize`'s own check holds it to a constant.
$decl ct_args_why $func ($decl cx proto_ctx, $decl pe env.node, $decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"} {
    $decl x xs.head
    $decl w $match x ($case {$prop tag "name"} "", $case x ($call ct_why (cx, pe, x)))
    $decl ret $if ($call eq_str (w, "")) ($call ct_args_why (cx, pe,
        $call Pa.nodes.val (xs.tail))) w
  }.ret,
  $case xs ""
)

$decl ct_form_why $func ($decl cx proto_ctx, $decl pe env.node, $decl n proto_form) {
  $decl k n.keyword
  $decl ret $if ($call or ($call eq_str (k, "func"), $call eq_str (k, "template"))) ""
    // §4.8a: the first member is the value; the rest are type-only (§5.7).
    ($if ($call eq_str (k, "union"))
         ($call ct_why (cx, pe, $call Pa.nodes.nth ($call Pa.group_list ($call op (n, 0)), 0)))
    ($if ($call eq_str (k, "overload"))
         ($call ct_why_list (cx, pe, $call Pa.group_list ($call op (n, 0))))
    ($if ($call eq_str (k, "specialize"))
         ($if ($call spec_runtime_body (cx, pe, $call op (n, 0)))
              "a $specialize of a template whose body has a $decl"
              ($call ct_args_why (cx, pe, $call Pa.group_list ($call op (n, 1)))))
    // §4.10: `$impl` is constant when its base and override are — it is the base's
    // value with props added (§4.12), and its trait is type-only. `$traitsof` never is:
    // it makes a trait object, which is a reference to a value (§6).
    ($if ($call eq_str (k, "impl"))
         ($call ct_why_list (cx, pe, $call Pa.nodes.cons ($call op (n, 0),
             $call Pa.nodes.cons ($call op (n, 2), Pa.nodes.nil))))
    ($if ($call eq_str (k, "traitsof"))
         "$traitsof, which makes a trait object (§6),"
         ($call concat ("$", k)))))))
}.ret

$decl ct_why $func ($decl cx proto_ctx, $decl pe env.node, $decl n Pa.proto_node) $match n (
  $case {$prop tag "int"}   "",
  $case {$prop tag "float"} "",
  $case {$prop tag "str"}   "",
  $case {$prop tag "bool"}  "",
  $case {$prop tag "unit"}  "",
  // §4.10 allows "projection of a prop", and the target is held to the same
  // rule — so `math.inner.two` is in and a projection off a parameter is out.
  $case {$prop tag "proj_name"}  ($call ct_why (cx, pe, n.target)),
  $case {$prop tag "proj_index"} ($call ct_why (cx, pe, n.target)),
  // A name that is not in scope here at all is §4.10's *other* rule — an
  // ordered sibling, which the prop-only environment already excludes — so it is
  // left to inference's ordinary "unknown name", which says the more useful
  // thing. This reports only a name that resolves and is not compile-time.
  $case {$prop tag "name"}
    $if ($call not ($call lookup (pe, n.text)).ok) ""
        ($if ($call mem_str ($call strs.val (cx.ctnames), n.text)) ""
             ($call concat ("'", $call concat (n.text, "'")))),
  $case {$prop tag "block"} ($if ($call props_only (n.items)) "" "a block with a $decl in it"),
  $case {$prop tag "form"}  ($call ct_form_why (cx, pe, n)),
  $case n "this"
)

$decl ct_init $func ($decl cx proto_ctx, $decl pe env.node, $decl n Pa.proto_node)
  $call eq_str ($call ct_why (cx, pe, n), "")

// §4.9: a compile-time generic's "argument must be a constant expression". Asked at
// every `$specialize`, memo hit or not, and reported at the argument, naming the prop
// the generic reaches — the place a reader has to look to see why.
$decl ct_args_check $func ($decl cx proto_ctx, $decl e env.node, $decl gs strs.node,
                           $decl args Pa.nodes.node, $decl cg Pa.ctgs.node) $match gs (
  $case {$prop tag "cons"} $match args (
    $case {$prop tag "cons"} {
      $decl p $call Pa.ctg_prop (cg, gs.head)
      $decl w $if ($call eq_str (p, "")) "" ($call ct_why (cx, e, args.head))
      $decl rp $if ($call eq_str (w, "")) T.t_bot
          ($call err (cx, $call concat ("'", $call concat (gs.head, $call concat ("' reaches $prop ",
              $call concat (p, $call concat (", so its argument must be a constant expression (§4.9), and ",
              $call concat (w, " is not")))))), args.head))
      $decl ret  $call ct_args_check (cx, e, gs.tail, $call Pa.nodes.val (args.tail), cg)
    }.ret,
    $case args 0),
  $case gs 0
)

// The type of one prop. §4.10: the initializer sees other props and enclosing
// scopes, but *not* ordered siblings — hence the prop-only environment.
$decl prop_ty $func ($decl cx proto_ctx, $decl pe env.node, $decl nm "", $decl it Pa.proto_node,
    $decl rn "") {
  $decl init $call op (it, 1)
  // Reported here, at the `$prop`, with its span — not at each projection that
  // later fails to reach the value. `err` is quiet during the first of the two
  // prop passes, so this is said once.
  $decl why  $call ct_why (cx, pe, init)
  $decl ct   $if ($call eq_str (why, "")) T.t_bot
      ($call err (cx, $call concat ("a $prop must be a constant expression (§4.10), and ",
          $call concat (why, " is not")), it))
  $decl id   $call var_id ($call lookup (pe, nm)).ty
  // A member that names its receiver is typed here only for a provisional type, and
  // quietly: the receiver's block is not typed yet. `infer_block` types it for real
  // once it is (§4.10).
  $decl rcv  $if ($call is_form (init, "func")) ($call Pa.names_recv (init, rn)) false
  $decl q0   $call bval (cx.quiet)
  $decl qq   $set cx.quiet ($if rcv true q0)
  $decl ret0 $if ($call is_form (init, "func"))
      ($call infer_rec_func (cx, pe, nm, init, env.nil)) {
        $decl raw $call infer (cx, $if ($call is_form (init, "template"))
                                        ($call self_tmpl_env (cx, pe, nm, init)) pe, init)
        $decl ret2   $if ($call lt (-1, id)) ($call close_rec (cx, raw, id, it)) raw
      }.ret2
  $decl back $set cx.quiet q0
  $decl ret  ret0
}.ret

// §4.10 says props are "typed together as one system", which is the one place
// the subset genuinely needs a fixpoint: a prop may name a *later* prop, so one
// left-to-right pass would leave that reference as a placeholder. Two passes
// resolve it — the first computes types with placeholders, the second retypes
// with the first pass's answers in scope. Each prop is still typed with its own
// name bound to its placeholder, so self-recursion still closes with μ (§5.5).
$decl prop_pass $func ($decl cx proto_ctx, $decl pe0 env.node, $decl items Pa.nodes.node,
    $decl acc env.node, $decl rn "") $match items (
  $case {$prop tag "cons"} {
    $decl it items.head
    $decl nm $call name_of ($call op (it, 0))
    $decl e2 $if ($call is_form (it, "prop"))
        ($call bind (acc, nm,
            $call prop_ty (cx, $call bind (acc, nm, ($call lookup (pe0, nm)).ty), nm, it, rn)))
        acc
    $decl ret $call prop_pass (cx, pe0, items.tail, e2, rn)
  }.ret,
  $case items acc
)

// By the time this runs the prop's type is already resolved, so it only records
// the entry — §4.10's value for identity, plus the type for projection.
$decl infer_prop_item $func ($decl cx proto_ctx, $decl s proto_bst, $decl pe env.node,
    $decl it Pa.proto_node) {
  $decl nm $call name_of ($call op (it, 0))
  $decl f  $call lookup (pe, nm)
  $decl cv $call const_of (cx, $call op (it, 1))
  $decl added $set s.prps ($call T.props.cons ($call T.prop_typed (nm, cv, f.ty),
      $call eval_prps (s.prps)))
  $decl bound $set s.env ($call bind (s.env, nm, f.ty))
}

// §4.11: reserves an ordered slot *at this position*. The type was decided by
// `prebind_fwds` before the block was walked, so this only claims the slot —
// which is what keeps the layout position at the `$fwd`, not at the `$decl`.
$decl infer_fwd_item $func ($decl cx proto_ctx, $decl s proto_bst, $decl all Pa.nodes.node,
    $decl it Pa.proto_node) {
  $decl bound $call prebind_one (cx, s, all, it)
  $decl nm    $call name_of ($call op (it, 0))
  $decl f     $call lookup (s.env, nm)
  $decl added $set s.flds ($call put_field (s.flds, nm, f.ty))
}


$decl find_completing $func ($decl items Pa.nodes.node, $decl nm "") $match items (
  $case {$prop tag "cons"}
    $if ($call and ($call is_form (items.head, "decl"),
                    $call eq_str ($call name_of ($call op (items.head, 0)), nm)))
        items.head
        ($call find_completing (items.tail, nm)),
  $case items Pa.proto_node
)

// Bind every `$fwd` name before the block is walked.
//
// §5.5 says the slots "share one system of equations", which needs each name to
// stand for something callable while the others are typed. §3.4 supplies it: a
// parameter's default fixes its type and no default depends on a body, so the
// whole group's *signatures* are knowable up front. Each name is bound to
// `[params] -> R`, leaving only the results unknown — the same shape that makes
// self-recursion work in `infer_rec_func`.
$decl prebind_one $func ($decl cx proto_ctx, $decl s proto_bst,
                         $decl all Pa.nodes.node, $decl it Pa.proto_node) {
  $decl pe   $call eval_env (s.env)
  $decl nm   $call name_of ($call op (it, 0))
  $decl comp $call find_completing (all, nm)
  $decl id   $call fresh (cx)
  $decl init $if ($call is_form (comp, "decl")) ($call op (comp, 1)) comp
  $decl ty $if ($call is_form (init, "func"))
      ($call T.t_func (($call infer_params (cx, pe, $call group_items ($call op (init, 0)),
                                            T.tys.nil, pe)).tys,
                       $call T.t_var (id)))
      ($call T.t_var (id))
  $decl bound $set s.env ($call bind (s.env, nm, ty))
  $decl noted $set s.fwds ($call fwd_list.cons ($call fwd_ent (nm, id), $call eval_fwds (s.fwds)))
  $decl going $set cx.inprog ($if ($call is_form (init, "func"))
                  ($call hint_list.cons ($call hint_ent (nm, id), cx.inprog))
                  ($call hint_list.val (cx.inprog)))
  // §4.11: "A `$fwd` not completed by the end of its block is an error."
  $decl checked $if ($call is_form (comp, "decl")) T.t_unit
      ($call err (cx, $call concat ("$fwd '", $call concat (nm,
          "' is never completed by a $decl in this block")), it))
}

// The completing `$decl` for a `$fwd` name. The name is already bound to
// `[params] -> R` in `e`, so the body is typed without rebinding it, and `R` is
// closed over the result exactly as in `infer_rec_func`.
$decl infer_fwd_body $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node, $decl id 0)
  $if ($call not ($call is_form (n, "func")))
      ($call close_rec (cx, $call infer (cx, e, n), id, n)) {
        $decl ps       $call group_items ($call op (n, 0))
        $decl r        $call infer_params (cx, e, ps, T.tys.nil, e)
        $decl mr       $call mark_params (cx, ps, r.tys, r.env, 0, 0, n)
        $decl saved    $call tval (cx.tryset)
        $decl cleared  $set cx.tryset T.t_bot
        $decl din      $set cx.fdepth ($call add ($call ival (cx.fdepth), 1))
        // §5.3a's owner rule leaves this body's own projection to R2 (`owner_check`).
        $decl fb0      $call sval (cx.fbody)
        $decl fb1      $set cx.fbody ($call fn_key_of (cx, $call op (n, 1)))
        $decl body     $call infer (cx, mr.env, $call op (n, 1))
        $decl fb2      $set cx.fbody fb0
        $decl dout     $set cx.fdepth ($call sub ($call ival (cx.fdepth), 1))
        $decl tries    $call tval (cx.tryset)
        $decl restored $set cx.tryset saved
        $decl res0     $call join_m (cx, body, tries)
        $decl res      $if ($call T.same (res0, $call T.t_var (id))) T.t_bot ($call close_rec (cx,
            res0, id, n))
        // §5.3a, for a `$fwd`-completing `$decl` — see `func_close`.
        $decl ret  $call func_close (cx, e, n, ps, r.tys, res, mr, id)
      }.ret


// Solving the system. Each equation is substituted into the others — never into
// itself, which `close_rec` handles instead — and one round per equation is
// enough to resolve a cycle of that length.
$decl subst_all $func ($decl t T.proto_ty, $decl rs res_list.node) $match rs (
  $case {$prop tag "cons"} $call subst_all ($call T.subst (t, rs.head.id, rs.head.ty), rs.tail),
  $case rs t
)

$decl subst_others $func ($decl t T.proto_ty, $decl rs res_list.node, $decl self 0) $match rs (
  $case {$prop tag "cons"}
    $call subst_others ($if ($call eq_int (rs.head.id, self)) t ($call T.subst (t, rs.head.id,
        rs.head.ty)),
                        rs.tail, self),
  $case rs t
)

$decl solve_once $func ($decl cx proto_ctx, $decl rs res_list.node, $decl all res_list.node,
                        $decl acc res_list.node, $decl x P.proto_span) $match rs (
  $case {$prop tag "cons"} {
    $decl t2  $call close_rec (cx, $call subst_others (rs.head.ty, all, rs.head.id), rs.head.id, x)
    $decl ret $call solve_once (cx, rs.tail, all, $call res_list.cons ($call res_ent (rs.head.id,
        t2), acc), x)
  }.ret,
  $case rs ($call res_list.reverse (acc, res_list.nil))
)

$decl solve $func ($decl cx proto_ctx, $decl rs res_list.node, $decl n 0, $decl x P.proto_span)
  $if ($call eq_int (n, 0)) rs
      ($call solve (cx, $call solve_once (cx, rs, rs, res_list.nil, x), $call sub (n, 1), x))

$decl apply_res_fields $func ($decl fs T.fields.node, $decl rs res_list.node,
    $decl acc T.fields.node) $match fs (
  $case {$prop tag "cons"}
    $call apply_res_fields (fs.tail, rs,
        $call T.fields.cons ($call T.field (fs.head.name, $call subst_all (fs.head.ty, rs)), acc)),
  $case fs ($call T.fields.reverse (acc, T.fields.nil))
)

$decl infer_item $func ($decl cx proto_ctx, $decl s proto_bst, $decl pe env.node,
                        $decl all Pa.nodes.node, $decl it Pa.proto_node)
  $if ($call is_form (it, "prop")) ($call infer_prop_item (cx, s, pe, it))
  ($if ($call is_form (it, "fwd")) ($call infer_fwd_item (cx, s, all, it))
  ($if ($call is_form (it, "decl")) ($call infer_decl_item (cx, s, it))
  // §4.15a: typed where it stands — it may name only what precedes it — and run when
  // the block is done; its value is discarded, as an effect's is.
  ($if ($call is_form (it, "defer")) ($do ($call infer (cx, s.env, $call op (it, 0))) ())
       // §3.3: other expressions run for effect and are discarded.
       ($do ($call infer (cx, s.env, it)) ()))))

$decl infer_items $func ($decl cx proto_ctx, $decl s proto_bst, $decl pe env.node,
                         $decl all Pa.nodes.node, $decl items Pa.nodes.node) $match items (
  $case {$prop tag "cons"}
    $do ($call infer_item (cx, s, pe, all, items.head))
        ($call infer_items (cx, s, pe, all, items.tail)),
  $case items ()
)

$decl recheck_one $func ($decl cx proto_ctx, $decl d proto_def, $decl rs res_list.node) {
  $decl a $call subst_all (d.sub, rs)
  $decl b $call subst_all (d.sup, rs)
  $decl ret $if ($call or ($call has_free_var (a), $call has_free_var (b)))
      // Still unresolved: it belongs to an enclosing knot, so hand it on.
      ($set cx.defer ($call def_list.cons ($call def_ent (d.line, d.col, d.msg, a, b),
                                           $call eval_defer (cx.defer))))
      ($if ($call T.sub (a, b)) T.t_unit
           ($do ($call T.explain (a, b))
                ($call err (cx, $call concat (d.msg, $call concat ($call T.show (a),
                     $call concat (", expected ", $call T.show (b)))), d))))
}.ret

$decl recheck_list $func ($decl cx proto_ctx, $decl ds def_list.node,
    $decl rs res_list.node) $match ds (
  $case {$prop tag "cons"} $do ($call recheck_one (cx, ds.head, rs)) ($call recheck_list (cx,
      ds.tail, rs)),
  $case ds ()
)

$decl recheck_defers $func ($decl cx proto_ctx, $decl rs res_list.node) {
  $decl ds      $call eval_defer (cx.defer)
  $decl cleared $set cx.defer def_list.nil
  $decl ret     $call recheck_list (cx, ds, rs)
}.ret

// §3.3: a block's type is the ordered list of its `$decl` slots plus its props.
$decl replace_prop_ty $func ($decl xs T.props.node, $decl nm "", $decl t T.proto_ty,
    $decl acc T.props.node) $match xs (
  $case {$prop tag "cons"}
    $call replace_prop_ty ($call T.props.val (xs.tail), nm, t, $call T.props.cons (
        $if ($call eq_str (xs.head.name, nm)) ($call T.prop_typed (nm, xs.head.value, t)) xs.head,
        acc)),
  $case xs ($call T.props.reverse (acc, T.props.nil))
)

// §4.10: "a member that writes through its receiver needs a mutable one, which is part
// of the member's type." So a member is typed against a read-only receiver first. If that
// fails and the declaration is `$mut`, it is retyped against a mutable one and its type
// marked; otherwise the read-only typing stands, and so do its errors. The trial is loud
// with its diagnostics rolled back, because a quiet `err` records nothing to count.
//
// A parameter default is a type-only position (§5.7), where "the declaring name is the
// block's complete type, so a member takes another value of its own type as `$prop
// same_w $func ($decl other rect) …`" (§4.10). So the defaults see `rn` as the block and
// only the body sees it as the receiver.
$decl recv_one $func ($decl cx proto_ctx, $decl pe env.node, $decl it Pa.proto_node, $decl rn "",
    $decl bt T.proto_ty, $decl mutok P.boolean, $decl acc T.props.node) {
  $decl nm   $call name_of ($call op (it, 0))
  $decl init $call op (it, 1)
  $decl e0   $call Pa.diags.val (cx.errs)
  $decl dpe  $call bind (pe, rn, bt)
  $decl rpe  $call bind (pe, rn, $call T.t_ref ("const", bt))
  $decl ty0  $call infer_rec_func (cx, rpe, nm, init, dpe)
  $decl bad  $call lt ($call Pa.diags.length (e0, 0), $call Pa.diags.length (cx.errs, 0))
  $decl ty   $if ($call and (bad, mutok)) {
    $decl back $set cx.errs e0
    $decl mpe  $call bind (pe, rn, $call T.t_ref ("mut", bt))
    $decl tm   $call infer_rec_func (cx, mpe, nm, init, dpe)
    $decl ret2 $call T.with_rmut (tm)
  }.ret2 ty0
  $decl ret  $call replace_prop_ty (acc, nm, ty, T.props.nil)
}.ret

// §4.10's third pass: each member naming the receiver, typed with the receiver bound.
$decl recv_props $func ($decl cx proto_ctx, $decl pe env.node, $decl items Pa.nodes.node,
    $decl rn "", $decl bt T.proto_ty, $decl mutok P.boolean, $decl acc T.props.node) $match items (
  $case {$prop tag "cons"} {
    $decl it  items.head
    // Only a `$prop` has a second operand, and §7.1 makes a `$decl` strict, so each read
    // of one stays inside the test that it exists.
    $decl ok  $if ($call is_form (it, "prop"))
                  ($if ($call is_form ($call op (it, 1), "func"))
                       ($call Pa.names_recv ($call op (it, 1), rn)) false) false
    $decl a2  $if ok ($call recv_one (cx, pe, it, rn, bt, mutok, acc)) acc
    $decl ret $call recv_props (cx, pe, $call Pa.nodes.val (items.tail), rn, bt, mutok, a2)
  }.ret,
  $case items acc
)

$decl infer_block $func ($decl cx proto_ctx, $decl e0 env.node, $decl items Pa.nodes.node,
                         $decl x P.proto_span) {
  // §5.3a's fixed point (see the end): what a second typing of a file starts from.
  $decl h0     $call hint_list.length (cx.hints, 0)
  $decl es0    $call Pa.diags.val (cx.errs)
  $decl ds0    $call eval_defer (cx.defer)
  $decl pc0    $call pesc_list.val (cx.pesc)
  $decl uniq   $call check_unique (cx, items, Pa.nodes.nil, "bound in this block")
  $decl fwdr   $call check_fwd_reads (cx, items)
  // §4.15a: at a file's top level "the end of its evaluation" would be before `main`.
  $decl topd   $if ($call P.and ($call eq_int (x.line, 0), $call eq_int (x.col, 0))) {
    $decl d    $call first_defer (items)
    $decl d2   $call bare_any (items)
    $decl r3   $if ($call is_defer (d))
        ($do ($call err (cx, "$defer at a file's top level is not defined yet (DEFER.md)", d)) ())
        ()
    $decl ret3 $if ($call is_defer (d2))
        ($do ($call err (cx, "$defer in a $new block at a file's top level is not defined yet (DEFER.md)", d2)) ())
        ()
  }.ret3 ()
  $decl pe0    $call prebind_props (cx, items, e0)
  // §4.10: the block a `$decl` is declaring claims its receiver, and only that block —
  // a block nested inside it has a span of its own.
  $decl mine   $call P.and ($call P.not ($call eq_str ($call sval (cx.rname), "")),
                   $call P.and ($call eq_int ($call ival (cx.rline), x.line),
                               $call eq_int ($call ival (cx.rcol), x.col)))
  $decl rn     $if mine ($call sval (cx.rname)) ""
  $decl rq     $call sval (cx.rqual)
  // Design point 7: this block's `$traitsof rn` is a placeholder until the block is done.
  $decl so_n   $call sval (cx.stname)
  $decl so_i   $call ival (cx.stid)
  $decl so_u   $call bval (cx.stuse)
  $decl so_b   $call T.tval (cx.stblk)
  $decl sid    $if ($call eq_str (rn, "")) so_i ($call fresh (cx))
  $decl sn1    $set cx.stname ($if ($call eq_str (rn, "")) so_n rn)
  $decl si1    $set cx.stid sid
  $decl su1    $set cx.stuse ($if ($call eq_str (rn, "")) so_u false)
  $decl sb1    $set cx.stblk ($if ($call eq_str (rn, "")) so_b T.t_bot)
  // Read now: typing the items may reach another `$impl`, which sets these afresh.
  $decl isimp  $call P.and ($call eq_int ($call ival (cx.rbline), x.line),
                   $call eq_int ($call ival (cx.rbcol), x.col))
  $decl rbase  $call T.tval (cx.rbase)
  // Restored, not cleared: this block may itself sit inside a quiet pass — a member's
  // provisional typing (`prop_pass`), whose body is a `{ … }.ret` — and clearing the flag
  // made the rest of that pass report the placeholder errors it exists to swallow.
  //
  // And the quiet pass leaves no specialisation behind: §4.9's memo would hand the loud
  // pass an answer whose errors were swallowed — a body typed at a placeholder, or a
  // depth-limit chain — and the loud pass would never type it to report them. So the
  // outermost quiet pass puts the memo back as it found it; inside one, repeats still hit.
  $decl q0     $call bval (cx.quiet)
  $decl mm0    $call eval_memo (cx.memo)
  $decl hushed $set cx.quiet true
  $decl peA    $call prop_pass (cx, pe0, items, pe0, rn)
  $decl heard  $set cx.quiet q0
  $decl unmemo $set cx.memo ($if q0 ($call eval_memo (cx.memo)) mm0)
  $decl pe     $call prop_pass (cx, pe0, items, peA, rn)
  $decl s      $call bst (pe)
  $decl walked $call infer_items (cx, s, pe, items, items)
  // §5.5: the group is solved as one system, then its answers are substituted
  // everywhere — a sibling typed before the group closed still mentions the
  // placeholders.
  $decl eqns   $call eval_res (s.res)
  $decl solved $call solve (cx, eqns, $call res_list.length (eqns, 0), x)
  $decl flds   $call apply_res_fields ($call T.fields.reverse (s.flds, T.fields.nil),
                                       solved, T.fields.nil)
  $decl late $call recheck_defers (cx, solved)
  // The members that name the receiver, typed for real: the block's type exists now,
  // and the receiver is a reference to it at the declaration's qualifier (§4.10). A
  // prop's `ty` is outside the block's identity (§5.1), so replacing it moves nothing.
  $decl bt0  $if isimp ($call T.impl_ty (rbase, $call T.props.val (s.prps)))
                 ($call T.t_block (flds, s.prps))
  $decl sb2  $set cx.stblk ($if ($call eq_str (rn, "")) ($call T.tval (cx.stblk)) bt0)
  $decl prps $if ($call eq_str (rn, "")) ($call T.props.val (s.prps))
                 ($call recv_props (cx, pe, items, rn, bt0, $call eq_str (rq, "mut"),
                     $call T.props.val (s.prps)))
  $decl t1u  $call T.t_block (flds, prps)
  // The placeholder closed: the trait of the finished block, with `stid` as the bound
  // variable of a μ around it, substituted back into the block's props (§5.5).
  $decl used $if ($call eq_str (rn, "")) false ($call bval (cx.stuse))
  $decl t1   $if used ($call close_self (t1u, sid)) t1u
  $decl sn2  $set cx.stname so_n
  $decl si2  $set cx.stid so_i
  $decl su2  $set cx.stuse ($if ($call eq_str (rn, "")) ($call bval (cx.stuse)) so_u)
  $decl sb3  $set cx.stblk so_b
  // §5.3a, for mutual recursion: a parameter found to escape only after its function had
  // closed — a `$fwd` member passing its own to a later one, or a body nested in a
  // recursive one — leaves a hint, and everything typed after that function saw its
  // smaller set. So a file with a new hint is typed again, its diagnostics and deferred
  // checks rolled back, until none appears; hints only grow, so this ends, and a file that
  // finds none is typed once. At file level and not per block, because the retry has to
  // reach whatever the hinted function is nested in, and because a wrapper around this
  // function made lowering the compiler blow up (it is the centre of inference's largest
  // recursion; CLAUDE.md records the same symptom from an earlier attempt).
  $decl ret  $if ($if ($call eq_int (x.line, 0))
                      ($call lt (h0, $call hint_list.length (cx.hints, 0))) false) {
    $decl a    $set cx.errs es0
    $decl b    $set cx.defer ds0
    $decl c    $set cx.pesc pc0
    $decl ret2 $call infer_block (cx, e0, items, x)
  }.ret2 t1
}.ret

// §4.16: `$extern "symbol" sig` binds a C function and "evaluates to a callable
// value". `sig` is a type-only position (§5.7) whose type — an example `$func` —
// *is* the C signature, so the form's type is simply that, and §4.16's ABI
// mapping is a function of the type alone. The symbol is a string literal, which
// the parser has already required, and nothing here looks at it: the backend
// reads it off the AST.
//
// Rule 1 makes an extern call **unsafe by declaration** and says "the compiler
// treats every extern call as opaque", so there is nothing further to check on
// this side — the signature is taken on trust, exactly as a `$decl`'s parameter
// default is.
$decl infer_extern $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl t $call T.tval ($call infer (cx, e, $call op (n, 1)))
  // §4.7's catch-all idiom needs a *name* to narrow, so the unrolling is bound
  // first — and it has to be unrolled at all because §5.5's `μ` would read as
  // opaque otherwise.
  $decl u $call T.unroll (t)
  $decl ret $match u (
      $case {$prop tag "func"} t,
      $case u ($call err (cx, $call concat (
          "$extern's signature must be an example $func (§4.16), found ",
          $call T.show (t)), n))
    )
}.ret

// ------------------------------------------------------------------ dispatch

// DEFER.md step 4: `$free r` releases allocated storage through the allocator in scope —
// `free (addr, size)`, the root's `raw_free (addr)` — which runs any deferrals registered
// for it first. Frame storage is released with its frame, and a `&const` view cannot end
// what it only reads. Which allocator made `r` is checked by lowering, which can tell
// bindings apart. `unit`.
$decl infer_free $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl t   $call T.tval ($call infer (cx, e, $call op (n, 0)))
  $decl ok  $match t (
      $case {$prop tag "ref"}
        $if ($call T.is_alloc (t.kind)) ($call not ($call eq_str (t.qual, "const"))) false,
      $case t false
    )
  $decl e1  $if ok ()
      ($do ($call err (cx, $call concat ("$free needs allocated storage it may end, found ",
           $call concat ($call T.show (t), ": frame storage is released with its frame, and a $const view only reads (DEFER.md)")), n)) ())
  $decl f   $call lookup (e, "allocator")
  $decl root $if f.ok ($call T.same (f.ty, T.ffi_alloc)) true
  $decl rec $call note_freed (cx, $call op (n, 0), root)
  $decl e2  $if root () {
    $decl sp   $call P.span_of (n)
    $decl m    $call Pa.n_projn ($call Pa.n_name ("allocator", sp.line, sp.col), "free",
                   sp.line, sp.col)
    $decl mt   $call deref_ty ($call infer (cx, e, m))
    $decl two  $call two_params (mt)
    $decl ret3 $if two ()
        ($do ($call err (cx, $call concat ("the allocator in scope cannot serve $free: its free is ",
             $call concat ($call T.show (mt), ", which must take an address and a size (DEFER.md)")), n)) ())
  }.ret3
  $decl ret T.t_unit
}.ret

$decl infer_form $func ($decl cx proto_ctx, $decl e env.node, $decl n proto_form) {
  $decl k n.keyword
  $decl ret
    $if ($call eq_str (k, "decl"))  ($call infer (cx, e, $call op (n, 1)))
    ($if ($call eq_str (k, "new"))
         ($do ($call storage_defer (cx, e, n)) ($call infer_new (cx, e, n)))
    ($if ($call eq_str (k, "free"))  ($call infer_free (cx, e, n))
    // §4.2a: the same shape as `$new`, and the other storage kind (§3.5).
    // Where it comes from is the `allocator` in lexical scope (§7.6), which
    // is a runtime matter; the type records only that it outlives scopes.
    ($if ($call eq_str (k, "alloc")) {
      $decl sd $call storage_defer (cx, e, n)
      $decl ac $call alloc_conforms (cx, e, n)
      $decl v $call deref_ty ($call infer (cx, e, $call op (n, 0)))
      // §5.3a again: allocated storage is exactly "storage that is not
      // itself frame-bound", so putting a frame reference in one escapes.
      $decl esc  $call escapes (cx, v, "this value", n)
      $decl ret2 $call T.t_ref_k ("", v, T.k_alloc)
    }.ret2
    ($if ($call or ($call eq_str (k, "mut"), $call eq_str (k, "const")))
                                     ($call infer_mut (cx, e, n, k))
    ($if ($call eq_str (k, "set"))   ($call infer_set (cx, e, n))
    ($if ($call eq_str (k, "func"))  ($call infer_func (cx, e, n))
    ($if ($call eq_str (k, "call"))  ($call infer_call (cx, e, n))
    ($if ($call eq_str (k, "if"))
         ($do ($call arm_storage (cx, $call Pa.nodes.cons ($call op (n, 1),
                   $call Pa.nodes.cons ($call op (n, 2), Pa.nodes.nil))))
              ($call infer_if (cx, e, n)))
    ($if ($call eq_str (k, "do"))    ($do ($call infer (cx, e, $call op (n, 0)))
                                          ($call infer (cx, e, $call op (n, 1))))
    ($if ($call eq_str (k, "union")) ($call infer_union (cx, e, n))
    ($if ($call eq_str (k, "match"))
         ($do ($call arm_storage (cx, $call case_bodies ($call group_items ($call op (n, 1)),
                   Pa.nodes.nil)))
              ($call infer_match (cx, e, n)))
    ($if ($call eq_str (k, "try"))   ($call infer_try (cx, e, n))
    ($if ($call eq_str (k, "template"))   ($call infer_template (cx, e, n))
    ($if ($call eq_str (k, "specialize")) ($call infer_specialize (cx, e, n))
    ($if ($call eq_str (k, "import"))     ($call infer_import (cx, n))
    ($if ($call eq_str (k, "extern"))     ($call infer_extern (cx, e, n))
    ($if ($call eq_str (k, "traitsof"))   ($call infer_traitsof (cx, e, n))
    ($if ($call eq_str (k, "impl"))       ($call infer_impl (cx, e, n))
    ($if ($call eq_str (k, "overload"))   ($call infer_overload (cx, e, n))
    ($if ($call eq_str (k, "defer"))
         ($call err (cx, "$defer is a block item: it belongs directly in a block's items (§4.15a)", n))
         ($call err (cx, $call concat ("typing $", $call concat (k, " is not implemented yet")), n))
    ))))))))))))))))))))
}.ret

$decl infer $func ($decl cx proto_ctx, $decl e env.node, $decl n Pa.proto_node) $match n (
  // §3.1: "Literals have their base type." There are no singleton literal types.
  $case {$prop tag "int"}   T.t_int,
  $case {$prop tag "float"} T.t_float,
  $case {$prop tag "str"}   T.t_str,
  // §3.2 is the exception: `true` and `false` are distinct nullary *tag* types,
  // so a boolean literal's type is narrower than Bool.
  $case {$prop tag "bool"}  $if n.value T.t_true T.t_false,
  $case {$prop tag "unit"}  T.t_unit,
  $case {$prop tag "name"} {
    $decl f $call lookup (e, n.text)
    $decl ret $if f.ok f.ty
        ($call err (cx, $call concat ("unknown name '", $call concat (n.text, "'")), n))
  }.ret,
  $case {$prop tag "group"} $call T.t_group ($call infer_tys (cx, e, n.items, T.tys.nil)),
  $case {$prop tag "block"} $call infer_block (cx, e, n.items, n),
  $case {$prop tag "proj_name"}  $call infer_proj_name (cx, e, n),
  $case {$prop tag "proj_index"} $call infer_proj_index (cx, e, n),
  $case {$prop tag "form"}  $call infer_form (cx, e, n),
  // A parse error already reported; ⊥ keeps it from cascading.
  $case n T.t_bot
)

// ---------------------------------------------------------------------- entry

$decl result $func ($decl t T.proto_ty, $decl ds Pa.diags.node, $decl ua strs.node)
  { $decl ty t  $decl errs ds  $decl ualloc ua }

// The parser leaves `file` empty; this fills it in once the reader is known.
$decl stamp_file $func ($decl xs Pa.diags.node, $decl path "", $decl acc Pa.diags.node) $match xs (
  $case {$prop tag "cons"}
    $call stamp_file (xs.tail, path, $call Pa.diags.cons (
        $call Pa.diag (xs.head.msg, xs.head.line, xs.head.col, path), acc)),
  $case xs ($call Pa.diags.reverse (acc, Pa.diags.nil))
)

// §3.3: "A source file is a block."
$decl infer_file $func ($decl items Pa.nodes.node, $decl e0 env.node, $decl base "",
    $decl path "", $decl roots strs.node) {
  $decl cx     $call ctx ()
  $decl rooted $set cx.base base
  $decl libs   $set cx.roots roots
  $decl named  $set cx.file path
  $decl t      $call infer_block (cx, e0, items, P.proto_span)
  $decl ret    $call result (t, $call Pa.diags.reverse (cx.errs, Pa.diags.nil),
                   $call strs.val (cx.ualloc))
}.ret

// `base` is the directory `$import` resolves from; it defaults to the working
// directory so that existing single-file callers are unaffected (§3.4).
// `check_source` with the §9 interface cache on, answering the hit and miss counts
// beside the type so a build can see whether its cache is working. A separate entry
// point rather than a fourth parameter on `check_source`: §3.4 makes a short call an
// arity error, so widening a function every caller uses is the expensive change this
// codebase keeps a second constructor for.
$decl cached_res $func ($decl t T.proto_ty, $decl ds Pa.diags.node, $decl h 0, $decl m 0)
  { $decl ty t  $decl errs ds  $decl hits h  $decl misses m }

$decl check_cached $func ($decl src "", $decl base "", $decl path "", $decl dir "") {
  $decl p $call Pa.parse (src)
  $decl ret $if ($call Pa.diags.is_nil (p.errs)) {
    $decl cx     $call ctx ()
    $decl rooted $set cx.base base
    $decl named  $set cx.file path
    $decl cached $set cx.cdir dir
    $decl t      $call infer_block (cx, root_env, p.exprs, P.proto_span)
    $decl ret2 $call cached_res (t, $call Pa.diags.reverse (cx.errs, Pa.diags.nil),
                $call ival (cx.nhit), $call ival (cx.nmiss))
  }.ret2
      ($call cached_res (T.t_bot, $call stamp_file (p.errs, path, Pa.diags.nil), 0, 0))
}.ret

$decl check_source $func ($decl src "", $decl base "", $decl path "") {
  $decl p $call Pa.parse (src)
  $decl ret $if ($call Pa.diags.is_nil (p.errs))
      ($call infer_file (p.exprs, root_env, base, path))
      ($call result (T.t_bot, $call stamp_file (p.errs, path, Pa.diags.nil)))
}.ret

// Imports resolve relative to the entry file, so that a module's imports mean
// the same thing however the checker was invoked.
$decl check_file $func ($decl path "") {
  $decl src $call read_module (path)
  $decl ret $call check_source (src, $call P.dirname (path), path)
}.ret
