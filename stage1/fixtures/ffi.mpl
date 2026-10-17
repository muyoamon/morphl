// §8's FFI intrinsics against a C host (`ffi_host.c`): an address is an `Int`
// (§3.1), `str_ptr` and `array_ptr` give the bytes and the elements, `box_ptr` the
// address of storage C writes through, and `unbox` a reference to memory C owns,
// typed by the example — read, then written whole and read back from C.
//
// 241 + 10 + 15 + 15 + 304 + 908 = 1493: the bytes of "ABn", the lengths 3 + 2 + 5,
// the cell bumped from 5 as C saw it and as morphl reads it, the point as C left
// it, and the point as morphl wrote it. Then `str_from_ptr`, which copies and validates:
// "héllo" read back is a 6-byte `Str` equal to the literal (+ 6 * 1000 + 10000),
// invalid UTF-8 is `none` (+ 100000), zero bytes from a null address is the empty
// `Str` (+ 1000000), and a negative length is `none` (+ 10000000) — 11117493.

$decl ival $func ($decl x 0) x

$decl sum_bytes  $extern "host_sum_bytes"  $func ($decl p 0, $decl n 0) 0
$decl total_len  $extern "host_total_len"  $func ($decl p 0, $decl n 0) 0
$decl bump       $extern "host_bump"       $func ($decl a 0) 0
$decl point      $extern "host_point"      $func () 0
$decl point_sum  $extern "host_point_sum"  $func () 0
$decl greeting   $extern "host_greeting"   $func () 0
$decl garbage    $extern "host_garbage"    $func () 0

// 1 when `str_from_ptr` answered `none`, else 0.
$decl is_none $func ($decl a 0, $decl n 0) {
  $decl o   $call str_from_ptr (a, n)
  $decl ret $match o ($case {$prop tag "some"} 0, $case o 1)
}.ret

$decl cell $mut $alloc 5

$decl main $func () {
  $decl s    "ABn"
  $decl r0   $call sum_bytes ($call str_ptr (s), $call len (s))
  $decl av   $call array (3, "abc")
  $decl a1   $call at (av, 1)
  $decl w1   $set a1 "de"
  $decl a2   $call at (av, 2)
  $decl w2   $set a2 "fghij"
  $decl r1   $call total_len ($call array_ptr (av), $call alen (av))
  $decl r2   $call bump ($call box_ptr (cell))
  $decl r3   $call ival (cell)
  $decl p    $call unbox ($call point (), { $decl x 0  $decl y 0 })
  $decl r4   $call add ($call mul (p.x, 100), p.y)
  $decl w3   $set p { $decl x 9  $decl y 8 }
  $decl r5   $call point_sum ()
  $decl g    $call str_from_ptr ($call greeting (), 6)
  $decl r6   $match g (
      $case {$prop tag "some"}
        $call add ($call mul ($call len (g.v), 1000), $if ($call eq (g.v, "héllo")) 10000 0),
      $case g -1)
  $decl r7   $call mul ($call is_none ($call garbage (), 2), 100000)
  $decl r8   $call mul ($call sub (1, $call is_none (0, 0)), 1000000)
  $decl r9   $call mul ($call is_none ($call greeting (), -1), 10000000)
  $decl ret  $call add ($call add ($call add ($call add (r0, r1), $call add (r2, r3)),
                 $call add (r4, r5)), $call add ($call add (r6, r7), $call add (r8, r9)))
}.ret
