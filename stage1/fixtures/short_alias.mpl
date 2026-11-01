// §3.4: a block's `$decl h f`, `f` a top-level function, is another name for `f`, so a
// short call through `h` takes `f`'s defaults as one through a top-level alias does —
// from a function written beside it and from a block's later item too. Lowering used to
// bind `h` as the slot `f` is copied into and refuse the call as one through a value.
$decl f $func ($decl a 0, $decl b 3) $call add (a, b)
$decl main $func () {
  $decl h f
  $decl k $func ($decl x 0) $call h (x)
  $decl r { $decl g f  $decl v $call g (10) }
  $decl ret $call add ($call mul ($call h (1), 100), $call add ($call k (20), r.v))
}.ret
