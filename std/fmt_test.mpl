// std/fmt's tests, as inline checks run by `std/test`: `mplc std/fmt_test.mpl -L . -o …`
// from the repository root. A failure is reported on stderr and aborts; `main` answers how
// many passed, which `zig build test-std` compares.

$decl C $import "std/core"
$decl F $import "std/fmt"
$decl L $import "std/list"
$decl S $import "std/str"
$decl T $import "std/test"

$decl ints $specialize L.list 0

// A block with a `show` member, and one whose `show` shows its fields through theirs.
// A field may not be initialised from a same-named outer binding (§4.1), hence `px`.
$decl point $func ($decl px 0, $decl py 0) {
  $decl p   {
    $decl x px
    $decl y py
    $prop show $func ($decl b F.builder)
      $do ($call b.write ("("))
          ($do ($call F.int (b, p.x))
               ($do ($call b.write (", ")) ($do ($call F.int (b, p.y)) ($call b.write (")")))))
  }
  $decl ret p
}.ret
$decl segment $func ($decl pa ($call point (0, 0)), $decl pz ($call point (0, 0))) {
  $decl s   {
    $decl a pa
    $decl z pz
    $prop show $func ($decl b F.builder)
      $do ($call F.show (b, s.a)) ($do ($call b.write (" -> ")) ($call F.show (b, s.z)))
  }
  $decl ret s
}.ret

// Through a trait object, for when the type is not known until run time.
$decl via_object $func ($decl x F.showable) {
  $decl b   $call S.builder ()
  $decl w   $call x.show (b)
  $decl ret $call b.build ()
}.ret

// What one writer produced, alone.
$decl one $func ($decl f $func ($decl b F.builder) ()) {
  $decl b   $call S.builder ()
  $decl w   $call f (b)
  $decl ret $call b.build ()
}.ret
$decl is $func ($decl f $func ($decl b F.builder) (), $decl want "") $call eq ($call one (f), want)

// Doubles a literal cannot spell — there is no exponent — made exactly: scaling by two is
// exact until the range runs out.
$decl twice $func ($decl x 0.0, $decl n 0)
  $if ($call eq (n, 0)) x ($call twice ($call mul (x, 2.0), $call sub (n, 1)))
$decl halve $func ($decl x 0.0, $decl n 0)
  $if ($call eq (n, 0)) x ($call halve ($call div (x, 2.0), $call sub (n, 1)))
$decl fmax   $call mul ($call sub (2.0, $call halve (1.0, 52)), $call twice (1.0, 1023))
$decl tiny_f $call halve (1.0, 1074)

$decl main $func () {
  $decl r   $call T.results ()
  $decl c1  $call T.expect (r, "int", $call is ($func ($decl b F.builder) $call F.int (b, -42), "-42"))
  $decl c2  $call T.expect (r, "float", $call C.and (
                $call is ($func ($decl b F.builder) $call F.float (b, 2.5), "2.5"),
                $call is ($func ($decl b F.builder) $call F.float (b, 3.0), "3.0")))
  $decl c3  $call T.expect (r, "str and bool", $call is ($func ($decl b F.builder)
                $do ($call F.str (b, "ok "))
                    ($do ($call F.bool (b, true)) ($call F.bool (b, $call eq (1, 2)))),
                "ok truefalse"))
  $decl c4  $call T.expect (r, "code", $call is ($func ($decl b F.builder)
                $do ($call F.code (b, 233)) ($call F.code (b, 55296)), "é\u{fffd}"))
  $decl c5  $call T.expect (r, "put, by type", $call is ($func ($decl b F.builder)
                $do ($call F.put (b, 1))
                    ($do ($call F.put (b, " "))
                         ($do ($call F.put (b, 0.5)) ($call F.put (b, false)))), "1 0.5false"))
  $decl p   $call point (3, -4)
  $decl c6  $call T.expect (r, "render a show member", $call eq ($call F.render (p), "(3, -4)"))
  $decl sg  $call segment ($call point (1, 2), p)
  $decl c7  $call T.expect (r, "...nested", $call eq ($call F.render (sg), "(1, 2) -> (3, -4)"))
  $decl c8  $call T.expect (r, "show into a builder in use", $call is ($func ($decl b F.builder)
                $do ($call b.write ("p = ")) ($call F.show (b, p)), "p = (3, -4)"))
  $decl xs  $call ($call ($call ($call ints.empty ()).push (3)).push (2)).push (1)
  $decl c9  $call T.expect (r, "sep_by", $call is ($func ($decl b F.builder)
                $call F.sep_by (b, xs, ", ", F.int), "1, 2, 3"))
  $decl c10 $call T.expect (r, "sep_by of nothing", $call is ($func ($decl b F.builder)
                $call F.sep_by (b, $call ints.empty (), ", ", F.int), ""))
  $decl c11 $call T.expect (r, "hex", $call C.and (
                $call is ($func ($decl b F.builder) $call F.hex (b, 255), "ff"),
                $call is ($func ($decl b F.builder) $call F.hex (b, 0), "0")))
  $decl c12 $call T.expect (r, "radix", $call C.and (
                $call is ($func ($decl b F.builder) $call F.radix (b, 10, 2), "1010"),
                $call is ($func ($decl b F.builder) $call F.radix (b, -5, 10), "-5")))
  $decl c13 $call T.expect (r, "...at the ends of Int", $call C.and (
                $call is ($func ($decl b F.builder)
                    $call F.hex (b, -9223372036854775808), "-8000000000000000"),
                $call is ($func ($decl b F.builder)
                    $call F.radix (b, 9223372036854775807, 36), "1y2p0ij32e8e7")))
  $decl c14 $call T.expect (r, "pad_left and pad_right", $call C.and (
                $call is ($func ($decl b F.builder) $call F.pad_left (b, "ab", 5, "."), "...ab"),
                $call is ($func ($decl b F.builder) $call F.pad_right (b, "ab", 4, " "), "ab  ")))
  $decl c15 $call T.expect (r, "...counts code points, and never cuts", $call C.and (
                $call is ($func ($decl b F.builder) $call F.pad_left (b, "é", 3, " "), "  é"),
                $call is ($func ($decl b F.builder) $call F.pad_left (b, "abcd", 2, " "), "abcd")))
  $decl c16 $call T.expect (r, "zeros", $call C.and (
                $call is ($func ($decl b F.builder) $call F.zeros (b, 7, 3), "007"),
                $call is ($func ($decl b F.builder) $call F.zeros (b, -7, 4), "-007")))
  $decl c17 $call T.expect (r, "quoted", $call is ($func ($decl b F.builder)
                $call F.quoted (b, "say \"hi\"\n\\ é\u{1}"), "\"say \\\"hi\\\"\\n\\\\ é\\u{1}\""))
  $decl c18 $call T.expect (r, "quoted plain", $call is ($func ($decl b F.builder)
                $call F.quoted (b, "plain"), "\"plain\""))
  $decl c19 $call T.expect (r, "a showable object", $call eq ($call via_object (sg), "(1, 2) -> (3, -4)"))
  // Checked against C's `%.*f`: ties to even on the double's exact value, so 2.675 (just
  // below) goes down and 0.125 (exact) goes to the even 2.
  $decl c20 $call T.expect (r, "fixed rounds the exact value", $call C.and (
                $call eq ($call F.fixed_str (2.675, 2), "2.67"),
                $call C.and ($call eq ($call F.fixed_str (0.125, 2), "0.12"),
                $call C.and ($call eq ($call F.fixed_str (0.375, 2), "0.38"),
                             $call eq ($call F.fixed_str (9.995, 2), "9.99")))))
  $decl c21 $call T.expect (r, "...ties to even at no decimals", $call C.and (
                $call eq ($call F.fixed_str (2.5, 0), "2"),
                $call C.and ($call eq ($call F.fixed_str (3.5, 0), "4"),
                $call C.and ($call eq ($call F.fixed_str (0.5, 0), "0"),
                             $call eq ($call F.fixed_str (1.0, 0), "1")))))
  $decl c22 $call T.expect (r, "...and the sign is kept", $call C.and (
                $call eq ($call F.fixed_str (-1.5, 0), "-2"),
                $call C.and ($call eq ($call F.fixed_str (-0.0, 1), "-0.0"),
                $call C.and ($call eq ($call F.fixed_str (-0.001, 2), "-0.00"),
                             $call eq ($call F.fixed_str (0.0, 3), "0.000")))))
  $decl c23 $call T.expect (r, "...digits past the double's own", $call C.and (
                $call eq ($call F.fixed_str (0.1, 20), "0.10000000000000000555"),
                $call C.and ($call eq ($call F.fixed_str (123.456, 3), "123.456"),
                             $call eq ($call F.fixed_str (0.0000001, 3), "0.000"))))
  $decl c24 $call T.expect (r, "...big whole numbers", $call C.and (
                $call eq ($call F.fixed_str (10000000000000000000000.0, 1), "10000000000000000000000.0"),
                $call eq ($call F.fixed_str (fmax, 0), "179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368")))
  $decl tiny $call F.fixed_str (tiny_f, 1074)
  $decl c25 $call T.expect (r, "...the smallest subnormal, every digit", $call C.and (
                $call eq ($call len (tiny), 1076),
                $call C.and ($call eq ($call slice (tiny, 0, 8), "0.000000"),
                             $call eq ($call slice (tiny, 1056, 1076), "19718265533447265625"))))
  $decl c26 $call T.expect (r, "...not a number, nor infinite", $call C.and (
                $call eq ($call F.fixed_str ($call div (0.0, 0.0), 2), "nan"),
                $call C.and ($call eq ($call F.fixed_str ($call div (1.0, 0.0), 2), "inf"),
                             $call eq ($call F.fixed_str ($call div (-1.0, 0.0), 2), "-inf"))))
  $decl c27 $call T.expect (r, "fixed writes into the builder",
                $call is ($func ($decl b F.builder) $call F.fixed (b, 3.14159, 2), "3.14"))
  $decl ret $call T.finish (r)
}.ret
