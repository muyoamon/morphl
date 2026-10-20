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

$decl isv  $specialize V.sorted_vec 0
$decl ilt  lt
$decl less $func ($decl a 0, $decl b 0) $call ilt (a, b)
// 0 .. 999 in no order: i * 389 mod 1000, each once.
$decl scramble $func ($decl s ($call isv.new (less, 0)), $decl i 0)
  $if ($call lt (i, 1000))
      ($do ($call s.insert ($call mod ($call mul (i, 389), 1000)))
           ($call scramble (s, $call add (i, 1))))
      ()
// How many of 0 .. 999 `search` finds.
$decl found $func ($decl s ($call isv.new (less, 0)), $decl x 0, $decl n 0)
  $if ($call lt (x, 1000))
      ($call found (s, $call add (x, 1),
                    $if ($call C.is_some ($call s.search (x))) ($call add (n, 1)) n))
      n
// Whether `v`'s elements never decrease, read by position.
$decl ordered $func ($decl s ($call isv.new (less, 0)), $decl i 1)
  $if ($call lt (i, $call s.length ()))
      ($if ($call lt ($call s.get (i), $call s.get ($call sub (i, 1)))) false
           ($call ordered (s, $call add (i, 1))))
      true
// Records ordered by key alone, so equal keys show the order they were inserted in.
$decl kvec $specialize V.sorted_vec pt
$decl by_x $func ($decl a pt, $decl b pt) $call ilt (a.x, b.x)
$decl ys   $func ($decl s ($call kvec.new (by_x, 0)), $decl i 0, $decl acc 0)
  $if ($call lt (i, $call s.length ()))
      ($call ys (s, $call add (i, 1), $call add ($call mul (acc, 10), ($call s.get (i)).y)))
      acc

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
  $decl sv2 $call isv.new (less, 0)
  $decl sc  $call scramble (sv2, 0)
  $decl c18 $call T.expect (r, "sorted_vec keeps its order",
                $call C.and ($call eq ($call sv2.length (), 1000), $call ordered (sv2, 1)))
  $decl c19 $call T.expect (r, "...so search finds everything", $call eq ($call found (sv2, 0, 0), 1000))
  $decl c20 $call T.expect (r, "...and std/seq's search too, through indexed_of",
                $call eq ($call C.or_else ($call Q.search_by (sv2, 777, less), -1), 777))
  $decl c21 $call T.expect (r, "remove", $call C.and ($call sv2.remove (500),
                                                      $call eq ($call sv2.length (), 999)))
  $decl c22 $call T.expect (r, "...of an absent one", $call C.not ($call sv2.remove (500)))
  $decl c23 $call T.expect (r, "...keeps the order", $call C.and ($call ordered (sv2, 1),
                $call eq ($call C.or_else ($call sv2.search (501), -1), 500)))
  $decl c24 $call T.expect (r, "min and max",
                $call C.and ($call eq ($call C.or_else ($call sv2.min (), -1), 0),
                             $call eq ($call C.or_else ($call sv2.max (), -1), 999)))
  $decl e3  $call isv.new (less, 0)
  $decl c25 $call T.expect (r, "...of nothing", $call C.is_none ($call e3.min ()))
  $decl kv  $call kvec.new (by_x, 0)
  $decl i1  $call kv.insert ({ $decl x 2  $decl y 1 })
  $decl i2  $call kv.insert ({ $decl x 1  $decl y 2 })
  $decl i3  $call kv.insert ({ $decl x 2  $decl y 3 })
  $decl i4  $call kv.insert ({ $decl x 1  $decl y 4 })
  $decl c26 $call T.expect (r, "equal elements keep their order", $call eq ($call ys (kv, 0, 0), 2413))
  $decl ret $call T.finish (r)
}.ret
