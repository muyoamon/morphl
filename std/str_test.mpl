// std/str's tests, as inline checks run by `std/test`: `mplc std/str_test.mpl -L . -o …`
// from the repository root. A failure is reported on stderr and aborts; `main` answers how
// many passed, which `zig build test-std` compares.

$decl C $import "std/core"
$decl L $import "std/list"
$decl Q $import "std/seq"
$decl S $import "std/str"
$decl T $import "std/test"

$decl strs $specialize L.list ""
$decl ints $specialize L.list 0

// `n` writes of "ab", to a builder.
$decl fill $func ($decl b ($call S.builder ()), $decl n 0)
  $if ($call lt (0, n)) ($do ($call b.write ("ab")) ($call fill (b, $call sub (n, 1)))) ()

// The pieces of a split, with `|` between, so an empty piece shows.
$decl bars $func ($decl xs ($call strs.empty ())) $call S.join (xs, "|")

$decl at_or $func ($decl o $union (none, { $prop tag "some"  $decl v 0 })) $call C.or_else (o, -1)

// Each code point encoded again, which must give back the string.
$decl encode $func ($decl b ($call S.builder ()), $decl cs ($call S.codes ("", 0))) {
  $decl w   $call Q.for_each (cs, $func ($decl c 0)
                $call b.write ($call C.or_else ($call from_code (c), "?")))
  $decl ret $call b.build ()
}.ret

$decl main $func () {
  $decl r   $call T.results ()
  $decl b   $call S.builder ()
  $decl w1  $call b.write ("hello")
  $decl w2  $call b.write (", ")
  $decl w3  $call b.line ("world")
  $decl c1  $call T.expect (r, "builder", $call eq ($call b.build (), "hello, world\n"))
  $decl c2  $call T.expect (r, "...counts its bytes", $call eq ($call b.bytes (), 13))
  $decl c3  $call T.expect (r, "...builds again the same", $call eq ($call b.build (), "hello, world\n"))
  $decl w4  $call b.write ("!")
  $decl c4  $call T.expect (r, "...and carries on", $call eq ($call b.build (), "hello, world\n!"))
  $decl big $call S.builder ()
  $decl f   $call fill (big, 100000)
  $decl c5  $call T.expect (r, "many writes", $call eq ($call len ($call big.build ()), 200000))
  $decl xs  $call ($call ($call ($call strs.empty ()).push ("c")).push ("b")).push ("a")
  $decl c6  $call T.expect (r, "concat_all", $call eq ($call S.concat_all (xs), "abc"))
  $decl c7  $call T.expect (r, "join", $call eq ($call S.join (xs, ", "), "a, b, c"))
  $decl c8  $call T.expect (r, "join of nothing", $call eq ($call S.join ($call strs.empty (), ","), ""))
  $decl c9  $call T.expect (r, "split", $call eq ($call bars ($call S.split ("a,,b", ",")), "a||b"))
  $decl c10 $call T.expect (r, "split at the ends",
                $call eq ($call bars ($call S.split (",a,", ",")), "|a|"))
  $decl c11 $call T.expect (r, "split without the separator",
                $call eq ($call ($call S.split ("abc", "::")).length (), 1))
  $decl c12 $call T.expect (r, "split by a longer separator",
                $call eq ($call bars ($call S.split ("a::b::c", "::")), "a|b|c"))
  $decl c13 $call T.expect (r, "join inverts split",
                $call eq ($call S.join ($call S.split ("x, y, z", ", "), ", "), "x, y, z"))
  $decl c14 $call T.expect (r, "find", $call eq ($call at_or ($call S.find ("banana", "an", 0)), 1))
  $decl c15 $call T.expect (r, "find from", $call eq ($call at_or ($call S.find ("banana", "an", 2)), 3))
  $decl c16 $call T.expect (r, "find nothing", $call C.is_none ($call S.find ("banana", "x", 0)))
  $decl c17 $call T.expect (r, "contains", $call C.and ($call S.contains ("banana", "nan"),
                                                         $call C.not ($call S.contains ("ban", "nan"))))
  $decl c18 $call T.expect (r, "starts_with",
                $call C.and ($call S.starts_with ("prefix", "pre"),
                             $call C.not ($call S.starts_with ("p", "pre"))))
  $decl c19 $call T.expect (r, "ends_with", $call C.and ($call S.ends_with ("suffix", "fix"),
                                                         $call C.not ($call S.ends_with ("suffix", "suf"))))
  $decl c20 $call T.expect (r, "trim", $call eq ($call S.trim (" \t a b \u{d}\n"), "a b"))
  $decl c21 $call T.expect (r, "trim_start and trim_end",
                $call C.and ($call eq ($call S.trim_start ("  x "), "x "),
                             $call eq ($call S.trim_end ("  x "), "  x")))
  $decl c22 $call T.expect (r, "trim of white space alone", $call eq ($call S.trim (" \n "), ""))
  $decl c23 $call T.expect (r, "repeat", $call eq ($call S.repeat ("ab", 5), "ababababab"))
  $decl c24 $call T.expect (r, "repeat none", $call eq ($call S.repeat ("ab", 0), ""))
  // One code point of each width: 1, 2, 3 and 4 bytes.
  $decl u   "aé€😀"
  $decl cs  $call Q.to_list ($call S.codes (u, 0), $call ints.empty ())
  $decl c25 $call T.expect (r, "codes",
                $call C.and ($call C.and ($call eq ($call cs.nth (0), 97),
                                         $call eq ($call cs.nth (1), 233)),
                             $call C.and ($call eq ($call cs.nth (2), 8364),
                                         $call eq ($call cs.nth (3), 128512))))
  $decl c26 $call T.expect (r, "...counted", $call eq ($call Q.count ($call S.codes (u, 0), 0), 4))
  $decl c27 $call T.expect (r, "...encoded back", $call eq ($call encode ($call S.builder (),
                $call S.codes (u, 0)), u))
  $decl c28 $call T.expect (r, "codes of nothing", $call ($call S.codes ("", 0)).is_empty ())
  $decl ret $call T.finish (r)
}.ret
