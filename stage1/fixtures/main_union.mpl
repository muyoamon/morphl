// The entry point prints what stage 0 prints, by value. This `main` answers a union — §4.7's
// catch-all does not narrow, so `$case r r` is the whole `<Int, {w}>` — and the value is the
// `Int`: printed by its tag (`main_out`). It used to be cast to `long long`, which `cc`
// refused after `mplc` had reported success. A member stage 0 cannot print either is
// reported on stderr if it ever arrives.
$decl g $func ($decl b false) $if b { $prop tag "w" $decl q "s" } { $prop tag "v" $decl n 5 }
$decl f $func ($decl b false) {
  $decl r   $try ($call g (b)) { $prop tag "w" }
  $decl ret r.n
}.ret
$decl main $func () {
  $decl r   $call f (false)
  $decl ret $match r ($case {$prop tag "w"} 0, $case r r)
}.ret
