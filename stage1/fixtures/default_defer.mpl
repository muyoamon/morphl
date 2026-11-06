// A parameter default is a type-only position (§5.7): lowering derives its type and throws
// the tree away (`type_only`). A `$new { … $defer … }` there left its deferral on the
// enclosing frame's stack, which lowered it against captures that frame does not have:
// `verify` said "capture index 0 names nothing" for a program the checker accepted and
// stage 0 ran. Here every call passes the argument, so the default is never evaluated.
$decl main $func () {
  $decl log  $mut $alloc 0
  $decl say  $func ($decl d 0) $set log ($call add ($call mul (log, 10), d))
  $decl peek $func ($decl r $new { $decl v 0  $defer $call say (9) }) $call say (r.v)
  $decl a    $call peek ($new { $decl v 4 })
  $decl b    $call peek ($new { $decl v 2 })
  $decl ret  $call add ($call mul (log, 10), 1)
}.ret
