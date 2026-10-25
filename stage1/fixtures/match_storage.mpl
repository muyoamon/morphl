// §4.7's catch-all on a name bound to storage: `$decl c $alloc …` keeps a reference
// (§5.4), and a `$match` on it narrows the pointee. Stage 0 dereferenced the scrutinee
// but not a name *pattern*, so `$case c` compared a reference with the block it points
// at and never matched — "no $match arm applied to block" — while the checker accepted
// the program and the compiled C answered it. Tag arms on the same storage always
// matched; only the bound-name catch-all missed.
//
// Each digit is one match: the tag arm and the catch-all on `$alloc` storage, the same
// through `$mut` storage after a `$set` changes which member it holds, and the
// workaround the bug forced — the value read out through an identity first. 2122121.

$decl mk $func ($decl k 0)
  $if ($call eq (k, 0)) { $prop tag "a"  $decl v 10 } { $prop tag "b" }
$decl id $func ($decl x $call mk (0)) x

$decl bound $func ($decl k 0) {
  $decl c   $alloc $call mk (k)
  $decl ret $match c ($case {$prop tag "a"} 1, $case c 2)
}.ret

$decl reset $func ($decl k 0) {
  $decl c   $mut $alloc $call mk (0)
  $decl s   $if ($call eq (k, 0)) c ($set c ($call mk (k)))
  $decl ret $match c ($case {$prop tag "a"} 1, $case c 2)
}.ret

$decl valued $func ($decl k 0) {
  $decl c   $alloc $call mk (k)
  $decl x   $call id (c)
  $decl ret $match x ($case {$prop tag "a"} 1, $case x 2)
}.ret

$decl digit $func ($decl acc 0, $decl d 0) $call add ($call mul (acc, 10), d)

$decl main $func () {
  $decl a   $call digit ($call bound (1), $call bound (0))
  $decl b   $call digit (a, $call bound (1))
  $decl c   $call digit (b, $call reset (1))
  $decl d   $call digit (c, $call reset (0))
  $decl e   $call digit (d, $call valued (1))
  $decl ret $call digit (e, $call valued (0))
}.ret
