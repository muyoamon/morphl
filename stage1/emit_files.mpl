// `emit_files <file.mpl>` — §9.1's `emit` produces a *list* of outputs, and this is the
// driver that shows them: one line per file, its path and its size in bytes.
//
// It exists because every other driver joins the list into one artifact (`sole_text`),
// which is right for a target that wants a single file but hides the split entirely. The
// writing driver grows from this one: §8's `write_file` is emitted now, so a compiled
// driver can put each output where its `path` says.
$decl C  $import "compiler"
$decl P  $import "prelude"

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))

$decl show $func ($decl fs C.ir.ofiles.node) $match fs (
  $case {$prop tag "cons"}
    $do ($call nl ($call concat (fs.head.path, $call concat ("  ",
             $call int_to_str ($call len (fs.head.text))))))
        ($call show ($call C.ir.ofiles.val (fs.tail))),
  $case fs ()
)

// Inside `main`, which makes this a **compiled-only** driver, and that is deliberate.
// A stage-0 driver does its work in top-level `$decl`s, because `--run` evaluates those
// and never calls `main`; a compiled one needs `main`, or the emitted C is a library and
// the link fails with `undefined reference to 'main'`. It cannot be both: §3.3's
// top-level items run from `mpl_init`, which runs *before* `main`, so a driver written
// both ways would do its work twice when compiled.
//
// Compiled-only is the right side for this one, because what it grows into is writing
// each output with §8's `write_file` — and that is only of use to a real build.
// `emit_diag.mpl` is compiled-only for the same reason.
$decl main $func ()
  { $decl argv $call args ()
    $decl path $call P.sval ($call at (argv, 0))
    $decl rf  $call read_file (path)
    $decl src $match rf (
        $case {$prop tag "some"} rf.v,
        $case rf ($call panic ($call concat ("cannot read ", path)))
      )
    $decl ckd $call C.check ($call C.parse (src, path))
    $decl out $call C.emit (ckd.program)
    $decl d   $call show ($call C.ir.ofiles.val (out.files))
    $decl r   "" }.r
