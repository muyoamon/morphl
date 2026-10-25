// std/fmt: writing values as text into a `std/str` builder (STDLIB.md, D1, D4, D6).
//
// Every writer takes the builder first and answers unit, so a value's text is assembled in
// one place however deeply it nests — a record whose `show` returned a `Str` would `concat`
// its children's, which is D6's O(n²) trap. `render` is the one that answers a `Str`.
//
//   $decl F $import "std/fmt"
//   $decl b $call S.builder ()
//   $call F.str (b, "x = ")  $call F.int (b, 42)  $call b.build ()     // "x = 42"
//
// A block opts in by having a `show` member (D4): `$prop show $func ($decl b F.builder) …`,
// writing itself into `b`. §9 keeps reflection out of the language, so nothing is derived.
// `show` takes no value of the block's own type, so `show_proto` needs no F-bound and a
// `showable` is an ordinary trait object.

$decl C $import "std/core"
$decl L $import "std/list"
$decl Q $import "std/seq"
$decl S $import "std/str"

$decl strs $specialize L.list ""
$decl cl   strs.cell

// A builder, as the default of a parameter that takes one. §5.7 never evaluates a
// default as a type carrier, but a top-level `$decl` is evaluated once (§4.10), so this
// is one empty builder nothing writes to.
$decl builder $call S.builder ()

$decl show_proto { $prop show $func ($decl b builder) () }
$decl showable   $traitsof show_proto

// ---------------------------------------------------------------- primitives

$decl int   $func ($decl b builder, $decl n 0)      $call b.write ($call int_to_str (n))
// §8's `to_str` on a `Float`: the shortest of 15, 16 or 17 significant digits that reads
// back as the same double, with `.0` on a whole number.
$decl float $func ($decl b builder, $decl x 0.0)    $call b.write ($call to_str (x))
$decl str   $func ($decl b builder, $decl s "")     $call b.write (s)
$decl bool  $func ($decl b builder, $decl v C.bool) $call b.write ($if v "true" "false")
// A code point; one `from_code` refuses (a surrogate, or past U+10FFFF) is U+FFFD.
$decl code  $func ($decl b builder, $decl c 0)
  $call b.write ($call C.or_else ($call from_code (c), "\u{fffd}"))

// Any of the four by its type, resolved at compile time (§4.8). `Bool` is `true | false`
// and no subtype of `Int` (§3.2), so the candidates cannot overlap.
$decl put $overload (int, float, str, bool)

// ------------------------------------------------------------ showable things

// Bounded templates rather than functions over a `showable`, so the call is static (§6,
// "Bounds") and `x` is passed as a value. A trait object refers to its value, so taking one
// would make `F.show (b, s.a)` refuse a field, and refuse it as a tail call, where the
// object would refer to storage of the call that is ending (§7.7).
$decl show $template ($decl X $traitsof show_proto)
  $func ($decl b builder, $decl x X) $call x.show (b)

// The text of `x` alone.
$decl render $template ($decl X $traitsof show_proto) $func ($decl x X) {
  $decl b   $call S.builder ()
  $decl w   $call x.show (b)
  $decl ret $call b.build ()
}.ret

// `f` of each element of any `std/seq` sequence, with `sep` between: `sep_by (b, xs, ", ",
// F.int)`. `A` and `B` come from `f`.
$decl sep_rest $template ($decl Sq $traitsof ($specialize Q.seq_of Sq), A, B)
  $func ($decl b builder, $decl xs Sq, $decl sep "", $decl f $func ($decl o builder, $decl x A) B)
    $if ($call xs.is_empty ()) ()
        ($do ($call b.write (sep))
             ($do ($call f (b, $call xs.head ())) ($call sep_rest (b, $call xs.rest (), sep, f))))
$decl sep_by $template ($decl Sq $traitsof ($specialize Q.seq_of Sq), A, B)
  $func ($decl b builder, $decl xs Sq, $decl sep "", $decl f $func ($decl o builder, $decl x A) B)
    $if ($call xs.is_empty ()) ()
        ($do ($call f (b, $call xs.head ())) ($call sep_rest (b, $call xs.rest (), sep, f)))

// ---------------------------------------------------------------------- radix

$decl digits "0123456789abcdefghijklmnopqrstuvwxyz"
$decl digit  $func ($decl d 0) $call slice (digits, d, $call add (d, 1))

// The digits of `n` ≥ 0 in front of `acc`, most significant first.
$decl digits_of $func ($decl n 0, $decl base 0, $decl acc strs.node)
  $if ($call eq (n, 0)) acc
      ($call digits_of ($call div (n, base), base,
           $call cl.cons ($call digit ($call mod (n, base)), acc)))

// `n` in `base`, 2 to 36, lower case, a `-` before a negative. The magnitude of the most
// negative `Int` does not fit in one, so a negative number takes its last digit first —
// `div` truncates, so `q * base - n` is that digit — and what is left, `-q`, does fit.
$decl radix_str $func ($decl n 0, $decl base 10)
  $if ($call C.or ($call lt (base, 2), $call lt (36, base)))
      ($call panic ($call concat ("fmt: no base ", $call int_to_str (base))))
      ($if ($call eq (n, 0)) "0"
           ($if ($call lt (n, 0)) {
             $decl q    $call div (n, base)
             $decl d    $call sub ($call mul (q, base), n)
             $decl ret2 $call concat ("-", $call S.concat_all ($call strs.of
                            ($call digits_of ($call neg (q), base,
                                 $call cl.cons ($call digit (d), strs.nil)))))
           }.ret2
               ($call S.concat_all ($call strs.of ($call digits_of (n, base, strs.nil))))))

$decl radix $func ($decl b builder, $decl n 0, $decl base 10)
  $call b.write ($call radix_str (n, base))
$decl hex   $func ($decl b builder, $decl n 0) $call radix (b, n, 16)

// ------------------------------------------------------------------- padding

// Width is in code points, not bytes (§3.1), so `é` takes one column as `e` does.
$decl width_of $func ($decl s "") $call Q.count ($call S.codes (s, 0), 0)

// `s` with `fill` in front, or after, until it is `w` code points wide; a wider `s` is
// written whole. `fill` is repeated whole, so it should be one code point.
$decl pad_left  $func ($decl b builder, $decl s "", $decl w 0, $decl fill " ")
  $do ($call b.write ($call S.repeat (fill, $call sub (w, $call width_of (s)))))
      ($call b.write (s))
$decl pad_right $func ($decl b builder, $decl s "", $decl w 0, $decl fill " ")
  $do ($call b.write (s))
      ($call b.write ($call S.repeat (fill, $call sub (w, $call width_of (s)))))

// `n` in at least `w` columns, zeros after the sign: `zeros (b, -7, 4)` is `-007`.
$decl zeros $func ($decl b builder, $decl n 0, $decl w 0) {
  $decl s   $call int_to_str (n)
  $decl ret $if ($call lt (n, 0))
                ($do ($call b.write ("-"))
                     ($call pad_left (b, $call slice (s, 1, $call len (s)), $call sub (w, 1), "0")))
                ($call pad_left (b, s, w, "0"))
}.ret

// ------------------------------------------------------------------ quoting

// The escape for byte `c` in a morphl string literal (§2.1: `\n \t \\ \"` and `\u{…}`),
// or "" when it stands for itself. A byte of a multi-byte code point is 128 or more and
// stands for itself, so the text stays valid UTF-8.
$decl escape_of $func ($decl c 0)
  $if ($call eq (c, 34)) "\\\""
  ($if ($call eq (c, 92)) "\\\\"
  ($if ($call eq (c, 10)) "\\n"
  ($if ($call eq (c, 9)) "\\t"
  ($if ($call C.or ($call lt (c, 32), $call eq (c, 127)))
       ($call concat ("\\u{", $call concat ($call radix_str (c, 16), "}")))
       ""))))

// The unescaped run from `start` is written in one piece when an escape or the end is
// reached, so plain text costs one write and not one per byte.
$decl quoted_go $func ($decl b builder, $decl s "", $decl start 0, $decl i 0)
  $if ($call lt (i, $call len (s)))
      ($if ($call eq ($call len ($call escape_of ($call byte (s, i))), 0))
           ($call quoted_go (b, s, start, $call add (i, 1)))
           ($do ($call b.write ($call slice (s, start, i)))
                ($do ($call b.write ($call escape_of ($call byte (s, i))))
                     ($call quoted_go (b, s, $call add (i, 1), $call add (i, 1))))))
      ($call b.write ($call slice (s, start, i)))

// `s` as a morphl string literal, which reads back as `s`.
$decl quoted $func ($decl b builder, $decl s "")
  $do ($call b.write ("\""))
      ($do ($call quoted_go (b, s, 0, 0)) ($call b.write ("\"")))
