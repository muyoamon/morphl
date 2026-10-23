// A prop read deferred to the end of the file (`resolve_pends`) is a thunk lifted into the
// entry file's output, and `mpl_init` has to assign it before the entry's globals. `use`
// is `$fwd`'d, so its body is lowered at the `$fwd`, before `L` is: `L.cons` and
// `L.length` are read before their source is registered. Read as a *value*, `cons` came
// from a static nothing assigned — a zero pair, and a crash where stage 0 answers. 2.
$decl P   $import "../prelude"
$fwd use
$decl L   $specialize P.list 0
$decl use $func () {
  $decl c   L.cons
  $decl ret $call L.length ($call c (4, $call c (5, L.nil)), 0)
}.ret
$decl main $func () $call use ()
