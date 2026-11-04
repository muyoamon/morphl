// What a capture check asks by name must follow scope. A local spelled like an intrinsic is a
// frame binding, and a name bound to a `$func` literal answers with the literal in scope, not
// the last one any `$decl` of that name was bound to.
$decl qsort $extern "void qsort(void *, size_t, size_t, void *)"
    $func ($decl a 0, $decl n 0, $decl w 0, $decl f $func ($decl x 0, $decl y 0) 0) ()
$decl cb $func ($decl x 0, $decl y 0) 0
$decl rt $func ($decl k 0) {
  $decl add $func ($decl a 0, $decl b 0) k
  $decl c   $func ($decl x 0, $decl y 0) $call add (x, y)
  $decl r   $call qsort (0, 0, 8, c)
  $decl ret 0
}.ret
$decl par $func ($decl cb $func ($decl x 0, $decl y 0) 0) $call qsort (0, 0, 8, cb)
$decl pr $func ($decl add $func ($decl a 0, $decl b 0) 0) {
  $decl b   { $prop f $func () $call add (1, 2) }
  $decl ret 0
}.ret
// Legal: a local `cb` that captures, and after it the top-level one passed as itself.
$decl loc $func ($decl k 0) {
  $decl cb  $func ($decl x 0, $decl y 0) k
  $decl ret $call cb (1, 2)
}.ret
$decl ok $func () {
  $decl r   $call qsort (0, 0, 8, cb)
  $decl c   $func ($decl x 0, $decl y 0) $call add (x, y)
  $decl s   $call qsort (0, 0, 8, c)
  $decl ret 0
}.ret
$decl main $func () 0
