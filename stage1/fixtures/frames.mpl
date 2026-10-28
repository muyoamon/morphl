// Constructs whose source lowering keeps and lowers again later, used from a frame other
// than the one they were written in — a `$func` nested there. Three silent miscompiles had
// this shape (`spec_frame.mpl`, `prop_cap.mpl`); these are the neighbours that were probed
// and found right, kept so they stay so. Each case runs at two values of the frame and
// answers 1 when both are what stage 0 says, so a regression is a 0 at its position.
$decl ival $func ($decl x 0) x
$decl two  $func ($decl f $func ($decl b 0) 0, $decl want 0)
  $if ($call eq ($call add ($call mul ($call f (7), 100), $call f (10)), want)) 1 0
$decl shape { $prop area $func () 0 }
$decl use   $func ($decl s ($traitsof shape)) $call s.area ()

// 1. A receiver's member, called from a nested `$func`.
$decl recv $func ($decl base 0) {
  $decl b   { $decl v base  $prop get $func () b.v }
  $decl g   $func () $call b.get ()
  $decl ret $call g ()
}.ret
// 2. A member writing through its receiver's storage, from a nested `$func`.
$decl recv_mut $func ($decl base 0) {
  $decl c   { $decl n $mut $alloc base  $prop inc $func () $set c.n ($call add (c.n, 1)) }
  $decl g   $func () $call c.inc ()
  $decl a   $call g ()
  $decl b   $call g ()
  $decl ret $call ival (c.n)
}.ret
// 3. A member taken as a value there, a closure over its receiver (§4.10).
$decl member $func ($decl base 0) {
  $decl b   { $decl v base  $prop get $func () b.v }
  $decl g   $func () { $decl f b.get  $decl ret $call f () }.ret
  $decl ret $call g ()
}.ret
// 4. An `$impl` over a block of the frame.
$decl impl $func ($decl base 0) {
  $decl b   $impl { $decl v base } ($traitsof shape) { $prop area $func () b.v }
  $decl g   $func () $call b.area ()
  $decl ret $call g ()
}.ret
// 5. A trait object of a block of the frame, made in the nested `$func`.
$decl tobj $func ($decl base 0) {
  $decl b   { $decl v base  $prop area $func () b.v }
  $decl g   $func () $call use (b)
  $decl ret $call g ()
}.ret
// 6. A block with props inside a template instance built in the nested `$func`.
$decl inst $func ($decl base 0) {
  $decl t   $template T { $decl v T  $decl b { $decl w v  $prop get $func () b.w } }
  $decl g   $func ($decl x 0) $call ($specialize t x).b.get ()
  $decl ret $call add ($call g (base), $call g (1))
}.ret
// 7. A `$defer` in the nested `$func` naming the frame.
$decl defers $func ($decl base 0) {
  $decl hits $mut $alloc 0
  $decl g    $func ($decl x 0) {
    $defer $set hits ($call add (hits, base))
    $decl ret x
  }.ret
  $decl a    $call g (1)
  $decl b    $call g (2)
  $decl ret  $call ival (hits)
}.ret
// 8. A `$fwd`'d local `$func`, completed after the one calling it.
$decl fwd $func ($decl base 0) {
  $fwd h
  $decl g   $func ($decl x 0) $call h (x)
  $decl h   $func ($decl x 0) $call add (x, base)
  $decl ret $call g (1)
}.ret
// 9. A capturing local `$func` reached through a block's field.
$decl field $func ($decl base 0) {
  $decl h   $func ($decl x 0) $call add (x, base)
  $decl b   { $decl f h }
  $decl g   $func ($decl x 0) $call b.f (x)
  $decl ret $call g (1)
}.ret
// 10. A local `$overload` of capturing candidates.
$decl over $func ($decl base 0) {
  $decl h   $overload ($func ($decl x 0) $call add (x, base), $func ($decl s "") $call len (s))
  $decl g   $func ($decl x 0) $call add ($call h (x), $call h ("ab"))
  $decl ret $call g (1)
}.ret

$decl d $func ($decl acc 0, $decl x 0) $call add ($call mul (acc, 10), x)
$decl main $func () {
  $decl a   $call d ($call d ($call d ($call two (recv, 710), $call two (recv_mut, 912)),
                $call two (member, 710)), $call two (impl, 710))
  $decl b   $call d ($call d ($call d ($call d (a, $call two (tobj, 710)), $call two (inst, 811)),
                $call two (defers, 1420)), $call two (fwd, 811))
  $decl ret $call d ($call d (b, $call two (field, 811)), $call two (over, 1013))
}.ret
