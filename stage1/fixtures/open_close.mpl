// DEFER.md: a resource from the root allocator, freed where it was not made. `open`
// allocates with a deferral, which the root's `defer_at` registers and its `free` runs;
// `close` frees its parameter, which its type records (`free(0)`), so every caller must
// pass root storage — and `open`'s result is, since its type does not say otherwise
// (no `nonroot`). `close2` frees through `close`, which makes it a freeing function too.
// Each step appends a digit: 2, then 4, then 3, then 1. Compiled only: stage 0 has no
// allocators.
$decl log  $mut $alloc 0
$decl ival $func ($decl x 0) x
$decl say  $func ($decl d 0) $set log ($call add ($call mul ($call ival (log), 10), d))
// A resource from the root: its deferral runs when it is freed, wherever that is.
$decl open   $func ($decl id 0) $alloc { $decl k id  $defer $call say (k) }
$decl close  $func ($decl f ($call open (0))) $free f
$decl close2 $func ($decl f ($call open (0))) $call close (f)
$decl main $func () {
  $decl a   $call open (1)
  $decl b   $call open (2)
  $decl c   $call open (3)
  $decl x   $call close (b)
  $decl y   $call say (4)
  $decl z   $call close2 (c)
  $decl w   $free a
  $decl ret $call ival (log)
}.ret
