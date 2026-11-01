// `override_diag.mpl`'s module: a template whose `ap` frees a parameter, which only lowering
// knows the provenance of (DEFER.md), and a plain member whose short call would evaluate a
// default reading its frame in a wrapper that has none (§3.4) — refusals lowering alone
// makes. A short call through a function value used to be both; the checker refuses that
// now, and a check error stops the pipeline before lowering.
$decl box $template T {
  $prop k  0
  $prop ap $func ($decl r $alloc T) { $free r  $decl ret 1 }.ret
}
$decl ap2 $func () {
  $decl p   { $prop k 2 }
  $decl b   { $prop g $func ($decl s p) s.k }
  $decl ret $call b.g ()
}.ret
