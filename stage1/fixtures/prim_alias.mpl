// A block's another name for an intrinsic is the intrinsic (`lower_item0`): a call through it
// is inline, and a `$func` or a `$prop`'s `$func` naming it captures nothing — the lifted
// form of a file's `$decl isub sub`. `count` runs 2,000,000 deep through the aliases, so a
// self tail call that stopped being one would overflow at -O0 (§7.7).
$decl main $func () {
  $decl ilt   lt
  $decl isub  sub
  $decl iadd  add
  $decl cat   concat
  $decl b     { $prop less $func ($decl x 0, $decl y 0) $call ilt (x, y) }
  $decl k     $func ($decl x 0) $call isub (x, 1)
  $decl count $func ($decl n 0, $decl acc 0)
      $if ($call ilt (n, 1)) acc ($call count ($call isub (n, 1), $call iadd (acc, 2)))
  $decl s     $call cat ("ab", "cde")
  $decl n     $if ($call b.less (1, 2)) ($call k ($call len (s))) 0
  $decl ret   $call iadd ($call mul (n, 10000000), $call count (2000000, 0))
}.ret
