// §8's byte type and `view`, and the FFI group, all reached through `$primitives`
// (TEXT.md, step 4). Compiled only: stage 0 refuses them (BOOTSTRAP 1.2).
$decl to_u8  $primitives.to_u8
$decl of_u8  $primitives.of_u8
$decl view   $primitives.view
$decl to_str $primitives.to_str
$decl concat $primitives.concat

// One byte written through `unbox`, which an example of the byte type makes `&^mut u8`.
$decl put $func ($decl p 0, $decl i 0, $decl c 0)
  $set ($call $primitives.unbox ($call add (p, i), $primitives.u8)) ($call to_u8 (c))
$decl fill $func ($decl p 0, $decl i 0, $decl n 0)
  $if ($call lt (i, n))
      ($do ($call put (p, i, $call add (97, i))) ($call fill (p, $call add (i, 1), n))) ()

// A: bytes written into raw memory, read back as a `Str` with no copy.
$decl case_a $func () {
  $decl p   $call $primitives.raw_alloc (5)
  $decl w   $call fill (p, 0, 5)
  $decl s   $call view (p, 5)
  $decl ok  $if ($call eq (s, "abcde")) 1 0
  $decl f   $call $primitives.raw_free (p)
  $decl ret ok
}.ret

// B: a byte round-trips its `Int`.
$decl case_b $func () $call of_u8 ($call to_u8 (200))

// C: an array of bytes is laid out a byte apart, so a view over it reads them in order.
$decl case_c $func () {
  $decl a   $call array (3, $primitives.u8)
  $decl s1  $set ($call at (a, 0)) ($call to_u8 (65))
  $decl s2  $set ($call at (a, 1)) ($call to_u8 (66))
  $decl s3  $set ($call at (a, 2)) ($call to_u8 (67))
  $decl s   $call view ($call $primitives.array_ptr (a), $call alen (a))
  $decl ret $if ($call eq (s, "ABC")) $call of_u8 ($call at (a, 1)) 0
}.ret

// D: a view of a literal's own bytes.
$decl case_d $func () $call len ($call view ($call $primitives.str_ptr ("hey"), 2))

// E: storage's address and back.
$decl case_e $func () {
  $decl c   $mut $alloc $primitives.u8
  $decl w   $set ($call $primitives.unbox ($call $primitives.box_ptr (c), $primitives.u8))
                ($call to_u8 (9))
  $decl ret $call of_u8 (c)
}.ret

// F: both conversions as values, through a function that takes them.
$decl apply $func ($decl f of_u8, $decl g to_u8, $decl n 0) $call f ($call g (n))
$decl case_f $func () $call apply (of_u8, to_u8, 42)

// G: `str_from_ptr` copies and validates.
$decl case_g $func () $match ($call $primitives.str_from_ptr ($call $primitives.str_ptr ("hello"), 4)) (
  $case {$prop tag "some"} 4,
  $case () 0
)

$decl main $func ()
  $call concat ($call to_str ($call case_a ()), $call concat ($call to_str ($call case_b ()),
    $call concat ($call to_str ($call case_c ()), $call concat ($call to_str ($call case_d ()),
    $call concat ($call to_str ($call case_e ()), $call concat ($call to_str ($call case_f ()),
    $call to_str ($call case_g ())))))))
