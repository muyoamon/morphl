// §3.3: a block's effects after its last `$decl` run after its slots. Lowering folds an
// effect into the next slot's initializer, and for trailing ones there is none — they
// were folded *around* the block instead, so they ran first: this answered 213, not 123.
$decl log  $mut $alloc 0
$decl ival $func ($decl x 0) x
$decl say  $func ($decl d 0) $set log ($call add ($call mul ($call ival (log), 10), d))
$decl main $func () {
  $decl r   { $decl a $call say (1)  $call say (2)  $call say (3) }
  $decl ret $call ival (log)
}.ret
