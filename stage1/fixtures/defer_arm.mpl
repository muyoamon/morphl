// DEFER.md example 10: a `$new` block in an `$if` or `$match` arm runs its deferrals only
// if that arm ran. The compiler gives each such site a flag, set false where its item
// starts and true once the storage is made; stage 0 decides at run time, from which `$new`
// ran. Each deferral appends a digit, so the answer is the order.
$decl log  $mut $alloc 0
$decl ival $func ($decl x 0) x
$decl say  $func ($decl d 0) $set log ($call add ($call mul ($call ival (log), 10), d))
$decl use  $func ($decl c $new { $decl k 0 }) c.k
// Owned by `p`: one of the two at the scope's end, after the body.
$decl pick $func ($decl c $union (false, true)) {
  $decl p   $if c ($new { $decl k 1  $defer $call say (1) })
                  ($new { $decl k 2  $defer $call say (2) })
  $decl x   $call say (9)
  $decl ret p.k
}.ret
// Ephemeral: one of the two at the end of the item.
$decl eph $func ($decl c $union (false, true)) {
  $decl u   $call use ($if c ($new { $decl k 3  $defer $call say (3) })
                             ($new { $decl k 4  $defer $call say (4) }))
  $decl x   $call say (8)
  $decl ret u
}.ret
// `$match` arms, owned by `q`.
$decl opt $func ($decl s "") {
  $decl o   $call str_to_int (s)
  $decl q   $match o (
      $case {$prop tag "some"} ($new { $decl k o.v  $defer $call say (5) }),
      $case o                  ($new { $decl k 0    $defer $call say (6) })
    )
  $decl x   $call say (7)
  $decl ret q.k
}.ret
// A `$try` in the arm not taken by the other site: the first literal never ran, so
// returning runs nothing of it.
$decl tr $func ($decl c $union (false, true)) {
  $decl q   $if c ($new { $decl k 1  $defer $call say (1) })
                  ($do ($try ($call str_to_int ("x")) none)
                       ($new { $decl k 2  $defer $call say (2) }))
  $decl ret q.k
}.ret
$decl main $func () {
  $decl a   $call pick (true)
  $decl b   $call pick (false)
  $decl c   $call eph (true)
  $decl d   $call eph (false)
  $decl e   $call opt ("7")
  $decl f   $call opt ("y")
  $decl g   $call tr (false)
  $decl h   $call tr (true)
  $decl ret $call ival (log)
}.ret
