// A `$template` whose body is a `$func` reading the frame it is written in: the instance is a
// closure over that frame (`spec_fn_frame`), where it was a prop function with nowhere to
// keep the capture — refused as a prop's capture, or through an `$overload` lowered to read
// the frame's slot out of its own. Each shape adds a digit; `k` differs per call of `body`,
// so an instance that kept the first call's frame answers wrong.
$decl body $func ($decl k 0) {
  $decl int_one $func ($decl x 0) $call add (k, 1)
  $decl any_two $template T $func ($decl x T) 2
  $decl pick    $overload (int_one, any_two)
  $decl direct  $template T $func ($decl x T) $call int_one (x)
  $decl via     $template T $func ($decl x T) $call pick (x)
  $decl sp      $specialize direct 0
  $decl nested  $func ($decl y 0) $call direct (y)
  $decl count   $template T $func ($decl n T, $decl acc 0)
      $if ($call lt (n, 1)) acc ($call count ($call sub (n, 1), $call add (acc, k)))
  $decl ret $call add ($call mul ($call direct (5), 100000),
            $call add ($call mul ($call via (5), 10000),
            $call add ($call mul ($call via ("s"), 1000),
            $call add ($call mul ($call sp (9), 100),
            $call add ($call mul ($call nested (3), 10), $call count (1000000, 0))))))
}.ret
$decl main $func () $call add ($call body (1), $call mul ($call body (3), 1000000000))
