// DEFER.md example 7: storage passed to a call that may hand it back is owned by the
// `$decl` binding the result only if the result reaches it — which the callee decides, so
// both stages decide at run time: stage 0 from the values, the compiler by comparing the
// addresses the result holds with the storage's. Otherwise it was ephemeral and its
// deferrals run at the end of the item. Each deferral appends a digit.
$decl log  $mut $alloc 0
$decl ival $func ($decl x 0) x
$decl say  $func ($decl d 0) $set log ($call add ($call mul ($call ival (log), 10), d))
$decl id   $func ($decl c $new { $decl k 0 }) c
$decl use  $func ($decl c $new { $decl k 0 }) c.k
$decl pick $func ($decl b $union (false, true), $decl x $new { $decl k 0 },
                  $decl y $new { $decl k 0 }) $if b x y
$decl wrap $func ($decl c $new { $decl k 0 }) { $decl r c }
$decl opt  $func ($decl b $union (false, true), $decl c $new { $decl k 0 }) $if b c 0
// Example 7: `a` owns it, so it runs at the end.                            "2 1"
$decl seven $func () {
  $decl a   $call id ($new { $decl k 7  $defer $call say (1) })
  $decl b   $call say (2)
  $decl ret a.k
}.ret
// Not handed back: at the end of its item.                                  "3 4"
$decl gone $func () {
  $decl a   $call use ($new { $decl k 1  $defer $call say (3) })
  $decl b   $call say (4)
  $decl ret a
}.ret
// The callee chooses: the other ends with the item, the one returned later.  "5 7 6"
$decl chosen $func ($decl c $union (false, true)) {
  $decl a   $call pick (c, $new { $decl k 1  $defer $call say (5) },
                           $new { $decl k 2  $defer $call say (6) })
  $decl b   $call say (7)
  $decl ret a.k
}.ret
// Through two calls, a record and a union; `p` holds none.                  "8 3 2 1 9"
$decl deep $func () {
  $decl a   $call id ($call id ($new { $decl k 1  $defer $call say (9) }))
  $decl r   $call wrap ($new { $decl k 2  $defer $call say (1) })
  $decl o   $call opt (true, $new { $decl k 3  $defer $call say (2) })
  $decl p   $call opt (false, $new { $decl k 4  $defer $call say (8) })
  $decl b   $call say (3)
  $decl ret a.k
}.ret
// A call in an arm, and the arm not taken.                                  "4 5"
$decl arm $func ($decl c $union (false, true)) {
  $decl a   $if c ($call id ($new { $decl k 1  $defer $call say (5) }))
                  ($new { $decl k 2  $defer $call say (6) })
  $decl b   $call say (4)
  $decl ret a.k
}.ret
$decl main $func () {
  $decl a   $call seven ()
  $decl b   $call gone ()
  $decl c   $call chosen (false)
  $decl d   $call deep ()
  $decl e   $call arm (true)
  $decl ret $call ival (log)
}.ret
