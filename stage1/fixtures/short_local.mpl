// §3.4: a short call to a *local* `$func` — one a block's `$decl` binds — evaluates the
// omitted defaults per call, in the callee's scope with no parameter bound. The checker
// accepted it and stage 0 ran it; lowering refused it, since only a top-level function or
// a module member had a definition to take defaults from. Now the defaults are lowered at
// the call against the callee's scope as that frame sees it — a `$func` naming the callee
// captures what they read, as for a template's body — so from a nested `$func` too, under a
// block shadowing what they read, and in a builder. Each case answers 1 when it gives what
// stage 0 does, so a regression is a 0 at its position.
$decl ival $func ($decl x 0) x
$decl two  $func ($decl f $func ($decl b 0) 0, $decl want 0)
  $if ($call eq ($call add ($call mul ($call f (7), 100), $call f (10)), want)) 1 0

// 1. In the frame that wrote it.
$decl here $func ($decl base 0) {
  $decl h   $func ($decl x 0, $decl y base) $call add (x, y)
  $decl ret $call h (1)
}.ret
// 2. From a nested `$func`, which captures `base` for the default without naming it.
$decl nested $func ($decl base 0) {
  $decl h   $func ($decl x 0, $decl y base) $call add (x, y)
  $decl g   $func () $call h (1)
  $decl ret $call g ()
}.ret
// 3. Under a block that shadows what the default reads: the callee's `base` is meant.
$decl shadow $func ($decl base 0) {
  $decl h   $func ($decl x 0, $decl y base) $call add (x, y)
  $decl ret { $decl base 50  $decl r $call h (1) }.r
}.ret
// 4. Evaluated per call: storage it reads, written between two calls.
$decl percall $func ($decl base 0) {
  $decl c   $mut $alloc base
  $decl h   $func ($decl x 0, $decl y ($call ival (c))) $call add (x, y)
  $decl a   $call h (1)
  $decl w   $set c 30
  $decl g   $func () $call h (1)
  $decl ret $call add ($call mul (a, 100), $call g ())
}.ret
// 5. Through an alias, two `$func`s deep.
$decl alias $func ($decl base 0) {
  $decl h   $func ($decl x 0, $decl y base) $call add (x, y)
  $decl h2  h
  $decl g   $func () { $decl k $func () $call h2 (1)  $decl ret $call k () }.ret
  $decl ret $call g ()
}.ret
// 6. A default that is a short call to another local `$func`.
$decl chain $func ($decl base 0) {
  $decl j   $func ($decl z base) $call mul (z, 2)
  $decl h   $func ($decl x 0, $decl y ($call j ())) $call add (x, y)
  $decl g   $func () $call h (1)
  $decl ret $call g ()
}.ret
// 7. In a self-reaching template's builder, which takes what the default reads.
$decl builder $func ($decl base 0) {
  $decl h   $func ($decl x 0, $decl y base) $call add (x, y)
  $decl ctr $template T {
    $decl n    T
    $decl tot  $call h (n)
    $decl next $func () $specialize ctr ($call add (n, 1))
  }
  $decl c2  $call ($call ($specialize ctr 1).next ()).next ()
  $decl ret c2.tot
}.ret

$decl d $func ($decl acc 0, $decl x 0) $call add ($call mul (acc, 10), x)
$decl main $func () {
  $decl a   $call d ($call d ($call d ($call two (here, 811), $call two (nested, 811)),
                $call two (shadow, 811)), $if ($call eq ($call percall (7), 831)) 1 0)
  $decl ret $call d ($call d ($call d (a, $call two (alias, 811)), $call two (chain, 1521)),
                $call two (builder, 1013))
}.ret
