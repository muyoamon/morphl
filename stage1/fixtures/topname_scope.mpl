// A local spelled like a top-level name is a frame binding, not a global: a callback to C,
// a trait object and an `$alloc` block's deferral that read one must say so. The checker used
// to ask a set of bare top-level names, and compiled all three with the frame read dropped.
$decl qsort $extern "void qsort(void *, size_t, size_t, void *)"
    $func ($decl a 0, $decl n 0, $decl w 0, $decl f $func ($decl x 0, $decl y 0) 0) ()
$decl helper 3
$decl g { $prop get $func () 1 }
$decl s "top"
$decl cb $func () {
  $decl helper 5
  $decl c   $func ($decl x 0, $decl y 0) helper
  $decl r   $call qsort (0, 0, 8, c)
  $decl ret 0
}.ret
$decl tr $func () {
  $decl g   { $decl v 1  $prop get $func () 1 }
  $decl ret $traitsof g
}.ret
$decl dfr $func () {
  $decl s   "local"
  $decl r   $alloc { $decl k 1  $defer $call print (s) }
  $decl ret 0
}.ret
// Legal: the same reads of the globals themselves.
$decl ok $func () {
  $decl c   $func ($decl x 0, $decl y 0) helper
  $decl r   $call qsort (0, 0, 8, c)
  $decl t   $traitsof g
  $decl a   $alloc { $decl k 1  $defer $call print (s) }
  $decl ret 0
}.ret
$decl ok2 $func () $traitsof g
$decl main $func () 0
