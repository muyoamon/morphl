// §4.7: "a pattern is any expression, never evaluated". Lowering read a pattern's type
// off its syntax — a literal, a prop-only block or a name — and typed anything else ⊥,
// which no member is a subtype of: a projection onto a module's member (`U.ok`) gave its
// arm no discriminator, so the `switch` had no `case` for it and the match panicked
// "no $match arm applied". Inference typed it right, so nothing was reported. `$try`'s
// pattern goes through the same function. Stage 0 keeps patterns to the syntactic three
// (BOOTSTRAP §1.3), so this is compiled only.
//
// 321: 1 from `U.ok` in a `$match`, 20 from `U.miss` after it, and 300 from a `$try`
// on `U.miss` that returned rather than fell through.

$decl U $import "pattern_util"

$decl pick $func ($decl n 0)
  $if ($call lt (n, 0)) U.miss ($union (U.ok, U.miss))

$decl score $func ($decl n 0) {
  $decl r   $call pick (n)
  $decl ret $match r ($case U.ok 1, $case U.miss 20)
}.ret

$decl tried $func ($decl n 0) {
  $decl r   $try ($call pick (n)) U.miss
  $decl ret 7
}.ret

$decl main $func () {
  $decl t   $call tried (-1)
  $decl tv  $match t ($case 0 0, $case t 300)
  $decl ret $call add ($call score (1), $call add ($call score (-1), tv))
}.ret
