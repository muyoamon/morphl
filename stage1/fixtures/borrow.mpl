// §5.3a's provenance (STORAGE.md), the accepting side. A frame reference is a place; a
// function may hand back a place that came in — through a parameter, a capture, or a name
// in an enclosing frame — and a tail call may pass one it borrowed. All of these were
// refused before borrowing (§R).
//
// 30 + 5 + 7 + 1000 + 500500 + 50 = 501592: what `main` wrote through `pass`'s result,
// what `use` wrote through its method's, the top-level cell read through `peek`, `count`
// passing `main`'s cell down 1000 tail calls, `scratch` reading values out of its own, and
// `bigger` handing back the trait object over `use_big`'s own local it was given.

$decl ival $func ($decl x 0) x

// A place given, handed back; and one reached through a parameter's field.
$decl id_ref $func ($decl p $mut $new 0) p
$decl pick   $func ($decl b { $decl r $mut $new 0  $decl s $mut $new 0 }) b.r

// A method returning a place its enclosing function made: captured, so borrowed.
$decl use $func () {
  $decl ctr { $decl n $mut $new 0 }
  $decl get $func () ctr.n
  $decl w   $set ($call get ()) 5
  $decl ret $call ival (ctr.n)
}.ret

// A method returning a field of top-level storage: the outermost frame, so borrowed.
$decl top  { $decl n $mut $new 7  $prop cell $func () top.n }
$decl peek $func () $call top.cell ()

// Composition: `pass` borrows `q` because `id_ref` borrows its parameter.
$decl pass $func ($decl q $mut $new 0) $call id_ref (q)

// A tail call passing a borrowed place, and one reading a value out of its own.
$decl count $func ($decl c $mut $new 0, $decl n 0)
  $if ($call eq_int (n, 0)) ($call ival (c))
      ($do ($set c ($call add ($call ival (c), 1))) ($call count (c, $call sub (n, 1))))

$decl scratch $func ($decl n 0, $decl acc 0)
  $if ($call eq_int (n, 0)) acc
      ($call scratch ($call sub (n, 1), $call ival ($new $call add (acc, n))))

// A trait-typed parameter handed back is borrowed too: `bigger` returns one of the objects
// it was given, so a caller may pass one over its own local and read the result.
$decl shape  { $prop area $func () 0 }
$decl tri    { $decl b 6  $prop area $func () tri.b }
$decl bigger $func ($decl a $traitsof shape, $decl b $traitsof shape)
  $if ($call lt ($call a.area (), $call b.area ())) b a
$decl use_big $func () {
  $decl loc { $prop area $func () 50 }
  $decl w   $call bigger ($traitsof loc, $traitsof tri)
  $decl ret $call w.area ()
}.ret

$decl main $func () {
  $decl c    $mut $new 1
  $decl d    $call pass (c)
  $decl w    $set d 30
  $decl e    $mut $new 0
  $decl both { $decl r e  $decl s e }
  $decl w2   $set ($call pick (both)) 0
  $decl cell $mut $new 0
  $decl k    $call count (cell, 1000)
  $decl got  $call add ($call add ($call ival (c), $call use ()), $call ival ($call peek ()))
  $decl ret  $call add ($call add (got, $call add (k, $call scratch (1000, 0))), $call use_big ())
}.ret
