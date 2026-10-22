// DEFER.md: `open_close.mpl` with the resource in a library. `M.open`'s result is root
// storage and `M.close` frees its parameter, though both are module members, whose types
// lowering derives. Each step appends a digit: 5, 2, 4, 3, then 1. Compiled only: stage 0
// has no allocators.
$decl M $import "open_util"
$decl main $func () {
  $decl v   $call M.cycle (5)
  $decl a   $call M.open (1)
  $decl b   $call M.open (2)
  $decl c   $call M.open (3)
  $decl x   $call M.close (b)
  $decl y   $call M.say (4)
  $decl z   $call M.close2 (c)
  $decl w   $free a
  $decl ret $call M.read ()
}.ret
