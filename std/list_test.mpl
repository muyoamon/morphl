// std/list's tests: `mplc std/list_test.mpl -L . -o …`, from the repository root. A
// failing check panics with its name; `main` answers how many passed (`zig build
// test-std`).

$decl C $import "std/core"
$decl L $import "std/list"

$decl ints $specialize L.list 0
$decl strs $specialize L.list ""

$decl check $func ($decl name "", $decl ok C.bool) $if ok 1 ($call panic ($call concat ("FAIL ", name)))

// 0, 1, …, n-1, built back to front so the recursion is a tail call.
$decl upto $func ($decl n 0, $decl acc ints.node)
  $if ($call lt (0, n)) ($call upto ($call sub (n, 1), $call ints.cons ($call sub (n, 1), acc))) acc

$decl sum  $func ($decl xs ints.node)
  $call ints.fold (xs, 0, $func ($decl a 0, $decl x 0) $call add (a, x))
$decl show $func ($decl xs ints.node)
  $call strs.fold ($call ints.map (xs, $func ($decl n 0) $call int_to_str (n)), "",
                   $func ($decl a "", $decl s "") $call concat (a, s))
$decl even $func ($decl n 0) $call eq ($call mod (n, 2), 0)
$decl less $func ($decl a 0, $decl b 0) $call lt (a, b)

// Pairs ordered by their first element only, so a stable sort keeps the seconds in order.
$decl pr    { $decl k 0  $decl s "" }
$decl prs   $specialize L.list pr
$decl mk    $func ($decl a 0, $decl b "") { $decl k a  $decl s b }
$decl by_k  $func ($decl a pr, $decl b pr) $call lt (a.k, b.k)
$decl seconds $func ($decl xs prs.node)
  $call strs.fold ($call prs.map (xs, $func ($decl p pr) p.s), "",
                   $func ($decl a "", $decl s "") $call concat (a, s))

$decl main $func () {
  $decl xs  $call upto (10, ints.nil)
  $decl big $call upto (1000000, ints.nil)
  $decl c1  $call check ("length", $call eq ($call ints.length (xs, 0), 10))
  $decl c2  $call check ("a million is a loop", $call eq ($call ints.length (big, 0), 1000000))
  $decl c3  $call check ("fold", $call eq ($call sum (xs), 45))
  $decl c4  $call check ("map to another type", $call eq ($call show (xs), "0123456789"))
  $decl c5  $call check ("reverse", $call eq ($call show ($call ints.reverse (xs, ints.nil)), "9876543210"))
  $decl c6  $call check ("nth", $call eq ($call ints.nth (xs, 7), 7))
  $decl c7  $call check ("append", $call eq ($call show ($call ints.append ($call upto (3, ints.nil),
                                       $call upto (2, ints.nil))), "01201"))
  $decl c8  $call check ("take", $call eq ($call show ($call ints.take (xs, 3, ints.nil)), "012"))
  $decl c9  $call check ("take past the end",
                $call eq ($call ints.length ($call ints.take (xs, 99, ints.nil), 0), 10))
  $decl c10 $call check ("drop", $call eq ($call show ($call ints.drop (xs, 7)), "789"))
  $decl c11 $call check ("filter", $call eq ($call show ($call ints.filter (xs, even, ints.nil)), "02468"))
  $decl c12 $call check ("any", $call ints.any (xs, $func ($decl n 0) $call eq (n, 9)))
  $decl c13 $call check ("all", $call C.not ($call ints.all (xs, even)))
  $decl c14 $call check ("find", $call eq ($call C.or_else ($call ints.find (xs, $func ($decl n 0)
                                       $call lt (4, n)), -1), 5))
  $decl c15 $call check ("find nothing", $call C.is_none ($call ints.find (xs, $func ($decl n 0)
                                       $call lt (99, n))))
  $decl ys  $call ints.cons (5, $call ints.cons (1, $call ints.cons (4, $call ints.cons (1,
                $call ints.cons (3, ints.nil)))))
  $decl c16 $call check ("sort_by", $call eq ($call show ($call ints.sort_by (ys, less)), "11345"))
  // Smaller than `big`: the runtime never frees (BOOTSTRAP §3), and a sort allocates
  // log₂ n lists of every length — a million elements came to 1.3 GB.
  $decl mid $call upto (50000, ints.nil)
  $decl c17 $call check ("sort_by a big list", $call eq ($call ints.nth ($call ints.sort_by (
                $call ints.reverse (mid, ints.nil), less), 12345), 12345))
  $decl ps  $call prs.cons ($call mk (2, "a"), $call prs.cons ($call mk (1, "b"),
                $call prs.cons ($call mk (2, "c"), $call prs.cons ($call mk (1, "d"), prs.nil))))
  $decl c18 $call check ("sort_by is stable", $call eq ($call seconds ($call prs.sort_by (ps, by_k)), "bdac"))
  $decl arr $call array (4, 0)
  $decl w   $set ($call at (arr, 2)) 7
  $decl c19 $call check ("from_array", $call eq ($call show ($call ints.from_array (arr)), "0070"))
  $decl c20 $call check ("is_nil",
                $call C.and ($call ints.is_nil (ints.nil), $call C.not ($call ints.is_nil (xs))))
  $decl ret $call add ($call add ($call add ($call add (c1, c2), $call add (c3, c4)),
                                 $call add ($call add (c5, c6), $call add (c7, c8))),
                       $call add ($call add ($call add (c9, c10), $call add (c11, c12)),
                                 $call add ($call add ($call add (c13, c14), $call add (c15, c16)),
                                           $call add ($call add (c17, c18), $call add (c19, c20)))))
}.ret
