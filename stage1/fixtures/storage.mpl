// A round-trip fixture for §4.2: `$new` is the only way storage exists, and
// §7.3's aliasing — `$decl y n` aliases, it does not copy. Prints 154.
//
// The global matters most: §4.10 initialises it once, in source order, so both
// bumps must land in the *same* cell. A backend that re-evaluated the
// initializer at each mention would print 7 here, not 12.
$decl counter $mut $new 0

$decl bump $func ($decl by 0) $set counter ($call add (counter, by))

$decl pair $func ($decl a 0, $decl b 0) { $decl x a  $decl y b }

$decl main $func ()
  $do ($call bump (5))
  ($do ($call bump (7))
    { $decl n  $mut $new 0
      // §7.3: an alias, so writing through either is visible through both.
      $decl y  n
      $decl w1 $set n ($call add (n, 40))
      $decl w2 $set y ($call add (y, 2))
      // Storage holding a block (§7.4: a thin pointer to a struct).
      $decl p  $new ($call pair (1, 2))
      $decl w3 $set p ($call pair (100, 200))
      $decl out $call add ($call add (counter, n), $call sub (p.y, p.x)) }.out)
