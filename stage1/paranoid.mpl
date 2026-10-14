// Paranoid mode: compile a file with `T.same` checking every class comparison against
// the structural reference, and report where they part. Compiled-only, like `mplc`:
//
//   mplc stage1/paranoid.mpl > p.c && cc -O2 -o paranoid p.c && ./paranoid <file.mpl>
//
// `zig build test-paranoid` runs it over the whole compiler. It exists because the class
// key (`types.mpl`'s `ckey`, built in each constructor) has to mirror `same_deep` case by
// case and nothing else would notice if it stopped: a **merge** — two types `same_deep`
// calls different in one class — is a miscompile, and a **split** — one type in two
// classes — is only slow. INTERNING.md says why both directions are checked.
//
// The check runs the full pipeline through `emit`, because lowering and emit compare
// far more types than inference does, and stops with a non-zero exit on a merge.
$decl C $import "compiler"
$decl T $import "types"
$decl P $import "prelude"

$decl argv $call args ()
$decl path $if ($call lt (0, $call alen (argv)))
    ($call P.sval ($call at (argv, 0)))
    ($call panic ("usage: paranoid <file.mpl>"))

$decl rf  $call read_file (path)
$decl src $match rf (
  $case {$prop tag "some"} rf.v,
  $case rf ($call panic ($call concat ("cannot read ", path)))
)

$decl main $func () {
  $decl on  $call T.set_paranoid (true)
  $decl ckd $call C.check ($call C.parse (src, path))
  $decl bad $call C.verify (ckd.program)
  $decl out $call C.emit (ckd.program)
  $decl n   $call T.pz_counts ()
  $decl s   $call concat ("paranoid: ", $call concat ($call int_to_str (n.class),
            $call concat (" compared by class, ", $call concat ($call int_to_str (n.fallbacks),
            $call concat (" fallbacks, ", $call concat ($call int_to_str (n.merges),
            $call concat (" merges, ", $call concat ($call int_to_str (n.splits), " splits\n"))))))))
  $decl g   $if ($call lt (0, n.merges))
      ($call panic ($call concat (s, "a merge is two different types in one class: the class key no longer mirrors same_deep")))
      ""
  $decl ret   s
}.ret
