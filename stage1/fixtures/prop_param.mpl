// A function-valued `$prop` read off a *parameter*. Prints 98.
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

$decl L  $specialize P.list 0
$decl sz $func ($decl l L) $call l.length ($call l.cons (4, $call l.cons (5, l.nil)), 0)

$decl t { $prop inner { $prop f $func () 30 } }
$decl n $func ($decl v t) $call v.inner.f ()

// A block built inside a prop's *body*. Lowering reaches a prop body only when
// something first projects it — here `main`, below the reader — so when the reader is
// lowered nothing has registered `g` yet, and the read is resolved at the end of the
// file instead (`resolve_pends`).
$decl holder { $prop mk $func () { $prop g $func ($decl x 0) $call mul (x, 10) } }
$decl late   $func ($decl b ($call holder.mk ())) $call b.g (4)

// The same inside a template, where the identity also carries the specialisation:
// inference typed `mk`'s body inside `$specialize tm 0`, and lowering enters it later,
// from wherever `S.mk` is first projected — so a module remembers the specialisation
// it was written in (`mod_ent_g`'s `isctx`).
$decl tm     $template T { $prop mk $func () { $prop g $func ($decl x T) $call add (x, 1) } }
$decl S      $specialize tm 0
$decl inspec $func ($decl b ($call S.mk ())) $call b.g (5)

$decl main $func () {
  // A `$func` literal's parameter is typed by lowering, from its default, rather
  // than by inference — the same identity has to come out either way.
  $decl f $func ($decl m b, $decl y 0) $call m.pf (y)
  // 3 + 10 + 2 + 30 + 7 + 40 + 6 = 98.
  $decl ret $call add ($call g (b), $call add ($call h (U), $call add ($call sz (L),
              $call add ($call n (t), $call add ($call f (b, 6),
              $call add ($call late ($call holder.mk ()), $call inspec ($call S.mk ())))))))
}.ret
