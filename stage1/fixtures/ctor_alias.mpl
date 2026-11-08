// §5.3a: arms that call one constructor through different names forward to it — another
// name for a definition is that definition (`$decl h mk`), followed when the arms are
// compared, so the caller's storage holds that constructor's block whichever arm ran.
//
// uauaxafagaga 2 31 — each letter pair a call and its deferral, at its owner's end:
//   ua ua  `pick`'s arms, `mk` and its alias `h`, each way;
//   xa     `one`, forwarding through the alias alone;
//   fa     `deep`, through an alias of the alias;
//   ga ga  `graded`'s `$match` arms, `h2` and `mk`;
//   then the module's `hits`, counted by the two `pickm` calls, `U.um` against its alias
//   `um`, and a block's local constructor against its local alias in `local`.
// The numbers are `hits` and the calls' answers summed.

$decl U $import "ctor_alias_util"

$decl log $mut $alloc ""
$decl say $func ($decl s "") $set log ($call concat (log, s))

$decl mk  $func ($decl n 0) $new { $decl v n  $defer $call say ("a") }
$decl h   mk
$decl h2  h
$decl um  U.um

$decl pick   $func ($decl c $union (false, true), $decl n 0) $if c ($call mk (n)) ($call h (n))
$decl one    $func ($decl n 0) $call h (n)
$decl deep   $func ($decl c $union (false, true), $decl n 0) $if c ($call h2 (n)) ($call h (n))
$decl graded $func ($decl g $union ({ $prop tag "lo" }, { $prop tag "hi" }), $decl n 0)
  $match g ($case { $prop tag "lo" } ($call h2 (n)), $case { $prop tag "hi" } ($call mk (n)))
$decl pickm  $func ($decl c $union (false, true), $decl n 0) $if c ($call U.um (n)) ($call um (n))

$decl use $func ($decl c $union (false, true)) {
  $decl r   $call pick (c, 1)
  $decl z   $call say ("u")
  $decl ret r.v
}.ret
$decl via $func ($decl s "", $decl n 0) {
  $decl r   $call one (n)
  $decl z   $call say (s)
  $decl ret r.v
}.ret
$decl viad $func () {
  $decl r   $call deep (false, 3)
  $decl z   $call say ("f")
  $decl ret r.v
}.ret
$decl viag $func ($decl g $union ({ $prop tag "lo" }, { $prop tag "hi" })) {
  $decl r   $call graded (g, 4)
  $decl z   $call say ("g")
  $decl ret r.v
}.ret
$decl viam $func ($decl c $union (false, true)) {
  $decl r   $call pickm (c, 5)
  $decl ret r.v
}.ret
$decl local $func ($decl c $union (false, true)) {
  $decl lm  $func ($decl n 0) $new { $decl v n }
  $decl lh  lm
  $decl lp  $func ($decl n 0) $if c ($call lm (n)) ($call lh (n))
  $decl r   $call lp (6)
  $decl ret $call add (r.v, 0)
}.ret

$decl main $func () {
  $decl a   $call use (true)
  $decl b   $call use (false)
  $decl x   $call via ("x", 2)
  $decl f   $call viad ()
  $decl g1  $call viag ({ $prop tag "lo" })
  $decl g2  $call viag ({ $prop tag "hi" })
  $decl m1  $call viam (true)
  $decl m2  $call viam (false)
  $decl l   $call local (false)
  $decl ret $call concat (log, $call concat (" ", $call concat ($call int_to_str (U.hits),
                $call concat (" ", $call int_to_str ($call add (a, $call add (b, $call add (x,
                $call add (f, $call add (g1, $call add (g2, $call add (m1,
                $call add (m2, l)))))))))))))
}.ret
