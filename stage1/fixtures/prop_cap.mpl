// §4.10: a `$func` that is a prop's value may not capture. Its body is not evaluated where
// the prop stands, but its captures would be, each time the block is — a runtime value in
// what §4.10 makes part of the block's type. The checker accepted these and lowering
// refused them; the checker refuses them now, at the `$prop`, naming what is read. The
// legal shapes around them must stay legal, so the error count is exact. A template's
// body is checked where it is specialised (§10.7), so each one here is.
$decl twice $func ($decl x 0) $call mul (x, 2)
$decl make $func ($decl base 0) {
  // Refused: a parameter, directly.
  $decl a $template T { $prop f $func ($decl x 0) $call add (x, base) }
  // Refused: through a template of the frame whose body reads it.
  $decl w $template T { $decl v $call add (T, base) }
  $decl b $template T { $prop f $func ($decl x 0) ($specialize w x).v }
  // Legal: what the literal binds, a global, a sibling prop, a generic, and a template
  // that reads nothing of the frame.
  $decl q $template T { $decl v T }
  $decl c $template T {
    $prop k 3
    $prop g $func ($decl x 0) {
      $decl y   $call twice (x)
      $decl ret $call add ($call add (y, k), ($specialize q T).v)
    }.ret
  }
  // Refused: a `$func` the value evaluates — an `$overload`'s candidate, a `$union`'s first
  // member. Lowered at each projection, so from a nested `$func` it read the wrong frame.
  $decl o { $prop f $overload ($func ($decl x 0) $call add (x, base), $func ($decl s "") s) }
  $decl u { $prop f $union ($func ($decl x 0) $call add (x, base), $func ($decl x 0) x) }
  // Legal: a `$union`'s later members are type-only (§5.7), and candidates that capture
  // nothing.
  $decl l { $prop f $union ($func ($decl x 0) x, $func ($decl x 0) $call add (x, base)) }
  $decl m { $prop f $overload ($func ($decl x 0) $call twice (x), $func ($decl s "") s) }
  $decl ra  $call ($specialize a 0).f (1)
  $decl rb  $call ($specialize b 0).f (1)
  $decl ro  $call add ($call add ($call o.f (1), $call u.f (1)),
                $call add ($call l.f (1), $call m.f (1)))
  $decl ret $call add ($call ($specialize c 1).g (2), $call add (ra, $call add (rb, ro)))
}.ret
$decl counter {
  $decl n 1
  // Legal: the receiver.
  $prop get $func () counter.n
}
$decl main $func () $call make (7)
