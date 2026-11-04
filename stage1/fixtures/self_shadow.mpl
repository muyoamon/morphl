// A block's `$func` naming itself is that function from its own line on (§4.1), whatever it is
// spelt like outside: lowering asked for the self-reference only when the name was unbound, so
// a local recursive `add` called §8's `add` — 6 for 32, silently, at the same signature — and a
// local `len` was refused for the intrinsic's. Only a binding in the literal's own frame hides
// it: `twice`'s parameter `twice`. 32 and 42, then 6: 32426.
$decl main $func () {
  $decl add $func ($decl n 0, $decl acc 0)
      $if ($call lt (n, 1)) acc ($call add ($call sub (n, 1), $call mul (acc, 2)))
  $decl len $func ($decl n 0, $decl acc 0)
      $if ($call lt (n, 1)) acc ($call len ($call sub (n, 1), $call sub (acc, -2)))
  $decl twice $func ($decl twice 0) $call mul (twice, 2)
  $decl ret $call sub ($call mul ($call sub ($call mul ($call add (5, 1), 100),
                $call sub (0, $call len (21, 0))), 10), $call sub (0, $call twice (3)))
}.ret
