// std/seq's tests, as inline checks run by `std/test`: `mplc std/seq_test.mpl -L . -o …`
// from the repository root. A failure is reported on stderr and aborts; `main` answers how
// many passed, which `zig build test-std` compares.

$decl C $import "std/core"
$decl L $import "std/list"
$decl Q $import "std/seq"
$decl T $import "std/test"

$decl ints $specialize L.list 0
$decl strs $specialize L.list ""

$decl upto $func ($decl n 0, $decl acc ($call ints.empty ()))
  $if ($call lt (0, n)) ($call upto ($call sub (n, 1), $call acc.push ($call sub (n, 1)))) acc
$decl cat  $func ($decl xs ($call strs.empty ()))
  $call Q.fold (xs, "", $func ($decl a "", $decl s "") $call concat (a, s))
$decl show $func ($decl xs ($call ints.empty ()))
  $call cat ($call Q.map (xs, $func ($decl n 0) $call int_to_str (n)))
$decl even $func ($decl n 0) $call eq ($call mod (n, 2), 0)

// A sequence that is not a list: `n`, `n-1`, …, 1, with nothing stored but the count.
$decl down $func ($decl n 0) {
  $decl w   {
    $decl k n
    $prop is_empty $func () $call eq (w.k, 0)
    $prop head     $func () w.k
    $prop rest     $func () $call down ($call sub (w.k, 1))
  }
  $decl ret w
}.ret

// `sized_of` as a bound: anything with a `length`.
$decl size $template ($decl S $traitsof ($specialize Q.sized_of S)) $func ($decl xs S)
  $call xs.length ()

// A type with its own equality and order (`std/core`'s prototypes), by key alone.
$decl ieq eq
$decl ilt lt
$decl kv $func ($decl k 0, $decl tag "") {
  $decl p   { $decl key k  $decl name tag
    $prop eq $func ($decl o p) $call ieq (p.key, o.key)
    $prop lt $func ($decl o p) $call ilt (p.key, o.key) }
  $decl ret p
}.ret
$decl kv0   $call kv (0, "")
$decl kvs   $specialize L.list kv0
$decl names $func ($decl xs ($call kvs.empty ()))
  $call cat ($call Q.map (xs, $func ($decl p kv0) p.name))
$decl some_key $func ($decl o $union (none, { $prop tag "some"  $decl v kv0 })) $match o (
  $case {$prop tag "some"} o.v.key,
  $case o -1
)

$decl main $func () {
  $decl r   $call T.results ()
  $decl xs  $call upto (10, $call ints.empty ())
  $decl big $call upto (1000000, $call ints.empty ())
  $decl c1  $call T.expect (r, "count", $call eq ($call Q.count (xs, 0), 10))
  $decl c2  $call T.expect (r, "a million is a loop",
                $call eq ($call Q.count (big, 0), 1000000))
  $decl c3  $call T.expect (r, "fold",
                $call eq ($call Q.fold (xs, 0, $func ($decl a 0, $decl x 0) $call add (a, x)), 45))
  $decl c4  $call T.expect (r, "map to another type", $call eq ($call show (xs), "0123456789"))
  $decl seen $mut $alloc 0
  $decl fe  $call Q.for_each (xs, $func ($decl x 0) $set seen ($call add ($call C.ival (seen), x)))
  $decl c5  $call T.expect (r, "for_each", $call eq ($call C.ival (seen), 45))
  $decl c6  $call T.expect (r, "any", $call Q.any (xs, $func ($decl n 0) $call eq (n, 9)))
  $decl c7  $call T.expect (r, "all", $call C.not ($call Q.all (xs, even)))
  $decl c8  $call T.expect (r, "find",
                $call eq ($call C.or_else ($call Q.find (xs, $func ($decl n 0) $call lt (4, n)),
                                           -1), 5))
  $decl c9  $call T.expect (r, "find nothing",
                $call C.is_none ($call Q.find (xs, $func ($decl n 0) $call lt (99, n))))
  $decl c10 $call T.expect (r, "to_list after what is there",
                $call eq ($call show ($call Q.to_list ($call upto (3, $call ints.empty ()),
                          $call ($call ints.empty ()).push (7))), "7012"))
  $decl d5  $call down (5)
  $decl c11 $call T.expect (r, "a sequence that is not a list",
                $call eq ($call Q.count (d5, 0), 5))
  $decl c12 $call T.expect (r, "...mapped to a list", $call eq ($call show ($call Q.map (d5,
                $func ($decl n 0) $call mul (n, 2))), "108642"))
  $decl c13 $call T.expect (r, "...to_list", $call eq ($call show ($call Q.to_list (d5,
                $call ints.empty ())), "54321"))
  $decl c14 $call T.expect (r, "sized_of", $call eq ($call size (xs), 10))
  $decl ks  $call ($call ($call ($call ($call kvs.empty ()).push ($call kv (2, "b"))).push (
                $call kv (3, "d"))).push ($call kv (1, "a"))).push ($call kv (3, "c"))
  $decl c15 $call T.expect (r, "contains, by the element's eq",
                $call Q.contains (ks, $call kv (2, "")))
  $decl c16 $call T.expect (r, "...and not", $call C.not ($call Q.contains (ks, $call kv (9, ""))))
  $decl c17 $call T.expect (r, "index_of",
                $call eq ($call C.or_else ($call Q.index_of (ks, $call kv (3, "x"), 0), -1), 0))
  $decl c18 $call T.expect (r, "...of an absent one is none",
                $call C.is_none ($call Q.index_of (ks, $call kv (7, ""), 0)))
  $decl c19 $call T.expect (r, "sort by the element's lt, stable",
                $call eq ($call names ($call Q.sort (ks)), "abcd"))
  $decl c20 $call T.expect (r, "is_sorted", $call C.and ($call Q.is_sorted ($call Q.sort (ks)),
                                                          $call C.not ($call Q.is_sorted (ks))))
  $decl c21 $call T.expect (r, "max_of and min_of",
                $call C.and ($call eq ($call some_key ($call Q.max_of (ks)), 3),
                             $call eq ($call some_key ($call Q.min_of (ks)), 1)))
  $decl c22 $call T.expect (r, "...of no elements is none",
                $call C.is_none ($call Q.max_of ($call kvs.empty ())))
  $decl c23 $call T.expect (r, "sorting nothing", $call ($call Q.sort ($call kvs.empty ())).is_empty ())
  $decl ret $call T.finish (r)
}.ret
