// A stage-0 smoke test: run with `morphlc --run examples/loop.mpl`.
// Everything here is inside the BOOTSTRAP.md §1 subset.

// Loops are recursion (§7.7), and `$do` is what puts the recursive call after
// the effect in tail position (§4.8b).
$decl while $func ($decl cond $func () true, $decl body $func () {})
  $if ($call cond ()) ($do ($call body ()) ($call while (cond, body))) {}

$decl i $mut $new 1
$decl total $mut $new 0

$decl looped $call while (
  $func () ($call lt (i, 11)),
  $func () ($do ($set total ($call add (total, i)))
                ($set i ($call add (i, 1))))
)

$decl show $func ($decl label "", $decl n 0)
  $do ($call print (label))
      ($do ($call print ($call int_to_str (n))) ($call print ("\n")))

$decl p1 $call show ("sum 1..10 = ", total)

// From the core, per §8's sanity check.
$decl not $func ($decl b true) $match b ($case true false, $case false true)

// Tagged blocks and first-fit dispatch (§4.7, §4.10).
$decl circle { $prop kind "circle"  $decl r 3 }
$decl square { $prop kind "square"  $decl w 4 }
$decl area $func ($decl s $union (circle, square)) $match s (
  $case {$prop kind "circle"} $call mul (3, $call mul (s.r, s.r)),
  $case {$prop kind "square"} $call mul (s.w, s.w),
  $case s 0
)

$decl p2 $call show ("circle area = ", $call area (circle))
$decl p3 $call show ("square area = ", $call area (square))

// Error propagation: `$try` is the only non-local exit (§4.15).
$decl parse_or_zero $func ($decl s "")
  { $decl v $try ($call str_to_int (s)) none
    $decl out v.v }.out

$decl p4 $call show ("parsed 123 = ", $call parse_or_zero ("123"))
