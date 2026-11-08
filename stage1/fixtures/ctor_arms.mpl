// §5.3a: a body whose arms each call one constructor constructs, and forwards to it — the
// caller's storage holds that constructor's block whichever arm ran, so its deferrals are
// that constructor's (STORAGE.md R3). It used to be refused as a choice between
// constructions; arms calling two constructors still are. One reached through an alias is
// the same one (`ctor_alias.mpl`).
//
// u1u2g3g5g62qpq 12356270:
//   u1 u2       `pick`'s `$if` arms; each block's deferral runs where `use` ends, after "u";
//   g3 g5 g6    `graded`'s `$match` arms, one of them an `$if` of its own;
//   2           `take` handed `pick2`, which forwards to `pick`, released once `take` returns;
//               `take`'s default is a call to `pick`, so the argument is not read through;
//   qp q        `either` over a constructor that can fail: built, its deferral runs after
//               "q"; failed, nothing was built and nothing runs.
// The number is each call's answer, a digit apiece; the last is the failed parse's 0.

$decl log $mut $alloc ""
$decl say $func ($decl s "") $set log ($call concat (log, s))

$decl mk $func ($decl n 0) $new {
  $decl v n
  $defer $call say ($call int_to_str (v))
}

$decl pick  $func ($decl c $union (false, true)) $if c ($call mk (1)) ($call mk (2))
$decl pick2 $func ($decl c $union (false, true)) $call pick (c)

$decl use $func ($decl c $union (false, true)) {
  $decl r   $call pick (c)
  $decl z   $call say ("u")
  $decl ret r.v
}.ret

$decl grades $union ({ $prop tag "lo" }, { $prop tag "mid" }, { $prop tag "hi" })
$decl grade  $func ($decl g grades, $decl c $union (false, true))
  $match g ($case { $prop tag "lo" } ($call mk (3)),
            $case { $prop tag "mid" } ($if c ($call mk (4)) ($call mk (5))),
            $case { $prop tag "hi" } ($call mk (6)))

$decl graded $func ($decl g grades, $decl c $union (false, true)) {
  $decl r   $call grade (g, c)
  $decl z   $call say ("g")
  $decl ret r.v
}.ret

$decl take $func ($decl r $call pick (true)) r.v

$decl parse $func ($decl s "") $new {
  $prop tag "ok"
  $decl n ($try ($call str_to_int (s)) none).v
  $defer $call say ("p")
}
$decl either $func ($decl s "", $decl c $union (false, true))
  $if c ($call parse (s)) ($call parse ("x"))

$decl parsed $func ($decl s "", $decl c $union (false, true)) {
  $decl r   $call either (s, c)
  $decl z   $call say ("q")
  $decl ret $match r ($case { $prop tag "none" } 0, $case { $prop tag "ok" } r.n)
}.ret

$decl digit $func ($decl acc 0, $decl d 0) $call add ($call mul (acc, 10), d)

$decl main $func () {
  $decl a   $call use (true)
  $decl b   $call use (false)
  $decl g1  $call graded ({ $prop tag "lo" }, true)
  $decl g2  $call graded ({ $prop tag "mid" }, false)
  $decl g3  $call graded ({ $prop tag "hi" }, true)
  $decl t   $call take ($call pick2 (false))
  $decl p   $call parsed ("7", true)
  $decl q   $call parsed ("7", false)
  $decl n   $call digit ($call digit ($call digit ($call digit ($call digit ($call digit (
                $call digit ($call digit (0, a), b), g1), g2), g3), t), p), q)
  $decl ret $call concat (log, $call concat (" ", $call int_to_str (n)))
}.ret
