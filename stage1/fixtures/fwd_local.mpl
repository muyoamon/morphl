// §4.11 inside a block: a `$fwd` in a function body, completed in the same block and read
// by a `$func` written in between. Compiled through a cell (`lower.mpl`'s `lower_fwd_item`),
// since §7.3 copies a binding and this one is empty until its `$decl` runs.

// Mutual recursion, a million deep: every call goes through a captured function value, so
// §7.7 holds only if §6a's trampoline carries it. `step` is captured too.
$decl parity $func ($decl n 0, $decl step 1) {
  $fwd odd
  $decl even $func ($decl k 0) $if ($call eq (k, 0)) true ($call odd ($call sub (k, step)))
  $decl odd  $func ($decl k 0) $if ($call eq (k, 0)) false ($call even ($call sub (k, step)))
  $decl ret  $if ($call even (n)) 1 0
}.ret

// The pair outlives the call that made it, so the cell cannot be in its frame.
$decl pair $func () {
  $fwd b
  $decl a   $func ($decl k 0) $if ($call lt (k, 1)) 0 ($call add (1, $call b ($call sub (k, 1))))
  $decl b   $func ($decl k 0) $if ($call lt (k, 1)) 0 ($call add (2, $call a ($call sub (k, 1))))
  $decl ret a
}.ret

// A block holding a `$fwd`, read as a record: the name's field is at the `$fwd`.
$decl rec $func () {
  $fwd g
  $decl h $func () $call add ($call g (), 1)
  $decl g $func () 40
}

$decl main $func () {
  $decl p   $call add ($call mul ($call parity (1000000), 1000), $call mul ($call parity (7), 100))
  $decl q   $call add ($call ($call pair ()) (5), $call ($call rec ()).h ())
  $decl ret $call add (p, q)
}.ret
