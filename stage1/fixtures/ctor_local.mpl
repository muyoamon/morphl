// §5.3a: a block's local constructor used as a value is not lowered yet. Its value is a
// closure, and no shim answering `{b, d}` is written for one, so lowering refuses it rather
// than hand a static constructor's pair to a dynamic call. The checker accepts it, and stage
// 0 runs it (5). Called by name it is fine.
$decl mk   $func ($decl n 0) $new { $decl v n }
$decl with $func ($decl make mk, $decl n 0) { $decl r $call make (n)  $decl ret r.v }.ret
$decl main $func () {
  $decl lm  $func ($decl n 0) $new { $decl v $call add (n, 1) }
  $decl ret $call with (lm, 4)
}.ret
