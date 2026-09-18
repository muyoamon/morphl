// A linked list, monomorphic over Int, entirely inside the BOOTSTRAP.md §1
// subset. Run with `morphlc --run examples/list.mpl`.
//
// SPEC.md §12's list is generic and uses self-specialization ($specialize list
// U inside list) plus $call-time inference of A — both excluded by §1.1/§1.2.
// This is the version stage 1 can actually be written in, and it is the check
// that the subset is expressive enough to hold a compiler's data structures.

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))

// Recursive data, obtained the only way §5.5 offers: inference over a $union
// whose later member names the type being defined. Stage 0 never evaluates
// that member (§4.8a), so this costs the evaluator nothing.
$decl nil  { $prop tag "nil" }
$decl node $union (nil, { $prop tag "cons"  $decl head 0  $decl tail node })

$decl cons $func ($decl h 0, $decl t node)
  { $prop tag "cons"  $decl head h  $decl tail t }

// Every $match puts the specific arm first and ends in a catch-all, per
// BOOTSTRAP.md §4.1 and §4.2: first fit is semantic, and stage 0 cannot check
// exhaustiveness for itself.
$decl length $func ($decl xs node, $decl acc 0)
  $match xs (
    $case {$prop tag "cons"} $call length (xs.tail, $call add (acc, 1)),
    $case xs acc
  )

$decl sum $func ($decl xs node, $decl acc 0)
  $match xs (
    $case {$prop tag "cons"} $call sum (xs.tail, $call add (acc, xs.head)),
    $case xs acc
  )

$decl reverse $func ($decl xs node, $decl acc node)
  $match xs (
    $case {$prop tag "cons"} $call reverse (xs.tail, $call cons (xs.head, acc)),
    $case xs acc
  )

// The shape of a map: build reversed, then reverse. Both halves are tail
// recursive, so §7.7 keeps this in one frame however long the list is.
$decl double_all $func ($decl xs node, $decl acc node)
  $match xs (
    $case {$prop tag "cons"} $call double_all (xs.tail, $call cons ($call mul (2, xs.head), acc)),
    $case xs ($call reverse (acc, nil))
  )

$decl join $func ($decl xs node, $decl acc "")
  $match xs (
    $case {$prop tag "cons"}
      $call join (xs.tail, $call concat (acc, $call concat ($call int_to_str (xs.head), " "))),
    $case xs acc
  )

// [1 .. n]
$decl upto $func ($decl n 0, $decl acc node)
  $if ($call eq_int (n, 0)) acc ($call upto ($call sub (n, 1), $call cons (n, acc)))

$decl xs $call upto (6, nil)

$decl r1 $call nl ($call concat ("list    = ", $call join (xs, "")))
$decl r2 $call nl ($call concat ("length  = ", $call int_to_str ($call length (xs, 0))))
$decl r3 $call nl ($call concat ("sum     = ", $call int_to_str ($call sum (xs, 0))))
$decl r4 $call nl ($call concat ("doubled = ", $call join ($call double_all (xs, nil), "")))
$decl r5 $call nl ($call concat ("reverse = ", $call join ($call reverse (xs, nil), "")))

// Mandatory TCE is what makes this a loop rather than a stack overflow.
$decl big $call upto (50000, nil)
$decl r6 $call nl ($call concat ("sum 1..50000 = ", $call int_to_str ($call sum (big, 0))))
