// std/list's tests, as inline checks run by `std/test`: `mplc std/list_test.mpl -L . -o …`
// from the repository root. A failure is reported on stderr and aborts; `main` answers how
// many passed, which `zig build test-std` compares. `map`, `fold` and the bounded forms are
// `std/seq`'s, and tested there.

$decl C $import "std/core"
$decl L $import "std/list"
$decl T $import "std/test"

$decl ints $specialize L.list 0
$decl strs $specialize L.list ""

// A parameter typed "a list of `Int`" is defaulted to an empty one (D9).
// 0, 1, …, n-1, pushed back to front so the recursion is a tail call.
$decl upto $func ($decl n 0, $decl acc ($call ints.empty ()))
  $if ($call lt (0, n)) ($call upto ($call sub (n, 1), $call acc.push ($call sub (n, 1)))) acc
$decl upto0 $func ($decl n 0) $call upto (n, $call ints.empty ())

$decl sum $func ($decl xs ($call ints.empty ()), $decl acc 0)
  $if ($call xs.is_empty ()) acc ($call sum ($call xs.rest (), $call add (acc, $call xs.head ())))
$decl show $func ($decl xs ($call ints.empty ()), $decl acc "")
  $if ($call xs.is_empty ()) acc
      ($call show ($call xs.rest (), $call concat (acc, $call int_to_str ($call xs.head ()))))
$decl even $func ($decl n 0) $call eq ($call mod (n, 2), 0)
$decl less $func ($decl a 0, $decl b 0) $call lt (a, b)

// Pairs ordered by their first element only, so a stable sort keeps the seconds in order.
$decl pr    { $decl k 0  $decl s "" }
$decl prs   $specialize L.list pr
$decl mk    $func ($decl a 0, $decl b "") { $decl k a  $decl s b }
$decl by_k  $func ($decl a pr, $decl b pr) $call lt (a.k, b.k)
$decl seconds $func ($decl xs ($call prs.empty ()), $decl acc "")
  $if ($call xs.is_empty ()) acc
      ($call seconds ($call xs.rest (), $call concat (acc, ($call xs.head ()).s)))

// The cells are a plain union, for code that wants to `$match`.
$decl second $func ($decl xs ($call ints.empty ())) {
  $decl c   xs.cells
  $decl ret $match c (
      $case {$prop tag "cons"} $call ints.cell.head ($call ints.cell.val (c.tail)),
      $case c -1
    )
}.ret

$decl main $func () {
  $decl r   $call T.results ()
  $decl xs  $call upto0 (10)
  $decl big $call upto0 (1000000)
  $decl c1  $call T.expect (r, "length", $call eq ($call xs.length (), 10))
  $decl c2  $call T.expect (r, "a million is a loop", $call eq ($call big.length (), 1000000))
  $decl c3  $call T.expect (r, "head, rest, is_empty", $call eq ($call sum (xs, 0), 45))
  $decl c4  $call T.expect (r, "push in front",
                $call eq ($call show ($call xs.push (7), ""), "70123456789"))
  $decl c5  $call T.expect (r, "a pushed list is a new one", $call eq ($call xs.length (), 10))
  $decl c6  $call T.expect (r, "reverse", $call eq ($call show ($call xs.reverse (), ""), "9876543210"))
  $decl c7  $call T.expect (r, "nth", $call eq ($call xs.nth (7), 7))
  $decl c8  $call T.expect (r, "append",
                $call eq ($call show ($call ($call upto0 (3)).append ($call upto0 (2)), ""), "01201"))
  $decl c9  $call T.expect (r, "take", $call eq ($call show ($call xs.take (3), ""), "012"))
  $decl c10 $call T.expect (r, "take past the end",
                $call eq ($call ($call xs.take (99)).length (), 10))
  $decl c11 $call T.expect (r, "drop", $call eq ($call show ($call xs.drop (7), ""), "789"))
  $decl c12 $call T.expect (r, "drop past the end", $call ($call xs.drop (99)).is_empty ())
  $decl c13 $call T.expect (r, "filter", $call eq ($call show ($call xs.filter (even), ""), "02468"))
  $decl c14 $call T.expect (r, "any", $call xs.any ($func ($decl n 0) $call eq (n, 9)))
  $decl c15 $call T.expect (r, "all", $call C.not ($call xs.all (even)))
  $decl c16 $call T.expect (r, "find",
                $call eq ($call C.or_else ($call xs.find ($func ($decl n 0) $call lt (4, n)), -1),
                          5))
  $decl c17 $call T.expect (r, "find nothing",
                $call C.is_none ($call xs.find ($func ($decl n 0) $call lt (99, n))))
  $decl y2  $call ($call ($call ints.empty ()).push (3)).push (1)
  $decl ys  $call ($call ($call y2.push (4)).push (1)).push (5)
  $decl c18 $call T.expect (r, "sort_by", $call eq ($call show ($call ys.sort_by (less), ""), "11345"))
  // Smaller than `big`: the runtime never frees (BOOTSTRAP §3), and a sort allocates
  // log₂ n lists of every length — a million elements came to 1.3 GB.
  $decl mid $call ($call upto0 (50000)).reverse ()
  $decl c19 $call T.expect (r, "sort_by a big list",
                $call eq ($call ($call mid.sort_by (less)).nth (12345), 12345))
  $decl ps  $call ($call ($call ($call ($call prs.empty ()).push ($call mk (1, "d"))).push (
                $call mk (2, "c"))).push ($call mk (1, "b"))).push ($call mk (2, "a"))
  $decl c20 $call T.expect (r, "sort_by is stable",
                $call eq ($call seconds ($call ps.sort_by (by_k), ""), "bdac"))
  $decl arr $call array (4, 0)
  $decl w   $set ($call at (arr, 2)) 7
  $decl c21 $call T.expect (r, "from_array",
                $call eq ($call show ($call ints.from_array (arr), ""), "0070"))
  $decl e   $call ints.empty ()
  $decl c22 $call T.expect (r, "is_empty",
                $call C.and ($call e.is_empty (), $call C.not ($call xs.is_empty ())))
  $decl c23 $call T.expect (r, "first", $call eq ($call C.or_else ($call xs.first (), -1), 0))
  $decl c24 $call T.expect (r, "first of an empty list is none", $call C.is_none ($call e.first ()))
  $decl c25 $call T.expect (r, "the empty list's rest is empty", $call ($call e.rest ()).is_empty ())
  $decl c26 $call T.expect (r, "the cells, matched", $call eq ($call second (xs), 1))
  $decl c27 $call T.expect (r, "of the cells", $call eq ($call ($call ints.of (xs.cells)).length (), 10))
  $decl ss  $call ($call ($call strs.empty ()).push ("b")).push ("a")
  $decl c28 $call T.expect (r, "another element type", $call eq ($call ss.head (), "a"))
  $decl ret $call T.finish (r)
}.ret
