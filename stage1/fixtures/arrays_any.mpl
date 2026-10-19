// §8's arrays at any element type: "`$call array (n, example)` → `&mut [T]`". Until
// STDLIB.md's P3 the root block bound them at `Str` alone (BOOTSTRAP §2), so stage 1
// had one array type. Now each call is typed from its own arguments — `array`, `at`,
// `alen` and `array_ptr` are bound at markers, as `box_ptr` and `unbox` are — and the
// backend, which never assumed `Str`, needed nothing.
//
// 4950 + 30 + 7 + 3 + 4 + 18 = 5012: `Int`s written and summed, records read through
// `at`, booleans written and read back, an array of arrays, an array's length through a
// template specialised at an array type, and a write through a nested `at`. Both stages
// run it, so it is in the differential set.

$decl ieq  eq
$decl ival $func ($decl x 0) x

$decl fill $func ($decl a $call array (0, 0), $decl i 0)
  $if ($call lt (i, $call alen (a)))
      ($do ($set ($call at (a, i)) i) ($call fill (a, $call add (i, 1)))) ()
$decl sum  $func ($decl a $call array (0, 0), $decl i 0, $decl acc 0)
  $if ($call lt (i, $call alen (a)))
      ($call sum (a, $call add (i, 1), $call add (acc, $call ival ($call at (a, i))))) acc

$decl size $template T $func ($decl a T) $call alen (a)

$decl pt   { $decl x 10  $decl y 20 }

$decl main $func () {
  $decl xs  $call array (100, 0)
  $decl f   $call fill (xs, 0)
  $decl s1  $call sum (xs, 0, 0)
  $decl ps  $call array (2, pt)
  $decl p   $call at (ps, 1)
  $decl s2  $call add (p.x, p.y)
  $decl bs  $call array (3, $union (false, true))
  $decl wb  $set ($call at (bs, 1)) true
  $decl n3  $if ($call at (bs, 1)) ($if ($call at (bs, 0)) 0 7) 0
  $decl m   $call array (3, $call array (2, ""))
  $decl s4  $call alen (m)
  $decl s5  $call ($specialize size ($call array (0, true))) ($call array (4, true))
  $decl g   $call array (2, $call array (3, 0))
  $decl w   $set ($call at ($call at (g, 1), 2)) 18
  $decl s6  $call ival ($call at ($call at (g, 1), 2))
  $decl ret $call add ($call add ($call add (s1, s2), $call add (n3, s4)), $call add (s5, s6))
}.ret
