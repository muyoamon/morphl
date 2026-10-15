// §6 across a module boundary: a trait object made in one output dispatches to members
// defined in another, through a table in the shared header — and the module's own
// coercion runs in its initialiser (§4.10).
//
// 37 + 12 = 49.

$decl U $import "traits_util"

$decl main $func () {
  // A copy reaches its members through itself (§4.10), and is coerced here.
  $decl r   U.rect
  $decl ret $call add (U.answer, $call U.one (r))
}.ret
