// `open_mod.mpl`'s library: `open_close.mpl`'s resource, as module members. Lowering
// rebuilds a member's type from its body, so the facts inference found — `close` frees
// its parameter, `open`'s result is root storage — reach it through `member_facts`.
$decl log  $mut $alloc 0
$decl ival $func ($decl x 0) x
$decl say  $func ($decl d 0) $set log ($call add ($call mul ($call ival (log), 10), d))
$decl open   $func ($decl id 0) $alloc { $decl k id  $defer $call say (k) }
$decl close  $func ($decl f ($call open (0))) $free f
$decl close2 $func ($decl f ($call open (0))) $call close (f)
// A sibling's result freed inside the module: `open` named from beside it.
$decl cycle  $func ($decl id 0) {
  $decl r   $call open (id)
  $decl ret $free r
}.ret
$decl read   $func () $call ival (log)
// Storage from another allocator, handed back without the root's guarantee (`nonroot`):
// `lower_test`'s `t37f` frees it, which must be refused. Never called by `open_mod.mpl`.
$decl arena  $func () {
  $decl a   { $prop alloc $func ($decl n 0) 0  $prop free $func ($decl p 0, $decl s 0) () }
  $decl ret a
}.ret
$decl other  $func () {
  $decl allocator $call arena ()
  $decl ret $alloc { $decl k 2 }
}.ret
