// §4.9's template written inside a function, whose body reads that function's frame. The
// template's environment names that frame's slots, which are right where it is written and
// wrong in any other frame — a `$func` nested there, or the builder a self-reaching one is
// lowered as. So lowering keeps a *view* per template: inside a `$func` its frame bindings
// are captures (taken from the view, never by name where the use stands), inside a builder
// parameters after the generics, which each call passes. Lowering used to refuse a
// self-reaching one ("reads the enclosing frame"), and an ordinary one specialised inside a
// nested `$func` read the template's slot out of the wrong frame (5).
//
// The digits: 116 (two `make`s), 9, 5, 3 ticks, 3, 9 where the shadowing `lim`
// gives 25, and 39.

// 1. Through a `$func` member: `next` reaches the template; `tot` reads `base`.
$decl make $func ($decl base 0) {
  $decl ctr $template T {
    $decl n    T
    $decl tot  $call add (n, base)
    $decl next $func () $specialize ctr ($call add (n, 1))
  }
  $decl c2  $call ($call ($specialize ctr 1).next ()).next ()
  $decl ret c2.tot
}.ret

// 2. A direct reach, ended by a branch that reads the frame too.
$decl down $func ($decl lim 0) {
  $decl t $template T {
    $decl k T
    $decl m $if ($call lt (k, lim)) ($specialize t ($call add (k, 1))).m ($call mul (k, lim))
  }
  $decl ret ($specialize t 0).m
}.ret

// 3. Written a `$func` deeper, so what it reads is a capture there, not a slot.
$decl outer $func ($decl step 0) {
  $decl inner $func ($decl x 0) {
    $decl g $template T {
      $decl v    T
      $decl bump $func () $specialize g ($call add (v, step))
    }
    $decl ret ($call ($specialize g x).bump ()).v
  }.ret
  $decl ret $call inner (1)
}.ret

// Reading a value out of storage needs a value-expecting position.
$decl ival $func ($decl x 0) x

// 4. Storage: each instance's `tick` writes the one cell the frame owns.
$decl count $func () {
  $decl hits $mut $alloc 0
  $decl s $template T {
    $decl v    T
    $decl tick $func () { $decl w $set hits ($call add (hits, 1))  $decl ret $specialize s v }.ret
  }
  $decl a   $call ($call ($call ($specialize s 0).tick ()).tick ()).tick ()
  $decl ret $call ival (hits)
}.ret

// 5. Not self-reaching, specialised inside a nested `$func`.
$decl plain $func ($decl base 0) {
  $decl w   $template T { $decl v $call add (T, base) }
  $decl f   $func ($decl x 0) ($specialize w x).v
  $decl ret $call f (2)
}.ret

// 6. A direct-reach use under a block that shadows what the body reads: the body means the
// `lim` where it is written, so the builder is passed that one.
$decl shadow $func ($decl lim 0) {
  $decl t $template T {
    $decl k T
    $decl m $if ($call lt (k, lim)) ($specialize t ($call add (k, 1))).m ($call mul (k, lim))
  }
  $decl ret { $decl lim 5  $decl r ($specialize t 1).m }.r
}.ret

// 7. A deferral in a builder's body, naming another template of the frame: lowered at the
// builder's exit, which has to be inside its view still. 11 + 12 + 13, plus `c.n`.
$decl defers $func ($decl base 0) {
  $decl hits $mut $alloc 0
  $decl w $template T { $decl v $call add (T, base) }
  $decl ctr $template T {
    $decl n    T
    $defer $set hits ($call add (hits, ($specialize w n).v))
    $decl next $func () $specialize ctr ($call add (n, 1))
  }
  $decl c   $call ($call ($specialize ctr 1).next ()).next ()
  $decl ret $call add ($call ival (hits), c.n)
}.ret

$decl main $func () {
  $decl d1  $call add ($call make (10), $call make (100))
  $decl d2  $call down (3)
  $decl d3  $call outer (4)
  $decl d4  $call count ()
  $decl d5  $call plain (1)
  $decl d6  $call shadow (3)
  $decl d7  $call defers (10)
  $decl ret $call add ($call mul (d1, 10000000), $call add ($call mul (d2, 1000000),
                $call add ($call mul (d3, 100000), $call add ($call mul (d4, 10000),
                $call add ($call mul (d5, 1000), $call add ($call mul (d6, 100), d7))))))
}.ret
