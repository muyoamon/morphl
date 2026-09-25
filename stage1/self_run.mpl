// Stage 0 side of the stage-2 differential: run `self.mpl`'s pipeline under the
// interpreter, so the compiled binary's answer can be compared against it.
$decl S $import "self"
$decl d $call print ($call int_to_str ($call S.run_it (S.src)))
