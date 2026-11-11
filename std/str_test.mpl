// std/str's tests, as inline checks run by `std/test`: `mplc std/str_test.mpl -L . -o …`
// from the repository root. A failure is reported on stderr and aborts; `main` answers how
// many passed, which `zig build test-std` compares.

$decl C $import "std/core"
$decl L $import "std/list"
$decl Q $import "std/seq"
$decl M $import "std/mem"
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

// The pieces of a view's split, with `|` between, written into `t`.
$decl bar_views $func ($decl t S.proto_text,
                       $decl xs ($call S.split ($call S.proto_text.view (), ",")),
                       $decl first C.bool)
  $if ($call xs.is_empty ()) ()
      ($do ($if first () ($call t.write ("|")))
           ($do ($call t.write ($call xs.head ())) ($call bar_views (t, $call xs.rest (), false))))

// `n` writes of "ab", to a text.
$decl fill_text $func ($decl t S.proto_text, $decl n 0)
  $if ($call lt (0, n)) ($do ($call t.write ("ab")) ($call fill_text (t, $call sub (n, 1)))) ()

// A text's bytes copied out, which outlive it.
$decl copied $func () {
  $decl t   $call S.text ()
  $decl w   $call t.write ("kept")
  $decl ret $call S.copy_out ($call t.view ())
}.ret

// A heap text in an arena, written and read, then released with the arena, which runs
// the text's deferral. Its buffer is the root's, freed by that deferral.
$decl in_arena $func () {
  $decl allocator $call M.arena (4096)
  $decl h         $alloc $call S.text ()
  $decl w         $call fill_text (h, 1000)
  $decl n         $call h.size ()
  $decl done      $call allocator.release ()
  $decl ret       n
}.ret

// A frame text drawing from an arena: what the arena handed out, once the text has grown
// past 16 bytes twice. The text ends before the arena does.
$decl arena_bytes $func ($decl a M.proto_arena) {
  $decl t   $call S.text (a)
  $decl w   $call fill_text (t, 20)
  $decl ok  $call S.eq ($call S.slice ($call t.view (), 38, 40), "ab")
  $decl ret $if ok ($call a.used ()) -1
}.ret
$decl from_arena $func () {
  $decl a   $call M.arena (65536)
  $decl n   $call arena_bytes (a)
  $decl r   $call a.release ()
  $decl ret n
}.ret

// A heap text in an arena that it draws from too, released with it: the deferral gives the
// buffer back to the arena, before the arena's memory goes. The text keeps a reference to
// its allocator, so a heap text's must be heap storage too (§5.3a): the arena is `$alloc`ed.
$decl all_arena $func () {
  $decl ar   $alloc $call M.arena (65536)
  $decl n    {
    $decl allocator ar
    $decl h         $alloc $call S.text (ar)
    $decl w         $call fill_text (h, 3000)
    $decl ret2      $call S.len ($call h.view ())
  }.ret2
  $decl done $call ar.release ()
  $decl f    $free ar
  $decl ret  n
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
  $decl c29 $call T.expect (r, "compare, bytewise then shorter first",
                $call C.and ($call eq ($call S.compare ("ab", "abc"), -1),
                             $call C.and ($call eq ($call S.compare ("b", "abc"), 1),
                                         $call eq ($call S.compare ("x", "x"), 0))))
  $decl c30 $call T.expect (r, "less", $call C.and ($call S.less ("a", "b"),
                                                    $call C.not ($call S.less ("b", "b"))))
  // `concat_all`'s edges: no pieces, one (answered as itself), and many in order.
  $decl one $call ($call strs.empty ()).push ("é")
  $decl c31 $call T.expect (r, "concat_all of nothing",
                $call eq ($call S.concat_all ($call strs.empty ()), ""))
  $decl c32 $call T.expect (r, "concat_all and join of one",
                $call C.and ($call eq ($call S.concat_all (one), "é"),
                             $call eq ($call S.join (one, ","), "é")))
  $decl c33 $call T.expect (r, "join of many, in order",
                $call eq ($call S.join ($call S.split ("1 2 3 4 5 6 7 8 9", " "), ""), "123456789"))
  $decl c34 $call T.expect (r, "an empty builder builds nothing",
                $call eq ($call ($call S.builder ()).build (), ""))
  // Text: growth, a view across growth, a text written into itself.
  $decl t   $call S.text ()
  $decl f2  $call fill_text (t, 100000)
  $decl c35 $call T.expect (r, "text grows", $call eq ($call t.size (), 200000))
  $decl t2  $call S.text ()
  $decl w5  $call t2.write ("hello")
  $decl v   $call t2.view ()
  $decl f3  $call fill_text (t2, 5000)
  $decl c36 $call T.expect (r, "...and a view made before still reads",
                $call S.eq (v, "hello"))
  $decl t3  $call S.text ()
  $decl w6  $call t3.write ("abc")
  $decl w7  $call t3.write ($call t3.view ())
  $decl w8  $call t3.write ($call t3.view ())
  $decl c37 $call T.expect (r, "a text written into itself", $call S.eq ($call t3.view (), "abcabcabcabc"))
  // Views: the root's operations by the first operand's type.
  $decl t4  $call S.text ()
  $decl w9  $call t4.line ("héllo")
  $decl v4  $call t4.view ()
  $decl c38 $call T.expect (r, "a view's len and byte",
                $call C.and ($call eq ($call S.len (v4), 7), $call eq ($call S.byte (v4, 6), 10)))
  $decl c39 $call T.expect (r, "a view's slice",
                $call C.and ($call S.eq ($call S.slice (v4, 1, 3), "é"),
                             $call S.eq ($call S.slice ($call S.slice (v4, 1, 6), 2, 4), "ll")))
  $decl c40 $call T.expect (r, "a view's find and its relatives",
                $call C.and ($call C.and ($call eq ($call at_or ($call S.find (v4, "l", 4)), 4),
                                         $call S.starts_with (v4, "hé")),
                             $call C.and ($call S.ends_with (v4, "o\n"),
                                         $call C.not ($call S.contains (v4, "x")))))
  $decl c41 $call T.expect (r, "two views equal",
                $call S.eq ($call S.slice (v4, 3, 4), $call S.slice (v4, 4, 5)))
  $decl t5  $call S.text ()
  $decl w10 $call t5.code (233)
  $decl w11 $call t5.code (128512)
  $decl w12 $call t5.code (55296)
  $decl w13 $call t5.code (36)
  $decl c42 $call T.expect (r, "code points written", $call S.eq ($call t5.view (), "é😀\u{fffd}$"))
  // Clear and truncate: the text goes on, from where it was cut.
  $decl t6  $call S.text ()
  $decl w14 $call t6.write ("aéb")
  $decl k1  $call t6.truncate (3)
  $decl w15 $call t6.write ("!")
  $decl c43 $call T.expect (r, "truncate at a code point", $call S.eq ($call t6.view (), "aé!"))
  $decl k2  $call t6.clear ()
  $decl w16 $call t6.write ("new")
  $decl c44 $call T.expect (r, "clear", $call C.and ($call eq ($call t6.size (), 3),
                                                     $call S.eq ($call t6.view (), "new")))
  $decl c45 $call T.expect (r, "copy_out outlives its text", $call eq ($call copied (), "kept"))
  $decl h   $alloc $call S.text ()
  $decl w17 $call fill_text (h, 3)
  $decl c46 $call T.expect (r, "a heap text", $call S.eq ($call h.view (), "ababab"))
  $decl fr  $free h
  $decl c47 $call T.expect (r, "a heap text in an arena", $call eq ($call in_arena (), 2000))
  // 32 for the header, then buffers of 16, 32 and 64 as it grows: an arena gives nothing back.
  $decl c54 $call T.expect (r, "a text drawing from an arena", $call eq ($call from_arena (), 112))
  $decl c55 $call T.expect (r, "...heap, and released with it", $call eq ($call all_arena (), 6000))
  $decl c48 $call T.expect (r, "an empty text", $call S.eq ($call ($call S.text ()).view (), ""))
  // Taking a view apart, into views of the same text.
  $decl t7  $call S.text ()
  $decl w18 $call t7.write (",a,,bé,")
  $decl o7  $call S.text ()
  $decl b7  $call bar_views (o7, $call S.split ($call t7.view (), ","), true)
  $decl c49 $call T.expect (r, "a view's split", $call S.eq ($call o7.view (), "|a||bé|"))
  $decl o8  $call S.text ()
  $decl b8  $call bar_views (o8, $call S.split ($call S.slice ($call t7.view (), 1, 2), ","), true)
  $decl c50 $call T.expect (r, "...without the separator", $call S.eq ($call o8.view (), "a"))
  $decl t8  $call S.text ()
  $decl w19 $call t8.write (" \t a b \n")
  $decl c51 $call T.expect (r, "a view's trim",
                $call C.and ($call S.eq ($call S.trim ($call t8.view ()), "a b"),
                $call C.and ($call S.eq ($call S.trim_start ($call t8.view ()), "a b \n"),
                             $call S.eq ($call S.trim_end ($call t8.view ()), " \t a b"))))
  $decl c52 $call T.expect (r, "...of white space alone",
                $call eq ($call S.len ($call S.trim ($call S.slice ($call t8.view (), 0, 3))), 0))
  $decl t9  $call S.text ()
  $decl w20 $call t9.write (u)
  $decl c53 $call T.expect (r, "a view's codes",
                $call C.and ($call eq ($call Q.count ($call S.codes ($call t9.view (), 0), 0), 4),
                             $call eq ($call ($call ($call S.codes ($call t9.view (), 1)).rest ())
                                           .head (), 8364)))
  $decl ret $call T.finish (r)
}.ret
