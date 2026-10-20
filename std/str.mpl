// std/str: building and taking apart a `Str` (STDLIB.md, D6), over §8's `concat`, `len`,
// `slice`, `byte` and `from_code`.
//
// §3.1 makes a `Str` valid UTF-8 and its operations byte-indexed, so every index here is a
// byte offset and every search compares bytes; code points are `codes`, a sequence that
// decodes as it goes and works with `std/seq`: `$call Q.count ($call S.codes (s))`.
//
// §8's `concat` copies both operands, so appending to an accumulator is O(n²) in the pieces
// (CLAUDE.md, from `emit.mpl`'s `say`). Text is assembled in a **builder** instead, or with
// `concat_all`/`join`: the pieces are collected and joined by folding adjacent pairs, log₂ n
// passes each copying the text once.

$decl C $import "std/core"
$decl L $import "std/list"

$decl strs $specialize L.list ""
$decl cl   strs.cell

// ---------------------------------------------------------------- joining

$fwd join_pass
$decl join_pair $func ($decl x "", $decl rest strs.node, $decl acc strs.node) $match rest (
  $case {$prop tag "cons"}
    $call join_pass ($call cl.val (rest.tail), $call cl.cons ($call concat (x, rest.head), acc)),
  $case rest ($call cl.reverse ($call cl.cons (x, acc), strs.nil))
)
$decl join_pass $func ($decl xs strs.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"} $call join_pair (xs.head, $call cl.val (xs.tail), acc),
  $case xs ($call cl.reverse (acc, strs.nil))
)
$fwd join_cells
$decl join_more $func ($decl xs strs.node, $decl rest strs.node) $match rest (
  $case {$prop tag "cons"} $call join_cells ($call join_pass (xs, strs.nil)),
  $case rest ""
)
// The pieces in order, joined.
$decl join_cells $func ($decl xs strs.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call cl.is_nil ($call cl.val (xs.tail))) xs.head
        ($call join_more (xs, $call cl.val (xs.tail))),
  $case xs ""
)

$decl concat_all $func ($decl xs ($call strs.empty ())) $call join_cells (xs.cells)

// `sep` between each pair, reversed in front of `acc`.
$decl sep_go $func ($decl xs strs.node, $decl sep "", $decl acc strs.node) $match xs (
  $case {$prop tag "cons"}
    $call sep_go ($call cl.val (xs.tail), sep,
        $call cl.cons (xs.head, $if ($call cl.is_nil (acc)) acc ($call cl.cons (sep, acc)))),
  $case xs acc
)
$decl join $func ($decl xs ($call strs.empty ()), $decl sep "")
  $call join_cells ($call cl.reverse ($call sep_go (xs.cells, sep, strs.nil), strs.nil))

// --------------------------------------------------------------- the builder

// Text assembled piece by piece: `$call b.write (s)` and `$call b.build ()`. The pieces are
// held newest first in the builder's own cell (D9: a container that changes in place holds
// its state in `$mut $alloc` cells), and `build` joins them pairwise, then keeps the result
// as the one piece, so building again costs nothing and adding after it carries on.
$decl builder $func () {
  $decl b   {
    $decl parts $mut $alloc strs.node
    $decl size  $mut $alloc 0
    // Not `add` or `len`: a prop is visible throughout its block (§4.10), so a member
    // of either name would shadow the intrinsic these bodies call.
    $prop write $func ($decl s "") $do
      ($set b.parts ($call cl.cons (s, $call cl.val (b.parts))))
      ($set b.size ($call add ($call C.ival (b.size), $call len (s))))
    $prop line  $func ($decl s "") $do ($call b.write (s)) ($call b.write ("\n"))
    // The bytes written so far.
    $prop bytes $func () $call C.ival (b.size)
    $prop build $func () {
      $decl t   $call join_cells ($call cl.reverse ($call cl.val (b.parts), strs.nil))
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

$decl starts_with $func ($decl s "", $decl p "")
  $if ($call lt ($call len (s), $call len (p))) false
      ($call eq ($call slice (s, 0, $call len (p)), p))
$decl ends_with $func ($decl s "", $decl p "")
  $if ($call lt ($call len (s), $call len (p))) false
      ($call eq ($call slice (s, $call sub ($call len (s), $call len (p)), $call len (s)), p))

// Whether `p` occurs at byte `i` of `s`.
$decl at_is $func ($decl s "", $decl p "", $decl i 0)
  $if ($call lt ($call len (s), $call add (i, $call len (p)))) false
      ($call eq ($call slice (s, i, $call add (i, $call len (p))), p))

// The first byte offset at or after `from` where `p` occurs, as an option. An empty `p`
// occurs everywhere, so it is found at `from`.
$decl find $func ($decl s "", $decl p "", $decl from 0)
  $if ($call lt ($call sub ($call len (s), $call len (p)), from)) none
      ($if ($call at_is (s, p, from)) ($call C.some (from))
           ($call find (s, p, $call add (from, 1))))
$decl contains $func ($decl s "", $decl p "") $call C.is_some ($call find (s, p, 0))

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
$decl split $func ($decl s "", $decl sep "")
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
$decl trim_start $func ($decl s "") $call slice (s, $call first_non (s, 0), $call len (s))
$decl trim_end   $func ($decl s "") $call slice (s, 0, $call last_non (s, $call len (s)))
$decl trim       $func ($decl s "") $call trim_end ($call trim_start (s))

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
$decl codes $func ($decl s "", $decl i 0) {
  $decl w   {
    $decl text s
    $decl at   i
    $prop is_empty $func () $call C.not ($call lt (w.at, $call len (w.text)))
    $prop head     $func () $call code_at (w.text, w.at)
    $prop rest     $func ()
      $call codes (w.text, $call add (w.at, $call width ($call byte (w.text, w.at))))
  }
  $decl ret w
}.ret
