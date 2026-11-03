// §3.4: a short call to a `$func` prop evaluates the omitted defaults in a wrapper, a
// function of its own (lowering's `build_wrap`), so a default naming a binding of the frame
// the prop is written in — legal for its type (§5.7) — has nothing to read there. Lowering
// refused these after the checker accepted them; the checker refuses them at the call now.
// Stage 0 evaluates a default where its function was written, and runs them all.
$decl q { $prop k 5 }
$decl f $func () {
  $decl p { $prop k 2 }
  $prop r { $prop k 3 }
  // Refused: by projection, by name from a sibling, and leaving off only the one that reads.
  $decl b {
    $prop g $func ($decl a 1, $decl s p, $decl t q) $call add (a, $call add (s.k, t.k))
    $decl v $call g ()
  }
  $decl x $call b.g ()
  $decl y $call b.g (10)
  // Legal: passing it, and defaults reading a global, a prop or nothing.
  $decl c { $prop h $func ($decl a 1, $decl t q, $decl u r) $call add (a, $call add (t.k, u.k)) }
  $decl ret $call add ($call b.g (10, p), $call c.h ())
}.ret
// Refused: a top-level block's `$decl` is its initializer's frame, not a global.
$decl top {
  $decl p { $prop k 2 }
  $decl b { $prop g $func ($decl s p) s.k }
  $decl v $call b.g ()
}
$decl main $func () $call add ($call f (), top.v)
