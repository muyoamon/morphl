// §5.3a, DEFER.md example 12: a top-level item calling a constructor through a value is the
// program's to own, as one naming it is — lowering asks inference (`note_ctor`), since the
// callee has no record to say so. Prints "e init main 11", then "a3 a2 b1 c5".
//   b1  through a top-level `$decl` holding the constructor its `$if` chose;
//   a2  through a block's field;
//   a3  through an `$if` written as the callee;
//   e   the same in an item binding nothing, whose storage dies at the item's end;
//   c5  another module's member, through its block's field, run after the entry's.
$decl U $import "ctor_top_util"

$decl mk  $func ($decl n 0) $new { $decl v n  $defer $call print ($call concat ("a",
              $call concat ($call int_to_str (v), " "))) }
$decl mk2 $func ($decl n 0) $new { $decl v n  $defer $call print ($call concat ("b",
              $call concat ($call int_to_str (v), " "))) }
$decl mke $func ($decl n 0) $new { $decl v n  $defer $call print ("e ") }

$decl chosen $if ($call lt (2, 1)) mk mk2
$decl kit    { $decl make mk }
$decl s1     $call chosen (1)
$decl s2     $call kit.make (2)
$decl s3     $call ($if ($call lt (1, 2)) mk mk2) (3)
$call ($if ($call lt (2, 1)) mk mke) (4)
$call print ("init ")
$decl main $func () {
  $decl r   $call print ("main ")
  $decl ret $call add (s1.v, $call add (s2.v, $call add (s3.v, U.t.v)))
}.ret
