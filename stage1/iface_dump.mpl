// `iface_dump <file.mpl> <member>` — print the serialised interface of one of a
// file's top-level members, which for an `$import` is the imported module's.
//
// This is what a per-module cache would store, so it is also what has to be stable:
// the same module reached from two different programs must render identically.
$decl I $import "infer"
$decl T $import "types"
$decl P $import "prelude"
$decl Y $import "tyio"

$decl pick $func ($decl fs T.fields.node, $decl nm "") $match fs (
  $case {$prop tag "cons"}
    $if ($call eq_str (fs.head.name, nm)) ($call T.tval (fs.head.ty))
        ($call pick ($call T.fields.val (fs.tail), nm)),
  $case fs T.t_bot
)

// A prop is in the type's *props*, not its fields (§4.10), and what a cache has to
// keep stable is its **value** — that is where `cv_opaque`'s identity sits.
$decl pick_prop $func ($decl xs T.props.node, $decl nm "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, nm)) ($call T.show_cv (xs.head.value))
        ($call pick_prop ($call T.props.val (xs.tail), nm)),
  $case xs ""
)

$decl argv $call args ()
$decl path $call P.sval ($call at (argv, 0))
$decl want $call P.sval ($call at (argv, 1))
$decl rf   $call read_file (path)
$decl src  $match rf ($case {$prop tag "some"} rf.v, $case rf ($call panic ("cannot read")))
$decl r    $call I.check_source (src, path, $call P.dirname (path))
$decl rty  $call T.tval (r.ty)
$decl fs   $match rty ($case {$prop tag "block"} ($call T.fields.val (rty.fields)), $case rty T.fields.nil)
$decl ps   $match rty ($case {$prop tag "block"} ($call T.props.val (rty.props)), $case rty T.props.nil)
$decl pv   $call pick_prop (ps, want)
// A field renders as its serialised type; a prop as its *value*, which is where a
// `cv_opaque`'s identity sits. Nothing else is printed: this is compared byte for
// byte, so a stray diagnostic line would make two programs differ for a reason that
// has nothing to do with the identity — which is exactly what a `fields:` line used
// for debugging did on the first run.
$decl out  $if ($call eq_str (pv, "")) ($call Y.show_ty ($call pick (fs, want)))
               ($call concat ("prop ", pv))
$decl go   $do ($call print (out)) ($call print ("\n"))
