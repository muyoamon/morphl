// std/list's tests, as inline checks run by `std/test`: `mplc std/list_test.mpl -L . -o …`
// from the repository root. A failure is reported on stderr and aborts; `main` answers how
// many passed, which `zig build test-std` compares.

$decl C $import "std/core"
$decl L $import "std/list"
$decl T $import "std/test"

$decl ints $specialize L.list 0
$decl strs $specialize L.list ""

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

// A type with its own equality and order (`std/core`'s prototypes), by key alone.
$decl ieq eq
$decl ilt lt
$decl kv $func ($decl k 0, $decl tag "") {
  $decl p   { $decl key k  $decl name tag
    $prop eq $func ($decl o p) $call ieq (p.key, o.key)
    $prop lt $func ($decl o p) $call ilt (p.key, o.key) }
  $decl ret p
}.ret
$decl kv0  $call kv (0, "")
$decl kvs  $specialize L.list kv0
$decl ord  $specialize L.ord_list kv0
$decl names $func ($decl xs kvs.node)
  $call strs.fold ($call kvs.map (xs, $func ($decl p kv0) p.name), "",
                   $func ($decl a "", $decl s "") $call concat (a, s))
$decl some_key $func ($decl o $union (none, { $prop tag "some"  $decl v kv0 })) $match o (
  $case {$prop tag "some"} o.v.key,
  $case o -1
)

$decl main $func () {
  $decl r   $call T.results ()
  $decl ks  $call kvs.cons ($call kv (3, "c"), $call kvs.cons ($call kv (1, "a"),
                $call kvs.cons ($call kv (3, "d"), $call kvs.cons ($call kv (2, "b"), kvs.nil))))
  $decl b1  $call T.expect (r, "contains, by the element's eq", $call kvs.contains (ks, $call kv (2, "")))
  $decl b2  $call T.expect (r, "...and not", $call C.not ($call kvs.contains (ks, $call kv (9, ""))))
  $decl b3  $call T.expect (r, "index_of",
                $call eq ($call C.or_else ($call kvs.index_of (ks, $call kv (3, "x")), -1), 0))
  $decl b4  $call T.expect (r, "...of an absent one is none",
                $call C.is_none ($call kvs.index_of (ks, $call kv (7, ""))))
  $decl b5  $call T.expect (r, "sort by the element's lt, stable", $call eq ($call names ($call ord.sort (ks)), "abcd"))
  $decl b6  $call T.expect (r, "is_sorted", $call C.and ($call ord.is_sorted ($call ord.sort (ks)),
                                                         $call C.not ($call ord.is_sorted (ks))))
  $decl b7  $call T.expect (r, "max_of and min_of",
                $call C.and ($call eq ($call some_key ($call ord.max_of (ks)), 3),
                             $call eq ($call some_key ($call ord.min_of (ks)), 1)))
  $decl b8  $call T.expect (r, "...of no elements is none", $call C.is_none ($call ord.max_of (kvs.node)))
  $decl xs  $call upto (10, ints.nil)
  $decl big $call upto (1000000, ints.nil)
  $decl c1  $call T.expect (r, "length", $call eq ($call ints.length (xs, 0), 10))
  $decl c2  $call T.expect (r, "a million is a loop",
                $call eq ($call ints.length (big, 0), 1000000))
  $decl c3  $call T.expect (r, "fold", $call eq ($call sum (xs), 45))
  $decl c4  $call T.expect (r, "map to another type", $call eq ($call show (xs), "0123456789"))
  $decl c5  $call T.expect (r, "reverse",
                $call eq ($call show ($call ints.reverse (xs, ints.nil)), "9876543210"))
  $decl c6  $call T.expect (r, "nth", $call eq ($call ints.nth (xs, 7), 7))
  $decl c7  $call T.expect (r, "append",
                $call eq ($call show ($call ints.append ($call upto (3, ints.nil),
                                       $call upto (2, ints.nil))), "01201"))
  $decl c8  $call T.expect (r, "take",
                $call eq ($call show ($call ints.take (xs, 3, ints.nil)), "012"))
  $decl c9  $call T.expect (r, "take past the end",
                $call eq ($call ints.length ($call ints.take (xs, 99, ints.nil), 0), 10))
  $decl c10 $call T.expect (r, "drop", $call eq ($call show ($call ints.drop (xs, 7)), "789"))
  $decl c11 $call T.expect (r, "filter",
                $call eq ($call show ($call ints.filter (xs, even, ints.nil)), "02468"))
  $decl c12 $call T.expect (r, "any", $call ints.any (xs, $func ($decl n 0) $call eq (n, 9)))
  $decl c13 $call T.expect (r, "all", $call C.not ($call ints.all (xs, even)))
  $decl c14 $call T.expect (r, "find",
                $call eq ($call C.or_else ($call ints.find (xs, $func ($decl n 0)
                                       $call lt (4, n)), -1), 5))
  $decl c15 $call T.expect (r, "find nothing",
                $call C.is_none ($call ints.find (xs, $func ($decl n 0)
                                       $call lt (99, n))))
  $decl ys  $call ints.cons (5, $call ints.cons (1, $call ints.cons (4, $call ints.cons (1,
                $call ints.cons (3, ints.nil)))))
  $decl c16 $call T.expect (r, "sort_by",
                $call eq ($call show ($call ints.sort_by (ys, less)), "11345"))
  // Smaller than `big`: the runtime never frees (BOOTSTRAP §3), and a sort allocates
  // log₂ n lists of every length — a million elements came to 1.3 GB.
  $decl mid $call upto (50000, ints.nil)
  $decl c17 $call T.expect (r, "sort_by a big list", $call eq ($call ints.nth ($call ints.sort_by (
                $call ints.reverse (mid, ints.nil), less), 12345), 12345))
  $decl ps  $call prs.cons ($call mk (2, "a"), $call prs.cons ($call mk (1, "b"),
                $call prs.cons ($call mk (2, "c"), $call prs.cons ($call mk (1, "d"), prs.nil))))
  $decl c18 $call T.expect (r, "sort_by is stable",
                $call eq ($call seconds ($call prs.sort_by (ps, by_k)), "bdac"))
  $decl arr $call array (4, 0)
  $decl w   $set ($call at (arr, 2)) 7
  $decl c19 $call T.expect (r, "from_array",
                $call eq ($call show ($call ints.from_array (arr)), "0070"))
  $decl c20 $call T.expect (r, "is_nil",
                $call C.and ($call ints.is_nil (ints.nil), $call C.not ($call ints.is_nil (xs))))
  $decl ret $call T.finish (r)
}.ret
