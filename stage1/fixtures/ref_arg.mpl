// SPEC §5.4: a reference reads as its pointee where a value is expected, and a parameter
// that is storage does not expect one — `&T`, or a union with a storage member, which is
// what a constructor that can fail answers (`<&T, none>`, §5.3a). Read through, that
// argument was `<T, none>`, and the checker refused a call whose types matched exactly; so
// it is passed as it is, in all three implementations, and a callee handing the place back
// passes ownership as it would for `&T`. The log is "1762": `n_of` consumes `parse ("6")`'s
// block, `pass` hands `parse ("7")`'s to `p`, which releases it after `say (1)`.
$decl log  $mut $alloc ""
$decl sval $func ($decl x "") x
$decl say  $func ($decl d 0) $set log ($call concat ($call sval (log), $call int_to_str (d)))
$decl parse $func ($decl src "") $new {
  $prop tag "ok"
  $decl n   ($try ($call str_to_int (src)) none).v
  $defer    $call say (n)
}
$decl n_of $func ($decl r $call parse ("0")) $match r (
  $case {$prop tag "none"} 0,
  $case {$prop tag "ok"}   r.n
)
// Hands the place back: ownership passes through the call (DEFER.md example 7).
$decl pass $func ($decl r $call parse ("0")) r
$decl take $func ($decl r $if true ($new { $prop tag "ok"  $decl n 0 }) none) $match r (
  $case {$prop tag "none"} 0,
  $case {$prop tag "ok"}   r.n
)
$decl c    $func ($decl c $union (true, false)) {
  $decl s   $if c ($new { $prop tag "ok"  $decl n 4 }) none
  $decl ret $call take (s)
}.ret
$decl main $func () {
  $decl s   $call parse ("5")
  $decl a   $call n_of (s)
  $decl b   $call n_of ($call parse ("x"))
  $decl d   {
    $decl p    $call pass ($call parse ("7"))
    $decl ret2 $call say (1)
  }.ret2
  $decl e   $call n_of ($call parse ("6"))
  $decl f   $call say (2)
  $decl ret $call concat ($call sval (log), $call concat (" ",
              $call int_to_str ($call add (a, $call add (b, $call add ($call c (true),
                  $call c (false)))))))
}.ret
