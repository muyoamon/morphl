// §4.10: a `$prop`'s `$func` may not capture, and a top-level name is no capture because
// lowering makes it a global (§7.3) — but only where it is in scope. The checker asked a
// set of names, so the module's `helper` made every `helper` a global: a function's own
// local, and the `$override` below, whose names are hidden as `$o:helper` and were judged
// by the plain name. Lowering refused all three after the checker accepted them, and the
// override was what `tools/sweep.sh --lift` found, `override2.mpl` lifted into a function.
// A block's `$decl` at the top level is a slot of its initializer's frame, not a global.
// Stage 0 has no such rule, and leaves `$override` out.
$decl U $import "prop_cap_util"
$decl local $func () {
  $decl helper $func () 200
  $decl b   { $prop two $func ($decl x 0) $call helper () }
  $decl top $override U.base { $prop one $func ($decl x 0) $call helper () }
  $decl t   $specialize top 0
  $decl ret $call add ($call b.two (0), $call t.sum (0))
}.ret
$decl x {
  $decl y 7
  $decl b { $prop g $func ($decl z 0) y }
  $decl v $call b.g (0)
}
// Legal: a global, a `$fwd`'d one before its `$decl`, and a function naming itself.
$fwd later
$decl self $func ($decl n 0) {
  $decl b   { $prop g $func ($decl k 0) $if ($call eq (k, 0)) ($call later ()) ($call self (0)) }
  $decl ret $call add ($call b.g (n), $call U.helper ())
}.ret
$decl later $func () 5
$decl main $func () $call add ($call local (), $call add (x.v, $call self (1)))
