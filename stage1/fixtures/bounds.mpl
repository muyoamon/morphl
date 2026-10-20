// §4.9's bounds, in TRAITS.md's syntax: a generic is a bare name, unbounded, or
// `$decl name bound`, written as a `$func` parameter is. A bound is checked at every
// specialisation — `type(arg) <: type(bound)` — with the generics bound to the arguments,
// so an F-bound names the generic itself: `max` asks for a `K` that compares with
// another `K`, which is how "another value of my own type" is said without `Self`.
//
// 7 + 18 + 30 = 55: the larger of two through an F-bound, a trait bound, and a template with
// one plain generic beside a bounded one. Stage 0 binds the names and ignores the bounds,
// as it ignores every type; the refusals are `infer_test`'s.

$decl ilt lt

$decl ord_proto $template T { $prop lt $func ($decl o T) $union (false, true) }
$decl max $template ($decl K $traitsof ($specialize ord_proto K))
  $func ($decl a K, $decl b K) $if ($call a.lt (b)) b a

$decl mk $func ($decl v 0) {
  $decl p   { $decl x v  $prop lt $func ($decl o p) $call ilt (p.x, o.x) }
  $decl ret p
}.ret

$decl shape_proto { $prop area $func () 0 }
$decl doubled $template ($decl S $traitsof shape_proto)
  $func ($decl s S) $call mul ($call s.area (), 2)
$decl sq { $prop area $func () 9 }

$decl scaled $template (N, $decl S $traitsof shape_proto)
  $func ($decl n N, $decl s S) $call add (n, $call s.area ())
$decl big { $prop area $func () 25 }

$decl main $func () {
  $decl a   ($call ($specialize max ($call mk (0))) ($call mk (3), $call mk (7))).x
  $decl b   $call ($specialize doubled sq) (sq)
  $decl c   $call ($specialize scaled (0, big)) (5, big)
  $decl ret $call add ($call add (a, b), c)
}.ret
