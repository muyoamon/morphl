// §4.12's `$impl` over a union: a `with` laid out as the union, carrying methods — the shape
// a result type with members wants. It is a subtype of the bare union, so it passes where
// that is expected (`is_ok_u (w)`); `$match` and `$try` narrow it as the union, keeping the
// props, so an arm's value and what a `$try` returns still answer the methods; and a field
// of the narrowed member is read where the union has it.
//
// 91147: 5 and 100 from `value_or`, 1000 from `is_ok`, 42 from a `$try` that let an `ok`
// through, 3 × 10000 from the `err` it returned instead; then 40000 from `is_ok` and
// `value_or` asked of an arm's narrowed `ok`, and 20000 from the same two asked of the `err`
// a `$try` returned — false, and `value_or`'s default. A method on a narrowed member takes
// its receiver as a copy injected back into the union, since the member's layout has no
// discriminator.

$decl result $template (T, E) {
  $prop shape { $prop is_ok $func () $union (true, false)  $prop value_or $func ($decl d T) d }
  $prop is_ok_u $func ($decl r $union ({ $prop tag "ok" $decl v T }, { $prop tag "err" $decl e E }))
    $match r ($case {$prop tag "ok"} true, $case r false)
  $prop value_or_u $func ($decl r $union ({ $prop tag "ok" $decl v T }, { $prop tag "err" $decl e E }),
                         $decl d T)
    $match r ($case {$prop tag "ok"} r.v, $case r d)
  // One `$impl` site, so every result has the same props and so one type.
  $prop wrap $func ($decl r $union ({ $prop tag "ok" $decl v T }, { $prop tag "err" $decl e E })) {
    $decl w $impl r ($traitsof shape) {
      $prop is_ok    $func () $call is_ok_u (w)
      $prop value_or $func ($decl d T) $call value_or_u (w, d)
    }
  }.w
  $prop ok  $func ($decl x T) $call wrap ({ $prop tag "ok"  $decl v x })
  $prop err $func ($decl x E) $call wrap ({ $prop tag "err" $decl e x })
}

$decl ri $specialize result (0, "")

$decl pick $func ($decl n 0) $if ($call lt (n, 0)) ($call ri.err ("neg")) ($call ri.ok (n))

$decl twice $func ($decl n 0) {
  $decl r    $try ($call pick (n)) err
  $decl ret  $call mul (r.v, 2)
}.ret

$decl main $func () {
  $decl a   $call pick (5)
  $decl b   $call pick (-1)
  $decl t   $call twice (21)
  $decl tv  $match t ($case 0 t, $case t 0)
  $decl u   $call twice (-3)
  $decl uv  $match u ($case {$prop tag "err"} $call len (u.e), $case u 0)
  $decl an  $match a (
      $case {$prop tag "ok"}
        $call add ($if ($call a.is_ok ()) 100000 0, $call mul ($call a.value_or (7), 20000)),
      $case a 0)
  $decl ue  $match u (
      $case {$prop tag "err"}
        $call add ($if ($call u.is_ok ()) 1 10000, $call mul ($call u.value_or (1), 10000)),
      $case u 0)
  $decl ret $call add ($call a.value_or (0), $call add ($call b.value_or (100),
                $call add ($if ($call a.is_ok ()) 1000 0, $call add (tv,
                $call add ($call mul (uv, 10000), $call add ($call div (an, 5), ue))))))
}.ret
