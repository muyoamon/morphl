// §4.9's self-reaching instance with no `$func` between: a `$decl` initializer specialises
// the template it is in. §4.9 makes evaluating it evaluate that instance in turn, "like any
// unconditional recursion" — so a branch may end it, and stage 0 always ran such a program.
// Lowering refused it, because it builds each use inline and the use unfolds again. It is a
// builder function that calls itself there now (`lower.mpl`, `spec_knot`), and the site and
// every later use call the builder too.
//
// The digits: a use projected under a branch (3); a later use at the same argument type,
// which calls the builder rather than building inline (5); a prop read off the builder's
// result (1); a template reaching itself both directly and through a `$func` (7); and one
// template at two argument types (4, 2). 351742.

// 1. Counts up to 3.
$decl upto $template T {
  $decl n T
  $decl m $if ($call lt (n, 3)) ($specialize upto ($call add (n, 1))).m n
}

// 2. A prop beside the reach.
$decl tagged $template T {
  $prop kind "tagged"
  $decl n    T
  $decl d    $if ($call lt (n, 2)) ($call add (($specialize tagged ($call add (n, 1))).d, 1)) 0
}

// 3. Directly and through a `$func`.
$decl both $template T {
  $decl n    T
  $decl s    $if ($call lt (n, 4)) ($call add (($specialize both ($call add (n, 1))).s, n)) 0
  $decl next $func () $specialize both ($call add (n, 1))
}

// 4. At `Int` and at `Str`.
$decl to_s $overload ($func ($decl x 0) $call int_to_str (x), $func ($decl x "") x)
$decl grow $template T {
  $decl v T
  $decl k $if ($call lt ($call len ($call to_s (v)), 4))
              ($specialize grow ($call concat ($call to_s (v), "x"))).k ($call len ($call to_s (v)))
}

$decl d $func ($decl acc 0, $decl x 0) $call add ($call mul (acc, 10), x)

$decl main $func () {
  $decl a   ($specialize upto 0).m
  $decl b   $call sub (($specialize upto 1).m, -2)
  $decl t   $specialize tagged 0
  $decl c   $if ($call eq_str (t.kind, "tagged")) ($call sub (t.d, 1)) 0
  $decl bo  $specialize both 3
  $decl e   $call add (bo.s, ($call bo.next ()).n)
  $decl g   ($specialize grow 7).k
  $decl h   $call sub (($specialize grow "abcdef").k, 4)
  $decl ret $call d ($call d ($call d ($call d ($call d (a, b), c), e), g), h)
}.ret
