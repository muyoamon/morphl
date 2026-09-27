// `mplc` written the *other* way: the pipeline in top-level `$decl`s rather than
// inside `main`. This is the shape that used to segfault — a top-level `$decl`
// whose initializer calls into an imported module, reading a static `mpl_init`
// had not assigned yet — so it exists to prove the ordering fix at full scale: it
// emits byte-identical C to `mplc.mpl` for `lexer.mpl` and `types.mpl`. Nothing
// in `build.zig` runs it, because that would cost a three-minute emit per build —
// `stage1/fixtures/init_order.mpl` is the automated guard, and this is the
// full-size one to reach for if the ordering is ever touched again.
$decl C  $import "compiler"
$decl P  $import "prelude"

$decl argv $call args ()
$decl path $if ($call lt (0, $call alen (argv)))
    ($call P.sval ($call at (argv, 0)))
    ($call panic ("usage: mplc_top <file.mpl>"))

$decl rf  $call read_file (path)
$decl src $match rf (
  $case {$prop tag "some"} rf.v,
  $case rf ($call panic ($call concat ("cannot read ", path)))
)

$decl ckd $call C.check ($call C.parse (src, path))
$decl out $call C.emit (ckd.program)

$decl main $func () $call P.sval (out.text)
