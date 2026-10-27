// §5.1's group rule: `(S₁, …, Sₙ) <: (T₁, …, Tₘ)` when `m ≤ n` and each `Sᵢ <: Tᵢ`, and,
// since §2.3 makes `(T)` be `T`, a group is a subtype of its first element. A coercion of a
// value copies the prefix, coercing each item. Argument lists are not groups and stay
// exact (§3.4); a group is one argument only through a name, since `((1, 2))` is `(1, 2)`.
//
// The digits: a prefix (3), depth inside it — a longer block in the first position (5), a
// group used as its first element (7), a join of two lengths read at the shorter (2), and a
// group answered as a shorter group's type (9). 35729.

$decl two $func ($decl g (0, 0)) $call add (g.1, g.2)

$decl inner $func ($decl g ({ $decl a 0 }, 0)) $call add (g.1.a, g.2)

$decl only $func ($decl n 0) n

$decl pick $func ($decl c $union (false, true)) {
  $decl long  (1, 2, 3)
  $decl short (0, 2)
  $decl g     $if c long short
  $decl ret   g.2
}.ret

$decl shorter $func ($decl c $union (false, true))
  $if c (4, 5, 6) (9, 0)

$decl d $func ($decl acc 0, $decl x 0) $call add ($call mul (acc, 10), x)

$decl main $func () {
  $decl t3  (1, 2, 30)
  $decl a   $call two (t3)
  $decl tb  ({ $decl a 2  $decl b 9 }, 3, "x")
  $decl b   $call inner (tb)
  $decl t7  (7, "seven")
  $decl c   $call only (t7)
  $decl e   $call pick (true)
  $decl s   $call shorter (false)
  $decl ret $call d ($call d ($call d ($call d (a, b), c), e), s.1)
}.ret
