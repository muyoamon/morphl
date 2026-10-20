// A block built inside its own recursive constructor, with a member taking another value
// of its type (§4.10's `$decl o w`) — the shape of a list wrapper (STDLIB.md, D9). The
// constructor's result closes twice, over the block and then over the constructor, and
// the second close used to miss the members' types, so every member answered the
// constructor's unsolved placeholder and `$call ($call w0 ()).push (3)` could not be
// projected from. And `unroll`'s memo, keyed by `same`, which ignores a prop's type,
// handed the settled type the stale members. At the top level and in a template. 6205.
$decl of $func ($decl c 0) {
  $decl w   {
    $decl k c
    $prop push $func ($decl x 0) $call of ($call add (w.k, x))
    $prop app  $func ($decl o w) $call of ($call add (w.k, o.k))
    $prop same $func ($decl o w) $call eq (w.k, o.k)
    $prop n    $func () w.k
  }
  $decl ret w
}.ret

$decl box $template T {
  $prop of $func ($decl c T) {
    $decl w   {
      $decl v c
      $prop put  $func ($decl x T) $call of (x)
      $prop pick $func ($decl o w, $decl first true) $call of ($if first w.v o.v)
      $prop get  $func () w.v
    }
    $decl ret w
  }.ret
}
$decl sbox $specialize box ""

$decl main $func () {
  $decl a   $call ($call ($call of (0)).push (3)).push (4)
  $decl b   $call a.app ($call ($call a.push (1)).app (a))
  $decl s   $call ($call sbox.of ("ab")).put ("xyz")
  $decl t   $call ($call s.pick ($call sbox.of ("q"), true)).put ("hello")
  $decl ret $call add ($call add ($call mul ($call b.n (), 100), $call len ($call t.get ())),
              $if ($call b.same (b)) 4000 0)
}.ret
