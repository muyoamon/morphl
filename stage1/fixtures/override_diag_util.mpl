// `override_diag.mpl`'s module: a template whose `ap` makes a short call through a
// function value, which only lowering refuses (§3.4), and a plain member that does too.
$decl box $template T {
  $prop k  0
  $prop ap $func ($decl g ($func ($decl a T, $decl b 3) a)) $call g (1)
}
$decl ap2 $func ($decl g ($func ($decl a 0, $decl b 3) a)) $call g (2)
