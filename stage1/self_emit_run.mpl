// Stage 0 side of the emit differential: the same driver under the interpreter.
$decl S $import "self_emit"
$decl d $call print ($call S.emit_it (S.src))
