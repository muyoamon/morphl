// std/str: building and taking apart a `Str` (STDLIB.md, D6), over §8's `concat`, `len`,
// `slice`, `byte` and `from_code`; and **text**, a growable buffer owning its bytes, with
// views of it (TEXT.md, T3–T6), at the end of this file.
//
// §3.1 makes a `Str` valid UTF-8 and its operations byte-indexed, so every index here is a
// byte offset and every search compares bytes; code points are `codes`, a sequence that
// decodes as it goes and works with `std/seq`: `$call Q.count ($call S.codes (s))`.
//
// §8's `concat` copies both operands, so appending to an accumulator is O(n²) in the pieces
// (CLAUDE.md, from `emit.mpl`'s `say`). Text is assembled in a **builder** instead, or with
// `concat_all`/`join`: the pieces are collected and joined once by §8's `concat_all`, one
// allocation of their total length (STRINGS.md).

$decl C $import "std/core"
$decl L $import "std/list"
$decl M $import "std/mem"

$decl strs $specialize L.list ""
$decl cl   strs.cell

// ---------------------------------------------------------------- joining

// §8's, named before this module's own `concat_all` shadows it (§4.1).
$decl cat_all concat_all

// The pieces go into an array of their count, which `cat_all` copies into one allocation.
$decl fill_back $func ($decl a $call array (0, ""), $decl xs strs.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $do ($set ($call at (a, i)) xs.head)
        ($call fill_back (a, $call cl.val (xs.tail), $call sub (i, 1))),
  $case xs a
)
$decl fill_fwd $func ($decl a $call array (0, ""), $decl xs strs.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $do ($set ($call at (a, i)) xs.head)
        ($call fill_fwd (a, $call cl.val (xs.tail), $call add (i, 1))),
  $case xs a
)
// The pieces newest first, joined: the array is filled from the far end, so nothing is
// reversed. One piece is itself, uncopied.
$decl join_back $func ($decl cs strs.node) $match cs (
  $case {$prop tag "cons"}
    $if ($call cl.is_nil ($call cl.val (cs.tail))) cs.head {
      $decl n    $call cl.length (cs, 0)
      $decl ret2 $call cat_all ($call fill_back ($call array (n, ""), cs, $call sub (n, 1)))
    }.ret2,
  $case cs ""
)
// The pieces in order, joined.
$decl join_fwd $func ($decl xs strs.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call cl.is_nil ($call cl.val (xs.tail))) xs.head {
      $decl n    $call cl.length (xs, 0)
      $decl ret2 $call cat_all ($call fill_fwd ($call array (n, ""), xs, 0))
    }.ret2,
  $case xs ""
)

$decl concat_all $func ($decl xs ($call strs.empty ())) $call join_fwd (xs.cells)

// `sep` between each pair, reversed in front of `acc`.
$decl sep_go $func ($decl xs strs.node, $decl sep "", $decl acc strs.node) $match xs (
  $case {$prop tag "cons"}
    $call sep_go ($call cl.val (xs.tail), sep,
        $call cl.cons (xs.head, $if ($call cl.is_nil (acc)) acc ($call cl.cons (sep, acc)))),
  $case xs acc
)
$decl join $func ($decl xs ($call strs.empty ()), $decl sep "")
  $call join_back ($call sep_go (xs.cells, sep, strs.nil))

// --------------------------------------------------------------- the builder

// The pieces design, kept for `std/json` and the language server until TEXT.md's step 6;
// new code writes a `text` (below), which owns its bytes.
//
// Text assembled piece by piece: `$call b.write (s)` and `$call b.build ()`. The pieces are
// held newest first in the builder's own cell (D9: a container that changes in place holds
// its state in `$mut $alloc` cells), and `build` joins them once, then keeps the result as
// the one piece, so building again costs nothing and adding after it carries on.
$decl builder $func () {
  $decl b   {
    $decl parts $mut $alloc strs.node
    $decl size  $mut $alloc 0
    // Not `add` or `len`: a prop is visible throughout its block (§4.10), so a member
    // of either name would shadow the intrinsic these bodies call.
    // Both answer unit, so a `show` member ending in a write conforms to `std/fmt`'s
    // `show_proto`, whose `show` answers `()`.
    $prop write $func ($decl s "") $do
      ($set b.parts ($call cl.cons (s, $call cl.val (b.parts))))
      ($do ($set b.size ($call add ($call C.ival (b.size), $call len (s)))) ())
    $prop line  $func ($decl s "") $do ($call b.write (s)) ($call b.write ("\n"))
    // The bytes written so far.
    $prop bytes $func () $call C.ival (b.size)
    $prop build $func () {
      $decl t   $call join_back ($call cl.val (b.parts))
      $decl k   $set b.parts ($call cl.cons (t, strs.nil))
      $decl ret t
    }.ret
  }
  $decl ret b
}.ret

// `s` `n` times, by doubling: log₂ n concatenations.
$decl repeat $func ($decl s "", $decl n 0)
  $if ($call lt (n, 1)) ""
      ($if ($call eq (n, 1)) s {
        $decl h    $call repeat ($call concat (s, s), $call div (n, 2))
        $decl ret2 $if ($call eq ($call mod (n, 2), 0)) h ($call concat (h, s))
      }.ret2)

// --------------------------------------------------------------- ordering

// Byte by byte, then the shorter first: -1, 0 or 1. Since §3.1 makes a `Str` UTF-8, byte
// order is code-point order. The root block orders numbers only, so this is what a map with
// `Str` keys sorts by.
$decl compare_go $func ($decl a "", $decl b "", $decl i 0)
  $if ($call lt (i, $call len (a)))
      ($if ($call lt (i, $call len (b)))
           ($if ($call lt ($call byte (a, i), $call byte (b, i))) -1
           ($if ($call lt ($call byte (b, i), $call byte (a, i))) 1
                ($call compare_go (a, b, $call add (i, 1)))))
           1)
      ($if ($call lt (i, $call len (b))) -1 0)
$decl compare $func ($decl a "", $decl b "") $call compare_go (a, b, 0)
$decl less    $func ($decl a "", $decl b "") $call lt ($call compare (a, b), 0)

// ------------------------------------------------------------- searching

$decl str_starts_with $func ($decl s "", $decl p "")
  $if ($call lt ($call len (s), $call len (p))) false
      ($call eq ($call slice (s, 0, $call len (p)), p))
$decl str_ends_with $func ($decl s "", $decl p "")
  $if ($call lt ($call len (s), $call len (p))) false
      ($call eq ($call slice (s, $call sub ($call len (s), $call len (p)), $call len (s)), p))

// Whether `p` occurs at byte `i` of `s`.
$decl at_is $func ($decl s "", $decl p "", $decl i 0)
  $if ($call lt ($call len (s), $call add (i, $call len (p)))) false
      ($call eq ($call slice (s, i, $call add (i, $call len (p))), p))

// The first byte offset at or after `from` where `p` occurs, as an option. An empty `p`
// occurs everywhere, so it is found at `from`.
$decl str_find $func ($decl s "", $decl p "", $decl from 0)
  $if ($call lt ($call sub ($call len (s), $call len (p)), from)) none
      ($if ($call at_is (s, p, from)) ($call C.some (from))
           ($call str_find (s, p, $call add (from, 1))))
$decl str_contains $func ($decl s "", $decl p "") $call C.is_some ($call str_find (s, p, 0))

// ------------------------------------------------------------ taking apart

// The pieces between occurrences of `sep`, in order: `split ("a,,b", ",")` is `a`, ``, `b`.
// An empty `sep` would occur everywhere and is a bug (§4.15).
$decl split_go $func ($decl s "", $decl sep "", $decl start 0, $decl i 0, $decl acc strs.node)
  $if ($call lt ($call sub ($call len (s), $call len (sep)), i))
      ($call cl.reverse ($call cl.cons ($call slice (s, start, $call len (s)), acc), strs.nil))
      ($if ($call at_is (s, sep, i))
           ($call split_go (s, sep, $call add (i, $call len (sep)), $call add (i, $call len (sep)),
                $call cl.cons ($call slice (s, start, i), acc)))
           ($call split_go (s, sep, start, $call add (i, 1), acc)))
$decl str_split $func ($decl s "", $decl sep "")
  $if ($call eq ($call len (sep), 0)) ($call panic ("split: an empty separator"))
      ($call strs.of ($call split_go (s, sep, 0, 0, strs.nil)))

// ASCII white space: space, tab, newline, carriage return.
$decl is_space $func ($decl b 0)
  $if ($call eq (b, 32)) true ($if ($call eq (b, 9)) true
      ($if ($call eq (b, 10)) true ($call eq (b, 13))))
$decl first_non $func ($decl s "", $decl i 0)
  $if ($call lt (i, $call len (s)))
      ($if ($call is_space ($call byte (s, i))) ($call first_non (s, $call add (i, 1))) i) i
$decl last_non $func ($decl s "", $decl j 0)
  $if ($call lt (0, j))
      ($if ($call is_space ($call byte (s, $call sub (j, 1))))
           ($call last_non (s, $call sub (j, 1))) j)
      j
$decl str_trim_start $func ($decl s "") $call slice (s, $call first_non (s, 0), $call len (s))
$decl str_trim_end   $func ($decl s "") $call slice (s, 0, $call last_non (s, $call len (s)))
$decl str_trim       $func ($decl s "") $call str_trim_end ($call str_trim_start (s))

// -------------------------------------------------------------- code points

// The bytes the code point starting with `b` takes, which §3.1's validity makes exact.
$decl width $func ($decl b 0)
  $if ($call lt (b, 128)) 1 ($if ($call lt (b, 224)) 2 ($if ($call lt (b, 240)) 3 4))
$decl cont $func ($decl s "", $decl i 0) $call band ($call byte (s, i), 63)

// The code point at byte `i`, decoding as `from_code` encodes.
$decl code_at $func ($decl s "", $decl i 0) {
  $decl b   $call byte (s, i)
  $decl w   $call width (b)
  $decl ret $if ($call eq (w, 1)) b
      ($if ($call eq (w, 2))
           ($call bor ($call shl ($call band (b, 31), 6), $call cont (s, $call add (i, 1))))
      ($if ($call eq (w, 3))
           ($call bor ($call bor ($call shl ($call band (b, 15), 12),
                                  $call shl ($call cont (s, $call add (i, 1)), 6)),
                      $call cont (s, $call add (i, 2))))
           ($call bor ($call bor ($call shl ($call band (b, 7), 18),
                                  $call shl ($call cont (s, $call add (i, 1)), 12)),
                      $call bor ($call shl ($call cont (s, $call add (i, 2)), 6),
                                 $call cont (s, $call add (i, 3)))))))
}.ret

// The code points of `s` from byte `i`, as a sequence (`std/seq`'s `seq_of`): decoded as it
// is walked, and nothing stored but the string and the offset.
$decl str_codes $func ($decl s "", $decl i 0) {
  $decl w   {
    $decl text s
    $decl at   i
    $prop is_empty $func () $call C.not ($call lt (w.at, $call len (w.text)))
    $prop head     $func () $call code_at (w.text, w.at)
    $prop rest     $func ()
      $call str_codes (w.text, $call add (w.at, $call width ($call byte (w.text, w.at))))
  }
  $decl ret w
}.ret

// ------------------------------------------------------------------- text
//
// A text is a growable buffer, the builder and the string at once (TEXT.md, T3–T6):
//
//   $decl t $call S.text ()            // frame text: its deferral frees the buffer
//   $call t.write ("hello, ")
//   $call t.write (name)               // a `Str` or a view, copied in at once
//   $call I.print_line ($call t.view ())
//
// `S.text` is a constructor (§5.3a), so `$decl t $call S.text ()` is frame storage of the
// scope it stands in, and `$alloc $call S.text ()` a heap text whose deferral is its
// allocator's: run by `$free`, or when an arena releases it. The buffer is from the
// allocator the text is given, the root's unless it is given one.
//
// A **view** is `{of, at, n, gen}`: the text, an offset, a length and the generation it was
// made under. It holds the text as a reference, so §5.3a keeps a view of a frame text in that
// frame. A text only grows, and a view holds an offset rather than an address, so a view stays
// right across growth; `clear` and `truncate` add one to the generation, and reading a view
// made before panics (T6). `raw_str (v)` is the view as a `Str`, valid until the text next
// grows or ends: for the length of a platform call, nothing longer (T5).

$decl c_memcpy $extern "void *memcpy(void *, const void *, size_t)"
  $func ($decl d 0, $decl s 0, $decl n 0) 0

// C's `memcpy` wants an address even for no bytes, and an empty text has none.
$decl copy $func ($decl d 0, $decl s 0, $decl n 0)
  $if ($call lt (0, n)) ($call c_memcpy (d, s, n)) 0

// The state is four cells of the text's own — the buffer's address, its capacity, the bytes
// used, the generation — built where the text is (§5.3a's composition). Everything here
// takes it as `proto_st`, the prefix every text has (§5.1): sibling props are typed against
// each other's placeholders, so it has to be written before `text` is, and one type then
// serves every text. Its buffer is from the text's allocator, `al`, an `M.any`.
$decl proto_st $const $new {
  $decl p    $mut $new 0
  $decl cap  $mut $new 0
  $decl used $mut $new 0
  $decl gen  $mut $new 0
}

// Byte `i` of the memory at `a`, and a byte stored there.
$decl peek $func ($decl a 0, $decl i 0)
  $call $primitives.of_u8 ($call $primitives.unbox ($call add (a, i), $primitives.u8))
$decl poke $func ($decl a 0, $decl i 0, $decl c 0)
  $set ($call $primitives.unbox ($call add (a, i), $primitives.u8)) ($call $primitives.to_u8 (c))

// The buffer grown to hold `need` bytes, what is there copied across and then `n` bytes from
// `p` after it, before the old one is freed — so `p` may point into the text itself, and
// `t.write (t.view ())` reads its source after growing.
$decl grow $func ($decl s proto_st, $decl al M.any, $decl need 0, $decl p 0, $decl n 0) {
  $decl u   $call C.ival (s.used)
  $decl nc  $call C.max ($call C.max ($call mul ($call C.ival (s.cap), 2), need), 16)
  $decl nb  $call al.alloc (nc)
  $decl ok  $if ($call eq (nb, 0)) ($call panic ("str: out of memory")) 0
  $decl m1  $call copy (nb, $call C.ival (s.p), u)
  $decl m2  $call copy ($call add (nb, u), p, n)
  // An empty text has had no buffer to free.
  $decl f   $if ($call eq ($call C.ival (s.cap), 0)) ()
                ($call al.free ($call C.ival (s.p), $call C.ival (s.cap)))
  $decl s0  $set s.p nb
  $decl s1  $set s.cap nc
  $decl ret ()
}.ret

// `n` bytes at `p` written at the end.
$decl put_bytes $func ($decl s proto_st, $decl al M.any, $decl p 0, $decl n 0) {
  $decl u   $call C.ival (s.used)
  $decl m   $if ($call lt ($call C.ival (s.cap), $call add (u, n)))
                ($call grow (s, al, $call add (u, n), p, n))
                ($do ($call copy ($call add ($call C.ival (s.p), u), p, n)) ())
  $decl ret $do ($set s.used ($call add (u, n))) ()
}.ret

// Code point `c` written at the end as UTF-8, or U+FFFD for one `from_code` would refuse: a
// surrogate, or past U+10FFFF.
$decl code_ok $func ($decl c 0)
  $call C.and ($call C.and ($call lt (-1, c), $call lt (c, 1114112)),
               $call C.not ($call C.and ($call lt (55295, c), $call lt (c, 57344))))
$decl put_code $func ($decl s proto_st, $decl al M.any, $decl c0 0) {
  $decl c   $if ($call code_ok (c0)) c0 65533
  $decl w   $if ($call lt (c, 128)) 1 ($if ($call lt (c, 2048)) 2 ($if ($call lt (c, 65536)) 3 4))
  $decl u   $call C.ival (s.used)
  $decl g   $if ($call lt ($call C.ival (s.cap), $call add (u, w)))
                ($call grow (s, al, $call add (u, w), 0, 0)) ()
  $decl a   $call add ($call C.ival (s.p), u)
  $decl lo  $func ($decl k 0) $call bor (128, $call band ($call shr (c, k), 63))
  $decl b   $if ($call eq (w, 1)) ($call poke (a, 0, c))
      ($if ($call eq (w, 2))
           ($do ($call poke (a, 0, $call bor (192, $call shr (c, 6))))
                ($call poke (a, 1, $call lo (0))))
      ($if ($call eq (w, 3))
           ($do ($call poke (a, 0, $call bor (224, $call shr (c, 12))))
                ($do ($call poke (a, 1, $call lo (6))) ($call poke (a, 2, $call lo (0)))))
           ($do ($call poke (a, 0, $call bor (240, $call shr (c, 18))))
                ($do ($call poke (a, 1, $call lo (12)))
                     ($do ($call poke (a, 2, $call lo (6))) ($call poke (a, 3, $call lo (0))))))))
  $decl ret $do ($set s.used ($call add (u, w))) ()
}.ret

// Whether byte `i` of the memory at `a` continues a code point rather than starting one.
$decl is_cont $func ($decl a 0, $decl i 0)
  $call C.and ($call lt (127, $call peek (a, i)), $call lt ($call peek (a, i), 192))

// The first `n` bytes kept, `n` not past the end nor inside a code point (§3.1), and the
// generation moved on.
$decl cut $func ($decl s proto_st, $decl n 0) {
  $decl u   $call C.ival (s.used)
  $decl ok  $if ($call C.or ($call lt (n, 0), $call lt (u, n)))
                ($call panic ($call concat ("str: truncate to ", $call concat ($call int_to_str (n),
                     $call concat (" of ", $call int_to_str (u))))))
                ($if ($call lt (n, u))
                     ($if ($call is_cont ($call C.ival (s.p), n))
                          ($call panic ("str: truncate inside a code point")) 0) 0)
  $decl s2  $set s.used n
  $decl ret $do ($set s.gen ($call add ($call C.ival (s.gen), 1))) ()
}.ret

// A view.
$decl view_of $func ($decl o proto_st, $decl a 0, $decl k 0, $decl g 0)
  { $decl of o  $decl at a  $decl n k  $decl gen g }
$decl proto_view $call view_of (proto_st, 0, 0, 0)

// The address of a view's first byte, or a panic when its text was cleared or truncated
// after it was made.
$decl view_addr $func ($decl v proto_view)
  $if ($call eq ($call C.ival (v.of.gen), v.gen)) ($call add ($call C.ival (v.of.p), v.at))
      ($call panic ("str: a view read after its text was cleared or truncated"))

// A `Str` as itself, and a view as a `Str` of its bytes — valid until its text next grows or
// ends, so for the length of a call and nothing longer (T5).
$decl raw_str $func ($decl s $union ("", proto_view)) $match s (
  $case "" s,
  $case {} $call $primitives.view ($call view_addr (s), s.n)
)

// A `Str` or a view written at the end of the text whose state is `st`.
$decl put $func ($decl st proto_st, $decl s $union ("", proto_view), $decl al M.any) {
  $decl r   $call raw_str (s)
  $decl ret $call put_bytes (st, al, $call $primitives.str_ptr (r), $call len (r))
}.ret
// A view of the whole of a text.
$decl whole $func ($decl s proto_st)
  $call view_of (s, 0, $call C.ival (s.used), $call C.ival (s.gen))

// `from` is the allocator its buffer comes from, the root's unless it is given one:
// `$call S.text (allocator)` with an arena bound draws from the arena. It is kept in a field,
// since a deferral may name only the block's own bindings (§4.15a), and the text holds it as
// a reference, so it must end before the allocator does.
$decl text $func ($decl from M.any) $new {
  $decl p    $mut $new 0
  $decl cap  $mut $new 0
  $decl used $mut $new 0
  $decl gen  $mut $new 0
  $decl al   from
  // The whole of the text, as written so far.
  $prop view     $func () $call whole (text)
  // A `Str` or a view, copied in; so `t.write (t.view ())` doubles it. All of these answer
  // unit, so a `show` member ending in a write conforms to `std/fmt`'s `show_proto`.
  $prop write    $func ($decl s $union ("", proto_view)) $call put (text, s, text.al)
  $prop line     $func ($decl s $union ("", proto_view))
    $do ($call put (text, s, text.al)) ($call put (text, "\n", text.al))
  $prop code     $func ($decl c 0) $call put_code (text, text.al, c)
  // The bytes written so far.
  $prop size     $func () $call C.ival (text.used)
  // Emptied, keeping the buffer; and the first `n` bytes kept. Either makes every view made
  // before stale.
  $prop clear    $func () $call cut (text, 0)
  $prop truncate $func ($decl n 0) $call cut (text, n)
  // An empty text has had no buffer to free.
  $defer $if ($call eq ($call C.ival (cap), 0)) ()
             ($call al.free ($call C.ival (p), $call C.ival (cap)))
}

// ------------------------------------------------------------------- views

// The view as a `Str` of its own, copied, which outlives the text.
$decl copy_out $func ($decl v proto_view)
  $call C.or_else ($call $primitives.str_from_ptr ($call view_addr (v), v.n), "")

$decl view_len  $func ($decl v proto_view) $do ($call view_addr (v)) v.n
$decl view_byte $func ($decl v proto_view, $decl i 0)
  $if ($call C.and ($call lt (-1, i), $call lt (i, v.n))) ($call peek ($call view_addr (v), i))
      ($call panic ($call concat ("str: byte ", $call concat ($call int_to_str (i),
           $call concat (" of a view of ", $call int_to_str (v.n))))))

// Bytes `i` to `j` of the view, a view of the same text; as §8's `slice`, `i ≤ j ≤ len` and
// neither inside a code point.
$decl view_slice $func ($decl v proto_view, $decl i 0, $decl j 0) {
  $decl a   $call view_addr (v)
  $decl bad $func ($decl k 0) $if ($call lt (k, v.n)) ($call is_cont (a, k)) false
  $decl ok  $if ($call C.or ($call C.or ($call lt (i, 0), $call lt (j, i)), $call lt (v.n, j)))
                ($call panic ($call concat ("str: slice ", $call concat ($call int_to_str (i),
                     $call concat (" to ", $call concat ($call int_to_str (j),
                     $call concat (" of a view of ", $call int_to_str (v.n))))))))
                ($if ($call C.or ($call bad (i), $call bad (j)))
                     ($call panic ("str: slice inside a code point")) 0)
  $decl ret $call view_of (v.of, $call add (v.at, i), $call sub (j, i), v.gen)
}.ret

// Each of these reads the view's bytes for the length of the call.
$decl view_eq     $func ($decl v proto_view, $decl s "") $call eq ($call raw_str (v), s)
$decl views_eq    $func ($decl v proto_view, $decl w proto_view)
  $call eq ($call raw_str (v), $call raw_str (w))
$decl view_find   $func ($decl v proto_view, $decl p "", $decl from 0)
  $call str_find ($call raw_str (v), p, from)
$decl view_starts $func ($decl v proto_view, $decl p "")
  $call str_starts_with ($call raw_str (v), p)
$decl view_ends   $func ($decl v proto_view, $decl p "") $call str_ends_with ($call raw_str (v), p)
$decl view_has    $func ($decl v proto_view, $decl p "") $call str_contains ($call raw_str (v), p)

// Trimmed: a view of the same text, without the white space at either end.
$decl view_first_non $func ($decl a 0, $decl n 0, $decl i 0)
  $if ($call lt (i, n))
      ($if ($call is_space ($call peek (a, i))) ($call view_first_non (a, n, $call add (i, 1))) i) i
$decl view_last_non $func ($decl a 0, $decl j 0)
  $if ($call lt (0, j))
      ($if ($call is_space ($call peek (a, $call sub (j, 1))))
           ($call view_last_non (a, $call sub (j, 1))) j)
      j
$decl view_trim_start $func ($decl v proto_view)
  $call view_slice (v, $call view_first_non ($call view_addr (v), v.n, 0), v.n)
$decl view_trim_end   $func ($decl v proto_view)
  $call view_slice (v, 0, $call view_last_non ($call view_addr (v), v.n))
$decl view_trim       $func ($decl v proto_view) $call view_trim_end ($call view_trim_start (v))

// The pieces of a view between occurrences of `sep`, as a sequence of views (`std/seq`'s
// `seq_of`) found as it is walked — not a list, since a list's cells may not hold a view of
// a frame text (§5.3a, A0). The pieces are `split`'s: `a,,b` is `a`, ``, `b`.
$decl splits $func ($decl v proto_view, $decl p "", $decl i 0, $decl d C.bool) {
  $decl w   {
    $decl src  v
    $decl sep  p
    $decl from i
    $decl done d
    $prop is_empty $func () w.done
    // Where the piece from `from` ends: the next `sep`, or the end of the view.
    $prop stop     $func ()
      $call C.or_else ($call str_find ($call raw_str (w.src), w.sep, w.from), w.src.n)
    $prop head     $func () $call view_slice (w.src, w.from, $call w.stop ())
    $prop rest     $func () {
      $decl e    $call w.stop ()
      $decl last $call eq (e, w.src.n)
      $decl ret2 $call splits (w.src, w.sep, $if last e ($call add (e, $call len (w.sep))), last)
    }.ret2
  }
  $decl ret w
}.ret
$decl view_split $func ($decl v proto_view, $decl sep "")
  $if ($call eq ($call len (sep), 0)) ($call panic ("split: an empty separator"))
      ($call splits (v, sep, 0, false))

// The code points of a view from byte `i`, as `codes` gives a `Str`'s.
$decl view_codes $func ($decl v proto_view, $decl i 0) {
  $decl w   {
    $decl src v
    $decl at  i
    $prop is_empty $func () $call C.not ($call lt (w.at, $call view_len (w.src)))
    $prop head     $func () $call code_at ($call raw_str (w.src), w.at)
    $prop rest     $func ()
      $call view_codes (w.src, $call add (w.at, $call width ($call view_byte (w.src, w.at))))
  }
  $decl ret w
}.ret

// Every operation on a `Str` or a view, by the type of the first operand (§4.8). The root's
// are named first, since these names shadow them from here on (§4.1).
$decl root_len   len
$decl root_byte  byte
$decl root_slice slice
$decl root_eq    eq
$decl len         $overload (root_len, view_len)
$decl byte        $overload (root_byte, view_byte)
$decl slice       $overload (root_slice, view_slice)
$decl eq          $overload (root_eq, view_eq, views_eq)
$decl find        $overload (str_find, view_find)
$decl starts_with $overload (str_starts_with, view_starts)
$decl ends_with   $overload (str_ends_with, view_ends)
$decl contains    $overload (str_contains, view_has)
$decl split       $overload (str_split, view_split)
$decl trim_start  $overload (str_trim_start, view_trim_start)
$decl trim_end    $overload (str_trim_end, view_trim_end)
$decl trim        $overload (str_trim, view_trim)
$decl codes       $overload (str_codes, view_codes)

// A text, as the default of a parameter that takes one. A top-level `$decl` is evaluated once
// (§4.10), so this is one empty text nothing writes to.
$decl proto_text $call text ()
