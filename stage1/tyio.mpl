// Writing a type down and reading it back — the foundation of a per-module
// interface cache.
//
// §3.3 makes a file a block, so a module's interface *is* a type: `check_file`
// answers every top-level name with its solved type. An importer needs nothing
// else, with one exception the compiler happens not to exercise widely — §10.7
// checks a `$template`'s body at the specialization site, so a module exporting
// one exports its *body*. There is exactly one `$template` in stage 1
// (`prelude`'s `list`) and no top-level `$prop` at all, so every other module's
// interface is a type and nothing more.
//
// **§5.5 is what makes this possible at all.** A binder carries no name — a bound
// variable is a de Bruijn index — so a written-down type needs no renaming on the
// way back in, and alpha-equivalence is structural. And since `intern` keys on
// `T.same`, a type read back in *is* the entry a fresh derivation would have
// found, rather than a copy of it.
//
// There is no syntax for writing a type (§2.1), so this cannot go through morphl
// source: the format is its own.
//
//   ty  = i f s T F u !              Int Float Str true false unit ⊥
//       | v<n> b<n> M<n>             a $var, a de Bruijn index, a $template
//       | g<n> ty*                   group        U<n> ty*  union
//       | I<n> ty*                   intersection O<n> ty*  $overload
//       | r<str><str>ty              reference: qual, kind, pointee
//       | a ty                       array        m ty       μ (§5.5)
//       | w<n> ty* ty <bool>         function: params, result, §5.3a frame flag
//       | B<n> fld* <n> prp*         block: fields then props (§7.2 order)
//   fld = <str> ty
//   prp = <str> cv ty                a prop's `ty` is written because for a
//                                    `copaque` it does not follow from the value
//   cv  = n<n> | c<str> | y | w | o<n>
//   str = <n>bytes                   length-prefixed, so no escaping is needed
//   n   = digits ';'                 terminated, or `B2;` and a following
//                                    length would run together
$decl T  $import "types"
$decl P  $import "prelude"

$decl not P.not
$decl and P.and
$decl isub sub

$decl strs $specialize P.list ""

// ------------------------------------------------------------------ writing
//
// Chunks, newest first, joined once at the end. §8's `concat` copies both
// operands, so appending to an accumulator costs O(L·n) — `emit.mpl`'s `say` was
// 590 MB of copying to produce 350 KB before it was folded in pairs instead.
// **Split in four so that every recursive call is a tail call (§7.7).** Reading
// `xs.tail` twice needs a `$decl` to bind it, and a block around a recursive call is
// a real frame — which at half the chunk count per pass is thousands of them. The
// first cut here did exactly that and died on `types.mpl` with "call depth limit
// exceeded at 8799 nested calls"; `emit.mpl`'s joiner is split this way for the same
// reason and the comment there says so.
//
// Each pass copies the output once and there are log2(n) of them, so joining n chunks
// totalling L bytes costs O(L log n) against a left fold's O(L n).
$fwd join_pass

$decl join_two $func ($decl a "", $decl t strs.node, $decl acc strs.node) $match t (
  $case {$prop tag "cons"}
    $call join_pass ($call strs.val (t.tail), $call strs.cons ($call concat (a, t.head), acc)),
  $case t ($call join_pass (t, $call strs.cons (a, acc)))
)

$decl join_pass $func ($decl xs strs.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"} $call join_two (xs.head, $call strs.val (xs.tail), acc),
  $case xs acc
)

$fwd join_all

$decl join_step $func ($decl xs strs.node, $decl a "", $decl t strs.node) $match t (
  $case {$prop tag "cons"}
    $call join_all ($call strs.reverse ($call join_pass (xs, strs.nil), strs.nil)),
  $case t a
)

$decl join_all $func ($decl xs strs.node) $match xs (
  $case {$prop tag "cons"} $call join_step (xs, xs.head, $call strs.val (xs.tail)),
  $case xs ""
)

// Newest-first, so the chunks are reversed before joining.
$decl out_of $func ($decl cs strs.node)
  $call join_all ($call strs.reverse (cs, strs.nil))

$decl put $func ($decl cs strs.node, $decl s "") $call strs.cons (s, cs)
$decl put_n $func ($decl cs strs.node, $decl n 0)
  $call put (cs, $call concat ($call int_to_str (n), ";"))
$decl put_s $func ($decl cs strs.node, $decl s "")
  $call put ($call put_n (cs, $call len (s)), s)

$decl put_cv $func ($decl cs strs.node, $decl c T.proto_cv) $match c (
  $case {$prop tag "cint"}    ($call put_n ($call put (cs, "n"), c.v)),
  $case {$prop tag "cstr"}    ($call put_s ($call put (cs, "c"), c.v)),
  $case {$prop tag "cbool"}   ($call put (cs, $if c.v "y" "w")),
  $case {$prop tag "cunit"}   ($call put (cs, "u")),
  $case {$prop tag "copaque"} ($call put_n ($call put (cs, "o"), c.id)),
  $case c ($call put (cs, "u"))
)

$fwd put_ty

$decl put_tys $func ($decl cs strs.node, $decl xs T.tys.node) $match xs (
  $case {$prop tag "cons"}
    $call put_tys ($call put_ty (cs, $call T.tval (xs.head)), $call T.tys.val (xs.tail)),
  $case xs cs
)

$decl put_flds $func ($decl cs strs.node, $decl xs T.fields.node) $match xs (
  $case {$prop tag "cons"}
    $call put_flds ($call put_ty ($call put_s (cs, xs.head.name), $call T.tval (xs.head.ty)),
        $call T.fields.val (xs.tail)),
  $case xs cs
)

$decl put_prps $func ($decl cs strs.node, $decl xs T.props.node) $match xs (
  $case {$prop tag "cons"}
    $call put_prps ($call put_ty ($call put_cv ($call put_s (cs, xs.head.name), xs.head.value),
            $call T.tval (xs.head.ty)),
        $call T.props.val (xs.tail)),
  $case xs cs
)

$decl put_ty $func ($decl cs strs.node, $decl t T.proto_ty) $match t (
  $case {$prop tag "int"}   ($call put (cs, "i")),
  $case {$prop tag "float"} ($call put (cs, "f")),
  $case {$prop tag "str"}   ($call put (cs, "s")),
  $case {$prop tag "true"}  ($call put (cs, "T")),
  $case {$prop tag "false"} ($call put (cs, "F")),
  $case {$prop tag "unit"}  ($call put (cs, "u")),
  $case {$prop tag "bot"}   ($call put (cs, "!")),
  $case {$prop tag "var"}   ($call put_n ($call put (cs, "v"), t.id)),
  $case {$prop tag "bnd"}   ($call put_n ($call put (cs, "b"), t.idx)),
  $case {$prop tag "tmpl"}  ($call put_n ($call put (cs, "M"), t.id)),
  $case {$prop tag "group"}
    ($call put_tys ($call put_n ($call put (cs, "g"),
         $call T.tys.length ($call T.tys.val (t.items), 0)), $call T.tys.val (t.items))),
  $case {$prop tag "union"}
    ($call put_tys ($call put_n ($call put (cs, "U"),
         $call T.tys.length ($call T.tys.val (t.members), 0)), $call T.tys.val (t.members))),
  // **Sorted, because the written form has to be canonical.** §3.6 makes an
  // intersection a set and, unlike a union, it is deliberately *not* canonicalised
  // on construction — `t_inter` conses, so reading one back and writing it again
  // gave a different byte string for the same type. `T.same` was satisfied either
  // way; the *rendering* was not, and the rendering is what a cache key hashes, so
  // a non-canonical form means the cache never hits. `T.sort_tys` is the same order
  // `t_union` uses. A union arrives sorted already and an `$overload`'s candidates
  // get the same treatment for the same reason.
  $case {$prop tag "inter"}
    { $decl ms $call T.sort_tys ($call T.tys.val (t.members))
      $decl r  $call put_tys ($call put_n ($call put (cs, "I"),
                   $call T.tys.length (ms, 0)), ms) }.r,
  $case {$prop tag "over"}
    { $decl cds $call T.sort_tys ($call T.tys.val (t.cands))
      $decl r   $call put_tys ($call put_n ($call put (cs, "O"),
                    $call T.tys.length (cds, 0)), cds) }.r,
  $case {$prop tag "ref"}
    ($call put_ty ($call put_s ($call put_s ($call put (cs, "r"), t.qual), t.kind),
         $call T.tval (t.inner))),
  $case {$prop tag "array"} ($call put_ty ($call put (cs, "a"), $call T.tval (t.elem))),
  $case {$prop tag "rec"}   ($call put_ty ($call put (cs, "m"), $call T.tval (t.body))),
  $case {$prop tag "func"}
    { $decl ps $call T.tys.val (t.params)
      $decl c0 $call put_n ($call put (cs, "w"), $call T.tys.length (ps, 0))
      $decl c1 $call put_ty ($call put_tys (c0, ps), $call T.tval (t.result))
      $decl r  $call put (c1, $if t.frame "y" "w") }.r,
  $case {$prop tag "block"}
    { $decl fs $call T.fields.val (t.fields)
      $decl ps $call T.props.val (t.props)
      $decl c0 $call put_flds ($call put_n ($call put (cs, "B"),
                    $call T.fields.length (fs, 0)), fs)
      $decl r  $call put_prps ($call put_n (c0, $call T.props.length (ps, 0)), ps) }.r,
  $case t ($call put (cs, "!"))
)

$decl show_ty $func ($decl t T.proto_ty)
  $call out_of ($call put_ty (strs.nil, t))

// ------------------------------------------------------------------ reading
//
// A cursor is (position, value). Every reader answers the value it read and the
// position after it, so the callers compose without a mutable cell.
$decl rn    $func ($decl i 0, $decl v 0) { $decl at i  $decl val v }
$decl rs    $func ($decl i 0, $decl v "") { $decl at i  $decl val v }
$decl proto_rn $call rn (0, 0)
$decl proto_rs $call rs (0, "")

$decl c_semi  $call byte (";", 0)
$decl c_minus $call byte ("-", 0)
$decl c_zero  $call byte ("0", 0)
$decl c_nine  $call byte ("9", 0)

$decl digits $func ($decl s "", $decl i 0, $decl acc 0)
  $if ($call not ($call lt (i, $call len (s)))) ($call rn (i, acc))
      { $decl ch $call byte (s, i)
        $decl ok $call and ($call not ($call lt (ch, c_zero)), $call not ($call lt (c_nine, ch)))
        $decl r  $if ok
            ($call digits (s, $call add (i, 1),
                 $call add ($call mul (acc, 10), $call isub (ch, c_zero))))
            ($call rn (i, acc)) }.r

// An integer, terminated by ';'. A leading '-' is honoured, because §9.3's node
// indices and a `$match` arm's -1 both reach a type through a prop value.
$decl read_n $func ($decl s "", $decl i 0)
  { $decl neg $call and ($call lt (i, $call len (s)),
                  $call eq_int ($call byte (s, i), c_minus))
    $decl d   $call digits (s, $if neg ($call add (i, 1)) i, 0)
    $decl r   $call rn ($call add (d.at, 1), $if neg ($call isub (0, d.val)) d.val) }.r

$decl read_s $func ($decl s "", $decl i 0)
  { $decl n $call read_n (s, i)
    $decl e $call add (n.at, n.val)
    $decl r $call rs (e, $call slice (s, n.at, e)) }.r

$decl rcv $func ($decl i 0, $decl v T.proto_cv) { $decl at i  $decl val v }
$decl proto_rcv $call rcv (0, T.cv_unit)

$decl read_cv $func ($decl s "", $decl i 0)
  { $decl ch $call byte (s, i)
    $decl j  $call add (i, 1)
    $decl r  $if ($call eq_int (ch, $call byte ("n", 0)))
                 { $decl n $call read_n (s, j)
                   $decl z $call rcv (n.at, $call T.cv_int (n.val)) }.z
            ($if ($call eq_int (ch, $call byte ("c", 0)))
                 { $decl q $call read_s (s, j)
                   $decl z $call rcv (q.at, $call T.cv_str (q.val)) }.z
            ($if ($call eq_int (ch, $call byte ("y", 0)))
                 ($call rcv (j, $call T.cv_bool (true)))
            ($if ($call eq_int (ch, $call byte ("w", 0)))
                 ($call rcv (j, $call T.cv_bool (false)))
            ($if ($call eq_int (ch, $call byte ("o", 0)))
                 { $decl n $call read_n (s, j)
                   $decl z $call rcv (n.at, $call T.cv_opaque (n.val)) }.z
                 ($call rcv (j, T.cv_unit)))))) }.r

$decl rt $func ($decl i 0, $decl v T.proto_ty) { $decl at i  $decl val v }
$decl proto_rt $call rt (0, T.t_bot)

// While `read_ty` is being solved its result is §5.5's placeholder, so projecting
// `.at` off it fails. Passing it through an identity at the intended type defers
// the check until the knot is tied — the idiom `T.tval` exists for.
$decl rtval $func ($decl x proto_rt) x

$fwd read_ty

$decl rl $func ($decl i 0, $decl v T.tys.node) { $decl at i  $decl val v }
$decl proto_rl $call rl (0, T.tys.nil)

$decl read_list $func ($decl s "", $decl i 0, $decl n 0, $decl acc T.tys.node)
  $if ($call not ($call lt (0, n))) ($call rl (i, $call T.tys.reverse (acc, T.tys.nil)))
      { $decl e $call rtval ($call read_ty (s, i))
        $decl r $call read_list (s, e.at, $call isub (n, 1),
                    $call T.tys.cons (e.val, acc)) }.r

$decl rf $func ($decl i 0, $decl v T.fields.node) { $decl at i  $decl val v }
$decl proto_rf $call rf (0, T.fields.nil)

$decl read_flds $func ($decl s "", $decl i 0, $decl n 0, $decl acc T.fields.node)
  $if ($call not ($call lt (0, n))) ($call rf (i, $call T.fields.reverse (acc, T.fields.nil)))
      { $decl nm $call read_s (s, i)
        $decl ty $call rtval ($call read_ty (s, nm.at))
        $decl r  $call read_flds (s, ty.at, $call isub (n, 1),
                     $call T.fields.cons ($call T.field (nm.val, ty.val), acc)) }.r

$decl rp $func ($decl i 0, $decl v T.props.node) { $decl at i  $decl val v }
$decl proto_rp $call rp (0, T.props.nil)

$decl read_prps $func ($decl s "", $decl i 0, $decl n 0, $decl acc T.props.node)
  $if ($call not ($call lt (0, n))) ($call rp (i, $call T.props.reverse (acc, T.props.nil)))
      { $decl nm $call read_s (s, i)
        $decl cv $call read_cv (s, nm.at)
        $decl ty $call rtval ($call read_ty (s, cv.at))
        $decl r  $call read_prps (s, ty.at, $call isub (n, 1),
                     $call T.props.cons ($call T.prop_typed (nm.val, cv.val, ty.val), acc)) }.r

$decl one $func ($decl s "", $decl i 0, $decl tag "")
  $call eq_int ($call byte (s, i), $call byte (tag, 0))

$decl read_ty $func ($decl s "", $decl i 0)
  { $decl j $call add (i, 1)
    $decl r $if ($call one (s, i, "i")) ($call rt (j, T.t_int))
           ($if ($call one (s, i, "f")) ($call rt (j, T.t_float))
           ($if ($call one (s, i, "s")) ($call rt (j, T.t_str))
           ($if ($call one (s, i, "T")) ($call rt (j, T.t_true))
           ($if ($call one (s, i, "F")) ($call rt (j, T.t_false))
           ($if ($call one (s, i, "u")) ($call rt (j, T.t_unit))
           ($if ($call one (s, i, "!")) ($call rt (j, T.t_bot))
           ($if ($call one (s, i, "v"))
                { $decl n $call read_n (s, j)
                  $decl z $call rt (n.at, $call T.t_var (n.val)) }.z
           ($if ($call one (s, i, "b"))
                { $decl n $call read_n (s, j)
                  $decl z $call rt (n.at, $call T.t_bnd (n.val)) }.z
           ($if ($call one (s, i, "M"))
                { $decl n $call read_n (s, j)
                  $decl z $call rt (n.at, $call T.t_tmpl (n.val)) }.z
           ($if ($call one (s, i, "g"))
                { $decl n $call read_n (s, j)
                  $decl l $call read_list (s, n.at, n.val, T.tys.nil)
                  $decl z $call rt (l.at, $call T.t_group (l.val)) }.z
           ($if ($call one (s, i, "U"))
                { $decl n $call read_n (s, j)
                  $decl l $call read_list (s, n.at, n.val, T.tys.nil)
                  $decl z $call rt (l.at, $call T.t_union (l.val)) }.z
           ($if ($call one (s, i, "I"))
                { $decl n $call read_n (s, j)
                  $decl l $call read_list (s, n.at, n.val, T.tys.nil)
                  $decl z $call rt (l.at, $call T.t_inter (l.val)) }.z
           ($if ($call one (s, i, "O"))
                { $decl n $call read_n (s, j)
                  $decl l $call read_list (s, n.at, n.val, T.tys.nil)
                  $decl z $call rt (l.at, $call T.t_over (l.val)) }.z
           ($if ($call one (s, i, "r"))
                { $decl q $call read_s (s, j)
                  $decl k $call read_s (s, q.at)
                  $decl e $call rtval ($call read_ty (s, k.at))
                  $decl z $call rt (e.at, $call T.t_ref_k (q.val, e.val, k.val)) }.z
           ($if ($call one (s, i, "a"))
                { $decl e $call rtval ($call read_ty (s, j))
                  $decl z $call rt (e.at, $call T.t_array (e.val)) }.z
           ($if ($call one (s, i, "m"))
                { $decl e $call rtval ($call read_ty (s, j))
                  $decl z $call rt (e.at, $call T.t_rec (e.val)) }.z
           ($if ($call one (s, i, "w"))
                { $decl n  $call read_n (s, j)
                  $decl ps $call read_list (s, n.at, n.val, T.tys.nil)
                  $decl rr $call rtval ($call read_ty (s, ps.at))
                  $decl fr $call one (s, rr.at, "y")
                  $decl z  $call rt ($call add (rr.at, 1),
                               $call T.t_func_fr (ps.val, rr.val, fr)) }.z
           ($if ($call one (s, i, "B"))
                { $decl nf $call read_n (s, j)
                  $decl fs $call read_flds (s, nf.at, nf.val, T.fields.nil)
                  $decl np $call read_n (s, fs.at)
                  $decl ps $call read_prps (s, np.at, np.val, T.props.nil)
                  $decl z  $call rt (ps.at, $call T.t_block (fs.val, ps.val)) }.z
                ($call rt (j, T.t_bot)))))))))))))))))))) }.r
