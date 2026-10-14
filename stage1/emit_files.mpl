// `emit_files <file.mpl> [dir]` — §9.1's `emit` produces a *list* of outputs, and this is
// the driver that writes them, one file each, under `dir` (default `.`).
//
// It exists because every other driver joins the list into one artifact (`sole_text`),
// which is right for a target that wants a single file but hides the split entirely. The
// writing driver grows from this one: §8's `write_file` is emitted now, so a compiled
// driver can put each output where its `path` says.
$decl C $import "compiler"
$decl P $import "prelude"

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))

// Each output written where its `path` says, under `dir`. §8's `write_file` answers
// `<unit, err>`; a failure is reported and does not stop the rest, because a build wants
// to know about every one rather than the first.
$decl put $func ($decl dir "", $decl fs C.ir.ofiles.node) $match fs (
  $case {$prop tag "cons"} {
    $decl full $call concat (dir, $call concat ("/", fs.head.path))
    $decl w    $call write_file (full, fs.head.text)
    $decl say  $match w (
        $case {$prop tag "err"} ($call nl ($call concat ("cannot write ", full))),
        $case w ($call nl ($call concat (full, $call concat ("  ",
                     $call int_to_str ($call len (fs.head.text))))))
      )
    $decl ret $call put (dir, $call C.ir.ofiles.val (fs.tail))
  }.ret,
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
$decl main $func () {
  $decl argv $call args ()
  $decl path $call P.sval ($call at (argv, 0))
  $decl rf   $call read_file (path)
  $decl src $match rf (
      $case {$prop tag "some"} rf.v,
      $case rf ($call panic ($call concat ("cannot read ", path)))
    )
  $decl ckd $call C.check ($call C.parse (src, path))
  $decl out $call C.emit (ckd.program)
  $decl dir $if ($call lt (1, $call alen (argv))) ($call P.sval ($call at (argv, 1))) "."
  $decl d   $call put (dir, $call C.ir.ofiles.val (out.files))
  $decl ret ""
}.ret
