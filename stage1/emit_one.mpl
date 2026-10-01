// `emit_one <file.mpl> <output.c>` — print *one* named output of §9.1's split on stdout.
//
// Every other driver joins the list (`sole_text`) or writes it (`emit_files.mpl`, which
// is compiled-only because it needs `main`). This one runs under stage 0 and answers a
// single file, which is what makes the linkage property testable: a module's output has
// to be a function of its own source, so the same module in two different programs must
// come out byte-identical. `test-stable` in `build.zig` is that check.
$decl C  $import "compiler"
$decl P  $import "prelude"

$decl pick $func ($decl want "", $decl fs C.ir.ofiles.node) $match fs (
  $case {$prop tag "cons"}
    $if ($call eq_str (fs.head.path, want)) ($call print (fs.head.text))
        ($call pick (want, $call C.ir.ofiles.val (fs.tail))),
  $case fs ()
)

$decl argv $call args ()
$decl path $call P.sval ($call at (argv, 0))
$decl want $call P.sval ($call at (argv, 1))
$decl rf   $call read_file (path)
$decl src  $match rf (
    $case {$prop tag "some"} rf.v,
    $case rf ($call panic ($call concat ("cannot read ", path)))
  )
$decl ckd  $call C.check ($call C.parse (src, path))
$decl out  $call C.emit (ckd.program)
$decl go   $call pick (want, $call C.ir.ofiles.val (out.files))
