// std/map's tests, as inline checks run by `std/test`: `mplc std/map_test.mpl -L . -o …`
// from the repository root. A failure is reported on stderr and aborts; `main` answers how
// many passed, which `zig build test-std` compares.

$decl C $import "std/core"
$decl L $import "std/list"
$decl M $import "std/map"
$decl Q $import "std/seq"
$decl S $import "std/str"
$decl T $import "std/test"

$decl strs $specialize L.list ""
$decl ages $specialize M.map ("", 0)
$decl imap $specialize M.map (0, 0)
$decl ilt  lt
$decl less $func ($decl a 0, $decl b 0) $call ilt (a, b)

// i * 389 mod 1000 mapped to i, for i in 0 .. 999: every key once, in no order.
$decl fill $func ($decl m ($call imap.new (less)), $decl i 0)
  $if ($call lt (i, 1000))
      ($do ($call m.put ($call mod ($call mul (i, 389), 1000), i))
           ($call fill (m, $call add (i, 1))))
      ()
// Whether every key `k` maps to the `i` it was put with.
$decl right $func ($decl m ($call imap.new (less)), $decl i 0)
  $if ($call lt (i, 1000))
      ($if ($call eq ($call m.get_or ($call mod ($call mul (i, 389), 1000), -1), i))
           ($call right (m, $call add (i, 1))) false)
      true
$decl at_or $func ($decl o $union (none, { $prop tag "some"  $decl v 0 })) $call C.or_else (o, -1)

$decl main $func () {
  $decl r   $call T.results ()
  $decl m   $call ages.new (S.less)
  $decl c1  $call T.expect (r, "new is empty", $call m.is_empty ())
  $decl p1  $call m.put ("grace", 85)
  $decl p2  $call m.put ("ada", 36)
  $decl c2  $call T.expect (r, "put is new", $call m.put ("alan", 41))
  $decl c3  $call T.expect (r, "get", $call eq ($call at_or ($call m.get ("ada")), 36))
  $decl c4  $call T.expect (r, "get of an absent key", $call C.is_none ($call m.get ("bob")))
  $decl c5  $call T.expect (r, "put again replaces",
                $call C.and ($call C.not ($call m.put ("ada", 37)),
                             $call C.and ($call eq ($call m.get_or ("ada", 0), 37),
                                         $call eq ($call m.length (), 3))))
  $decl c6  $call T.expect (r, "has", $call C.and ($call m.has ("alan"), $call C.not ($call m.has ("al"))))
  $decl c7  $call T.expect (r, "keys in order",
                $call eq ($call S.concat_all ($call Q.to_list ($call m.keys (),
                                                               $call strs.empty ())),
                          "adaalangrace"))
  $decl c8  $call T.expect (r, "values in key order",
                $call eq ($call Q.fold ($call m.values (), 0,
                    $func ($decl a 0, $decl v 0) $call add ($call mul (a, 100), v)), 374185))
  $decl c9  $call T.expect (r, "key_at and value_at",
                $call C.and ($call eq ($call m.key_at (2), "grace"),
                             $call eq ($call m.value_at (1), 41)))
  $decl c10 $call T.expect (r, "remove", $call C.and ($call m.remove ("alan"),
                                                      $call eq ($call m.length (), 2)))
  $decl c11 $call T.expect (r, "...of an absent key", $call C.not ($call m.remove ("alan")))
  $decl c12 $call T.expect (r, "min_key and max_key",
                $call C.and ($call eq ($call C.or_else ($call m.min_key (), ""), "ada"),
                             $call eq ($call C.or_else ($call m.max_key (), ""), "grace")))
  $decl n   $call imap.new (less)
  $decl f   $call fill (n, 0)
  $decl c13 $call T.expect (r, "a thousand keys in no order", $call C.and ($call eq ($call n.length (), 1000),
                                                                          $call right (n, 0)))
  $decl c14 $call T.expect (r, "...kept sorted", $call Q.all ($call n.keys (), $func ($decl k 0)
                $call eq ($call n.key_at (k), k)))
  $decl u   n
  $decl w   $call u.put (5000, 1)
  $decl c15 $call T.expect (r, "a copy is the same map", $call n.has (5000))
  $decl cl  $call n.clear ()
  $decl c16 $call T.expect (r, "clear",
                $call C.and ($call n.is_empty (), $call C.is_none ($call n.get (5))))
  $decl ret $call T.finish (r)
}.ret
