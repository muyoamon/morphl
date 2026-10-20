// std/vec's tests, as inline checks run by `std/test`: `mplc std/vec_test.mpl -L . -o …`
// from the repository root. A failure is reported on stderr and aborts; `main` answers how
// many passed, which `zig build test-std` compares.

$decl C $import "std/core"
$decl Q $import "std/seq"
$decl T $import "std/test"
$decl V $import "std/vec"

$decl ivec $specialize V.vec 0
$decl svec $specialize V.vec ""
$decl pt   { $decl x 0  $decl y 0 }
$decl pvec $specialize V.vec pt

// 0, 1, …, n-1 pushed onto `v`.
$decl fill $func ($decl v ($call ivec.new (0)), $decl i 0, $decl n 0)
  $if ($call lt (i, n)) ($do ($call v.push (i)) ($call fill (v, $call add (i, 1), n))) ()

$decl sum $func ($decl xs ($call ($call ivec.new (0)).items ()))
  $call Q.fold (xs, 0, $func ($decl a 0, $decl x 0) $call add (a, x))

$decl main $func () {
  $decl r   $call T.results ()
  $decl v   $call ivec.new (0)
  $decl c1  $call T.expect (r, "new is empty", $call C.and ($call v.is_empty (),
                                                            $call eq ($call v.length (), 0)))
  $decl f   $call fill (v, 0, 100000)
  $decl c2  $call T.expect (r, "push grows", $call eq ($call v.length (), 100000))
  $decl c3  $call T.expect (r, "...by doubling", $call eq ($call v.capacity (), 131072))
  $decl c4  $call T.expect (r, "get", $call eq ($call v.get (54321), 54321))
  $decl s   $call v.set (7, 700)
  $decl c5  $call T.expect (r, "set", $call eq ($call v.get (7), 700))
  $decl c6  $call T.expect (r, "items, folded",
                $call eq ($call sum ($call v.items ()), $call add (4999950000, 693)))
  $decl w   $call ivec.new (8)
  $decl c7  $call T.expect (r, "new with room", $call C.and ($call eq ($call w.capacity (), 8),
                                                             $call w.is_empty ()))
  $decl p1  $call w.push (1)
  $decl p2  $call w.push (2)
  $decl c8  $call T.expect (r, "pop", $call eq ($call C.or_else ($call w.pop (), -1), 2))
  $decl c9  $call T.expect (r, "...shortens", $call eq ($call w.length (), 1))
  $decl x   $call w.pop ()
  $decl c10 $call T.expect (r, "pop of an empty vec is none", $call C.is_none ($call w.pop ()))
  // Every copy of a vec is the same vec: the state is in its cells.
  $decl u   w
  $decl p3  $call u.push (9)
  $decl c11 $call T.expect (r, "a copy shares the elements", $call eq ($call w.get (0), 9))
  $decl it  $call w.items ()
  $decl p4  $call w.push (10)
  $decl c12 $call T.expect (r, "items reads the vec as it is", $call eq ($call Q.count (it, 0), 2))
  $decl ls  $call v.to_list ()
  $decl c13 $call T.expect (r, "to_list", $call C.and ($call eq ($call ls.length (), 100000),
                                                       $call eq ($call ls.nth (99999), 99999)))
  $decl cl  $call v.clear ()
  $decl c14 $call T.expect (r, "clear", $call C.and ($call v.is_empty (),
                                                     $call eq ($call v.capacity (), 131072)))
  $decl sv  $call svec.new (0)
  $decl q1  $call sv.push ("a")
  $decl q2  $call sv.push ("bc")
  $decl c15 $call T.expect (r, "another element type",
                $call eq ($call Q.fold ($call sv.items (), "",
                    $func ($decl a "", $decl t "") $call concat (a, t)), "abc"))
  $decl pv  $call pvec.new (0)
  $decl q3  $call pv.push ({ $decl x 3  $decl y 4 })
  $decl q4  $call pv.push ({ $decl x 5  $decl y 6 })
  $decl c16 $call T.expect (r, "records", $call eq ($call add (($call pv.get (0)).x,
                                                               ($call pv.get (1)).y), 9))
  $decl c17 $call T.expect (r, "map over items",
                $call eq ($call ($call Q.map ($call pv.items (), $func ($decl p pt) p.x)).nth (1),
                          5))
  $decl ret $call T.finish (r)
}.ret
