// `override_diag.mpl`'s module: a template whose `ap` frees a parameter, which only lowering
// knows the provenance of (DEFER.md), and a plain member specialising a template whose value
// specialises itself where it is evaluated (§4.9) — refusals lowering alone makes. A body that
// is not a block used to be the second, until value bodies were lowered; a short call through a
// function value and others before that, which the checker refuses now, and a check error
// stops the pipeline before lowering.
$decl box $template T {
  $prop k  0
  $prop ap $func ($decl r $alloc T) { $free r  $decl ret 1 }.ret
}
$decl five $template T $call add (T, $specialize five T)
$decl ap2 $func () {
  $decl v   $specialize five 0
  $decl ret 1
}.ret
