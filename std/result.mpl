// std/result: a value or the failure that stopped it, carrying its own methods —
// `$specialize R.result <value example>, <error example>` per pair of types (STDLIB.md, D7):
//
//   $decl R    $import "std/result"
//   $decl ires $specialize R.result (0, "")
//   $decl r    $call ires.ok (5)            // or $call ires.err ("why")
//   $call r.is_ok ()   $call r.value_or (0)   $call r.unwrap ()
//
// A result is the union `<{tag ok, v T}, {tag err, e E}>` under an `$impl` (§4.12, STDLIB.md
// P15), so it is matched like any union — `$case {$prop tag "ok"} r.v` — and `$try r err`
// hands its failure up, since §5.1 keeps `{tag err, e E}` a subtype of the root block's
// `err`. A narrowed member keeps the methods. A function written over the bare union takes
// a result too, and `wrap` puts the methods on a bare union.
//
// The methods are the operations that keep both types. `map` and `map_err` change one, so
// they are templates on the specialisation rather than methods — `$call ires.map (r, f)` —
// since a template-valued member cannot read its receiver (D9) and §4.9 infers nothing
// from inside a union, which a free function's parameter would have to.
//
// Three things shape the template, all from P15. The members are tag blocks, because
// `$union (T, E)` is one type when `T` and `E` are. Every result is made at the one `$impl`
// in `wrap`, because each `$impl` site's props are identities of their own and so a type of
// their own. And the body is props only, so the generics are compile-time and a method
// captures nothing; the methods call the `_u` helpers, typed at the bare union, because a
// method's receiver is still being typed while its own body is.

$decl C $import "std/core"

$decl result $template (T, E) {
  $prop shape {
    $prop is_ok      $func () C.bool
    $prop is_err     $func () C.bool
    $prop value_or   $func ($decl d T) d
    $prop error_or   $func ($decl d E) d
    $prop unwrap     $func () T
    $prop unwrap_err $func () E
  }

  $prop is_ok_u $func (
      $decl r $union ({ $prop tag "ok" $decl v T }, { $prop tag "err" $decl e E }))
    $match r ($case {$prop tag "ok"} true, $case r false)
  $prop value_or_u $func (
      $decl r $union ({ $prop tag "ok" $decl v T }, { $prop tag "err" $decl e E }), $decl d T)
    $match r ($case {$prop tag "ok"} r.v, $case r d)
  $prop error_or_u $func (
      $decl r $union ({ $prop tag "ok" $decl v T }, { $prop tag "err" $decl e E }), $decl d E)
    $match r ($case {$prop tag "err"} r.e, $case r d)
  // An `err` here is a bug, not an expected failure (§4.15), so it panics.
  $prop unwrap_u $func (
      $decl r $union ({ $prop tag "ok" $decl v T }, { $prop tag "err" $decl e E }))
    $match r ($case {$prop tag "ok"} r.v, $case r ($call panic ("unwrap of an err result")))
  $prop unwrap_err_u $func (
      $decl r $union ({ $prop tag "ok" $decl v T }, { $prop tag "err" $decl e E }))
    $match r ($case {$prop tag "err"} r.e, $case r ($call panic ("unwrap_err of an ok result")))

  // The bare union with the methods on it. The one `$impl` site (see above).
  $prop wrap $func ($decl r $union ({ $prop tag "ok" $decl v T }, { $prop tag "err" $decl e E })) {
    $decl w $impl r ($traitsof shape) {
      $prop is_ok      $func () $call is_ok_u (w)
      $prop is_err     $func () $call C.not ($call is_ok_u (w))
      $prop value_or   $func ($decl d T) $call value_or_u (w, d)
      $prop error_or   $func ($decl d E) $call error_or_u (w, d)
      $prop unwrap     $func () $call unwrap_u (w)
      $prop unwrap_err $func () $call unwrap_err_u (w)
    }
  }.w

  $prop ok  $func ($decl x T) $call wrap ({ $prop tag "ok"  $decl v x })
  $prop err $func ($decl x E) $call wrap ({ $prop tag "err" $decl e x })

  // `f` of the value, or the failure unchanged: a result of `f`'s type `B`, inferred from
  // `f` (§4.9), and `E`.
  $prop map $template B
    $func ($decl r $union ({ $prop tag "ok" $decl v T }, { $prop tag "err" $decl e E }),
           $decl f $func ($decl x T) B) $match r (
      $case {$prop tag "ok"}  $call ($specialize result (B, E)).ok ($call f (r.v)),
      $case {$prop tag "err"} $call ($specialize result (B, E)).err (r.e)
    )
  // The value unchanged, or `f` of the failure: a result of `T` and `f`'s type `F`.
  $prop map_err $template F
    $func ($decl r $union ({ $prop tag "ok" $decl v T }, { $prop tag "err" $decl e E }),
           $decl f $func ($decl x E) F) $match r (
      $case {$prop tag "err"} $call ($specialize result (T, F)).err ($call f (r.e)),
      $case {$prop tag "ok"}  $call ($specialize result (T, F)).ok (r.v)
    )
}
