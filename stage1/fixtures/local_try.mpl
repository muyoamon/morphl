// §4.15's `$try` inside a `$func` a block binds, or one written as a value. Inference widens
// such a function's result to carry what its `$try`s return, as it does a top-level one's;
// lowering derives a literal's result from its body, which knows nothing of the exits, so
// emit was asked to coerce `none` into `Int` and refused. Each case is one digit.
$decl outer $func ($decl k 0) {
  $decl half $func ($decl n 0)
    $if ($call eq_int ($call mod (n, 2), 0)) ($call div (n, 2)) none
  // 1. A local `$func` with two exits.
  $decl quarter $func ($decl n 0) {
    $decl h   $try ($call half (n)) none
    $decl ret $try ($call half (h)) none
  }.ret
  $decl q1 $call quarter (k)
  $decl d1 $match q1 ($case {$prop tag "none"} 0, $case 0 q1)
  // 2. One that names itself, so it is lowered twice: the exit is in both passes' result.
  $decl halves $func ($decl n 0, $decl c 0)
    $if ($call eq_int (n, 1)) c
        ($call halves ($try ($call half (n)) none, $call add (c, 1)))
  $decl q2 $call halves ($call add (k, 12), 0)
  $decl d2 $match q2 ($case {$prop tag "none"} 7, $case 0 q2)
  // 3. An anonymous literal, called through a parameter.
  $decl app $func ($decl f $func ($decl n 0) $if true 0 none, $decl n 0) $call f (n)
  $decl q3 $call app ($func ($decl n 0) $call add ($try ($call half (n)) none, 1),
                      $call div (k, 2))
  $decl d3 $match q3 ($case {$prop tag "none"} 3, $case 0 q3)
  // 4. A `$try` belongs to its nearest `$func`: the inner literal's exit does not widen the
  // outer, whose result stays `Int` and is added to directly.
  $decl wrap $func ($decl n 0) {
    $decl inner $func ($decl m 0) $try ($call half (m)) none
    $decl q4    $call inner (n)
    $decl ret   $match q4 ($case {$prop tag "none"} 4, $case 0 q4)
  }.ret
  $decl d4 $call add ($call wrap (7), 0)
  // 5. A `$try` leaving through a `$defer` (§4.15a), which runs on either exit: this was
  // the shape the sweep's lifted `defer.mpl` hit, emitted as a read of a field `none`
  // does not have.
  $decl log  $mut $alloc 0
  $decl five $func ($decl n 0) {
    $defer    $set log ($call add (log, 1))
    $decl h   $try ($call half (n)) none
    $decl ret h
  }.ret
  $decl q5 $call five ($call div (k, 2))
  $decl d5 $call add ($match q5 ($case {$prop tag "none"} 5, $case 0 3), log)
  $decl ret $call add ($call mul (d1, 10000), $call add ($call mul (d2, 1000),
              $call add ($call mul (d3, 100), $call add ($call mul (d4, 10), d5))))
}.ret

$decl main $func () $call add ($call mul ($call outer (20), 10), $call outer (6))
