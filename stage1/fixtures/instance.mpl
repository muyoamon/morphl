// §4.9's instance semantics, for a template whose body has `$decl`s.
//
// "Typing is memoized per argument type; values are not." A `$specialize` is
// evaluated where it stands, like a block literal written there, so each
// evaluation is a new instance with storage of its own, while its props — which
// are compile-time and part of the type — are shared.
//
// 1 + 6 + 6 + 102 + 1 + 6 + 14 + 4 = 140. Each term pins one rule; the comment
// on each says what the wrong answer would be.

$decl ival $func ($decl x 0) x

$decl cell $template T {
  $prop kind 7
  $prop wrap $func ($decl x T) x
  $decl v $mut $alloc T
  $decl get $func () $call ival (v)
}

// Two instances written in two places share nothing, though they share a type.
// 10 if `b` were `a`.
$decl a $specialize cell 1
$decl b $specialize cell 1
$decl two_sites $func ()
  { $decl w $set a.v 10
    $decl r $call b.get () }.r

// One written inside a `$func` is a new instance each time that function runs.
// The second call answers 7 if the storage survived the first.
$decl mk $func ($decl k 0)
  { $decl c $specialize cell k
    $decl w $set c.v ($call add ($call ival (c.v), 1))
    $decl r $call c.get () }.r

// One bound by a top-level `$decl` is evaluated once, and every use sees it.
// 101 if the second bump saw a fresh instance.
$decl g $specialize cell 100
$decl bump $func ()
  { $decl w $set g.v ($call add ($call ival (g.v), 1))
    $decl r $call g.get () }.r

// Step 1: an argument is evaluated once per evaluation of the `$specialize`, not
// once per mention of its generic. 2 if `T` re-ran `tick` at each mention.
$decl hits $mut $alloc 0
$decl tick $func ()
  { $decl w $set hits ($call add ($call ival (hits), 1))
    $decl r 3 }.r
$decl twice $template T { $decl x T  $decl y T }

$decl main $func ()
  { $decl s1 $call two_sites ()
    $decl s2 $call mk (5)
    $decl s3 $call mk (5)
    $decl s4 $do ($call bump ()) ($call bump ())
    $decl t2 $specialize twice $call tick ()
    $decl s5 $call ival (hits)
    $decl s6 $call add (t2.x, t2.y)
    // Props are shared: both instances carry `kind` in their type.
    $decl s7 $call add (a.kind, b.kind)
    $decl s8 $call a.wrap (4)
    $decl r $call add ($call add ($call add (s1, s2), $call add (s3, s4)),
                       $call add ($call add (s5, s6), $call add (s7, s8))) }.r
