// §2.3: `()` is the top type and `{}` the top of blocks, and §4.7 makes each a pattern:
// `$case ()` covers any scrutinee, named or not, and `$case {}` every member that is a
// block.
//
// 1 + 20 + 300 + 4000 + 50000 + 600000 = 654321: a `$case ()` after a specific arm on an
// unnamed scrutinee, `$case {}` taking both block members of a union while `Int` takes its
// own arm, a parameter defaulted to `()` taking an `Int`, a `Str` and a block, `$if c 5 ()`
// keeping its `Int` (a join does not absorb into a top, §3.6), and `$case ()` as a
// scrutinee's whole match.

$decl pick $func ($decl n 0)
  $if ($call lt (n, 0)) { $prop tag "neg" } { $prop tag "pos" $decl v n }

$decl first $func ($decl n 0)
  $match ($call pick (n)) ($case {$prop tag "neg"} 1, $case () 2)

$decl kind $func ($decl u $union (0, { $prop tag "a" }, { $prop tag "b" $decl v 0 }))
  $match u ($case 0 10, $case {} 20)

$decl ignore $func ($decl x ()) 100

$decl maybe $func ($decl c $union (false, true)) $if c 5 ()
$decl from_maybe $func ($decl c $union (false, true)) {
  $decl m   $call maybe (c)
  $decl ret $match m ($case 0 m, $case () 0)
}.ret

$decl whole $func ($decl s "") $match s ($case () 600000)

$decl main $func () {
  $decl a   $call first (-1)
  $decl b   $call kind ({ $prop tag "b" $decl v 3 })
  $decl c   $call add ($call ignore (1),
                $call add ($call ignore ("x"), $call ignore ({ $decl q 1 })))
  $decl d   $call mul ($call from_maybe (true), 800)
  $decl e   $call add ($call mul ($call kind (7), 3000),
                $call mul ($call kind ({ $prop tag "a" }), 1000))
  $decl f   $call whole ("y")
  $decl ret $call add ($call add ($call add (a, b), $call add (c, d)), $call add (e, f))
}.ret
