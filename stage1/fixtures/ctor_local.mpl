// §5.3a: a block's local constructor is a value too. Its value is a closure, and so is its
// shim, which captures the constructor's own pair, calls it and answers `{b, d}`; the `drop`
// reads only the block's fields, so it is the constructor's as ever.
//
// wawbkcpwpzuptqt 57739470 — each letter pair a call and its deferral, which runs at its
// owner's end:
//   wa  `with` passed a local constructor whose deferral says "a";
//   wb  another, capturing its frame's `k` in what it builds;
//   k   one with no deferrals, held in a block's field and called through it;
//   cp  a local alias of one, called by name, its deferral saying "p";
//   wpz `with` passed it by a `$func` that captures it;
//   up  the same constructor called by name beside its value's uses;
//   tq t  one that can fail, passed: built, its deferral runs; failed, nothing was built.
// The number is each call's answer, a digit apiece.

$decl log $mut $alloc ""
$decl say $func ($decl s "") $set log ($call concat (log, s))

$decl mk   $func ($decl n 0) $new { $decl v n }
$decl with $func ($decl make mk, $decl n 0) {
  $decl r   $call make (n)
  $decl z   $call say ("w")
  $decl ret r.v
}.ret

$decl parse $func ($decl s "") $new {
  $prop tag "ok"
  $decl n ($try ($call str_to_int (s)) none).v
}
$decl tryit $func ($decl p parse, $decl s "") {
  $decl r   $call p (s)
  $decl z   $call say ("t")
  $decl ret $match r ($case { $prop tag "none" } 0, $case { $prop tag "ok" } r.n)
}.ret

$decl run $func ($decl k 0) {
  $decl la  $func ($decl n 0) $new { $decl v n  $defer $call say ("a") }
  $decl lb  $func ($decl n 0) $new { $decl v $call add (n, k)  $defer $call say ("b") }
  $decl lc  $func ($decl n 0) $new { $decl v $call mul (n, 2) }
  $decl lp  $func ($decl n 0) $new { $decl v n  $defer $call say ("p") }
  $decl lq  $func ($decl s "") $new {
    $prop tag "ok"
    $decl n ($try ($call str_to_int (s)) none).v
    $defer $call say ("q")
  }
  $decl x1  $call with (la, 5)
  $decl x2  $call with (lb, 4)
  $decl kit { $decl make lc  $decl n 0 }
  $decl x3  {
    $decl r    $call kit.make (8)
    $decl z    $call say ("k")
    $decl ret2 $call sub (r.v, 9)
  }.ret2
  $decl h   lp
  $decl x4  {
    $decl r    $call h (3)
    $decl z    $call say ("c")
    $decl ret2 $call add (r.v, 0)
  }.ret2
  $decl pass $func ($decl n 0) {
    $decl r    $call with (lp, n)
    $decl z    $call say ("z")
    $decl ret2 r
  }.ret2
  $decl x5  $call pass (9)
  $decl x6  {
    $decl r    $call lp (4)
    $decl z    $call say ("u")
    $decl ret2 $call add (r.v, 0)
  }.ret2
  $decl x7  $call tryit (lq, "7")
  $decl x8  $call tryit (lq, "x")
  $decl ret $call concat ($call int_to_str (x1), $call concat ($call int_to_str (x2),
                $call concat ($call int_to_str (x3), $call concat ($call int_to_str (x4),
                $call concat ($call int_to_str (x5), $call concat ($call int_to_str (x6),
                $call concat ($call int_to_str (x7), $call int_to_str (x8))))))))
}.ret

$decl main $func () {
  $decl r   $call run (3)
  $decl ret $call concat (log, $call concat (" ", r))
}.ret
