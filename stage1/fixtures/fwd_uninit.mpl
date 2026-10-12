// §4.11's refused side: "References to `name` before its completing `$decl` are
// allowed only inside a `$func` or `$template` body" — and a `$func` body that
// an initializer *calls* runs before the `$decl` too. Must not type-check.
//
// Stage 0 refuses it at run time ("'f' is not initialized yet"); the compiled
// backend used to answer 7, because it emits a `$decl` of a `$func` as a plain C
// function and so has no empty slot to read. `zig build test-reject` checks that
// stage 1 reports each shape below and that stage 0 refuses the program.
$fwd f
$fwd v

// Read through a call: `x` runs `g`, which reads `f`'s empty slot.
$decl g $func () $call f ()
$decl x $call g ()

// Transitively, and of a value rather than a function: `y` runs `h`, which runs
// `k`, which reads `v`.
$decl k $func () v
$decl h $func () $call add ($call k (), 1)
$decl y $call h ()

// Directly, outside any `$func` body.
$decl z v

$decl f $func () 7
$decl v 5

$decl main $func () $call add (x, $call add (y, z))
