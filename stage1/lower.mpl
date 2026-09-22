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

// Integer subtraction, captured before anything in this file could shadow it
// — a `$decl sub` anywhere below would take every `$call sub` with it,
// including the ones written above it (§4.10: a name resolves against the
// finished block).
$decl isub sub

$decl strs $specialize P.list ""

$decl mem_str $func ($decl xs strs.node, $decl x "") $match xs (
  $case {$prop tag "cons"} $if ($call eq_str (xs.head, x)) true ($call mem_str (xs.tail, x)),
  $case xs false
)

// ------------------------------------------------------------- environment
//
// A name resolves to a frame slot, a closure capture, a top-level function, or
// a root-block intrinsic (§2.1: an intrinsic is an ordinary shadowable name, so
// this is a lookup, not a special case).

$decl bind_ent6 $func ($decl n "", $decl k "", $decl s 0, $decl t T.proto_ty,
                       $decl m 0, $decl tm 0)
  { $decl name n  $decl kind k  $decl slot s  $decl ty t
    // The module this name's value is, if it is one — see the compile-time
    // environment below. -1 for everything that is not a block with props.
    $decl mod m
    // The template it is, likewise. §4.9 makes a template compile-time and
    // `$specialize` its only consumer, so this is how that consumer finds the
    // body: the type says *that* a name is a template, this says which one
    // lowering registered.
    $decl tmpl tm }

$decl bind_ent5 $func ($decl n "", $decl k "", $decl s 0, $decl t T.proto_ty, $decl m 0)
  $call bind_ent6 (n, k, s, t, m, -1)

// The four-argument form every ordinary binding uses: nothing but a block with
// props is a module and nothing but a `$template` is a template, so -1 twice
// is the answer almost everywhere.
$decl bind_ent $func ($decl n "", $decl k "", $decl s 0, $decl t T.proto_ty)
  $call bind_ent6 (n, k, s, t, -1, -1)

$decl proto_bind $call bind_ent6 ("", "", 0, T.t_bot, 0, 0)
$decl benv $specialize P.list proto_bind

$decl found $func ($decl ok P.boolean, $decl b proto_bind) { $decl hit ok  $decl bnd b }

$decl lookup $func ($decl e benv.node, $decl n "") $match e (
  $case {$prop tag "cons"}
    $if ($call eq_str (e.head.name, n)) ($call found (true, e.head)) ($call lookup (e.tail, n)),
  $case e ($call found (false, proto_bind))
)

// ------------------------------------------------- the compile-time environment
//
// §4.10 makes `$decl` and `$prop` the one compile-time/runtime split: a prop
// has no layout slot, and its *value* is part of the block's type. So a block
// with props is two things at once — a runtime value with a layout, and a
// namespace the compiler resolves without emitting anything (§4.5: "a block is
// scope, record, module, namespace and (props-only) trait at once").
//
// The type carries a prop's value only when it is a scalar. A function-valued
// prop is `cv_opaque` — an identity, not code — so a projection onto one
// cannot be answered from the type, and lowering keeps the prop's *source*
// instead. That is what a module is here: the prop initializers, the
// environment they were written in, and where each has been lowered to.

// `kind` is "prop" or "decl". §4.10's split survives into the compile-time
// half: a `$prop` has no runtime entity at all and is lowered afresh wherever
// it is named, while a `$decl` — which is what a file's top level is made of
// (§3.3) — has one cell, initialised once in source order.
$decl mprop $func ($decl nm "", $decl n Pa.proto_node, $decl k "")
  { $decl name nm  $decl node n  $decl kind k }
$decl proto_mprop $call mprop ("", Pa.proto_node, "")
$decl mprops $specialize P.list proto_mprop

// A prop already lowered. `kind` is "global" for a function — lifted once, and
// every projection onto it is a fresh reference to the same index — or "pend"
// while its body is being lowered, which is what makes a prop that calls
// itself terminate (§4.9 memoises "before the body is typed" for the same
// reason).
$decl mdone $func ($decl nm "", $decl k "", $decl i 0, $decl t T.proto_ty,
                   $decl md 0, $decl tm 0)
  { $decl name nm  $decl kind k  $decl idx i  $decl ty t
    // What the value *is*, compile-time — a module of its own, or a template.
    // `$decl P $import "prelude"` inside a module is both a global and a
    // namespace, and the namespace is the half that matters.
    $decl mod md  $decl tmpl tm }
$decl proto_mdone $call mdone ("", "", 0, T.t_bot, 0, 0)
$decl mdones $specialize P.list proto_mdone

// `base` is the directory this module's own `$import`s resolve from, and
// `path` the resolved file it was loaded from — empty for a block written in
// place. §4.14 makes the path the identity: "all imports of the same resolved
// file yield the same module".
$decl mod_ent $func ($decl i 0, $decl ps mprops.node, $decl ds mdones.node,
                     $decl en benv.node, $decl bs "", $decl pt "")
  { $decl id i  $decl props ps  $decl done ds  $decl env en  $decl base bs  $decl path pt }
$decl proto_mod $call mod_ent (0, mprops.nil, mdones.nil, benv.nil, "", "")
$decl mods_list $specialize P.list proto_mod

// §4.9's other half. A template is compile-time and has no runtime value at
// all, so what lowering keeps is the same three things a module keeps: the
// generic names, the body, and the environment it was written in.
$decl tmpl_rec $func ($decl i 0, $decl gs strs.node, $decl bd Pa.proto_node, $decl en benv.node)
  { $decl id i  $decl generics gs  $decl body bd  $decl env en }
$decl proto_tmpl $call tmpl_rec (0, strs.nil, Pa.proto_node, benv.nil)
$decl tmpls_list $specialize P.list proto_tmpl

// §4.9: "Typing is memoized per **argument type**." Lowering memoises the same
// way and for a stronger reason — two uses of one specialisation must share
// its lifted functions, or every `$specialize P.list Int` in a program would
// emit its own `cons`. The key is the interned index of each argument's type,
// which is exact: interning is by `T.same`, and de Bruijn binders make
// alpha-equivalent types identical (§5.5).
$decl spec_ent $func ($decl t 0, $decl ks IR.ints.node, $decl m 0, $decl bt T.proto_ty)
  { $decl tmpl t  $decl keys ks  $decl mod m  $decl bty bt }
$decl proto_spec $call spec_ent (0, IR.ints.nil, 0, T.t_bot)
$decl specs_list $specialize P.list proto_spec

$decl same_keys $func ($decl a IR.ints.node, $decl b IR.ints.node) $match a (
  $case {$prop tag "cons"} $match b (
    $case {$prop tag "cons"}
      $if ($call eq_int (a.head, b.head))
          ($call same_keys ($call IR.ints.val (a.tail), $call IR.ints.val (b.tail))) false,
    $case b false),
  $case a ($call IR.ints.is_nil (b))
)

$decl find_tmpl $func ($decl xs tmpls_list.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_int (xs.head.id, i)) ($call tmpls_list.cons (xs.head, tmpls_list.nil))
        ($call find_tmpl ($call tmpls_list.val (xs.tail), i)),
  $case xs tmpls_list.nil
)

$decl find_spec $func ($decl xs specs_list.node, $decl i 0, $decl ks IR.ints.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call and ($call eq_int (xs.head.tmpl, i),
                    $call same_keys ($call IR.ints.val (xs.head.keys), ks)))
        ($call specs_list.cons (xs.head, specs_list.nil))
        ($call find_spec ($call specs_list.val (xs.tail), i, ks)),
  $case xs specs_list.nil
)

$decl find_mod_path $func ($decl xs mods_list.node, $decl p "") $match xs (
  $case {$prop tag "cons"}
    $if ($call and ($call not ($call eq_str (p, "")), $call eq_str (xs.head.path, p)))
        ($call mods_list.cons (xs.head, mods_list.nil))
        ($call find_mod_path ($call mods_list.val (xs.tail), p)),
  $case xs mods_list.nil
)

$decl find_mod $func ($decl xs mods_list.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_int (xs.head.id, i)) ($call mods_list.cons (xs.head, mods_list.nil))
        ($call find_mod ($call mods_list.val (xs.tail), i)),
  $case xs mods_list.nil
)

$decl find_mprop $func ($decl xs mprops.node, $decl n "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, n)) ($call mprops.cons (xs.head, mprops.nil))
        ($call find_mprop ($call mprops.val (xs.tail), n)),
  $case xs mprops.nil
)

$decl find_mdone $func ($decl xs mdones.node, $decl n "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, n)) ($call mdones.cons (xs.head, mdones.nil))
        ($call find_mdone ($call mdones.val (xs.tail), n)),
  $case xs mdones.nil
)

// ------------------------------------------------------------------ state
//
// The interned type table, the frame counter for the function being lowered,
// and the diagnostics. Storage is widened to what gets written into it (§4.2:
// `$new` takes the type of its operand, so `$new xs.nil` would be storage only
// the empty list fits).

$decl lstate $func ()
  { $decl types  $mut $alloc T.tys.node
    $decl ntypes $mut $alloc 0
    $decl nslots $mut $alloc 0
    // The type of each slot allocated so far, newest first (§7.2).
    $decl sltys  $mut $alloc IR.ints.node
    // Identities for opaque prop values; §4.10 makes two distinct
    // function-valued props distinct types, so they must not share one.
    $decl nopaque $mut $alloc 0
    // §4.10's compile-time half: every block with props that lowering has
    // seen, so a projection onto a prop can be answered from its source.
    $decl mods   $mut $alloc mods_list.node
    $decl nmods  $mut $alloc 0
    // §4.9's templates, and the specialisations already built from them.
    $decl tmpls  $mut $alloc tmpls_list.node
    $decl ntmpls $mut $alloc 0
    $decl specs  $mut $alloc specs_list.node
    // §5.5's placeholders. Inference solves knots and hands the answers over,
    // so lowering needs none — except for a specialised template, whose types
    // it derives itself (§4.9), and a prop's value may reach its own type.
    $decl nvars  $mut $alloc 0
    // §4.14: an `$import` resolves relative to the entry file, and a module
    // sees "the root block plus what it imports, nothing else" — so both have
    // to be reachable from wherever an import is lowered.
    $decl base    $mut $alloc ""
    $decl rootenv $mut $alloc benv.node
    // Functions lifted out of `$func` literals, newest first, and the index
    // the first of them will get. The top-level `$decl`s take the indices
    // below that, in source order, so that a global's index is its position.
    $decl lifted  $mut $alloc IR.fns.node
    $decl nlifted $mut $alloc 0
    $decl fnbase  $mut $alloc 0
    $decl errs   $mut $alloc Pa.diags.node }

$decl proto_lst $call lstate ()

$decl eval_tys   $func ($decl x T.tys.node) x
$decl eval_diags $func ($decl x Pa.diags.node) x

$decl err $func ($decl st proto_lst, $decl m "", $decl x P.proto_span)
  { $decl noted $set st.errs ($call Pa.diags.cons ($call Pa.diag (m, x.line, x.col, ""),
                                                   $call eval_diags (st.errs)))
    $decl out   0 }.out

// Append, so that an index into the table stays the index it was handed out
// as. The table holds one entry per *distinct* type, and both of the obvious
// ways to speed this up have been tried and measured; neither helped. Read the
// note in CLAUDE.md before trying a third.
$decl append_ty $func ($decl xs T.tys.node, $decl t T.proto_ty)
  $call T.tys.reverse ($call T.tys.cons (t, $call T.tys.reverse (xs, T.tys.nil)), T.tys.nil)

// Interning is exact because de Bruijn binders make alpha-equivalent types
// identical (§5.5), so `T.same` is the right key and one index names one C
// struct however the type was spelled.
$fwd intern

// A `μ` reaches the table as one entry, but the backend has to *lay it out*,
// and its layout is its unrolling — whose parts were never interned, because
// they were never lowered as expressions: what lowering saw was the body with
// a placeholder in it (§5.5), not the body with the `μ` substituted back.
//
// So interning a `μ` also interns its unrolling's components, which is what
// gives each of them a C struct name. It terminates because the `μ` is in the
// table before this runs, so the `&μ` inside its own members finds it and
// stops — and §5.5's guardedness is what guarantees that inner reference is a
// reference and not another level of unrolling.
$decl seal_tys $func ($decl st proto_lst, $decl xs T.tys.node) $match xs (
  $case {$prop tag "cons"}
    $do ($call intern (st, xs.head)) ($call seal_tys (st, $call T.tys.val (xs.tail))),
  $case xs 0
)

$decl seal_flds $func ($decl st proto_lst, $decl xs T.fields.node) $match xs (
  $case {$prop tag "cons"}
    $do ($call intern (st, xs.head.ty)) ($call seal_flds (st, $call T.fields.val (xs.tail))),
  $case xs 0
)

$decl seal_rec $func ($decl st proto_lst, $decl t T.proto_ty)
  { $decl u $call T.unroll (t)
    $decl r $match u (
        $case {$prop tag "union"}
          $do ($call seal_tys (st, $call T.tys.val (u.members))) ($call intern (st, u)),
        $case {$prop tag "block"}
          $do ($call seal_flds (st, $call T.fields.val (u.fields))) ($call intern (st, u)),
        $case u 0
      ) }.r

$decl is_rec $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "rec"} true,
  $case t false
)

$decl intern $func ($decl st proto_lst, $decl t T.proto_ty)
  { $decl cur $call T.tys.val ($call eval_tys (st.types))
    // The count before anything is added: on a miss that *is* the new entry's
    // index, and `seal_rec` below may add more without changing it.
    $decl cnt $call P.ival (st.ntypes)
    $decl f   $call IR.find_ty (cur, t)
    $decl out $if f.hit f.id
        { $decl added $set st.types ($call append_ty (cur, t))
          $decl n     $set st.ntypes ($call add (cnt, 1))
          // After the entry exists, never before: the unrolling names this
          // very type, and finding it is what ends the recursion.
          $decl sealed $if ($call is_rec (t)) ($call seal_rec (st, t)) 0
          $decl r     cnt }.r }.out

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

$decl eval_mods $func ($decl x mods_list.node) x

// Replace a module's entry, keyed by id. The table is small — one per block
// with props — so a rebuild costs less than the indirection a mutable cell in
// each entry would need.
$decl put_mod $func ($decl xs mods_list.node, $decl m proto_mod, $decl acc mods_list.node)
  $match xs (
    $case {$prop tag "cons"}
      $call put_mod ($call mods_list.val (xs.tail), m,
          $call mods_list.cons ($if ($call eq_int (xs.head.id, m.id)) m xs.head, acc)),
    $case xs ($call mods_list.reverse (acc, mods_list.nil))
  )

$decl save_mod $func ($decl st proto_lst, $decl m proto_mod)
  { $decl s $set st.mods ($call put_mod ($call eval_mods (st.mods), m, mods_list.nil))
    $decl r 0 }.r

$decl fresh_var $func ($decl st proto_lst)
  { $decl i $call P.ival (st.nvars)
    $decl n $set st.nvars ($call add (i, 1))
    $decl r i }.r

// Everything a pass can add that outlives it. The first pass of a recursive
// member exists *only* to find its type — §5.5's knot has to be closed before
// the body can be lowered for real — so nothing it built may survive: the
// specialisations it memoised are keyed on the placeholder, and the functions
// it lifted for them would be dead code carrying a type that is not a layout.
$decl lsnap $func ($decl lf IR.fns.node, $decl nl 0, $decl md mods_list.node, $decl nm 0,
                   $decl sp specs_list.node, $decl tm tmpls_list.node, $decl nt 0)
  { $decl lifted lf  $decl nlifted nl  $decl mods md  $decl nmods nm
    $decl specs sp   $decl tmpls tm    $decl ntmpls nt }

$decl proto_lsnap $call lsnap (IR.fns.nil, 0, mods_list.nil, 0, specs_list.nil,
                      tmpls_list.nil, 0)

$decl eval_tmpls $func ($decl x tmpls_list.node) x
$decl eval_specs $func ($decl x specs_list.node) x

$decl take_snap $func ($decl st proto_lst)
  $call lsnap ($call IR.fns.val (st.lifted), $call P.ival (st.nlifted),
      $call eval_mods (st.mods), $call P.ival (st.nmods),
      $call eval_specs (st.specs), $call eval_tmpls (st.tmpls), $call P.ival (st.ntmpls))

$decl put_snap $func ($decl st proto_lst, $decl sn proto_lsnap)
  { $decl a $set st.lifted  ($call IR.fns.val (sn.lifted))
    $decl b $set st.nlifted sn.nlifted
    $decl c $set st.mods    ($call mods_list.val (sn.mods))
    $decl d $set st.nmods   sn.nmods
    $decl e $set st.specs   ($call specs_list.val (sn.specs))
    $decl f $set st.tmpls   ($call tmpls_list.val (sn.tmpls))
    $decl g $set st.ntmpls  sn.ntmpls
    $decl r 0 }.r

$decl fresh_tmpl $func ($decl st proto_lst, $decl gs strs.node, $decl bd Pa.proto_node,
                        $decl en benv.node)
  { $decl i $call P.ival (st.ntmpls)
    $decl n $set st.ntmpls ($call add (i, 1))
    $decl t $set st.tmpls ($call tmpls_list.cons ($call tmpl_rec (i, gs, bd, en),
                               $call eval_tmpls (st.tmpls)))
    $decl r i }.r

$decl add_spec $func ($decl st proto_lst, $decl sp proto_spec)
  { $decl s $set st.specs ($call specs_list.cons (sp, $call eval_specs (st.specs)))
    $decl r 0 }.r

$decl eval_benv $func ($decl x benv.node) x

$decl fresh_mod_at $func ($decl st proto_lst, $decl ps mprops.node, $decl en benv.node,
                          $decl bs "", $decl pt "")
  { $decl i $call P.ival (st.nmods)
    $decl n $set st.nmods ($call add (i, 1))
    $decl m $set st.mods ($call mods_list.cons ($call mod_ent (i, ps, mdones.nil, en, bs, pt),
                              $call eval_mods (st.mods)))
    $decl r i }.r

$decl fresh_mod $func ($decl st proto_lst, $decl ps mprops.node, $decl en benv.node)
  $call fresh_mod_at (st, ps, en, "", "")

$decl mod_props $func ($decl st proto_lst, $decl mid 0)
  { $decl ms $call find_mod ($call eval_mods (st.mods), mid)
    $decl r $match ms (
        $case {$prop tag "cons"} ($call mprops.val (ms.head.props)),
        $case ms mprops.nil
      ) }.r

// A global index reserved before the function that fills it exists. A prop
// whose body calls itself needs its own name bound while that body is lowered,
// and a name is bound to an index — so the index has to come first.
$decl reserve_lifted $func ($decl st proto_lst)
  { $decl i $call P.ival (st.nlifted)
    $decl n $set st.nlifted ($call add (i, 1))
    $decl l $set st.lifted ($call IR.fns.cons (IR.proto_fn, $call IR.fns.val (st.lifted)))
    $decl r $call add ($call P.ival (st.fnbase), i) }.r

$decl replace_at $func ($decl xs IR.fns.node, $decl i 0, $decl f IR.proto_fn,
                        $decl acc IR.fns.node) $match xs (
  $case {$prop tag "cons"}
    $call replace_at ($call IR.fns.val (xs.tail), $call isub (i, 1), f,
        $call IR.fns.cons ($if ($call eq_int (i, 0)) f xs.head, acc)),
  $case xs ($call IR.fns.reverse (acc, IR.fns.nil))
)

// `st.lifted` is newest-first, so it is turned around to be indexed and back
// again. Both the list and the reservation are compile-time bookkeeping.
$decl put_lifted $func ($decl st proto_lst, $decl idx 0, $decl f IR.proto_fn)
  { $decl k   $call isub (idx, $call P.ival (st.fnbase))
    $decl old $call IR.fns.reverse ($call IR.fns.val (st.lifted), IR.fns.nil)
    $decl new $call replace_at (old, k, f, IR.fns.nil)
    $decl s   $set st.lifted ($call IR.fns.reverse (new, IR.fns.nil))
    $decl r   0 }.r

// ------------------------------------------------------------------ results
//
// Lowering returns the node *and* its type: the node carries an interned index,
// which is what `emit` wants, while the type itself is what the next step of
// the derivation wants.

// `mod` is the compile-time half of the answer: which module this value's
// props live in, or -1 when it has none. §4.10 makes a block both at once, so
// a lowered block carries both — the layout in `ir`, the namespace in `mod`.
$decl lres4 $func ($decl e IR.proto_expr, $decl t T.proto_ty, $decl m 0, $decl tm 0)
  { $decl ir e  $decl ty t  $decl mod m  $decl tmpl tm }

$decl lres3 $func ($decl e IR.proto_expr, $decl t T.proto_ty, $decl m 0)
  $call lres4 (e, t, m, -1)

// The two-argument form, for every value that is neither a block with props
// nor a template.
$decl lres $func ($decl e IR.proto_expr, $decl t T.proto_ty) $call lres4 (e, t, -1, -1)

$decl proto_lres $call lres4 ({ $prop tag "unit" $decl ty 0  $decl id 0 }, T.t_bot, 0, 0)

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
$decl result_of $func ($decl t0 T.proto_ty)
  { $decl t $call T.unroll (t0)
    $decl r $match t (
        $case {$prop tag "func"} ($call T.tval (t.result)),
        $case t t
      ) }.r

// §3.5's kind, read off a reference type. Empty for anything that is not one,
// which is the same answer as "frame" and is what a malformed `$mut` would
// get anyway — the error for that is raised where it belongs.
$decl ref_kind $func ($decl t0 T.proto_ty)
  { $decl t $call T.unroll (t0)
    $decl r $match t ($case {$prop tag "ref"} t.kind, $case t "") }.r

$decl deref_ty $func ($decl t0 T.proto_ty)
  { $decl t $call T.unroll (t0)
    $decl r $match t (
        $case {$prop tag "ref"} ($call T.tval (t.inner)),
        $case t t
      ) }.r

// §5.4: a reference behaves as its pointee wherever a value is expected, and
// there is no way to write that in source — so it is written here.
//
// The type is bound to a name before matching on it: §4.7 narrows a scrutinee
// *by its name*, so `$match r.ty` would leave `r.ty.inner` on the whole union.
$decl as_value $func ($decl st proto_lst, $decl r proto_lres)
  { $decl t   $call T.unroll (r.ty)
    $decl out $match t (
        $case {$prop tag "ref"}
          { $decl inner $call T.tval (t.inner)
            // Reading through storage does not change which module the value
            // is, so the compile-time half survives the deref.
            $decl v $call lres4 ($call IR.e_deref ($call intern (st, inner), r.ir), inner,
                        r.mod, r.tmpl) }.v,
        $case t r
      ) }.out

// A field's layout position and type (§7.2: `$decl` order is the layout).
$decl fld_found $func ($decl ok P.boolean, $decl i 0, $decl t T.proto_ty)
  { $decl hit ok  $decl idx i  $decl ty t }

$decl fld_found_proto $call fld_found (false, 0, T.t_bot)

$decl find_fld $func ($decl xs T.fields.node, $decl n "", $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, n)) ($call fld_found (true, i, xs.head.ty))
        ($call find_fld (xs.tail, n, $call add (i, 1))),
  $case xs ($call fld_found (false, 0, T.t_bot))
)

$decl has_fields $func ($decl t0 T.proto_ty)
  { $decl t $call T.unroll (t0)
    $decl r $match t (
        $case {$prop tag "block"} ($call not ($call T.fields.is_nil ($call T.fields.val (t.fields)))),
        $case t false
      ) }.r

// ------------------------------------------------------------------ lowering

// What an unlowered node *was*, for a diagnostic that says so. Worth the
// dozen lines: "this expression is not lowered yet" leaves the reader to find
// which expression, and the answer is usually one construct repeated.
$decl kind_of $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "int"}        "an integer literal",
  $case {$prop tag "float"}      "a float literal",
  $case {$prop tag "str"}        "a string literal",
  $case {$prop tag "bool"}       "a boolean literal",
  $case {$prop tag "name"}       "a name",
  $case {$prop tag "unit"}       "()",
  $case {$prop tag "err"}        "a parse error",
  $case {$prop tag "group"}      "a group (§2.3)",
  $case {$prop tag "block"}      "a block",
  $case {$prop tag "proj_name"}  "a projection",
  $case {$prop tag "proj_index"} "a positional projection (.n)",
  $case n "a form"
)

$decl proto_form  $call Pa.n_form ("", Pa.nodes.nil, 0, 0)
$decl proto_projn $call Pa.n_projn (Pa.proto_node, "", 0, 0)

$fwd lower
$fwd lower_block
// A projection onto a prop, answered from the prop's source. It needs
// `lower_func` (a function-valued prop is lifted like any other `$func`),
// which is far below, and `lower_name` needs it — §4.10 makes a prop visible
// throughout its block, so a prop's body can name its siblings and itself.
$fwd lower_prop

// §5.7's type-only positions are never evaluated, but lowering still has to
// *derive* their types — so it lowers them and throws the tree away. What it
// must not throw away by accident is the enclosing frame: a block in such a
// position would otherwise take slots in it, and §7.2 puts the parameters in
// the first slots, so the signature and the frame would stop agreeing.
$decl type_only $func ($decl st proto_lst, $decl e benv.node, $decl n Pa.proto_node)
  { $decl keep $call take_slots (st)
    $decl v    $call lval ($call lower (st, e, n, false))
    $decl back $call restore_slots (st, keep)
    $decl r    v }.r

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
      ($if ($call eq_str (f.bnd.kind, "prop"))
        // §4.10: a prop is compile-time, so naming one is not reading a slot —
        // it is asking the module what that prop's value lowered to.
        ($call lower_prop (st, f.bnd.mod, nm, n))
        { $decl bt $call T.tval (f.bnd.ty)
          $decl id $call intern (st, bt)
          $decl ir $if ($call eq_str (f.bnd.kind, "local"))   ($call IR.e_local (id, f.bnd.slot))
              ($if ($call eq_str (f.bnd.kind, "capture")) ($call IR.e_capture (id, f.bnd.slot))
              ($if ($call eq_str (f.bnd.kind, "global"))  ($call IR.e_global (id, f.bnd.slot))
                   ($call IR.e_prim (id, nm))))
          $decl r  $call lres4 (ir, bt, f.bnd.mod, f.bnd.tmpl) }.r) }.out

// §4.6 as a layout position. The target is a value position, so a reference
// target is read through first.
// A prop's value read off the type. §4.10 puts it there — "its value is part
// of the block's type" — but only a scalar survives the trip: §1.1's other
// prop initializers become `cv_opaque`, an identity rather than code, so a
// block whose source lowering never saw cannot answer for those.
$decl find_prop $func ($decl xs T.props.node, $decl nm "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, nm)) ($call T.props.cons (xs.head, T.props.nil))
        ($call find_prop ($call T.props.val (xs.tail), nm)),
  $case xs T.props.nil
)

$decl cv_lower $func ($decl st proto_lst, $decl c T.proto_cv, $decl nm "",
                      $decl n Pa.proto_node) $match c (
  $case {$prop tag "cint"}  ($call lres ($call IR.e_int ($call intern (st, T.t_int), c.v), T.t_int)),
  $case {$prop tag "cstr"}  ($call lres ($call IR.e_str ($call intern (st, T.t_str), c.v), T.t_str)),
  $case {$prop tag "cbool"}
    ($call lres ($call IR.e_bool ($call intern (st, T.t_bool), c.v),
                 $if c.v T.t_true T.t_false)),
  $case {$prop tag "cunit"} ($call lres ($call IR.e_unit ($call intern (st, T.t_unit)), T.t_unit)),
  $case c ($call lres ($call IR.e_unit ($call err (st, $call concat ("the value of prop '",
      $call concat (nm, "' is not reachable from here: it is not a scalar, and this block's source was not lowered in this file")), n)), T.t_bot))
)

// The props, not the type: §4.7 narrows by the scrutinee's name and narrowing
// does not cross a call, so the caller — which is inside the `$match` that
// proved this is a block — passes the list out.
$decl prop_from_ty $func ($decl st proto_lst, $decl ps T.props.node, $decl nm "",
                          $decl n Pa.proto_node)
  { $decl f $call find_prop (ps, nm)
    $decl r $match f (
        $case {$prop tag "cons"} ($call cv_lower (st, f.head.value, nm, n)),
        $case f ($call lres ($call IR.e_unit ($call err (st, $call concat ("no field '",
            $call concat (nm, "'")), n)), T.t_bot))
      ) }.r

// §4.6 as a layout position — for a `$decl`. A `$prop` has no layout position
// at all (§4.10), so the two halves of a block are searched in turn: the
// fields, then the props.
// Whether lowering has this name's *source*. A module is asked first, because
// an imported module's members are compile-time here (§4.14) while its type —
// which inference gives in full, §3.3 — still lists them as fields; taking the
// field would emit a read of a layout the module does not have.
$decl mod_has $func ($decl st proto_lst, $decl mid 0, $decl nm "")
  { $decl ms $call find_mod ($call eval_mods (st.mods), mid)
    $decl r $match ms (
        $case {$prop tag "cons"}
          ($if ($call mprops.is_nil ($call find_mprop ($call mprops.val (ms.head.props), nm)))
               ($call not ($call mdones.is_nil ($call find_mdone ($call mdones.val (ms.head.done), nm))))
               true),
        $case ms false
      ) }.r

// §5.1 makes a block's fields an *ordered prefix*, so a union whose members
// all begin the same way has that prefix in common — `Pa.proto_node`'s members
// all start `line`, `col`, and `n.line` is how the parser reads a span off any
// node. Every member agrees on the name, the position and the type, which is
// exactly what C guarantees is readable through any member of a union of
// structs with a common initial sequence.
$decl common_fld $func ($decl ms T.tys.node, $decl nm "", $decl best fld_found_proto)
  $match ms (
    $case {$prop tag "cons"}
      { $decl m $call T.unroll (ms.head)
        $decl f $match m (
            $case {$prop tag "block"} ($call find_fld ($call T.fields.val (m.fields), nm, 0)),
            $case m ($call fld_found (false, 0, T.t_bot))
          )
        // Every member must have it, at the same position.
        $decl ok $if f.hit
            ($if best.hit ($call eq_int (f.idx, best.idx)) true)
            false
        $decl r $if ok ($call common_fld ($call T.tys.val (ms.tail), nm, f))
                       ($call fld_found (false, 0, T.t_bot)) }.r,
    $case ms best
  )

$decl lower_proj $func ($decl st proto_lst, $decl e benv.node, $decl n proto_projn)
  { $decl tgt $call as_value (st, $call lower (st, e, n.target, false))
    $decl tt  $call T.unroll (tgt.ty)
    $decl own $if ($call lt (tgt.mod, 0)) false ($call mod_has (st, tgt.mod, n.field))
    $decl out $match tt (
        $case {$prop tag "block"}
          { $decl f $call find_fld ($call T.fields.val (tt.fields), n.field, 0)
            $decl r $if own ($call lower_prop (st, tgt.mod, n.field, n))
                ($if f.hit
                ($call lres ($call IR.e_field ($call intern (st, f.ty), tgt.ir, f.idx), f.ty))
                ($if ($call lt (tgt.mod, 0))
                     ($call prop_from_ty (st, $call T.props.val (tt.props), n.field, n))
                     ($call lower_prop (st, tgt.mod, n.field, n)))) }.r,
        $case {$prop tag "union"}
          { $decl f $call common_fld ($call T.tys.val (tt.members), n.field, fld_found_proto)
            $decl r $if f.hit
                ($call lres ($call IR.e_field ($call intern (st, f.ty), tgt.ir, f.idx), f.ty))
                ($call lres ($call IR.e_unit ($call err (st, $call concat ("no field '",
                    $call concat (n.field, "' common to every member of this union (§5.1)")), n)),
                    T.t_bot)) }.r,
        $case tt ($call lres ($call IR.e_unit ($call err (st,
            $call concat ("projection needs a block, found ", $call T.show (tt)), n)), T.t_bot))
      ) }.out

// §4.6's `.n`. §2.3 makes a group the only thing it applies to — a block's
// members have names — and inference reads it one-based, so this does too.
$decl lower_projidx $func ($decl st proto_lst, $decl e benv.node, $decl n Pa.proto_node,
                           $decl tgtn Pa.proto_node, $decl idx 0)
  { $decl tgt $call as_value (st, $call lower (st, e, tgtn, false))
    $decl tt  $call T.unroll (tgt.ty)
    $decl out $match tt (
        $case {$prop tag "group"}
          { $decl its $call T.tys.val (tt.items)
            $decl nf  $call T.tys.length (its, 0)
            $decl r $if ($call and ($call lt (0, idx), $call not ($call lt (nf, idx))))
                { $decl k   $call isub (idx, 1)
                  $decl fty $call T.tval ($call T.tys.nth (its, k))
                  $decl q   $call lres ($call IR.e_field ($call intern (st, fty), tgt.ir, k), fty) }.q
                ($call lres ($call IR.e_unit ($call err (st, "group index is out of range", n)),
                    T.t_bot)) }.r,
        $case tt ($call lres ($call IR.e_unit ($call err (st,
            $call concat ("cannot index into ", $call T.show (tt)), n)), T.t_bot))
      ) }.out

// §2.3's group as a value: laid out elementwise (§7.2), so it is a block whose
// members have positions instead of names.
$decl lower_items_g $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node,
                           $decl irs IR.exprs.node, $decl tys T.tys.node) $match xs (
  $case {$prop tag "cons"}
    { $decl v $call lval ($call lower (st, e, xs.head, false))
      $decl r $call lower_items_g (st, e, $call Pa.nodes.val (xs.tail),
                  $call IR.exprs.cons (v.ir, irs), $call T.tys.cons (v.ty, tys)) }.r,
  $case xs ($call args_res ($call IR.exprs.reverse (irs, IR.exprs.nil),
                $call T.tys.reverse (tys, T.tys.nil)))
)

$decl lower_group $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node)
  { $decl a  $call lower_items_g (st, e, xs, IR.exprs.nil, T.tys.nil)
    $decl ty $call T.t_group ($call T.tys.val (a.tys))
    $decl r  $call lres ($call IR.e_group ($call intern (st, ty), $call IR.exprs.val (a.irs)), ty) }.r

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

// §5.5 makes a recursive type a `μ`, and every structural question about one
// is a question about its unrolling. `T.unroll` is the identity on everything
// else, so it costs nothing to ask first — and asking is not optional now that
// a specialised template derives its own recursive types (§4.9) rather than
// reading inference's already-unrolled answers.
// The interned table's own copy of a type.
//
// §3.6 makes a union a *set*, so `T.same` answers yes for two orderings of the
// same members and interning returns whichever ordering got there first. But
// §7.5's discriminator is a **position**, and the backend reads positions off
// the table entry. So anything that computes a discriminator has to ask the
// table, not the copy it happens to be holding, or the two disagree about
// which member is which.
$decl ty_at $func ($decl st proto_lst, $decl i 0)
  $call T.tys.nth ($call T.tys.val ($call eval_tys (st.types)), i)

$decl canon_ty $func ($decl st proto_lst, $decl t T.proto_ty)
  $call ty_at (st, $call intern (st, t))

$decl members_of $func ($decl t0 T.proto_ty)
  { $decl t $call T.unroll (t0)
    $decl r $match t (
        $case {$prop tag "union"} ($call T.tys.val (t.members)),
        $case t ($call T.tys.cons (t, T.tys.nil))
      ) }.r

// §4.8a's type: every member joined. Lowering a member is how its type is
// read; the tree is thrown away, which costs the slots a discarded `$decl`
// would have taken and nothing else.
$fwd union_ty

$decl union_ty $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node,
                      $decl acc T.proto_ty) $match xs (
  $case {$prop tag "cons"}
    { $decl m $call type_only (st, e, xs.head)
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

// ------------------------------------------------------ templates (§4.9)
//
// §4.9's three steps, with step 2 done by lowering rather than typing:
// substitute the argument for the generic, lower the substituted body with
// ordinary rules, and have exactly what that produced. There is no
// `$template` node in the tree (ir.mpl says so) — by this point the program is
// monomorphic, which is what makes a block type a C struct.
//
// The generic is bound the same way a prop is, and for the same reason: its
// value is source the compiler still has, and every use has to lower it afresh
// or two uses would share one node's index (§9.3). The module table is exactly
// that, so a specialisation's generics are a module of their own.

$decl generic_names_list $func ($decl xs Pa.nodes.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"}
    $call generic_names_list ($call Pa.nodes.val (xs.tail),
        $call strs.cons ($call name_of (xs.head), acc)),
  $case xs ($call strs.reverse (acc, strs.nil))
)

// §2.3: with one generic the whole operand is the name; with several it is a
// group.
$decl generic_names $func ($decl n Pa.proto_node, $decl acc strs.node) $match n (
  $case {$prop tag "name"}  ($call strs.cons (n.text, acc)),
  $case {$prop tag "group"} ($call generic_names_list ($call Pa.nodes.val (n.items), acc)),
  $case n acc
)

$decl gen_props $func ($decl gs strs.node, $decl xs Pa.nodes.node, $decl acc mprops.node)
  $match gs (
    $case {$prop tag "cons"} $match xs (
      $case {$prop tag "cons"}
        $call gen_props ($call strs.val (gs.tail), $call Pa.nodes.val (xs.tail),
            $call mprops.cons ($call mprop (gs.head, xs.head, "prop"), acc)),
      $case xs ($call mprops.reverse (acc, mprops.nil))),
    $case gs ($call mprops.reverse (acc, mprops.nil))
  )

$decl with_gens $func ($decl e benv.node, $decl gs strs.node, $decl mid 0) $match gs (
  $case {$prop tag "cons"}
    $call with_gens ($call benv.cons ($call bind_ent6 (gs.head, "prop", 0, T.t_bot, mid, -1), e),
        $call strs.val (gs.tail), mid),
  $case gs e
)

// The memo key: each argument's interned type index. Lowering the argument is
// how its type is known (§5.7 never evaluates it, but lowering has to derive
// it), and the node that produces is discarded — §9.3 lets indices be skipped,
// only not repeated.
$decl arg_keys $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node,
                      $decl acc IR.ints.node) $match xs (
  $case {$prop tag "cons"}
    { $decl a $call type_only (st, e, xs.head)
      $decl r $call arg_keys (st, e, $call Pa.nodes.val (xs.tail),
                  $call IR.ints.cons ($call intern (st, a.ty), acc)) }.r,
  $case xs ($call IR.ints.reverse (acc, IR.ints.nil))
)

$decl spec_build $func ($decl st proto_lst, $decl e benv.node, $decl r proto_tmpl,
                        $decl args Pa.nodes.node, $decl keys IR.ints.node,
                        $decl n Pa.proto_node)
  { $decl gm $call fresh_mod (st, $call gen_props ($call strs.val (r.generics), args, mprops.nil), e)
    $decl be $call with_gens ($call benv.val (r.env), $call strs.val (r.generics), gm)
    $decl v  $call lval ($call lower (st, be, r.body, false))
    $decl ok $if ($call lt (v.mod, 0))
        ($call err (st, "$specialize: this template's body is not a block with props, which is the only shape lowered so far", n))
        ($if ($call has_fields (v.ty))
             ($call err (st, "$specialize: this template's body has $decl fields; only a props-only block is lowered so far", n))
             0)
    $decl sp $call add_spec (st, $call spec_ent (r.id, keys, v.mod, v.ty))
    $decl out v }.out

// A second use of the same specialisation. §4.9 memoises per argument type, so
// this shares the first one's module — and therefore its lifted functions,
// which is the whole point: one `cons` per element type, not one per mention.
// The value is rebuilt rather than shared, because a node index belongs to one
// node (§9.3).
$decl spec_reuse $func ($decl st proto_lst, $decl sp proto_spec)
  { $decl bt $call T.tval (sp.bty)
    $decl r  $call lres3 ($call IR.e_block ($call intern (st, bt), IR.bslots.nil), bt, sp.mod) }.r

$decl spec_with $func ($decl st proto_lst, $decl e benv.node, $decl r proto_tmpl,
                       $decl argn Pa.proto_node, $decl n Pa.proto_node)
  { $decl ng   $call strs.length ($call strs.val (r.generics), 0)
    $decl args $if ($call eq_int (ng, 1)) ($call Pa.nodes.cons (argn, Pa.nodes.nil))
                   ($call group_items (argn))
    $decl na   $call Pa.nodes.length (args, 0)
    $decl out  $if ($call not ($call eq_int (ng, na)))
        ($call lres ($call IR.e_unit ($call err (st, $call concat ("this template has ",
             $call concat ($call int_to_str (ng), $call concat (" generic parameters, found ",
             $call int_to_str (na)))), n)), T.t_bot))
        { $decl keys $call arg_keys (st, e, args, IR.ints.nil)
          $decl hit  $call find_spec ($call eval_specs (st.specs), r.id, keys)
          $decl rr $match hit (
              $case {$prop tag "cons"} ($call spec_reuse (st, hit.head)),
              $case hit ($call spec_build (st, e, r, args, keys, n))
            ) }.rr }.out

// ----------------------------------------------------------- $import (§4.14)
//
// §3.3 makes a file a block, and §4.14 makes `$import` load one — so a module
// is a block whose members are its top-level `$decl`s. The compile-time half
// is all of it: a projection onto a module resolves to the global its member
// was lifted to, and the module itself has no layout. Using one *as a value*
// is not lowered, which is the only thing this gives up.
//
// Members are lowered **eagerly, in source order**, and that is not an
// optimisation — it is what makes the initialisation order right. §4.10
// initialises a `$decl` once, in source order; the backend does that by
// assigning each thunk's static in index order, so the index a member is
// lifted to has to follow the order it was written in. Lowering them lazily
// would number them in order of first *use*, and a member that reads another
// would then read it before it was assigned.

$decl str_of $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "str"} n.text,
  $case n ""
)

$decl resolve_path $func ($decl base "", $decl nm "")
  $if ($call eq_str (base, "")) ($call concat (nm, ".mpl"))
      ($call concat (base, $call concat ("/", $call concat (nm, ".mpl"))))

$decl find_completing $func ($decl xs Pa.nodes.node, $decl nm "") $match xs (
  $case {$prop tag "cons"}
    $if ($call and ($call is_form (xs.head, "decl"),
                    $call eq_str ($call name_of ($call op (xs.head, 0)), nm)))
        xs.head ($call find_completing ($call Pa.nodes.val (xs.tail), nm)),
  $case xs ($call Pa.n_err ("no completing $decl", 0, 0))
)

// A file's top level, as module members, **in the order they become visible**.
//
// §4.10 makes that source order for a `$decl`, and §4.11 makes `$fwd` the way
// to move it earlier: "`$fwd` reserves a layout slot at its own position". So a
// `$fwd`'d name enters the list where the `$fwd` stands, carrying the value its
// completing `$decl` gives it — and the completing `$decl` is then skipped,
// having already been counted. That ordering is what `with_scope` reads.
$decl file_props_at $func ($decl all Pa.nodes.node, $decl xs Pa.nodes.node,
                           $decl acc mprops.node) $match xs (
  $case {$prop tag "cons"}
    { $decl nm  $if ($call is_form (xs.head, "fwd"))
            ($call name_of ($call op (xs.head, 0)))
            ($if ($call is_form (xs.head, "decl")) ($call name_of ($call op (xs.head, 0)))
                 ($if ($call is_form (xs.head, "prop")) ($call name_of ($call op (xs.head, 0))) ""))
      $decl seen $if ($call eq_str (nm, "")) true
                     ($call not ($call mprops.is_nil ($call find_mprop (acc, nm))))
      $decl a2 $if seen acc
          ($if ($call is_form (xs.head, "fwd"))
               ($call mprops.cons ($call mprop (nm,
                    $call op ($call find_completing (all, nm), 1), "decl"), acc))
          ($if ($call is_form (xs.head, "prop"))
               ($call mprops.cons ($call mprop (nm, $call op (xs.head, 1), "prop"), acc))
               ($call mprops.cons ($call mprop (nm, $call op (xs.head, 1), "decl"), acc))))
      $decl r $call file_props_at (all, $call Pa.nodes.val (xs.tail), a2) }.r,
  $case xs ($call mprops.reverse (acc, mprops.nil))
)

$decl file_props $func ($decl xs Pa.nodes.node, $decl acc mprops.node)
  $call file_props_at (xs, xs, acc)

$decl force_props $func ($decl st proto_lst, $decl mid 0, $decl xs mprops.node,
                         $decl n Pa.proto_node) $match xs (
  $case {$prop tag "cons"}
    $do ($call lower_prop (st, mid, xs.head.name, n))
        ($call force_props (st, mid, $call mprops.val (xs.tail), n)),
  $case xs 0
)

$decl mod_value $func ($decl st proto_lst, $decl mid 0)
  { $decl t $call T.t_block (T.fields.nil, T.props.nil)
    $decl r $call lres3 ($call IR.e_block ($call intern (st, t), IR.bslots.nil), t, mid) }.r

$decl load_module $func ($decl st proto_lst, $decl key "", $decl nm "", $decl n Pa.proto_node)
  { $decl rf  $call read_file (key)
    $decl src $match rf ($case {$prop tag "some"} rf.v, $case rf "")
    $decl out $if ($call eq_str (src, ""))
        ($call lres ($call IR.e_unit ($call err (st, $call concat ("cannot read the file for $import \"",
             $call concat (nm, $call concat ("\" (", $call concat (key, ")")))), n)), T.t_bot))
        { $decl p   $call Pa.parse (src)
          // §4.14: "A file sees the root block plus what it imports, nothing
          // else" — so a module is lowered in the root environment, never in
          // the importer's.
          $decl mid $call fresh_mod_at (st, $call file_props ($call Pa.nodes.val (p.exprs), mprops.nil),
                        $call benv.val ($call eval_benv (st.rootenv)), $call P.dirname (key), key)
          $decl f   $call force_props (st, mid, $call mod_props (st, mid), n)
          $decl r   $call mod_value (st, mid) }.r }.out

$decl lower_import $func ($decl st proto_lst, $decl n proto_form)
  { $decl nm  $call str_of ($call op (n, 0))
    $decl key $call resolve_path ($call P.sval (st.base), nm)
    $decl hit $call find_mod_path ($call eval_mods (st.mods), key)
    $decl out $match hit (
        // §4.14: "Loaded once. All imports of the same resolved file yield the
        // same module." A cycle finds the entry too, because it is registered
        // before its members are lowered.
        $case {$prop tag "cons"} ($call mod_value (st, hit.head.id)),
        $case hit ($call load_module (st, key, nm, n))
      ) }.out

$decl lower_specialize $func ($decl st proto_lst, $decl e benv.node, $decl n proto_form)
  { $decl f  $call lval ($call lower (st, e, $call op (n, 0), false))
    $decl ts $if ($call lt (f.tmpl, 0)) tmpls_list.nil
                 ($call find_tmpl ($call eval_tmpls (st.tmpls), f.tmpl))
    $decl out $match ts (
        $case {$prop tag "cons"} ($call spec_with (st, e, ts.head, $call op (n, 1), n)),
        $case ts ($call lres ($call IR.e_unit ($call err (st,
            "$specialize expects a template", n)), T.t_bot))
      ) }.out

$decl lower_match $func ($decl st proto_lst, $decl e benv.node, $decl n proto_form,
                         $decl tail P.boolean)
  { $decl sn    $call op (n, 0)
    $decl scrut $call as_value (st, $call lower (st, e, sn, false))
    $decl items $call group_items ($call op (n, 1))
    $decl out $if ($call T.same (scrut.ty, T.t_bool))
        ($call lower_bool_match (st, e, scrut, items, tail))
        { $decl a $call lower_arms (st, e, items, tail,
                      $call members_of ($call canon_ty (st, scrut.ty)),
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
      // §4.2a. The same node as `$new`: the storage *kind* (§3.5) is already on
      // the node's type, so the tree needs no second field to carry it, and
      // the backend reads it off the type when it has two ways to allocate.
      ($if ($call eq_str (k, "alloc"))
        { $decl v  $call as_value (st, $call lower (st, e, $call op (n, 0), false))
          $decl rt $call T.t_ref_k ("", v.ty, T.k_alloc)
          $decl r  $call lres ($call IR.e_new ($call intern (st, rt), v.ir), rt) }.r
      // §4.3: a view, not a value — no node, only a different type.
      ($if ($call eq_str (k, "mut"))
        { $decl v  $call lval ($call lower (st, e, $call op (n, 0), false))
          // §5.3: a view preserves the kind.
          $decl rt $call T.t_ref_k ("mut", $call deref_ty (v.ty), $call ref_kind (v.ty))
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
          $decl ds  $call disc_of ($call members_of ($call canon_ty (st, v.ty)), pty, 0,
                        IR.ints.nil, IR.ints.nil)
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
      // §4.9: a template is compile-time and has no runtime value, so this
      // registers the body and evaluates to nothing. `$specialize` is the
      // only thing that can consume it, and it finds it by the index here.
      ($if ($call eq_str (k, "template"))
        { $decl gs  $call generic_names ($call op (n, 0), strs.nil)
          $decl tid $call fresh_tmpl (st, gs, $call op (n, 1), e)
          $decl r   $call lres4 ($call IR.e_unit ($call intern (st, T.t_unit)), T.t_unit,
                        -1, tid) }.r
      ($if ($call eq_str (k, "specialize")) ($call lower_specialize (st, e, n))
      ($if ($call eq_str (k, "import")) ($call lower_import (st, n))
      ($if ($call eq_str (k, "call"))
        { $decl f  $call as_value (st, $call lower (st, e, $call op (n, 0), false))
          $decl as $call lower_args (st, e, $call group_items ($call op (n, 1)),
                                     IR.exprs.nil, T.tys.nil)
          $decl ty $call result_of (f.ty)
          $decl r  $call lres ($call IR.e_call ($call intern (st, ty), f.ir, as.irs, tail), ty) }.r
        ($call lres ($call IR.e_unit ($call err (st, $call concat ("$", $call concat (k,
             " is not lowered yet")), n)), T.t_unit)))))))))))))))  }.out

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
  $case {$prop tag "proj_index"} ($call lower_projidx (st, e, n, n.target, n.index)),
  $case {$prop tag "block"} ($call lower_block (st, e, $call Pa.nodes.val (n.items))),
  $case {$prop tag "group"} ($call lower_group (st, e, $call Pa.nodes.val (n.items))),
  $case {$prop tag "form"}  ($call lower_form (st, e, n, tail)),
  $case n ($call lres ($call IR.e_unit ($call err (st,
      $call concat ($call kind_of (n), " is not lowered yet"), n)), T.t_unit))
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
          $case ts { $decl d $call type_only (st, e, $call op (ps.head, 1))
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


// ------------------------------------------------------- props, as values
//
// §4.10 makes a prop compile-time and gives it no layout slot, so a projection
// onto one is resolved here rather than emitted. The block's *type* carries a
// prop's value only when it is a scalar; §1.1's other initializers — a
// prop-only block, a `$func`, a `$template` — become `cv_opaque`, an identity
// rather than code. So lowering keeps the source and answers from that.

// What a *`$decl`* member's initializer may name. §4.10 is source order: a
// `$decl` is visible from its own position onward, which is why `$fwd` exists
// to reserve an earlier one — and why `types.mpl`'s `$decl isub sub` at the
// top captures the integer intrinsic before the file's own `sub` shadows it.
// A `$prop` is different: it is visible throughout its block regardless of
// order, so props are bound wherever they stand.
//
// A `$func` member's *body* is not this: it resolves against the finished
// block, which is what `with_props` gives it.
$decl with_scope $func ($decl e benv.node, $decl xs mprops.node, $decl mid 0, $decl nm "",
                        $decl seen P.boolean) $match xs (
  $case {$prop tag "cons"}
    { $decl hit $call eq_str (xs.head.name, nm)
      // Up to and *including* the member itself: §5.7 lets a type-only position
      // name a declaration that is in progress, which is how a recursive type
      // is written at all (§5.5). Only what comes after is out of scope.
      $decl vis $if ($call eq_str (xs.head.kind, "prop")) true ($if seen false true)
      $decl e2  $if vis
          ($call benv.cons ($call bind_ent6 (xs.head.name, "prop", 0, T.t_bot, mid, -1), e)) e
      $decl sn  $if seen true hit
      $decl r   $call with_scope (e2, $call mprops.val (xs.tail), mid, nm, sn) }.r,
  $case xs e
)

$decl with_props $func ($decl e benv.node, $decl xs mprops.node, $decl mid 0) $match xs (
  $case {$prop tag "cons"}
    $call with_props ($call benv.cons ($call bind_ent5 (xs.head.name, "prop", 0, T.t_bot, mid), e),
        $call mprops.val (xs.tail), mid),
  $case xs e
)

// A function-valued prop lifts like any other `$func` (§7.3) — except that a
// prop has no position at which a capture could be evaluated, because it has
// no position at all. Worth its own message: without the check, a captured
// local would silently become a read of the *lifted* function's own frame.
$decl no_caps $func ($decl st proto_lst, $decl pe benv.node, $decl n Pa.proto_node)
  { $decl cs $call caps ($call free_names (n, strs.nil), pe, benv.nil)
    $decl r $match cs (
        $case {$prop tag "cons"}
          ($call err (st, $call concat ("a $prop's value may not capture '",
              $call concat (cs.head.name,
              "': a prop is compile-time (§4.10), so there is nowhere to evaluate the capture")), n)),
        $case cs 0
      ) }.r

// Recorded against whatever the module looks like *now*: lowering a prop's
// body can lower its siblings, so the entry read at the start is stale by the
// time the body is done.
$decl note_prop $func ($decl st proto_lst, $decl mid 0, $decl d proto_mdone)
  { $decl ms $call find_mod ($call eval_mods (st.mods), mid)
    $decl r $match ms (
        $case {$prop tag "cons"}
          ($call save_mod (st, $call mod_ent (mid, $call mprops.val (ms.head.props),
              $call mdones.cons (d, $call mdones.val (ms.head.done)),
              $call benv.val (ms.head.env), ms.head.base, ms.head.path))),
        $case ms 0
      ) }.r

$decl prop_global $func ($decl st proto_lst, $decl d proto_mdone)
  { $decl t $call T.tval (d.ty)
    // While the member's own body is being lowered its type is §5.5's
    // placeholder. That is the right *type* — it is what the knot is tied on —
    // but not a layout, so the node's type index is a harmless stand-in.
    $decl ti $if ($call T.has_var (t, 0)) ($call intern (st, T.t_unit)) ($call intern (st, t))
    $decl r $call lres4 ($call IR.e_global (ti, d.idx), t, d.mod, d.tmpl) }.r

$fwd lower_prop_new

// A prop's body lowered as a function of its own, with the enclosing frame put
// aside and restored (§7.2: a lifted function's frame is its own).
$decl lower_prop_body $func ($decl st proto_lst, $decl pe benv.node, $decl nm "",
                             $decl pn Pa.proto_node, $decl fty T.proto_ty)
  { $decl o $call take_slots (st)
    $decl f $call lower_func (st, pe, nm, pn, fty, IR.ints.nil)
    $decl b $call restore_slots (st, o)
    $decl r f }.r

$decl lower_prop_func $func ($decl st proto_lst, $decl m proto_mod, $decl nm "",
                             $decl pn Pa.proto_node, $decl n Pa.proto_node)
  { $decl pe    $call with_props ($call benv.val (m.env), $call mprops.val (m.props), m.id)
    $decl chk   $call no_caps (st, pe, pn)
    // The index is reserved before the body exists, because the body may name
    // this prop — §4.9 memoises before typing for exactly the same reason.
    $decl idx   $call reserve_lifted (st)
    $decl p0    $call note_prop (st, m.id, $call mdone (nm, "global", idx, T.t_bot, -1, -1))
    // A prop that names itself has to be lowered twice, and the reason is the
    // one place lowering feels the absence of §5.5's knot: it *derives* types,
    // so while the body is being lowered its own result is not known yet and a
    // call to it types as ⊥. The first pass is only for that result — `join`
    // absorbs ⊥, so the body's type comes out right even though one node in it
    // does not — and the second is lowered against it.
    //
    // A prop that does not name itself is lowered once. Checking is a scan of
    // the body's free names, which lifting needs anyway.
    $decl self  $call mem_str ($call free_names (pn, strs.nil), nm)
    $decl lf0   $call lower_prop_body (st, pe, nm, pn, T.t_bot)
    $decl fty   $call fn_ty (st, lf0)
    // Completed now that the body has given up its result type. The new entry
    // goes in front of the placeholder, which `find_mdone` therefore stops at.
    $decl p1    $call note_prop (st, m.id, $call mdone (nm, "global", idx, fty, -1, -1))
    $decl lf    $if self ($call lower_prop_body (st, pe, nm, pn, fty)) lf0
    $decl put   $call put_lifted (st, idx, lf)
    $decl r     $call lres ($call IR.e_global ($call intern (st, fty), idx), fty) }.r

// A prop that is not a function: a literal or a prop-only block (§1.1). It has
// no index of its own — it is lowered afresh wherever it is named, which is
// also what keeps §9.3's node indices distinct.
// §5.5 in full, and the one place lowering needs it. A recursive data type is
// *inferred*, never declared, and the way to write one is a `$prop` whose value
// names itself through storage — prelude's `node` is
// `$union (nil, {… $decl tail $new node})`. Inference solves that knot and
// lowering normally reads the answer off its result; inside a specialised
// template there is no answer to read, because §4.9 made this body new. So the
// rule is applied here: the name takes a placeholder `R`, the body derives as
// `B(R)`, and the result is `μR. B(R)` — or simply `B`, when `R` did not occur.
$decl lower_prop_value $func ($decl st proto_lst, $decl m proto_mod, $decl nm "",
                              $decl pn Pa.proto_node, $decl n Pa.proto_node)
  { $decl pe $call with_props ($call benv.val (m.env), $call mprops.val (m.props), m.id)
    $decl self $call mem_str ($call free_names (pn, strs.nil), nm)
    $decl pv $call fresh_var (st)
    $decl p0 $call note_prop (st, m.id, $call mdone (nm, "pend", pv, T.t_bot, -1, -1))
    $decl sn $call take_snap (st)
    $decl v0 $call lval ($call lower (st, pe, pn, false))
    $decl und $if self ($call put_snap (st, sn)) 0
    $decl ty $if ($call T.occurs (v0.ty, pv)) ($call T.close_var (v0.ty, pv)) ($call T.tval (v0.ty))
    $decl gd $if ($call T.unguarded_rec (ty))
        ($call err (st, $call concat (
            "this recursive prop has no layout: it recurs through a value, not storage. Write $new at the recursive position (§5.5). Derived ",
            $call T.show (ty)), n))
        0
    // Tied: the knot is closed, so a self-reference in the second pass gets
    // the real type rather than the placeholder. Lowering again is what puts
    // that type on the nodes *inside* the body, whose indices were handed out
    // while the placeholder stood.
    $decl p1 $call note_prop (st, m.id, $call mdone (nm, "tied", 0, ty, v0.mod, v0.tmpl))
    $decl v  $if self ($call lval ($call lower (st, pe, pn, false))) v0
    // Remembered as what it *is*: re-lowering would build a second module or
    // register the template twice, and then two mentions of one name would
    // name two different things.
    $decl p2 $call note_prop (st, m.id, $call mdone (nm, "value", 0, ty, v.mod, v.tmpl))
    $decl r  $call lres4 (v.ir, ty, v.mod, v.tmpl) }.r

// §4.9: a template has no runtime value at all, so it is registered once and
// remembered — registering it twice would make two templates of one, and every
// `$specialize` of the second would emit its own copy of everything.
$decl lower_prop_tmpl $func ($decl st proto_lst, $decl m proto_mod, $decl nm "",
                             $decl pn Pa.proto_node, $decl n Pa.proto_node)
  { $decl pe  $call with_props ($call benv.val (m.env), $call mprops.val (m.props), m.id)
    $decl gs  $call generic_names ($call op (pn, 0), strs.nil)
    $decl tid $call fresh_tmpl (st, gs, $call op (pn, 1), pe)
    $decl p1  $call note_prop (st, m.id, $call mdone (nm, "tmpl", 0, T.t_unit, -1, tid))
    $decl r   $call lres4 ($call IR.e_block ($call intern (st, T.t_unit), IR.bslots.nil),
                  T.t_unit, -1, tid) }.r

// §3.3 makes a file a block, so a module's members are `$decl`s — one cell
// each, initialised once in source order (§4.10), which is a thunk. That is
// the whole difference from a `$prop`, whose value is compile-time and is
// lowered afresh wherever it is named.
$decl tbody $func ($decl v proto_lres, $decl ss IR.ints.node) { $decl val v  $decl slots ss }

// A member's body lowered as a thunk body, with the enclosing frame put aside
// and restored — so it can be done twice and the second result used.
$decl thunk_body $func ($decl st proto_lst, $decl pe benv.node, $decl pn Pa.proto_node)
  { $decl o $call take_slots (st)
    $decl v $call lval ($call lower (st, pe, pn, true))
    $decl r $call tbody (v, $call take_slots (st))
    $decl b $call restore_slots (st, o)
    $decl z r }.z

$decl lower_prop_thunk $func ($decl st proto_lst, $decl m proto_mod, $decl nm "",
                              $decl pn Pa.proto_node, $decl n Pa.proto_node)
  { $decl pe   $call with_scope ($call benv.val (m.env), $call mprops.val (m.props), m.id, nm,
                   ($union (false, true)))
    $decl chk  $call no_caps (st, pe, pn)
    $decl idx  $call reserve_lifted (st)
    // §5.5 again, and for the same reason as a `$prop`: a module's members are
    // where recursive *data* is written — `types.mpl`'s `proto_ty` is a
    // top-level `$decl` whose `$union` names itself — and inside a module
    // lowering derives rather than reads, so the knot is tied here. The index
    // is reserved for a self *call*; the placeholder is for a self *type*.
    // A member that names itself is lowered **twice**, and it is the same
    // reason a self-naming `$prop` function is: lowering derives rather than
    // solves, so during the first pass the member's own type is §5.5's
    // placeholder — and not only its result. Every node inside that reached it
    // holds the placeholder too, and a node's type is an interned *index*, so
    // those cannot be revised afterwards. Closing the knot and lowering again
    // is what gives them the real type. The first pass exists only to find it.
    $decl self $call mem_str ($call free_names (pn, strs.nil), nm)
    $decl pv   $call fresh_var (st)
    $decl p0   $call note_prop (st, m.id, $call mdone (nm, "global", idx, $call T.t_var (pv), -1, -1))
    $decl sn   $call take_snap (st)
    $decl b0   $call thunk_body (st, pe, pn)
    $decl und  $if self ($call put_snap (st, sn)) 0
    $decl t    $if ($call T.occurs (b0.val.ty, pv)) ($call T.close_var (b0.val.ty, pv))
                   ($call T.tval (b0.val.ty))
    $decl gd   $if ($call T.unguarded_rec (t))
        ($call err (st, $call concat (
            "this recursive member has no layout: it recurs through a value, not storage. Write $new at the recursive position (§5.5). Derived ",
            $call T.show (t)), n))
        0
    $decl p1   $call note_prop (st, m.id, $call mdone (nm, "global", idx, t,
                   b0.val.mod, b0.val.tmpl))
    $decl bd   $if self ($call thunk_body (st, pe, pn)) b0
    $decl vty  $call intern (st, t)
    $decl f    $call IR.fn (nm, IR.ints.nil, vty, $call IR.ints.val (bd.slots), bd.val.ir,
                    false, true, IR.ints.nil)
    $decl put  $call put_lifted (st, idx, f)
    $decl r    $call lres4 ($call IR.e_global (vty, idx), t, bd.val.mod, bd.val.tmpl) }.r

$decl lower_prop_ast $func ($decl st proto_lst, $decl m proto_mod, $decl nm "",
                            $decl pn Pa.proto_node, $decl n Pa.proto_node, $decl kd "")
  $if ($call is_form (pn, "template")) ($call lower_prop_tmpl (st, m, nm, pn, n))
      ($if ($call is_form (pn, "func")) ($call lower_prop_func (st, m, nm, pn, n))
           ($if ($call eq_str (kd, "decl")) ($call lower_prop_thunk (st, m, nm, pn, n))
                ($call lower_prop_value (st, m, nm, pn, n))))

$decl lower_prop_new $func ($decl st proto_lst, $decl m proto_mod, $decl nm "",
                            $decl n Pa.proto_node)
  { $decl f $call find_mprop ($call mprops.val (m.props), nm)
    $decl r $match f (
        $case {$prop tag "cons"} ($call lower_prop_ast (st, m, nm, f.head.node, n, f.head.kind)),
        $case f ($call lres ($call IR.e_unit ($call err (st, $call concat ("no field '",
            $call concat (nm, "'")), n)), T.t_bot))
      ) }.r

// A prop whose value is compile-time only — a template, or a module with no
// layout. There is nothing to rebuild but the node itself (§9.3 gives each its
// own index), and rebuilding the *identity* would be wrong.
$decl prop_const $func ($decl st proto_lst, $decl d proto_mdone)
  { $decl t $call T.tval (d.ty)
    $decl r $call lres4 ($call IR.e_block ($call intern (st, t), IR.bslots.nil), t,
                 d.mod, d.tmpl) }.r

$decl lower_prop_in $func ($decl st proto_lst, $decl m proto_mod, $decl nm "",
                           $decl n Pa.proto_node)
  { $decl d $call find_mdone ($call mdones.val (m.done), nm)
    $decl r $match d (
        $case {$prop tag "cons"}
          ($if ($call eq_str (d.head.kind, "global")) ($call prop_global (st, d.head))
          ($if ($call eq_str (d.head.kind, "tmpl"))   ($call prop_const (st, d.head))
          ($if ($call eq_str (d.head.kind, "tied"))   ($call prop_const (st, d.head))
          ($if ($call eq_str (d.head.kind, "value"))
               ($if ($call has_fields (d.head.ty)) ($call lower_prop_new (st, m, nm, n))
                    ($call prop_const (st, d.head)))
               // §5.5: the name stands for `R` while its own body is derived,
               // and the binder is discharged when that finishes. The tree is
               // a placeholder too — a prop can only reach itself from a
               // type-only position (§5.7), which is never evaluated.
               // The *type* is the placeholder, because that is what §5.5's
               // knot is tied on; the node's own type index is not, because
               // the node is discarded and a placeholder is not a layout.
               ($call lres ($call IR.e_unit ($call intern (st, T.t_unit)),
                   $call T.t_var (d.head.idx))))))),
        $case d ($call lower_prop_new (st, m, nm, n))
      ) }.r

$decl lower_prop $func ($decl st proto_lst, $decl mid 0, $decl nm "", $decl n Pa.proto_node)
  { $decl ms $call find_mod ($call eval_mods (st.mods), mid)
    $decl r $match ms (
        $case {$prop tag "cons"} ($call lower_prop_in (st, ms.head, nm, n)),
        $case ms ($call lres ($call IR.e_unit ($call err (st,
            "this block's props were not lowered in this file", n)), T.t_bot))
      ) }.r

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
            $call benv.cons ($call bind_ent6 (nm, "local", sl, v.ty, v.mod, v.tmpl),
                $call benv.val (a.env)),
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

// The `$prop` items, kept as source. §4.10 makes a prop's value compile-time,
// so it is code the compiler still has rather than anything in the layout —
// and it is the only way to answer a projection onto a prop that is not a
// scalar, since the type keeps only `cv_opaque` for those.
$decl block_props $func ($decl xs Pa.nodes.node, $decl acc mprops.node) $match xs (
  $case {$prop tag "cons"}
    $call block_props ($call Pa.nodes.val (xs.tail),
        $if ($call is_form (xs.head, "prop"))
            ($call mprops.cons ($call mprop ($call name_of ($call op (xs.head, 0)),
                 $call op (xs.head, 1), "prop"), acc))
            acc),
  $case xs ($call mprops.reverse (acc, mprops.nil))
)

// §4.5: "a block is scope, record, module, namespace and (props-only) trait at
// once". Both halves are built here — the layout, and, when there are props,
// the module a projection onto one is answered from. The environment recorded
// is the block's own, so a prop's body sees its siblings (§4.10 makes a prop
// visible throughout its block regardless of order).
$decl lower_block $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node)
  { $decl a  $call lower_items (st, $call blk_acc (IR.bslots.nil, T.fields.nil, T.props.nil,
                                                   e, IR.exprs.nil), xs)
    $decl ty $call T.t_block ($call T.fields.reverse ($call T.fields.val (a.flds), T.fields.nil),
                              $call T.props.val (a.prps))
    $decl id $call intern (st, ty)
    $decl ir $call with_pending ($call IR.exprs.val (a.pend),
        $call IR.e_block (id, $call IR.bslots.reverse ($call IR.bslots.val (a.slots), IR.bslots.nil)), id)
    $decl ps $call block_props (xs, mprops.nil)
    $decl md $if ($call mprops.is_nil (ps)) -1
                 ($call fresh_mod (st, ps, $call benv.val (a.env)))
    $decl r  $call lres3 (ir, ty, md) }.r

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
// A lowered top-level `$decl`: the function it became, and — when its value
// was compile-time — the module or template it is.
$decl topfn $func ($decl f IR.proto_fn, $decl m 0, $decl tm 0)
  { $decl fn f  $decl mod m  $decl tmpl tm }

$decl lower_top $func ($decl st proto_lst, $decl e benv.node, $decl items Pa.nodes.node,
                       $decl fts T.fields.node, $decl acc IR.fns.node) $match fts (
  $case {$prop tag "cons"}
    { $decl nm   fts.head.name
      $decl fty  fts.head.ty
      $decl it   $call find_completing (items, nm)
      $decl init $call op (it, 1)
      $decl fm   $if ($call is_form (init, "func"))
          ($call topfn ($call lower_func (st, e, nm, init, fty, IR.ints.nil), -1, -1))
          // A thunk: no parameters, the value as its body (§7.2's frame is
          // whatever slots the initializer needed).
          { $decl reset $call take_slots (st)
            $decl v     $call lval ($call lower (st, e, init, true))
            $decl vty   $call intern (st, v.ty)
            $decl t     $call topfn ($call IR.fn (nm, IR.ints.nil, vty, $call take_slots (st),
                                v.ir, false, true, IR.ints.nil), v.mod, v.tmpl) }.t
      $decl f    fm.fn
      $decl idx  $call IR.fns.length (acc, 0)
      // A top-level `$decl` whose value is a block with props is a module, and
      // one whose value is a `$template` is a template — neither of which the
      // environment built up front could know, because the initializer had not
      // been lowered yet. The binding is re-bound in front of the original, so
      // every *later* item sees it (§4.10, source order), and an earlier
      // forward reference still sees the plain global.
      $decl e2   $if ($call and ($call lt (fm.mod, 0), $call lt (fm.tmpl, 0))) e
                     ($call benv.cons ($call bind_ent6 (nm, "global", idx, fty,
                          fm.mod, fm.tmpl), e))
      $decl r    $call lower_top (st, e2, items, $call T.fields.val (fts.tail),
                     $call IR.fns.cons (f, acc)) }.r,
  $case fts ($call fns_acc ($call IR.fns.reverse (acc, IR.fns.nil), 0))
)

// §6a's cheap case needs to know whether a function tail-calls *itself*, and
// that is only answerable once its final index is known — which is after the
// lifted functions have been appended, not while each is being built. Doing it
// here covers a lifted function too: an anonymous `$func` cannot name itself,
// but a `$prop` can, so one that recurses would otherwise be emitted as a real
// call and §7.7 would not hold.
//
// The body is not rebuilt, only re-pointed at, so no node gains a second
// index (§9.3).
$decl mark_self $func ($decl xs IR.fns.node, $decl i 0, $decl acc IR.fns.node) $match xs (
  $case {$prop tag "cons"}
    $call mark_self ($call IR.fns.val (xs.tail), $call add (i, 1),
        $call IR.fns.cons ($call IR.fn (xs.head.name, xs.head.params, xs.head.result,
            xs.head.slots, $call IR.eval (xs.head.body),
            $call self_tails ($call IR.eval (xs.head.body), i), xs.head.thunk, xs.head.env),
            acc)),
  $case xs ($call IR.fns.reverse (acc, IR.fns.nil))
)

// `fty` is what `check_file` returned for this file (§3.3). Only `$decl` items
// are lowered; a top-level `$prop` or a bare expression is out of the subset
// for a program's top level and reported rather than guessed at.
$decl lower_file $func ($decl st proto_lst, $decl items Pa.nodes.node, $decl fty T.proto_ty,
                        $decl prims benv.node, $decl base "")
  { $decl flds $match fty ($case {$prop tag "block"} ($call T.fields.val (fty.fields)), $case fty T.fields.nil)
    $decl env  $call globals_from (flds, 0, prims)
    // §4.14: an import resolves relative to the entry file, and a module is
    // lowered against the root block alone — so both are recorded before any
    // item is lowered.
    $decl based $set st.base base
    $decl rooted $set st.rootenv prims
    // A global's index is its position among the top-level `$decl`s, so the
    // lifted functions take the indices after them.
    $decl fnbased $set st.fnbase ($call T.fields.length (flds, 0))
    $decl done $call lower_top (st, env, items, flds, IR.fns.nil)
    $decl all0 $call append_fns ($call IR.fns.val (done.funcs),
                   $call IR.fns.reverse ($call IR.fns.val (st.lifted), IR.fns.nil))
    $decl all  $call mark_self (all0, 0, IR.fns.nil)
    $decl es   $call collect_edges (all, 0, edges.nil)
    $decl gs   $call find_groups (es, 0, $call IR.fns.length (all, 0), IR.groups.nil)
    $decl out  $call IR.program ($call T.tys.val ($call eval_tys (st.types)), all, gs, 0) }.out
