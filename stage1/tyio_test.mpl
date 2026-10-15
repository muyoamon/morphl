// `tyio` round-trips every type a real program interns:
//
//   morphlc --run stage1/tyio_test.mpl [file.mpl]
//
// The property is `T.same (read_ty (show_ty (t)), t)` for every entry in §9.3's
// table — which is the right equality, because `intern` keys on `T.same`, so a
// type read back in *is* the entry a fresh derivation would have found.
//
// A table from a compiled program is a far better test than hand-written cases:
// it has the μ types, the big unions, the de Bruijn binders and the prop-bearing
// blocks that only arise from real source. `types.mpl` alone interns ~1,400.
$decl T  $import "types"
$decl IR $import "ir"
$decl I  $import "infer"
$decl L  $import "lower"
$decl Pa $import "parser"
$decl P  $import "prelude"
$decl Y  $import "tyio"

$decl not  P.not
$decl isub sub

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))

// A prop's `ty` is deliberately outside `T.same` (§9.3's hash does not cover it
// either), so identity alone would not notice the field being dropped. The
// rendering is compared as well, which does cover it.
$decl both $func ($decl t T.proto_ty) {
  $decl w   $call Y.show_ty (t)
  $decl r   $call Y.read_ty (w, 0)
  $decl w2  $call Y.show_ty (r.val)
  $decl ret $if ($call T.same (r.val, t)) ($call eq_str (w, w2)) false
}.ret

$decl walk $func ($decl ts T.tys.node, $decl i 0, $decl bad 0, $decl first 0) $match ts (
  $case {$prop tag "cons"} {
    $decl t   $call T.tval (ts.head)
    $decl ok  $call both (t)
    $decl b2  $if ok bad ($call add (bad, 1))
    $decl f2  $if ok first ($if ($call eq_int (bad, 0)) i first)
    $decl ret $call walk ($call T.tys.val (ts.tail), $call add (i, 1), b2, f2)
  }.ret,
  $case ts { $decl nbad bad  $decl at first }
)

// §6's trait has no instance in a lowered program yet, so it is round-tripped directly:
// both frame flags, a mutable one, and a member whose type mentions `Self` (`bnd 0`).
// `both` compares the rendering as well as `same`, so it notices the flag, which `same`
// ignores.
$decl tr_ms  $call T.fields.cons (
    $call T.field ("area", $call T.t_func ($call T.tys.cons ($call T.t_bnd (0), T.tys.nil),
        T.t_int)),
    $call T.fields.cons ($call T.field ("name", T.t_str), T.fields.nil))
$decl tr_ok  $call P.and ($call P.and ($call both ($call T.t_trait_fr (tr_ms, false)),
                 $call both ($call T.t_trait_fr (tr_ms, true))),
                 $call both ($call T.t_trait_q (tr_ms, false, "mut")))
$decl tr_chk $if tr_ok ($call nl ("ok   a trait survives a round trip"))
                 ($call panic ("a trait does not survive a round trip"))

// §4.12's `with` likewise: a non-block base with props added, one a function whose `ty` is
// written beside its opaque value, and a `with` over a reference.
$decl wi_ps  $call T.props.cons (
    $call T.prop_typed ("area", $call T.cv_opaque (5), $call T.t_func (T.tys.nil, T.t_int)),
    $call T.props.cons ($call T.prop_typed ("k", $call T.cv_int (3), T.t_int), T.props.nil))
$decl wi_ok  $call P.and ($call both ($call T.t_with (T.t_int, wi_ps)),
                 $call both ($call T.t_with ($call T.t_ref ("const", T.t_str), wi_ps)))
$decl wi_chk $if wi_ok ($call nl ("ok   an $impl's with survives a round trip"))
                 ($call panic ("an $impl's with does not survive a round trip"))

$decl argv $call args ()
$decl path $if ($call lt (0, $call alen (argv))) ($call P.sval ($call at (argv, 0)))
               "stage1/types.mpl"
$decl rf   $call read_file (path)
$decl src  $match rf (
    $case {$prop tag "some"} rf.v,
    $case rf ($call panic ($call concat ("cannot read ", path)))
  )

$decl chk   $call I.check_source (src, $call P.dirname (path), path)
$decl ast   $call Pa.parse (src)
$decl st    $call L.lstate ()
$decl prims $call L.prims_from ($call I.eval_env (I.root_env), L.benv.nil)
$decl prog  $call L.lower_file (st, $call Pa.nodes.val (ast.exprs), chk.ty, prims, path)
$decl ts    $call T.tys.val (prog.types)
$decl nt    $call T.tys.length (ts, 0)
$decl res   $call walk (ts, 0, 0, -1)

$decl r1    $call nl ($call concat ("types: ", $call int_to_str (nt)))
$decl r2    $call nl ($call concat ("round-trip failures: ", $call int_to_str (res.nbad)))
$decl bad_t $if ($call lt (res.at, 0)) T.t_bot ($call T.tval ($call T.tys.nth (ts, res.at)))
$decl r3 $if ($call eq_int (res.nbad, 0)) ($call nl ("ok   every interned type survives a round trip"))
             ($do ($call nl ($call concat ("FAIL first at index ", $call int_to_str (res.at))))
             ($do ($call nl ($call concat ("  show   ", $call T.show (bad_t))))
             ($do ($call nl ($call concat ("  wrote  ", $call Y.show_ty (bad_t))))
                  ($call nl ($call concat ("  reread ",
                      $call Y.show_ty (($call Y.read_ty ($call Y.show_ty (bad_t), 0)).val)))))))
