// A `$try` returning a member nothing else in the program interns: the only `none` here
// is the one it returns. Lowering never interned it, emit's lookup missed, and its
// fallback injected type 0 instead — a warning, and C returning an uninitialised result.
// 3, and compiled with -Werror.
$decl inc $func ($decl s "") {
  $decl n   $try ($call str_to_int (s)) none
  $decl ret $call add (n.v, 1)
}.ret
$decl main $func () {
  $decl a   $call inc ("x")
  $decl b   $call inc ("4")
  $decl ret 3
}.ret
