// A round-trip fixture for §7.4's coercion between two unions.
//
// §3.6 makes a union a *set*, so two unions can agree on their members and
// disagree on the order — and §7.5 makes the order the discriminator. So using
// a value of one where the other is expected is a **re-tag**: one `case` per
// source member, writing the target's position and moving the payload across.
//
// §3.2's `Bool` is the exception the re-tag has to know about: it is the union
// `true | false`, but its discriminator *is* its value, so there is no `.tag`
// to read and its members are nullary tags with nothing to move.
//
// 1 + 20 + 300 = 321.

$decl a { $prop tag "a"  $decl v 1 }
$decl b { $prop tag "b"  $decl v 20 }
$decl c { $prop tag "c"  $decl v 300 }

$decl small $union (a, b)
$decl big   $union (c, a, b)

$decl widen $func ($decl x big) $match x (
  $case {$prop tag "a"} x.v,
  $case {$prop tag "b"} x.v,
  $case x x.v
)

// `small` is `<a,b>`, the parameter is `<c,a,b>`: same members, different
// positions.
$decl from_small $call widen (small)

// A member on its own, injected rather than re-tagged.
$decl from_member $call widen (b)

// And the third member, reached through a union that never held it.
$decl from_c $call widen (c)

$decl main $func () $call add (from_small, $call add (from_member, from_c))
