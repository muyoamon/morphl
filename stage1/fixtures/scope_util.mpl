// §4.10's source order, and §4.11's escape from it.
//
// `isub` captures the intrinsic `sub` *before* the declaration below shadows
// it — a `$decl`'s initializer sees only what precedes it, so this resolves to
// the root block (§2.1) and not to the `sub` two lines down. The whole trick
// only works if a module's members become visible in source order.
$decl isub sub

// Shadows `sub` for every `$func` body in this file, including ones written
// above it — a body resolves against the finished block.
$decl sub $func ($decl a 0, $decl b 0) $call add (a, b)

// §4.11: `$fwd` reserves the name at *its own* position, so `odd` may name
// `even` although the completing `$decl` comes later.
$fwd even
$decl odd  $func ($decl n 0) $if ($call eq_int (n, 0)) 0 ($call even ($call isub (n, 1)))
$decl even $func ($decl n 0) $if ($call eq_int (n, 0)) 1 ($call odd ($call isub (n, 1)))

// Reads the shadowed `sub`, which adds.
$decl shadowed $call sub (3, 4)
