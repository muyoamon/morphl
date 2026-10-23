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

$decl mem_strs $func ($decl xs strs.node, $decl s "") $match xs (
  $case {$prop tag "cons"} $if ($call eq_str (xs.head, s)) true ($call mem_strs (xs.tail, s)),
  $case xs false
)

$decl mem_str $func ($decl xs strs.node, $decl x "") $match xs (
  $case {$prop tag "cons"} $if ($call eq_str (xs.head, x)) true ($call mem_str (xs.tail, x)),
  $case xs false
)

// ------------------------------------------------------------- environment
//
// A name resolves to a frame slot, a closure capture, a top-level function, or
// a root-block intrinsic (§2.1: an intrinsic is an ordinary shadowable name, so
// this is a lookup, not a special case).

// A binding, as `lookup` answers it.
$decl pbind $func ($decl n "", $decl k "", $decl s 0, $decl t T.proto_ty,
                   $decl m 0, $decl tm 0) {
  $decl name n  $decl kind k  $decl slot s  $decl ty t
  // The module this name's value is, if it is one — see the compile-time
  // environment below. -1 for everything that is not a block with props.
  $decl mod m
  // The template it is, likewise. §4.9 makes a template compile-time and
  // `$specialize` its only consumer, so this is how that consumer finds the
  // body: the type says *that* a name is a template, this says which one
  // lowering registered.
  $decl tmpl tm
}
$decl proto_pbind $call pbind ("", "", 0, T.t_bot, 0, 0)
$decl pbinds      $specialize P.list proto_pbind

// **An environment index.** `lookup` scanned the environment from the front, and a
// module's environment is its members — hundreds — consed onto the root block's
// intrinsics, so every reference to `add` or `concat` walked past every member: 19.5% of
// a self-emit. Environments stay lists, because they are extended one binding at a time
// and shadowing is "the first match"; but a long-lived one gets an *index entry* on top
// (`with_index`), whose trie answers for everything below it. A lookup that reaches one
// stops there. The trie keeps each bucket newest first, so its first match is the list's.
$decl ptrie $union (
  { $prop tag "leaf"   $decl items $alloc pbinds.node },
  { $prop tag "branch" $decl lo $alloc ptrie  $decl hi $alloc ptrie }
)
$decl pt_leaf $func ($decl xs pbinds.node) { $prop tag "leaf" $decl items $alloc xs }
$decl pt_branch $func ($decl l ptrie, $decl h ptrie) {
  $prop tag "branch" $decl lo $alloc l  $decl hi $alloc h
}
$decl pt_val   $func ($decl x ptrie) x
$decl pt_items $func ($decl tr ptrie)
    $match tr ($case {$prop tag "leaf"} ($call pbinds.val (tr.items)), $case tr pbinds.nil)
// One empty leaf for every absent child. A leaf boxes its list, and the list node holds
// a binding inline, so a fresh empty one is 152 bytes — and building a path asked for two
// at each of `pt_depth` levels, which made this trie 102 MB of a self-emit (PERF.md). The
// trie is persistent, so the empty leaf is never written and one serves them all.
$decl pt_empty $call pt_leaf (pbinds.nil)
$decl pt_kid $func ($decl tr ptrie, $decl hi P.boolean) $match tr (
  $case {$prop tag "branch"} ($call pt_val ($if hi tr.hi tr.lo)),
  $case tr pt_empty
)
$decl pt_depth 10
$decl pt_key   $func ($decl nm "") $call mod ($call add ($call mod ($call T.hash_str (nm, 0, 0),
    1021), 1021), 1021)
$decl pt_add $func ($decl tr ptrie, $decl k 0, $decl d 0, $decl b proto_pbind)
  $if ($call not ($call lt (d, pt_depth))) ($call pt_leaf ($call pbinds.cons (b,
      $call pt_items (tr)))) {
    $decl lo $call pt_kid (tr, false)
    $decl hi $call pt_kid (tr, true)
    $decl up $call eq_int ($call mod (k, 2), 0)
    $decl ret  $if up ($call pt_branch ($call pt_add (lo, $call div (k, 2), $call add (d, 1), b),
        hi))
                    ($call pt_branch (lo, $call pt_add (hi, $call div (k, 2), $call add (d, 1), b)))
  }.ret
// The slot an index entry carries, and the name: a slot no binding has, so telling one
// apart is an integer test, and a name no identifier can be (§2: none starts with `$`),
// since `lower_name` looks up "" for a node that is not a name.
$decl ix_slot -7

$decl bind_ent7 $func ($decl n "", $decl k "", $decl s 0, $decl t T.proto_ty,
                       $decl m 0, $decl tm 0, $decl x ptrie) {
  $decl name n  $decl kind k  $decl slot s  $decl ty t  $decl mod m  $decl tmpl tm
  $decl ix   $alloc x
}

$decl bind_ent6 $func ($decl n "", $decl k "", $decl s 0, $decl t T.proto_ty,
                       $decl m 0, $decl tm 0)
  $call bind_ent7 (n, k, s, t, m, tm, pt_empty)

$decl bind_ent5 $func ($decl n "", $decl k "", $decl s 0, $decl t T.proto_ty, $decl m 0)
  $call bind_ent6 (n, k, s, t, m, -1)

// The four-argument form every ordinary binding uses: nothing but a block with
// props is a module and nothing but a `$template` is a template, so -1 twice
// is the answer almost everywhere.
$decl bind_ent $func ($decl n "", $decl k "", $decl s 0, $decl t T.proto_ty)
  $call bind_ent6 (n, k, s, t, -1, -1)

$decl proto_bind $call bind_ent6 ("", "", 0, T.t_bot, 0, 0)
$decl benv       $specialize P.list proto_bind

$decl found $func ($decl ok P.boolean, $decl b proto_pbind) { $decl hit ok  $decl bnd b }

$decl pt_scan $func ($decl xs pbinds.node, $decl n "") $match xs (
  $case {$prop tag "cons"} $if ($call eq_str (xs.head.name, n)) ($call found (true,
      xs.head)) ($call pt_scan ($call pbinds.val (xs.tail), n)),
  $case xs ($call found (false, proto_pbind))
)
$decl pt_find $func ($decl tr ptrie, $decl k 0, $decl n "") $match tr (
  $case {$prop tag "branch"}
    $if ($call eq_int ($call mod (k, 2), 0)) ($call pt_find ($call pt_val (tr.lo), $call div (k, 2),
        n))
        ($call pt_find ($call pt_val (tr.hi), $call div (k, 2), n)),
  $case tr ($call pt_scan ($call pt_items (tr), n))
)

$decl as_pbind $func ($decl b proto_bind)
  $call pbind (b.name, b.kind, b.slot, b.ty, b.mod, b.tmpl)

$decl lookup $func ($decl e benv.node, $decl n "") $match e (
  $case {$prop tag "cons"}
    $if ($call eq_int (e.head.slot, ix_slot))
        ($call pt_find ($call pt_val (e.head.ix), $call pt_key (n), n))
        ($if ($call eq_str (e.head.name, n)) ($call found (true,
            $call as_pbind (e.head))) ($call lookup (e.tail, n))),
  $case e ($call found (false, proto_pbind))
)

// Everything in `e` from its head down to the first index entry, which is where `with_index`
// can stop: that entry already answers for the rest.
$decl ix_segment $func ($decl e benv.node, $decl acc pbinds.node) $match e (
  $case {$prop tag "cons"}
    $if ($call eq_int (e.head.slot, ix_slot)) acc
        ($call ix_segment (e.tail, $call pbinds.cons ($call as_pbind (e.head), acc))),
  $case e acc
)
$decl ix_base $func ($decl e benv.node) $match e (
  $case {$prop tag "cons"}
    $if ($call eq_int (e.head.slot, ix_slot)) ($call pt_val (e.head.ix)) ($call ix_base (e.tail)),
  $case e pt_empty
)
// `ix_segment` hands the segment back oldest first, so consing each onto its bucket leaves
// the newest at the front — the binding the list would have found.
$decl ix_fill $func ($decl tr ptrie, $decl xs pbinds.node) $match xs (
  $case {$prop tag "cons"} $call ix_fill ($call pt_add (tr, $call pt_key (xs.head.name), 0,
      xs.head), $call pbinds.val (xs.tail)),
  $case xs tr
)
$decl with_index $func ($decl e benv.node)
  $call benv.cons ($call bind_ent7 ("$index", "index", ix_slot, T.t_bot, -1, -1,
                       $call ix_fill ($call ix_base (e), $call ix_segment (e, pbinds.nil))), e)

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
$decl mprops      $specialize P.list proto_mprop

// A prop already lowered. `kind` is "global" for a function — lifted once, and
// every projection onto it is a fresh reference to the same index — or "pend"
// while its body is being lowered, which is what makes a prop that calls
// itself terminate (§4.9 memoises "before the body is typed" for the same
// reason).
$decl mdone $func ($decl nm "", $decl k "", $decl i 0, $decl t T.proto_ty,
                   $decl md 0, $decl tm 0) {
  $decl name nm  $decl kind k  $decl idx i  $decl ty t
  // What the value *is*, compile-time — a module of its own, or a template.
  // `$decl P $import "prelude"` inside a module is both a global and a
  // namespace, and the namespace is the half that matters.
  $decl mod md  $decl tmpl tm
}
$decl proto_mdone $call mdone ("", "", 0, T.t_bot, 0, 0)
$decl mdones      $specialize P.list proto_mdone

// `base` is the directory this module's own `$import`s resolve from, and
// `path` the resolved file it was loaded from — empty for a block written in
// place. §4.14 makes the path the identity: "all imports of the same resolved
// file yield the same module".
// `file` is the source module whose text produced this one, which is the output its
// members are emitted in. For a real `$import` it is the module itself; for a
// `$specialize` it is where the **template** is written; for a props-bearing block
// literal it is the file the literal sits in. `path` is the naming identity and may
// be none of those — see `IR.fn`'s `mod` against `nmod`.
// The module's record once built (§4.14, see `mod_value`): its type, that type's
// interned index, and each `$decl` member's type index in layout order. Kept on the
// entry rather than beside it because §5.5's `put_snap` restores the module list and
// the type table together — so an index here can never outlive the table entry it
// names, which is the hazard every other cached index in this file ran into.
$decl mrec $func ($decl ok P.boolean, $decl t T.proto_ty, $decl i 0, $decl fs IR.ints.node)
  { $decl has ok  $decl ty t  $decl id i  $decl fids fs }
$decl no_mrec  $call mrec (false, T.t_unit, 0, IR.ints.nil)
$decl mrec_val $func ($decl r no_mrec) r

// `isctx` is the specialisation context the module's code was written in, in
// inference's spelling (see `opaque_at`): empty for a file, which §4.14 types at its
// own top level, and the enclosing `$specialize`'s key for a block literal in a
// template body — whose prop bodies inference typed inside that specialisation, and
// which lowering only reaches later, from wherever the first projection happens.
// `done` by name. `find_mdone` scanned the list — 13% of a self-emit, since every
// projection onto a module member asks it — so the entry carries a trie keyed by the
// name's hash as well. On the entry rather than beside it, so a rollback restores the two
// together. A bucket is newest first like the list, so the first match is the same one.
$decl dxtrie $union (
  { $prop tag "leaf"   $decl items $alloc mdones.node },
  { $prop tag "branch" $decl lo $alloc dxtrie  $decl hi $alloc dxtrie }
)
$decl dx_leaf $func ($decl xs mdones.node) { $prop tag "leaf" $decl items $alloc xs }
$decl dx_branch $func ($decl l dxtrie, $decl h dxtrie) {
  $prop tag "branch" $decl lo $alloc l  $decl hi $alloc h
}
$decl dx_val   $func ($decl x dxtrie) x
$decl dx_items $func ($decl tr dxtrie)
    $match tr ($case {$prop tag "leaf"} ($call mdones.val (tr.items)), $case tr mdones.nil)
// The one empty leaf every absent child shares: the trie is persistent, so it is
// never written, and a fresh one per child was an allocation per level (PERF.md).
$decl dx_nil $call dx_leaf (mdones.nil)
$decl dx_kid $func ($decl tr dxtrie, $decl hi P.boolean) $match tr (
  $case {$prop tag "branch"} ($call dx_val ($if hi tr.hi tr.lo)),
  $case tr dx_nil
)
$decl dx_depth 10
$decl dx_key   $func ($decl nm "") $call mod ($call add ($call mod ($call T.hash_str (nm, 0, 0),
    1021), 1021), 1021)
$decl dx_scan $func ($decl xs mdones.node, $decl nm "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, nm)) xs
        ($call dx_scan ($call mdones.val (xs.tail), nm)),
  $case xs mdones.nil
)
$decl dx_find $func ($decl tr dxtrie, $decl k 0, $decl nm "") $match tr (
  $case {$prop tag "branch"}
    $if ($call eq_int ($call mod (k, 2), 0)) ($call dx_find ($call dx_val (tr.lo), $call div (k, 2),
        nm))
        ($call dx_find ($call dx_val (tr.hi), $call div (k, 2), nm)),
  $case tr ($call dx_scan ($call dx_items (tr), nm))
)
$decl dx_add $func ($decl tr dxtrie, $decl k 0, $decl d 0, $decl m proto_mdone)
  $if ($call not ($call lt (d, dx_depth))) ($call dx_leaf ($call mdones.cons (m,
      $call dx_items (tr)))) {
    $decl lo $call dx_kid (tr, false)
    $decl hi $call dx_kid (tr, true)
    $decl up $call eq_int ($call mod (k, 2), 0)
    $decl ret  $if up ($call dx_branch ($call dx_add (lo, $call div (k, 2), $call add (d, 1), m),
        hi))
                    ($call dx_branch (lo, $call dx_add (hi, $call div (k, 2), $call add (d, 1), m)))
  }.ret
$decl dx_empty $call dx_leaf (mdones.nil)

$decl mod_ent_g $func ($decl i 0, $decl ps mprops.node, $decl ds mdones.node,
                       $decl en benv.node, $decl bs "", $decl pt "", $decl pe benv.node,
                       $decl fl "", $decl rc no_mrec, $decl ic "", $decl dx dxtrie) {
  $decl id   i  $decl props $alloc ps  $decl done $alloc ds  $decl env $alloc en
  $decl base bs  $decl path pt  $decl file fl  $decl isctx ic
  // `with_props (en, ps, i)`, built once at registration. See `with_props`.
  $decl penv $alloc pe
  $decl rec  $alloc rc
  $decl dix  $alloc dx
}


$decl mod_ent_f $func ($decl i 0, $decl ps mprops.node, $decl ds mdones.node,
                       $decl en benv.node, $decl bs "", $decl pt "", $decl pe benv.node,
                       $decl fl "")
  $call mod_ent_g (i, ps, ds, en, bs, pt, pe, fl, no_mrec, "", dx_empty)

$decl mod_ent $func ($decl i 0, $decl ps mprops.node, $decl ds mdones.node,
                     $decl en benv.node, $decl bs "", $decl pt "", $decl pe benv.node)
  $call mod_ent_f (i, ps, ds, en, bs, pt, pe, "")
$decl proto_mod $call mod_ent (0, mprops.nil, mdones.nil, benv.nil, "", "", benv.nil)

// A module's lowered member by name: `find_mdone`'s answer, the list from that entry on.
$decl find_mdone_m $func ($decl m proto_mod, $decl nm "")
  $call dx_find ($call dx_val (m.dix), $call dx_key (nm), nm)
$decl mods_list $specialize P.list proto_mod

// Every member of a module bound at once, which is what a `$prop` body and a
// `$func` member's body both resolve against (§4.10).
//
// Declared up here because it is computed **once per module**, in
// `fresh_mod_at`, and kept on the entry as `penv`. Its five callers all passed
// the same three things — `(m.env, m.props, m.id)` — so the answer never
// differed between them, and `note_prop` only ever rewrites the `done` list, so
// it never goes stale. Rebuilding it per prop lowered, and again on every
// `replay_union` (which is every `xs.node` in the program), measured **41.08 MB
// across 5,140 calls** on the front end: 8.2% of the run, and all but one call
// per module of it redundant.
$decl with_props $func ($decl e benv.node, $decl xs mprops.node, $decl mid 0) $match xs (
  $case {$prop tag "cons"}
    $call with_props ($if ($call eq_str (xs.head.kind, "effect")) e
                         ($call benv.cons ($call bind_ent5 (xs.head.name, "prop", 0, T.t_bot, mid), e)),
        $call mprops.val (xs.tail), mid),
  $case xs e
)

// §4.9's other half. A template is compile-time and has no runtime value at
// all, so what lowering keeps is the same three things a module keeps: the
// generic names, the body, and the environment it was written in.
// `key` is the template's **stable** identity — the module it was written in and its
// member name, e.g. `prelude_list`. `id` is a counter, so it is handed out in load
// order and cannot name anything: two programs that import the same template in a
// different order give it different ids. The key is what a specialisation is named
// from, and §4.14 plus §4.1 are what make it unique — one binding per name in the
// block that is the module's file.
// `file` is where the template is **written**, which is where its specialisations are
// emitted: §4.9 makes an instantiation the template's code, so putting it in whichever
// module happened to reach it first would make that file's text depend on the program.
// `iid` is the id *inference* gave the same template (`infer.mpl`'s `ct_id`, tag 7),
// which is the head of its memo key and so of every identity minted in a
// specialisation's body — see `opaque_at` and `spec_build`.
// `ctg` is §4.9's compile-time generics, the same set inference computes, found on
// first use (`tmpl_ctg`) — `ctok` says it has been, and an entry being computed is
// `ctok` with an empty set, which errs permissive for a template reaching itself
// through another. `vk` is the value part of one specialisation's memo key: a copy of
// the record made per `$specialize` carries it, with the literals substituted into
// `body`, so the build paths read both off `r` like everything else.
$decl tmpl_rec_x $func ($decl i 0, $decl gs strs.node, $decl bd Pa.proto_node,
                        $decl en benv.node, $decl ky "", $decl fl "", $decl ii 0,
                        $decl cg Pa.ctgs.node, $decl ck P.boolean, $decl v "") {
  $decl id   i  $decl generics gs  $decl body bd  $decl env en  $decl key ky
  $decl file fl  $decl iid ii  $decl ctg cg  $decl ctok ck  $decl vk v
}
$decl tmpl_rec_k $func ($decl i 0, $decl gs strs.node, $decl bd Pa.proto_node,
                        $decl en benv.node, $decl ky "", $decl fl "", $decl ii 0)
  $call tmpl_rec_x (i, gs, bd, en, ky, fl, ii, Pa.ctgs.nil, false, "")
$decl tmpl_rec $func ($decl i 0, $decl gs strs.node, $decl bd Pa.proto_node, $decl en benv.node)
  $call tmpl_rec_k (i, gs, bd, en, "", "", 0)
$decl proto_tmpl $call tmpl_rec (0, strs.nil, Pa.proto_node, benv.nil)
$decl tmpls_list $specialize P.list proto_tmpl

// §4.9: "Typing is memoized per **argument type**." Lowering memoises the same
// way and for a stronger reason — two uses of one specialisation must share
// its lifted functions, or every `$specialize P.list Int` in a program would
// emit its own `cons`. The key is the interned index of each argument's type,
// which is exact: interning is by `T.same`, and de Bruijn binders make
// alpha-equivalent types identical (§5.5).
$decl spec_ent_v $func ($decl t 0, $decl ks IR.ints.node, $decl m 0, $decl bt T.proto_ty,
    $decl v "")
  { $decl tmpl t  $decl keys ks  $decl mod m  $decl bty bt  $decl vk v }
$decl spec_ent $func ($decl t 0, $decl ks IR.ints.node, $decl m 0, $decl bt T.proto_ty)
  $call spec_ent_v (t, ks, m, bt, "")
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

// The finders below answer the list **from the entry on**, or nil — never a fresh
// one-element list. Every caller reads only `.head` and tests for `cons`, so the suffix
// is the same answer without an allocation; building the one-element list made
// `dx_scan` alone 415k cons cells of a self-emit (PERF.md).
$decl find_tmpl $func ($decl xs tmpls_list.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_int (xs.head.id, i)) xs
        ($call find_tmpl (xs.tail, i)),
  $case xs tmpls_list.nil
)

$decl find_spec $func ($decl xs specs_list.node, $decl i 0, $decl ks IR.ints.node,
    $decl v "") $match xs (
  $case {$prop tag "cons"}
    $if ($call and ($call and ($call eq_int (xs.head.tmpl, i), $call eq_str (xs.head.vk, v)),
                    $call same_keys ($call IR.ints.val (xs.head.keys), ks)))
        xs
        ($call find_spec (xs.tail, i, ks, v)),
  $case xs specs_list.nil
)

$decl find_mod_path $func ($decl xs mods_list.node, $decl p "") $match xs (
  $case {$prop tag "cons"}
    $if ($call and ($call not ($call eq_str (p, "")), $call eq_str (xs.head.path, p)))
        xs
        ($call find_mod_path (xs.tail, p)),
  $case xs mods_list.nil
)

$decl find_mprop $func ($decl xs mprops.node, $decl n "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, n)) xs
        ($call find_mprop (xs.tail, n)),
  $case xs mprops.nil
)

$decl find_mdone $func ($decl xs mdones.node, $decl n "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, n)) xs
        ($call find_mdone (xs.tail, n)),
  $case xs mdones.nil
)

// ------------------------------------------------------------------ state
//
// The interned type table, the frame counter for the function being lowered,
// and the diagnostics. Storage is widened to what gets written into it (§4.2:
// `$new` takes the type of its operand, so `$new xs.nil` would be storage only
// the empty list fits).

$decl mrank       $func ($decl m "", $decl n 0) { $decl mod m  $decl next n }
$decl proto_mrank $call mrank ("", 0)
$decl mranks_list $specialize P.list proto_mrank

// §4.10: a function-valued prop's identity — the `cv_opaque` id its block's *type*
// carries — and the module whose source holds it. See `prop_by_id`.
$decl opq_ent   $func ($decl i 0, $decl m 0, $decl nm "") { $decl id i  $decl mod m  $decl name nm }
$decl proto_opq $call opq_ent (0, 0, "")
$decl opq_list  $specialize P.list proto_opq

// The module list by id. `find_mod` used to scan `st.mods` comparing ids — 7.4% of a
// self-emit once types compared in O(1) — so the entries are indexed by a trie on the id's
// bits, which holds the *current* version of each. The list beside it holds each module
// as registered and answers only `find_mod_path`, by fields that never change; both are
// restored together by `put_snap`. A leaf holds the one entry for its id.
$decl mxtrie $union (
  { $prop tag "leaf"   $decl items $alloc mods_list.node },
  { $prop tag "branch" $decl lo $alloc mxtrie  $decl hi $alloc mxtrie }
)
$decl mx_leaf $func ($decl xs mods_list.node) { $prop tag "leaf" $decl items $alloc xs }
$decl mx_branch $func ($decl l mxtrie, $decl h mxtrie) {
  $prop tag "branch" $decl lo $alloc l  $decl hi $alloc h
}
$decl mx_val   $func ($decl x mxtrie) x
$decl mx_items $func ($decl tr mxtrie)
    $match tr ($case {$prop tag "leaf"} ($call mods_list.val (tr.items)), $case tr mods_list.nil)
// The one empty leaf every absent child shares: the trie is persistent, so it is
// never written, and a fresh one per child was an allocation per level (PERF.md).
$decl mx_nil $call mx_leaf (mods_list.nil)
$decl mx_kid $func ($decl tr mxtrie, $decl hi P.boolean) $match tr (
  $case {$prop tag "branch"} ($call mx_val ($if hi tr.hi tr.lo)),
  $case tr mx_nil
)
// Sixteen levels: 65,536 modules, against a dozen in the compiler.
$decl mx_depth 16
$decl mx_find $func ($decl tr mxtrie, $decl k 0, $decl d 0) $match tr (
  $case {$prop tag "branch"}
    $if ($call eq_int ($call mod (k, 2), 0)) ($call mx_find ($call mx_val (tr.lo), $call div (k, 2),
        $call add (d, 1)))
        ($call mx_find ($call mx_val (tr.hi), $call div (k, 2), $call add (d, 1))),
  $case tr ($call mx_items (tr))
)
$decl mx_put $func ($decl tr mxtrie, $decl k 0, $decl d 0, $decl m proto_mod)
  $if ($call not ($call lt (d, mx_depth))) ($call mx_leaf ($call mods_list.cons (m,
      mods_list.nil))) {
    $decl lo $call mx_kid (tr, false)
    $decl hi $call mx_kid (tr, true)
    $decl up $call eq_int ($call mod (k, 2), 0)
    $decl ret  $if up ($call mx_branch ($call mx_put (lo, $call div (k, 2), $call add (d, 1), m),
        hi))
                    ($call mx_branch (lo, $call mx_put (hi, $call div (k, 2), $call add (d, 1), m)))
  }.ret

// A read of a function-valued prop whose source had not been lowered yet when the read
// was, kept until the end of the file. See `prop_pending`.
$decl pend_ent $func ($decl i 0, $decl nm "", $decl k 0, $decl t T.proto_ty, $decl n Pa.proto_node)
  { $decl id i  $decl name nm  $decl idx k  $decl ty t  $decl node n }
$decl proto_pend $call pend_ent (0, "", 0, T.t_bot, Pa.proto_node)
$decl pend_list  $specialize P.list proto_pend

// §4.15a: a `$defer` registered and not yet run — its expression and the environment where
// it stands, so it is lowered against the names it was written among however many blocks
// nest between it and an exit. Newest first, for the current function only: `lower_func`
// starts each body with none, since `$try` returns from the nearest `$func`.
//
// `key` is empty for a block's own `$defer`, and the position of a `$new` literal for one
// of its storage's (DEFER.md step 3): those belong to the storage's owner, not the block.
// `flag` is the frame slot saying whether that literal ran, or -1 when it always does: one
// in an `$if` or `$match` arm may not have (example 10), and its deferrals run only if so.
$decl dfr_ent   $func ($decl n Pa.proto_node, $decl e benv.node, $decl k "", $decl f -1)
  { $decl node n  $decl env $alloc e  $decl key k  $decl flag f }
$decl proto_dfr $call dfr_ent (Pa.proto_node, benv.nil, "")
$decl dfr_list  $specialize P.list proto_dfr

// §3.4's defaults, which a short call needs. A known function's definition context —
// its parameters' source and the scope they are evaluated in — and the wrappers built
// from it. See `short_callee`.
$decl fdef_ent $func ($decl i 0, $decl ps Pa.nodes.node, $decl en benv.node,
                      $decl md "", $decl fl "", $decl ic "", $decl nm "") {
  $decl idx   i  $decl params $alloc ps  $decl env $alloc en  $decl mod md  $decl file fl
  $decl isctx ic
  $decl name  nm
}
$decl proto_fdef $call fdef_ent (0, Pa.nodes.nil, benv.nil, "", "", "", "")
$decl fdef_list  $specialize P.list proto_fdef

// A wrapper `w` for calls to `g` that supply `k` arguments; `ty` and `node` are kept
// while it is pending, for building it and for reporting.
$decl wrap_ent $func ($decl g 0, $decl k 0, $decl w 0, $decl t T.proto_ty, $decl n Pa.proto_node)
  { $decl fn g  $decl nargs k  $decl idx w  $decl ty t  $decl node n }
$decl proto_wrap $call wrap_ent (0, 0, 0, T.t_bot, Pa.proto_node)
$decl wrap_list  $specialize P.list proto_wrap

// §4.9: "Two specializations whose arguments have the same types … share the same
// code." A `$func` literal inside a specialisation is lifted once per memo key, and
// every later evaluation builds only its closure — the same code, this frame's
// captures. Keyed on the specialisation's key (`isctx`) and where the literal is
// written; outside a specialisation `isctx` is empty and nothing is memoised.
$decl fnm_ent   $func ($decl k "", $decl i 0,
    $decl t T.proto_ty) { $decl key k  $decl idx i  $decl ty t }
$decl proto_fnm $call fnm_ent ("", 0, T.t_bot)
$decl fnm_list  $specialize P.list proto_fnm

// §4.10's receivers. A module whose props have one records its name and the type the
// receiver is captured at: the block's own type for a value, a reference to it for `$mut`
// storage, so a member writes what the declaration can.
$decl rcv_ent $func ($decl m 0, $decl n "", $decl t T.proto_ty)
  { $decl mid m  $decl name n  $decl ty t }
$decl proto_rcv $call rcv_ent (0, "", T.t_bot)
$decl rcv_list $specialize P.list proto_rcv

$decl find_rcv $func ($decl xs rcv_list.node, $decl m 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_int (xs.head.mid, m)) xs
        ($call find_rcv (xs.tail, m)),
  $case xs rcv_list.nil
)

$decl find_fnm $func ($decl xs fnm_list.node, $decl k "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.key, k)) xs
        ($call find_fnm (xs.tail, k)),
  $case xs fnm_list.nil
)

$decl lstate $func () {
  // §9.3's table, pending half: **newest first**, so an append is one cell.
  $decl tpend  $mut $alloc T.tys.node
  $decl ntypes $mut $alloc 0
  $decl nslots $mut $alloc 0
  // How many §5.7 type-only positions enclose what is being lowered (`type_only`). A
  // generic inferred by application has a type and no value (`tyhole`), so reading one
  // anywhere else is reported.
  $decl tonly  $mut $alloc 0
  // A `$func` literal a block's `$decl` binds (`lower_item`): its name, handed to the
  // literal's lowering, and then, while that body is lowered, the function it names —
  // its lifted index, its type, and its captures' types — so naming it inside its own
  // body is a closure over itself (STDLIB.md, P10).
  $decl recname $mut $alloc ""
  $decl scname  $mut $alloc ""
  $decl scidx   $mut $alloc -1
  $decl scty    $mut $alloc T.proto_ty
  $decl scets   $mut $alloc IR.ints.node
  // The type of each slot allocated so far, newest first (§7.2).
  $decl sltys  $mut $alloc IR.ints.node
  // Identities for opaque prop values; §4.10 makes two distinct
  // function-valued props distinct types, so they must not share one.
  // §4.10's compile-time half: every block with props that lowering has
  // seen, so a projection onto a prop can be answered from its source.
  // §9.3's table, settled half: **oldest first**, so a position *is* an
  // index and a scan meets the oldest entries first. See `add_ty`.
  $decl tsettled $mut $alloc T.tys.node
  $decl nsettled $mut $alloc 0
  // §9.3's table indexed by hash. The queue above still answers `ty_at` and
  // `all_types`, because an index *is* a type's identity; this answers "which index
  // is this type", which the linear scan was doing at ~74% of a compiled build.
  $decl tytrie   $mut $alloc IR.proto_trie
  // The same table by **index**, for `ty_at` (see `IR.ix_put`).
  $decl tyix  $mut $alloc IR.proto_trie
  $decl mods  $mut $alloc mods_list.node
  $decl nmods $mut $alloc 0
  $decl modix $mut $alloc mxtrie
  // Which module's code is being lowered right now, or -1 for the entry file.
  // §4.14 lets two modules bind one name, so this is what lets a function be
  // *named* by something stable rather than by its table index. Saved and restored
  // at the three `lower_prop_*` entries, because loading a module can load another
  // partway through one of its members — so a module's functions are **not** a
  // contiguous range of the table, which is why this is per function and not a
  // span. Those three are the same three places this file has twice been caught
  // patching only some of.
  $decl curmod $mut $alloc ""
  // The **file** being lowered, which is where a function is emitted — as against
  // `curmod`, which is what it is *named* from. They part company inside a
  // `$specialize` and inside a props-bearing block literal: those get names of their
  // own, because that is their stable identity, but their code belongs in the file
  // whose source produced it. One field serving both put a block literal in an
  // output nothing compiled.
  $decl curfile $mut $alloc ""
  // The entry file's short name, and which `$specialize` body is being lowered in
  // *inference's* spelling — both only so `opaque_at` can mint the identity inference
  // minted for the same prop. See `opaque_at`.
  $decl entry $mut $alloc ""
  $decl isctx $mut $alloc ""
  // Every function-valued prop lowering has seen, by identity. See `prop_by_id`.
  $decl opaqs  $mut $alloc opq_list.node
  $decl pends  $mut $alloc pend_list.node
  $decl defers $mut $alloc dfr_list.node
  // DEFER.md step 3: the span of a `$new` literal whose deferrals its declaring block
  // adopts — `lower_block` leaves them on the stack instead of running them.
  $decl keepat $mut $alloc ""
  // How many `$if`/`$match` arms of the current function enclose what is being lowered: a
  // `$new` literal kept with deferrals there takes a flag (`dfr_ent`, example 10).
  $decl armdepth $mut $alloc 0
  // DEFER.md example 7: where each `$new` literal kept with deferrals saved its address,
  // "key|slot|type": a call may hand that place back, and the item decides at run time.
  $decl newptrs $mut $alloc strs.node
  // DEFER.md step 4's routing: for each slot of this function bound from an `$alloc`, the
  // `allocator` binding it was drawn from, as "slot|identity". `$free` checks it.
  $decl aprov  $mut $alloc strs.node
  // The root allocator's binding identity, from §2's root block (`lower_file`).
  $decl rootid $mut $alloc ""
  // DEFER.md: the parameters the module member about to be lowered frees, from inference's
  // facts (`member_facts`); `lower_func` takes them, as it takes `free(i)` from a type.
  $decl mfree  $mut $alloc strs.node
  // Whether the next block lowered is a scope — projected on the spot, or written as an
  // item — rather than a value (DEFER.md): a value passes its storage's deferrals out.
  $decl nextscope $mut $alloc $union (false, true)
  $decl fdefs  $mut $alloc fdef_list.node
  $decl wraps  $mut $alloc wrap_list.node
  $decl wpends $mut $alloc wrap_list.node
  // Lifted `$func` literals by specialisation and position. See `fnm_ent`.
  $decl fnmemo  $mut $alloc fnm_list.node
  // §4.10's receiver as lowering meets it: the `$decl` whose initializer is the block
  // about to be lowered, as in inference; every module whose props have one; and every
  // lifted member that captures it, which a projection makes a closure over the target.
  $decl rname   $mut $alloc ""
  $decl rqual   $mut $alloc ""
  $decl rkind   $mut $alloc ""
  $decl rline   $mut $alloc -1
  $decl rcol    $mut $alloc -1
  $decl recvs   $mut $alloc rcv_list.node
  $decl recvfns $mut $alloc rcv_list.node
  // §4.12: an `$impl`'s base and its override block's span, as in inference — that
  // block's receiver is the `$impl`'s result, so `lower_block` types it from these.
  $decl rbase   $mut $alloc T.proto_ty
  $decl rbline  $mut $alloc -1
  $decl rbcol   $mut $alloc -1
  // Imported modules in the order their loading **completed** — a dependency first,
  // since §4.14 finishes a module before the importer's next member. It is what
  // `mpl_init` has to call them in, and it cannot be recovered from the function
  // table: a module's `$import` member takes its index before the imported module's
  // members are lifted, so index order puts the importer first.
  $decl morder  $mut $alloc strs.node
  // One rank counter per module, so a function's identity is (module, rank) and an
  // edit to one module renumbers only its own. An assoc list because there are a
  // handful of modules, not thousands.
  $decl mranks $mut $alloc mranks_list.node
  // §4.9's templates, and the specialisations already built from them.
  $decl tmpls  $mut $alloc tmpls_list.node
  $decl ntmpls $mut $alloc 0
  $decl specs  $mut $alloc specs_list.node
  // §5.5's placeholders. Inference solves knots and hands the answers over,
  // so lowering needs none — except for a specialised template, whose types
  // it derives itself (§4.9), and a prop's value may reach its own type.
  $decl nvars  $mut $alloc 0
  // How many times a member has been *read* while its own type was still a
  // §5.5 placeholder. A body lowered across one of those has nodes carrying
  // the placeholder, and a node's type is an interned index, so they cannot
  // be revised — the body has to be lowered again once the knot is closed.
  // Counting is what tells a member that needs it from one that does not:
  // naming itself is only the commonest case, not the only one.
  $decl nplace $mut $alloc 0
  // The `$func` members being lowered right now, innermost first (by global index), and the
  // shallowest depth among them read unsettled since the innermost began (`lp_find`). A
  // body that read an *ancestor* still in progress is not lowered again on its own: the
  // ancestor's retry rolls it back and lowers it afresh, so its own would be wasted — and
  // with nesting every wasted retry doubles what is under it (PERF.md, "Retries nested").
  $decl lpstack $mut $alloc strs.node
  $decl minread $mut $alloc 1000000000
  // Reads of unsettled members that are not in progress: the reader answers for those.
  $decl nunk    $mut $alloc 0
  // §3.3's top-level expressions, in the order they were lowered. A file and
  // a module both produce them and both reach this one list, which is why it
  // lives here rather than being threaded through either walk.
  $decl effs   $mut $alloc IR.effects.node
  // §4.14: an `$import` resolves relative to the entry file, and a module
  // sees "the root block plus what it imports, nothing else" — so both have
  // to be reachable from wherever an import is lowered.
  $decl base    $mut $alloc ""
  // The library roots `$import` falls back to (`Pa.resolve_import`), from `compiler`.
  $decl roots   $mut $alloc strs.node
  $decl rootenv $mut $alloc benv.node
  // Functions lifted out of `$func` literals, newest first, and the index
  // the first of them will get. The top-level `$decl`s take the indices
  // below that, in source order, so that a global's index is its position.
  $decl lifted  $mut $alloc IR.fns.node
  $decl nlifted $mut $alloc 0
  $decl fnbase  $mut $alloc 0
  $decl errs    $mut $alloc Pa.diags.node
  // §7.6: the `$alloc` sites inference found drawing from an allocator other than the
  // root's (`infer.mpl`'s `ualloc`). Empty unless a caller supplies it, so a direct
  // lowering keeps the root's everywhere.
  $decl ualloc  $mut $alloc strs.node
}

$decl proto_lst $call lstate ()

// DEFER.md: a file's top level, whose scope is the program (`top_item`, `exit_reg`, after
// `lower_item`, whose walk they reuse).
$fwd top_item
$fwd exit_reg

// The module with id `i`: the leaf's list from that entry on, or nil (see `find_tmpl`).
$decl find_mod_st $func ($decl st proto_lst, $decl i 0) $call mx_find ($call mx_val (st.modix), i,
    0)

// Enter a module for the duration of lowering one of its members, answering the
// previous value so the caller can put it back. A module's members can load another
// module, so these nest.
// The module's short name — its file's basename without the extension, which is what
// names its functions. Two modules with one basename would collide, and `cc` rejects
// the duplicate definition rather than accepting it silently.
$decl mod_short $func ($decl path "") {
  $decl sl $call P.last_slash (path, 0, -1)
  $decl b  $if ($call lt (sl, 0)) path
               ($call slice (path, $call add (sl, 1), $call len (path)))
  $decl n $call len (b)
  $decl ret $if ($call lt (4, n))
      ($if ($call eq_str ($call slice (b, $call sub (n, 4), n), ".mpl"))
           ($call slice (b, 0, $call sub (n, 4))) b)
      b
}.ret

// A compile-time identity as inference mints it (`infer.mpl`'s `ct_id`): the
// specialisation context, the short name of the file it is written in, a per-kind
// tag, and the span. See `opaque_at`.
$decl fshort $func ($decl st proto_lst, $decl fl "")
  $if ($call eq_str (fl, "")) ($call P.sval (st.entry)) ($call mod_short (fl))

$decl ct_hash $func ($decl ic "", $decl fs "", $decl tag 0, $decl n Pa.proto_node) {
  $decl sp  $call P.span_of (n)
  $decl h0  $call T.hash_str (ic, 0, $call T.hash_str (fs, 0, tag))
  $decl ret $call T.hmix ($call T.hmix (h0, sp.line), sp.col)
}.ret

// What `enter_mod` saves: the naming module **and** the file. Two fields because the
// two part company — a `$specialize` body and a props-bearing block literal are named
// from themselves and emitted in the file that produced them.
//
// And the specialisation context: entering a module restores the one it was written in
// (`mod_ent_g`'s `isctx`), and `spec_build` enters its own.
$decl msave_rec   $func ($decl nm "", $decl fl "",
    $decl ic "") { $decl name nm  $decl file fl  $decl isctx ic }
$decl proto_msave $call msave_rec ("", "", "")

$decl cur_msave $func ($decl st proto_lst)
  $call msave_rec ($call P.sval (st.curmod), $call P.sval (st.curfile), $call P.sval (st.isctx))

// A real source module: it is both the name and the file.
$decl enter_mod $func ($decl st proto_lst, $decl mid "") {
  $decl prev $call cur_msave (st)
  $decl s0   $set st.curmod mid
  $decl s1   $set st.curfile mid
  $decl ret  prev
}.ret

// A module whose code belongs to a *different* file than its name: `fl` is where it is
// emitted, `mid` is what it is named from.
$decl enter_mod_in $func ($decl st proto_lst, $decl mid "", $decl fl "", $decl ic "") {
  $decl prev $call cur_msave (st)
  $decl s0   $set st.curmod mid
  $decl s1   $set st.curfile fl
  $decl s2   $set st.isctx ic
  $decl ret  prev
}.ret

$decl leave_mod $func ($decl st proto_lst, $decl prev proto_msave) {
  $decl s0  $set st.curmod prev.name
  $decl s1  $set st.curfile prev.file
  $decl s2  $set st.isctx prev.isctx
  $decl ret 0
}.ret

$decl find_mrank $func ($decl xs mranks_list.node, $decl m "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.mod, m)) xs.head.next
        ($call find_mrank ($call mranks_list.val (xs.tail), m)),
  $case xs 0
)

// The entry is moved to the front: lowering works through one module at a time, so the
// module asked for is nearly always the head and an update is one cell, where rebuilding the
// list up to the entry in place was a copy of it per lowered function (PERF.md). Order means
// nothing here — `find_mrank` looks a module up by name.
$decl put_mrank $func ($decl xs mranks_list.node, $decl m "", $decl n 0, $decl acc mranks_list.node)
  $match xs (
    $case {$prop tag "cons"}
      $if ($call eq_str (xs.head.mod, m))
          ($call mranks_list.cons ($call mrank (m, n),
               $call mranks_list.reverse (acc, $call mranks_list.val (xs.tail))))
          ($call put_mrank ($call mranks_list.val (xs.tail), m, n,
               $call mranks_list.cons (xs.head, acc))),
    $case xs ($call mranks_list.cons ($call mrank (m, n), $call mranks_list.reverse (acc,
                  mranks_list.nil)))
  )

// The next rank for the module being lowered, bumping it.
$decl next_rank $func ($decl st proto_lst) {
  $decl m $call P.sval (st.curmod)
  $decl i $call find_mrank ($call mranks_list.val (st.mranks), m)
  $decl p $set st.mranks ($call put_mrank ($call mranks_list.val (st.mranks), m,
               $call add (i, 1), mranks_list.nil))
  $decl ret i
}.ret


$decl eval_tys   $func ($decl x T.tys.node) x
$decl eval_diags $func ($decl x Pa.diags.node) x

$decl err $func ($decl st proto_lst, $decl m "", $decl x P.proto_span) {
  $decl noted $set st.errs ($call Pa.diags.cons ($call Pa.diag (m, x.line, x.col, ""),
                                                 $call eval_diags (st.errs)))
  $decl ret   0
}.ret

// Append, so that an index into the table stays the index it was handed out
// as. The table holds one entry per *distinct* type, and both of the obvious
// ways to speed this up have been tried and measured; neither helped. Read the
// note in CLAUDE.md before trying a third.
// §9.3's table is append-only and indexed, and appending used to be
// `reverse (cons (t, reverse (xs)))` — two full rebuilds per *new* type, so
// `sum 2k` over a program with T types is T² cons cells. At the front end's
// 1,382 types that measured 1.9M `cons` calls, about a fifth of everything the
// run allocated; the table is the one structure that grows with the *whole*
// program rather than with the file being lowered, which is why it showed up
// as superlinear the moment another module joined the closure.
//
// The obvious repair — hold it newest first, so an append is one cell, and
// read index `i` of `n` entries at position `n-1-i` — takes the memory back
// and costs 30% in *time*, which is worth writing down because the reason is
// not obvious. `find_ty` scans, and the types asked for constantly are `Int`,
// `Str`, unit and the booleans, which are interned *first* and so have the
// smallest indices. Newest-first moves exactly those from the head of the scan
// to its tail: on the front end, 145,860 of 147,242 lookups are hits, and they
// went from position ~10 to position ~1,372. That is 200M extra comparisons,
// against the 248M extra calls actually measured.
//
// So the table is a **banker's queue**. `tsettled` is oldest-first and holds
// indices 0..nsettled-1; `tpend` is newest-first and holds the rest, which
// makes an append one cell. When the pending half outgrows the settled one the
// two are merged, which doubles `nsettled` and so costs O(T) over the whole
// run rather than O(T²). `find_ty` scans settled first, so the hot types are
// back at the head where they were.
$decl join_tys $func ($decl settled T.tys.node, $decl pend T.tys.node)
  $call T.tys.reverse ($call T.tys.reverse (settled, T.tys.nil),
      $call T.tys.reverse (pend, T.tys.nil))

$decl npend $func ($decl st proto_lst)
  $call isub ($call P.ival (st.ntypes), $call P.ival (st.nsettled))

// The whole table in index order. Everything downstream — `emit`, `verify`, a
// §9.2 pass — indexes it, and an index is a position.
$decl all_types $func ($decl st proto_lst)
  $call join_tys ($call T.tys.val (st.tsettled), $call T.tys.val (st.tpend))

// Merging when the pending half outgrows the settled one is what makes the
// append amortised: `nsettled` doubles each time, so the merges cost 1 + 3 + 7
// + … + T ≈ 2T cells in total.
$decl merge_tys $func ($decl st proto_lst)
  $if ($call lt ($call P.ival (st.nsettled), $call npend (st))) {
    $decl j   $set st.tsettled ($call all_types (st))
    $decl c   $set st.tpend T.tys.nil
    $decl n   $set st.nsettled ($call P.ival (st.ntypes))
    $decl ret 0
  }.ret
      0

$decl add_ty $func ($decl st proto_lst, $decl t T.proto_ty) {
  $decl i $call P.ival (st.ntypes)
  $decl p $set st.tpend ($call T.tys.cons (t, $call T.tys.val (st.tpend)))
  // Indexed under the same key `ty_find` will ask with, and with the index this
  // type is being given — which is `ntypes` *before* the bump.
  $decl x $set st.tytrie ($call IR.trie_add ($call IR.tval_trie (st.tytrie),
              $call IR.bucket_of ($call T.hash_of (t)), 0, $call IR.tyent (i, t)))
  $decl xi  $set st.tyix ($call IR.ix_put ($call IR.tval_trie (st.tyix), i, t))
  $decl n   $set st.ntypes ($call add (i, 1))
  $decl m   $call merge_tys (st)
  $decl ret 0
}.ret

// One descent and a short bucket scan, where this used to walk the settled half and
// then the pending one — oldest-first so `Int` and friends were met immediately, which
// helped and was still 229 entries on average. The trie carries each type's index with
// it, so the two-half arithmetic that mapped a position in `tpend` back to an index is
// gone as well.
$decl ty_find $func ($decl st proto_lst, $decl t T.proto_ty)
  $call IR.trie_find ($call IR.tval_trie (st.tytrie),
      $call IR.bucket_of ($call T.hash_of (t)), t)

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

$decl seal_rec $func ($decl st proto_lst, $decl t T.proto_ty) {
  $decl u $call T.unroll (t)
  $decl ret $match u (
      $case {$prop tag "union"}
        $do ($call seal_tys (st, $call T.tys.val (u.members))) ($call intern (st, u)),
      $case {$prop tag "block"}
        $do ($call seal_flds (st, $call T.fields.val (u.fields))) ($call intern (st, u)),
      $case u 0
    )
}.ret

$decl is_rec $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "rec"} true,
  $case t false
)

$decl intern $func ($decl st proto_lst, $decl t T.proto_ty) {
  // The count before anything is added: on a miss that *is* the new entry's
  // index, and `seal_rec` below may add more without changing it.
  $decl cnt $call P.ival (st.ntypes)
  $decl f   $call ty_find (st, t)
  $decl ret $if f.hit f.id {
    $decl added $call add_ty (st, t)
    // After the entry exists, never before: the unrolling names this
    // very type, and finding it is what ends the recursion.
    $decl sealed $if ($call is_rec (t)) ($call seal_rec (st, t)) 0
    $decl ret2   cnt
  }.ret2
}.ret

// The index of a module-valued name's type. A module's value is its record
// (`mod_value`), whose type is enormous — and *naming* a module is the commonest thing
// a program does, since `T.foo` lowers `T` first. Interning that type at every
// projection was a full structural comparison per member access, which is what made
// the compiler emit itself in 4m11s rather than 26s even with the record memoised.
// The memo already holds the index, so a module with a record answers from it; the
// type of a module-valued global is that record by construction. Anything without one
// — a props-bearing block literal, a specialisation, a record not yet settled — is
// interned as before.
$decl mod_rec_of $func ($decl st proto_lst, $decl mid 0)
  $if ($call lt (mid, 0)) no_mrec {
    $decl ms $call find_mod_st (st, mid)
    $decl ret  $match ms (
        $case {$prop tag "cons"} ($call mrec_val (ms.head.rec)),
        $case ms no_mrec
      )
  }.ret

$decl mod_ty_id $func ($decl st proto_lst, $decl mid 0, $decl t T.proto_ty) {
  $decl mr  $call mod_rec_of (st, mid)
  $decl ret $if mr.has mr.id ($call intern (st, t))
}.ret

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
$decl fresh_slot $func ($decl st proto_lst, $decl ty 0) {
  $decl i   $call P.ival (st.nslots)
  $decl n   $set st.nslots ($call add (i, 1))
  $decl t   $set st.sltys ($call IR.ints.cons (ty, $call IR.ints.val (st.sltys)))
  $decl ret i
}.ret

// Put a saved slot space back, for lowering a nested `$func` literal.
$decl restore_slots $func ($decl st proto_lst, $decl xs IR.ints.node) {
  $decl c0  $set st.nslots ($call IR.ints.length (xs, 0))
  $decl c1  $set st.sltys ($call IR.ints.reverse (xs, IR.ints.nil))
  $decl ret ()
}.ret

// The slot types in order, and the counters reset for the next function.
$decl take_slots $func ($decl st proto_lst) {
  $decl xs  $call IR.ints.reverse ($call IR.ints.val (st.sltys), IR.ints.nil)
  $decl c0  $set st.nslots 0
  $decl c1  $set st.sltys IR.ints.nil
  $decl ret xs
}.ret

// Lift a function out of an expression and hand back the index it will have.
$decl add_lifted $func ($decl st proto_lst, $decl f IR.proto_fn) {
  $decl i   $call P.ival (st.nlifted)
  $decl n   $set st.nlifted ($call add (i, 1))
  $decl l   $set st.lifted ($call IR.fns.cons (f, $call IR.fns.val (st.lifted)))
  $decl ret $call add (st.fnbase, i)
}.ret

$decl eval_mods $func ($decl x mods_list.node) x

// Replace a module's entry, keyed by id.
//
// The comment here used to say "the table is small — one per block with props —
// so a rebuild costs less than the indirection a mutable cell would need". It
// is not small: **865 modules** on the front end alone, every `$specialize` and
// every prop-bearing literal among them. Rebuilding all of them to change one
// entry's `done` field measured **81.94 MB across 7,175 calls, 17.8% of the
// run** and 22.5% of everything `cons` allocated.
//
// So the walk stops at the entry it came for and **shares the tail**, which is
// untouched by construction: cost is 2p for position p instead of 2M. It can
// never be worse than the old version, since p <= M, and it is usually far
// better — `fresh_mod_at` prepends, and `note_prop` fires on the module being
// lowered right now, which is at or near the head.
//
// Still copy-on-write, and that is deliberate. The tempting fix is a `$mut`
// cell for `done` so nothing is rebuilt at all — but `take_snap`/`put_snap`
// roll the module table back for a recursive member's first pass (§5.5), and
// restoring a list of entries that hold *pointers* would restore the pointers
// and keep the mutations. Copying the prefix has no such hazard.
// An updated entry goes to the index only. The list answers exactly one question —
// which module a resolved path is (`find_mod_path`, for §4.14's load-once) — and an
// entry's `id` and `path` never change after registration, so the list never needs the
// new version. It used to get one anyway: `put_mod` rebuilt the list up to the entry on
// every save, which was 912 MB of a self-emit's 3.4 GB — 27% of everything the compiled
// compiler allocated, in 7.0M cons cells of 136 bytes.
$decl save_mod $func ($decl st proto_lst, $decl m proto_mod) {
  $decl x   $set st.modix ($call mx_put ($call mx_val (st.modix), m.id, 0, m))
  $decl ret 0
}.ret

$decl fresh_var $func ($decl st proto_lst) {
  $decl i   $call P.ival (st.nvars)
  $decl n   $set st.nvars ($call add (i, 1))
  $decl ret i
}.ret

// Everything a pass can add that outlives it. The first pass of a recursive
// member exists *only* to find its type — §5.5's knot has to be closed before
// the body can be lowered for real — so nothing it built may survive: the
// specialisations it memoised are keyed on the placeholder, and the functions
// it lifted for them would be dead code carrying a type that is not a layout.
$decl lsnap $func ($decl lf IR.fns.node, $decl nl 0, $decl md mods_list.node, $decl nm 0,
                   $decl sp specs_list.node, $decl tm tmpls_list.node, $decl nt 0,
                   $decl ts T.tys.node, $decl tp T.tys.node, $decl ns 0, $decl ny 0,
                   $decl tr IR.proto_trie, $decl oq opq_list.node, $decl pq pend_list.node,
                   $decl fd fdef_list.node, $decl wr wrap_list.node, $decl wp wrap_list.node,
                   $decl mx mxtrie, $decl ti IR.proto_trie, $decl fm fnm_list.node,
                   $decl rv rcv_list.node, $decl rf rcv_list.node) {
  $decl lifted lf  $decl nlifted nl  $decl mods md  $decl nmods nm
  // The receivers name modules by id and members by lifted index; a rollback hands both
  // out again.
  $decl recvs rv  $decl recvfns rf
  // The shared `$func` literals name lifted indices, which a rollback hands out again.
  $decl fnmemo fm
  // The prop registry names modules by id, and a rollback hands ids out again; a
  // pending read names a lifted index, which a rollback hands out again too.
  $decl opaqs oq  $decl pends pq
  // Function definitions and wrappers name lifted indices too.
  $decl fdefs fd  $decl wraps wr  $decl wpends wp
  // The module index, which a rollback has to restore with the list it indexes.
  $decl modix mx
  // The type table by index, likewise: a rollback truncates the table.
  $decl tyix  ti
  $decl specs sp   $decl tmpls tm    $decl ntmpls nt
  // §9.3's table, both halves of the banker's queue and both counters. Every
  // type the discarded pass interned is garbage by construction: it was
  // derived against a placeholder, the tree that named it is thrown away, and
  // nothing outside the pass holds its index. Leaving them behind is what made
  // the table track the *number of derivations* rather than the program.
  $decl tsettled ts  $decl tpend tp  $decl nsettled ns  $decl ntypes ny
  // The trie is persistent, so rolling it back is restoring one reference — the
  // same reason the queue is snapshotted rather than undone. Leaving it out would
  // leave the index naming types the rollback discarded, and `ty_find` would hand
  // back an index past the end of the table.
  $decl tytrie tr
}

$decl proto_lsnap $call lsnap (IR.fns.nil, 0, mods_list.nil, 0, specs_list.nil,
    tmpls_list.nil, 0, T.tys.nil, T.tys.nil, 0, 0, IR.proto_trie, opq_list.nil,
    pend_list.nil, fdef_list.nil, wrap_list.nil, wrap_list.nil, mxtrie, IR.proto_trie,
    fnm_list.nil, rcv_list.nil, rcv_list.nil)

$decl eval_tmpls $func ($decl x tmpls_list.node) x
$decl eval_specs $func ($decl x specs_list.node) x

$decl take_snap $func ($decl st proto_lst)
  $call lsnap ($call IR.fns.val (st.lifted), $call P.ival (st.nlifted),
      $call eval_mods (st.mods), $call P.ival (st.nmods),
      $call eval_specs (st.specs), $call eval_tmpls (st.tmpls), $call P.ival (st.ntmpls),
      $call T.tys.val (st.tsettled), $call T.tys.val (st.tpend),
      $call P.ival (st.nsettled), $call P.ival (st.ntypes),
      $call IR.tval_trie (st.tytrie), $call opq_list.val (st.opaqs),
      $call pend_list.val (st.pends), $call fdef_list.val (st.fdefs),
      $call wrap_list.val (st.wraps), $call wrap_list.val (st.wpends),
      $call mx_val (st.modix), $call IR.tval_trie (st.tyix), $call fnm_list.val (st.fnmemo),
      $call rcv_list.val (st.recvs), $call rcv_list.val (st.recvfns))

$decl put_snap $func ($decl st proto_lst, $decl sn proto_lsnap) {
  $decl a   $set st.lifted  ($call IR.fns.val (sn.lifted))
  $decl b   $set st.nlifted sn.nlifted
  $decl c   $set st.mods    ($call mods_list.val (sn.mods))
  $decl d   $set st.nmods   sn.nmods
  $decl e   $set st.specs   ($call specs_list.val (sn.specs))
  $decl f   $set st.tmpls   ($call tmpls_list.val (sn.tmpls))
  $decl g   $set st.ntmpls  sn.ntmpls
  $decl h   $set st.tsettled ($call T.tys.val (sn.tsettled))
  $decl i   $set st.tpend    ($call T.tys.val (sn.tpend))
  $decl j   $set st.nsettled sn.nsettled
  $decl k   $set st.ntypes   sn.ntypes
  $decl l   $set st.tytrie   ($call IR.tval_trie (sn.tytrie))
  $decl o   $set st.opaqs    ($call opq_list.val (sn.opaqs))
  $decl q   $set st.pends    ($call pend_list.val (sn.pends))
  $decl u   $set st.fdefs    ($call fdef_list.val (sn.fdefs))
  $decl v   $set st.wraps    ($call wrap_list.val (sn.wraps))
  $decl w   $set st.wpends   ($call wrap_list.val (sn.wpends))
  $decl x   $set st.modix    ($call mx_val (sn.modix))
  $decl y   $set st.tyix     ($call IR.tval_trie (sn.tyix))
  $decl z   $set st.fnmemo   ($call fnm_list.val (sn.fnmemo))
  $decl z2  $set st.recvs    ($call rcv_list.val (sn.recvs))
  $decl z3  $set st.recvfns  ($call rcv_list.val (sn.recvfns))
  $decl ret 0
}.ret

$decl fresh_tmpl $func ($decl st proto_lst, $decl gs strs.node, $decl bd Pa.proto_node,
                        $decl en benv.node, $decl ky "", $decl fl "", $decl ic "",
                        $decl fm Pa.proto_node) {
  $decl i  $call P.ival (st.ntmpls)
  $decl n  $set st.ntmpls ($call add (i, 1))
  $decl ii $call ct_hash (ic, $call fshort (st, fl), 7, fm)
  $decl t $set st.tmpls ($call tmpls_list.cons ($call tmpl_rec_k (i, gs, bd, en, ky, fl, ii),
                             $call eval_tmpls (st.tmpls)))
  $decl ret i
}.ret

// §4.9's self-specialisation, lowering's half of what `infer.mpl`'s `self_tmpl_env`
// does. A template records the environment it was *written* in, and its own name was
// not bound there yet — the `$decl` naming it is lowered after its initializer — so
// `$specialize list T` inside `list` found a plain global and said "expects a
// template". Once the `$decl` is known to be a template, its name is bound in that
// environment too. `find_tmpl` takes the first record with the id, so the rebuilt one
// goes in front.
$decl tmpl_self $func ($decl st proto_lst, $decl tid 0, $decl nm "", $decl kind "",
                       $decl idx 0, $decl ty T.proto_ty) {
  $decl hit $call find_tmpl ($call eval_tmpls (st.tmpls), tid)
  $decl ret $match hit (
      $case {$prop tag "cons"} {
        $decl t  hit.head
        $decl nr $call tmpl_rec_x (t.id, t.generics, t.body,
                     $call benv.cons ($call bind_ent6 (nm, kind, idx, ty, -1, tid),
                         $call benv.val (t.env)),
                     t.key, t.file, t.iid, t.ctg, t.ctok, t.vk)
        $decl w    $set st.tmpls ($call tmpls_list.cons (nr, $call eval_tmpls (st.tmpls)))
        $decl ret2 0
      }.ret2,
      $case hit 0
    )
}.ret

$decl add_spec $func ($decl st proto_lst, $decl sp proto_spec) {
  $decl s   $set st.specs ($call specs_list.cons (sp, st.specs))
  $decl ret 0
}.ret

$decl eval_benv $func ($decl x benv.node) x

$decl fresh_mod_ic $func ($decl st proto_lst, $decl ps mprops.node, $decl en benv.node,
                          $decl bs "", $decl pt "", $decl fl "", $decl ic "") {
  $decl i $call P.ival (st.nmods)
  $decl n $set st.nmods ($call add (i, 1))
  // The prop environment is a function of the module alone, so it is built
  // here and never again.
  $decl pe  $call with_index ($call with_props (en, ps, i))
  $decl me  $call mod_ent_g (i, ps, mdones.nil, en, bs, pt, pe, fl, no_mrec, ic, dx_empty)
  $decl m   $set st.mods ($call mods_list.cons (me, $call eval_mods (st.mods)))
  $decl x   $set st.modix ($call mx_put ($call mx_val (st.modix), i, 0, me))
  $decl ret i
}.ret

// A specialisation's **generics module**: each prop is a generic, its source the
// argument written at the `$specialize`. §4.9 evaluates an argument where the
// `$specialize` stands, so its source resolves in the site's scope alone and never
// sees the generics — with them in scope, `$specialize P.list T` written inside a
// template whose own generic is also `T` lowered the argument `T` as the very prop
// it is the source of, and derived a μ with no layout.
$decl fresh_mod_gen $func ($decl st proto_lst, $decl ps mprops.node, $decl en benv.node,
                           $decl pt "", $decl fl "") {
  $decl i $call P.ival (st.nmods)
  $decl n $set st.nmods ($call add (i, 1))
  $decl me $call mod_ent_g (i, ps, mdones.nil, en, "", pt, $call with_index (en), fl, no_mrec,
               $call P.sval (st.isctx), dx_empty)
  $decl m   $set st.mods ($call mods_list.cons (me, $call eval_mods (st.mods)))
  $decl x   $set st.modix ($call mx_put ($call mx_val (st.modix), i, 0, me))
  $decl ret i
}.ret

// Written where it stands, so in whatever specialisation is being lowered.
$decl fresh_mod_in $func ($decl st proto_lst, $decl ps mprops.node, $decl en benv.node,
                          $decl bs "", $decl pt "", $decl fl "")
  $call fresh_mod_ic (st, ps, en, bs, pt, fl, $call P.sval (st.isctx))

// A real `$import`: the module is its own file, so `mod_short (pt)` is both. Never in a
// specialisation, even when the first `$import` of it is reached from inside one.
$decl fresh_mod_at $func ($decl st proto_lst, $decl ps mprops.node, $decl en benv.node,
                          $decl bs "", $decl pt "")
  $call fresh_mod_ic (st, ps, en, bs, pt, $call mod_short (pt), "")

$decl fresh_mod $func ($decl st proto_lst, $decl ps mprops.node, $decl en benv.node)
  $call fresh_mod_at (st, ps, en, "", "")

$decl mod_props $func ($decl st proto_lst, $decl mid 0) {
  $decl ms $call find_mod_st (st, mid)
  $decl ret $match ms (
      $case {$prop tag "cons"} ($call mprops.val (ms.head.props)),
      $case ms mprops.nil
    )
}.ret

// A global index reserved before the function that fills it exists. A prop
// whose body calls itself needs its own name bound while that body is lowered,
// and a name is bound to an index — so the index has to come first.
$decl reserve_lifted $func ($decl st proto_lst) {
  $decl i   $call P.ival (st.nlifted)
  $decl n   $set st.nlifted ($call add (i, 1))
  $decl l   $set st.lifted ($call IR.fns.cons (IR.proto_fn, $call IR.fns.val (st.lifted)))
  $decl ret $call add (st.fnbase, i)
}.ret

// Replace one entry, copying only as far as it and **sharing the tail**. `st.lifted`
// is newest first, so the entry just reserved is at position 0 and the common case
// costs nothing.
$decl replace_at $func ($decl xs IR.fns.node, $decl i 0, $decl f IR.proto_fn,
                        $decl acc IR.fns.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_int (i, 0))
        ($call IR.fns.reverse (acc, $call IR.fns.cons (f, xs.tail)))
        ($call replace_at ($call IR.fns.val (xs.tail), $call isub (i, 1), f,
             $call IR.fns.cons (xs.head, acc))),
  $case xs ($call IR.fns.reverse (acc, IR.fns.nil))
)

// `st.lifted` is newest-first, so it is turned around to be indexed and back
// again. Both the list and the reservation are compile-time bookkeeping.
// This used to turn the list around, replace, and turn it back — **three full
// rebuilds of the function table per lifted function**, so `sum 3k` = 1.5L²
// cells. Compiled, an `IR.fns.node` is 136 bytes (its element `IR.fn` has eight
// fields, three of them list nodes held inline), and it measured **14.6M
// allocations, 1,889 MB, 51% of everything the compiled compiler allocates** —
// the largest single term by a wide margin.
//
// `st.lifted` is newest first, so index `k` sits at position `nlifted-1-k` from
// the head, and `reserve_lifted` hands out `k = nlifted-1` immediately before
// this is called: **position 0**. So the common case copies nothing and shares
// the whole tail, and the worst case is no worse than one traversal where it
// used to be three.
$decl put_lifted $func ($decl st proto_lst, $decl idx 0, $decl f IR.proto_fn) {
  $decl k   $call isub (idx, st.fnbase)
  $decl pos $call isub ($call isub ($call P.ival (st.nlifted), 1), k)
  $decl s   $set st.lifted
                ($call replace_at ($call IR.fns.val (st.lifted), pos, f, IR.fns.nil))
  $decl ret   0
}.ret

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
$decl result_of $func ($decl t0 T.proto_ty) {
  $decl t $call T.unroll (t0)
  $decl ret $match t (
      $case {$prop tag "func"} ($call T.tval (t.result)),
      $case t t
    )
}.ret

// §3.5's kind, read off a reference type. Empty for anything that is not one,
// which is the same answer as "frame" and is what a malformed `$mut` would
// get anyway — the error for that is raised where it belongs.
$decl ref_kind $func ($decl t0 T.proto_ty) {
  $decl t   $call T.unroll (t0)
  $decl ret $match t ($case {$prop tag "ref"} t.kind, $case t "")
}.ret

$decl deref_ty $func ($decl t0 T.proto_ty) {
  $decl t $call T.unroll (t0)
  $decl ret $match t (
      $case {$prop tag "ref"} ($call T.tval (t.inner)),
      $case t t
    )
}.ret

// §5.4: a reference behaves as its pointee wherever a value is expected, and
// there is no way to write that in source — so it is written here.
//
// The type is bound to a name before matching on it: §4.7 narrows a scrutinee
// *by its name*, so `$match r.ty` would leave `r.ty.inner` on the whole union.
$decl as_value $func ($decl st proto_lst, $decl r proto_lres) {
  $decl t   $call T.unroll (r.ty)
  $decl ret $match t (
      $case {$prop tag "ref"} {
        $decl inner $call T.tval (t.inner)
        // Reading through storage does not change which module the value
        // is, so the compile-time half survives the deref.
        $decl ret2 $call lres4 ($call IR.e_deref ($call intern (st, inner), r.ir), inner,
                    r.mod, r.tmpl)
      }.ret2,
      $case t r
    )
}.ret

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

$decl has_fields $func ($decl t0 T.proto_ty) {
  $decl t $call T.unroll (t0)
  $decl ret $match t (
      $case {$prop tag "block"} ($call not ($call T.fields.is_nil ($call T.fields.val (t.fields)))),
      $case t false
    )
}.ret

// Does a value of this type occupy nothing at run time? Only a block with no
// `$decl` fields does — §7.2 gives it an empty layout, so the value *is* its
// own type and rebuilding it is free. Everything else has content: a union
// carries §7.5's discriminator, and a leaf carries a word. This is the test
// `prop_const` needs, and asking `has_fields` instead was a miscompile — a
// union is not a block, so it answered "no fields" and the prop was emitted as
// a zeroed struct with tag 0 rather than §4.8a's first member injected.
$decl empty_val $func ($decl t0 T.proto_ty) {
  $decl t $call T.unroll (t0)
  $decl ret $match t (
      $case {$prop tag "block"} ($call T.fields.is_nil ($call T.fields.val (t.fields))),
      $case t false
    )
}.ret

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
  $case {$prop tag "error"}      "a parse error",
  $case {$prop tag "group"}      "a group (§2.3)",
  $case {$prop tag "block"}      "a block",
  $case {$prop tag "proj_name"}  "a projection",
  $case {$prop tag "proj_index"} "a positional projection (.n)",
  $case n "a form"
)

$decl proto_form  $call Pa.n_form ("", Pa.nodes.nil, 0, 0)
$decl proto_projn $call Pa.n_projn (Pa.proto_node, "", 0, 0)

// The receiver a module's member is lifted with, if the member names it.
$decl rcv_name $func ($decl rv rcv_list.node, $decl pn Pa.proto_node) $match rv (
  $case {$prop tag "cons"} $if ($call Pa.names_recv (pn, rv.head.name)) rv.head.name "",
  $case rv ""
)

$decl rcv_ty $func ($decl rv rcv_list.node) $match rv (
  $case {$prop tag "cons"} rv.head.ty,
  $case rv T.t_bot
)

$decl is_ref_ty $func ($decl t T.proto_ty) $match t ($case {$prop tag "ref"} true, $case t false)

// Whether a lifted index is a member that captures its receiver.
$decl has_recvfn $func ($decl st proto_lst, $decl i 0)
  $call P.not ($call rcv_list.is_nil ($call find_rcv ($call rcv_list.val (st.recvfns), i)))

$decl is_name_at $func ($decl n Pa.proto_node) $match n ($case {$prop tag "name"} true, $case n false)

// §4.10: a member that names its receiver is a closure over it, so a projection onto one
// builds the closure from the target it was projected from. "The receiver is a
// reference", so the capture is the target's **own storage**, read-only or not: the
// target if it is a reference already, a name's storage (`addr`), and only a temporary
// through fresh frame storage — exactly how `$traitsof` makes its referent (`tobj_of`).
// A copy of the value used to stand in for a read-only receiver, so `$traitsof a` inside a
// member referred to the copy: on the heap here, which hid it, and in a trait object's
// shim's frame, which did not (stack-use-after-return).
$decl recv_wrap $func ($decl st proto_lst, $decl raw proto_lres, $decl tgt proto_lres,
    $decl x Pa.proto_node, $decl r proto_lres) {
  $decl ir  r.ir
  $decl ret $match ir (
      $case {$prop tag "global"}
        $if ($call has_recvfn (st, ir.fn)) {
          // Keyed by the member's lifted index, not by the target's module: a projection
          // off a parameter of block type reaches the member through its type's props
          // and has no module, and the receiver is still what it was reached through.
          $decl rv   $call find_rcv ($call rcv_list.val (st.recvfns), ir.fn)
          $decl rk   $call intern (st, $call rcv_ty (rv))
          $decl cap  $if ($call is_ref_ty ($call T.unroll (raw.ty))) raw.ir
                         ($if ($call is_name_at (x)) ($call IR.e_addr (rk, raw.ir))
                              ($call IR.e_new (rk, tgt.ir)))
          $decl ret2 $call lres ($call IR.e_closure (ir.ty, ir.fn,
                         $call IR.exprs.cons (cap, IR.exprs.nil)), r.ty)
        }.ret2 r,
      $case ir r
    )
}.ret

// A member that names its receiver has nothing to capture when it is reached by its bare
// name from a sibling, so it is reached through its receiver or not at all.
$decl bare_recv $func ($decl st proto_lst, $decl r proto_lres, $decl nm "", $decl n Pa.proto_node) {
  $decl ir  r.ir
  $decl ret $match ir (
      $case {$prop tag "global"}
        $if ($call has_recvfn (st, ir.fn))
            ($call lres ($call IR.e_unit ($call err (st, $call concat ("'",
                $call concat (nm, "' names its receiver, so it is reached through it (§4.10)")), n)),
                T.t_bot))
            r,
      $case ir r
    )
}.ret

$fwd lower
$fwd lower_block
// §4.15a: `$try` runs the pending deferrals, which are lowered with the block machinery.
$fwd lower_dfrs
// DEFER.md step 4: `$free`, which needs `$decl`'s provenance record, below.
$fwd lower_free
$fwd check_freed
$fwd freed_provs
$fwd mfree_provs
$fwd alloc_ident
$fwd alloc_fin
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
$decl type_only $func ($decl st proto_lst, $decl e benv.node, $decl n Pa.proto_node) {
  $decl keep $call take_slots (st)
  $decl tin  $set st.tonly ($call add ($call P.ival (st.tonly), 1))
  $decl v    $call lval ($call lower (st, e, n, false))
  $decl tout $set st.tonly ($call sub ($call P.ival (st.tonly), 1))
  $decl back $call restore_slots (st, keep)
  $decl ret  v
}.ret

// A `$func` literal is lowered by the same code as a top-level one, and needs
// its type back to build the closure — both sit below, in the same knot (§5.5).
$fwd lower_func
$fwd fn_ty

// Arguments are a value position (§5.4), so each is read through.
// The callee's parameter types, walked alongside the arguments. Both accessors
// tolerate running out, because §3.4 fixes a parameter's *type* and not its
// presence — a short call is accepted by inference — and because a callee whose
// type is not a `$func` gives no list at all.
$decl params_of $func ($decl t0 T.proto_ty) {
  $decl t $call T.unroll (t0)
  $decl ret $match t (
      $case {$prop tag "func"} ($call T.tys.val (t.params)),
      $case t T.tys.nil
    )
}.ret

$decl ps_head $func ($decl xs T.tys.node) $match xs (
  $case {$prop tag "cons"} ($call T.tval (xs.head)),
  $case xs T.t_bot
)

$decl ps_tail $func ($decl xs T.tys.node) $match xs (
  $case {$prop tag "cons"} ($call T.tys.val (xs.tail)),
  $case xs T.tys.nil
)

// §5.4 makes a reference behave as its pointee "wherever a value is expected",
// and a parameter typed `&T` does **not** expect one — the section says so in as
// many words: "A value is never implicitly converted to storage. Passing `0` to a
// `&Int` parameter is an error; write `$new 0`." So transparency is a permission
// at a value position, not an obligation at every argument.
$decl wants_ref $func ($decl t0 T.proto_ty) {
  $decl t   $call T.unroll (t0)
  $decl ret $match t ($case {$prop tag "ref"} true, $case t false)
}.ret

// Arguments are a value position (§5.4) — *unless* the parameter is storage,
// which is what makes a `&T` parameter reachable at all and is exactly what
// §4.16's ABI mapping needs for `&T` to arrive as a `T*`. Lowering used to
// dereference every argument, so a reference could never reach a reference
// parameter: inference accepted the call and emit then reported "cannot coerce
// Int to &Int". The two passes have to agree, and §5.4 says which way.
// ---------------------------------------------------------- §4.8 overloads, lowered
//
// Resolution is first fit over lowering's own types, the rule inference applied: an
// argument fits a parameter if it is a subtype, still holds a placeholder (§5.5), or is
// an overload one of whose candidates is. A resolved overload is projection `x.i` (§4.8),
// and an intrinsic's candidate is the intrinsic at that candidate's type.
$decl is_over_l $func ($decl t T.proto_ty) $match t ($case {$prop tag "over"} true, $case t false)

// Read off the type as it stands, never through `T.unroll`: an overload set is not a `μ`,
// and asking `unroll` of every argument's type — a list type is a `μ` — made every call in
// the compiler pay a cache scan for a question whose answer was always "no".
$decl over_cands $func ($decl t T.proto_ty)
  $match t ($case {$prop tag "over"} ($call T.tys.val (t.cands)), $case t T.tys.nil)

// The position of the first candidate `p` accepts, or -1.
$decl cand_ix $func ($decl cs T.tys.node, $decl p T.proto_ty, $decl i 0) $match cs (
  $case {$prop tag "cons"}
    $if ($call T.sub ($call T.tval (cs.head), p)) i
        ($call cand_ix ($call T.tys.val (cs.tail), p, $call add (i, 1))),
  $case cs -1
)

// Candidate `i` of an overload value, at type `c`.
$decl pick_at $func ($decl st proto_lst, $decl r proto_lres, $decl i 0, $decl c T.proto_ty) {
  $decl x   r.ir
  $decl ret $match x (
      $case {$prop tag "prim"} ($call lres ($call IR.e_prim ($call intern (st, c), x.name), c)),
      $case x ($call lres ($call IR.e_field ($call intern (st, c), r.ir, i), c))
    )
}.ret

$fwd tobj_of

// §6: a trait object is wanted and a value of a conforming type given.
$decl to_trait $func ($decl want T.proto_ty, $decl got T.proto_ty)
  $if ($call T.is_trait (want)) ($call not ($call T.is_trait ($call deref_ty (got)))) false

// An argument, lowered, made what its parameter wants: storage kept for a storage
// parameter, a trait object for a trait one (§6), a value otherwise (§5.4) — and an
// overload resolved against a parameter that wants one type (§4.8). `lval` is the identity
// at `lres`: while a knot is being solved `lower`'s own result is a placeholder, so the
// `$if`'s arms have nothing to join on until it is passed through one.
$decl finish_arg $func ($decl st proto_lst, $decl raw proto_lres, $decl x Pa.proto_node,
                        $decl pw T.proto_ty) {
  $decl rl  $call lval (raw)
  $decl r0  $if ($call to_trait (pw, rl.ty))
                ($call lval ($call tobj_of (st, raw, x, pw, x)))
            ($if ($call wants_ref (pw)) ($call lval (raw))
                ($call as_value (st, raw)))
  $decl cs  $call over_cands (r0.ty)
  $decl ix  $if ($call is_over_l (pw)) -1 ($call cand_ix (cs, pw, 0))
  $decl ret $if ($call lt (ix, 0)) r0
                ($call pick_at (st, r0, ix, $call T.tval ($call T.tys.nth (cs, ix))))
}.ret

$decl lres_list $specialize P.list proto_lres

$decl lower_raws $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node,
                        $decl acc lres_list.node) $match xs (
  $case {$prop tag "cons"}
    $call lower_raws (st, e, xs.tail,
        $call lres_list.cons ($call lval ($call lower (st, e, xs.head, false)), acc)),
  $case xs ($call lres_list.reverse (acc, lres_list.nil))
)

// The rest of a node list, total over it: `finish_raws` walks two lists in step and can
// narrow only one of them.
$decl nodes_rest $func ($decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"} ($call Pa.nodes.val (xs.tail)),
  $case xs xs
)

$decl finish_raws $func ($decl st proto_lst, $decl rs lres_list.node, $decl xs Pa.nodes.node,
                         $decl ps T.tys.node, $decl acc IR.exprs.node, $decl tys T.tys.node)
    $match rs (
  $case {$prop tag "cons"} {
    $decl r   $call finish_arg (st, rs.head, $call Pa.nodes.nth (xs, 0), $call ps_head (ps))
    $decl ret $call finish_raws (st, $call lres_list.val (rs.tail), $call nodes_rest (xs),
                  $call ps_tail (ps), $call IR.exprs.cons (r.ir, acc), $call T.tys.cons (r.ty, tys))
  }.ret,
  $case rs ($call args_res ($call IR.exprs.reverse (acc, IR.exprs.nil),
                            $call T.tys.reverse (tys, T.tys.nil)))
)

$decl over_vals $func ($decl st proto_lst, $decl rs lres_list.node, $decl acc IR.exprs.node,
                       $decl tys T.tys.node) $match rs (
  $case {$prop tag "cons"} {
    $decl v   $call as_value (st, rs.head)
    $decl ret $call over_vals (st, $call lres_list.val (rs.tail), $call IR.exprs.cons (v.ir, acc),
                  $call T.tys.cons (v.ty, tys))
  }.ret,
  $case rs ($call args_res ($call IR.exprs.reverse (acc, IR.exprs.nil),
                            $call T.tys.reverse (tys, T.tys.nil)))
)

$decl fits_l $func ($decl p T.proto_ty, $decl raw T.proto_ty) {
  $decl a   $if ($call P.or ($call wants_ref (p), $call T.is_trait (p))) raw ($call deref_ty (raw))
  $decl ret $if ($call T.has_var (a, 0)) true
      ($if ($call T.sub (a, p)) true
      ($if ($call P.and ($call is_over_l (a), $call not ($call is_over_l (p))))
           ($call lt (-1, $call cand_ix ($call over_cands (a), p, 0))) false))
}.ret

$decl all_fit_l $func ($decl ps T.tys.node, $decl rs lres_list.node) $match rs (
  $case {$prop tag "cons"} $match ps (
      $case {$prop tag "cons"}
        $if ($call fits_l ($call T.tval (ps.head), rs.head.ty))
            ($call all_fit_l ($call T.tys.val (ps.tail), $call lres_list.val (rs.tail))) false,
      $case ps false),
  $case rs true
)

// The callee an overloaded call resolves to: first fit, a nested overload looked into.
$decl resolve_call $func ($decl st proto_lst, $decl f proto_lres, $decl cs T.tys.node,
                          $decl rs lres_list.node, $decl i 0) $match cs (
  $case {$prop tag "cons"} {
    $decl c   $call T.unroll ($call deref_ty ($call T.tval (cs.head)))
    $decl ret $match c (
        $case {$prop tag "func"}
          $if ($call all_fit_l ($call T.tys.val (c.params), rs)) ($call pick_at (st, f, i, c))
              ($call resolve_call (st, f, $call T.tys.val (cs.tail), rs, $call add (i, 1))),
        $case {$prop tag "over"} {
          $decl inner $call pick_at (st, f, i, c)
          $decl got   $call lval ($call resolve_call (st, inner, $call T.tys.val (c.cands), rs, 0))
          $decl ret2  $if ($call is_over_l ($call T.unroll (got.ty)))
                          ($call resolve_call (st, f, $call T.tys.val (cs.tail), rs,
                              $call add (i, 1)))
                          got
        }.ret2,
        $case c ($call resolve_call (st, f, $call T.tys.val (cs.tail), rs, $call add (i, 1)))
      )
  }.ret,
  // None fits: inference reported it, so the call is left on the overload itself.
  $case cs f
)

$decl lower_args $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node,
                        $decl acc IR.exprs.node, $decl tys T.tys.node,
                        $decl ps  T.tys.node) $match xs (
  $case {$prop tag "cons"} {
    $decl r   $call finish_arg (st, $call lower (st, e, xs.head, false), xs.head,
                  $call ps_head (ps))
    $decl ret $call lower_args (st, e, xs.tail,
        $call IR.exprs.cons (r.ir, acc), $call T.tys.cons (r.ty, tys),
        $call ps_tail (ps))
  }.ret,
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

// DEFER.md step 3: a `$new` literal with deferrals keeps them past its own end — they are
// its storage's, and belong to its owner. `keepat` names it by position for `lower_block`,
// and the entries it leaves are tagged with the same key (`dfr_ent`).
$decl has_defer $func ($decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call is_form (xs.head, "defer")) true ($call has_defer ($call Pa.nodes.val (xs.tail))),
  $case xs false
)
$decl keep_key $func ($decl line 0, $decl col 0)
  $call concat ($call int_to_str (line), $call concat (":", $call int_to_str (col)))
$decl newlit_key $func ($decl b Pa.proto_node) {
  $decl ok  $match b ($case {$prop tag "block"} ($call has_defer ($call Pa.nodes.val (b.items))),
                      $case b false)
  $decl sp  $call P.span_of (b)
  $decl ret $if ok ($call keep_key (sp.line, sp.col)) ""
}.ret
$decl is_block_ast $func ($decl n Pa.proto_node) $match n ($case {$prop tag "block"} true, $case n false)

// A name: §2.1 makes intrinsics ordinary names, so the only question is which
// kind of binding it found.
//
// An overloaded intrinsic named as a value is the group of its candidates (§4.8), and
// the backend lays that out from the candidates' own entries — which nothing else
// interns, since no expression of a candidate's type was lowered.
$decl intern_cands $func ($decl st proto_lst, $decl cs T.tys.node, $decl id 0) $match cs (
  $case {$prop tag "cons"}
    $do ($call intern (st, $call T.tval (cs.head)))
        ($call intern_cands (st, $call T.tys.val (cs.tail), id)),
  $case cs id
)

// A local `$func` named inside its own body: the closure over itself — its lifted index,
// with its own captures read back in order, which is the closure the enclosing frame holds.
$decl self_caps $func ($decl xs IR.ints.node, $decl i 0, $decl acc IR.exprs.node) $match xs (
  $case {$prop tag "cons"}
    $call self_caps ($call IR.ints.val (xs.tail), $call add (i, 1),
        $call IR.exprs.cons ($call IR.e_capture (xs.head, i), acc)),
  $case xs ($call IR.exprs.reverse (acc, IR.exprs.nil))
)
$decl self_closure $func ($decl st proto_lst) {
  $decl t   $call T.tval (st.scty)
  $decl ret $call lres ($call IR.e_closure ($call intern (st, t), $call P.ival (st.scidx),
                $call self_caps ($call IR.ints.val (st.scets), 0, IR.exprs.nil)), t)
}.ret

$decl lower_name $func ($decl st proto_lst, $decl e benv.node, $decl n Pa.proto_node) {
  $decl nm $call name_of (n)
  $decl f  $call lookup (e, nm)
  $decl ret $if ($call not (f.hit))
      ($if ($if ($call eq_str ($call P.sval (st.scname), "")) false
                ($call eq_str (nm, $call P.sval (st.scname))))
           ($call self_closure (st))
           ($call lres ($call IR.e_unit ($call err (st, $call concat ("unknown name '",
                $call concat (nm, "'")), n)), T.t_bot)))
    ($if ($call eq_str (f.bnd.kind, "prop"))
      // §4.10: a prop is compile-time, so naming one is not reading a slot —
      // it is asking the module what that prop's value lowered to.
      ($call bare_recv (st, $call lower_prop (st, f.bnd.mod, nm, n), nm, n)) {
        $decl bt $call T.tval (f.bnd.ty)
        $decl id $call mod_ty_id (st, f.bnd.mod, bt)
        $decl ir $if ($call eq_str (f.bnd.kind, "local"))   ($call IR.e_local (id, f.bnd.slot))
            ($if ($call eq_str (f.bnd.kind, "capture")) ($call IR.e_capture (id, f.bnd.slot))
            ($if ($call eq_str (f.bnd.kind, "global"))  ($call IR.e_global (id, f.bnd.slot))
                 ($call IR.e_prim ($if ($call is_over_l (bt))
                     ($call intern_cands (st, $call over_cands (bt), id)) id, nm))))
        $decl ret2  $call lres4 (ir, bt, f.bnd.mod, f.bnd.tmpl)
      }.ret2)
}.ret

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

// A prop whose value is not a scalar is `cv_opaque` — an identity, not code (§4.10)
// — and that identity is **where it is written**: the module in scope and the
// initializer's own span. `P.span_of` reaches both off any node, since §5.1 makes
// `{line, col}` a prefix of every one.
//
// It used to be a counter (`st.nopaque`), which made it an artifact of the order
// things were reached: `cv_eq` compares opaque ids and §9.3's hash is *faithful* to
// them, so a prop's type — and therefore its C struct's name — moved when anything
// ahead of it in the program changed. That is the same defect a struct's name and a
// function's name each had, in the one place that still derived an identity from
// arrival order.
//
// It distinguishes exactly what it must. Two props in one module differ by span. Two
// instantiations of one template body share a span and differ by module, because
// `spec_build` enters the specialisation's own key before lowering it — which is why
// that `enter_mod` is load-bearing and not tidying. And a member lowered **twice**
// (§5.5's knot, where the first pass only finds the type) now gets the *same* id both
// times, where a counter gave it two.
//
// **And it is inference's identity exactly, which is what lets a prop be found from a
// type.** A parameter's type comes from inference and a block literal's from here, so
// the two met with different numbers for the same prop: `hash (curmod, line, col)`
// here against `infer.mpl`'s `ct_id` — the specialisation context, the file's short
// name, a per-kind tag (3 for a prop) and the span. Different numbers meant two types
// for one block, and no way to get from a parameter's prop back to its source, so
// `$call m.pf (…)` on a parameter was refused (`prop_by_id`). Same formula now, from
// the same inputs: the file the prop is written in (`curfile`, or the entry's own name),
// and `isctx`, which `spec_build` sets to inference's memo key.
$decl opaque_at $func ($decl st proto_lst, $decl n Pa.proto_node)
  $call ct_hash ($call P.sval (st.isctx), $call fshort (st, $call P.sval (st.curfile)), 3, n)

$decl const_of $func ($decl st proto_lst, $decl n Pa.proto_node) $match n (
  $case {$prop tag "int"}  ($call T.cv_int (n.value)),
  $case {$prop tag "str"}  ($call T.cv_str (n.text)),
  $case {$prop tag "bool"} ($call T.cv_bool (n.value)),
  $case {$prop tag "unit"} T.cv_unit,
  $case n ($call T.cv_opaque ($call opaque_at (st, n)))
)

// Record where each function-valued prop of a module lives, by the identity its type
// carries. Called wherever a block's props are given their identities, in the same
// context, so the number recorded is the number in the type.
$decl note_opaqs $func ($decl st proto_lst, $decl mid 0, $decl xs mprops.node) $match xs (
  $case {$prop tag "cons"} {
    $decl c  $if ($call eq_str (xs.head.kind, "prop")) ($call const_of (st, xs.head.node)) T.cv_unit
    $decl d  $match c (
        $case {$prop tag "copaque"}
          ($set st.opaqs ($call opq_list.cons ($call opq_ent (c.id, mid, xs.head.name), st.opaqs))),
        $case c ($call opq_list.val (st.opaqs))
      )
    $decl ret  $call note_opaqs (st, mid, $call mprops.val (xs.tail))
  }.ret,
  $case xs 0
)

// §4.10 puts a prop's value in its block's **type**, so every value of a type agrees on
// it — which is what makes reading a function-valued prop off a *parameter* sound: the
// parameter's type names the one definition, and nothing at run time can change which.
// The type carries only the identity (`cv_opaque`), so this maps it back to the module
// holding the source, and `lower_prop` lowers it as for any other projection. The name
// must match too: an identity is per prop, and asking for another name is a miss.
$decl prop_by_id $func ($decl xs opq_list.node, $decl id 0, $decl nm "") $match xs (
  $case {$prop tag "cons"}
    $if ($call and ($call eq_int (xs.head.id, id), $call eq_str (xs.head.name, nm))) xs.head.mod
        ($call prop_by_id ($call opq_list.val (xs.tail), id, nm)),
  $case xs -1
)

// A function-valued prop whose block has not been lowered *yet*. Lowering reaches code
// on demand, so a reader written above the code that builds the block — `use` before
// `main`, or a member above its sibling, or anything inside a prop body that only a
// later projection lowers — finds nothing registered. But a value of the type exists
// at run time, so the code building it is lowered by the end of the file. So the read
// reserves a lifted index now, at the prop's type (inference's, which a parameter
// carries), and `resolve_pends` fills it once everything is lowered: a thunk whose body
// is the prop's value, which for a function is one `global` — an alias, so emit calls
// the real function directly.
$decl find_pend $func ($decl xs pend_list.node, $decl c 0, $decl nm "") $match xs (
  $case {$prop tag "cons"}
    $if ($call and ($call eq_int (xs.head.id, c), $call eq_str (xs.head.name, nm))) xs.head.idx
        ($call find_pend ($call pend_list.val (xs.tail), c, nm)),
  $case xs -1
)

// One thunk per prop, however many reads are deferred: it is named from the identity,
// so two would be one name twice.
$decl prop_pending $func ($decl st proto_lst, $decl c 0, $decl nm "", $decl t T.proto_ty,
                          $decl n Pa.proto_node) {
  $decl had $call find_pend ($call pend_list.val (st.pends), c, nm)
  $decl k   $if ($call lt (had, 0)) {
    $decl k0   $call reserve_lifted (st)
    $decl p    $set st.pends ($call pend_list.cons ($call pend_ent (c, nm, k0, t, n), st.pends))
    $decl ret2 k0
  }.ret2
      had
  $decl ret $call lres ($call IR.e_global ($call intern (st, t), k), t)
}.ret

$decl cv_lower $func ($decl st proto_lst, $decl c T.proto_cv, $decl nm "",
                      $decl n Pa.proto_node, $decl pty T.proto_ty) $match c (
  $case {$prop tag "cint"}  ($call lres ($call IR.e_int ($call intern (st, T.t_int), c.v), T.t_int)),
  $case {$prop tag "cstr"}  ($call lres ($call IR.e_str ($call intern (st, T.t_str), c.v), T.t_str)),
  $case {$prop tag "cbool"}
    ($call lres ($call IR.e_bool ($call intern (st, T.t_bool), c.v),
                 $if c.v T.t_true T.t_false)),
  $case {$prop tag "cunit"} ($call lres ($call IR.e_unit ($call intern (st, T.t_unit)), T.t_unit)),
  $case {$prop tag "copaque"} {
    $decl mid $call prop_by_id ($call opq_list.val (st.opaqs), c.id, nm)
    // A type that is not settled has no layout to reserve at; that is a type-only
    // position, never evaluated, and reported rather than guessed.
    $decl ret   $if ($call lt (mid, 0))
        ($if ($call T.has_var (pty, 0))
             ($call lres ($call IR.e_unit ($call err (st, $call concat ("the value of prop '",
                 $call concat (nm, "' is not reachable from here: its type is not settled")), n)), T.t_bot))
             ($call prop_pending (st, c.id, nm, pty, n)))
        ($call lval ($call lower_prop (st, mid, nm, n)))
  }.ret,
  $case c ($call lres ($call IR.e_unit ($call err (st, $call concat ("the value of prop '",
      $call concat (nm, "' is not reachable from here: it is not a scalar, and this block's source was not lowered in this file")), n)), T.t_bot))
)

// The props, not the type: §4.7 narrows by the scrutinee's name and narrowing
// does not cross a call, so the caller — which is inside the `$match` that
// proved this is a block — passes the list out.
$decl prop_from_ty $func ($decl st proto_lst, $decl ps T.props.node, $decl nm "",
                          $decl n Pa.proto_node) {
  $decl f $call find_prop (ps, nm)
  $decl ret $match f (
      $case {$prop tag "cons"} ($call cv_lower (st, f.head.value, nm, n, $call T.tval (f.head.ty))),
      $case f ($call lres ($call IR.e_unit ($call err (st, $call concat ("no field '",
          $call concat (nm, "'")), n)), T.t_bot))
    )
}.ret

// The props a value carries in its type: a block's, or §4.12's `with`'s.
$decl own_props $func ($decl t0 T.proto_ty) {
  $decl t   $call T.unroll (t0)
  $decl ret $match t (
      $case {$prop tag "block"} ($call T.props.val (t.props)),
      $case {$prop tag "with"}  ($call T.props.val (t.props)),
      $case t T.props.nil
    )
}.ret

$decl global_of $func ($decl x IR.proto_expr) $match x ($case {$prop tag "global"} x.fn, $case x -1)

$decl is_name_node $func ($decl n Pa.proto_node) $match n ($case {$prop tag "name"} true, $case n false)

// A trait member that is not a function — `$prop name ""`, §9's test interface — has no
// lifted function for the table to name, and a trait object erases the type that holds
// its value (§6). So it gets one: a zero-argument function answering the value, which is
// compile-time (§4.10) and so a constant. A read through the object calls it (`lower_proj`).
//
// Exported, because a table lives in the shared header (`emit_tables`) and every module's
// output may call it. Named in a space of its own — `<module>_tmem`, ranked off the
// module's counter — since `pub` puts a name in `fn_key`'s member space, where a member's
// rank would collide with the counter's (the same collision default wrappers had).
$decl scalar_fn $func ($decl st proto_lst, $decl v proto_lres) {
  $decl o   $call take_slots (st)
  $decl idx $call reserve_lifted (st)
  $decl f   $call IR.fn_p ("(trait member)", IR.ints.nil, $call intern (st, v.ty),
                $call take_slots (st), v.ir, false, false, IR.ints.nil,
                $call P.sval (st.curfile), $call next_rank (st), true,
                $call concat ($call P.sval (st.curmod), "_tmem"))
  $decl put $call put_lifted (st, idx, f)
  $decl b   $call restore_slots (st, o)
  $decl ret idx
}.ret

$decl is_func_ty $func ($decl t0 T.proto_ty) {
  $decl t   $call T.unroll (t0)
  $decl ret $match t ($case {$prop tag "func"} true, $case t false)
}.ret

// §6: the implementation a value of a conforming type has — each member, in the trait's
// order, as the lifted function its prop's identity names (§4.10), or `scalar_fn`'s.
$decl tobj_fns $func ($decl st proto_lst, $decl ps T.props.node, $decl ms T.fields.node,
    $decl n Pa.proto_node, $decl acc IR.ints.node) $match ms (
  $case {$prop tag "cons"} {
    $decl r   $call lval ($call prop_from_ty (st, ps, ms.head.name, n))
    $decl g   $call global_of (r.ir)
    $decl fi  $if ($if ($call lt (g, 0)) ($call not ($call is_func_ty (r.ty))) false)
                  ($call scalar_fn (st, r)) g
    $decl ret $call tobj_fns (st, ps, $call T.fields.val (ms.tail), n,
                  $call IR.ints.cons (fi, acc))
  }.ret,
  $case ms ($call IR.ints.reverse (acc, IR.ints.nil))
)

// Lowering's block types carry a function-valued prop's *identity* and not its type —
// `T.cv_type` answers ⊥ for an opaque value, since the type exists only once the prop is
// lowered — so a trait derived here takes each member's type from the prop itself, by
// the same route the table does (`prop_from_ty`). Inference's types are already right.
$decl typed_props $func ($decl st proto_lst, $decl ps T.props.node, $decl all T.props.node,
    $decl n Pa.proto_node, $decl acc T.props.node) $match ps (
  $case {$prop tag "cons"} {
    $decl t0  $call T.tval (ps.head.ty)
    $decl t   $if ($call T.same (t0, T.t_bot))
                  ($call lval ($call prop_from_ty (st, all, ps.head.name, n))).ty t0
    $decl ret $call typed_props (st, $call T.props.val (ps.tail), all, n,
                  $call T.props.cons ($call T.prop_typed (ps.head.name, ps.head.value, t), acc))
  }.ret,
  $case ps acc
)

$decl ltrait_of $func ($decl st proto_lst, $decl v0 T.proto_ty, $decl q "", $decl n Pa.proto_node) {
  $decl v   $call T.unroll (v0)
  $decl ret $match v (
      $case {$prop tag "block"} {
        $decl ps   $call T.props.val (v.props)
        $decl ret2 $call T.trait_of ($call T.t_block ($call T.fields.val (v.fields),
                       $call typed_props (st, ps, ps, n, T.props.nil)), false, q)
      }.ret2,
      $case {$prop tag "with"} {
        $decl ps   $call T.props.val (v.props)
        $decl ret2 $call T.trait_of ($call T.t_with ($call T.tval (v.base),
                       $call typed_props (st, ps, ps, n, T.props.nil)), false, q)
      }.ret2,
      $case v ($call T.trait_of (v, false, q))
    )
}.ret

// §6's coercion, and §4.13's `$traitsof`: a trait object referring to the value — a
// reference as itself, a name through its own storage, anything else through fresh
// frame storage as `$new` would make (§4.13). A value already a trait object is itself.
$decl tobj_of $func ($decl st proto_lst, $decl raw proto_lres, $decl x Pa.proto_node,
                     $decl want T.proto_ty, $decl n Pa.proto_node) {
  $decl v   $call deref_ty (raw.ty)
  $decl ret $if ($call T.is_trait (v)) ($call as_value (st, raw)) {
    $decl rft  $call T.t_ref ("", v)
    $decl rir  $if ($call is_ref_ty ($call T.unroll (raw.ty))) raw.ir
                   ($if ($call is_name_node (x)) ($call IR.e_addr ($call intern (st, rft), raw.ir))
                        ($call IR.e_new ($call intern (st, rft), raw.ir)))
    $decl ms   $match want ($case {$prop tag "trait"} ($call T.fields.val (want.members)),
                            $case want T.fields.nil)
    $decl fs   $call tobj_fns (st, $call own_props (v), ms, n, IR.ints.nil)
    $decl ret2 $call lres ($call IR.e_tobj ($call intern (st, want), rir, fs), want)
  }.ret2
}.ret

// §4.6 as a layout position — for a `$decl`. A `$prop` has no layout position
// at all (§4.10), so the two halves of a block are searched in turn: the
// fields, then the props.
// Whether lowering has this name's *source*. A module is asked first, because
// an imported module's members are compile-time here (§4.14) while its type —
// which inference gives in full, §3.3 — still lists them as fields; taking the
// field would emit a read of a layout the module does not have.
$decl mod_has $func ($decl st proto_lst, $decl mid 0, $decl nm "") {
  $decl ms $call find_mod_st (st, mid)
  $decl ret $match ms (
      $case {$prop tag "cons"}
        ($if ($call mprops.is_nil ($call find_mprop (ms.head.props, nm)))
             ($call not ($call mdones.is_nil ($call find_mdone_m (ms.head, nm))))
             true),
      $case ms false
    )
}.ret

// §5.1 makes a block's fields an *ordered prefix*, so a union whose members
// all begin the same way has that prefix in common — `Pa.proto_node`'s members
// all start `line`, `col`, and `n.line` is how the parser reads a span off any
// node. Every member agrees on the name, the position and the type, which is
// exactly what C guarantees is readable through any member of a union of
// structs with a common initial sequence.
$decl ty_at $func ($decl st proto_lst, $decl i 0) $call IR.ix_get ($call IR.tval_trie (st.tyix), i)

$decl canon_ty $func ($decl st proto_lst, $decl t T.proto_ty)
  $call ty_at (st, $call intern (st, t))

$decl members_of $func ($decl t0 T.proto_ty) {
  $decl t $call T.unroll (t0)
  $decl ret $match t (
      $case {$prop tag "union"} ($call T.tys.val (t.members)),
      $case t ($call T.tys.cons (t, T.tys.nil))
    )
}.ret

// §5.4 reads a reference as its pointee, so a union some of whose members are references
// is projected through each: a `switch` on the discriminator, every arm reading its own
// member's field at that member's position. Its pointees share no layout the way a union
// of blocks shares its members' — each is its own object — so the prefix read below does
// not apply, and the arms need not agree on where the field is. Inference joins the field
// types (`proj_one`), as this does.
$decl uproj_arms $func ($decl st proto_lst, $decl ms T.tys.node, $decl i 0, $decl nm "",
                        $decl n Pa.proto_node, $decl acc IR.arms.node, $decl ty T.proto_ty)
  $match ms (
    $case {$prop tag "cons"} {
      $decl m    $call T.unroll (ms.head)
      $decl mid  $call intern (st, ms.head)
      $decl sl   $call fresh_slot (st, mid)
      $decl ld   $call IR.e_local (mid, sl)
      $decl rd   $match m (
          $case {$prop tag "ref"}
            ($call lres ($call IR.e_deref ($call intern (st, $call T.tval (m.inner)), ld),
                $call T.tval (m.inner))),
          $case m ($call lres (ld, ms.head))
        )
      $decl pt   $call T.unroll (rd.ty)
      $decl f    $match pt (
          $case {$prop tag "block"} ($call find_fld ($call T.fields.val (pt.fields), nm, 0)),
          $case pt ($call fld_found (false, 0, T.t_bot))
        )
      $decl body $if f.hit ($call IR.e_field ($call intern (st, f.ty), rd.ir, f.idx))
          ($call IR.e_unit ($call err (st, $call concat ("no field '",
              $call concat (nm, "' in every member of this union (§5.1)")), n)))
      $decl ret  $call uproj_arms (st, $call T.tys.val (ms.tail), $call add (i, 1), nm, n,
          $call IR.arms.cons ($call IR.arm ($call IR.ints.cons (i, IR.ints.nil), sl, body), acc),
          $if f.hit ($call T.join (ty, f.ty)) ty)
    }.ret,
    $case ms ($call arms_res ($call IR.arms.reverse (acc, IR.arms.nil),
                  $call IR.e_unit ($call intern (st, T.t_unit)), ty))
  )

$decl any_ref $func ($decl ms T.tys.node) $match ms (
  $case {$prop tag "cons"} {
    $decl m   $call T.unroll (ms.head)
    $decl ret $match m (
        $case {$prop tag "ref"} true,
        $case m ($call any_ref ($call T.tys.val (ms.tail)))
      )
  }.ret,
  $case ms false
)

// Whether the members of a union of blocks agree on every field up to and including the
// first `n + 1` — same names, same types — which is what makes the C union's common
// initial sequence the prefix §5.1 means. A field at the same position after fields that
// differ sits at a different offset (`{a Int, k Int}` against `{a Str, k Int}`), and one
// whose own type differs is read at the wrong type: both go through the switch.
$decl same_flds $func ($decl xs T.fields.node, $decl ys T.fields.node, $decl n 0)
  $if ($call lt (n, 0)) true
  ($match xs (
      $case {$prop tag "cons"} $match ys (
          $case {$prop tag "cons"}
            $if ($if ($call eq_str (xs.head.name, ys.head.name))
                     ($call T.same ($call T.tval (xs.head.ty), $call T.tval (ys.head.ty))) false)
                ($call same_flds ($call T.fields.val (xs.tail), $call T.fields.val (ys.tail),
                    $call sub (n, 1)))
                false,
          $case ys false),
      $case xs false
    ))
$decl blk_flds $func ($decl t T.proto_ty) {
  $decl m   $call T.unroll (t)
  $decl ret $match m ($case {$prop tag "block"} ($call T.fields.val (m.fields)),
                      $case m T.fields.nil)
}.ret
$decl prefix_ok $func ($decl ms T.tys.node, $decl first T.fields.node, $decl n 0) $match ms (
  $case {$prop tag "cons"}
    $if ($call same_flds ($call blk_flds (ms.head), first, n))
        ($call prefix_ok ($call T.tys.val (ms.tail), first, n)) false,
  $case ms true
)

$decl lower_uproj $func ($decl st proto_lst, $decl tgt proto_lres, $decl nm "",
                         $decl n Pa.proto_node) {
  $decl ms  $call members_of ($call canon_ty (st, tgt.ty))
  $decl a   $call uproj_arms (st, ms, 0, nm, n, IR.arms.nil, T.t_bot)
  $decl ret $call lres ($call IR.e_switch ($call intern (st, a.ty), tgt.ir, a.arms, a.default),
                a.ty)
}.ret

$decl common_fld $func ($decl ms T.tys.node, $decl nm "", $decl best fld_found_proto)
  $match ms (
    $case {$prop tag "cons"} {
      $decl m $call T.unroll (ms.head)
      $decl f $match m (
          $case {$prop tag "block"} ($call find_fld ($call T.fields.val (m.fields), nm, 0)),
          $case m ($call fld_found (false, 0, T.t_bot))
        )
      // Every member must have it, at the same position.
      $decl ok $if f.hit
          ($if best.hit ($call eq_int (f.idx, best.idx)) true)
          false
      $decl ret $if ok ($call common_fld ($call T.tys.val (ms.tail), nm, f))
                     ($call fld_found (false, 0, T.t_bot))
    }.ret,
    $case ms best
  )

// Read out of storage. `as_value` keeps the module across the deref, which is
// right for a `$prop` — §4.10 puts its value in the type, so every value of the
// type agrees — and wrong for a `$decl`: storage holding a module can be `$set` to
// another block of the same type, so which member a field holds is a run-time fact.
// Reading the field is possible because a module's value has its layout (`mod_value`).
$decl is_deref $func ($decl x IR.proto_expr) $match x (
  $case {$prop tag "deref"} true,
  $case x false
)

$decl member_ix $func ($decl ms T.fields.node, $decl nm "", $decl i 0) $match ms (
  $case {$prop tag "cons"}
    $if ($call eq_str (ms.head.name, nm)) i ($call member_ix ($call T.fields.val (ms.tail), nm,
        $call add (i, 1))),
  $case ms -1
)

$decl lower_proj $func ($decl st proto_lst, $decl e benv.node, $decl n proto_projn) {
  $decl raw $call lval ($call lower (st, e, n.target, false))
  $decl tgt $call as_value (st, raw)
  $decl tt  $call T.unroll (tgt.ty)
  $decl own $if ($call lt (tgt.mod, 0)) false ($call mod_has (st, tgt.mod, n.field))
  $decl ret $match tt (
      // §7.6: the root `allocator`'s members are §8's `raw_alloc` and `raw_free`.
      // DEFER.md: and `defer_at`, the runtime's table that `raw_free` consults.
      $case {$prop tag "block"} $if ($call T.same (tt, T.ffi_alloc)) {
        $decl dat  $call eq_str (n.field, "defer_at")
        $decl nm   $if ($call eq_str (n.field, "free")) "raw_free" ($if dat "raw_defer_at" "raw_alloc")
        $decl ft   $if dat
                       ($call T.t_func ($call T.tys.cons (T.t_int, $call T.tys.cons (
                           $call T.t_func (T.tys.nil, T.t_unit), T.tys.nil)), T.t_unit))
                       ($call T.t_func ($call T.tys.cons (T.t_int, T.tys.nil),
                           $if ($call eq_str (n.field, "free")) T.t_unit T.t_int))
        $decl ret3 $call lres ($call IR.e_prim ($call intern (st, ft), nm), ft)
      }.ret3 {
        $decl f   $call find_fld ($call T.fields.val (tt.fields), n.field, 0)
        $decl ask $if own ($call not ($call and (f.hit, $call is_deref (tgt.ir)))) false
        $decl ret2 $if ask
            ($call recv_wrap (st, raw, tgt, n.target, $call lower_prop (st, tgt.mod, n.field, n)))
            ($if f.hit
            ($call lres ($call IR.e_field ($call intern (st, f.ty), tgt.ir, f.idx), f.ty))
            ($if ($call lt (tgt.mod, 0))
                 ($call recv_wrap (st, raw, tgt, n.target,
                     $call prop_from_ty (st, $call T.props.val (tt.props), n.field, n)))
                 ($call recv_wrap (st, raw, tgt, n.target,
                     $call lower_prop (st, tgt.mod, n.field, n)))))
      }.ret2,
      // §6: a member through a trait object, by its place in the trait's sorted members,
      // with the object for `Self`.
      $case {$prop tag "trait"} {
        $decl ms   $call T.fields.val (tt.members)
        $decl ix   $call member_ix (ms, n.field, 0)
        $decl mt   $call T.trait_member (tt, n.field, tt)
        $decl ret2 $if ($call lt (ix, 0))
            ($call lres ($call IR.e_unit ($call err (st, $call concat ("no member '",
                $call concat (n.field, "' in this trait")), n)), T.t_bot))
            ($if ($call is_func_ty (mt))
                 ($call lres ($call IR.e_tmem ($call intern (st, mt), tgt.ir, ix), mt))
                 // A scalar member: its table entry answers it (`scalar_fn`).
                 {
                   $decl ft   $call T.t_func (T.tys.nil, mt)
                   $decl ret3 $call lres ($call IR.e_call ($call intern (st, mt),
                                  $call IR.e_tmem ($call intern (st, ft), tgt.ir, ix),
                                  IR.exprs.nil, false), mt)
                 }.ret3)
      }.ret2,
      // §4.12: an added prop, from the `$impl`'s override where its source is known and by
      // its identity in the type otherwise — exactly a block's props.
      $case {$prop tag "with"}
        $if own ($call recv_wrap (st, raw, tgt, n.target,
                     $call lower_prop (st, tgt.mod, n.field, n)))
            ($call recv_wrap (st, raw, tgt, n.target,
                $call prop_from_ty (st, $call T.props.val (tt.props), n.field, n))),
      $case {$prop tag "union"} {
        $decl ums  $call T.tys.val (tt.members)
        $decl f    $call common_fld (ums, n.field, fld_found_proto)
        $decl pre  $if f.hit ($match ums (
                       $case {$prop tag "cons"}
                         ($call prefix_ok (ums, $call blk_flds (ums.head), f.idx)),
                       $case ums false)) false
        $decl ret2 $if ($if ($call any_ref (ums)) true ($call not (pre)))
            ($call lower_uproj (st, tgt, n.field, n))
            ($if f.hit
            ($call lres ($call IR.e_field ($call intern (st, f.ty), tgt.ir, f.idx), f.ty))
            ($call lres ($call IR.e_unit ($call err (st, $call concat ("no field '",
                $call concat (n.field, "' common to every member of this union (§5.1)")), n)),
                T.t_bot)))
      }.ret2,
      $case tt ($call lres ($call IR.e_unit ($call err (st,
          $call concat ("projection needs a block, found ", $call T.show (tt)), n)), T.t_bot))
    )
}.ret

// §4.6's `.n`. §2.3 makes a group the only thing it applies to — a block's
// members have names — and inference reads it one-based, so this does too.
$decl lower_projidx $func ($decl st proto_lst, $decl e benv.node, $decl n Pa.proto_node,
                           $decl tgtn Pa.proto_node, $decl idx 0) {
  $decl tgt $call as_value (st, $call lower (st, e, tgtn, false))
  $decl tt  $call T.unroll (tgt.ty)
  $decl ret $match tt (
      $case {$prop tag "group"} {
        $decl its $call T.tys.val (tt.items)
        $decl nf  $call T.tys.length (its, 0)
        $decl ret2 $if ($call and ($call lt (0, idx), $call not ($call lt (nf, idx)))) {
          $decl k    $call isub (idx, 1)
          $decl fty  $call T.tval ($call T.tys.nth (its, k))
          $decl ret3 $call lres ($call IR.e_field ($call intern (st, fty), tgt.ir, k), fty)
        }.ret3
            ($call lres ($call IR.e_unit ($call err (st, "group index is out of range", n)),
                T.t_bot))
      }.ret2,
      // §4.8: an overload is its group of candidates, and `x.i` names one.
      $case {$prop tag "over"} {
        $decl cs   $call T.tys.val (tt.cands)
        $decl nc   $call T.tys.length (cs, 0)
        $decl ret2 $if ($call and ($call lt (0, idx), $call not ($call lt (nc, idx))))
            ($call pick_at (st, tgt, $call isub (idx, 1),
                $call T.tval ($call T.tys.nth (cs, $call isub (idx, 1)))))
            ($call lres ($call IR.e_unit ($call err (st, "overload index is out of range", n)),
                T.t_bot))
      }.ret2,
      $case tt ($call lres ($call IR.e_unit ($call err (st,
          $call concat ("cannot index into ", $call T.show (tt)), n)), T.t_bot))
    )
}.ret

// §2.3's group as a value: laid out elementwise (§7.2), so it is a block whose
// members have positions instead of names.
$decl lower_items_g $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node,
                           $decl irs IR.exprs.node, $decl tys T.tys.node) $match xs (
  $case {$prop tag "cons"} {
    $decl v $call lval ($call lower (st, e, xs.head, false))
    $decl ret $call lower_items_g (st, e, $call Pa.nodes.val (xs.tail),
                $call IR.exprs.cons (v.ir, irs), $call T.tys.cons (v.ty, tys))
  }.ret,
  $case xs ($call args_res ($call IR.exprs.reverse (irs, IR.exprs.nil),
                $call T.tys.reverse (tys, T.tys.nil)))
)

$decl lower_group $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node) {
  $decl a   $call lower_items_g (st, e, xs, IR.exprs.nil, T.tys.nil)
  $decl ty  $call T.t_group ($call T.tys.val (a.tys))
  $decl ret $call lres ($call IR.e_group ($call intern (st, ty), $call IR.exprs.val (a.irs)), ty)
}.ret

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
$decl pat_props $func ($decl st proto_lst, $decl xs Pa.nodes.node,
    $decl acc T.props.node) $match xs (
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
    ($call T.t_block (T.fields.nil, $call pat_props (st, $call Pa.nodes.val (n.items),
        T.props.nil))),
  // §4.7's catch-all names the scrutinee, so its type is whatever that is —
  // read through, because §5.4 makes a reference transparent in a `$match`
  // scrutinee and the pattern is compared against the *value*.
  $case {$prop tag "name"} {
    $decl f   $call lookup (e, $call name_of (n))
    $decl ret $if f.hit ($call deref_ty (f.bnd.ty)) T.t_bot
  }.ret,
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
// Entry `i` of the banker's queue: a position in the settled half, or counted
// from the other end of the pending one.
// By index, through `tyix`: the queue below gave a position in one of its two halves,
// and `nth` walked to it from the head.
// §4.8a's type: every member joined. Lowering a member is how its type is
// read; the tree is thrown away, which costs the slots a discarded `$decl`
// would have taken and nothing else.
$fwd union_ty

$decl union_ty $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node,
                      $decl acc T.proto_ty) $match xs (
  $case {$prop tag "cons"} {
    $decl m   $call type_only (st, e, xs.head)
    $decl ret $call union_ty (st, e, $call Pa.nodes.val (xs.tail), $call T.join (acc, m.ty))
  }.ret,
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
  // §7.6: `$alloc` draws from the `allocator` in lexical scope, so it reads that name
  // although it never spells it — `Pa.free_names`'s rule, which this copy lacked. A closure
  // that allocated from a local arena captured nothing, and its `$alloc` then read the
  // enclosing frame's slot of that number from its own frame.
  $case {$prop tag "form"}
    ($call free_names_list ($call Pa.nodes.val (n.operands),
        $if ($call eq_str (n.keyword, "alloc"))
            ($if ($call mem_str (acc, "allocator")) acc ($call strs.cons ("allocator", acc)))
            acc)),
  $case {$prop tag "group"} ($call free_names_list ($call Pa.nodes.val (n.items), acc)),
  $case {$prop tag "block"} ($call free_names_list ($call Pa.nodes.val (n.items), acc)),
  $case {$prop tag "proj_name"}  ($call free_names (n.target, acc)),
  $case {$prop tag "proj_index"} ($call free_names (n.target, acc)),
  $case n acc
)

$decl caps $func ($decl ns strs.node, $decl e benv.node, $decl acc benv.node) $match ns (
  $case {$prop tag "cons"} {
    $decl f $call lookup (e, ns.head)
    $decl keep $if f.hit
        ($if ($call eq_str (f.bnd.kind, "local")) true
             ($call eq_str (f.bnd.kind, "capture")))
        false
    $decl ret $call caps (ns.tail, e,
                $if keep ($call benv.cons ($call bind_ent6 (f.bnd.name, f.bnd.kind, f.bnd.slot,
                              f.bnd.ty, f.bnd.mod, f.bnd.tmpl), acc)) acc)
  }.ret,
  $case ns acc
)

// The captured values, as expressions in the *enclosing* frame — §7.3's copy
// happens where the literal stood.
$decl cap_exprs $func ($decl st proto_lst, $decl cs benv.node, $decl acc IR.exprs.node) $match cs (
  $case {$prop tag "cons"} {
    $decl id $call intern (st, cs.head.ty)
    $decl ir $if ($call eq_str (cs.head.kind, "local"))
                 ($call IR.e_local (id, cs.head.slot))
                 ($call IR.e_capture (id, cs.head.slot))
    $decl ret  $call cap_exprs (st, cs.tail, $call IR.exprs.cons (ir, acc))
  }.ret,
  $case cs ($call IR.exprs.reverse (acc, IR.exprs.nil))
)

$decl cap_tys $func ($decl st proto_lst, $decl cs benv.node, $decl acc IR.ints.node) $match cs (
  $case {$prop tag "cons"}
    $call cap_tys (st, cs.tail,
        $call IR.ints.cons ($call intern (st, cs.head.ty), acc)),
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
      $case {$prop tag "cons"} {
        $decl rest $call IR.ints.val (ds.tail)
        $decl ret $match rest (
            // More than one member: the narrowed type is their union, which
            // is what the scrutinee already has, so there is nothing to bind.
            $case {$prop tag "cons"} ($call narrowed (e, -1)),
            $case rest {
              $decl mt $call T.tys.nth (ms, ds.head)
              $decl sl $call fresh_slot (st, $call intern (st, mt))
              $decl ret2  $call narrowed (
                  $call benv.cons ($call bind_ent (nm, "local", sl, mt), e), sl)
            }.ret2
          )
      }.ret,
      $case ds ($call narrowed (e, -1))
    ))

$decl lower_arms $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node,
                        $decl tail  P.boolean, $decl ms T.tys.node, $decl nm "",
                        $decl taken IR.ints.node, $decl acc IR.arms.node,
                        $decl ty    T.proto_ty) $match xs (
  $case {$prop tag "cons"} {
    $decl pty  $call pattern_ty (st, e, $call op (xs.head, 0))
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
    $decl ret  $match rest (
        $case {$prop tag "cons"}
          $call lower_arms (st, e, rest, tail, ms, nm, $call append_ints (ds, taken),
              acc2, ty2),
        $case rest ($call arms_res ($call IR.arms.reverse (acc2, IR.arms.nil),
                        $call IR.e_unit ($call intern (st, T.t_unit)), ty2))
      )
  }.ret,
  $case xs ($call arms_res ($call IR.arms.reverse (acc, IR.arms.nil), $call IR.e_unit (0), ty))
)

// §3.2: "`$if` is `$match` over them". A boolean carries no discriminator of
// its own — its value *is* the answer — so a `$match` on one lowers to an `$if`
// rather than to a switch, and the question of which member sits at which
// index never arises.
$decl arm_for $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node,
                     $decl want T.proto_ty) $match xs (
  $case {$prop tag "cons"} {
    $decl pty $call pattern_ty (st, e, $call op (xs.head, 0))
    $decl ret $if ($call T.sub (want, pty)) ($call op (xs.head, 1))
                ($call arm_for (st, e, $call Pa.nodes.val (xs.tail), want))
  }.ret,
  $case xs ($call Pa.n_err ("no arm covers this boolean", 0, 0))
)

$decl lower_bool_match $func ($decl st proto_lst, $decl e benv.node, $decl scrut proto_lres,
                              $decl items Pa.nodes.node, $decl tail P.boolean) {
  $decl t   $call lval ($call lower (st, e, $call arm_for (st, e, items, T.t_true), tail))
  $decl f   $call lval ($call lower (st, e, $call arm_for (st, e, items, T.t_false), tail))
  $decl ty  $call T.join (t.ty, f.ty)
  $decl ret $call lres ($call IR.e_if ($call intern (st, ty), scrut.ir, t.ir, f.ir), ty)
}.ret

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
        $call strs.cons ($call Pa.generic_name (xs.head), acc)),
  $case xs ($call strs.reverse (acc, strs.nil))
)

// §2.3: with one generic the whole operand is the name; with several it is a
// group.
$decl generic_names $func ($decl n Pa.proto_node, $decl acc strs.node) $match n (
  $case {$prop tag "name"}  ($call strs.cons (n.text, acc)),
  $case {$prop tag "group"} ($call generic_names_list ($call Pa.nodes.val (n.items), acc)),
  // `($decl K bound)`: lowering reads the name; the bound is inference's to check (§4.9).
  $case {$prop tag "form"}  ($call strs.cons ($call Pa.generic_name (n), acc)),
  $case n acc
)

$decl gen_props $func ($decl gs strs.node, $decl xs Pa.nodes.node, $decl acc mprops.node)
  $match gs (
    $case {$prop tag "cons"} $match xs (
      $case {$prop tag "cons"}
        $call gen_props (gs.tail, $call Pa.nodes.val (xs.tail),
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
  $case {$prop tag "cons"} {
    $decl a $call type_only (st, e, xs.head)
    $decl ret $call arg_keys (st, e, $call Pa.nodes.val (xs.tail),
                $call IR.ints.cons ($call intern (st, a.ty), acc))
  }.ret,
  $case xs ($call IR.ints.reverse (acc, IR.ints.nil))
)

// A specialisation's **stable name**: the template's key and the structural hashes of
// its arguments, e.g. `prelude_list_4172…`. §4.9 identifies a specialisation by its
// argument types and nothing else, and `T.hash_of` is a function of a type's structure
// — so this is the same identity the memo uses, spelled as a name.
//
// It replaces no name at all. `spec_build` used to create the generics module with
// `fresh_mod`, which passes an **empty path**, and `fn_key` maps `mod ""` to `"e"` — so
// `$specialize P.list Int`'s `cons` took the *entry file's* name and shared its rank
// counter. Two consequences, both fatal to caching a module: the name depended on which
// module reached the specialisation first, and the functions landed in the entry file's
// output while two other modules' outputs called them.
$decl spec_hash $func ($decl st proto_lst, $decl ks IR.ints.node, $decl acc 0) $match ks (
  $case {$prop tag "cons"}
    $call spec_hash (st, $call IR.ints.val (ks.tail),
        $call T.hmix (acc, $call T.hash_of ($call ty_at (st, ks.head)))),
  $case ks acc
)

// `vk` is hashed in too; empty, it hashes to nothing, so a template with no
// compile-time generic keeps the name it always had.
$decl spec_key $func ($decl st proto_lst, $decl r proto_tmpl, $decl ks IR.ints.node)
  $call concat (r.key, $call concat ("_",
      $call int_to_str ($call spec_hash (st, ks,
          $call T.hash_str (r.vk, 0, $call T.hash_str (r.key, 0, 0))))))

$decl infer_key $func ($decl st proto_lst, $decl i 0, $decl ks IR.ints.node,
    $decl acc "") $match ks (
  $case {$prop tag "cons"}
    $call infer_key (st, i, $call IR.ints.val (ks.tail),
        $call concat (acc, $call concat ("|", $call T.show ($call ty_at (st, ks.head))))),
  $case ks ($call concat ($call int_to_str (i), acc))
)

// Inference's memo key for this specialisation, value part included — exactly
// `infer.mpl`'s `memo_key` followed by its `ct_vals`.
$decl spec_ictx $func ($decl st proto_lst, $decl r proto_tmpl, $decl ks IR.ints.node)
  $call concat ($call infer_key (st, r.iid, ks, ""), r.vk)

$decl spec_build_props $func ($decl st proto_lst, $decl e benv.node, $decl r proto_tmpl,
                        $decl args Pa.nodes.node, $decl keys IR.ints.node,
                        $decl n    Pa.proto_node) {
  $decl sk $call spec_key (st, r, keys)
  // The key goes in as the module's `path`, which is what `mod_short` reads when a
  // member of it is lowered — and `mod_short` is the identity on a name with no
  // directory and no `.mpl`, so the members come out named from the specialisation.
  $decl gm $call fresh_mod_gen (st, $call gen_props (r.generics, args, mprops.nil), e,
               sk, r.file)
  $decl be $call with_gens (r.env, $call strs.val (r.generics), gm)
  // Entered around the body, not only around each member: the body is a block with
  // props, and `const_of` gives each one its compile-time identity from the module
  // in scope. Without this the props of `P.list Int` and `P.list Str` would be
  // identified by whoever happened to be lowering when they were first reached.
  // Inference's memo key for the same specialisation (`infer.mpl`'s `memo_key`):
  // the template's id, then each argument type rendered. Every identity minted in
  // the body hashes it, exactly as inference's `sctx` does.
  $decl ms $call enter_mod_in (st, sk, r.file, $call spec_ictx (st, r, keys))
  $decl v0 $call lval ($call lower (st, be, r.body, false))
  $decl mr $call leave_mod (st, ms)
  $decl v  v0
  $decl ok $if ($call lt (v.mod, 0))
      ($call err (st, "$specialize: this template's body is not a block with props or $decls, which is the only shape lowered so far", n))
      0
  $decl sp  $call add_spec (st, $call spec_ent_v (r.id, keys, v.mod, v.ty, r.vk))
  $decl ret v
}.ret

// A second use of the same specialisation. §4.9 memoises per argument type, so
// this shares the first one's module — and therefore its lifted functions,
// which is the whole point: one `cons` per element type, not one per mention.
// The value is rebuilt rather than shared, because a node index belongs to one
// node (§9.3).
$decl spec_reuse $func ($decl st proto_lst, $decl sp proto_spec) {
  $decl bt  $call T.tval (sp.bty)
  $decl ret $call lres3 ($call IR.e_block ($call intern (st, bt), IR.bslots.nil), bt, sp.mod)
}.ret

// ------------------------------------------ a template body with `$decl`s (§4.9)
//
// §4.9: "Typing is memoized per argument type; values are not." A body that builds
// anything at run time — a `$decl`, or a §3.3 effect — is evaluated where the
// `$specialize` stands, like a block literal written there, so each use lowers its
// items into **this** frame. Its props are compile-time and part of the type, so
// they are shared: the props module is made once per argument type and reused,
// which is what keeps a prop function lifted once rather than once per mention.
//
// Step 1 evaluates each argument **once** and binds it to its generic: the
// argument is lowered at the site, into a slot of its own, and the generic names
// that slot. (The props-only path binds a generic to the argument's *source* and
// lowers it at each mention, which is right there and only there: §4.10 lets a
// prop mention a generic only in a type-only position, never evaluated.)
$decl inst_items $func ($decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call is_form (xs.head, "prop")) ($call inst_items ($call Pa.nodes.val (xs.tail))) true,
  $case xs false
)

$decl inst_body $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "block"} ($call inst_items ($call Pa.nodes.val (n.items))),
  $case n false
)

$decl body_items $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "block"} ($call Pa.nodes.val (n.items)),
  $case n Pa.nodes.nil
)

$decl drop_props $func ($decl xs Pa.nodes.node, $decl acc Pa.nodes.node) $match xs (
  $case {$prop tag "cons"}
    $call drop_props ($call Pa.nodes.val (xs.tail),
        $if ($call is_form (xs.head, "prop")) acc ($call Pa.nodes.cons (xs.head, acc))),
  $case xs ($call Pa.nodes.reverse (acc, Pa.nodes.nil))
)

// The props' compile-time values, newest first — the order `lower_item` builds them in.
$decl inst_props $func ($decl st proto_lst, $decl xs Pa.nodes.node,
    $decl acc T.props.node) $match xs (
  $case {$prop tag "cons"}
    $call inst_props (st, $call Pa.nodes.val (xs.tail),
        $if ($call is_form (xs.head, "prop"))
            ($call T.props.cons ($call T.prop_entry ($call name_of ($call op (xs.head, 0)),
                 $call const_of (st, $call op (xs.head, 1))), acc))
            acc),
  $case xs acc
)

$decl props_of_ty $func ($decl t0 T.proto_ty) {
  $decl t $call T.unroll (t0)
  $decl ret $match t (
      $case {$prop tag "block"} ($call T.props.val (t.props)),
      $case t T.props.nil
    )
}.ret

// The generics, each bound to a slot holding its argument's value.
$decl gen_acc $func ($decl en benv.node, $decl sl IR.bslots.node, $decl fl T.fields.node)
  { $decl env en  $decl slots sl  $decl flds fl }
$decl proto_genacc $call gen_acc (benv.nil, IR.bslots.nil, T.fields.nil)

$decl bind_args $func ($decl st proto_lst, $decl site benv.node, $decl gs strs.node,
                       $decl xs Pa.nodes.node, $decl a proto_genacc) $match gs (
  $case {$prop tag "cons"} $match xs (
    $case {$prop tag "cons"} {
      $decl v  $call lval ($call lower (st, site, xs.head, false))
      $decl id $call intern (st, v.ty)
      $decl sl $call fresh_slot (st, id)
      $decl a2 $call gen_acc (
          $call benv.cons ($call bind_ent6 (gs.head, "local", sl, v.ty, v.mod, v.tmpl),
              $call benv.val (a.env)),
          $call IR.bslots.cons ($call IR.bslot (sl, v.ir), $call IR.bslots.val (a.slots)),
          $call T.fields.cons ($call T.field (gs.head, v.ty), $call T.fields.val (a.flds)))
      $decl ret  $call bind_args (st, site, $call strs.val (gs.tail), $call Pa.nodes.val (xs.tail),
          a2)
    }.ret,
    $case xs a),
  $case gs a
)


$fwd spec_inst

// A later use. Entered exactly as the first was, so what its items lift is named and
// placed with the template (§4.9 makes an instantiation the template's code).
$decl spec_reuse_inst $func ($decl st proto_lst, $decl e benv.node, $decl r proto_tmpl,
                             $decl args Pa.nodes.node, $decl keys IR.ints.node,
                             $decl sp   proto_spec, $decl n Pa.proto_node) {
  $decl sk  $call spec_key (st, r, keys)
  $decl ms  $call enter_mod_in (st, sk, r.file, $call spec_ictx (st, r, keys))
  $decl v   $call lval ($call spec_inst (st, e, r, args, -1, sp.mod, sp.bty, false, n))
  $decl mr  $call leave_mod (st, ms)
  $decl ret v
}.ret

$decl spec_build_inst $func ($decl st proto_lst, $decl e benv.node, $decl r proto_tmpl,
                             $decl args Pa.nodes.node, $decl keys IR.ints.node,
                             $decl n    Pa.proto_node) {
  $decl sk $call spec_key (st, r, keys)
  $decl gm $call fresh_mod_gen (st, $call gen_props (r.generics, args, mprops.nil), e,
               sk, r.file)
  // In progress: a use reached while the body's own items are being lowered is the
  // body reaching itself, which §4.9 makes evaluate without bound.
  $decl pg  $call add_spec (st, $call spec_ent_v (r.id, keys, -2, T.t_bot, r.vk))
  $decl ms  $call enter_mod_in (st, sk, r.file, $call spec_ictx (st, r, keys))
  $decl v   $call lval ($call spec_inst (st, e, r, args, gm, -1, T.t_bot, true, n))
  $decl mr  $call leave_mod (st, ms)
  $decl sp  $call add_spec (st, $call spec_ent_v (r.id, keys, v.mod, v.ty, r.vk))
  $decl ret v
}.ret

// §4.9's compile-time generics, lowering's half — the same scan as inference
// (`Pa.ct_generics`) with lowering's way of resolving a `$specialize`'s target. The
// answer is kept on the template's record, which the snapshot rolls back with it.
$fwd tmpl_ctg

// The identity at `proto_tmpl`: `tmpl_ctg`'s result is §5.5's placeholder above its
// completion, and projecting off one fails.
$decl tmpl_val $func ($decl r proto_tmpl) r

$decl ctg_target_l $func ($decl st proto_lst, $decl en benv.node, $decl own 0, $decl gs strs.node,
                          $decl cur Pa.ctgs.node, $decl x Pa.proto_node) {
  $decl v   $call type_only (st, en, x)
  $decl ret $if ($call eq_int (v.tmpl, own)) ($call Pa.ctg_mask (gs, cur, Pa.pstrs.nil))
      ($if ($call lt (v.tmpl, 0)) Pa.pstrs.nil {
        $decl hit $call find_tmpl ($call eval_tmpls (st.tmpls), v.tmpl)
        $decl ret2 $match hit (
            $case {$prop tag "cons"} {
              $decl rr   $call tmpl_val ($call tmpl_ctg (st, hit.head))
              $decl ret3 $call Pa.ctg_mask (rr.generics, rr.ctg, Pa.pstrs.nil)
            }.ret3,
            $case hit Pa.pstrs.nil
          )
      }.ret2)
}.ret

$decl ctg_fix_l $func ($decl st proto_lst, $decl r proto_tmpl, $decl cur Pa.ctgs.node, $decl k 0) {
  $decl rs $func ($decl x Pa.proto_node) $call ctg_target_l (st, r.env, r.id, r.generics, cur, x)
  $decl nx $call Pa.ct_generics (r.body, r.generics, rs)
  $decl ret $if ($call P.or ($call eq_int ($call Pa.ctgs.length (nx, 0), $call Pa.ctgs.length (cur,
      0)),
                          $call lt (k, 1)))
      nx ($call ctg_fix_l (st, r, nx, $call isub (k, 1)))
}.ret

$decl tmpl_ctg $func ($decl st proto_lst, $decl r proto_tmpl)
  $if r.ctok r {
    $decl busy $set st.tmpls ($call tmpls_list.cons ($call tmpl_rec_x (r.id, r.generics, r.body,
                   r.env, r.key, r.file, r.iid, Pa.ctgs.nil, true, ""),
                       $call eval_tmpls (st.tmpls)))
    $decl cg   $call ctg_fix_l (st, r, Pa.ctgs.nil, $call strs.length (r.generics, 0))
    $decl done $call tmpl_rec_x (r.id, r.generics, r.body, r.env, r.key, r.file, r.iid, cg, true,
        "")
    $decl kept $set st.tmpls ($call tmpls_list.cons (done, $call eval_tmpls (st.tmpls)))
    $decl ret  done
  }.ret

// `infer.mpl`'s `ct_vals`, spelled the same way: a literal by its text, anything else
// by where it is written — `opaque_at` is inference's `ct_id` with tag 3.
$decl spec_vals $func ($decl st proto_lst, $decl gs strs.node, $decl args Pa.nodes.node,
                       $decl cg Pa.ctgs.node, $decl acc "") $match gs (
  $case {$prop tag "cons"} $match args (
    $case {$prop tag "cons"} {
      $decl p  $call Pa.ctg_prop (cg, gs.head)
      $decl lk $call Pa.lit_key (args.head)
      $decl v  $if ($call eq_str (p, "")) ""
                   ($if ($call eq_str (lk, ""))
                        ($call concat ("=@", $call int_to_str ($call opaque_at (st, args.head))))
                        ($call concat ("=", lk)))
      $decl ret  $call spec_vals (st, gs.tail, $call Pa.nodes.val (args.tail), cg,
          $call concat (acc,
          v))
    }.ret,
    $case args acc),
  $case gs acc
)

$decl subst_ct_l $func ($decl body Pa.proto_node, $decl gs strs.node, $decl args Pa.nodes.node,
                        $decl cg Pa.ctgs.node) $match gs (
  $case {$prop tag "cons"} $match args (
    $case {$prop tag "cons"}
      $call subst_ct_l (
          $if ($call and ($call not ($call eq_str ($call Pa.ctg_prop (cg, gs.head), "")),
                          $call not ($call eq_str ($call Pa.lit_key (args.head), ""))))
              ($call Pa.subst_lit (body, gs.head, args.head)) body,
          gs.tail, $call Pa.nodes.val (args.tail), cg),
    $case args body),
  $case gs body
)

// §4.9 lets a template's body be any expression, and the build paths below lower a
// block. A `$func` body is lowered as the block `{ $prop $fn <body> }` and the function
// read back off it, which makes it a prop function: lifted once per memo key, and named
// and placed with the specialisation, exactly as `P.list`'s members are. `$fn` cannot be
// written in source — an identifier may not start with `$` (§2.1) — so no template
// written as such a block is mistaken for one. Wrapped here rather than where the
// template is recorded, so `tmpl_ctg` reads the body as written, which is what
// inference's compile-time generics are computed from.
$decl fn_wrap $func ($decl b Pa.proto_node) {
  $decl sp  $call P.span_of (b)
  $decl ret $call Pa.n_block ($call Pa.nodes.cons ($call Pa.n_form ("prop",
                $call Pa.nodes.cons ($call Pa.n_name ("$fn", sp.line, sp.col),
                    $call Pa.nodes.cons (b, Pa.nodes.nil)), sp.line, sp.col), Pa.nodes.nil),
                sp.line, sp.col)
}.ret

$decl spec_args $func ($decl st proto_lst, $decl e benv.node, $decl r proto_tmpl,
                       $decl args Pa.nodes.node, $decl n Pa.proto_node) {
  $decl ret {
        $decl keys $call arg_keys (st, e, args, IR.ints.nil)
        $decl r0   $call tmpl_ctg (st, r)
        $decl b0   $call subst_ct_l (r0.body, r0.generics, args, r0.ctg)
        $decl isfn $call is_form (b0, "func")
        $decl r    $call tmpl_rec_x (r0.id, r0.generics, $if isfn ($call fn_wrap (b0)) b0,
                       r0.env, r0.key, r0.file, r0.iid, r0.ctg, true,
                       $call spec_vals (st, r0.generics, args, r0.ctg, ""))
        $decl hit  $call find_spec (st.specs, r.id, keys, r.vk)
        $decl inst $call inst_body (r.body)
        $decl ret2 $match hit (
            $case {$prop tag "cons"}
              $if inst
                  ($if ($call eq_int (hit.head.mod, -2))
                       ($call lres ($call IR.e_unit ($call err (st,
                            "$specialize: this specialisation's own $decls reach it again; §4.9 makes that evaluate without bound, and lowering it through a $func is not done yet", n)),
                            T.t_bot))
                       ($call spec_reuse_inst (st, e, r, args, keys, hit.head, n)))
                  ($call spec_reuse (st, hit.head)),
            $case hit
              $if inst ($call spec_build_inst (st, e, r, args, keys, n))
                  ($call spec_build_props (st, e, r, args, keys, n))
          )
        $decl ret3 $if ($if isfn ($call lt (-1, ret2.mod)) false)
                       ($call lower_prop (st, ret2.mod, "$fn", n)) ret2
      }.ret3
}.ret

$decl spec_with $func ($decl st proto_lst, $decl e benv.node, $decl r proto_tmpl,
                       $decl argn Pa.proto_node, $decl n Pa.proto_node) {
  $decl ng   $call strs.length (r.generics, 0)
  $decl args $if ($call eq_int (ng, 1)) ($call Pa.nodes.cons (argn, Pa.nodes.nil))
                 ($call group_items (argn))
  $decl na   $call Pa.nodes.length (args, 0)
  $decl ret  $if ($call not ($call eq_int (ng, na)))
      ($call lres ($call IR.e_unit ($call err (st, $call concat ("this template has ",
           $call concat ($call int_to_str (ng), $call concat (" generic parameters, found ",
           $call int_to_str (na)))), n)), T.t_bot))
      ($call spec_args (st, e, r, args, n))
}.ret

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
// ------------------------------------------------------- §3.3's top-level effects
//
// "A non-`$decl` expression runs for effect and is discarded" — the *value* is
// discarded, not the expression. §4.10 runs a file's items once in **source
// order**, so such an item has a position among them, and a backend that drops
// it produces a program missing whatever it did. `parser.mpl` builds §2.2's
// arity table with twenty-three of them; without them the compiled parser
// reports `unknown keyword '$decl'` for every form in its input.
//
// `after` is the index in the function table before whose initialisation the
// effect runs. For a file's own item that is the *field* index — §4.11 is why
// it cannot be the item's index, since a `$fwd` takes a field at its own
// position and the `$decl` completing it takes none. For a module's item it is
// the effect's own lifted index, which sits between the member lowered before
// it and the one lowered after. Both say the same thing to `emit_inits`.
$decl lower_effect $func ($decl st proto_lst, $decl e benv.node, $decl n Pa.proto_node,
                          $decl after 0) {
  $decl o   $call take_slots (st)
  $decl idx $call reserve_lifted (st)
  // In tail position: this is a whole function body, so §7.7 applies to it
  // exactly as it does to a thunk's. `verify` reports every unmarked tail
  // call otherwise, which is how the `false` here was found. A `$defer` is registered
  // to run at the program's exit, and storage with deferrals goes through the owner
  // walk (DEFER.md example 12).
  $decl v   $if ($call is_form (n, "defer"))
      ($call lres ($call IR.eval ($call exit_reg (st, $call dfr_ent ($call op (n, 0), e, "", -1),
           true)), T.t_unit))
      ($if ($call Pa.storage_defers (n)) ($call lval ($call top_item (st, e, n)))
           ($call lval ($call lower (st, e, n, true))))
  // Not a thunk: a thunk *is* a global and is named by its static. This has
  // no name and nothing reads it, so it is an ordinary zero-argument
  // function that is called and whose result is dropped.
  $decl f   $call IR.fn_p ("(top-level effect)", IR.ints.nil, $call intern (st, v.ty),
                $call take_slots (st), v.ir, false, false, IR.ints.nil,
                $call P.sval (st.curfile), $call next_rank (st), false,
                $call P.sval (st.curmod))
  $decl put $call put_lifted (st, idx, f)
  $decl b   $call restore_slots (st, o)
  // A module's effect is placed by its **source position**, encoded as `-1 - pos`
  // so a negative still says "module": the same numbering a member's rank uses,
  // which is what lets a module's initialiser interleave the two (`emit_mod_init`).
  // It was the effect's lifted index, which is source order only while members are
  // lowered in source order — and a `$fwd`'d function lowered early pulls later
  // members forward, so it is not.
  $decl inm $call lt (after, 0)
  $decl at  $if inm ($call isub (-1, after)) after
  $decl s   $set st.effs ($call IR.effects.cons ($call IR.effect (at, idx, inm),
                 $call IR.effects.val (st.effs)))
  $decl ret   0
}.ret

// A file's own items, paired with the field they stand before. Counting a name
// only the first time it is bound is exactly the rule that builds the field
// list, which is what makes the two agree across §4.11's `$fwd`.
$decl eff_item  $func ($decl a 0, $decl n Pa.proto_node) { $decl after a  $decl node n }
$decl proto_eff_item $call eff_item (0, Pa.proto_node)
$decl eff_items $specialize P.list proto_eff_item

$decl binder_of $func ($decl n Pa.proto_node)
  $if ($call is_form (n, "decl")) ($call name_of ($call op (n, 0)))
      ($if ($call is_form (n, "fwd")) ($call name_of ($call op (n, 0))) "")

// A `$prop` is in **neither** of the two categories this walk sorts items into, and
// treating it as the second was half of why a top-level prop did not lower. It binds
// a name, so it is not a §3.3 bare expression — but the name goes in the block's
// *props*, not its fields (§4.10: "a prop is in the block's namespace and type, not
// its layout"), so counting it would desynchronise `k` from the field list that
// `after` indexes. Skipped outright: `lower_file` registers the props as a module of
// their own instead.
$decl scan_effects $func ($decl xs Pa.nodes.node, $decl k 0, $decl seen strs.node,
                          $decl acc eff_items.node) $match xs (
  $case {$prop tag "cons"} {
    $decl pr $call is_form (xs.head, "prop")
    $decl nm $if pr "" ($call binder_of (xs.head))
    $decl new $call and ($call not ($call eq_str (nm, "")),
                  $call not ($call mem_str (seen, nm)))
    $decl ret   $call scan_effects ($call Pa.nodes.val (xs.tail),
                  $if new ($call add (k, 1)) k,
                  $if new ($call strs.cons (nm, seen)) seen,
                  $if ($call and ($call not (pr), $call eq_str (nm, "")))
                      ($call eff_items.cons ($call eff_item (k, xs.head), acc)) acc)
  }.ret,
  $case xs ($call eff_items.reverse (acc, eff_items.nil))
)

// Everything standing before field `k`, lowered here so it sees exactly the
// names bound so far (§4.10). The remainder is handed back so the walk over
// the fields keeps its place.
$decl eff_split $func ($decl st proto_lst, $decl e benv.node, $decl xs eff_items.node,
                       $decl k 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call lt (k, xs.head.after)) xs
        ($do ($call lower_effect (st, e, xs.head.node, xs.head.after))
             ($call eff_split (st, e, $call eff_items.val (xs.tail), k))),
  $case xs xs
)

// completing `$decl` gives it — and the completing `$decl` is then skipped,
// having already been counted. That ordering is what `with_scope` reads.
$decl file_props_at $func ($decl all Pa.nodes.node, $decl xs Pa.nodes.node,
                           $decl acc mprops.node) $match xs (
  $case {$prop tag "cons"} {
    $decl nm  $if ($call is_form (xs.head, "fwd"))
          ($call name_of ($call op (xs.head, 0)))
          ($if ($call is_form (xs.head, "decl")) ($call name_of ($call op (xs.head, 0)))
               ($if ($call is_form (xs.head, "prop")) ($call name_of ($call op (xs.head, 0))) ""))
    // §3.3: an item that binds nothing is not skipped — it runs for effect,
    // and it has to keep its place among the members so §4.10's order holds.
    $decl bare $call eq_str (nm, "")
    $decl seen $if bare false
                   ($call not ($call mprops.is_nil ($call find_mprop (acc, nm))))
    $decl a2 $if bare ($call mprops.cons ($call mprop ("", xs.head, "effect"), acc))
        ($if seen acc
        ($if ($call is_form (xs.head, "fwd"))
             ($call mprops.cons ($call mprop (nm,
                  $call op ($call find_completing (all, nm), 1), "decl"), acc))
        ($if ($call is_form (xs.head, "prop"))
             ($call mprops.cons ($call mprop (nm, $call op (xs.head, 1), "prop"), acc))
             ($call mprops.cons ($call mprop (nm, $call op (xs.head, 1), "decl"), acc)))))
    $decl ret $call file_props_at (all, $call Pa.nodes.val (xs.tail), a2)
  }.ret,
  $case xs ($call mprops.reverse (acc, mprops.nil))
)

$decl file_props $func ($decl xs Pa.nodes.node, $decl acc mprops.node)
  $call file_props_at (xs, xs, acc)

// The entry file's `$prop` items, and **only** those. `file_props` takes every member
// because §4.14 answers a projection onto a module for all of them; the entry file is
// not projected onto, and its `$decl`s must stay globals — they have layout slots,
// §4.10's statics and an initialisation order that `lower_top` is what implements.
// So the props alone are registered, and everything else is untouched.
$decl top_props $func ($decl xs Pa.nodes.node, $decl acc mprops.node) $match xs (
  $case {$prop tag "cons"}
    $call top_props ($call Pa.nodes.val (xs.tail),
        $if ($call is_form (xs.head, "prop"))
            ($call mprops.cons ($call mprop ($call name_of ($call op (xs.head, 0)),
                 $call op (xs.head, 1), "prop"), acc))
            acc),
  $case xs ($call mprops.reverse (acc, mprops.nil))
)

// §4.10's source order, which for a module is what `force_props` *is*: each
// member's thunk takes the next lifted index, so index order is source order.
// An effect takes one of those indices too and `mpl_init` runs it there, which
// is how it lands between the member before it and the member after.
$decl mod_effect $func ($decl st proto_lst, $decl mid 0, $decl pn Pa.proto_node, $decl pos 0) {
  $decl ms $call find_mod_st (st, mid)
  $decl ret $match ms (
      $case {$prop tag "cons"} {
        // A **fourth** place that lowers a module's code, beside the three
        // `lower_prop_*`. Without entering the module here, the effect's function is
        // attributed to the entry file, and a per-module initialiser never claims it —
        // `stage1/fixtures/effect.mpl` answers 4 instead of 46, which is exactly what
        // "dropped" looks like.
        $decl pe    $call benv.val (ms.head.penv)
        $decl msave $call enter_mod_in (st, $call mod_short (ms.head.path), ms.head.file,
            ms.head.isctx)
        $decl ret2  $call lower_effect (st, pe, pn, $call isub (-1, pos))
        $decl mrest $call leave_mod (st, msave)
      }.ret2,
      $case ms 0
    )
}.ret

// `pos` is the item's position in the module, which is the rank a member is named by
// (`prop_rank`) and so the order its initialiser runs in.
$decl force_props $func ($decl st proto_lst, $decl mid 0, $decl xs mprops.node,
                         $decl n Pa.proto_node, $decl pos 0) $match xs (
  $case {$prop tag "cons"}
    $do ($if ($call eq_str (xs.head.kind, "effect"))
             ($call mod_effect (st, mid, xs.head.node, pos))
             ($do ($call lower_prop (st, mid, xs.head.name, n)) 0))
        ($call force_props (st, mid, xs.tail, n, $call add (pos, 1))),
  $case xs 0
)

// §4.14 makes `$import` evaluate to the file's block, and §4.5 makes that block a
// record like any other — so a module's value has the layout its type says: its
// `$decl` members in source order (§7.2), each slot initialised from the global the
// member was lifted to, and its `$prop`s in the type (§4.10).
//
// It used to be the empty block. A projection never noticed, because `lower_proj`
// asks the module before the type and resolves `M.f` to the member's global without
// reading the value — which is still how a projection works, so naming a member costs
// what it did. But inference types the import with every member as a field, so
// anything else that received the value disagreed with it: a module passed to a
// function emitted a field read of a struct with no fields, which `cc` rejected, and
// `$new M` was refused here with "no field" for a program inference had accepted.
// Stage 0 ran both.
//
// **Memoised per module, and the first version shows why.** Building the record at
// every `$import` made the compiler emit itself in 3m50s against 26s: interning a
// record compares it structurally (`T.same` was 70% of the profile), a member's type
// that mentions `proto_ty` is enormous, and there is no pointer equality to stop a
// comparison of a type with itself. So the first build interns, and the rest reuse the
// record's type and its members' indices from `mrec`. Building it only where the value
// is *used* as one was tried too, and cost more than it saved: it needs the decision in
// `lower_name`/`lower`'s dispatch, and any edge from there put more of this file inside
// the first passes §5.5 rolls back — importing `lower` as a module went from 24s to out
// of memory.
//
// Every member is read off `done`, which `force_props` filled when the module was
// loaded — not through `lower_prop`, for the same reason. A member that is a module is
// already its record, since that member's own `$import` built it.
$decl racc $func ($decl sl IR.bslots.node, $decl fl T.fields.node, $decl pr T.props.node,
                  $decl fs IR.ints.node, $decl ok P.boolean)
  { $decl slots sl  $decl flds fl  $decl prps pr  $decl fids fs  $decl settled ok }
$decl proto_racc $call racc (IR.bslots.nil, T.fields.nil, T.props.nil, IR.ints.nil, true)

// A `$decl` member's node at the type index `ti`. A `$template` member has no runtime
// value (§4.9), so its slot holds the empty block.
$decl member_ir $func ($decl ds mdones.node, $decl nm "", $decl ti 0) {
  $decl d $call find_mdone (ds, nm)
  $decl ret $match d (
      $case {$prop tag "cons"}
        $if ($call eq_str (d.head.kind, "global")) ($call IR.e_global (ti, d.head.idx))
            ($call IR.e_block (ti, IR.bslots.nil)),
      $case d ($call IR.e_block (ti, IR.bslots.nil))
    )
}.ret

$decl member_ty $func ($decl ds mdones.node, $decl nm "") {
  $decl d $call find_mdone (ds, nm)
  $decl ret $match d (
      $case {$prop tag "cons"}
        $if ($call eq_str (d.head.kind, "global")) ($call T.tval (d.head.ty)) T.t_unit,
      $case d T.t_unit
    )
}.ret

// The first build: everything interned, and whether every member had settled — a
// member still holding §5.5's placeholder (a cycle, which inference reports) is not
// a layout, so that build is used once and not remembered.
$decl rec_build $func ($decl st proto_lst, $decl ds mdones.node, $decl xs mprops.node,
                       $decl a proto_racc) $match xs (
  $case {$prop tag "cons"} {
    $decl m  xs.head
    $decl a2 $if ($call eq_str (m.kind, "decl")) {
      $decl t  $call member_ty (ds, m.name)
      $decl ok $call not ($call T.has_var (t, 0))
      $decl ti $if ok ($call intern (st, t)) ($call intern (st, T.t_unit))
      $decl sl $call fresh_slot (st, ti)
      $decl ret2  $call racc ($call IR.bslots.cons ($call IR.bslot (sl, $call member_ir (ds, m.name,
          ti)),
                                                 $call IR.bslots.val (a.slots)),
                   $call T.fields.cons ($call T.field (m.name, t), $call T.fields.val (a.flds)),
                   $call T.props.val (a.prps),
                   $call IR.ints.cons (ti, $call IR.ints.val (a.fids)),
                   $if ok a.settled false)
    }.ret2
        // A §3.3 effect binds nothing and has run; it has no place in the value.
        ($if ($call eq_str (m.kind, "prop"))
             ($call racc ($call IR.bslots.val (a.slots), $call T.fields.val (a.flds),
                  $call T.props.cons ($call T.prop_entry (m.name, $call const_of (st, m.node)),
                                      $call T.props.val (a.prps)),
                  $call IR.ints.val (a.fids), a.settled))
             a)
    $decl ret  $call rec_build (st, ds, $call mprops.val (xs.tail), a2)
  }.ret,
  $case xs a
)

$decl ps_int $func ($decl xs IR.ints.node) $match xs ($case {$prop tag "cons"} xs.head, $case xs 0)
$decl ints_tail $func ($decl xs IR.ints.node) $match xs (
  $case {$prop tag "cons"} ($call IR.ints.val (xs.tail)),
  $case xs IR.ints.nil
)

// Every later build: the slots alone, at the indices the first one found.
$decl rec_slots $func ($decl st proto_lst, $decl ds mdones.node, $decl xs mprops.node,
                       $decl fs IR.ints.node, $decl acc IR.bslots.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.kind, "decl")) {
      $decl ti $call ps_int (fs)
      $decl sl $call fresh_slot (st, ti)
      $decl ret  $call rec_slots (st, ds, $call mprops.val (xs.tail), $call ints_tail (fs),
                   $call IR.bslots.cons ($call IR.bslot (sl, $call member_ir (ds, xs.head.name,
                       ti)), acc))
    }.ret
        ($call rec_slots (st, ds, $call mprops.val (xs.tail), fs, acc)),
  $case xs ($call IR.bslots.reverse (acc, IR.bslots.nil))
)

$decl mod_value $func ($decl st proto_lst, $decl mid 0) {
  $decl ms $call find_mod_st (st, mid)
  $decl ret $match ms (
      $case {$prop tag "cons"} {
        $decl m  ms.head
        $decl mr $call mrec_val (m.rec)
        $decl ps $call mprops.val (m.props)
        $decl ds $call mdones.val (m.done)
        $decl ret2  $if mr.has
            ($call lres3 ($call IR.e_block (mr.id, $call rec_slots (st, ds, ps, mr.fids,
                IR.bslots.nil)),
                         mr.ty, mid)) {
              // The module is entered while its props' identities are minted, so
              // every value of one module has one type — `const_of` names an
              // opaque prop by `curmod`.
              $decl msave $call enter_mod_in (st, $call mod_short (m.path), m.file, m.isctx)
              $decl a     $call rec_build (st, ds, ps, proto_racc)
              $decl reg   $call note_opaqs (st, mid, ps)
              $decl back  $call leave_mod (st, msave)
              // Fields in layout order; props as `lower_block` leaves them.
              $decl t  $call T.t_block ($call T.fields.reverse ($call T.fields.val (a.flds),
                  T.fields.nil),
                                        $call T.props.val (a.prps))
              $decl id $call intern (st, t)
              $decl fs $call IR.ints.reverse ($call IR.ints.val (a.fids), IR.ints.nil)
              $decl kept $if a.settled
                  ($call save_mod (st, $call mod_ent_g (m.id, ps, ds, $call benv.val (m.env),
                       m.base, m.path, $call benv.val (m.penv), m.file,
                       $call mrec (true, t, id, fs), m.isctx, $call dx_val (m.dix))))
                  0
              $decl ret3  $call lres3 ($call IR.e_block (id,
                           $call IR.bslots.reverse ($call IR.bslots.val (a.slots),
                               IR.bslots.nil)), t, mid)
            }.ret3
      }.ret2,
      $case ms {
        $decl t    $call T.t_block (T.fields.nil, T.props.nil)
        $decl ret2 $call lres3 ($call IR.e_block ($call intern (st, t), IR.bslots.nil), t, mid)
      }.ret2
    )
}.ret

$decl load_module $func ($decl st proto_lst, $decl key "", $decl nm "", $decl n Pa.proto_node) {
  $decl rf  $call read_file (key)
  // On the option, not on the text. Flattening it to a string made a file that could
  // not be read and a file that is *empty* the same case, so importing an empty
  // module reported "cannot read" for a file that was read perfectly well — and §3.3
  // makes an empty file a valid empty block. Matched on `some` rather than through a
  // catch-all, since §4.7's catch-all pattern is a name and does not narrow.
  $decl ret $match rf (
      $case {$prop tag "some"} {
        $decl src rf.v
        $decl p   $call Pa.parse (src)
        // §4.14: "A file sees the root block plus what it imports, nothing
        // else" — so a module is lowered in the root environment, never in
        // the importer's.
        $decl mid $call fresh_mod_at (st, $call file_props ($call Pa.nodes.val (p.exprs),
            mprops.nil),
                      $call benv.val (st.rootenv), $call P.dirname (key), key)
        $decl f   $call force_props (st, mid, $call mod_props (st, mid), n, 0)
        // Complete now, so it is appended after everything it imported.
        $decl ord $set st.morder ($call strs.cons ($call mod_short (key),
                      $call strs.val (st.morder)))
        $decl ret2   $call mod_value (st, mid)
      }.ret2,
      $case rf
        ($call lres ($call IR.e_unit ($call err (st,
             $call concat ("cannot read the file for $import \"",
             $call concat (nm, $call concat ("\" (", $call concat (key, ")")))), n)), T.t_bot))
    )
}.ret

$decl lower_import $func ($decl st proto_lst, $decl n proto_form) {
  $decl nm  $call str_of ($call op (n, 0))
  $decl key $call Pa.resolve_import ($call P.sval (st.base), $call strs.val (st.roots), nm)
  $decl hit $call find_mod_path (st.mods, key)
  $decl ret $match hit (
      // §4.14: "Loaded once. All imports of the same resolved file yield the
      // same module." A cycle finds the entry too, because it is registered
      // before its members are lowered.
      $case {$prop tag "cons"} ($call mod_value (st, hit.head.id)),
      $case hit ($call load_module (st, key, nm, n))
    )
}.ret

$decl lower_specialize $func ($decl st proto_lst, $decl e benv.node, $decl n proto_form) {
  $decl f  $call lval ($call lower (st, e, $call op (n, 0), false))
  $decl ts $if ($call lt (f.tmpl, 0)) tmpls_list.nil
               ($call find_tmpl (st.tmpls, f.tmpl))
  $decl ret $match ts (
      $case {$prop tag "cons"} ($call spec_with (st, e, ts.head, $call op (n, 1), n)),
      $case ts ($call lres ($call IR.e_unit ($call err (st,
          "$specialize expects a template", n)), T.t_bot))
    )
}.ret

$decl lower_match $func ($decl st proto_lst, $decl e benv.node, $decl n proto_form,
                         $decl tail P.boolean) {
  $decl sn    $call op (n, 0)
  $decl scrut $call as_value (st, $call lower (st, e, sn, false))
  $decl items $call group_items ($call op (n, 1))
  $decl ret $if ($call T.same (scrut.ty, T.t_bool))
      ($call lower_bool_match (st, e, scrut, items, tail))
  // §4.7: a trait object is not inspected, so inference has already decided that the
  // first arm is the one — it matches always, and an arm before it would have been an
  // error. Its name is the object itself, so nothing is narrowed or rebound.
  ($if ($call T.is_trait ($call T.unroll (scrut.ty))) {
    $decl body $call lval ($call lower (st, e, $call op ($call Pa.nodes.nth (items, 0), 1), tail))
    $decl ret2 $call lres ($call IR.e_do ($call intern (st, body.ty), scrut.ir, body.ir), body.ty)
  }.ret2 {
        $decl a $call lower_arms (st, e, items, tail,
                    $call members_of ($call canon_ty (st, scrut.ty)),
                    $call name_of (sn), IR.ints.nil, IR.arms.nil, T.t_bot)
        $decl ret2 $call lres (
            $call IR.e_switch ($call intern (st, a.ty), scrut.ir, a.arms, a.default), a.ty)
      }.ret2)
}.ret


// ---------------------------------------------- §3.4's defaults at a short call
//
// "Defaults are evaluated at call time when the argument is omitted" — and stage 0
// evaluates them in the *callee's* lexical scope, with no parameter bound yet. Only the
// callee's definition has that scope, so a call site cannot simply lower the default
// where it stands: its names would resolve to the caller's bindings. So a short call to
// a known function `f` calls a generated wrapper instead, lowered in `f`'s recorded
// definition context (`fdef_ent`): it takes the arguments supplied, evaluates the
// omitted defaults there, and tail-calls `f` with all of them. One wrapper per function
// and argument count, built when first wanted; `f` itself is untouched, so a full call
// costs what it did.
//
// This used to be lowered as written, and `verify` refused the arity mismatch — so a
// program inference accepted and stage 0 ran could not be compiled, which is why five
// of the stage-1 test suites never built under `mplc`.
//
// A short call through a function *value* has no knowable callee and is reported. A
// call reached before its callee's definition is recorded — a `$fwd`, or a member a
// later projection lowers — reserves the wrapper's index and is built at the end of the
// file (`resolve_wraps`), as a deferred prop read is.
$decl find_fdef $func ($decl xs fdef_list.node, $decl g 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_int (xs.head.idx, g)) xs
        ($call find_fdef ($call fdef_list.val (xs.tail), g)),
  $case xs fdef_list.nil
)

$decl find_wrap $func ($decl xs wrap_list.node, $decl g 0, $decl k 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call and ($call eq_int (xs.head.fn, g), $call eq_int (xs.head.nargs, k))) xs.head.idx
        ($call find_wrap ($call wrap_list.val (xs.tail), g, k)),
  $case xs -1
)

$decl note_fdef $func ($decl st proto_lst, $decl d proto_fdef) {
  $decl s   $set st.fdefs ($call fdef_list.cons (d, st.fdefs))
  $decl ret 0
}.ret

$decl ts_take $func ($decl xs T.tys.node, $decl k 0, $decl acc T.tys.node)
  $if ($call eq_int (k, 0)) ($call T.tys.reverse (acc, T.tys.nil))
      ($match xs (
        $case {$prop tag "cons"} ($call ts_take ($call T.tys.val (xs.tail), $call isub (k, 1),
                                     $call T.tys.cons (xs.head, acc))),
        $case xs ($call T.tys.reverse (acc, T.tys.nil))
      ))

// The wrapper's frame: its parameters first (§7.2), then whatever the defaults need.
$decl wrap_params $func ($decl st proto_lst, $decl ts T.tys.node, $decl i 0, $decl tys IR.ints.node,
                         $decl args IR.exprs.node) $match ts (
  $case {$prop tag "cons"} {
    $decl ti $call intern (st, $call T.tval (ts.head))
    $decl sl $call fresh_slot (st, ti)
    $decl ret  $call wrap_params (st, $call T.tys.val (ts.tail), $call add (i, 1),
                 $call IR.ints.cons (ti, tys), $call IR.exprs.cons ($call IR.e_local (ti, sl),
                     args))
  }.ret,
  $case ts ($call args_res ($call IR.exprs.reverse (args, IR.exprs.nil), T.tys.nil))
)

// The omitted defaults, in the callee's scope: a value position (§5.4) unless the
// parameter is storage, as for any argument (`lower_args`).
$decl wrap_defaults $func ($decl st proto_lst, $decl en benv.node, $decl ds Pa.nodes.node,
                           $decl ts T.tys.node, $decl acc IR.exprs.node) $match ds (
  $case {$prop tag "cons"} {
    $decl raw $call lval ($call lower (st, en, $call op (ds.head, 1), false))
    $decl v   $if ($call wants_ref ($call ps_head (ts))) raw ($call as_value (st, raw))
    $decl ret   $call wrap_defaults (st, en, $call Pa.nodes.val (ds.tail), $call ps_tail (ts),
                  $call IR.exprs.cons (v.ir, acc))
  }.ret,
  $case ds ($call IR.exprs.reverse (acc, IR.exprs.nil))
)

$decl nodes_drop $func ($decl xs Pa.nodes.node, $decl k 0)
  $if ($call eq_int (k, 0)) xs
      ($match xs ($case {$prop tag "cons"} ($call nodes_drop ($call Pa.nodes.val (xs.tail),
          $call isub (k, 1))),
                  $case xs xs))

$decl ts_drop $func ($decl xs T.tys.node, $decl k 0)
  $if ($call eq_int (k, 0)) xs ($call ts_drop ($call ps_tail (xs), $call isub (k, 1)))

$decl append_exprs $func ($decl xs IR.exprs.node, $decl ys IR.exprs.node)
  $call IR.exprs.reverse ($call IR.exprs.reverse (xs, IR.exprs.nil), ys)

$decl ints_of_tys $func ($decl st proto_lst, $decl ts T.tys.node,
    $decl acc IR.ints.node) $match ts (
  $case {$prop tag "cons"}
    $call ints_of_tys (st, $call T.tys.val (ts.tail), $call IR.ints.cons ($call intern (st,
        $call T.tval (ts.head)), acc)),
  $case ts ($call IR.ints.reverse (acc, IR.ints.nil))
)

// Build the wrapper for `g` taking `k` arguments, at type `fty` (the callee's). It is
// named from the callee *as written* (`wm`, `wn`): through an alias that is the alias,
// so `$call f (2)` and `$call al (3)` with `$decl al f` get two wrappers of two names
// rather than one name twice.
$decl build_wrap $func ($decl st proto_lst, $decl d proto_fdef, $decl g 0, $decl k 0,
    $decl fty T.proto_ty,
                        $decl wm "", $decl wn "") {
  $decl msave $call enter_mod_in (st, d.mod, d.file, d.isctx)
  $decl outer $call take_slots (st)
  $decl ps    $call params_of (fty)
  $decl rty   $call result_of (fty)
  $decl pv    $call wrap_params (st, $call ts_take (ps, k, T.tys.nil), 0, IR.ints.nil, IR.exprs.nil)
  $decl dv    $call wrap_defaults (st, $call benv.val (d.env),
      $call nodes_drop ($call Pa.nodes.val (d.params), k),
                  $call ts_drop (ps, k), IR.exprs.nil)
  $decl pty   $call ints_of_tys (st, $call ts_take (ps, k, T.tys.nil), IR.ints.nil)
  $decl body  $call IR.e_call ($call intern (st, rty), $call IR.e_global ($call intern (st, fty),
      g),
                  $call append_exprs (pv.irs, dv), true)
  // Exported, since a call in any module's output may want it, and placed in the
  // callee's file. Named from the callee and the argument count — `pub` puts a name
  // in the module-member space (`fn_key`'s `_m`), so ranking it off the module's
  // counter collided with a member, which `cc` rejected as conflicting types.
  $decl f     $call IR.fn_p ("defaults", pty, $call intern (st, rty), $call take_slots (st), body,
                  false, false, IR.ints.nil, $call P.sval (st.curfile), k, true,
                  $call concat ($if ($call eq_str (wm, "")) "e" wm,
                      $call concat ("_", $call concat (wn, "_dflt"))))
  $decl back  $call restore_slots (st, outer)
  $decl mrest $call leave_mod (st, msave)
  $decl ret   f
}.ret

// The wrapper's index for `g` with `k` arguments: memoised, built now when `g`'s
// definition is known, and otherwise reserved and built at the end of the file.
$decl wrapper_for $func ($decl st proto_lst, $decl g 0, $decl k 0, $decl fty T.proto_ty,
    $decl n Pa.proto_node) {
  $decl hit $call find_wrap ($call wrap_list.val (st.wraps), g, k)
  $decl ret $if ($call not ($call lt (hit, 0))) hit {
    $decl ds $call find_fdef ($call fdef_list.val (st.fdefs), g)
    $decl w  $match ds (
        $case {$prop tag "cons"} ($call add_lifted (st, $call build_wrap (st, ds.head, g, k, fty,
                                     ds.head.mod, ds.head.name))),
        $case ds {
          $decl rw $call reserve_lifted (st)
          $decl pq $set st.wpends ($call wrap_list.cons ($call wrap_ent (g, k, rw, fty, n),
              st.wpends))
          $decl ret3  rw
        }.ret3
      )
    $decl m    $set st.wraps ($call wrap_list.cons ($call wrap_ent (g, k, w, fty, n), st.wraps))
    $decl ret2 w
  }.ret2
}.ret

// The callee of a `$call` with `k` arguments: itself, or the wrapper that supplies the
// rest. Only a direct call to a settled function type qualifies — a placeholder means a
// first pass that §5.5 will redo.
$decl short_callee $func ($decl st proto_lst, $decl f proto_lres, $decl k 0,
    $decl n Pa.proto_node) {
  $decl np $call T.tys.length ($call params_of (f.ty), 0)
  $decl ok $if ($call lt (k, np)) ($call not ($call T.has_var (f.ty, 0))) false
  // Bound first: §4.7 narrows a scrutinee by its name.
  $decl fi  f.ir
  $decl ret $if ok
      ($match fi (
          $case {$prop tag "global"} {
            $decl w  $call wrapper_for (st, fi.fn, k, f.ty, n)
            $decl wt $call T.t_func ($call ts_take ($call params_of (f.ty), k, T.tys.nil),
                $call result_of (f.ty))
            $decl ret2  $call IR.e_global ($call intern (st, wt), w)
          }.ret2,
          // A function *value* — a parameter, a field, a closure — has no definition
          // to take defaults from. Lowered as written this was a call with an argument
          // missing: wrong answers, not a refusal.
          $case fi ($call IR.e_unit ($call err (st,
              "an omitted argument needs its default, and this callee is a function value whose definition is not known here (§3.4): pass every argument", n)))
        ))
      f.ir
}.ret

// A call: the callee is lowered already, because §8's FFI intrinsics are told apart
// by it before their arguments are lowered (`lower_ffi`).
$decl lower_call $func ($decl st proto_lst, $decl e benv.node, $decl n proto_form,
                        $decl tail P.boolean, $decl f0 proto_lres) {
  $decl ov   $call is_over_l (f0.ty)
  $decl xs   $call group_items ($call op (n, 1))
  $decl rs   $if ov ($call lower_raws (st, e, xs, lres_list.nil)) lres_list.nil
  $decl f    $if ov ($call resolve_call (st, f0, $call over_cands (f0.ty), rs, 0)) f0
  $decl ps   $call params_of (f.ty)
  $decl as   $if ov ($call finish_raws (st, rs, xs, ps, IR.exprs.nil, T.tys.nil))
                    ($call lower_args (st, e, xs, IR.exprs.nil, T.tys.nil, ps))
  $decl ty   $call result_of (f.ty)
  $decl fck  $call check_freed (st, e, f.ty, xs, 0)
  $decl cf   $call short_callee (st, f, $call IR.exprs.length (as.irs, 0), n)
  $decl ret  $call lres ($call IR.e_call ($call intern (st, ty), cf, as.irs, tail), ty)
}.ret

// §8's `box_ptr` and `unbox`, and its arrays, bound at marker types (`T.ffi_box`)
// because the root block cannot say "for any T". Inference typed the call; here the
// intrinsic is given the monomorphic signature this call needs — `(&T) -> Int` with the
// storage passed as itself, `(Int, T) -> &^T`, `(Int, T) -> [T]`, `([T], Int) -> &mut T`
// or `([T]) -> Int` — so the backend sees an ordinary prim call.
$decl ffi_l $func ($decl f proto_lres) {
  $decl x   f.ir
  $decl t   f.ty
  $decl ret $match x (
      $case {$prop tag "prim"}
        $if ($call T.same (t, T.ffi_box)) "box_ptr"
        ($if ($call T.same (t, T.ffi_unbox)) "unbox"
        ($if ($call T.same (t, T.ffi_array)) "array"
        ($if ($call T.same (t, T.ffi_at)) "at"
        ($if ($call T.same (t, T.ffi_alen)) "alen"
        ($if ($call T.same (t, T.ffi_aptr)) "array_ptr" ""))))),
      $case x ""
    )
}.ret

// An array's element type, read the way inference's `arr_elem` reads it.
$decl elem_of $func ($decl t0 T.proto_ty) {
  $decl t   $call T.unroll (t0)
  $decl ret $match t ($case {$prop tag "array"} ($call T.tval (t.elem)), $case t T.t_bot)
}.ret

$decl lower_ffi $func ($decl st proto_lst, $decl e benv.node, $decl n proto_form,
                       $decl tail P.boolean, $decl w "") {
  $decl xs  $call group_items ($call op (n, 1))
  $decl box $call eq_str (w, "box_ptr")
  // A parameter typed as storage is what keeps `lower_args` from reading through.
  $decl ps  $if box ($call T.tys.cons ($call T.t_ref ("", T.t_int), T.tys.nil)) T.tys.nil
  $decl as  $call lower_args (st, e, xs, IR.exprs.nil, T.tys.nil, ps)
  $decl a0  $call ps_head (as.tys)
  $decl a1  $call ps_head ($call ps_tail (as.tys))
  $decl ty  $if box T.t_int
            ($if ($call eq_str (w, "array")) ($call T.t_array (a1))
            ($if ($call eq_str (w, "at")) ($call T.t_ref ("mut", $call elem_of (a0)))
            ($if ($call eq_str (w, "unbox")) ($call T.t_ref_k ("mut", a1, T.k_alloc))
                 T.t_int)))
  $decl ft  $call T.t_func (as.tys, ty)
  $decl cf  $call IR.e_prim ($call intern (st, ft), w)
  $decl ret $call lres ($call IR.e_call ($call intern (st, ty), cf, as.irs, tail), ty)
}.ret

// §4.9's application, lowering's half of `infer.mpl`'s `infer_apply`. The arguments are
// lowered once, as they stand, exactly as an overloaded call's are; each generic is read
// off their types where `Pa.app_sources` says; and the template is specialised through
// the explicit path with each generic bound to a `tyhole` — a node standing for an
// interned type, which is all an inferred generic is. So an application and an explicit
// `$specialize` at the same types share a memo entry, and so their lifted functions.
// A `$func` literal lifted: its body lowered in its own frame, with the enclosing slot space
// put aside. `self` is the name a block's `$decl` gives it when the body names it (P10):
// then the body is lowered twice, as a prop that names itself is — the first pass only to
// learn the result type the self-reference has, rolled back, and the second against it —
// with `self` resolving to the closure over this very function (`self_closure`). The
// self-reference is cleared for any literal nested in the body, whose captures differ.
$decl lam_res $func ($decl i 0, $decl t T.proto_ty) { $decl idx i  $decl ty t }

$decl lower_lam_pass $func ($decl st proto_lst, $decl ce benv.node, $decl n Pa.proto_node,
                            $decl ets IR.ints.node, $decl self "", $decl sty T.proto_ty) {
  $decl outer $call take_slots (st)
  $decl idx   $call reserve_lifted (st)
  $decl s0    $set st.scname self
  $decl s1    $set st.scidx idx
  $decl s2    $set st.scty sty
  $decl s3    $set st.scets ets
  $decl lf    $call lower_func (st, ce, "lambda", n, T.t_bot, ets)
  $decl back  $call restore_slots (st, outer)
  $decl put   $call put_lifted (st, idx, lf)
  $decl ret   $call lam_res (idx, $call fn_ty (st, lf))
}.ret

$decl lower_lambda $func ($decl st proto_lst, $decl ce benv.node, $decl n Pa.proto_node,
                          $decl ets IR.ints.node, $decl self "") {
  $decl o_n $call P.sval (st.scname)
  $decl o_i $call P.ival (st.scidx)
  $decl o_t $call T.tval (st.scty)
  $decl o_e $call IR.ints.val (st.scets)
  $decl ret $if ($call eq_str (self, "")) ($call lower_lam_pass (st, ce, n, ets, "", T.t_bot)) {
    $decl sn   $call take_snap (st)
    $decl p1   $call lower_lam_pass (st, ce, n, ets, self, T.t_bot)
    $decl rb   $call put_snap (st, sn)
    $decl ret2 $call lower_lam_pass (st, ce, n, ets, self, p1.ty)
  }.ret2
  $decl r0  $set st.scname o_n
  $decl r1  $set st.scidx o_i
  $decl r2  $set st.scty o_t
  $decl r3  $set st.scets o_e
}.ret

$decl int_node $func ($decl n Pa.proto_node) $match n (
  $case {$prop tag "int"} n.value,
  $case n -1
)

$decl tyhole $func ($decl st proto_lst, $decl t T.proto_ty, $decl n Pa.proto_node) {
  $decl sp  $call P.span_of (n)
  $decl ret $call Pa.n_form ("tyhole", $call Pa.nodes.cons ($call Pa.n_int ($call intern (st, t),
                sp.line, sp.col), Pa.nodes.nil), sp.line, sp.col)
}.ret

$decl app_lty $func ($decl s Pa.proto_app_src, $decl rs lres_list.node) {
  $decl at  $if ($if ($call lt (-1, s.arg)) ($call lt (s.arg, $call lres_list.length (rs, 0)))
                false) ($call lres_list.nth (rs, s.arg)).ty T.t_bot
  $decl ft  $call T.unroll ($call deref_ty (at))
  $decl ret $if ($call eq_int (s.kind, 0)) at
      ($match ft (
        $case {$prop tag "func"}
          $if ($call eq_int (s.kind, 2)) ($call T.tval (ft.result))
              ($if ($call lt (s.pos, $call T.tys.length ($call T.tys.val (ft.params), 0)))
                   ($call T.tys.nth ($call T.tys.val (ft.params), s.pos)) T.t_bot),
        $case ft T.t_bot))
}.ret

$decl app_holes $func ($decl st proto_lst, $decl ss Pa.app_srcs.node, $decl rs lres_list.node,
                       $decl n Pa.proto_node, $decl acc Pa.nodes.node) $match ss (
  $case {$prop tag "cons"}
    $call app_holes (st, $call Pa.app_srcs.val (ss.tail), rs, n,
        $call Pa.nodes.cons ($call tyhole (st, $call app_lty (ss.head, rs), n), acc)),
  $case ss ($call Pa.nodes.reverse (acc, Pa.nodes.nil))
)

$decl lower_apply $func ($decl st proto_lst, $decl e benv.node, $decl n proto_form,
                         $decl tail P.boolean, $decl r proto_tmpl) {
  $decl xs   $call group_items ($call op (n, 1))
  $decl rs   $call lower_raws (st, e, xs, lres_list.nil)
  $decl hs   $call app_holes (st, $call Pa.app_sources (r.body, r.generics, Pa.app_srcs.nil),
                 rs, n, Pa.nodes.nil)
  $decl f    $call as_value (st, $call spec_args (st, e, r, hs, n))
  $decl ps   $call params_of (f.ty)
  $decl as   $call finish_raws (st, rs, xs, ps, IR.exprs.nil, T.tys.nil)
  $decl ty   $call result_of (f.ty)
  $decl fck  $call check_freed (st, e, f.ty, xs, 0)
  $decl cf   $call short_callee (st, f, $call IR.exprs.length (as.irs, 0), n)
  $decl ret  $call lres ($call IR.e_call ($call intern (st, ty), cf, as.irs, tail), ty)
}.ret

$decl lower_form $func ($decl st proto_lst, $decl e benv.node, $decl n proto_form,
                        $decl tail P.boolean) {
  $decl k n.keyword
  $decl ret
    // §4.2: the only way storage exists. The operand is a value (§5.4).
    $if ($call eq_str (k, "new")) {
      $decl nk   $call newlit_key ($call op (n, 0))
      $decl kp   $set st.keepat nk
      $decl v    $call as_value (st, $call lower (st, e, $call op (n, 0), false))
      $decl rt   $call T.t_ref ("", v.ty)
      $decl nw   $call IR.e_new ($call intern (st, rt), v.ir)
      // Its address, for the item to compare what it binds against (`own_inits`).
      $decl ret2 $if ($call eq_str (nk, "")) ($call lres (nw, rt)) {
        $decl rid  $call intern (st, rt)
        $decl pp   $call fresh_slot (st, rid)
        $decl np   $set st.newptrs ($call strs.cons ($call concat (nk, $call concat ("|",
                       $call concat ($call int_to_str (pp), $call concat ("|",
                       $call int_to_str (rid))))), $call strs.val (st.newptrs)))
        $decl oty  $call T.t_block ($call T.fields.cons ($call T.field ("p", rt), T.fields.nil),
                       T.props.nil)
        $decl ob   $call IR.e_block ($call intern (st, oty),
                       $call IR.bslots.cons ($call IR.bslot (pp, nw), IR.bslots.nil))
        $decl ret3 $call lres ($call IR.e_field (rid, ob, 0), rt)
      }.ret3
    }.ret2
    // §4.2a. The same node as `$new`: the storage *kind* (§3.5) is already on
    // the node's type, so the tree needs no second field to carry it, and
    // the backend reads it off the type when it has two ways to allocate.
    ($if ($call eq_str (k, "free")) ($call lower_free (st, e, n, tail))
    ($if ($call eq_str (k, "alloc")) {
      // DEFER.md step 4: a literal's deferrals are kept for `defer_at` (`alloc_fin`).
      $decl dfa  $call dfr_list.val (st.defers)
      $decl kpa  $set st.keepat ($call newlit_key ($call op (n, 0)))
      $decl v    $call as_value (st, $call lower (st, e, $call op (n, 0), false))
      $decl rt   $call T.t_ref_k ("", v.ty, T.k_alloc)
      // §7.6: from the root allocator, the runtime's own; from any other, its `alloc` member
      // asked for the storage's size, through §8's `alloc_in`, which the backend emits.
      $decl sp0  $call P.span_of (n)
      $decl key  $call concat ($call fshort (st, $call P.sval (st.curfile)), $call concat (":",
                     $call concat ($call int_to_str (sp0.line), $call concat (":",
                     $call int_to_str (sp0.col)))))
      $decl user $call mem_strs ($call strs.val (st.ualloc), key)
      $decl ret2 $if user {
        $decl sp   $call P.span_of (n)
        $decl m    $call as_value (st, $call lower (st, e,
                       $call Pa.n_projn ($call Pa.n_name ("allocator", sp.line, sp.col), "alloc",
                           sp.line, sp.col), false))
        $decl ft   $call T.t_func ($call T.tys.cons (m.ty, $call T.tys.cons (v.ty, T.tys.nil)), rt)
        $decl ai   $call IR.e_call ($call intern (st, rt),
                       $call IR.e_prim ($call intern (st, ft), "alloc_in"),
                       $call IR.exprs.cons (m.ir, $call IR.exprs.cons (v.ir, IR.exprs.nil)),
                       tail)
        $decl ret3 $call lres ($call alloc_fin (st, e, n, dfa, ai, rt), rt)
      }.ret3 ($call lres ($call alloc_fin (st, e, n, dfa,
                  $call IR.e_new ($call intern (st, rt), v.ir), rt),
                  rt))
    }.ret2
    // §4.3: a view, not a value — no node, only a different type.
    ($if ($call P.or ($call eq_str (k, "mut"), $call eq_str (k, "const"))) {
      $decl v  $call lval ($call lower (st, e, $call op (n, 0), false))
      // §5.3: a view preserves the kind.
      $decl rt   $call T.t_ref_k (k, $call deref_ty (v.ty), $call ref_kind (v.ty))
      $decl ret2 $call lres (v.ir, rt)
    }.ret2
    // §4.4: writes *through* storage; the type is the written value's.
    ($if ($call eq_str (k, "set")) {
      $decl dst  $call lval ($call lower (st, e, $call op (n, 0), false))
      $decl raw  $call lval ($call lower (st, e, $call op (n, 1), false))
      // §6: storage of trait type holds trait objects, so a conforming value is coerced.
      $decl pt   $call deref_ty (dst.ty)
      $decl v    $if ($call to_trait (pt, raw.ty))
                     ($call lval ($call tobj_of (st, raw, $call op (n, 1), pt, n)))
                     ($call as_value (st, raw))
      $decl ret2 $call lres ($call IR.e_set ($call intern (st, v.ty), dst.ir, v.ir), v.ty)
    }.ret2
    // §4.8b, and the whole reason it exists: the second operand stays in tail
    // position, so a loop written with `$do` keeps §7.7.
    ($if ($call eq_str (k, "do")) {
      $decl a    $call lval ($call lower (st, e, $call op (n, 0), false))
      $decl b    $call lval ($call lower (st, e, $call op (n, 1), tail))
      $decl ret2 $call lres ($call IR.e_do ($call intern (st, b.ty), a.ir, b.ir), b.ty)
    }.ret2
    ($if ($call eq_str (k, "if")) {
      $decl c    $call as_value (st, $call lower (st, e, $call op (n, 0), false))
      $decl ad   $set st.armdepth ($call add ($call P.ival (st.armdepth), 1))
      $decl a    $call lval ($call lower (st, e, $call op (n, 1), tail))
      $decl b    $call lval ($call lower (st, e, $call op (n, 2), tail))
      $decl ad2  $set st.armdepth ($call sub ($call P.ival (st.armdepth), 1))
      $decl ty   $call T.join (a.ty, b.ty)
      $decl ret2 $call lres ($call IR.e_if ($call intern (st, ty), c.ir, a.ir, b.ir), ty)
    }.ret2
    ($if ($call eq_str (k, "match")) {
      $decl ad   $set st.armdepth ($call add ($call P.ival (st.armdepth), 1))
      $decl r    $call lower_match (st, e, n, tail)
      $decl ad2  $set st.armdepth ($call sub ($call P.ival (st.armdepth), 1))
      $decl ret2 r
    }.ret2
    // §4.8a: the expression *evaluates to its first member* and has the
    // type of all of them joined. The rest are type-only positions (§5.7) —
    // lowered here only to read their types off, and their trees discarded.
    //
    // The value is then coerced to that join, because what the members have
    // in common is a union and a member of one is not yet one (§7.4).
    ($if ($call eq_str (k, "union")) {
      $decl ms   $call group_items ($call op (n, 0))
      $decl fst  $call lval ($call lower (st, e, $call Pa.nodes.nth (ms, 0), false))
      $decl ty   $call union_ty (st, e, $call Pa.nodes.val (ms), T.t_bot)
      $decl id   $call intern (st, ty)
      $decl ir   $if ($call T.same (ty, fst.ty)) fst.ir ($call IR.e_copy (id, fst.ir))
      $decl ret2 $call lres (ir, ty)
    }.ret2
    // §4.15, the only non-local exit and only a conditional one: if the
    // value matches the pattern it returns from the enclosing `$func`, and
    // otherwise this expression carries on with what is left of its type.
    // Inference already widened the function's result to include the
    // matched member, so the return has somewhere to go.
    ($if ($call eq_str (k, "try")) {
      $decl v   $call lval ($call lower (st, e, $call op (n, 0), false))
      $decl pty $call pattern_ty (st, e, $call op (n, 1))
      $decl ds  $call disc_of ($call members_of ($call canon_ty (st, v.ty)), pty, 0,
                    IR.ints.nil, IR.ints.nil)
      // `type(e) & ¬pat` — what the value is once the matching member has
      // been taken away.
      $decl rest $call T.minus (v.ty, pty)
      $decl ret2 $match ds (
          // §4.15a: it returns, so every deferral pending in this function runs first.
          // The member it returns is interned here: emit looks it up to inject it into
          // the function's result, and nothing else need have interned it — a program
          // whose only `none` is the one a `$try` returns emitted an uninitialised result.
          $case {$prop tag "cons"}
            $do ($call intern (st, $call T.tys.nth ($call members_of ($call canon_ty (st, v.ty)),
                     ds.head)))
            ($call lres ($call IR.e_try ($call intern (st, rest), v.ir, ds.head,
                $call lower_dfrs (st, $call dfr_list.val (st.defers),
                    $call dfr_list.length ($call dfr_list.val (st.defers), 0), IR.exprs.nil)),
                rest)),
          $case ds
            ($call lres ($call IR.e_unit ($call err (st,
                "$try's pattern matches nothing in the value's type", n)), T.t_unit))
        )
    }.ret2
    // §7.3: a `$func` literal lifts to a top-level function and leaves the
    // pair behind. Its frame is its own, so the enclosing slot space is put
    // aside and restored.
    ($if ($call eq_str (k, "func")) {
      // The name a block's `$decl` gives this literal, taken so a literal nested in its body
      // does not see it; `self` only when the body names it (P10).
      $decl rnm  $call P.sval (st.recname)
      $decl clr  $set st.recname ""
      $decl fns  $call free_names (n, strs.nil)
      $decl self $if ($call eq_str (rnm, "")) "" ($if ($call mem_strs (fns, rnm)) rnm "")
      $decl cs   $call caps (fns, e, benv.nil)
      $decl vals $call cap_exprs (st, cs, IR.exprs.nil)
      // The captures are found the same way at every evaluation, so they come
      // out in the order the shared function's environment expects; only the
      // slots they are read from differ.
      $decl sp   $call P.span_of (n)
      $decl fk   $if ($call eq_str ($call P.sval (st.isctx), "")) ""
                     ($call concat ($call P.sval (st.isctx), $call concat ("@",
                      $call concat ($call P.sval (st.curfile), $call concat (":",
                      $call concat ($call int_to_str (sp.line), $call concat (":",
                      $call int_to_str (sp.col))))))))
      $decl hit  $if ($call eq_str (fk, "")) fnm_list.nil ($call find_fnm (st.fnmemo, fk))
      $decl ret2    $match hit (
          $case {$prop tag "cons"}
            ($call lres ($call IR.e_closure ($call intern (st, hit.head.ty), hit.head.idx, vals),
                 hit.head.ty)),
          $case hit {
            $decl ets   $call cap_tys (st, cs, IR.ints.nil)
            $decl lw    $call lower_lambda (st, $call cap_env (cs, 0, e), n, ets, self)
            $decl idx   lw.idx
            $decl fty   lw.ty
            $decl memo $set st.fnmemo ($if ($call eq_str (fk, "")) ($call fnm_list.val (st.fnmemo))
                           ($call fnm_list.cons ($call fnm_ent (fk, idx, fty), st.fnmemo)))
            $decl ret3    $call lres ($call IR.e_closure ($call intern (st, fty), idx, vals), fty)
          }.ret3
        )
    }.ret2
    // §4.9: a template is compile-time and has no runtime value, so this
    // registers the body and evaluates to nothing. `$specialize` is the
    // only thing that can consume it, and it finds it by the index here.
    ($if ($call eq_str (k, "template")) {
      $decl gs  $call generic_names ($call op (n, 0), strs.nil)
      // An inline `$template` has no member name to be identified by, so its key
      // is where it is **written**: the module and the form's own span. That is a
      // stable identity for the same reason a diagnostic's is — it names a place
      // in a source file rather than a position in this program's load order.
      $decl sp  $call P.span_of (n)
      $decl tid $call fresh_tmpl (st, gs, $call op (n, 1), e,
                    $call concat ($call P.sval (st.curmod),
                    $call concat ("_t", $call concat ($call int_to_str (sp.line),
                    $call concat ("_", $call int_to_str (sp.col))))),
                    $call P.sval (st.curfile), $call P.sval (st.isctx), n)
      $decl ret2   $call lres4 ($call IR.e_unit ($call intern (st, T.t_unit)), T.t_unit,
                    -1, tid)
    }.ret2
    ($if ($call eq_str (k, "specialize")) ($call lower_specialize (st, e, n))
    ($if ($call eq_str (k, "import")) ($call lower_import (st, n))
    // §4.16. The signature is a **type-only position** (§5.7): it is never
    // evaluated, so it is lowered for its type and the tree thrown away — and
    // `type_only` is what keeps its slots out of this frame, exactly as for
    // `$union`'s later members. The symbol comes off the AST; §4.16's ABI
    // mapping needs nothing but the type, which is why the node carries only
    // those two things.
    ($if ($call eq_str (k, "extern")) {
      $decl sg   $call type_only (st, e, $call op (n, 1))
      $decl sy   $call str_of ($call op (n, 0))
      $decl ret2 $call lres ($call IR.e_extern ($call intern (st, sg.ty), sy), sg.ty)
    }.ret2
    // §4.8: at run time an overload *is* the group of its candidates, typed as an
    // overload set so a call or a typed position can resolve it.
    ($if ($call eq_str (k, "overload")) {
      $decl rs   $call lower_raws (st, e, $call group_items ($call op (n, 0)), lres_list.nil)
      $decl vs   $call over_vals (st, rs, IR.exprs.nil, T.tys.nil)
      $decl ty   $call T.t_over (vs.tys)
      $decl ret2 $call lres ($call IR.e_group ($call intern (st, ty), vs.irs), ty)
    }.ret2
    // §4.13: the trait of the operand's type, with the operand as the referent.
    ($if ($call eq_str (k, "traitsof")) {
      $decl raw  $call lval ($call lower (st, e, $call op (n, 0), false))
      $decl tr   $call T.unroll (raw.ty)
      $decl q    $match tr ($case {$prop tag "ref"} ($if ($call eq_str (tr.qual, "mut")) "mut" ""),
                            $case tr "")
      $decl v0   $match tr ($case {$prop tag "ref"} ($call T.tval (tr.inner)), $case tr raw.ty)
      $decl ret2 $call tobj_of (st, raw, $call op (n, 0), $call ltrait_of (st, v0, q, n), n)
    }.ret2
    // §4.12: the base's value at the base's type with the override's props added. The
    // trait is type-only (§5.7). The override is lowered as a block so its props register
    // under its span the way any block literal's do, and told the base first, because
    // its receiver is the result (`lower_block`).
    ($if ($call eq_str (k, "impl")) {
      $decl bx   $call as_value (st, $call lower (st, e, $call op (n, 0), false))
      $decl tro  $call type_only (st, e, $call op (n, 1))
      $decl ov   $call op (n, 2)
      $decl sp   $call P.span_of (ov)
      $decl sb   $do ($set st.rbase bx.ty) ($do ($set st.rbline sp.line) ($set st.rbcol sp.col))
      $decl ovr  $call lval ($call lower (st, e, ov, false))
      $decl rt   $call T.impl_ty (bx.ty, $call own_props (ovr.ty))
      $decl ir   $if ($call T.same (rt, bx.ty)) bx.ir
                     ($call IR.e_copy ($call intern (st, rt), bx.ir))
      $decl ret2 $call lres3 (ir, rt, ovr.mod)
    }.ret2
    // §4.8: an overload as the callee resolves to its first fitting candidate — the
    // arguments lowered first, as they stand, then made what that candidate's parameters
    // want; lowering them twice could lift a `$func` literal twice.
    ($if ($call eq_str (k, "call")) {
      $decl f0   $call as_value (st, $call lower (st, e, $call op (n, 0), false))
      $decl fw   $call ffi_l (f0)
      $decl ts   $if ($call lt (f0.tmpl, 0)) tmpls_list.nil ($call find_tmpl (st.tmpls, f0.tmpl))
      $decl ret2 $match ts (
          $case {$prop tag "cons"} ($call lower_apply (st, e, n, tail, ts.head)),
          $case ts $if ($call eq_str (fw, "")) ($call lower_call (st, e, n, tail, f0))
                       ($call lower_ffi (st, e, n, tail, fw)))
    }.ret2
    // An inferred generic (`lower_apply`): its type, and no value to read.
    ($if ($call eq_str (k, "tyhole")) {
      $decl ti   $call int_node ($call op (n, 0))
      $decl t    $call ty_at (st, ti)
      $decl bad  $if ($call lt (0, $call P.ival (st.tonly))) 0
                     ($call err (st, "a generic inferred by application has a type and no value; write the $specialize to give it one (§4.9)", n))
      $decl ret2 $call lres ($call IR.e_panic (ti, "an inferred generic has no value"), t)
    }.ret2
      ($call lres ($call IR.e_unit ($call err (st, $call concat ("$", $call concat (k,
           " is not lowered yet")), n)), T.t_unit)))))))))))))))))))))
}.ret

$decl lower $func ($decl st proto_lst, $decl e benv.node, $decl n Pa.proto_node,
                   $decl tail P.boolean) $match n (
  $case {$prop tag "int"}   ($call lres ($call IR.e_int ($call intern (st, T.t_int), n.value),
      T.t_int)),
  $case {$prop tag "str"}   ($call lres ($call IR.e_str ($call intern (st, T.t_str), n.text),
      T.t_str)),
  $case {$prop tag "float"} ($call lres ($call IR.e_float ($call intern (st, T.t_float), n.text),
      T.t_float)),
  $case {$prop tag "bool"}
    ($call lres ($call IR.e_bool ($call intern (st, T.t_bool), n.value),
                 $if n.value T.t_true T.t_false)),
  $case {$prop tag "unit"}  ($call lres ($call IR.e_unit ($call intern (st, T.t_unit)), T.t_unit)),
  $case {$prop tag "name"}  ($call lower_name (st, e, n)),
  // A block literal projected on the spot is discarded there: a scope (§4.15a).
  $case {$prop tag "proj_name"}
    $do ($set st.nextscope $call is_block_ast (n.target)) ($call lower_proj (st, e, n)),
  $case {$prop tag "proj_index"} ($call lower_projidx (st, e, n, n.target, n.index)),
  $case {$prop tag "block"} ($call lower_block (st, e, $call Pa.nodes.val (n.items), n)),
  $case {$prop tag "group"} ($call lower_group (st, e, $call Pa.nodes.val (n.items))),
  $case {$prop tag "form"}  ($call lower_form (st, e, n, tail)),
  $case n ($call lres ($call IR.e_unit ($call err (st,
      $call concat ($call kind_of (n), " is not lowered yet"), n)), T.t_unit))
)

// ------------------------------------------------------------------ functions
//
// §7.2's frame: the parameters take the first slots, in order, then every
// `$decl` in the body. The counter left over is the frame size.

// P11: whether a type carries a function-valued prop whose source lowering has not seen
// yet. A parameter's type is inference's, so a body can reach a member through it before
// the code building the block is lowered — and a deferred read (`prop_pending`) cannot
// know the member names its receiver, so it would be called with no environment. The
// default builds a value of the type (§3.4), so lowering it registers the source first.
$decl unseen_props $func ($decl st proto_lst, $decl ps T.props.node) $match ps (
  $case {$prop tag "cons"} {
    $decl c   ps.head.value
    $decl hit $match c (
        $case {$prop tag "copaque"}
          ($call lt ($call prop_by_id ($call opq_list.val (st.opaqs), c.id, ps.head.name), 0)),
        $case c false
      )
    $decl ret $if hit true ($call unseen_props (st, $call T.props.val (ps.tail)))
  }.ret,
  $case ps false
)

$decl src_unseen $func ($decl st proto_lst, $decl t0 T.proto_ty) {
  $decl t   $call T.unroll (t0)
  $decl ret $match t (
      $case {$prop tag "block"} ($call unseen_props (st, $call T.props.val (t.props))),
      $case t false
    )
}.ret

// `de` is where the defaults are lowered when that differs from `e`: a member's, whose
// defaults see the declaring name as the block's type (§4.10, a type-only position) while
// its body sees the receiver, a reference. Empty means `e`. Inference splits the same way
// (`infer_rec_func`'s `pe`).
$decl bind_params $func ($decl st proto_lst, $decl e benv.node, $decl ps Pa.nodes.node,
                         $decl ts T.tys.node, $decl acc IR.ints.node, $decl de benv.node)
    $match ps (
  $case {$prop tag "cons"} {
    $decl nm $call name_of ($call op (ps.head, 0))
    // §3.4: "each default fixes the parameter's type". Inference already
    // solved a top-level function's, and passes it in; a `$func` literal
    // lifted out of an expression has none, so its defaults are the source.
    $decl de2 $if ($call benv.is_nil (de)) e de
    $decl ty $match ts (
        $case {$prop tag "cons"} {
          $decl seen $if ($call src_unseen (st, ts.head))
                         ($call type_only (st, de2, $call op (ps.head, 1))).ty ts.head
          $decl ret2 ts.head
        }.ret2,
        $case ts ($call type_only (st, de2, $call op (ps.head, 1))).ty
      )
    $decl tid $call intern (st, ty)
    $decl sl  $call fresh_slot (st, tid)
    $decl e2  $call benv.cons ($call bind_ent (nm, "local", sl, ty), e)
    $decl rt  $match ts ($case {$prop tag "cons"} ($call T.tys.val (ts.tail)), $case ts T.tys.nil)
    $decl ret  $call bind_params (st, e2, ps.tail, rt,
                 $call IR.ints.cons (tid, acc), de)
  }.ret,
  $case ps ($call binding_done (e, $call IR.ints.reverse (acc, IR.ints.nil)))
)

// Lower one `$func` whose type inference already solved. `fty` is that type, so
// the parameter types come from it rather than from re-reading the defaults.
$decl lower_func $func ($decl st proto_lst, $decl e benv.node, $decl nm "",
                        $decl n Pa.proto_node, $decl fty T.proto_ty, $decl ev IR.ints.node,
                        $decl de benv.node) {
  $decl reset $call take_slots (st)
  $decl ps    $call group_items ($call op (n, 0))
  $decl ptys  $match fty ($case {$prop tag "func"} ($call T.tys.val (fty.params)), $case fty T.tys.nil)
  $decl b     $call bind_params (st, e, ps, ptys, IR.ints.nil, de)
  // §4.15a: `$try` returns from the nearest `$func`, so the enclosing one's deferrals are
  // not this body's to run.
  $decl odf   $call dfr_list.val (st.defers)
  $decl clr   $set st.defers dfr_list.nil
  $decl oad   $call P.ival (st.armdepth)
  $decl cad   $set st.armdepth 0
  $decl oap   $call strs.val (st.aprov)
  // DEFER.md: a parameter the function's type says it frees (`128 + i`) came from the root,
  // which every caller checks — so `$free` of it here routes there.
  $decl cla   $set st.aprov ($call mfree_provs ($call strs.val (st.mfree), $call alloc_ident (e),
                  $call freed_provs (fty, 0, $call IR.ints.length (b.tys, 0),
                      $call alloc_ident (e), strs.nil)))
  $decl clm   $set st.mfree strs.nil
  // The body is in tail position: it *is* the function's result (§7.7).
  $decl body  $call lval ($call lower (st, b.env, $call op (n, 1), true))
  $decl rdf   $set st.defers odf
  $decl rad   $set st.armdepth oad
  $decl rap   $set st.aprov oap
  // §4.15 widens the *inferred* result to include what `$try` can return, so
  // the declared type is the one to believe — not the body's own, which does
  // not know about the non-local exits inside it.
  $decl rty0 $match fty ($case {$prop tag "func"} ($call T.tval (fty.result)), $case fty body.ty)
  $decl rty  $call intern (st, rty0)
  $decl ret   $call IR.fn_p (nm, b.tys, rty, $call take_slots (st), body.ir, false, false,
                  ev, $call P.sval (st.curfile), $call next_rank (st), false,
                  $call P.sval (st.curmod))
}.ret

// The type of a lifted function, rebuilt from the types its slots were
// interned under — lowering derives, it does not carry (§5.7).
$decl param_tys $func ($decl st proto_lst, $decl ts T.tys.node, $decl xs IR.ints.node,
                       $decl acc T.tys.node) $match xs (
  $case {$prop tag "cons"}
    $call param_tys (st, ts, xs.tail, $call T.tys.cons ($call ty_at (st, xs.head), acc)),
  $case xs ($call T.tys.reverse (acc, T.tys.nil))
)

$decl fn_ty $func ($decl st proto_lst, $decl f IR.proto_fn) {
  $decl ts T.tys.nil
  $decl ret  $call T.t_func ($call param_tys (st, ts, $call IR.ints.val (f.params), T.tys.nil),
               $call ty_at (st, f.result))
}.ret


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
  $case {$prop tag "cons"} {
    // §3.3's effect items bind nothing, so they enter no scope — they are in
    // the member list only to hold their position in §4.10's order.
    $decl hit $call eq_str (xs.head.name, nm)
    // Up to and *including* the member itself: §5.7 lets a type-only position
    // name a declaration that is in progress, which is how a recursive type
    // is written at all (§5.5). Only what comes after is out of scope.
    $decl vis $if ($call eq_str (xs.head.kind, "effect")) false
                  ($if ($call eq_str (xs.head.kind, "prop")) true ($if seen false true))
    $decl e2  $if vis
        ($call benv.cons ($call bind_ent6 (xs.head.name, "prop", 0, T.t_bot, mid, -1), e)) e
    $decl sn  $if seen true hit
    $decl ret $call with_scope (e2, xs.tail, mid, nm, sn)
  }.ret,
  $case xs e
)


// The names `n` reads from outside itself, by scope — unlike `free_names`, which is for a
// closure's capture list, where a name the body rebinds costs only a copied word. Here it
// costs an error: `no_caps` refused a member whose body bound a local of the same name as
// one of its block's fields (`{ $decl n … }` inside a member of a block with field `n`).
// Subtracting every name bound anywhere inside would hide a genuine read made *before* a
// rebinding — `{ $decl a n  $decl n 5 … }` reads the outer `n` — so the walk follows §4.10:
// a block's props are bound throughout it, a `$decl` from after its own initializer, and a
// `$func`'s parameters in its body, its defaults being read outside (§3.4).
$fwd free_sc

$decl free_sc_list $func ($decl xs Pa.nodes.node, $decl bound strs.node, $decl acc strs.node)
    $match xs (
  $case {$prop tag "cons"}
    $call free_sc_list ($call Pa.nodes.val (xs.tail), bound, $call free_sc (xs.head, bound, acc)),
  $case xs acc
)

$decl prop_names $func ($decl xs Pa.nodes.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"}
    $call prop_names ($call Pa.nodes.val (xs.tail),
        $if ($call is_form (xs.head, "prop"))
            ($call strs.cons ($call name_of ($call op (xs.head, 0)), acc)) acc),
  $case xs acc
)

// A block's items in order: an initializer is read before its own name is bound.
$decl free_sc_items $func ($decl xs Pa.nodes.node, $decl bound strs.node, $decl acc strs.node)
    $match xs (
  $case {$prop tag "cons"} {
    $decl it  xs.head
    $decl bnd $if ($call is_form (it, "decl")) true ($call is_form (it, "prop"))
    $decl a2  $if bnd ($call free_sc ($call op (it, 1), bound, acc))
                  ($if ($call is_form (it, "fwd")) acc ($call free_sc (it, bound, acc)))
    $decl nm  $call binder_of (it)
    $decl b2  $if ($call eq_str (nm, "")) bound ($call strs.cons (nm, bound))
    $decl ret $call free_sc_items ($call Pa.nodes.val (xs.tail), b2, a2)
  }.ret,
  $case xs acc
)

// A `$func`'s defaults, read outside it, and its parameter names.
$decl param_defaults $func ($decl ps Pa.nodes.node, $decl bound strs.node, $decl acc strs.node)
    $match ps (
  $case {$prop tag "cons"}
    $call param_defaults ($call Pa.nodes.val (ps.tail), bound,
        $if ($call is_form (ps.head, "decl")) ($call free_sc ($call op (ps.head, 1), bound, acc))
            acc),
  $case ps acc
)
$decl param_names $func ($decl ps Pa.nodes.node, $decl acc strs.node) $match ps (
  $case {$prop tag "cons"}
    $call param_names ($call Pa.nodes.val (ps.tail),
        $if ($call is_form (ps.head, "decl"))
            ($call strs.cons ($call name_of ($call op (ps.head, 0)), acc)) acc),
  $case ps acc
)

$decl free_sc_form $func ($decl n Pa.proto_node, $decl bound strs.node, $decl acc strs.node)
  $if ($call is_form (n, "func")) {
    $decl ps   $call group_items ($call op (n, 0))
    $decl a2   $call param_defaults (ps, bound, acc)
    $decl ret2 $call free_sc ($call op (n, 1), $call param_names (ps, bound), a2)
  }.ret2
  ($match n (
      $case {$prop tag "form"}
        ($call free_sc_list ($call Pa.nodes.val (n.operands), bound,
            // §7.6: `$alloc` reads `allocator` without spelling it (`free_names`).
            $if ($call eq_str (n.keyword, "alloc"))
                ($if ($call mem_str (bound, "allocator")) acc
                     ($if ($call mem_str (acc, "allocator")) acc ($call strs.cons ("allocator", acc))))
                acc)),
      $case n acc
    ))

$decl free_sc $func ($decl n Pa.proto_node, $decl bound strs.node, $decl acc strs.node) $match n (
  $case {$prop tag "name"}
    $if ($call mem_str (bound, n.text)) acc
        ($if ($call mem_str (acc, n.text)) acc ($call strs.cons (n.text, acc))),
  $case {$prop tag "form"}  ($call free_sc_form (n, bound, acc)),
  $case {$prop tag "group"} ($call free_sc_list ($call Pa.nodes.val (n.items), bound, acc)),
  $case {$prop tag "block"} {
    $decl xs   $call Pa.nodes.val (n.items)
    $decl ret2 $call free_sc_items (xs, $call prop_names (xs, bound), acc)
  }.ret2,
  $case {$prop tag "proj_name"}  ($call free_sc (n.target, bound, acc)),
  $case {$prop tag "proj_index"} ($call free_sc (n.target, bound, acc)),
  $case n acc
)

// A function-valued prop lifts like any other `$func` (§7.3) — except that a
// prop has no position at which a capture could be evaluated, because it has
// no position at all. Worth its own message: without the check, a captured
// local would silently become a read of the *lifted* function's own frame.
$decl no_caps $func ($decl st proto_lst, $decl pe benv.node, $decl n Pa.proto_node) {
  $decl cs $call caps ($call free_sc (n, strs.nil, strs.nil), pe, benv.nil)
  $decl ret $match cs (
      $case {$prop tag "cons"}
        ($call err (st, $call concat ("a $prop's value may not capture '",
            $call concat (cs.head.name,
            "': a prop is compile-time (§4.10), so there is nowhere to evaluate the capture")), n)),
      $case cs 0
    )
}.ret

// Recorded against whatever the module looks like *now*: lowering a prop's
// body can lower its siblings, so the entry read at the start is stale by the
// time the body is done.
$decl note_prop $func ($decl st proto_lst, $decl mid 0, $decl d proto_mdone) {
  $decl ms $call find_mod_st (st, mid)
  $decl ret $match ms (
      $case {$prop tag "cons"}
        // A copy, so `file` comes across — it is where this module's code is
        // emitted, and rebuilding without it sent every module's members into the
        // entry file's output. The same hazard `mark_self` and `fold` carry `mod`
        // and `rank` for.
        ($call save_mod (st, $call mod_ent_g (mid, ms.head.props,
            $call mdones.cons (d, ms.head.done),
            $call benv.val (ms.head.env), ms.head.base, ms.head.path,
            $call benv.val (ms.head.penv), ms.head.file, $call mrec_val (ms.head.rec),
            ms.head.isctx, $call dx_add ($call dx_val (ms.head.dix), $call dx_key (d.name), 0,
                d)))),
      $case ms 0
    )
}.ret

$decl bump_place $func ($decl st proto_lst) {
  $decl i   $call P.ival (st.nplace)
  $decl n   $set st.nplace ($call add (i, 1))
  $decl ret 0
}.ret

$decl places $func ($decl st proto_lst) $call P.ival (st.nplace)

// The depth of member `k` among those in progress (0 the outermost), or a depth no member
// has when it is not one — a read the reader must answer for itself.
$decl lp_find $func ($decl xs strs.node, $decl k "", $decl n 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head, k)) ($call isub ($call strs.length (xs, 0), 1))
        ($call lp_find ($call strs.val (xs.tail), k, n)),
  $case xs n
)
$decl lp_pop $func ($decl xs strs.node) $match xs (
  $case {$prop tag "cons"} ($call strs.val (xs.tail)),
  $case xs xs
)
$decl note_read $func ($decl st proto_lst, $decl d proto_mdone) {
  $decl dp  $call lp_find ($call strs.val (st.lpstack), $call int_to_str (d.idx), 1000000000)
  $decl unk $if ($call lt (dp, 1000000000)) ()
                ($do ($set st.nunk ($call add ($call P.ival (st.nunk), 1))) ())
  $decl ret $if ($call lt (dp, $call P.ival (st.minread))) ($do ($set st.minread dp) 0) 0
}.ret

// Is this the type a member has before its body has given one up? Both stand
// for "not known yet": a `$func` member starts at ⊥ and a value member at a
// §5.5 placeholder.
$decl unsettled $func ($decl t T.proto_ty)
  $if ($call T.has_var (t, 0)) true ($call T.same (t, T.t_bot))

$decl prop_global $func ($decl st proto_lst, $decl d proto_mdone) {
  $decl t $call T.tval (d.ty)
  // A module with a record is settled — only a settled record is kept — so its
  // type needs neither walk below, and walking it is `T.has_var` over the whole
  // record at every member access.
  $decl mr $call mod_rec_of (st, d.mod)
  $decl bp $if mr.has 0 ($if ($call unsettled (t))
                             ($do ($call note_read (st, d)) ($call bump_place (st))) 0)
  // While the member's own body is being lowered its type is §5.5's
  // placeholder. That is the right *type* — it is what the knot is tied on —
  // but not a layout, so the node's type index is a harmless stand-in.
  $decl ti $if mr.has mr.id
               ($if ($call T.has_var (t, 0)) ($call intern (st, T.t_unit)) ($call intern (st, t)))
  $decl ret $call lres4 ($call IR.e_global (ti, d.idx), t, d.mod, d.tmpl)
}.ret

$fwd lower_prop_new

// A prop's body lowered as a function of its own, with the enclosing frame put
// aside and restored (§7.2: a lifted function's frame is its own).
// A member's discriminator is its **position among its module's props**, which
// `block_props` and `file_props` both build in source order — not a counter.
//
// For a real module the two already agree: §4.14 lowers its members eagerly in source
// order, so the counter *was* the index. For a `$specialize` they do not, because its
// members are lowered lazily on first projection — so `P.list`'s `cons` came out
// `…_2` in one program and `…_19` in another, depending only on which member the
// program happened to project first. Reading the index makes lazy lowering agree with
// eager, which is the property §4.10 asks for anyway.
//
// A member not found takes -1, which cannot collide with an index and shows up in the
// C as a name rather than passing silently.
$decl prop_rank $func ($decl ps mprops.node, $decl nm "", $decl i 0) $match ps (
  $case {$prop tag "cons"}
    $if ($call eq_str (ps.head.name, nm)) i
        ($call prop_rank ($call mprops.val (ps.tail), nm, $call add (i, 1))),
  $case ps -1
)

// §4.10: the receiver a `$decl`'s initializer gives the block it is, recorded around the
// lowering of that initializer — exactly as inference does — so `lower_block` can claim it.
$decl recv_mark $func ($decl n "", $decl q "", $decl k "", $decl l 0, $decl c 0)
  { $decl name n  $decl qual q  $decl kind k  $decl line l  $decl col c }
$decl proto_mark $call recv_mark ("", "", "", -1, -1)

$decl recv_put $func ($decl st proto_lst, $decl r proto_mark) {
  $decl a   $set st.rname r.name
  $decl b   $set st.rqual r.qual
  $decl c   $set st.rkind r.kind
  $decl d   $set st.rline r.line
  $decl ret $set st.rcol r.col
}.ret

$decl recv_enter $func ($decl st proto_lst, $decl nm "", $decl init Pa.proto_node) {
  $decl old $call recv_mark ($call P.sval (st.rname), $call P.sval (st.rqual),
                $call P.sval (st.rkind), $call P.ival (st.rline), $call P.ival (st.rcol))
  $decl b   $call Pa.recv_target (init)
  $decl sp  $call P.span_of (b)
  $decl nw  $if ($call Pa.is_block (b))
                ($call recv_mark (nm, $call Pa.recv_qual (init), $call Pa.recv_kind (init),
                     sp.line, sp.col))
                proto_mark
  $decl put $call recv_put (st, nw)
  $decl ret old
}.ret

$decl lower_prop_body $func ($decl st proto_lst, $decl pe benv.node, $decl nm "",
                             $decl pn Pa.proto_node, $decl fty T.proto_ty, $decl rk 0,
                             $decl ets IR.ints.node, $decl de benv.node) {
  $decl o $call take_slots (st)
  // Marked here rather than inside `lower_func`, which also serves an entry-file
  // top-level `$decl` — §4.14 lets an importer project a *member*, and nothing
  // imports the entry file. `rk` is its source-order index, not a counter: see
  // `prop_rank`.
  $decl f   $call IR.fn_member ($call lower_func (st, pe, nm, pn, fty, ets, de), rk)
  $decl b   $call restore_slots (st, o)
  $decl ret f
}.ret

$decl nd_val $func ($decl n Pa.proto_node) n
$decl digits_int $func ($decl s "", $decl i 0, $decl acc 0)
  $if ($call lt (i, $call len (s)))
      ($call digits_int (s, $call add (i, 1), $call add ($call mul (acc, 10),
          $call sub ($call byte (s, i), 48))))
      acc
// DEFER.md: what inference recorded for a function a file declares at its top level
// (`member_facts`): the parameters it frees, and whether its result is root storage.
// Lowering rebuilds a module member's type from its body, without either, so they come
// from here — keyed as `ualloc`'s are, by the file's short name.
$decl fact_tail $func ($decl xs strs.node, $decl pre "", $decl acc strs.node) $match xs (
  $case {$prop tag "cons"} {
    $decl n   $call len (pre)
    $decl hit $if ($call lt (n, $call len (xs.head)))
                  ($call eq_str ($call slice (xs.head, 0, n), pre)) false
    $decl ret $call fact_tail ($call strs.val (xs.tail), pre,
                  $if hit ($call strs.cons ($call slice (xs.head, n, $call len (xs.head)), acc))
                      acc)
  }.ret,
  $case xs acc
)
$decl member_freed $func ($decl st proto_lst, $decl key "")
  $call fact_tail ($call strs.val (st.ualloc), $call concat ("p:", $call concat (key, ":")), strs.nil)
$decl member_root $func ($decl st proto_lst, $decl key "")
  $call mem_strs ($call strs.val (st.ualloc), $call concat ("r:", $call concat (key, ":root")))
$decl member_nonroot $func ($decl st proto_lst, $decl key "")
  $call mem_strs ($call strs.val (st.ualloc), $call concat ("r:", $call concat (key, ":nonroot")))

// A member's type with the facts put back, so a call — through the member, or through a
// value of its type — is checked as one to an entry-file function is.
$decl esc_of_idx $func ($decl xs strs.node, $decl acc T.cints.node) $match xs (
  $case {$prop tag "cons"}
    $call esc_of_idx ($call strs.val (xs.tail), $call T.cints.cons ($call add (128,
        $call digits_int (xs.head, 0, 0)), acc)),
  $case xs acc
)
$decl with_facts $func ($decl st proto_lst, $decl t T.proto_ty, $decl key "") {
  $decl fr  $call member_freed (st, key)
  $decl nr  $call member_nonroot (st, key)
  $decl es0 $call esc_of_idx (fr, T.cints.nil)
  $decl es  $if nr ($call T.cints.cons (1000, es0)) es0
  $decl ret $if ($call T.cints.is_nil (es)) t
      ($match t (
          $case {$prop tag "func"}
            ($call T.t_func_esc ($call T.tys.val (t.params), $call T.tval (t.result), t.frame,
                $call T.ci_sort ($call T.ci_union (es, $call T.cints.val (t.esc)), T.cints.nil),
                $call T.cints.val (t.marks))),
          $case t t
        ))
}.ret

$decl mod_key_x $func ($decl st proto_lst, $decl mid 0, $decl nm "")
  $if ($call lt (mid, 0)) "" {
    $decl ms   $call find_mod_st (st, mid)
    $decl ret  $match ms (
        $case {$prop tag "cons"}
          ($call concat ($call mod_short (ms.head.path), $call concat (":", nm))),
        $case ms ""
      )
  }.ret

// The member key of a callee naming a module member: `M.f`, or `f` inside the module.
$decl member_key $func ($decl st proto_lst, $decl e benv.node, $decl c Pa.proto_node) $match c (
  $case {$prop tag "name"} {
    $decl f    $call lookup (e, c.text)
    $decl ret2 $if ($if f.hit ($call eq_str (f.bnd.kind, "prop")) false)
                   ($call mod_key_x (st, f.bnd.mod, c.text)) ""
  }.ret2,
  $case {$prop tag "proj_name"} {
    $decl tg   $call nd_val (c.target)
    $decl ret2 $match tg (
        $case {$prop tag "name"} {
          $decl f    $call lookup (e, tg.text)
          $decl ret3 $if f.hit ($call mod_key_x (st, f.bnd.mod, c.field)) ""
        }.ret3,
        $case tg ""
      )
  }.ret2,
  $case c ""
)
$decl lower_prop_func $func ($decl st proto_lst, $decl m proto_mod, $decl nm "",
                             $decl pn Pa.proto_node, $decl n Pa.proto_node) {
  $decl msave $call enter_mod_in (st, $call mod_short (m.path), m.file, m.isctx)
  $decl pe0   $call benv.val (m.penv)
  $decl chk   $call no_caps (st, pe0, pn)
  // §4.10: a member that names its receiver captures it — capture 0, at the type the
  // module recorded — and a projection onto it is a closure over the target (`recv_wrap`).
  $decl rv    $call find_rcv ($call rcv_list.val (st.recvs), m.id)
  $decl rn    $call rcv_name (rv, pn)
  $decl rt    $call rcv_ty (rv)
  $decl pe    $if ($call eq_str (rn, "")) pe0
                  ($call benv.cons ($call bind_ent (rn, "capture", 0, rt), pe0))
  // The defaults see the declaring name as the block (§4.10): the receiver's pointee.
  $decl dpe   $if ($call eq_str (rn, "")) pe0
                  ($call benv.cons ($call bind_ent (rn, "capture", 0, $call deref_ty (rt)), pe0))
  $decl ets   $if ($call eq_str (rn, "")) IR.ints.nil
                  ($call IR.ints.cons ($call intern (st, rt), IR.ints.nil))
  // The index is reserved before the body exists, because the body may name
  // this prop — §4.9 memoises before typing for exactly the same reason.
  $decl idx $call reserve_lifted (st)
  $decl rfn $set st.recvfns ($if ($call eq_str (rn, "")) ($call rcv_list.val (st.recvfns))
                ($call rcv_list.cons ($call rcv_ent (idx, rn, rt), st.recvfns)))
  $decl p0  $call note_prop (st, m.id, $call mdone (nm, "global", idx, T.t_bot, -1, -1))
  // §3.4: where a short call's omitted defaults are evaluated. Before the snapshot,
  // so a first pass that §5.5 rolls back does not take it with it.
  $decl fd    $call note_fdef (st, $call fdef_ent (idx, $call group_items ($call op (pn, 0)), pe,
                  $call mod_short (m.path), m.file, m.isctx, nm))
  // A prop that names itself has to be lowered twice, and the reason is the
  // one place lowering feels the absence of §5.5's knot: it *derives* types,
  // so while the body is being lowered its own result is not known yet and a
  // call to it types as ⊥. The first pass is only for that result — `join`
  // absorbs ⊥, so the body's type comes out right even though one node in it
  // does not — and the second is lowered against it.
  //
  // A prop that does not name itself is lowered once. Checking is a scan of
  // the body's free names, which lifting needs anyway.
  // Naming itself is the commonest reason the first pass is not usable, but
  // not the only one: a *group* of members that name each other has the same
  // problem, and the member reached first does not name itself at all. So the
  // question asked is the real one — did this body read anything whose type
  // was not settled yet — and `nplace` answers it for siblings and self
  // alike. `types.mpl`'s `show` and `show_fields` are such a group, and the
  // node the first pass left behind carried a placeholder into the backend,
  // where `cc` refused the C it produced.
  // DEFER.md: what inference knows of this member and lowering's derived type does not —
  // the parameters it frees and whether its result is root storage (`with_facts`).
  $decl mkey  $call concat ($call mod_short (m.path), $call concat (":", nm))
  $decl mfr   $call member_freed (st, mkey)
  $decl sn    $call take_snap (st)
  $decl q0    $call places (st)
  $decl mf0   $set st.mfree mfr
  // In progress at depth `dx`; a read of an ancestor (a depth below it) defers the retry.
  $decl dx    $call strs.length ($call strs.val (st.lpstack), 0)
  $decl lpu   $set st.lpstack ($call strs.cons ($call int_to_str (idx),
                  $call strs.val (st.lpstack)))
  $decl om    $call P.ival (st.minread)
  $decl mr0   $set st.minread 1000000000
  $decl u0    $call P.ival (st.nunk)
  $decl lf0   $call lower_prop_body (st, pe, nm, pn, T.t_bot, $call prop_rank (m.props, nm, 0), ets,
                  dpe)
  $decl mr1   $call P.ival (st.minread)
  // Lowered again when this member itself was read unsettled — a descendant read has been
  // answered by that descendant's own retry, and an ancestor's will redo this one — or
  // when something not in progress was.
  $decl again $if ($call lt (mr1, dx)) false
                  ($call P.or ($call eq_int (mr1, dx), $call lt (u0, $call P.ival (st.nunk))))
  // Everything the first pass built is discarded, exactly as a self-naming
  // `$prop` discards it: the siblings it lowered were lowered against this
  // member's placeholder, so their lifted bodies are wrong in the same way
  // and have to be built again too.
  // **Before the rollback**, because `fn_ty` reads `lf0`'s interned *indices*
  // and the rollback invalidates them — which is precisely the
  // `nth: index out of range` an earlier attempt at this hit. A `T.proto_ty` is
  // structural, so once it is out it survives, and the second pass re-interns
  // whatever it needs. The other two rollback sites need no such care: they
  // read `v0.ty` / `b0.val.ty`, which are already structural.
  $decl fty $call with_facts (st, $call fn_ty (st, lf0), mkey)
  $decl und $if again ($call put_snap (st, sn)) 0
  // Completed now that the body has given up its result type. The new entry
  // goes in front of the placeholder, which `find_mdone` therefore stops at.
  $decl p1  $call note_prop (st, m.id, $call mdone (nm, "global", idx, fty, -1, -1))
  $decl mf1 $set st.mfree mfr
  $decl lf  $if again
      ($call lower_prop_body (st, pe, nm, pn, fty, $call prop_rank (m.props, nm, 0), ets, dpe))
      lf0
  $decl mf2 $set st.mfree strs.nil
  $decl mr2 $call P.ival (st.minread)
  $decl mrs $set st.minread ($if ($call lt (mr2, om)) mr2 om)
  $decl lpo $set st.lpstack ($call lp_pop ($call strs.val (st.lpstack)))
  $decl put $call put_lifted (st, idx, lf)
  $decl ret $call lres ($call IR.e_global ($call intern (st, fty), idx), fty)
  // Restored after the result is computed, not before: a nested `$import` inside
  // this member has already moved `curmod` on, and everything this member lowers
  // must still be attributed to it.
  $decl mrest $call leave_mod (st, msave)
}.ret

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
                              $decl pn Pa.proto_node, $decl n Pa.proto_node) {
  $decl msave $call enter_mod_in (st, $call mod_short (m.path), m.file, m.isctx)
  $decl pe    $call benv.val (m.penv)
  $decl self  $call mem_str ($call free_names (pn, strs.nil), nm)
  $decl pv    $call fresh_var (st)
  $decl p0    $call note_prop (st, m.id, $call mdone (nm, "pend", pv, T.t_bot, -1, -1))
  $decl sn    $call take_snap (st)
  $decl v0    $call lval ($call lower (st, pe, pn, false))
  $decl und   $if self ($call put_snap (st, sn)) 0
  $decl ty    $if ($call T.occurs (v0.ty, pv)) ($call T.close_var (v0.ty,
      pv)) ($call T.tval (v0.ty))
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
  $decl p2    $call note_prop (st, m.id, $call mdone (nm, "value", 0, ty, v.mod, v.tmpl))
  $decl ret   $call lres4 (v.ir, ty, v.mod, v.tmpl)
  $decl mrest $call leave_mod (st, msave)
}.ret

// §4.9: a template has no runtime value at all, so it is registered once and
// remembered — registering it twice would make two templates of one, and every
// `$specialize` of the second would emit its own copy of everything.
$decl lower_prop_tmpl $func ($decl st proto_lst, $decl m proto_mod, $decl nm "",
                             $decl pn Pa.proto_node, $decl n Pa.proto_node) {
  $decl pe $call benv.val (m.penv)
  $decl gs $call generic_names ($call op (pn, 0), strs.nil)
  // The template's stable key: the module it is written in, and its member name.
  $decl tid $call fresh_tmpl (st, gs, $call op (pn, 1), pe,
                $call concat ($call mod_short (m.path), $call concat ("_", nm)), m.file, "", pn)
  $decl p1  $call note_prop (st, m.id, $call mdone (nm, "tmpl", 0, T.t_unit, -1, tid))
  $decl ret   $call lres4 ($call IR.e_block ($call intern (st, T.t_unit), IR.bslots.nil),
                T.t_unit, -1, tid)
}.ret

// §3.3 makes a file a block, so a module's members are `$decl`s — one cell
// each, initialised once in source order (§4.10), which is a thunk. That is
// the whole difference from a `$prop`, whose value is compile-time and is
// lowered afresh wherever it is named.
$decl tbody $func ($decl v proto_lres, $decl ss IR.ints.node) { $decl val v  $decl slots ss }

// A member's body lowered as a thunk body, with the enclosing frame put aside
// and restored — so it can be done twice and the second result used.
$decl thunk_body $func ($decl st proto_lst, $decl pe benv.node, $decl pn Pa.proto_node,
                        $decl nm "") {
  $decl o   $call take_slots (st)
  // DEFER.md example 12, as a member: the item is `$decl nm pn`, and the owner walk wants it.
  $decl sp  $call P.span_of (pn)
  $decl v   $if ($call Pa.storage_defers (pn))
                ($call lval ($call top_item (st, pe, $call Pa.n_form ("decl", $call Pa.nodes.cons (
                     $call Pa.n_name (nm, sp.line, sp.col), $call Pa.nodes.cons (pn, Pa.nodes.nil)),
                     sp.line, sp.col))))
                ($call lval ($call lower (st, pe, pn, true)))
  $decl r   $call tbody (v, $call take_slots (st))
  $decl b   $call restore_slots (st, o)
  $decl ret r
}.ret

$decl lower_prop_thunk $func ($decl st proto_lst, $decl m proto_mod, $decl nm "",
                              $decl pn Pa.proto_node, $decl n Pa.proto_node) {
  $decl msave $call enter_mod_in (st, $call mod_short (m.path), m.file, m.isctx)
  $decl pe   $call with_index ($call with_scope (m.env, $call mprops.val (m.props), m.id, nm,
                 ($union (false, true))))
  $decl chk $call no_caps (st, pe, pn)
  $decl idx $call reserve_lifted (st)
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
  $decl rs   $call recv_enter (st, nm, pn)
  $decl sn   $call take_snap (st)
  $decl b0   $call thunk_body (st, pe, pn, nm)
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
  $decl bd  $if self ($call thunk_body (st, pe, pn, nm)) b0
  $decl rb  $call recv_put (st, rs)
  $decl vty $call intern (st, t)
  // A member, so exported (§4.14): an importer projects it and reads its static.
  $decl f    $call IR.fn_p (nm, IR.ints.nil, vty, $call IR.ints.val (bd.slots), bd.val.ir,
                  false, true, IR.ints.nil, $call P.sval (st.curfile),
                  $call prop_rank (m.props, nm, 0), true, $call P.sval (st.curmod))
  $decl put   $call put_lifted (st, idx, f)
  $decl ret   $call lres4 ($call IR.e_global (vty, idx), t, bd.val.mod, bd.val.tmpl)
  $decl mrest $call leave_mod (st, msave)
}.ret

$decl lower_prop_ast $func ($decl st proto_lst, $decl m proto_mod, $decl nm "",
                            $decl pn Pa.proto_node, $decl n Pa.proto_node, $decl kd "")
  $if ($call is_form (pn, "template")) ($call lower_prop_tmpl (st, m, nm, pn, n))
      ($if ($call is_form (pn, "func")) ($call lower_prop_func (st, m, nm, pn, n))
           ($if ($call eq_str (kd, "decl")) ($call lower_prop_thunk (st, m, nm, pn, n))
                ($call lower_prop_value (st, m, nm, pn, n))))

$decl lower_prop_new $func ($decl st proto_lst, $decl m proto_mod, $decl nm "",
                            $decl n Pa.proto_node) {
  $decl f $call find_mprop (m.props, nm)
  $decl ret $match f (
      $case {$prop tag "cons"} ($call lower_prop_ast (st, m, nm, f.head.node, n, f.head.kind)),
      $case f ($call lres ($call IR.e_unit ($call err (st, $call concat ("no field '",
          $call concat (nm, "'")), n)), T.t_bot))
    )
}.ret

// A prop whose value is compile-time only — a template, or a module with no
// layout. There is nothing to rebuild but the node itself (§9.3 gives each its
// own index), and rebuilding the *identity* would be wrong.
$decl prop_const $func ($decl st proto_lst, $decl d proto_mdone) {
  $decl t $call T.tval (d.ty)
  $decl ret $call lres4 ($call IR.e_block ($call intern (st, t), IR.bslots.nil), t,
               d.mod, d.tmpl)
}.ret

// A `$union`-valued prop projected a second time. §9.3 gives every node its own
// index, so the tree cannot be shared and something has to be built — but the
// *type* is settled, and for a `$union` deriving it is the whole expense:
// `union_ty` lowers every member to read its type off, and a prop that names
// itself pays §5.5's two passes on top. §4.8a makes the value the **first
// member alone**, and §5.7 never evaluates the ones after it, so a replay
// lowers one member against the join the memo already holds.
//
// Re-deriving it in full is correct and unaffordable: it took `front.mpl` from
// 0.60 GB to 2.67 GB of `P.list` cons cells and over the cap, because prelude's
// `node` is projected at every list operation in the program.
$decl replay_union $func ($decl st proto_lst, $decl m proto_mod,
                          $decl pn Pa.proto_node, $decl d proto_mdone) {
  $decl pe  $call benv.val (m.penv)
  $decl ms  $call group_items ($call op (pn, 0))
  $decl fst $call lval ($call lower (st, pe, $call Pa.nodes.nth (ms, 0), false))
  $decl ty  $call T.tval (d.ty)
  $decl ir  $if ($call T.same (ty, fst.ty)) fst.ir
                ($call IR.e_copy ($call intern (st, ty), fst.ir))
  $decl ret   $call lres4 (ir, ty, d.mod, d.tmpl)
}.ret

// A prop lowered once already and named again. Everything but a `$union` is
// rebuilt by lowering its source afresh, which is what the first projection
// did — cheap for a literal, and required for a block with fields, whose
// `$decl`s take slots in *this* frame and so cannot be copied from another.
$decl lower_prop_replay $func ($decl st proto_lst, $decl m proto_mod, $decl nm "",
                               $decl n Pa.proto_node, $decl d proto_mdone) {
  $decl f $call find_mprop (m.props, nm)
  $decl ret $match f (
      $case {$prop tag "cons"}
        ($if ($call is_form (f.head.node, "union"))
             ($call replay_union (st, m, f.head.node, d))
             ($call lower_prop_ast (st, m, nm, f.head.node, n, f.head.kind))),
      $case f ($call lres ($call IR.e_unit ($call err (st, $call concat ("no field '",
          $call concat (nm, "'")), n)), T.t_bot))
    )
}.ret

$decl lower_prop_in $func ($decl st proto_lst, $decl m proto_mod, $decl nm "",
                           $decl n Pa.proto_node) {
  $decl d $call find_mdone_m (m, nm)
  $decl ret $match d (
      $case {$prop tag "cons"}
        ($if ($call eq_str (d.head.kind, "global")) ($call prop_global (st, d.head))
        ($if ($call eq_str (d.head.kind, "tmpl"))   ($call prop_const (st, d.head))
        ($if ($call eq_str (d.head.kind, "tied"))   ($call prop_const (st, d.head))
        ($if ($call eq_str (d.head.kind, "value"))
             ($if ($call empty_val (d.head.ty)) ($call prop_const (st, d.head))
                  ($call lower_prop_replay (st, m, nm, n, d.head)))
             // §5.5: the name stands for `R` while its own body is derived,
             // and the binder is discharged when that finishes. The tree is
             // a placeholder too — a prop can only reach itself from a
             // type-only position (§5.7), which is never evaluated.
             // The *type* is the placeholder, because that is what §5.5's
             // knot is tied on; the node's own type index is not, because
             // the node is discarded and a placeholder is not a layout.
             ($do ($call bump_place (st))
                  ($call lres ($call IR.e_unit ($call intern (st, T.t_unit)),
                      $call T.t_var (d.head.idx)))))))),
      $case d ($call lower_prop_new (st, m, nm, n))
    )
}.ret

$decl lower_prop $func ($decl st proto_lst, $decl mid 0, $decl nm "", $decl n Pa.proto_node) {
  $decl ms $call find_mod_st (st, mid)
  $decl ret $match ms (
      $case {$prop tag "cons"} ($call lower_prop_in (st, ms.head, nm, n)),
      $case ms ($call lres ($call IR.e_unit ($call err (st,
          "this block's props were not lowered in this file", n)), T.t_bot))
    )
}.ret

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



// DEFER.md step 4: which `allocator` binding storage came from, so `$free` can insist on
// the same one. A binding's identity is its kind, slot and name — the root's is a prim's.
$decl alloc_ident $func ($decl e benv.node) {
  $decl f   $call lookup (e, "allocator")
  $decl b   f.bnd
  $decl ret $if f.hit
      ($call concat (b.kind, $call concat (":", $call concat ($call int_to_str (b.slot),
          $call concat (":", b.name)))))
      ""
}.ret

$decl is_alloc_init $func ($decl n Pa.proto_node)
  $if ($call is_form (n, "alloc")) true
      ($if ($call P.or ($call is_form (n, "mut"), $call is_form (n, "const")))
           ($call is_form ($call op (n, 0), "alloc")) false)

$decl prov_find $func ($decl xs strs.node, $decl k "") $match xs (
  $case {$prop tag "cons"} {
    $decl n   $call len (k)
    $decl hit $if ($call lt (n, $call len (xs.head)))
                  ($call eq_str ($call slice (xs.head, 0, n), k)) false
    $decl ret $if hit ($call slice (xs.head, n, $call len (xs.head)))
                  ($call prov_find ($call strs.val (xs.tail), k))
  }.ret,
  $case xs ""
)

// A call's result came from the root when its callee is a function of the entry file —
// whose type is inference's, so `1000` would be there if its result might not (DEFER.md) —
// answering allocated storage without that entry. A module member's type here is rebuilt by
// lowering and says nothing, so a member — `M.f`, or `f` from inside its module — is asked
// of inference's facts instead (`member_facts`).
$decl call_root $func ($decl st proto_lst, $decl e benv.node, $decl x Pa.proto_node) {
  $decl c   $call op (x, 0)
  $decl mk  $call member_key (st, e, c)
  $decl ret $if ($call not ($call eq_str (mk, "")))
      ($if ($call member_root (st, mk)) ($call P.sval (st.rootid)) "")
      ($match c (
      $case {$prop tag "name"} {
        $decl f    $call lookup (e, c.text)
        $decl ft   $call T.unroll ($call T.tval (f.bnd.ty))
        $decl ret2 $if ($if f.hit ($call eq_str (f.bnd.kind, "global")) false)
            ($match ft (
                $case {$prop tag "func"} {
                  $decl r    $call T.tval (ft.result)
                  $decl al   $match r ($case {$prop tag "ref"} ($call T.is_alloc (r.kind)),
                                       $case r false)
                  $decl nr   $call T.ci_mem ($call T.cints.val (ft.esc), 1000)
                  $decl ret3 $if ($if al ($call not (nr)) false)
                      ($call P.sval (st.rootid)) ""
                }.ret3,
                $case ft ""
              ))
            ""
      }.ret2,
      $case c ""
    ))
}.ret

// The provenance of what slot `sl` is bound to: an `$alloc` (or a view of one) records the
// allocator in scope there; a name already carrying one passes it on.
$decl note_prov $func ($decl st proto_lst, $decl e benv.node, $decl init Pa.proto_node,
                       $decl sl 0) {
  $decl pv  $if ($call is_alloc_init (init)) ($call alloc_ident (e))
      ($if ($call is_form (init, "call")) ($call call_root (st, e, init))
      ($match init (
          $case {$prop tag "name"} {
            $decl f    $call lookup (e, init.text)
            $decl ret2 $if ($if f.hit ($call eq_str (f.bnd.kind, "local")) false)
                ($call prov_find ($call strs.val (st.aprov),
                    $call concat ($call int_to_str (f.bnd.slot), "|")))
                ""
          }.ret2,
          $case init ""
        )))
  $decl ret $if ($call eq_str (pv, "")) ()
      ($do ($set st.aprov ($call strs.cons ($call concat ($call int_to_str (sl),
          $call concat ("|", pv)), $call strs.val (st.aprov)))) ())
}.ret

// DEFER.md: a function's type records which parameters it frees (`128 + i`), only ever
// through the root. Its own parameters get the root's provenance (`lower_func`), and every
// call checks the argument it passes there was drawn from the root too.
$decl frees_at $func ($decl t0 T.proto_ty, $decl i 0) {
  $decl t   $call T.unroll (t0)
  $decl ret $match t (
      $case {$prop tag "func"} ($call T.ci_mem ($call T.cints.val (t.esc), $call add (128, i))),
      $case t false
    )
}.ret

$decl freed_provs $func ($decl t T.proto_ty, $decl i 0, $decl n 0, $decl id "", $decl acc strs.node)
  $if ($call lt (i, n))
      ($call freed_provs (t, $call add (i, 1), n, id,
          $if ($call frees_at (t, i))
              ($call strs.cons ($call concat ($call int_to_str (i), $call concat ("|", id)), acc))
              acc))
      acc

$decl mfree_provs $func ($decl xs strs.node, $decl id "", $decl acc strs.node) $match xs (
  $case {$prop tag "cons"}
    $call mfree_provs ($call strs.val (xs.tail), id,
        $call strs.cons ($call concat (xs.head, $call concat ("|", id)), acc)),
  $case xs acc
)

// Where an argument's storage came from: a name with a recorded provenance, or an `$alloc`.
$decl arg_prov $func ($decl st proto_lst, $decl e benv.node, $decl x Pa.proto_node)
  $if ($call is_alloc_init (x)) ($call alloc_ident (e))
  ($if ($call is_form (x, "call")) ($call call_root (st, e, x))
  ($match x (
      $case {$prop tag "name"} {
        $decl f    $call lookup (e, x.text)
        $decl ret2 $if ($if f.hit ($call eq_str (f.bnd.kind, "local")) false)
            ($call prov_find ($call strs.val (st.aprov),
                $call concat ($call int_to_str (f.bnd.slot), "|")))
            ""
      }.ret2,
      $case x ""
    )))

$decl check_freed $func ($decl st proto_lst, $decl e benv.node, $decl ft T.proto_ty,
                         $decl xs Pa.nodes.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} {
    $decl pv  $if ($call frees_at (ft, i)) ($call arg_prov (st, e, xs.head)) "-"
    $decl chk $if ($call eq_str (pv, "-")) 0
        ($if ($call eq_str (pv, "")) ($call err (st, "the callee frees this argument, so where it came from must be known here: pass a name bound from an $alloc, or an $alloc (DEFER.md)", xs.head))
        ($if ($call eq_str (pv, $call P.sval (st.rootid))) 0
             ($call err (st, "the callee frees this argument through the root allocator, but it came from another (DEFER.md)", xs.head))))
    $decl ret $call check_freed (st, e, ft, $call Pa.nodes.val (xs.tail), $call add (i, 1))
  }.ret,
  $case xs 0
)

// `$free r` (DEFER.md step 4): `r` must be a name this function bound from an `$alloc`, and
// `allocator` here the binding it was drawn from — so the storage goes back to what made it.
// The root's is `raw_free`; any other's is its `free (addr, size)`, through the prim
// `free_in`, whose size only the C compiler knows. Either runs what was registered for the
// storage first: that is the allocator's half of the contract (`defer_at`).
$decl lower_free $func ($decl st proto_lst, $decl e benv.node, $decl n Pa.proto_node,
                        $decl tail P.boolean) {
  $decl r    $call op (n, 0)
  $decl pv   $match r (
      $case {$prop tag "name"} {
        $decl f    $call lookup (e, r.text)
        $decl ret2 $if ($if f.hit ($call eq_str (f.bnd.kind, "local")) false)
            ($call prov_find ($call strs.val (st.aprov),
                $call concat ($call int_to_str (f.bnd.slot), "|")))
            ""
      }.ret2,
      $case r ""
    )
  $decl here $call alloc_ident (e)
  $decl chk  $if ($call eq_str (pv, ""))
      ($call err (st, "$free needs a name this function bound from an $alloc: where else it came from, its allocator is not known here (DEFER.md)", n))
      ($if ($call eq_str (pv, here)) 0
           ($call err (st, "this storage came from another allocator than the one in scope here: $free it where the allocator that made it is (DEFER.md)", n)))
  $decl v    $call lval ($call lower (st, e, r, false))
  $decl uid  $call intern (st, T.t_unit)
  $decl fa   $call lookup (e, "allocator")
  $decl root $if fa.hit ($call T.same ($call T.tval (fa.bnd.ty), T.ffi_alloc)) true
  $decl sp   $call P.span_of (n)
  $decl ir   $if root {
    $decl bt   $call T.t_func ($call T.tys.cons (v.ty, T.tys.nil), T.t_int)
    $decl ft   $call T.t_func ($call T.tys.cons (T.t_int, T.tys.nil), T.t_unit)
    $decl ad   $call IR.e_call ($call intern (st, T.t_int),
                   $call IR.e_prim ($call intern (st, bt), "box_ptr"),
                   $call IR.exprs.cons (v.ir, IR.exprs.nil), false)
    $decl ret3 $call IR.e_call (uid, $call IR.e_prim ($call intern (st, ft), "raw_free"),
                   $call IR.exprs.cons (ad, IR.exprs.nil), tail)
  }.ret3 {
    $decl m    $call as_value (st, $call lower (st, e,
                   $call Pa.n_projn ($call Pa.n_name ("allocator", sp.line, sp.col), "free",
                       sp.line, sp.col), false))
    $decl ft   $call T.t_func ($call T.tys.cons (m.ty, $call T.tys.cons (v.ty, T.tys.nil)),
                   T.t_unit)
    $decl ret3 $call IR.e_call (uid, $call IR.e_prim ($call intern (st, ft), "free_in"),
                   $call IR.exprs.cons (m.ir, $call IR.exprs.cons (v.ir, IR.exprs.nil)), tail)
  }.ret3
  $decl ret  $call lres (ir, T.t_unit)
}.ret

$decl lower_item0 $func ($decl st proto_lst, $decl a proto_blk, $decl it Pa.proto_node)
  $if ($call is_form (it, "decl")) {
    $decl nm  $call name_of ($call op (it, 0))
    $decl rs  $call recv_enter (st, nm, $call op (it, 1))
    $decl rn0 $set st.recname ($if ($call is_form ($call op (it, 1), "func")) nm "")
    $decl v   $call lval ($call lower (st, a.env, $call op (it, 1), false))
    $decl rn1 $set st.recname ""
    $decl rb  $call recv_put (st, rs)
    $decl id  $call intern (st, v.ty)
    $decl ir  $call with_pending (a.pend, v.ir, id)
    $decl sl  $call fresh_slot (st, id)
    $decl apv $call note_prov (st, a.env, $call op (it, 1), sl)
    $decl slf $if ($call lt (-1, v.tmpl)) ($call tmpl_self (st, v.tmpl, nm, "local", sl, v.ty)) 0
    $decl ret   $call blk_acc (
        $call IR.bslots.cons ($call IR.bslot (sl, ir), $call IR.bslots.val (a.slots)),
        $call T.fields.cons ($call T.field (nm, v.ty), $call T.fields.val (a.flds)),
        $call T.props.val (a.prps),
        $call benv.cons ($call bind_ent6 (nm, "local", sl, v.ty, v.mod, v.tmpl),
            $call benv.val (a.env)),
        IR.exprs.nil)
  }.ret
  ($if ($call is_form (it, "prop")) {
    // Erased from the layout, kept in the type (§4.10).
    $decl nm $call name_of ($call op (it, 0))
    $decl cv $call const_of (st, $call op (it, 1))
    $decl ret  $call blk_acc ($call IR.bslots.val (a.slots), $call T.fields.val (a.flds),
        $call T.props.cons ($call T.prop_entry (nm, cv), $call T.props.val (a.prps)),
        $call benv.val (a.env), $call IR.exprs.val (a.pend))
  }.ret
  ($if ($call is_form (it, "fwd")) {
    $decl e   $call err (st, "$fwd is not lowered yet", it)
    $decl ret a
  }.ret
  // §4.15a: registered where it stands, lowered where it runs (`with_defers`, `$try`).
  ($if ($call is_form (it, "defer")) {
    $decl p   $set st.defers ($call dfr_list.cons ($call dfr_ent ($call op (it, 0),
                  $call benv.val (a.env)), st.defers))
    $decl ret a
  }.ret {
    // Runs for effect, discarded (§3.3). Held until the next slot. A block written as an
    // item is a scope (§4.15a).
    $decl sc $set st.nextscope $call is_block_ast (it)
    $decl v $call lval ($call lower (st, a.env, it, false))
    $decl ret $call blk_acc ($call IR.bslots.val (a.slots), $call T.fields.val (a.flds),
        $call T.props.val (a.prps), $call benv.val (a.env),
        $call IR.exprs.cons (v.ir, $call IR.exprs.val (a.pend)))
  }.ret)))

$fwd lower_item

$decl lower_items $func ($decl st proto_lst, $decl a proto_blk, $decl xs Pa.nodes.node) $match xs (
  $case {$prop tag "cons"} {
    $decl a2  $call lower_item (st, a, xs.head)
    $decl ret $call lower_items (st, a2, $call Pa.nodes.val (xs.tail))
  }.ret,
  $case xs a
)

// §4.15a: deferrals lowered for running, each against the environment it was written in,
// in the order they run — newest first, which is the order the stack keeps them in.
$decl lower_dfrs $func ($decl st proto_lst, $decl xs dfr_list.node, $decl n 0,
                        $decl acc IR.exprs.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call lt (0, n)) {
      $decl v   $call lval ($call lower (st, $call benv.val (xs.head.env), xs.head.node, false))
      $decl ir  $if ($call lt (xs.head.flag, 0)) v.ir {
        $decl bid  $call intern (st, T.t_bool)
        $decl uid  $call intern (st, T.t_unit)
        $decl ret2 $call IR.e_if (uid, $call IR.e_local (bid, xs.head.flag),
                       $call IR.e_do (uid, v.ir, $call IR.e_unit (uid)), $call IR.e_unit (uid))
      }.ret2
      $decl ret $call lower_dfrs (st, $call dfr_list.val (xs.tail), $call sub (n, 1),
                    $call IR.exprs.cons (ir, acc))
    }.ret ($call IR.exprs.reverse (acc, IR.exprs.nil)),
  $case xs ($call IR.exprs.reverse (acc, IR.exprs.nil))
)

// A block's own deferrals — those registered since `saved` — run once its value is built
// and before it is used, then taken off the stack. The block's value is the first slot of
// an outer block whose second slot runs them: appending them as slots of the block itself
// would change its layout, and §3.3's trailing effects are folded *around* the block, so
// they would run before its slots.
// The top `k` entries tagged as `key`'s storage, the rest left as they are.
$decl tag_store $func ($decl xs dfr_list.node, $decl k 0, $decl key "", $decl fl -1,
                       $decl rest dfr_list.node)
  $match xs (
    $case {$prop tag "cons"}
      $if ($call lt (0, k))
          ($call dfr_list.cons ($call dfr_ent (xs.head.node, $call benv.val (xs.head.env), key,
               fl),
              $call tag_store ($call dfr_list.val (xs.tail), $call sub (k, 1), key, fl, rest)))
          rest,
    $case xs rest
  )

$decl dfr_pair $func ($decl a dfr_list.node, $decl b dfr_list.node) { $decl sel a  $decl others b }
$decl proto_dpair $call dfr_pair (dfr_list.nil, dfr_list.nil)
// A recursive split's result is §5.5's placeholder while it is being solved, so it is read
// through this, at the type it will have.
$decl dpair_val $func ($decl x proto_dpair) x

// `xs` in front of `ys`.
$decl dfr_join $func ($decl xs dfr_list.node, $decl ys dfr_list.node)
  $call dfr_list.reverse ($call dfr_list.reverse (xs, dfr_list.nil), ys)

// The top `k` entries, in order.
$decl dfr_take $func ($decl xs dfr_list.node, $decl k 0, $decl acc dfr_list.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call lt (0, k)) ($call dfr_take ($call dfr_list.val (xs.tail), $call sub (k, 1),
                               $call dfr_list.cons (xs.head, acc)))
        ($call dfr_list.reverse (acc, dfr_list.nil)),
  $case xs ($call dfr_list.reverse (acc, dfr_list.nil))
)

// The top `k` entries split, each side in order: a block's own (`own`) or its storage's.
$decl dfr_split $func ($decl xs dfr_list.node, $decl k 0, $decl own P.boolean)
  $match xs (
    $case {$prop tag "cons"}
      $if ($call lt (0, k)) {
        $decl r    $call dpair_val ($call dfr_split ($call dfr_list.val (xs.tail), $call sub (k, 1),
                       own))
        $decl mine $call eq_str (xs.head.key, "")
        $decl ret2 $if ($if mine own ($call not (own)))
            ($call dfr_pair ($call dfr_list.cons (xs.head, r.sel), r.others))
            ($call dfr_pair (r.sel, $call dfr_list.cons (xs.head, r.others)))
      }.ret2 ($call dfr_pair (dfr_list.nil, dfr_list.nil)),
    $case xs ($call dfr_pair (dfr_list.nil, dfr_list.nil))
  )

$decl lower_dfr_all $func ($decl st proto_lst, $decl xs dfr_list.node, $decl acc IR.exprs.node)
  $call lower_dfrs (st, xs, $call dfr_list.length (xs, 0), acc)

$decl with_defers $func ($decl st proto_lst, $decl saved dfr_list.node, $decl ir IR.proto_expr,
                         $decl id 0, $decl ty T.proto_ty, $decl isc P.boolean) {
  $decl k0  $call sub ($call dfr_list.length ($call dfr_list.val (st.defers), 0),
                       $call dfr_list.length (saved, 0))
  // A value's own deferrals run at its end; its storage's belong to whatever owns the
  // record (DEFER.md), so they are passed out, still on the stack.
  $decl sp  $call dfr_split ($call dfr_list.val (st.defers), k0, true)
  $decl sel $if isc ($call dfr_take ($call dfr_list.val (st.defers), k0, dfr_list.nil)) sp.sel
  $decl k   $call dfr_list.length (sel, 0)
  $decl ret $if ($call lt (0, k)) {
    $decl run  $call lower_dfr_all (st, sel, IR.exprs.nil)
    $decl back $set st.defers ($if isc saved ($call dfr_join (sp.others, saved)))
    $decl uid  $call intern (st, T.t_unit)
    $decl s0   $call fresh_slot (st, id)
    $decl s1   $call fresh_slot (st, uid)
    // `with_pending` runs its list last first, so the newest-first list goes in reversed.
    $decl d    $call with_pending ($call IR.exprs.reverse (run, IR.exprs.nil),
                   $call IR.e_unit (uid), uid)
    $decl oty  $call T.t_block ($call T.fields.cons ($call T.field ("v", ty),
                   $call T.fields.cons ($call T.field ("d", T.t_unit), T.fields.nil)), T.props.nil)
    $decl oid  $call intern (st, oty)
    $decl ob   $call IR.e_block (oid, $call IR.bslots.cons ($call IR.bslot (s0, ir),
                   $call IR.bslots.cons ($call IR.bslot (s1, d), IR.bslots.nil)))
    $decl ret2 $call IR.e_field (id, ob, 0)
  }.ret2 ir
}.ret

// `ir` with flag slot `fl` set to `v` once it is built, or `ir` itself when there is no
// flag (-1). A `$new` literal in an arm sets its flag true (`lower_block`); the item it is
// in sets it false first (`flag_inits`), since a frame slot starts as nothing.
$decl with_flag $func ($decl st proto_lst, $decl fl 0, $decl v P.boolean, $decl ir IR.proto_expr,
                       $decl id 0, $decl ty T.proto_ty)
  $if ($call lt (fl, 0)) ir {
    $decl bid  $call intern (st, T.t_bool)
    $decl s0   $call fresh_slot (st, id)
    $decl oty  $call T.t_block ($call T.fields.cons ($call T.field ("v", ty),
                   $call T.fields.cons ($call T.field ("f", T.t_bool), T.fields.nil)), T.props.nil)
    $decl oid  $call intern (st, oty)
    $decl ob   $call IR.e_block (oid, $call IR.bslots.cons ($call IR.bslot (s0, ir),
                   $call IR.bslots.cons ($call IR.bslot (fl, $call IR.e_bool (bid, v)),
                       IR.bslots.nil)))
    $decl ret  $call IR.e_field (id, ob, 0)
  }.ret

// A block's effects after its last `$decl` (§3.3) run after its slots. There is no next
// slot to fold them into, and folding them *around* the block — which this used to do —
// ran them first: `{ $decl a $call say (1)  $call say (2) }` said 2 then 1.
$decl with_trail $func ($decl st proto_lst, $decl pd IR.exprs.node, $decl ir IR.proto_expr,
                        $decl id 0, $decl ty T.proto_ty) $match pd (
  $case {$prop tag "cons"} {
    $decl uid  $call intern (st, T.t_unit)
    $decl s0   $call fresh_slot (st, id)
    $decl s1   $call fresh_slot (st, uid)
    $decl d    $call with_pending (pd, $call IR.e_unit (uid), uid)
    $decl oty  $call T.t_block ($call T.fields.cons ($call T.field ("v", ty),
                   $call T.fields.cons ($call T.field ("e", T.t_unit), T.fields.nil)), T.props.nil)
    $decl oid  $call intern (st, oty)
    $decl ob   $call IR.e_block (oid, $call IR.bslots.cons ($call IR.bslot (s0, ir),
                   $call IR.bslots.cons ($call IR.bslot (s1, d), IR.bslots.nil)))
    $decl ret2 $call IR.e_field (id, ob, 0)
  }.ret2,
  $case pd ir
)

// The deferrals' expressions, in the order they run: the stack keeps them newest first.
$decl dfr_nodes $func ($decl xs dfr_list.node, $decl acc Pa.nodes.node) $match xs (
  $case {$prop tag "cons"}
    $call dfr_nodes ($call dfr_list.val (xs.tail), $call Pa.nodes.cons (xs.head.node, acc)),
  $case xs ($call Pa.nodes.reverse (acc, Pa.nodes.nil))
)

// `$alloc { … $defer … }` from a library allocator (DEFER.md step 4): the deferrals, which
// `lower_block` left on the stack, become a `$func ()` over the block's fields — what it
// captures is exactly those, since inference refused anything else — handed to the
// allocator's `defer_at` with the storage's address straight after it is made.
$decl alloc_fin $func ($decl st proto_lst, $decl e benv.node, $decl n Pa.proto_node,
                       $decl saved dfr_list.node, $decl ir IR.proto_expr, $decl rt T.proto_ty) {
  $decl k    $call sub ($call dfr_list.length ($call dfr_list.val (st.defers), 0),
                        $call dfr_list.length (saved, 0))
  $decl top  $call dfr_take ($call dfr_list.val (st.defers), k, dfr_list.nil)
  $decl back $set st.defers saved
  $decl ret  $match top (
      $case {$prop tag "cons"} {
        $decl sp   $call P.span_of (n)
        $decl body $call Pa.n_block ($call dfr_nodes (top, Pa.nodes.nil), sp.line, sp.col)
        $decl fn   $call Pa.n_form ("func", $call Pa.nodes.cons ($call Pa.n_unit (sp.line, sp.col),
                       $call Pa.nodes.cons (body, Pa.nodes.nil)), sp.line, sp.col)
        $decl fv   $call as_value (st, $call lower (st, $call benv.val (top.head.env), fn, false))
        $decl da   $call as_value (st, $call lower (st, e,
                       $call Pa.n_projn ($call Pa.n_name ("allocator", sp.line, sp.col), "defer_at",
                           sp.line, sp.col), false))
        $decl rid  $call intern (st, rt)
        $decl uid  $call intern (st, T.t_unit)
        $decl s0   $call fresh_slot (st, rid)
        $decl s1   $call fresh_slot (st, uid)
        $decl bt   $call T.t_func ($call T.tys.cons (rt, T.tys.nil), T.t_int)
        $decl ad   $call IR.e_call ($call intern (st, T.t_int),
                       $call IR.e_prim ($call intern (st, bt), "box_ptr"),
                       $call IR.exprs.cons ($call IR.e_local (rid, s0), IR.exprs.nil), false)
        $decl dres $call result_of (da.ty)
        $decl dc   $call IR.e_call ($call intern (st, dres), da.ir,
                       $call IR.exprs.cons (ad, $call IR.exprs.cons (fv.ir, IR.exprs.nil)), false)
        $decl dct  $call with_pending ($call IR.exprs.cons (dc, IR.exprs.nil),
                       $call IR.e_unit (uid), uid)
        $decl oty  $call T.t_block ($call T.fields.cons ($call T.field ("v", rt),
                       $call T.fields.cons ($call T.field ("d", T.t_unit), T.fields.nil)),
                       T.props.nil)
        $decl ob   $call IR.e_block ($call intern (st, oty),
                       $call IR.bslots.cons ($call IR.bslot (s0, ir),
                       $call IR.bslots.cons ($call IR.bslot (s1, dct), IR.bslots.nil)))
        $decl ret2 $call IR.e_field (rid, ob, 0)
      }.ret2,
      $case top ir
    )
}.ret

// ------------------------------------------- DEFER.md step 3: whose storage it is
//
// A `$new` literal's deferrals are on the stack, tagged with its key, until the end of
// the block item it was made in. There they are decided: if its place flows into what the
// item's `$decl` binds — that `$decl` is the first to bind it, so it is the owner — they
// stay, and belong to the block the `$decl` is in (a scope runs them at its end; a value
// passes them out to whatever owns the record). Otherwise nothing owns the place any
// more: it is ephemeral, and they run right after the item — the end of the expression
// it was made in, as a full expression ends a C++ temporary. Stage 0 decides the same at
// run time, by whether the bound value reaches the storage.
//
// Flowing is a question about the source: through parentheses, `$if`/`$match` arms (a site
// in one has a flag, so an arm not taken runs nothing of it), `$do`'s second operand,
// `$mut`/`$const`/`$traitsof`, and a record's field initializers. Through a call it only
// *may*: the callee chooses what it hands back, so the item decides at run time, as stage 0
// does (`own_inits`, DEFER.md example 7).
$fwd flows_to

// 0, 1 or 2: does not flow, may (through a call), does.
$decl fmax $func ($decl a 0, $decl b 0) $if ($call lt (a, b)) b a

$decl flows_any $func ($decl st proto_lst, $decl xs Pa.nodes.node, $decl key "", $decl acc 0)
  $match xs (
    $case {$prop tag "cons"}
      $call flows_any (st, $call Pa.nodes.val (xs.tail), key,
          $call fmax (acc, $call flows_to (st, xs.head, key))),
    $case xs acc
  )

$decl flows_fields $func ($decl st proto_lst, $decl xs Pa.nodes.node, $decl key "", $decl acc 0)
  $match xs (
    $case {$prop tag "cons"}
      $call flows_fields (st, $call Pa.nodes.val (xs.tail), key,
          $if ($call is_form (xs.head, "decl"))
              ($call fmax (acc, $call flows_to (st, $call op (xs.head, 1), key))) acc),
    $case xs acc
  )

$decl flows_arms $func ($decl st proto_lst, $decl xs Pa.nodes.node, $decl key "", $decl acc 0)
  $match xs (
    $case {$prop tag "cons"}
      $call flows_arms (st, $call Pa.nodes.val (xs.tail), key,
          $call fmax (acc, $call flows_to (st, $call op (xs.head, 1), key))),
    $case xs acc
  )

// A call may hand back what an argument carries, and which it does is the callee's choice:
// "may", decided at run time (`own_inits`, example 7).
$decl flows_form $func ($decl st proto_lst, $decl n Pa.proto_node, $decl k "", $decl key "")
  $if ($call eq_str (k, "new")) ($if ($call eq_str ($call newlit_key ($call op (n, 0)), key)) 2 0)
  ($if ($call eq_str (k, "if"))
       ($call fmax ($call flows_to (st, $call op (n, 1), key),
           $call flows_to (st, $call op (n, 2), key)))
  ($if ($call eq_str (k, "match"))
       ($call flows_arms (st, $call group_items ($call op (n, 1)), key, 0))
  ($if ($call eq_str (k, "do")) ($call flows_to (st, $call op (n, 1), key))
  ($if ($call eq_str (k, "call"))
       ($if ($call lt (0, $call flows_any (st, $call group_items ($call op (n, 1)), key, 0))) 1 0)
  ($if ($call P.or ($call eq_str (k, "mut"), $call P.or ($call eq_str (k, "const"),
                  $call eq_str (k, "traitsof"))))
       ($call flows_to (st, $call op (n, 0), key))
       0)))))

$decl flows_to $func ($decl st proto_lst, $decl n Pa.proto_node, $decl key "") $match n (
  $case {$prop tag "block"} ($call flows_fields (st, $call Pa.nodes.val (n.items), key, 0)),
  $case {$prop tag "group"} ($call flows_any (st, $call Pa.nodes.val (n.items), key, 0)),
  $case {$prop tag "form"}  ($call flows_form (st, n, n.keyword, key)),
  $case n 0
)

// DEFER.md example 7: storage that may have come back from a call is owned by the item's
// `$decl` only if what it binds reaches it, which is a run-time fact — and stage 0's rule
// (`reaches`). So the item computes it, as stage 0 does: every reference the bound value
// holds by value — itself, a field, a group's item, a union's member — is compared with
// the address the `$new` saved (`newptrs`). Storage holds no place (A0), so the walk
// stops at every reference.
$decl ir_or $func ($decl st proto_lst, $decl a IR.proto_expr, $decl b IR.proto_expr) {
  $decl bid $call intern (st, T.t_bool)
  $decl ret $call IR.e_if (bid, a, $call IR.e_bool (bid, true), b)
}.ret

$decl addr_of $func ($decl st proto_lst, $decl sl 0, $decl t T.proto_ty)
  $call IR.e_call ($call intern (st, T.t_int),
      $call IR.e_prim ($call intern (st, $call T.t_func ($call T.tys.cons (t, T.tys.nil), T.t_int)),
          "box_ptr"),
      $call IR.exprs.cons ($call IR.e_local ($call intern (st, t), sl), IR.exprs.nil), false)

// The walk is a list of paths, one per reference the value can hold — a path is a `Str`
// of steps, `f<i>,` for a field or group index and `m<i>,` for a union's member — and a
// test built per path. Every function here recurses only on itself and uses list types
// lowering already has: a mutually recursive group, and then a new `$specialize P.list`
// first used from inside `finish_item`'s group, each made lowering the whole compiler run
// out of memory (§5.5's retries; CLAUDE.md).
$decl fld_tys $func ($decl xs T.fields.node, $decl acc T.tys.node) $match xs (
  $case {$prop tag "cons"}
    $call fld_tys ($call T.fields.val (xs.tail), $call T.tys.cons ($call T.tval (xs.head.ty), acc)),
  $case xs ($call T.tys.reverse (acc, T.tys.nil))
)
$decl push_tys $func ($decl ts T.tys.node, $decl acc T.tys.node) $match ts (
  $case {$prop tag "cons"} $call push_tys ($call T.tys.val (ts.tail), $call T.tys.cons (ts.head, acc)),
  $case ts acc
)
$decl push_paths $func ($decl ts T.tys.node, $decl i 0, $decl kind "", $decl p "",
                        $decl acc strs.node) $match ts (
  $case {$prop tag "cons"}
    $call push_paths ($call T.tys.val (ts.tail), $call add (i, 1), kind, p,
        $call strs.cons ($call concat (p, $call concat (kind, $call concat ($call int_to_str (i),
            ","))), acc)),
  $case ts acc
)

// Worklists `ts` and `ps` run in step: a type and the path that reached it.
$decl ref_paths $func ($decl st proto_lst, $decl ts T.tys.node, $decl ps strs.node,
                       $decl acc strs.node) $match ts (
  $case {$prop tag "cons"} $match ps (
    $case {$prop tag "cons"} {
      $decl t    $call T.unroll (ts.head)
      $decl p    ps.head
      $decl rt   $call T.tys.val (ts.tail)
      $decl rp   $call strs.val (ps.tail)
      $decl kids $if ($call lt (40, $call len (p))) T.tys.nil ($match t (
          $case {$prop tag "block"} ($call fld_tys ($call T.fields.val (t.fields), T.tys.nil)),
          $case {$prop tag "group"} ($call T.tys.val (t.items)),
          $case {$prop tag "union"} ($call members_of ($call canon_ty (st, ts.head))),
          $case t T.tys.nil
        ))
      $decl kind $match t ($case {$prop tag "union"} "m", $case t "f")
      $decl isr  $match t ($case {$prop tag "ref"} true, $case t false)
      $decl ret  $call ref_paths (st, $call push_tys (kids, rt),
                     $call push_paths (kids, 0, kind, p, rp),
                     $if isr ($call strs.cons (p, acc)) acc)
    }.ret,
    $case ps acc),
  $case ts acc
)

// The number a step starts with at `i`, and where the next step starts.
$decl step_num $func ($decl s "", $decl i 0, $decl acc 0)
  $if ($if ($call lt (i, $call len (s))) ($call not ($call eq_int ($call byte (s, i), 44))) false)
      ($call step_num (s, $call add (i, 1), $call add ($call mul (acc, 10),
          $call sub ($call byte (s, i), 48))))
      acc
$decl step_end $func ($decl s "", $decl i 0)
  $if ($if ($call lt (i, $call len (s))) ($call not ($call eq_int ($call byte (s, i), 44))) false)
      ($call step_end (s, $call add (i, 1))) ($call add (i, 1))

// A union's arms for one path through member `m`: `inner` there, false elsewhere.
$decl path_arms $func ($decl st proto_lst, $decl ms T.tys.node, $decl j 0, $decl m 0,
                       $decl sl 0, $decl inner IR.proto_expr, $decl acc IR.arms.node) $match ms (
  $case {$prop tag "cons"} {
    $decl bid  $call intern (st, T.t_bool)
    $decl hit  $call eq_int (j, m)
    $decl arm  $call IR.arm ($call IR.ints.cons (j, IR.ints.nil), $if hit sl -1,
                   $if hit inner ($call IR.e_bool (bid, false)))
    $decl ret  $call path_arms (st, $call T.tys.val (ms.tail), $call add (j, 1), m, sl, inner,
                   $call IR.arms.cons (arm, acc))
  }.ret,
  $case ms ($call IR.arms.reverse (acc, IR.arms.nil))
)

// The type one step reaches: member `n` of a union (`um`), or part `n` of a block or group.
$decl step_ty $func ($decl st proto_lst, $decl t0 T.proto_ty, $decl um P.boolean, $decl n 0) {
  $decl t   $call T.unroll (t0)
  $decl pts $if um ($call members_of ($call canon_ty (st, t0))) ($match t (
      $case {$prop tag "block"} ($call fld_tys ($call T.fields.val (t.fields), T.tys.nil)),
      $case {$prop tag "group"} ($call T.tys.val (t.items)),
      $case t T.tys.nil
    ))
  $decl ret $call T.tys.nth (pts, n)
}.ret

// One step's test around the next one's, `inner`, which reads slot `s2`: a switch binding
// member `n`, or a block reading part `n` into `s2` and then testing.
$decl step_wrap $func ($decl st proto_lst, $decl sl 0, $decl t0 T.proto_ty, $decl um P.boolean,
                       $decl n 0, $decl ct T.proto_ty, $decl s2 0, $decl inner IR.proto_expr) {
  $decl bid $call intern (st, T.t_bool)
  $decl src $call IR.e_local ($call intern (st, t0), sl)
  $decl ret $if um
      ($call IR.e_switch (bid, src,
          $call path_arms (st, $call members_of ($call canon_ty (st, t0)), 0, n, s2, inner,
              IR.arms.nil),
          $call IR.e_unit ($call intern (st, T.t_unit)))) {
    $decl pid  $call intern (st, ct)
    $decl s3   $call fresh_slot (st, bid)
    $decl oty  $call T.t_block ($call T.fields.cons ($call T.field ("v", ct),
                   $call T.fields.cons ($call T.field ("r", T.t_bool), T.fields.nil)), T.props.nil)
    $decl ob   $call IR.e_block ($call intern (st, oty),
                   $call IR.bslots.cons ($call IR.bslot (s2, $call IR.e_field (pid, src, n)),
                   $call IR.bslots.cons ($call IR.bslot (s3, inner), IR.bslots.nil)))
    $decl ret2 $call IR.e_field (bid, ob, 1)
  }.ret2
}.ret

$decl ref_eq $func ($decl st proto_lst, $decl sl 0, $decl t0 T.proto_ty, $decl pp 0,
                    $decl prt T.proto_ty)
  $call IR.e_call ($call intern (st, T.t_bool), $call IR.e_prim ($call intern (st, $call T.t_func (
      $call T.tys.cons (T.t_int, $call T.tys.cons (T.t_int, T.tys.nil)), T.t_bool)), "eq_int"),
      $call IR.exprs.cons ($call addr_of (st, sl, t0),
          $call IR.exprs.cons ($call addr_of (st, pp, prt), IR.exprs.nil)), false)

// Whether the value in slot `sl` (type `t0`), followed down path `p` from byte `i`, is the
// reference in slot `pp`: an `Int` compare of addresses (§8's `box_ptr`). One self-call,
// in straight-line code: two of them in two arms ran lowering out of memory as well.
$decl path_ir $func ($decl st proto_lst, $decl sl 0, $decl t0 T.proto_ty, $decl p "", $decl i 0,
                     $decl pp 0, $decl prt T.proto_ty)
  $if ($call lt (i, $call len (p))) {
    $decl um   $call eq_int ($call byte (p, i), 109)
    $decl n    $call step_num (p, $call add (i, 1), 0)
    $decl ct   $call step_ty (st, t0, um, n)
    $decl s2   $call fresh_slot (st, $call intern (st, ct))
    $decl in   $call path_ir (st, s2, ct, p, $call step_end (p, i), pp, prt)
    $decl ret  $call step_wrap (st, sl, t0, um, n, ct, s2, in)
  }.ret ($call ref_eq (st, sl, t0, pp, prt))

$decl paths_ir $func ($decl st proto_lst, $decl ps strs.node, $decl sl 0, $decl t T.proto_ty,
                      $decl pp 0, $decl prt T.proto_ty, $decl acc IR.proto_expr) $match ps (
  $case {$prop tag "cons"}
    $call paths_ir (st, $call strs.val (ps.tail), sl, t, pp, prt,
        $call ir_or (st, acc, $call path_ir (st, sl, t, ps.head, 0, pp, prt))),
  $case ps acc
)

// A maybe-owned site: its key, the flags the item sets, and the guard its entries had.
$decl mown $func ($decl k "", $decl o 0, $decl p 0, $decl g -1)
  { $decl key k  $decl ow o  $decl ep p  $decl guard g }
$decl mowns $specialize P.list ($call mown ("", 0, 0, -1))

$decl find_mown $func ($decl xs mowns.node, $decl k "") $match xs (
  $case {$prop tag "cons"} $if ($call eq_str (xs.head.key, k)) xs
      ($call find_mown ($call mowns.val (xs.tail), k)),
  $case xs xs
)

// The maybe-owned sites among the top `k` entries, each with two fresh flags.
$decl mown_sites $func ($decl st proto_lst, $decl xs dfr_list.node, $decl k 0,
                        $decl init Pa.proto_node, $decl acc mowns.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call lt (0, k)) {
      $decl maybe $if ($call eq_str (xs.head.key, "")) false
                      ($call eq_int ($call flows_to (st, init, xs.head.key), 1))
      $decl fm    $call find_mown (acc, xs.head.key)
      $decl seen  $match fm ($case {$prop tag "cons"} true, $case fm false)
      $decl acc2  $if ($if maybe ($call not (seen)) false) {
        $decl bid  $call intern (st, T.t_bool)
        $decl ret3 $call mowns.cons ($call mown (xs.head.key, $call fresh_slot (st, bid),
                       $call fresh_slot (st, bid), xs.head.flag), acc)
      }.ret3 acc
      $decl ret2 $call mown_sites (st, $call dfr_list.val (xs.tail), $call sub (k, 1), init, acc2)
    }.ret2 acc,
  $case xs acc
)

$decl bar_at $func ($decl s "", $decl i 0)
  $if ($call lt (i, $call len (s)))
      ($if ($call eq_int ($call byte (s, i), 124)) i ($call bar_at (s, $call add (i, 1)))) i

// The flags' assignments: `ow` — the site ran (its guard) and the bound value in slot `bsl`
// reaches its storage — and `ep`, the site ran and it does not.
$decl own_inits $func ($decl st proto_lst, $decl ms mowns.node, $decl bsl 0, $decl bty T.proto_ty,
                       $decl acc IR.exprs.node) $match ms (
  $case {$prop tag "cons"} {
    $decl bid  $call intern (st, T.t_bool)
    $decl pv   $call prov_find ($call strs.val (st.newptrs), $call concat (ms.head.key, "|"))
    $decl bar  $call bar_at (pv, 0)
    $decl ps   $call ref_paths (st, $call T.tys.cons (bty, T.tys.nil),
                   $call strs.cons ("", strs.nil), strs.nil)
    $decl r    $if ($call lt (0, $call len (pv)))
                   ($call paths_ir (st, ps, bsl, bty,
                       $call digits_int ($call slice (pv, 0, bar), 0, 0),
                       $call ty_at (st, $call digits_int ($call slice (pv, $call add (bar, 1),
                           $call len (pv)), 0, 0)), $call IR.e_bool (bid, false)))
                   ($call IR.e_bool (bid, false))
    $decl g    ms.head.guard
    $decl owv  $if ($call lt (g, 0)) r
                   ($call IR.e_if (bid, $call IR.e_local (bid, g), r, $call IR.e_bool (bid, false)))
    $decl epv  $call IR.e_if (bid, $call IR.e_local (bid, ms.head.ow), $call IR.e_bool (bid, false),
                   $if ($call lt (g, 0)) ($call IR.e_bool (bid, true)) ($call IR.e_local (bid, g)))
    $decl oty  $call T.t_block ($call T.fields.cons ($call T.field ("o", T.t_bool),
                   $call T.fields.cons ($call T.field ("e", T.t_bool), T.fields.nil)), T.props.nil)
    $decl ob   $call IR.e_block ($call intern (st, oty),
                   $call IR.bslots.cons ($call IR.bslot (ms.head.ow, owv),
                   $call IR.bslots.cons ($call IR.bslot (ms.head.ep, epv), IR.bslots.nil)))
    $decl ret  $call own_inits (st, $call mowns.val (ms.tail), bsl, bty,
                   $call IR.exprs.cons (ob, acc))
  }.ret,
  $case ms acc
)

// The top `k` entries split into what stays — a block's own, and storage flowing into
// `init` when the item binds one — and what is ephemeral, each side in order. Storage that
// may flow (`ms`) goes to both sides, each copy guarded by the flag that says it belongs.
$decl eph_split $func ($decl st proto_lst, $decl xs dfr_list.node, $decl k 0,
                       $decl init Pa.proto_node, $decl isd P.boolean, $decl ms mowns.node)
  $match xs (
    $case {$prop tag "cons"}
      $if ($call lt (0, k)) {
        $decl r    $call dpair_val ($call eph_split (st, $call dfr_list.val (xs.tail),
                       $call sub (k, 1), init, isd, ms))
        $decl m    $if ($call eq_str (xs.head.key, "")) mowns.nil
                       ($call find_mown (ms, xs.head.key))
        $decl stay $if ($call eq_str (xs.head.key, "")) true
                       ($if isd ($call eq_int ($call flows_to (st, init, xs.head.key), 2)) false)
        $decl e    $call benv.val (xs.head.env)
        $decl ret2 $match m (
            $case {$prop tag "cons"}
              ($call dfr_pair (
                  $call dfr_list.cons ($call dfr_ent (xs.head.node, e, xs.head.key, m.head.ow),
                      r.sel),
                  $call dfr_list.cons ($call dfr_ent (xs.head.node, e, xs.head.key, m.head.ep),
                      r.others))),
            $case m
              $if stay ($call dfr_pair ($call dfr_list.cons (xs.head, r.sel), r.others))
                       ($call dfr_pair (r.sel, $call dfr_list.cons (xs.head, r.others)))
          )
      }.ret2 ($call dfr_pair (dfr_list.nil, dfr_list.nil)),
    $case xs ($call dfr_pair (dfr_list.nil, dfr_list.nil))
  )

// `irs`, in the order they run, folded onto an effect's place in `pend` (newest first).
$decl push_after $func ($decl pd IR.exprs.node, $decl irs IR.exprs.node) $match irs (
  $case {$prop tag "cons"}
    $call push_after ($call IR.exprs.cons (irs.head, pd), $call IR.exprs.val (irs.tail)),
  $case irs pd
)

$decl finish_item $func ($decl st proto_lst, $decl a proto_blk, $decl it Pa.proto_node,
                         $decl d0 dfr_list.node, $decl k 0) {
  $decl isd $call is_form (it, "decl")
  $decl ini $if isd ($call op (it, 1)) Pa.proto_node
  $decl ms  $if isd ($call mown_sites (st, $call dfr_list.val (st.defers), k, ini, mowns.nil))
                mowns.nil
  $decl sp  $call eph_split (st, $call dfr_list.val (st.defers), k, ini, isd, ms)
  $decl ret $if ($call dfr_list.is_nil (sp.others)) a {
    $decl put  $set st.defers ($call dfr_join (sp.sel, d0))
    $decl irs0 $call lower_dfr_all (st, sp.others, IR.exprs.nil)
    // The ownership flags are set before anything that reads them (`own_inits`), from the
    // value as it is built — the `$decl`'s own slot is assigned only after this runs, so
    // the value is saved in one of its own (`bv`) first.
    $decl f00  $call T.fields.val (a.flds)
    $decl bty  $match f00 ($case {$prop tag "cons"} ($call T.tval (f00.head.ty)),
                           $case f00 T.t_unit)
    $decl bv   $if ($call mowns.is_nil (ms)) -1 ($call fresh_slot (st, $call intern (st, bty)))
    $decl irs  $if ($call lt (bv, 0)) irs0
                   ($call IR.exprs.reverse ($call own_inits (st, ms, bv, bty, IR.exprs.nil), irs0))
    $decl ret2 $if isd {
      // The newest slot is this `$decl`'s: its value is built, then its storage's
      // deferrals run (`with_trail` runs its list last first).
      $decl s0   $call IR.bslots.val (a.slots)
      $decl f0   $call T.fields.val (a.flds)
      $decl ret3 $match s0 (
          $case {$prop tag "cons"} $match f0 (
            $case {$prop tag "cons"} {
              $decl ty   $call T.tval (f0.head.ty)
              $decl id   $call intern (st, ty)
              $decl i0   $call IR.eval (s0.head.init)
              $decl bi   $if ($call lt (bv, 0)) i0
                  ($call IR.e_field (id, $call IR.e_block ($call intern (st, $call T.t_block (
                      $call T.fields.cons ($call T.field ("v", ty), T.fields.nil), T.props.nil)),
                      $call IR.bslots.cons ($call IR.bslot (bv, i0), IR.bslots.nil)), 0))
              $decl ir   $call with_trail (st, $call IR.exprs.reverse (irs, IR.exprs.nil),
                             bi, id, ty)
              $decl ret4 $call blk_acc ($call IR.bslots.cons ($call IR.bslot (s0.head.slot, ir),
                             $call IR.bslots.val (s0.tail)), f0, $call T.props.val (a.prps),
                             $call benv.val (a.env), $call IR.exprs.val (a.pend))
            }.ret4,
            $case f0 a),
          $case s0 a
        )
    }.ret3
      ($call blk_acc ($call IR.bslots.val (a.slots), $call T.fields.val (a.flds),
           $call T.props.val (a.prps), $call benv.val (a.env),
           $call push_after ($call IR.exprs.val (a.pend), irs)))
  }.ret2
}.ret

// The flags of the top `k` entries, each once (`dfr_ent`).
$decl dfr_flags $func ($decl xs dfr_list.node, $decl k 0, $decl acc IR.ints.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call lt (0, k))
        ($call dfr_flags ($call dfr_list.val (xs.tail), $call sub (k, 1),
            $if ($call lt (xs.head.flag, 0)) acc
                ($if ($call mem_int (acc, xs.head.flag)) acc
                     ($call IR.ints.cons (xs.head.flag, acc)))))
        acc,
  $case xs acc
)

// `ir` with each flag in `fs` set false before it runs.
$decl flag_inits $func ($decl st proto_lst, $decl fs IR.ints.node, $decl ir IR.proto_expr,
                        $decl ty T.proto_ty) $match fs (
  $case {$prop tag "cons"} {
    $decl bid  $call intern (st, T.t_bool)
    $decl id   $call intern (st, ty)
    $decl s0   $call fresh_slot (st, id)
    $decl oty  $call T.t_block ($call T.fields.cons ($call T.field ("f", T.t_bool),
                   $call T.fields.cons ($call T.field ("v", ty), T.fields.nil)), T.props.nil)
    $decl oid  $call intern (st, oty)
    $decl ob   $call IR.e_block (oid, $call IR.bslots.cons ($call IR.bslot (fs.head,
                   $call IR.e_bool (bid, false)), $call IR.bslots.cons ($call IR.bslot (s0, ir),
                       IR.bslots.nil)))
    $decl ret  $call flag_inits (st, $call IR.ints.val (fs.tail), $call IR.e_field (id, ob, 1),
                   ty)
  }.ret,
  $case fs ir
)

// DEFER.md example 10: an item whose arms made storage with deferrals sets those sites'
// flags false first — its `$decl`'s value, or its effect, the newest in `pend`.
$decl item_flags $func ($decl st proto_lst, $decl a proto_blk, $decl it Pa.proto_node,
                        $decl fs IR.ints.node)
  $if ($call IR.ints.is_nil (fs)) a
  ($if ($call is_form (it, "decl")) {
    $decl s0   $call IR.bslots.val (a.slots)
    $decl f0   $call T.fields.val (a.flds)
    $decl ret2 $match s0 (
        $case {$prop tag "cons"} $match f0 (
          $case {$prop tag "cons"}
            ($call blk_acc ($call IR.bslots.cons ($call IR.bslot (s0.head.slot,
                 $call flag_inits (st, fs, $call IR.eval (s0.head.init),
                     $call T.tval (f0.head.ty))),
                 $call IR.bslots.val (s0.tail)), f0, $call T.props.val (a.prps),
                 $call benv.val (a.env), $call IR.exprs.val (a.pend))),
          $case f0 a),
        $case s0 a
      )
  }.ret2 {
    $decl pd   $call IR.exprs.val (a.pend)
    $decl ret2 $match pd (
        $case {$prop tag "cons"}
          ($call blk_acc ($call IR.bslots.val (a.slots), $call T.fields.val (a.flds),
               $call T.props.val (a.prps), $call benv.val (a.env),
               $call IR.exprs.cons ($call flag_inits (st, fs, pd.head, T.t_unit),
                   $call IR.exprs.val (pd.tail)))),
        $case pd a
      )
  }.ret2)

$decl lower_item $func ($decl st proto_lst, $decl a proto_blk, $decl it Pa.proto_node) {
  $decl d0  $call dfr_list.val (st.defers)
  $decl a1  $call lower_item0 (st, a, it)
  $decl k   $call sub ($call dfr_list.length ($call dfr_list.val (st.defers), 0),
                       $call dfr_list.length (d0, 0))
  $decl a2  $call item_flags (st, a1, it,
                $call dfr_flags ($call dfr_list.val (st.defers), k, IR.ints.nil))
  $decl ret $if ($call lt (0, k)) ($call finish_item (st, a2, it, d0, k)) a2
}.ret

// DEFER.md example 12: a deferral whose owner's scope is the program, registered to run at
// its exit — the runtime's stack (`at_exit`), which runs after `main` has returned and its
// answer is printed, newest first. Registering where initialisation reaches it is what
// makes the order the reverse of initialisation across files: an imported module is
// initialised first, so its deferrals run last, and every deferral can still use what it
// imports. It is a `$func ()` lowered in the deferral's own environment, so it captures by
// value what it reads that is not a global; its body is a block, so the deferral is never a
// tail call and nothing on the stack reports a pending one (§6a). One in an arm, or on a
// call that may hand its storage back, is registered only if its flag says so. `tl` when the
// registration is a whole function body — a bare `$defer`'s effect — so in tail position.
$decl exit_reg $func ($decl st proto_lst, $decl d proto_dfr, $decl tl P.boolean) {
  $decl sp   $call P.span_of (d.node)
  $decl body $call Pa.n_block ($call Pa.nodes.cons (d.node, Pa.nodes.nil), sp.line, sp.col)
  $decl fn   $call Pa.n_form ("func", $call Pa.nodes.cons ($call Pa.n_unit (sp.line, sp.col),
                 $call Pa.nodes.cons (body, Pa.nodes.nil)), sp.line, sp.col)
  $decl fv   $call as_value (st, $call lower (st, $call benv.val (d.env), fn, false))
  $decl uid  $call intern (st, T.t_unit)
  $decl ft   $call T.t_func ($call T.tys.cons (fv.ty, T.tys.nil), T.t_unit)
  $decl c    $call IR.e_call (uid, $call IR.e_prim ($call intern (st, ft), "at_exit"),
                 $call IR.exprs.cons (fv.ir, IR.exprs.nil), tl)
  $decl ret  $if ($call lt (d.flag, 0)) c
      ($call IR.e_if (uid, $call IR.e_local ($call intern (st, T.t_bool), d.flag),
           $call IR.e_do (uid, c, $call IR.e_unit (uid)), $call IR.e_unit (uid)))
}.ret

// The top `k` entries of the stack (newest first), registered in the order they were made.
$decl exit_regs $func ($decl st proto_lst, $decl xs dfr_list.node, $decl k 0,
                       $decl acc IR.exprs.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call lt (0, k))
        ($call exit_regs (st, $call dfr_list.val (xs.tail), $call sub (k, 1),
             $call IR.exprs.cons ($call exit_reg (st, xs.head, false), acc)))
        acc,
  $case xs acc
)

// An effect's item: what it ran for (§3.3), then the registrations.
$decl top_eff $func ($decl st proto_lst, $decl a proto_blk, $decl regs IR.exprs.node) {
  $decl uid $call intern (st, T.t_unit)
  $decl ret $call lres ($call with_pending ($call push_after ($call IR.exprs.val (a.pend), regs),
                $call IR.e_unit (uid), uid), T.t_unit)
}.ret

// A file's top-level item whose storage has deferrals (`Pa.storage_defers`), lowered as the
// one item of a block whose scope is the program: `lower_item`'s owner walk decides as it
// does in a function — the ephemeral run at the item's end, a call that may hand the
// storage back gets its run-time flags — and what that leaves is the owner's, so it is
// registered (`exit_regs`). A `$decl`'s value, or unit for an effect. A value whose
// storage has deferrals is never a module or a template, so the result carries neither.
$decl top_item $func ($decl st proto_lst, $decl e benv.node, $decl it Pa.proto_node) {
  $decl d0   $call dfr_list.val (st.defers)
  $decl a    $call lower_item (st, $call blk_acc (IR.bslots.nil, T.fields.nil, T.props.nil, e,
                 IR.exprs.nil), it)
  $decl k    $call sub ($call dfr_list.length ($call dfr_list.val (st.defers), 0),
                        $call dfr_list.length (d0, 0))
  $decl regs $call exit_regs (st, $call dfr_list.val (st.defers), k, IR.exprs.nil)
  $decl back $set st.defers d0
  $decl s0   $call IR.bslots.val (a.slots)
  $decl f0   $call T.fields.val (a.flds)
  $decl ret  $match s0 (
      $case {$prop tag "cons"} $match f0 (
        $case {$prop tag "cons"} {
          $decl ty   $call T.tval (f0.head.ty)
          $decl id   $call intern (st, ty)
          $decl bt   $call T.t_block ($call T.fields.cons ($call T.field (f0.head.name, ty),
                         T.fields.nil), T.props.nil)
          $decl v    $call IR.e_field (id, $call IR.e_block ($call intern (st, bt),
                         $call IR.bslots.cons (s0.head, IR.bslots.nil)), 0)
          $decl ret2 $call lres ($call with_trail (st, $call IR.exprs.reverse (regs, IR.exprs.nil),
                         v, id, ty), ty)
        }.ret2,
        $case f0 ($call top_eff (st, a, regs))),
      $case s0 ($call top_eff (st, a, regs))
    )
}.ret

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
// A props-bearing block literal is a module (§4.5: a block is scope, record, module,
// namespace and trait at once), so it needs a name — and like a `$prop`'s own identity
// it is **where it is written**: the module in scope and the first prop's span.
//
// This is where a specialisation's members actually come from, which took finding. The
// generics module `spec_build` creates holds only the bindings for `T`; the template's
// *body* is an ordinary block with props, lowered through here, and it used to take
// `fresh_mod`'s empty path — so every `cons`, `nth` and `reverse` in the program was
// named `mpl_fe_<n>` off the **entry file's** rank counter. `spec_build` entering the
// specialisation's key is what makes the body's key distinguish instantiations.
//
// Built once per block literal in the *source*, not per value, so the string costs
// nothing that scales with the program's run.
$decl blk_key $func ($decl st proto_lst, $decl ps mprops.node) $match ps (
  $case {$prop tag "cons"} {
    $decl sp $call P.span_of (ps.head.node)
    $decl ret  $call concat ($call P.sval (st.curmod),
                 $call concat ("_b", $call concat ($call int_to_str (sp.line),
                 $call concat ("_", $call int_to_str (sp.col)))))
  }.ret,
  $case ps ($call P.sval (st.curmod))
)

$decl lower_block $func ($decl st proto_lst, $decl e benv.node, $decl xs Pa.nodes.node,
    $decl x P.proto_span) {
  // §4.10: the block a `$decl` is declaring claims its receiver, by the literal's span.
  $decl mine $call and ($call not ($call eq_str ($call P.sval (st.rname), "")),
                 $call and ($call eq_int ($call P.ival (st.rline), x.line),
                           $call eq_int ($call P.ival (st.rcol), x.col)))
  $decl rn   $call P.sval (st.rname)
  $decl rq   $call P.sval (st.rqual)
  $decl rk   $call P.sval (st.rkind)
  $decl dfs  $call dfr_list.val (st.defers)
  // Adopted by the declaring block: left on the stack, so its end and any `$try` run them.
  // Read on entry, since the literal's own `$decl`s set the mark afresh.
  $decl kept $call eq_str ($call P.sval (st.keepat), $call keep_key (x.line, x.col))
  $decl kc   $if kept ($set st.keepat "") ($call P.sval (st.keepat))
  $decl isc  $call P.bval (st.nextscope)
  $decl ns0  $set st.nextscope false
  $decl a  $call lower_items (st, $call blk_acc (IR.bslots.nil, T.fields.nil, T.props.nil,
                                                 e, IR.exprs.nil), xs)
  $decl ty $call T.t_block ($call T.fields.reverse ($call T.fields.val (a.flds), T.fields.nil),
                            $call T.props.val (a.prps))
  $decl id $call intern (st, ty)
  $decl ir0 $call with_trail (st, $call IR.exprs.val (a.pend),
      $call IR.e_block (id, $call IR.bslots.reverse ($call IR.bslots.val (a.slots),
          IR.bslots.nil)), id, ty)
  // In an arm, the literal may not run: a flag set once it has is what its deferrals ask.
  $decl fl $if ($if kept ($call lt (0, $call P.ival (st.armdepth))) false)
               ($call fresh_slot (st, $call intern (st, T.t_bool))) -1
  $decl ir $if kept
      ($do ($set st.defers ($call tag_store ($call dfr_list.val (st.defers),
                $call sub ($call dfr_list.length ($call dfr_list.val (st.defers), 0),
                           $call dfr_list.length (dfs, 0)),
                $call keep_key (x.line, x.col), fl, dfs)))
           ($call with_flag (st, fl, true, ir0, id, ty)))
      ($call with_defers (st, dfs, ir0, id, ty, isc))
  $decl ps $call block_props (xs, mprops.nil)
  $decl md $if ($call mprops.is_nil (ps)) -1
               ($call fresh_mod_in (st, ps, a.env, "", $call blk_key (st, ps),
                   $call P.sval (st.curfile)))
  $decl reg $if ($call lt (md, 0)) 0 ($call note_opaqs (st, md, ps))
  // Captured as a reference (§4.10: "the receiver is a reference with the qualifier of
  // what the block was declared as") — read-only for a value, mutable for `$mut` storage —
  // to the block, or for an `$impl`'s override to the `$impl`'s result, which is what the
  // `$decl` over it holds (§4.12). See `recv_wrap`.
  $decl imp $call and ($call eq_int ($call P.ival (st.rbline), x.line),
                $call eq_int ($call P.ival (st.rbcol), x.col))
  $decl rty $if imp ($call T.impl_ty ($call T.tval (st.rbase), $call T.props.val (a.prps))) ty
  $decl rct $if ($call eq_str (rq, "mut"))
                ($call T.t_ref_k ("mut", rty, $if ($call eq_str (rk, "alloc")) T.k_alloc ""))
                ($call T.t_ref ("const", rty))
  $decl rcv $set st.recvs ($if ($call and (mine, $call not ($call lt (md, 0))))
                ($call rcv_list.cons ($call rcv_ent (md, rn, rct), st.recvs))
                ($call rcv_list.val (st.recvs)))
  $decl ret $call lres3 (ir, ty, md)
}.ret

// §4.9's instance, completing the `$fwd` above `spec_reuse_inst`: it needs the block
// machinery, which is here.
// One instance. `md` and `prps` are the props module and the props' values: made
// here on the first use (`fresh` true), handed in from the memo on every later one.
// The value is the instance block, reached through an outer block whose first slots
// hold the arguments — the IR has no other way to give a slot an initializer, and
// the generics must not become fields of the instance (§4.9 binds them, it does not
// prepend them to the layout).
$decl spec_inst $func ($decl st proto_lst, $decl e benv.node, $decl r proto_tmpl,
                       $decl args  Pa.nodes.node, $decl gm 0, $decl md0 0, $decl bty0 T.proto_ty,
                       $decl fresh P.boolean, $decl n Pa.proto_node) {
  $decl items $call body_items (r.body)
  $decl dfs $call dfr_list.val (st.defers)
  $decl ga  $call bind_args (st, e, $call strs.val (r.generics), args,
                $call gen_acc ($call benv.val (r.env), IR.bslots.nil, T.fields.nil))
  $decl a   $call lower_items (st, $call blk_acc (IR.bslots.nil, T.fields.nil, T.props.nil,
                $call benv.val (ga.env), IR.exprs.nil), $call drop_props (items, Pa.nodes.nil))
  $decl prps $if fresh ($call inst_props (st, items, T.props.nil)) ($call props_of_ty (bty0))
  $decl ps   $call block_props (items, mprops.nil)
  // The props see the template's environment and the generics as props — never the
  // instance's slots, since §4.10 forbids a prop reading an ordered sibling.
  $decl md  $if fresh
      ($if ($call mprops.is_nil (ps)) -1
           ($call fresh_mod_in (st, ps, $call with_gens (r.env, $call strs.val (r.generics), gm),
                "", $call blk_key (st, ps), $call P.sval (st.curfile))))
      md0
  $decl reg $if ($call and (fresh, $call lt (-1, md))) ($call note_opaqs (st, md, ps)) 0
  $decl ity $call T.t_block ($call T.fields.reverse ($call T.fields.val (a.flds), T.fields.nil),
      prps)
  $decl iid $call intern (st, ity)
  $decl iir0 $call with_trail (st, $call IR.exprs.val (a.pend),
      $call IR.e_block (iid,
          $call IR.bslots.reverse ($call IR.bslots.val (a.slots), IR.bslots.nil)), iid, ity)
  $decl iir $call with_defers (st, dfs, iir0, iid, ity, false)
  $decl ng  $call strs.length (r.generics, 0)
  $decl isl $call fresh_slot (st, iid)
  $decl oty $call T.t_block ($call T.fields.reverse (
                $call T.fields.cons ($call T.field ("$inst", ity), $call T.fields.val (ga.flds)),
                T.fields.nil), T.props.nil)
  $decl oid $call intern (st, oty)
  $decl oir $call IR.e_block (oid, $call IR.bslots.reverse (
                $call IR.bslots.cons ($call IR.bslot (isl, iir), $call IR.bslots.val (ga.slots)),
                IR.bslots.nil))
  $decl ret $call lres3 ($call IR.e_field (iid, oir, ng), ity, md)
}.ret

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
    $if ($call self_tails (xs.head, i)) true
        ($call self_tails_list ($call IR.exprs.val (xs.tail), i)),
  $case xs false
)

$decl self_tails_arms $func ($decl xs IR.arms.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call self_tails (xs.head.body, i)) true ($call self_tails_arms (xs.tail, i)),
  $case xs false
)

$decl self_tails $func ($decl e IR.proto_expr, $decl i 0) $match e (
  $case {$prop tag "call"} {
    $decl c $call IR.eval (e.callee)
    $decl ret $match c (
        $case {$prop tag "global"} ($if e.tail ($call eq_int (c.fn, i)) false),
        // A local `$func` calling itself is a closure over itself (P10).
        $case {$prop tag "closure"} ($if e.tail ($call eq_int (c.fn, i)) false),
        $case c false
      )
  }.ret,
  // Only tail position matters, so the arms of an `$if` and the second operand
  // of a `$do` — never the condition or the first operand (§7.7).
  $case {$prop tag "if"}
    $if ($call self_tails (e.then, i)) true
        ($call self_tails (e.els, i)),
  $case {$prop tag "do"} ($call self_tails (e.then, i)),
  $case {$prop tag "switch"}
    $if ($call self_tails_arms ($call IR.arms.val (e.arms), i)) true
        ($call self_tails (e.default, i)),
  $case e false
)

// ------------------------------------------------- mutually recursive groups
//
// §6a: a direct self tail call is a loop, but a *mutual* one is not — the group
// has to become one function with a state variable and one dispatch loop. The
// group is a strongly connected component of the tail-call graph, which §4.11's
// `$fwd` guarantees is knowable: the slots are completed in one block.

$decl edge       $func ($decl a 0, $decl b 0) { $decl from a  $decl to b }
$decl proto_edge $call edge (0, 0)
$decl edges      $specialize P.list proto_edge

$fwd tail_targets

$decl tail_targets_arms $func ($decl xs IR.arms.node, $decl acc IR.ints.node) $match xs (
  $case {$prop tag "cons"}
    $call tail_targets_arms (xs.tail, $call tail_targets (xs.head.body, acc)),
  $case xs acc
)

// Only tail position counts (§7.7): the arms of an `$if`, the second operand
// of a `$do`, the arms and default of a `$switch`.
$decl tail_targets $func ($decl e IR.proto_expr, $decl acc IR.ints.node) $match e (
  $case {$prop tag "call"} {
    $decl c $call IR.eval (e.callee)
    $decl ret $match c (
        $case {$prop tag "global"}
          $if e.tail ($if ($call mem_int (acc, c.fn)) acc ($call IR.ints.cons (c.fn, acc))) acc,
        $case c acc
      )
  }.ret,
  $case {$prop tag "if"}
    $call tail_targets (e.els, $call tail_targets (e.then, acc)),
  $case {$prop tag "do"} ($call tail_targets (e.then, acc)),
  $case {$prop tag "switch"}
    $call tail_targets (e.default,
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

// The tail-call graph with every edge turned around. Mutual reachability is an
// *intersection* — `j` is in `i`'s component exactly when `i` reaches `j` and `j`
// reaches `i` — and reaching `i` backwards is reaching it forwards along these.
// One list, built once, and the backward search is then the same code as the
// forward one.
$decl rev_edges $func ($decl es edges.node, $decl acc edges.node) $match es (
  $case {$prop tag "cons"}
    $call rev_edges (es.tail, $call edges.cons ($call edge (es.head.to, es.head.from), acc)),
  $case es acc
)

$fwd reach_add

// Depth first, accumulating the visited set rather than answering one question
// about it. `acc` is the termination argument: the graph is finite and it only
// grows. A node lands in its own set exactly when a cycle returns to it, which is
// what makes the intersection below mean what it should.
$decl reach_edges $func ($decl es edges.node, $decl all edges.node, $decl a 0,
                         $decl acc IR.ints.node) $match es (
  $case {$prop tag "cons"}
    $if ($call eq_int (es.head.from, a))
        ($call reach_edges (es.tail, all, a, $call reach_add (all, es.head.to, acc)))
        ($call reach_edges (es.tail, all, a, acc)),
  $case es acc
)

$decl reach_add $func ($decl all edges.node, $decl b 0, $decl acc IR.ints.node)
  $if ($call mem_int (acc, b)) acc
      ($call reach_edges (all, all, b, $call IR.ints.cons (b, acc)))

$decl reach_from $func ($decl es edges.node, $decl a 0)
  $call reach_edges (es, es, a, IR.ints.nil)

// Everything mutually reachable with `i`, itself included, in ascending order —
// `find_groups` needs the order, because it keeps a component only at its lowest
// member. `fw` and `bw` are computed once per `i` by the caller; this used to run
// two whole depth-first searches *per pair*, which is 2n² of them over the table
// against 2n now, each one scanning the entire edge list.
$decl scc_of $func ($decl fw IR.ints.node, $decl bw IR.ints.node, $decl i 0, $decl j 0,
                    $decl n 0, $decl acc IR.ints.node)
  $if ($call not ($call lt (j, n))) ($call IR.ints.reverse (acc, IR.ints.nil))
      ($call scc_of (fw, bw, i, $call add (j, 1), n,
          $if ($call eq_int (i, j)) ($call IR.ints.cons (j, acc))
              ($if ($call and ($call mem_int (fw, j), $call mem_int (bw, j)))
                   ($call IR.ints.cons (j, acc)) acc)))

// One entry per component, recorded against its lowest member so a component
// is not emitted once per member.
$decl find_groups $func ($decl es edges.node, $decl rev edges.node, $decl i 0, $decl n 0,
                         $decl acc IR.groups.node)
  $if ($call not ($call lt (i, n))) ($call IR.groups.reverse (acc, IR.groups.nil)) {
    $decl g $call scc_of ($call reach_from (es, i), $call reach_from (rev, i),
                i, 0, n, IR.ints.nil)
    $decl keep $match g (
        $case {$prop tag "cons"}
          // More than one member, and this is the lowest of them.
          $if ($call eq_int (g.head, i)) {
            $decl rest $call IR.ints.val (g.tail)
            $decl ret2 $match rest ($case {$prop tag "cons"} true, $case rest false)
          }.ret2
              false,
        $case g false
      )
    $decl ret $call find_groups (es, rev, $call add (i, 1), n,
                $if keep ($call IR.groups.cons ($call IR.group_of (g), acc)) acc)
  }.ret

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
                       $decl fts  T.fields.node, $decl acc IR.fns.node,
                       $decl effi eff_items.node, $decl k 0)
  $match fts (
  $case {$prop tag "cons"} {
    // §4.10: whatever stands before this field in source order runs before it,
    // and sees exactly the names bound so far — which is what `e` holds here.
    $decl sp   $call eff_split (st, e, effi, k)
    $decl nm   fts.head.name
    $decl fty  fts.head.ty
    $decl it   $call find_completing (items, nm)
    $decl init $call op (it, 1)
    // §3.4: an entry-file function's defaults are evaluated in the file's scope.
    $decl fd   $if ($call is_form (init, "func"))
        ($call note_fdef (st, $call fdef_ent ($call IR.fns.length (acc, 0),
             $call group_items ($call op (init, 0)), e, "", "", "", nm))) 0
    $decl fm   $if ($call is_form (init, "func"))
        ($call topfn ($call lower_func (st, e, nm, init, fty, IR.ints.nil), -1, -1)) {
          // A thunk: no parameters, the value as its body (§7.2's frame is
          // whatever slots the initializer needed).
          $decl reset $call take_slots (st)
          $decl rs    $call recv_enter (st, nm, init)
          // DEFER.md example 12: storage with deferrals, owned at the program's scope.
          $decl v     $if ($call Pa.storage_defers (init)) ($call lval ($call top_item (st, e, it)))
                          ($call lval ($call lower (st, e, init, true)))
          $decl rb    $call recv_put (st, rs)
          $decl vty   $call intern (st, v.ty)
          $decl ret2     $call topfn ($call IR.fn_p (nm, IR.ints.nil, vty, $call take_slots (st),
                              v.ir, false, true, IR.ints.nil,
                              $call P.sval (st.curfile), $call next_rank (st), false,
                              $call P.sval (st.curmod)),
                          v.mod, v.tmpl)
        }.ret2
    $decl f   fm.fn
    $decl idx $call IR.fns.length (acc, 0)
    $decl slf  $if ($call lt (-1, fm.tmpl))
        ($call tmpl_self (st, fm.tmpl, nm, "global", idx, $call ty_at (st, f.result))) 0
    // A top-level `$decl` whose value is a block with props is a module, and
    // one whose value is a `$template` is a template — neither of which the
    // environment built up front could know, because the initializer had not
    // been lowered yet. The binding is re-bound in front of the original, so
    // every *later* item sees it (§4.10, source order), and an earlier
    // forward reference still sees the plain global.
    //
    // It is re-bound with the type lowering *gave* it, not the one inference
    // solved. The two used to differ outright — a module's value was the empty
    // block while inference listed every member as a field — and binding
    // inference's made §9's own re-exports (`$decl ir IR`, `$decl types T`)
    // emit a thunk declared to return the member block and returning the empty
    // one. A module's value is its record now (`mod_value`), so they agree in
    // shape; lowering's is still the one to bind, because it is the type the
    // thunk's body actually has. Members resolve through `mod` either way:
    // `lower_proj` asks the module before the type, so naming a member never
    // reads the record.
    $decl e2   $if ($call and ($call lt (fm.mod, 0), $call lt (fm.tmpl, 0))) e
                   ($call benv.cons ($call bind_ent6 (nm, "global", idx,
                        $call ty_at (st, f.result), fm.mod, fm.tmpl), e))
    $decl ret    $call lower_top (st, e2, items, $call T.fields.val (fts.tail),
                   $call IR.fns.cons (f, acc), $call eff_items.val (sp),
                   $call add (k, 1))
  }.ret,
  // Anything after the last `$decl` still runs (§3.3), so the tail consumes
  // what is left rather than dropping it.
  $case fts {
    $decl sp  $call eff_split (st, e, effi, k)
    $decl ret $call fns_acc ($call IR.fns.reverse (acc, IR.fns.nil), 0)
  }.ret
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
        // A copy, so `mod` and `rank` come across — they are this function's name —
        // and `pub` with them, which is its linkage.
        $call IR.fns.cons ($call IR.fn_p (xs.head.name, xs.head.params, xs.head.result,
            xs.head.slots, $call IR.eval (xs.head.body),
            $call self_tails (xs.head.body, i), xs.head.thunk, xs.head.env,
            xs.head.mod, xs.head.rank, xs.head.pub, xs.head.nmod),
            acc)),
  $case xs ($call IR.fns.reverse (acc, IR.fns.nil))
)

// `fty` is what `check_file` returned for this file (§3.3). Only `$decl` items
// are lowered; a top-level `$prop` or a bare expression is out of the subset
// for a program's top level and reported rather than guessed at.
// The end of the file, where every pending read can be answered: §4.10 makes a prop's
// value part of its block's type, so the identity the read was given names one prop,
// and by now the block holding it has been lowered — something in the program builds
// the value the read is of. Resolving can lower more code and so defer more reads,
// hence the loop; it is bounded because every round lowers something new or stops.
$decl resolve_one $func ($decl st proto_lst, $decl p proto_pend) {
  $decl mid $call prop_by_id ($call opq_list.val (st.opaqs), p.id, p.name)
  $decl ret $if ($call lt (mid, 0))
      ($call err (st, $call concat ("the value of prop '",
          $call concat (p.name, "' is not reachable: no block in this program carries it")), p.node)) {
        $decl reset $call take_slots (st)
        $decl v     $call lval ($call lower_prop (st, mid, p.name, p.node))
        // P11: a member that names its receiver needs it as its environment, and a read
        // deferred here built no closure — so it would be called with none. Every route
        // to that is meant to be closed before this (`src_unseen`); say so if one is not.
        $decl vir   v.ir
        $decl rcv   $match vir (
            $case {$prop tag "global"}
              $if ($call has_recvfn (st, vir.fn))
                  ($call err (st, $call concat ("'", $call concat (p.name,
                      "' names its receiver and was reached before its block was lowered")),
                      p.node)) 0,
            $case vir 0
          )
        // Not `pub` by accident: the read may be in any module's output, and this
        // function lives in the entry file's. Named from the prop's identity rather
        // than ranked off a counter: `pub` puts a name in the member space, where a
        // counter's rank collides with a member's.
        $decl f     $call IR.fn_p (p.name, IR.ints.nil, $call intern (st, p.ty),
                        $call take_slots (st), v.ir, false, true, IR.ints.nil,
                        "", p.id, true, $call concat ("e_", $call concat (p.name, "_prop")))
        $decl put  $call put_lifted (st, p.idx, f)
        $decl back $call restore_slots (st, reset)
        $decl ret2 0
      }.ret2
}.ret

$decl resolve_list $func ($decl st proto_lst, $decl ps pend_list.node) $match ps (
  $case {$prop tag "cons"}
    $do ($call resolve_one (st, ps.head)) ($call resolve_list (st, $call pend_list.val (ps.tail))),
  $case ps 0
)

$decl resolve_pends $func ($decl st proto_lst, $decl rounds 0) {
  $decl ps $call pend_list.val (st.pends)
  $decl ret  $if ($call pend_list.is_nil (ps)) 0 {
    $decl cleared $set st.pends pend_list.nil
    $decl d       $call resolve_list (st, ps)
    $decl ret2    $if ($call lt (rounds, 64)) ($call resolve_pends (st, $call add (rounds, 1))) 0
  }.ret2
}.ret

// ------------------------------------------------- records nothing reads
//
// A module's value is its record (`mod_value`), so every `$decl M $import …` thunk
// builds one — and almost nothing reads it, since `M.f` resolves at compile time
// without touching the value. A record is a block of global reads, so computing it
// has no effect; if no node in the program reads the static it is assigned to, the
// value is unobservable and the thunk can compute the empty block instead. That took
// the emitted compiler's size back down, where every module binding had made it ~14%
// bigger for records nothing used.
//
// This is a pass over the finished table on purpose. Deciding it *during* lowering —
// building a record only where a module is used as a value — needs the decision in
// `lower_name` or `lower`'s dispatch, and every arrangement of that tried made lowering
// `lower.mpl` itself as a module run out of memory (see `mod_value`). Here nothing in
// lowering's knot changes.
//
// Kept is a fixed point, not one scan: `$decl ir IR` is a thunk that reads `IR`'s
// static, so `IR`'s record is used exactly when `ir`'s is.
$fwd pure_slots

$decl pure_rec $func ($decl x IR.proto_expr) $match x (
  $case {$prop tag "block"} ($call pure_slots ($call IR.bslots.val (x.slots))),
  $case x false
)

$decl pure_slots $func ($decl xs IR.bslots.node) $match xs (
  $case {$prop tag "cons"} {
    $decl v  $call IR.eval (xs.head.init)
    $decl ok $match v (
        $case {$prop tag "global"} true,
        $case {$prop tag "block"} ($call pure_rec (v)),
        $case v false
      )
    $decl ret $if ok ($call pure_slots ($call IR.bslots.val (xs.tail))) false
  }.ret,
  $case xs true
)

// Thunks whose whole body is a non-empty pure record.
$decl rec_cands $func ($decl fs IR.fns.node, $decl i 0, $decl acc IR.ints.node) $match fs (
  $case {$prop tag "cons"} {
    $decl f fs.head
    $decl b $call IR.eval (f.body)
    $decl ok $if f.thunk
        ($match b (
            $case {$prop tag "block"}
              ($if ($call IR.bslots.is_nil ($call IR.bslots.val (b.slots))) false
                   ($call pure_rec (b))),
            $case b false
          ))
        false
    $decl ret  $call rec_cands ($call IR.fns.val (fs.tail), $call add (i, 1),
                 $if ok ($call IR.ints.cons (i, acc)) acc)
  }.ret,
  $case fs acc
)

$fwd grefs

$decl grefs_list $func ($decl xs IR.exprs.node, $decl cs IR.ints.node, $decl acc IR.ints.node)
    $match xs (
  $case {$prop tag "cons"}
    $call grefs_list ($call IR.exprs.val (xs.tail), cs, $call grefs (xs.head, cs, acc)),
  $case xs acc
)

$decl grefs_slots $func ($decl xs IR.bslots.node, $decl cs IR.ints.node, $decl acc IR.ints.node)
    $match xs (
  $case {$prop tag "cons"}
    $call grefs_slots ($call IR.bslots.val (xs.tail), cs, $call grefs (xs.head.init, cs, acc)),
  $case xs acc
)

$decl grefs_arms $func ($decl xs IR.arms.node, $decl cs IR.ints.node, $decl acc IR.ints.node)
    $match xs (
  $case {$prop tag "cons"} $call grefs_arms (xs.tail, cs, $call grefs (xs.head.body, cs, acc)),
  $case xs acc
)

// The candidates `x` names. Only candidates are collected, so the set stays small.
$decl gref_add $func ($decl i 0, $decl cs IR.ints.node, $decl acc IR.ints.node)
  $if ($call mem_int (cs, i)) ($if ($call mem_int (acc, i)) acc ($call IR.ints.cons (i, acc))) acc

$decl gref_fns $func ($decl xs IR.ints.node, $decl cs IR.ints.node, $decl acc IR.ints.node)
    $match xs (
  $case {$prop tag "cons"}
    $call gref_fns ($call IR.ints.val (xs.tail), cs, $call gref_add (xs.head, cs, acc)),
  $case xs acc
)

$decl grefs $func ($decl x IR.proto_expr, $decl cs IR.ints.node, $decl acc IR.ints.node) $match x (
  $case {$prop tag "global"}  ($call gref_add (x.fn, cs, acc)),
  $case {$prop tag "closure"}
    ($call grefs_list ($call IR.exprs.val (x.captures), cs, $call gref_add (x.fn, cs, acc))),
  $case {$prop tag "field"}   ($call grefs ($call IR.eval (x.target), cs, acc)),
  $case {$prop tag "new"}     ($call grefs ($call IR.eval (x.init), cs, acc)),
  $case {$prop tag "deref"}   ($call grefs ($call IR.eval (x.src), cs, acc)),
  $case {$prop tag "copy"}    ($call grefs ($call IR.eval (x.src), cs, acc)),
  $case {$prop tag "set"}
    ($call grefs ($call IR.eval (x.value), cs, $call grefs ($call IR.eval (x.target), cs, acc))),
  $case {$prop tag "block"}   ($call grefs_slots ($call IR.bslots.val (x.slots), cs, acc)),
  $case {$prop tag "group"}   ($call grefs_list ($call IR.exprs.val (x.items), cs, acc)),
  $case {$prop tag "call"}
    ($call grefs_list ($call IR.exprs.val (x.args), cs,
        $call grefs ($call IR.eval (x.callee), cs, acc))),
  $case {$prop tag "if"}
    ($call grefs ($call IR.eval (x.els), cs, $call grefs ($call IR.eval (x.then), cs,
        $call grefs ($call IR.eval (x.cond), cs, acc)))),
  $case {$prop tag "switch"}
    ($call grefs ($call IR.eval (x.default), cs, $call grefs_arms ($call IR.arms.val (x.arms), cs,
        $call grefs ($call IR.eval (x.scrut), cs, acc)))),
  $case {$prop tag "do"}
    ($call grefs ($call IR.eval (x.then), cs, $call grefs ($call IR.eval (x.first), cs, acc))),
  $case {$prop tag "try"}
    ($call grefs_list ($call IR.exprs.val (x.pre), cs,
        $call grefs ($call IR.eval (x.value), cs, acc))),
  $case {$prop tag "tobj"}
    ($call grefs ($call IR.eval (x.ref), cs, $call gref_fns ($call IR.ints.val (x.fns), cs, acc))),
  $case {$prop tag "tmem"}    ($call grefs ($call IR.eval (x.obj), cs, acc)),
  $case {$prop tag "addr"}    ($call grefs ($call IR.eval (x.src), cs, acc)),
  $case x acc
)

// The roots: what every function that is not a candidate names.
$decl rec_roots $func ($decl fs IR.fns.node, $decl i 0, $decl cs IR.ints.node,
    $decl acc IR.ints.node) $match fs (
  $case {$prop tag "cons"}
    $call rec_roots ($call IR.fns.val (fs.tail), $call add (i, 1), cs,
        $if ($call mem_int (cs, i)) acc ($call grefs ($call IR.eval (fs.head.body), cs, acc))),
  $case fs acc
)

// `xs` not already in `seen`, consed onto `acc`.
$decl new_ints $func ($decl xs IR.ints.node, $decl seen IR.ints.node, $decl acc IR.ints.node)
    $match xs (
  $case {$prop tag "cons"}
    $call new_ints ($call IR.ints.val (xs.tail), seen,
        $if ($call mem_int (seen, xs.head)) acc ($call IR.ints.cons (xs.head, acc))),
  $case xs acc
)

// What the kept records name, until nothing new is kept.
$decl rec_close $func ($decl all IR.fns.node, $decl cs IR.ints.node, $decl todo IR.ints.node,
                       $decl kept IR.ints.node) $match todo (
  $case {$prop tag "cons"} {
    $decl more $call grefs ($call IR.eval (($call IR.fns.nth (all, todo.head)).body), cs,
                   IR.ints.nil)
    $decl ret    $call rec_close (all, cs, $call new_ints (more, kept,
        $call IR.ints.val (todo.tail)),
                   $call new_ints (more, kept, kept))
  }.ret,
  $case todo kept
)

// Every field carried across — `mod`, `rank`, `pub` and `nmod` included, which a pass
// that rebuilds a function has been caught dropping twice (`mark_self`, `fold`).
$decl empty_thunk $func ($decl f IR.proto_fn, $decl eid 0)
  $call IR.fn_p (f.name, f.params, eid, IR.ints.nil, $call IR.e_block (eid, IR.bslots.nil),
      f.self_tail, f.thunk, f.env, f.mod, f.rank, f.pub, f.nmod)

$decl rec_drop $func ($decl fs IR.fns.node, $decl i 0, $decl dead IR.ints.node, $decl eid 0,
                      $decl acc IR.fns.node) $match fs (
  $case {$prop tag "cons"}
    $call rec_drop ($call IR.fns.val (fs.tail), $call add (i, 1), dead, eid,
        $call IR.fns.cons ($if ($call mem_int (dead, i)) ($call empty_thunk (fs.head, eid)) fs.head,
            acc)),
  $case fs ($call IR.fns.reverse (acc, IR.fns.nil))
)

$decl minus_ints $func ($decl xs IR.ints.node, $decl ys IR.ints.node, $decl acc IR.ints.node)
    $match xs (
  $case {$prop tag "cons"}
    $call minus_ints ($call IR.ints.val (xs.tail), ys,
        $if ($call mem_int (ys, xs.head)) acc ($call IR.ints.cons (xs.head, acc))),
  $case xs acc
)

$decl drop_records $func ($decl st proto_lst, $decl all IR.fns.node) {
  $decl cs   $call rec_cands (all, 0, IR.ints.nil)
  $decl ret  $if ($call IR.ints.is_nil (cs)) all {
    $decl roots $call rec_roots (all, 0, cs, IR.ints.nil)
    $decl kept  $call rec_close (all, cs, roots, roots)
    $decl dead  $call minus_ints (cs, kept, IR.ints.nil)
    $decl eid   $call intern (st, $call T.t_block (T.fields.nil, T.props.nil))
    $decl ret2  $call rec_drop (all, 0, dead, eid, IR.fns.nil)
  }.ret2
}.ret

// A function by global index, while the file is still being assembled: the entry
// file's own below `fnbase`, the lifted ones newest first after it.
$decl fn_at $func ($decl st proto_lst, $decl top IR.fns.node, $decl g 0)
  $if ($call lt (g, st.fnbase)) ($call IR.fns.nth (top, g))
      ($call IR.fns.nth ($call IR.fns.val (st.lifted),
          $call isub ($call isub ($call P.ival (st.nlifted), 1), $call isub (g, st.fnbase))))

// What a callee really is. A thunk whose body is one `global` is an alias —
// `$decl and P.and` — and §4.10 makes it later than its target, so following it ends;
// the bound is only against a malformed table.
$decl chase $func ($decl st proto_lst, $decl top IR.fns.node, $decl g 0, $decl n 0) {
  $decl f $call fn_at (st, top, g)
  $decl b $call IR.eval (f.body)
  $decl ret $if ($call and (f.thunk, $call lt (n, 64)))
      ($match b ($case {$prop tag "global"} ($call chase (st, top, b.fn, $call add (n, 1))),
                 $case b g))
      g
}.ret

$decl resolve_wrap $func ($decl st proto_lst, $decl top IR.fns.node, $decl p proto_wrap) {
  $decl t  $call chase (st, top, p.fn, 0)
  $decl ds $call find_fdef ($call fdef_list.val (st.fdefs), t)
  $decl wf $call fn_at (st, top, p.fn)
  $decl ret  $match ds (
      $case {$prop tag "cons"}
        ($call put_lifted (st, p.idx, $call build_wrap (st, ds.head, t, p.nargs, p.ty,
            $call P.sval (wf.nmod), wf.name))),
      $case ds ($call err (st,
          "an omitted argument needs its default, and this callee's definition is not known (§3.4): pass every argument",
          p.node))
    )
}.ret

$decl resolve_wlist $func ($decl st proto_lst, $decl top IR.fns.node, $decl ps wrap_list.node)
    $match ps (
  $case {$prop tag "cons"}
    $do ($call resolve_wrap (st, top, ps.head))
        ($call resolve_wlist (st, top, $call wrap_list.val (ps.tail))),
  $case ps 0
)

// Deferred prop reads and deferred wrappers, until neither is left: building either can
// lower code that defers more of the other.
$decl resolve_late $func ($decl st proto_lst, $decl top IR.fns.node, $decl rounds 0) {
  $decl a  $call resolve_pends (st, 0)
  $decl ws $call wrap_list.val (st.wpends)
  $decl ret $if ($call wrap_list.is_nil (ws)) 0 {
    $decl cleared $set st.wpends wrap_list.nil
    $decl d       $call resolve_wlist (st, top, ws)
    $decl ret2       $if ($call lt (rounds, 64))
                      ($call resolve_late (st, top, $call add (rounds, 1))) 0
  }.ret2
}.ret

$decl lower_file $func ($decl st proto_lst, $decl items Pa.nodes.node, $decl fty T.proto_ty,
                        $decl prims benv.node, $decl base "") {
  $decl flds $match fty ($case {$prop tag "block"} ($call T.fields.val (fty.fields)),
                         $case fty T.fields.nil)
  $decl env0 $call globals_from (flds, 0, prims)
  $decl rid  $set st.rootid ($call alloc_ident (prims))
  // §4.14: an import resolves relative to the entry file, and a module is
  // lowered against the root block alone — so both are recorded before any
  // item is lowered.
  $decl based  $set st.base base
  $decl rooted $set st.rootenv ($call with_index (prims))
  // **§3.3's top-level `$prop`s, which used to be dropped.** A file is a block, so
  // its top level may carry props — inference puts them in the file's type and they
  // resolve normally — but `lower_top` walks the type's *fields*, and a prop is in
  // its props. So the item was never visited, a body naming one got "unknown name",
  // and `scan_effects` took it for a bare expression and reported "$prop is not
  // lowered yet". Exactly the shape §3.3's top-level *expressions* had before `effs`
  // existed, in the one category that fix did not cover: an item that binds a name
  // but takes no field.
  //
  // The machinery already existed on the §4.14 side. The props become a module of
  // their own, bound through `with_props` so naming one reaches `lower_prop`, which
  // lowers its value the way a module member's is lowered. Its `path` and `file` are
  // both "" — the entry file's own — so a prop-valued function is named and placed
  // exactly where the entry file's other functions are, and `fn_key`'s `_m` keeps
  // its prop index clear of `next_rank`'s counter.
  $decl tprops $call top_props (items, mprops.nil)
  $decl pmid $if ($call mprops.is_nil (tprops)) -1
                 ($call fresh_mod_in (st, tprops, env0, base, "", ""))
  $decl env  $call with_index ($if ($call eq_int (pmid, -1)) env0
                 ($call with_props (env0, tprops, pmid)))
  // A global's index is its position among the top-level `$decl`s, so the
  // lifted functions take the indices after them.
  $decl fnbased $set st.fnbase ($call T.fields.length (flds, 0))
  $decl effi    $call scan_effects (items, 0, strs.nil, eff_items.nil)
  $decl done    $call lower_top (st, env, items, flds, IR.fns.nil, effi, 0)
  $decl pend    $call resolve_late (st, $call IR.fns.val (done.funcs), 0)
  $decl all0 $call append_fns ($call IR.fns.val (done.funcs),
                 $call IR.fns.reverse ($call IR.fns.val (st.lifted), IR.fns.nil))
  $decl all $call mark_self ($call drop_records (st, all0), 0, IR.fns.nil)
  $decl es  $call collect_edges (all, 0, edges.nil)
  $decl gs   $call find_groups (es, $call rev_edges (es, edges.nil), 0,
                  $call IR.fns.length (all, 0), IR.groups.nil)
  // Newest first while they are collected, since a file and the modules it
  // imports both append here.
  // `st.fnbase` is the boundary §4.10 needs in the backend, not just here.
  $decl ret  $call IR.program_m ($call all_types (st), all, gs, 0,
                 $call IR.effects.reverse ($call IR.effects.val (st.effs),
                     IR.effects.nil), $call P.ival (st.fnbase),
                 $call strs.reverse ($call strs.val (st.morder), strs.nil))
}.ret
