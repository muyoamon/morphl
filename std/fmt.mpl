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
$decl str   $func ($decl b text, $decl s "")     $call b.write (s)
$decl bool  $func ($decl b text, $decl v C.bool) $call b.write ($if v "true" "false")
// A code point; one `from_code` refuses (a surrogate, or past U+10FFFF) is U+FFFD.
$decl code  $func ($decl b text, $decl c 0) $call b.code (c)

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
// does; NaN and the infinities are `nan`, `inf` and `-inf`.

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

// NaN as `nan`, whatever its sign, and an infinity as `inf` or `-inf`.
$decl nonfinite $func ($decl b text, $decl x 0.0)
  $if ($call eq (x, x)) ($call b.write ($if ($call lt (x, 0.0)) "-inf" "inf"))
      ($call b.write ("nan"))

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
  ($if ($call C.not ($call eq ($call sub (x, x), 0.0))) ($call nonfinite (b, x)) {
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

// ------------------------------------------------------------ shortest digits
//
// `float` writes what §8's `to_str` answers, with no `Str` built: the shortest of 15, 16
// and 17 significant digits that reads back as the same double, laid out as C's `%g` lays
// it out — a point where the exponent is from -4 to one less than the digits, `e±XX`
// otherwise, trailing zeros dropped — and `.0` after a whole number written without an
// exponent, so finite text is a morphl float literal.
//
// Every step is exact, over whole numbers in raw memory. `x = m · 2^e` with `m` of 53 bits
// (fewer only at the least exponent); its first digit's exponent is estimated from `e` and
// checked; the digits are `x · 10^k` rounded down by dividing, then corrected against
// `q + 1/2`, ties to even, as `%g` rounds. And they read back as `x` when they lie between
// the halfway points to the doubles either side — on one, when `m` is even, since a tie
// reads as the even one.

// A whole number in raw memory: a count of limbs, then the limbs, base 10⁹, low first. Each
// is freed when the question it was made for is answered, since nothing frees what is left
// (§7.6) and a program may print many doubles. `bcap` limbs hold every number below: the
// largest is a double's ~1,075 bits beside a power of ten that matches it, ~360 digits.
$decl bcap 160
$decl word $func ($decl a 0, $decl i 0) $call $primitives.unbox ($call add (a, $call mul (8, i)), 0)
$decl blen $func ($decl a 0) $call C.ival ($call word (a, 0))
$decl bget $func ($decl a 0, $decl i 0) $call C.ival ($call word (a, $call add (i, 1)))
$decl bput $func ($decl a 0, $decl i 0, $decl v 0)
  $do ($set ($call word (a, $call add (i, 1))) v) ()
$decl bsetn $func ($decl a 0, $decl n 0) $do ($set ($call word (a, 0)) n) ()

// The top limbs that are zero dropped, one kept.
$decl btrim $func ($decl a 0)
  $if ($call C.and ($call lt (1, $call blen (a)),
                    $call eq ($call bget (a, $call sub ($call blen (a), 1)), 0)))
      ($do ($call bsetn (a, $call sub ($call blen (a), 1))) ($call btrim (a))) ()

// `v` ≥ 0, in memory of its own.
$decl bnew $func ($decl v 0) {
  $decl a   $call $primitives.raw_alloc ($call mul (8, $call add (bcap, 1)))
  $decl ok  $if ($call eq (a, 0)) ($call panic ("fmt: out of memory")) ()
  $decl w0  $call bput (a, 0, $call mod (v, lbase))
  $decl w1  $call bput (a, 1, $call mod ($call div (v, lbase), lbase))
  $decl w2  $call bput (a, 2, $call div (v, $call mul (lbase, lbase)))
  $decl n   $call bsetn (a, 3)
  $decl t   $call btrim (a)
  $decl ret a
}.ret
$decl bfree $func ($decl a 0) $call $primitives.raw_free (a)

// `a · k` in place, `k` no more than 10⁹, so a limb's product and its carry fit an `Int`.
$decl bmul_go $func ($decl a 0, $decl k 0, $decl i 0, $decl carry 0)
  $if ($call lt (i, $call blen (a))) {
    $decl v    $call add ($call mul ($call bget (a, i), k), carry)
    $decl w    $call bput (a, i, $call mod (v, lbase))
    $decl ret2 $call bmul_go (a, k, $call add (i, 1), $call div (v, lbase))
  }.ret2
  ($if ($call eq (carry, 0)) ()
  ($if ($call lt ($call blen (a), bcap))
       ($do ($call bput (a, $call blen (a), carry))
            ($call bsetn (a, $call add ($call blen (a), 1))))
       ($call panic ("fmt: a number too large for its memory"))))
$decl bmul $func ($decl a 0, $decl k 0) $call bmul_go (a, k, 0, 0)

$decl small_pow $func ($decl k 0, $decl n 0, $decl acc 1)
  $if ($call eq (n, 0)) acc ($call small_pow (k, $call sub (n, 1), $call mul (acc, k)))

// `a · k^n` in place, `k^c` at a time; `kc` is `k^c`, no more than 10⁹.
$decl bpow $func ($decl a 0, $decl k 0, $decl n 0, $decl c 0, $decl kc 0)
  $if ($call lt (n, c)) ($if ($call eq (n, 0)) () ($call bmul (a, $call small_pow (k, n, 1))))
      ($do ($call bmul (a, kc)) ($call bpow (a, k, $call sub (n, c), c, kc)))
$decl bscale $func ($decl a 0, $decl p2 0, $decl p5 0)
  $do ($call bpow (a, 5, p5, 12, 244140625)) ($call bpow (a, 2, p2, 29, 536870912))

// `a / d` in place, rounded down, `d` no more than 2^29: from the top limb down.
$decl bdiv_go $func ($decl a 0, $decl d 0, $decl i 0, $decl rm 0)
  $if ($call lt (i, 0)) ($call btrim (a)) {
    $decl v    $call add ($call mul (rm, lbase), $call bget (a, i))
    $decl w    $call bput (a, i, $call div (v, d))
    $decl ret2 $call bdiv_go (a, d, $call sub (i, 1), $call mod (v, d))
  }.ret2
// `a / k^n`, rounded down, `k^c` at a time: rounding down twice is rounding down once.
$decl bdivp $func ($decl a 0, $decl k 0, $decl n 0, $decl c 0, $decl kc 0)
  $if ($call eq (n, 0)) ()
      ($do ($call bdiv_go (a, $if ($call lt (n, c)) ($call small_pow (k, n, 1)) kc,
                           $call sub ($call blen (a), 1), 0))
           ($call bdivp (a, k, $call sub (n, $call C.min (n, c)), c, kc)))

// The number as an `Int`, which it must fit.
$decl bint_go $func ($decl a 0, $decl i 0, $decl acc 0)
  $if ($call lt (i, 0)) acc
      ($call bint_go (a, $call sub (i, 1), $call add ($call mul (acc, lbase), $call bget (a, i))))
$decl bint $func ($decl a 0) $call bint_go (a, $call sub ($call blen (a), 1), 0)

// -1, 0 or 1 as `a` is below, equal to or above `b`.
$decl bcmp_go $func ($decl a 0, $decl b 0, $decl i 0)
  $if ($call lt (i, 0)) 0
  ($if ($call lt ($call bget (a, i), $call bget (b, i))) -1
  ($if ($call lt ($call bget (b, i), $call bget (a, i))) 1
       ($call bcmp_go (a, b, $call sub (i, 1)))))
$decl bcmp $func ($decl a 0, $decl b 0)
  $if ($call lt ($call blen (a), $call blen (b))) -1
  ($if ($call lt ($call blen (b), $call blen (a))) 1
       ($call bcmp_go (a, b, $call sub ($call blen (a), 1))))

// `a · 2^a2 · 5^a5` against `b · 2^b2 · 5^b5`, for `a` and `b` ≥ 0 and powers of any sign.
$decl cmp_sc $func ($decl a 0, $decl a2 0, $decl a5 0, $decl b 0, $decl b2 0, $decl b5 0) {
  $decl m2  $call C.min (a2, b2)
  $decl m5  $call C.min (a5, b5)
  $decl x   $call bnew (a)
  $decl y   $call bnew (b)
  $decl sx  $call bscale (x, $call sub (a2, m2), $call sub (a5, m5))
  $decl sy  $call bscale (y, $call sub (b2, m2), $call sub (b5, m5))
  $decl r   $call bcmp (x, y)
  $decl fx  $call bfree (x)
  $decl fy  $call bfree (y)
  $decl ret r
}.ret

// `m · 2^e` with its 53 bits, unless `e` is the least a double has.
$decl norm $func ($decl mm 0, $decl ee 0)
  $if ($call C.and ($call lt (mm, 4503599627370496), $call lt (-1074, ee)))
      ($call norm ($call mul (mm, 2), $call sub (ee, 1))) { $decl m mm  $decl e ee }

// The exponent of `x`'s first digit, `floor (log10 x)`: `log10 2` times the binary one,
// then moved until `10^k ≤ x < 10^(k+1)`.
$decl bitlen $func ($decl m 0, $decl k 0)
  $if ($call eq (m, 0)) k ($call bitlen ($call div (m, 2), $call add (k, 1)))
$decl est_exp $func ($decl m 0, $decl e 0)
  $call C.or_else ($call to_int ($call mul ($call to_float ($call add (e, $call sub (
      $call bitlen (m, 0), 1))), 0.30102999566398120)), 0)
$decl pow10_le $func ($decl m 0, $decl e 0, $decl k 0)
  $call lt (-1, $call cmp_sc (m, e, 0, 1, k, k))
$decl fix_exp $func ($decl m 0, $decl e 0, $decl k 0)
  $if ($call C.not ($call pow10_le (m, e, k))) ($call fix_exp (m, e, $call sub (k, 1)))
  ($if ($call pow10_le (m, e, $call add (k, 1))) ($call fix_exp (m, e, $call add (k, 1))) k)

// `m · 2^e` to `p` significant digits, `x0` its first digit's exponent: `{d, x}`, the digits
// as a whole number and the exponent after rounding, which a carry can move up one.
$decl round_sig $func ($decl m 0, $decl e 0, $decl x0 0, $decl p 0) {
  $decl k   $call sub ($call sub (p, 1), x0)
  // `x · 10^k` is `m · 2^t · 5^k`.
  $decl t   $call add (e, k)
  $decl a   $call bnew (m)
  $decl up  $call bscale (a, $call C.max (t, 0), $call C.max (k, 0))
  $decl d5  $call bdivp (a, 5, $call C.max ($call neg (k), 0), 12, 244140625)
  $decl d2  $call bdivp (a, 2, $call C.max ($call neg (t), 0), 29, 536870912)
  $decl q   $call bint (a)
  $decl fa  $call bfree (a)
  $decl c   $call cmp_sc (m, $call add (t, 1), k, $call add ($call mul (q, 2), 1), 0, 0)
  $decl r   $if ($call C.or ($call lt (0, c),
                             $call C.and ($call eq (c, 0), $call eq ($call mod (q, 2), 1))))
                ($call add (q, 1)) q
  $decl top $call small_pow (10, p, 1)
  $decl ret $if ($call eq (r, top)) { $decl d $call div (top, 10)  $decl x $call add (x0, 1) }
                { $decl d r  $decl x x0 }
}.ret

// Whether `d · 10^k` reads back as `m · 2^e`. Below a power of two the double under it is
// half as far away, so its halfway point is too.
$decl reads_back $func ($decl d 0, $decl k 0, $decl m 0, $decl e 0) {
  $decl eg  $call C.and ($call eq (m, 4503599627370496), $call lt (-1074, e))
  $decl lo  $if eg ($call cmp_sc (d, k, k, $call sub ($call mul (m, 4), 1), $call sub (e, 2), 0))
                   ($call cmp_sc (d, k, k, $call sub ($call mul (m, 2), 1), $call sub (e, 1), 0))
  $decl hi  $call cmp_sc (d, k, k, $call add ($call mul (m, 2), 1), $call sub (e, 1), 0)
  $decl ev  $call eq ($call mod (m, 2), 0)
  $decl ret $call C.and ($if ev ($call lt (-1, lo)) ($call eq (lo, 1)),
                         $if ev ($call lt (hi, 1)) ($call eq (hi, -1)))
}.ret

// The first of `p` = 15, 16 and 17 digits that reads back: `{d, x, prec}`.
$decl shortest $func ($decl m 0, $decl e 0, $decl x0 0, $decl p 15) {
  $decl r    $call round_sig (m, e, x0, p)
  $decl ret2 $if ($call C.or ($call eq (p, 17),
                              $call reads_back (r.d, $call add ($call sub (r.x, p), 1), m, e)))
                 { $decl d r.d  $decl x r.x  $decl prec p }
                 ($call shortest (m, e, x0, $call add (p, 1)))
}.ret2

// `d` without its trailing zeros: `{v, z}`, `z` how many there were.
$decl strip $func ($decl d 0, $decl z 0)
  $if ($call C.and ($call lt (0, d), $call eq ($call mod (d, 10), 0)))
      ($call strip ($call div (d, 10), $call add (z, 1))) { $decl v d  $decl n z }

// The digits `v`, `x` the exponent of the first, laid out by `%g` for precision `p`.
$decl put_g $func ($decl b text, $decl v 0, $decl x 0, $decl p 0) {
  $decl l   $call count_digits (v, 10, 1)
  $decl ret $if ($call C.or ($call lt (x, -4), $call C.not ($call lt (x, p)))) {
      $decl u    $call small_pow (10, $call sub (l, 1), 1)
      $decl ret2 $do ($call put_mag (b, $call div (v, u), 10))
          ($do ($if ($call lt (1, l))
                    ($do ($call b.write (".")) ($call zeros (b, $call mod (v, u), $call sub (l, 1))))
                    ())
               ($do ($call b.write ($if ($call lt (x, 0)) "e-" "e+"))
                    ($call zeros (b, $if ($call lt (x, 0)) ($call neg (x)) x, 2))))
    }.ret2
    ($if ($call lt (x, 0))
         ($do ($call b.write ("0."))
              ($do ($call times (b, "0", $call sub ($call neg (x), 1))) ($call put_mag (b, v, 10))))
    ($if ($call lt (x, l)) {
      $decl u    $call small_pow (10, $call sub (l, $call add (x, 1)), 1)
      $decl ret2 $do ($call put_mag (b, $call div (v, u), 10))
          ($do ($call b.write ("."))
               ($call zeros (b, $call mod (v, u), $call sub (l, $call add (x, 1)))))
    }.ret2
    ($do ($call put_mag (b, v, 10))
         ($do ($call times (b, "0", $call sub (x, $call sub (l, 1)))) ($call b.write (".0"))))))
}.ret

// §8's `to_str` on a `Float`, written.
$decl float $func ($decl b text, $decl x 0.0)
  $if ($call C.not ($call eq ($call sub (x, x), 0.0))) ($call nonfinite (b, x)) {
    $decl minus $call C.or ($call lt (x, 0.0),
                    $call C.and ($call eq (x, 0.0), $call lt ($call div (1.0, x), 0.0)))
    $decl a     $if minus ($call neg (x)) x
    $decl ret2  $do ($if minus ($call b.write ("-")) ())
        ($if ($call eq (a, 0.0)) ($call b.write ("0.0")) {
          $decl sp   $call split_go (a, 0)
          $decl nm   $call norm (sp.m, sp.e)
          $decl s    $call shortest (nm.m, nm.e,
                         $call fix_exp (nm.m, nm.e, $call est_exp (nm.m, nm.e)), 15)
          $decl z    $call strip (s.d, 0)
          $decl ret3 $call put_g (b, z.v, s.x, s.prec)
        }.ret3)
  }.ret2

// ---------------------------------------------------------------- primitives, by type

// Any of the four by its type, resolved at compile time (§4.8). `Bool` is `true | false`
// and no subtype of `Int` (§3.2), so the candidates cannot overlap.
$decl put $overload (int, float, str, bool)
