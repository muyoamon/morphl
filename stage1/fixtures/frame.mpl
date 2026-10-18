// §7.6's frame storage as C locals (STORAGE.md, step 3): each `$new` site is a local of
// its function, declared with the slots, and a top-level one is a `static`.
//
// `scratch` makes a cell on each of 2,000,000 iterations of a self tail loop, which reuses
// one local; `build.zig` also runs it under a memory cap below what 2,000,000 allocated
// cells would need. `pick` makes its cell inside an `$if` arm and uses it after, which is
// why the locals are declared at the top and not where the `$new` stands. `even`/`odd`
// are a contified group whose members make cells. `counter` is top-level storage written
// from a function, so it must outlive the thunk that made it.
//
// 2000001000000 + 11 + 21 + 2500 + 103 = 2000001002635.

$decl ival $func ($decl x 0) x

$decl scratch $func ($decl n 0, $decl acc 0)
  $if ($call eq_int (n, 0)) acc
      ($call scratch ($call sub (n, 1), $call ival ($new $call add (acc, n))))

$decl pick $func ($decl b $union (false, true)) {
  $decl c   $if b ($mut $new 10) ($mut $new 20)
  $decl w   $set c ($call add ($call ival (c), 1))
  $decl ret $call ival (c)
}.ret

$fwd odd

$decl even $func ($decl n 0, $decl acc 0)
  $if ($call eq_int (n, 0)) acc
      ($call odd ($call sub (n, 1), $call add (acc, $call ival ($new 2))))

$decl odd $func ($decl n 0, $decl acc 0)
  $if ($call eq_int (n, 0)) acc
      ($call even ($call sub (n, 1), $call add (acc, $call ival ($new 3))))

$decl counter $mut $new 100

$decl bump $func () $set counter ($call add ($call ival (counter), 1))

$decl main $func () {
  $decl s   $call scratch (2000000, 0)
  $decl p   $call add ($call pick (true), $call pick (false))
  $decl g   $call even (1000, 0)
  $decl b1  $call bump ()
  $decl b2  $call bump ()
  $decl b3  $call bump ()
  $decl ret $call add ($call add (s, p), $call add (g, $call ival (counter)))
}.ret
