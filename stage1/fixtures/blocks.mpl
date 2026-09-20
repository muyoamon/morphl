// A round-trip fixture for §7.2's layout: a block is a C struct in `$decl`
// order, props occupy no space, and blocks nest. 9 + 7 = 16.
$decl point $func ($decl a 0, $decl b 0) { $decl x a  $decl y b }

$decl seg $func ($decl p $call point (0, 0), $decl q $call point (0, 0))
  { $decl lo p  $decl hi q }

$decl span $func ($decl s $call seg ($call point (0, 0), $call point (0, 0)))
  $call sub (s.hi.x, s.lo.x)

// A `$prop` is in the type but not the layout (§4.10), so this is a one-field
// struct, not two.
$decl tagged { $prop tag "origin"  $decl x 7 }

$decl main $func ()
  $call add ($call span ($call seg ($call point (1, 2), $call point (10, 20))), tagged.x)
