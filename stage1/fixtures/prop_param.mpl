// A function-valued `$prop` read off a *parameter*. Prints 52.
//
// §4.10 puts a prop's value in its block's type, so a parameter's type names the one
// definition and nothing at run time can change which — reading the prop is sound
// without any layout. But the type carries only an identity (`cv_opaque`), and lowering
// used to refuse every one of these with "the value of prop … is not reachable from
// here". Two things had to hold: lowering must mint the *same* identity inference does
// (a parameter's type is inference's, a block literal's is lowering's), and it must map
// that identity back to the prop's source (`prop_by_id`).
//
// One of each place a function-valued prop is written, since each mints its identity
// in a different context: the entry file, an imported module, a `$specialize` body
// (where inference's memo key is part of the identity), and a prop nested in a prop.
$decl P $import "../prelude"
$decl U $import "prop_param_util"

$decl b { $prop pf $func ($decl x 0) $call add (x, 1)  $decl k 2 }
$decl g $func ($decl m b) $call m.pf (m.k)

$decl h $func ($decl u U) $call u.twice (u.base)

$decl L $specialize P.list 0
$decl sz $func ($decl l L) $call l.length ($call l.cons (4, $call l.cons (5, l.nil)), 0)

$decl t { $prop inner { $prop f $func () 30 } }
$decl n $func ($decl v t) $call v.inner.f ()

$decl main $func ()
  { // A `$func` literal's parameter is typed by lowering, from its default, rather
    // than by inference — the same identity has to come out either way.
    $decl f $func ($decl m b, $decl y 0) $call m.pf (y)
    // 3 + 10 + 2 + 30 + 7 = 52.
    $decl r $call add ($call g (b), $call add ($call h (U), $call add ($call sz (L),
                $call add ($call n (t), $call f (b, 6))))) }.r
