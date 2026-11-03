// `override_diag.mpl`'s module: a template whose `ap` frees a parameter, which only lowering
// knows the provenance of (DEFER.md), and a plain member specialising a template whose body
// is not a block — refusals lowering alone makes. A short call through a function value,
// one whose default reads its frame (§3.4), and a `$free` under another allocator than the
// storage's used to be the second; the checker refuses them all now, and a check error
// stops the pipeline before lowering.
$decl box $template T {
  $prop k  0
  $prop ap $func ($decl r $alloc T) { $free r  $decl ret 1 }.ret
}
$decl five $template T 5
$decl ap2 $func () {
  $decl v   $specialize five 0
  $decl ret 1
}.ret
