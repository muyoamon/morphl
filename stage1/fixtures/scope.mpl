// A round-trip fixture for §4.10's source-order scoping inside a module.
//
// The module it imports declares `$decl isub sub` above its own `$decl sub`,
// which is the documented way to keep an intrinsic that the file goes on to
// shadow. If a module's members were all made visible before any was lowered —
// which is what makes forward references work — `isub` would silently become
// the file's own `sub`, and integer subtraction would turn into addition. That
// is a wrong answer, not a diagnostic, which is why it has a fixture.
//
// isub(10,1) = 9; even(4) = 1; sub(3,4) = 7. 17.

$decl U $import "scope_util"

$decl main $func ()
  $call add ($call U.isub (10, 1), $call add ($call U.even (4), U.shadowed))
