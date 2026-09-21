// A round-trip fixture for §5.5's recursive types, end to end.
//
// This imports the *actual* prelude and specialises the *actual* `list`
// template, so it exercises the whole chain at once: `$import` (§4.14),
// `$specialize` (§4.9), a `$prop` whose value names itself through storage
// (§5.5), and a `μ` laid out as a C struct.
//
// The layout is the point. `μR. <{head, tail: &R}, nil>` becomes two structs —
// the cons cell, whose recursive field is a *pointer*, and the tagged union
// the `μ` names — and the cell has to be defined before the union that embeds
// it, which is not the order they were interned in. §5.5's guardedness is what
// makes that order exist at all: every recursive edge is a pointer.
//
// 3 + 8 + 9 = 20.

$decl P $import "../prelude"

$decl ints $specialize P.list 0

$decl main $func ()
  { $decl xs $call ints.cons (7, $call ints.cons (8, $call ints.cons (9, ints.nil)))
    $decl ys $call ints.reverse (xs, ints.nil)
    $decl r  $call add ($call ints.length (xs, 0),
                 $call add ($call ints.nth (xs, 1), $call ints.nth (ys, 0))) }.r
