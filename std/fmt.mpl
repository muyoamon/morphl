// std/fmt: writing values into a `std/str` text (STDLIB.md, D1, D4, D6; TEXT.md, T3).
//
// Every writer takes the text first and answers unit, so a value's text is assembled in
// one place however deeply it nests — a record whose `show` returned a `Str` would `concat`
// its children's, which is D6's O(n²) trap. `render` is the one that answers a `Str`.
//
//   $decl F $import "std/fmt"
//   $decl t $call S.text ()
//   $call F.str (t, "x = ")  $call F.int (t, 42)  $call t.view ()      // "x = 42"
//   $call F.fixed (t, 2.675, 2)                                        // "2.67"
//
// A block opts in by having a `show` member (D4): `$prop show $func ($decl b F.text) …`,
// writing itself into `b`. §9 keeps reflection out of the language, so nothing is derived.
// `show` takes no value of the block's own type, so `show_proto` needs no F-bound and a
// `showable` is an ordinary trait object.

$decl C $import "std/core"
$decl L $import "std/list"
$decl Q $import "std/seq"
$decl S $import "std/str"

// A text, as the default of a parameter that takes one: `std/str`'s, one empty text
// nothing writes to. A writer borrows the text it is given, so a frame text or a heap one
// will do (§5.3a).
$decl text S.proto_text

$decl show_proto { $prop show $func ($decl b text) () }
$decl showable   $traitsof show_proto

// ---------------------------------------------------------------------- radix
//
// Digits are written into the text as they are found, so nothing here builds a `Str`.

$decl digits "0123456789abcdefghijklmnopqrstuvwxyz"
$decl digit  $func ($decl d 0) $call slice (digits, d, $call add (d, 1))

$decl check_base $func ($decl base 0)
  $if ($call C.or ($call lt (base, 2), $call lt (36, base)))
      ($call panic ($call concat ("fmt: no base ", $call int_to_str (base)))) ()

// The digits of `n` > 0, most significant first. Not a tail call: the high digits are written
// first, and there are at most 64 of them.
$decl put_digits $func ($decl b text, $decl n 0, $decl base 0)
  $if ($call eq (n, 0)) ()
      ($do ($call put_digits (b, $call div (n, base), base))
           ($call b.write ($call digit ($call mod (n, base)))))

// The digits of `|n|`. The magnitude of the most negative `Int` does not fit in one, so a
// negative number takes its last digit first — `div` truncates, so `q * base - n` is that
// digit — and what is left, `-q`, does fit.
$decl put_mag $func ($decl b text, $decl n 0, $decl base 0)
  $if ($call lt (n, 0)) {
    $decl q    $call div (n, base)
    $decl ret2 $do ($call put_digits (b, $call neg (q), base))
                   ($call b.write ($call digit ($call sub ($call mul (q, base), n))))
  }.ret2 ($if ($call eq (n, 0)) ($call b.write ("0")) ($call put_digits (b, n, base)))

// How many digits `n` has in `base`, its sign aside.
$decl count_digits $func ($decl n 0, $decl base 0, $decl k 1)
  $if ($call C.and ($call lt ($call neg (base), n), $call lt (n, base))) k
      ($call count_digits ($call div (n, base), base, $call add (k, 1)))

// `n` in `base`, 2 to 36, lower case, a `-` before a negative.
$decl radix $func ($decl b text, $decl n 0, $decl base 10)
  $do ($call check_base (base))
      ($do ($if ($call lt (n, 0)) ($call b.write ("-")) ()) ($call put_mag (b, n, base)))
$decl hex   $func ($decl b text, $decl n 0) $call radix (b, n, 16)

// The same as a `Str` of its own.
$decl radix_str $func ($decl n 0, $decl base 10) {
  $decl t   $call S.text ()
  $decl w   $call radix (t, n, base)
  $decl ret $call S.copy_out ($call t.view ())
}.ret

// ---------------------------------------------------------------- primitives

$decl int   $func ($decl b text, $decl n 0)      $call radix (b, n, 10)
// §8's `to_str` on a `Float`: the shortest of 15, 16 or 17 significant digits that reads
// back as the same double, with `.0` on a whole number.
$decl float $func ($decl b text, $decl x 0.0)    $call b.write ($call to_str (x))
$decl str   $func ($decl b text, $decl s "")     $call b.write (s)
$decl bool  $func ($decl b text, $decl v C.bool) $call b.write ($if v "true" "false")
// A code point; one `from_code` refuses (a surrogate, or past U+10FFFF) is U+FFFD.
$decl code  $func ($decl b text, $decl c 0) $call b.code (c)

// Any of the four by its type, resolved at compile time (§4.8). `Bool` is `true | false`
// and no subtype of `Int` (§3.2), so the candidates cannot overlap.
$decl put $overload (int, float, str, bool)

// ------------------------------------------------------------ showable things

// Bounded templates rather than functions over a `showable`, so the call is static (§6,
// "Bounds") and `x` is passed as a value. A trait object refers to its value, so taking one
// would make `F.show (b, s.a)` refuse a field, and refuse it as a tail call, where the
// object would refer to storage of the call that is ending (§7.7).
$decl show $template ($decl X $traitsof show_proto)
  $func ($decl b text, $decl x X) $call x.show (b)

// The text of `x` alone, as a `Str` of its own: written into a frame text, which goes when
// this returns, and copied out of it.
$decl render $template ($decl X $traitsof show_proto) $func ($decl x X) {
  $decl t   $call S.text ()
  $decl w   $call x.show (t)
  $decl ret $call S.copy_out ($call t.view ())
}.ret

// `f` of each element of any `std/seq` sequence, with `sep` between: `sep_by (b, xs, ", ",
// F.int)`. `A` and `B` come from `f`.
$decl sep_rest $template ($decl Sq $traitsof ($specialize Q.seq_of Sq), A, B)
  $func ($decl b text, $decl xs Sq, $decl sep "", $decl f $func ($decl o text, $decl x A) B)
    $if ($call xs.is_empty ()) ()
        ($do ($call b.write (sep))
             ($do ($call f (b, $call xs.head ())) ($call sep_rest (b, $call xs.rest (), sep, f))))
$decl sep_by $template ($decl Sq $traitsof ($specialize Q.seq_of Sq), A, B)
  $func ($decl b text, $decl xs Sq, $decl sep "", $decl f $func ($decl o text, $decl x A) B)
    $if ($call xs.is_empty ()) ()
        ($do ($call f (b, $call xs.head ())) ($call sep_rest (b, $call xs.rest (), sep, f)))

// ------------------------------------------------------------------- padding

// Width is in code points, not bytes (§3.1), so `é` takes one column as `e` does.
$decl width_of $func ($decl s "") $call Q.count ($call S.codes (s, 0), 0)

// `s` written `k` times; none when `k` is not positive.
$decl times $func ($decl b text, $decl s "", $decl k 0)
  $if ($call lt (0, k)) ($do ($call b.write (s)) ($call times (b, s, $call sub (k, 1)))) ()

// `s` with `fill` in front, or after, until it is `w` code points wide; a wider `s` is
// written whole. `fill` is repeated whole, so it should be one code point.
$decl pad_left  $func ($decl b text, $decl s "", $decl w 0, $decl fill " ")
  $do ($call times (b, fill, $call sub (w, $call width_of (s)))) ($call b.write (s))
$decl pad_right $func ($decl b text, $decl s "", $decl w 0, $decl fill " ")
  $do ($call b.write (s)) ($call times (b, fill, $call sub (w, $call width_of (s))))

// `n` in at least `w` columns, zeros after the sign: `zeros (b, -7, 4)` is `-007`.
$decl zeros $func ($decl b text, $decl n 0, $decl w 0) {
  $decl neg $call lt (n, 0)
  $decl ret $do ($if neg ($call b.write ("-")) ())
      ($do ($call times (b, "0", $call sub ($call sub (w, $if neg 1 0),
                                             $call count_digits (n, 10, 1))))
           ($call put_mag (b, n, 10)))
}.ret

// ------------------------------------------------------------------ quoting

// Whether byte `c` needs an escape in a morphl string literal (§2.1: `\n \t \\ \"` and
// `\u{…}`), and the escape written. A byte of a multi-byte code point is 128 or more and
// stands for itself, so the text stays valid UTF-8.
$decl is_control $func ($decl c 0) $call C.or ($call lt (c, 32), $call eq (c, 127))
$decl escapes    $func ($decl c 0)
  $call C.or ($call C.or ($call eq (c, 34), $call eq (c, 92)), $call is_control (c))
$decl put_escape $func ($decl b text, $decl c 0)
  $if ($call eq (c, 34)) ($call b.write ("\\\""))
  ($if ($call eq (c, 92)) ($call b.write ("\\\\"))
  ($if ($call eq (c, 10)) ($call b.write ("\\n"))
  ($if ($call eq (c, 9)) ($call b.write ("\\t"))
       ($do ($call b.write ("\\u{")) ($do ($call radix (b, c, 16)) ($call b.write ("}")))))))

// The unescaped run from `start` is written in one piece when an escape or the end is
// reached, so plain text costs one write and not one per byte.
$decl quoted_go $func ($decl b text, $decl s "", $decl start 0, $decl i 0)
  $if ($call lt (i, $call len (s)))
      ($if ($call C.not ($call escapes ($call byte (s, i))))
           ($call quoted_go (b, s, start, $call add (i, 1)))
           ($do ($call b.write ($call slice (s, start, i)))
                ($do ($call put_escape (b, $call byte (s, i)))
                     ($call quoted_go (b, s, $call add (i, 1), $call add (i, 1))))))
      ($call b.write ($call slice (s, start, i)))

// `s` as a morphl string literal, which reads back as `s`.
$decl quoted $func ($decl b text, $decl s "")
  $do ($call b.write ("\""))
      ($do ($call quoted_go (b, s, 0, 0)) ($call b.write ("\"")))

// ------------------------------------------------------------- fixed decimals

// `x` with exactly `d` digits after the point, rounded correctly: to the nearest, ties to
// even, on the double's *exact* value — so `fixed (b, 2.675, 2)` is `2.67`, since the
// double nearest 2.675 is just below it, and `fixed (b, 0.125, 2)` is `0.12`. That is C's
// `%.*f`. Scaling by a power of ten and rounding would round twice, and `x * 10^d` stops
// being exact long before `d` is large.
//
// A finite double is `m · 2^e` exactly, `m` a whole number below 2^53, and found exactly:
// halving a whole number that big, or doubling any double, is exact. So `x · 10^d` is
// `m · 5^d · 2^(e+d)`, a whole number when `e + d` is not negative, and otherwise one
// divided by `2^s` — whose quotient is the answer up to rounding, and whose remainder
// decides it. Both are a whole number of up to ~1,100 bits, held as base-10⁹ limbs, low
// limb first; `d` digits cost O(d) limbs.
//
// A negative `x` writes `-`, `-0.0` and a negative that rounds to zero included, as `%f`
// does; NaN and the infinities are `to_str`'s `nan`, `inf` and `-inf`.

$decl limbs $specialize L.list 0
$decl lc    limbs.cell
$decl lbase 1000000000

// `xs · k + carry`, for `k` no more than 10⁹ so a limb's product fits an `Int`.
$decl big_mul_go $func ($decl xs limbs.node, $decl k 0, $decl carry 0, $decl acc limbs.node)
  $match xs (
    $case {$prop tag "cons"} {
      $decl v    $call add ($call mul (xs.head, k), carry)
      $decl ret2 $call big_mul_go (xs.tail, k, $call div (v, lbase),
                     $call lc.cons ($call mod (v, lbase), acc))
    }.ret2,
    $case xs
      $call lc.reverse ($if ($call eq (carry, 0)) acc ($call lc.cons (carry, acc)), limbs.nil)
  )
$decl big_mul $func ($decl xs limbs.node, $decl k 0) $call big_mul_go (xs, k, 0, limbs.nil)

// `xs · k^n`, `k^c` at a time, `k^c` no more than 10⁹.
$decl big_pow $func ($decl xs limbs.node, $decl k 0, $decl n 0, $decl c 0, $decl kc 0)
  $if ($call lt (n, c))
      ($if ($call eq (n, 0)) xs ($call big_pow ($call big_mul (xs, k), k, $call sub (n, 1), c, kc)))
      ($call big_pow ($call big_mul (xs, kc), k, $call sub (n, c), c, kc))

// `xs` divided by `p` ≤ 2^29, from the high limb down — `hi` is the limbs high first — so
// the quotient comes out low limb first. `{q, r}`.
$decl big_div_go $func ($decl hi limbs.node, $decl p 0, $decl rm 0, $decl acc limbs.node)
  $match hi (
    $case {$prop tag "cons"} {
      $decl v    $call add ($call mul (rm, lbase), hi.head)
      $decl ret2 $call big_div_go (hi.tail, p, $call mod (v, p),
                     $call lc.cons ($call div (v, p), acc))
    }.ret2,
    $case hi { $decl q acc  $decl r rm }
  )

// `xs + 1`.
$decl big_add1_go $func ($decl xs limbs.node, $decl acc limbs.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq (xs.head, $call sub (lbase, 1)))
        ($call big_add1_go (xs.tail, $call lc.cons (0, acc)))
        ($call lc.reverse ($call lc.cons ($call add (xs.head, 1), acc), xs.tail)),
  $case xs $call lc.reverse ($call lc.cons (1, acc), limbs.nil)
)
$decl big_add1 $func ($decl xs limbs.node) $call big_add1_go (xs, limbs.nil)

// `xs` divided by `2^s`, rounded to the nearest and ties to even: `half` is the remainder's
// top bit and `sticky` whether any bit below it is set, over the chunks taken so far.
$decl big_shr $func ($decl xs limbs.node, $decl s 0, $decl sticky C.bool)
  $if ($call lt (29, s)) {
    $decl dv   $call big_div_go ($call lc.reverse (xs, limbs.nil), 536870912, 0, limbs.nil)
    $decl ret2 $call big_shr (dv.q, $call sub (s, 29), $call C.or (sticky, $call lt (0, dv.r)))
  }.ret2 {
    $decl p    $call shl (1, s)
    $decl dv   $call big_div_go ($call lc.reverse (xs, limbs.nil), p, 0, limbs.nil)
    $decl hb   $call shr (p, 1)
    $decl half $call C.not ($call lt (dv.r, hb))
    $decl low  $call C.or (sticky, $call lt (0, $call sub (dv.r, $if half hb 0)))
    $decl odd  $call eq ($call mod ($call lc.head (dv.q), 2), 1)
    $decl up   $call C.and (half, $call C.or (low, odd))
    $decl ret2 $if up ($call big_add1 (dv.q)) dv.q
  }.ret2

// `a` ≥ 0 as `{m, e}`, `a = m · 2^e` with `m` whole and below 2^53.
$decl whole $func ($decl a 0.0) $call eq ($call to_float ($call C.or_else ($call to_int (a), 0)), a)
$decl split_go $func ($decl a 0.0, $decl ex 0)
  $if ($call C.not ($call lt (a, 9007199254740992.0)))
      ($call split_go ($call div (a, 2.0), $call add (ex, 1)))
      ($if ($call whole (a)) { $decl m $call C.or_else ($call to_int (a), 0)  $decl e ex }
           ($call split_go ($call mul (a, 2.0), $call sub (ex, 1))))

// The decimal digits of the limbs `hi`, high limb first: the first limb without its leading
// zeros, the rest nine wide.
$decl put_limbs $func ($decl b text, $decl hi limbs.node) $match hi (
  $case {$prop tag "cons"}
    $do ($call times (b, "0", $call sub (9, $call count_digits (hi.head, 10, 1))))
        ($do ($call put_mag (b, hi.head, 10)) ($call put_limbs (b, hi.tail))),
  $case hi ()
)
// Without the leading zero limbs, one limb kept so zero is "0".
$decl top_limbs $func ($decl hi limbs.node) $match hi (
  $case {$prop tag "cons"}
    $if ($call C.and ($call eq (hi.head, 0), $call C.not ($call lc.is_nil (hi.tail))))
        ($call top_limbs (hi.tail)) hi,
  $case hi hi
)
$decl digit_count $func ($decl hi limbs.node) $match hi (
  $case {$prop tag "cons"}
    $call add ($call count_digits (hi.head, 10, 1), $call mul (9, $call lc.length (hi.tail, 0))),
  $case hi 0
)

// The digits of `|x| · 10^d`, rounded — at least `d + 1` of them, so a point fits — written
// into `b`.
$decl put_scaled $func ($decl b text, $decl a 0.0, $decl d 0) {
  $decl sp  $call split_go (a, 0)
  $decl m5  $call big_pow ($call big_mul ($call lc.cons (sp.m, limbs.nil), 1), 5, d, 12, 244140625)
  $decl t   $call add (sp.e, d)
  $decl q   $if ($call lt (t, 0)) ($call big_shr (m5, $call neg (t), false))
                ($call big_pow (m5, 2, t, 29, 536870912))
  $decl hi  $call top_limbs ($call lc.reverse (q, limbs.nil))
  $decl ret $match hi (
    $case {$prop tag "cons"}
      $do ($call times (b, "0", $call sub ($call add (d, 1), $call digit_count (hi))))
          ($do ($call put_mag (b, hi.head, 10)) ($call put_limbs (b, hi.tail))),
    $case hi ()
  )
}.ret

// The digits go into a text of their own first, since the point falls `d` from their end,
// and are copied into `b` as two views of it.
$decl fixed $func ($decl b text, $decl x 0.0, $decl d 0)
  $if ($call lt (d, 0)) ($call panic ($call concat ("fmt: no ", $call concat (
          $call int_to_str (d), " decimals"))))
  ($if ($call C.not ($call eq ($call sub (x, x), 0.0))) ($call b.write ($call to_str (x))) {
    $decl minus $call C.or ($call lt (x, 0.0),
                    $call C.and ($call eq (x, 0.0), $call lt ($call div (1.0, x), 0.0)))
    $decl t     $call S.text ()
    $decl w     $call put_scaled (t, $if minus ($call neg (x)) x, d)
    $decl v     $call t.view ()
    $decl k     $call sub ($call S.len (v), d)
    $decl n     $call S.len (v)
    $decl ret2  $do ($if minus ($call b.write ("-")) ())
                    ($do ($call b.write ($call S.slice (v, 0, k)))
                         ($if ($call eq (d, 0)) ()
                              ($do ($call b.write (".")) ($call b.write ($call S.slice (v, k, n))))))
  }.ret2)

$decl fixed_str $func ($decl x 0.0, $decl d 0) {
  $decl t   $call S.text ()
  $decl w   $call fixed (t, x, d)
  $decl ret $call S.copy_out ($call t.view ())
}.ret
