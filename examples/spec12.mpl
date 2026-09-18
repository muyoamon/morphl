// Worked examples from SPEC.md §12, used as a parser fixture.
// Not all of these are in the BOOTSTRAP.md §1 subset — the parser covers the
// whole of §2.2; the subset restricts what stage-1 source may *use*.

// Counter and aliasing
$decl n $mut $new 0
$set n ($call add (n, 1))     // n : &mut Int, derefs in add
$decl y n                     // alias
$decl z $new n                // copy

// Tagged blocks and match
$decl circle { $prop kind "circle"  $decl r $new 1.0 }
$decl square { $prop kind "square"  $decl w $new 2.0 }
$decl area $func ($decl s $union (circle, square)) $match s (
  $case {$prop kind "circle"} $call mul (3.14, $call mul (s.r, s.r)),
  $case {$prop kind "square"} $call mul (s.w, s.w)
)

// Mutual recursion with $fwd
{
  $fwd odd
  $decl even $func ($decl n 0) $if ($call eq (n, 0)) true  ($call odd  ($call sub (n, 1)))
  $decl odd  $func ($decl n 0) $if ($call eq (n, 0)) false ($call even ($call sub (n, 1)))
}

// A loop
$decl while $func ($decl cond $func () true, $decl body $func () {})
  $if ($call cond ()) ($do ($call body ()) ($call while (cond, body))) {}

// Generic identity and inference
$decl id $template T $func ($decl x T) x
$call id 5
$specialize id "s"

// Overload as type-level switch
$decl show $overload (
  $func ($decl b true) $if b "yes" "no",
  $func ($decl n 0)    $call to_str (n)
)
$call show true
