// `override_diag.mpl`'s module: a template whose `ap` frees a parameter, which only lowering
// knows the provenance of (DEFER.md), and a plain member that frees storage under an
// allocator other than the one that made it — refusals lowering alone makes. A short call
// through a function value, and then one whose default reads its frame (§3.4), used to be
// the second; the checker refuses both now, and a check error stops the pipeline before
// lowering.
$decl box $template T {
  $prop k  0
  $prop ap $func ($decl r $alloc T) { $free r  $decl ret 1 }.ret
}
$decl ap2 $func () {
  $decl r         $alloc 3
  $decl allocator {
    $prop alloc $func ($decl n 0) $call raw_alloc (n)
    $prop free  $func ($decl a 0, $decl n 0) $call raw_free (a)
  }
  $free r
  $decl ret 1
}.ret
