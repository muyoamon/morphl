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
//       | w<n> ty* ty <bool> <bool> <n> <n>*
//                                    function: params, result, §5.3a frame, §4.10 rmut,
//                                    and the parameters that escape (§5.3a)
//       | B<n> fld* <n> prp*         block: fields then props (§7.2 order)
//       | t<n> fld* <bool> <str>     trait (§6): members, the frame flag, the qualifier
//       | W ty <n> prp*              §4.12's non-block base with props added
//   fld = <str> ty
//   prp = <str> cv ty                a prop's `ty` is written because for a
//                                    `copaque` it does not follow from the value
//   cv  = n<n> | c<str> | y | w | o<n>
//   str = <n>bytes                   length-prefixed, so no escaping is needed
//   n   = digits ';'                 terminated, or `B2;` and a following
//                                    length would run together
//       | R<n>                       the n-th type written so far
//
// **`R` is what makes this affordable, and the first version without it was not.** A
// type is a tree and a module's interface mentions the same types over and over — one
// per signature — so writing each as a tree gave `ir.mpl` a **792 KB** interface
// against a 50 KB source, and `types.mpl` 560 KB. Reading that back cost more than
// inferring the module, so the cache hit and lost: 12.56s cold against 15.68s warm.
// `ir`'s closure has 136 distinct types; the information was always small and the
// encoding wrote it thousands of times.
//
// Writer and reader number types in the same order because both register **after** a
// type's children, not before. A child therefore can never refer to its parent, which
// is sound precisely because §5.5 makes recursion explicit as `μ` — a type is a finite
// tree, so post-order terminates and nothing is ever referenced before it exists.
$decl T $import "types"
$decl P $import "prelude"

$decl not  P.not
$decl and  P.and
$decl isub sub

$decl strs $specialize P.list ""

// A type already written or read, and the index it was given. Held newest-first with
// the index carried, rather than oldest-first by position: appending to an immutable
// list costs O(n) a time and this list has one entry per distinct type.
$decl tent       $func ($decl i 0, $decl t T.proto_ty) { $decl idx i  $decl ty t }
$decl proto_tent $call tent (0, T.t_bot)
$decl tents      $specialize P.list proto_tent

// One state for both directions: the chunks being written, the types seen so far, and
// how many. The mutable block is this codebase's idiom for a walk that has to thread
// state through a recursion (`est`, `lstate`).
$decl cst $func () {
  $decl out  $mut $alloc strs.node
  $decl ents $mut $alloc tents.node
  $decl n    $mut $alloc 0
}
$decl proto_cst $call cst ()

$decl eval_ents $func ($decl x tents.node) x

// The index of a type already seen, or -1.
$decl seen_at $func ($decl xs tents.node, $decl t T.proto_ty) $match xs (
  $case {$prop tag "cons"}
    $if ($call T.same ($call T.tval (xs.head.ty), t)) xs.head.idx
        ($call seen_at ($call tents.val (xs.tail), t)),
  $case xs -1
)

$decl ent_at $func ($decl xs tents.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_int (xs.head.idx, i)) ($call T.tval (xs.head.ty))
        ($call ent_at ($call tents.val (xs.tail), i)),
  $case xs T.t_bot
)

// Registered after the children, so the writer's numbering and the reader's agree.
$decl note_ty $func ($decl st proto_cst, $decl t T.proto_ty) {
  $decl i   $call P.ival (st.n)
  $decl e   $set st.ents ($call tents.cons ($call tent (i, t), $call eval_ents (st.ents)))
  $decl b   $set st.n ($call add (i, 1))
  $decl ret i
}.ret

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

$decl put $func ($decl st proto_cst, $decl x "") {
  $decl a   $set st.out ($call strs.cons (x, $call strs.val (st.out)))
  $decl ret 0
}.ret

$decl put_n $func ($decl st proto_cst, $decl v 0)
  $call put (st, $call concat ($call int_to_str (v), ";"))

$decl put_ints $func ($decl st proto_cst, $decl xs T.cints.node) $match xs (
  $case {$prop tag "cons"}
    $do ($call put_n (st, xs.head)) ($call put_ints (st, $call T.cints.val (xs.tail))),
  $case xs ()
)

$decl put_s $func ($decl st proto_cst, $decl x "")
  $do ($call put_n (st, $call len (x))) ($call put (st, x))

$decl put_cv $func ($decl st proto_cst, $decl c T.proto_cv) $match c (
  $case {$prop tag "cint"}    ($do ($call put (st, "n")) ($call put_n (st, c.v))),
  $case {$prop tag "cstr"}    ($do ($call put (st, "c")) ($call put_s (st, c.v))),
  $case {$prop tag "cbool"}   ($call put (st, $if c.v "y" "w")),
  $case {$prop tag "cunit"}   ($call put (st, "u")),
  $case {$prop tag "copaque"} ($do ($call put (st, "o")) ($call put_n (st, c.id))),
  $case c ($call put (st, "u"))
)

$fwd put_ty

$decl put_tys $func ($decl st proto_cst, $decl xs T.tys.node) $match xs (
  $case {$prop tag "cons"}
    $do ($call put_ty (st, $call T.tval (xs.head)))
        ($call put_tys (st, $call T.tys.val (xs.tail))),
  $case xs 0
)

$decl put_flds $func ($decl st proto_cst, $decl xs T.fields.node) $match xs (
  $case {$prop tag "cons"}
    $do ($do ($call put_s (st, xs.head.name)) ($call put_ty (st, $call T.tval (xs.head.ty))))
        ($call put_flds (st, $call T.fields.val (xs.tail))),
  $case xs 0
)

$decl put_prps $func ($decl st proto_cst, $decl xs T.props.node) $match xs (
  $case {$prop tag "cons"}
    $do ($do ($call put_s (st, xs.head.name))
             ($do ($call put_cv (st, xs.head.value))
                  ($call put_ty (st, $call T.tval (xs.head.ty)))))
        ($call put_prps (st, $call T.props.val (xs.tail))),
  $case xs 0
)

// The tag and children of a type that has not been written before. `put_ty` is the
// half that decides whether to write it at all.
$decl put_body $func ($decl st proto_cst, $decl t T.proto_ty) $match t (
  $case {$prop tag "int"}   ($call put (st, "i")),
  $case {$prop tag "float"} ($call put (st, "f")),
  $case {$prop tag "str"}   ($call put (st, "s")),
  $case {$prop tag "true"}  ($call put (st, "T")),
  $case {$prop tag "false"} ($call put (st, "F")),
  $case {$prop tag "unit"}  ($call put (st, "u")),
  $case {$prop tag "bottom"} ($call put (st, "!")),
  $case {$prop tag "var"}   ($do ($call put (st, "v")) ($call put_n (st, t.id))),
  $case {$prop tag "bnd"}   ($do ($call put (st, "b")) ($call put_n (st, t.idx))),
  $case {$prop tag "tmpl"}  ($do ($call put (st, "M")) ($call put_n (st, t.id))),
  $case {$prop tag "group"} {
    $decl xs  $call T.tys.val (t.items)
    $decl a   $do ($call put (st, "g")) ($call put_n (st, $call T.tys.length (xs, 0)))
    $decl ret $call put_tys (st, xs)
  }.ret,
  $case {$prop tag "union"} {
    $decl xs  $call T.tys.val (t.members)
    $decl a   $do ($call put (st, "U")) ($call put_n (st, $call T.tys.length (xs, 0)))
    $decl ret $call put_tys (st, xs)
  }.ret,
  // Sorted, because the written form has to be canonical: §3.6 makes an intersection a
  // set and, unlike a union, it is not canonicalised on construction, so reading one
  // back and writing it again gave different bytes for one type. `T.same` was content
  // either way; the rendering is what a cache key hashes.
  $case {$prop tag "inter"} {
    $decl xs  $call T.sort_tys ($call T.tys.val (t.members))
    $decl a   $do ($call put (st, "I")) ($call put_n (st, $call T.tys.length (xs, 0)))
    $decl ret $call put_tys (st, xs)
  }.ret,
  $case {$prop tag "over"} {
    $decl xs  $call T.sort_tys ($call T.tys.val (t.cands))
    $decl a   $do ($call put (st, "O")) ($call put_n (st, $call T.tys.length (xs, 0)))
    $decl ret $call put_tys (st, xs)
  }.ret,
  $case {$prop tag "ref"} {
    $decl a   $do ($call put (st, "r")) ($do ($call put_s (st, t.qual)) ($call put_s (st, t.kind)))
    $decl ret $call put_ty (st, $call T.tval (t.inner))
  }.ret,
  $case {$prop tag "array"} {
    $decl a   $call put (st, "a")
    $decl ret $call put_ty (st, $call T.tval (t.elem))
  }.ret,
  $case {$prop tag "rec"} {
    $decl a   $call put (st, "m")
    $decl ret $call put_ty (st, $call T.tval (t.body))
  }.ret,
  $case {$prop tag "func"} {
    $decl ps  $call T.tys.val (t.params)
    $decl a   $do ($call put (st, "w")) ($call put_n (st, $call T.tys.length (ps, 0)))
    $decl b   $do ($call put_tys (st, ps)) ($call put_ty (st, $call T.tval (t.result)))
    $decl fr  $call put (st, $if t.frame "y" "w")
    $decl rm  $call put (st, $if t.rmut "y" "w")
    $decl es  $call T.cints.val (t.esc)
    $decl ec  $call put_n (st, $call T.cints.length (es, 0))
    $decl ret $call put_ints (st, es)
  }.ret,
  $case {$prop tag "block"} {
    $decl fs  $call T.fields.val (t.fields)
    $decl ps  $call T.props.val (t.props)
    $decl a   $do ($call put (st, "B")) ($call put_n (st, $call T.fields.length (fs, 0)))
    $decl b   $do ($call put_flds (st, fs)) ($call put_n (st, $call T.props.length (ps, 0)))
    $decl ret $call put_prps (st, ps)
  }.ret,
  $case {$prop tag "trait"} {
    $decl ms  $call T.fields.val (t.members)
    $decl a   $do ($call put (st, "t")) ($call put_n (st, $call T.fields.length (ms, 0)))
    $decl b   $do ($call put_flds (st, ms)) ($call put (st, $if t.frame "y" "w"))
    $decl ret $call put_s (st, t.qual)
  }.ret,
  $case {$prop tag "with"} {
    $decl ps  $call T.props.val (t.props)
    $decl a   $do ($call put (st, "W")) ($call put_ty (st, $call T.tval (t.base)))
    $decl b   $call put_n (st, $call T.props.length (ps, 0))
    $decl ret $call put_prps (st, ps)
  }.ret,
  $case t ($call put (st, "!"))
)

// A type already written is one back-reference; otherwise its tag and children, and
// then it is registered — **after**, so the reader can number identically.
$decl put_ty $func ($decl st proto_cst, $decl t T.proto_ty) {
  $decl at $call seen_at ($call eval_ents (st.ents), t)
  $decl ret  $if ($call lt (at, 0)) {
    $decl w    $call put_body (st, t)
    $decl ret2 $call note_ty (st, t)
  }.ret2
      ($do ($call put (st, "R")) ($call put_n (st, at)))
}.ret

$decl show_ty $func ($decl t T.proto_ty) {
  $decl st  $call cst ()
  $decl w   $call put_ty (st, t)
  $decl ret $call out_of ($call strs.val (st.out))
}.ret

// ------------------------------------------------------------------ reading
//
// A cursor is (position, value). Every reader answers the value it read and the
// position after it, so the callers compose without a mutable cell.
$decl rn       $func ($decl i 0, $decl v 0) { $decl at i  $decl val v }
$decl rs       $func ($decl i 0, $decl v "") { $decl at i  $decl val v }
$decl proto_rn $call rn (0, 0)
$decl proto_rs $call rs (0, "")

$decl c_semi  $call byte (";", 0)
$decl c_minus $call byte ("-", 0)
$decl c_zero  $call byte ("0", 0)
$decl c_nine  $call byte ("9", 0)

$decl digits $func ($decl s "", $decl i 0, $decl acc 0)
  $if ($call not ($call lt (i, $call len (s)))) ($call rn (i, acc)) {
    $decl ch $call byte (s, i)
    $decl ok $call and ($call not ($call lt (ch, c_zero)), $call not ($call lt (c_nine, ch)))
    $decl ret  $if ok
        ($call digits (s, $call add (i, 1),
             $call add ($call mul (acc, 10), $call isub (ch, c_zero))))
        ($call rn (i, acc))
  }.ret

// An integer, terminated by ';'. A leading '-' is honoured, because §9.3's node
// indices and a `$match` arm's -1 both reach a type through a prop value.
$decl read_n $func ($decl s "", $decl i 0) {
  $decl neg $call and ($call lt (i, $call len (s)),
                $call eq_int ($call byte (s, i), c_minus))
  $decl d   $call digits (s, $if neg ($call add (i, 1)) i, 0)
  $decl ret $call rn ($call add (d.at, 1), $if neg ($call isub (0, d.val)) d.val)
}.ret

$decl rints       $func ($decl i 0, $decl v T.cints.node) { $decl at i  $decl val v }
$decl proto_rints $call rints (0, T.cints.nil)

// Newest first; the caller reverses.
$decl read_ints $func ($decl s "", $decl i 0, $decl n 0, $decl acc T.cints.node)
  $if ($call not ($call lt (0, n))) ($call rints (i, acc)) {
    $decl x   $call read_n (s, i)
    $decl ret $call read_ints (s, x.at, $call sub (n, 1), $call T.cints.cons (x.val, acc))
  }.ret

$decl read_s $func ($decl s "", $decl i 0) {
  $decl n   $call read_n (s, i)
  $decl e   $call add (n.at, n.val)
  $decl ret $call rs (e, $call slice (s, n.at, e))
}.ret

$decl rcv       $func ($decl i 0, $decl v T.proto_cv) { $decl at i  $decl val v }
$decl proto_rcv $call rcv (0, T.cv_unit)

$decl read_cv $func ($decl s "", $decl i 0) {
  $decl ch $call byte (s, i)
  $decl j  $call add (i, 1)
  $decl ret  $if ($call eq_int (ch, $call byte ("n", 0))) {
    $decl n    $call read_n (s, j)
    $decl ret2 $call rcv (n.at, $call T.cv_int (n.val))
  }.ret2
          ($if ($call eq_int (ch, $call byte ("c", 0))) {
            $decl q    $call read_s (s, j)
            $decl ret2 $call rcv (q.at, $call T.cv_str (q.val))
          }.ret2
          ($if ($call eq_int (ch, $call byte ("y", 0)))
               ($call rcv (j, $call T.cv_bool (true)))
          ($if ($call eq_int (ch, $call byte ("w", 0)))
               ($call rcv (j, $call T.cv_bool (false)))
          ($if ($call eq_int (ch, $call byte ("o", 0))) {
            $decl n    $call read_n (s, j)
            $decl ret2 $call rcv (n.at, $call T.cv_opaque (n.val))
          }.ret2
               ($call rcv (j, T.cv_unit))))))
}.ret

$decl rt       $func ($decl i 0, $decl v T.proto_ty) { $decl at i  $decl val v }
$decl proto_rt $call rt (0, T.t_bot)

// While `read_at` is being solved its result is §5.5's placeholder, so projecting
// `.at` off it fails. Passing it through an identity at the intended type defers the
// check until the knot is tied — the idiom `T.tval` exists for.
$decl rtval $func ($decl x proto_rt) x

$fwd read_at

$decl rl       $func ($decl i 0, $decl v T.tys.node) { $decl at i  $decl val v }
$decl proto_rl $call rl (0, T.tys.nil)

$decl read_list $func ($decl st proto_cst, $decl s "", $decl i 0, $decl n 0,
                       $decl acc T.tys.node)
  $if ($call not ($call lt (0, n))) ($call rl (i, $call T.tys.reverse (acc, T.tys.nil))) {
    $decl e $call rtval ($call read_at (st, s, i))
    $decl ret $call read_list (st, s, e.at, $call isub (n, 1),
                $call T.tys.cons (e.val, acc))
  }.ret

$decl rf       $func ($decl i 0, $decl v T.fields.node) { $decl at i  $decl val v }
$decl proto_rf $call rf (0, T.fields.nil)

$decl read_flds $func ($decl st proto_cst, $decl s "", $decl i 0, $decl n 0,
                       $decl acc T.fields.node)
  $if ($call not ($call lt (0, n))) ($call rf (i, $call T.fields.reverse (acc, T.fields.nil))) {
    $decl nm $call read_s (s, i)
    $decl ty $call rtval ($call read_at (st, s, nm.at))
    $decl ret  $call read_flds (st, s, ty.at, $call isub (n, 1),
                 $call T.fields.cons ($call T.field (nm.val, ty.val), acc))
  }.ret

$decl rp       $func ($decl i 0, $decl v T.props.node) { $decl at i  $decl val v }
$decl proto_rp $call rp (0, T.props.nil)

$decl read_prps $func ($decl st proto_cst, $decl s "", $decl i 0, $decl n 0,
                       $decl acc T.props.node)
  $if ($call not ($call lt (0, n))) ($call rp (i, $call T.props.reverse (acc, T.props.nil))) {
    $decl nm $call read_s (s, i)
    $decl cv $call read_cv (s, nm.at)
    $decl ty $call rtval ($call read_at (st, s, cv.at))
    $decl ret  $call read_prps (st, s, ty.at, $call isub (n, 1),
                 $call T.props.cons ($call T.prop_typed (nm.val, cv.val, ty.val), acc))
  }.ret

$decl one $func ($decl s "", $decl i 0, $decl tag "")
  $call eq_int ($call byte (s, i), $call byte (tag, 0))

// Every branch registers what it built, except `R`, which is a reference to something
// already registered. Registration is after the children for the same reason the
// writer's is: the two numberings have to agree.
$decl read_body $func ($decl st proto_cst, $decl s "", $decl i 0) {
  $decl j $call add (i, 1)
  $decl ret $if ($call one (s, i, "i")) ($call rt (j, T.t_int))
         ($if ($call one (s, i, "f")) ($call rt (j, T.t_float))
         ($if ($call one (s, i, "s")) ($call rt (j, T.t_str))
         ($if ($call one (s, i, "T")) ($call rt (j, T.t_true))
         ($if ($call one (s, i, "F")) ($call rt (j, T.t_false))
         ($if ($call one (s, i, "u")) ($call rt (j, T.t_unit))
         ($if ($call one (s, i, "!")) ($call rt (j, T.t_bot))
         ($if ($call one (s, i, "v")) {
           $decl n    $call read_n (s, j)
           $decl ret2 $call rt (n.at, $call T.t_var (n.val))
         }.ret2
         ($if ($call one (s, i, "b")) {
           $decl n    $call read_n (s, j)
           $decl ret2 $call rt (n.at, $call T.t_bnd (n.val))
         }.ret2
         ($if ($call one (s, i, "M")) {
           $decl n    $call read_n (s, j)
           $decl ret2 $call rt (n.at, $call T.t_tmpl (n.val))
         }.ret2
         ($if ($call one (s, i, "g")) {
           $decl n    $call read_n (s, j)
           $decl l    $call read_list (st, s, n.at, n.val, T.tys.nil)
           $decl ret2 $call rt (l.at, $call T.t_group (l.val))
         }.ret2
         ($if ($call one (s, i, "U")) {
           $decl n    $call read_n (s, j)
           $decl l    $call read_list (st, s, n.at, n.val, T.tys.nil)
           $decl ret2 $call rt (l.at, $call T.t_union (l.val))
         }.ret2
         ($if ($call one (s, i, "I")) {
           $decl n    $call read_n (s, j)
           $decl l    $call read_list (st, s, n.at, n.val, T.tys.nil)
           $decl ret2 $call rt (l.at, $call T.t_inter (l.val))
         }.ret2
         ($if ($call one (s, i, "O")) {
           $decl n    $call read_n (s, j)
           $decl l    $call read_list (st, s, n.at, n.val, T.tys.nil)
           $decl ret2 $call rt (l.at, $call T.t_over (l.val))
         }.ret2
         ($if ($call one (s, i, "r")) {
           $decl q    $call read_s (s, j)
           $decl k    $call read_s (s, q.at)
           $decl e    $call rtval ($call read_at (st, s, k.at))
           $decl ret2 $call rt (e.at, $call T.t_ref_k (q.val, e.val, k.val))
         }.ret2
         ($if ($call one (s, i, "a")) {
           $decl e    $call rtval ($call read_at (st, s, j))
           $decl ret2 $call rt (e.at, $call T.t_array (e.val))
         }.ret2
         ($if ($call one (s, i, "m")) {
           $decl e    $call rtval ($call read_at (st, s, j))
           $decl ret2 $call rt (e.at, $call T.t_rec (e.val))
         }.ret2
         ($if ($call one (s, i, "w")) {
           $decl n  $call read_n (s, j)
           $decl ps $call read_list (st, s, n.at, n.val, T.tys.nil)
           $decl rr $call rtval ($call read_at (st, s, ps.at))
           $decl fr $call one (s, rr.at, "y")
           $decl rm $call one (s, $call add (rr.at, 1), "y")
           $decl ne $call read_n (s, $call add (rr.at, 2))
           $decl es $call read_ints (s, ne.at, ne.val, T.cints.nil)
           $decl ret2  $call rt (es.at, $call T.t_func_x (ps.val, rr.val, fr, rm,
                        $call T.cints.reverse (es.val, T.cints.nil), T.cints.nil))
         }.ret2
         ($if ($call one (s, i, "t")) {
           $decl nm   $call read_n (s, j)
           $decl ms   $call read_flds (st, s, nm.at, nm.val, T.fields.nil)
           $decl fr   $call one (s, ms.at, "y")
           $decl q    $call read_s (s, $call add (ms.at, 1))
           $decl ret2 $call rt (q.at, $call T.t_trait_q (ms.val, fr, q.val))
         }.ret2
         ($if ($call one (s, i, "B")) {
           $decl nf   $call read_n (s, j)
           $decl fs   $call read_flds (st, s, nf.at, nf.val, T.fields.nil)
           $decl np   $call read_n (s, fs.at)
           $decl ps   $call read_prps (st, s, np.at, np.val, T.props.nil)
           $decl ret2 $call rt (ps.at, $call T.t_block (fs.val, ps.val))
         }.ret2
         ($if ($call one (s, i, "W")) {
           $decl bs   $call rtval ($call read_at (st, s, j))
           $decl np   $call read_n (s, bs.at)
           $decl ps   $call read_prps (st, s, np.at, np.val, T.props.nil)
           $decl ret2 $call rt (ps.at, $call T.t_with (bs.val, ps.val))
         }.ret2
              ($call rt (j, T.t_bot))))))))))))))))))))))
}.ret

$decl read_at $func ($decl st proto_cst, $decl s "", $decl i 0)
  $if ($call one (s, i, "R")) {
    $decl n   $call read_n (s, $call add (i, 1))
    $decl ret $call rt (n.at, $call ent_at ($call eval_ents (st.ents), n.val))
  }.ret {
    $decl e   $call read_body (st, s, i)
    $decl w   $call note_ty (st, $call T.tval (e.val))
    $decl ret $call rt (e.at, $call T.tval (e.val))
  }.ret

$decl read_ty $func ($decl s "", $decl i 0) {
  $decl st  $call cst ()
  $decl ret $call rtval ($call read_at (st, s, i))
}.ret
