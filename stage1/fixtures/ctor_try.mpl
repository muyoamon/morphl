// SPEC §5.3a, STORAGE.md R3: a constructor may hold a `$try`, and then it can fail. A `$try`
// that leaves runs the deferrals registered before it, in the constructor — the half-built
// block's — and the constructor answers what it matched; otherwise it answers the block, and
// the caller's owner releases it as it would any constructed block. So the call is the built
// reference or the failure, `<&T, none>`, and the caller runs the block's deferrals only when
// it was built. Each case appends digits to `log`, so the answer is the order.
$decl U    $import "ctor_util"
$decl log  $mut $alloc ""
$decl sval $func ($decl x "") x
$decl say  $func ($decl d 0) $set log ($call concat ($call sval (log), $call int_to_str (d)))

// `a` is registered before the `$try`, `n` after it.
$decl parse $func ($decl src "") $new {
  $prop tag "ok"
  $decl a   1
  $defer    $call say (a)
  $decl n   ($try ($call str_to_int (src)) none).v
  $defer    $call say (n)
}
// Forwarding, and two ways out: `none`, or `err` when `t` is "z".
$decl parse0 $func () $call parse ("x")
$decl chk    $func ($decl t "") $if ($call eq_str (t, "z")) err 5
$decl both   $func ($decl s "", $decl t "") $mut $new {
  $prop tag "ok"
  $decl m   ($try ($call str_to_int (s)) none).v
  $decl n   $try ($call chk (t)) err
  $defer    $call say (m)
}
// No deferral at all.
$decl bare  $func ($decl src "") $new {
  $prop tag "ok"
  $decl n   ($try ($call str_to_int (src)) none).v
}
// What a call answered, read as a value (§5.4).
$decl n_of  $func ($decl r $union (none, { $prop tag "ok"  $decl a 0  $decl n 0 })) $match r (
  $case {$prop tag "none"} 0,
  $case {$prop tag "ok"}   r.n
)

// A: built, owned by an inner scope, released after its work, newest first. 751
// B: not built: only `a`'s deferral, in the constructor, before the caller goes on. 17
$decl case_ab $func ($decl src "") {
  $decl s   $call parse (src)
  $decl r   $call say (7)
  $decl ret $call n_of (s)
}.ret

// C: forwarded, and failing. 1
$decl case_c $func () {
  $decl s   $call parse0 ()
  $decl ret $call n_of (s)
}.ret

// D: `both`'s one deferral is after both `$try`s, so either failure runs nothing. 4
$decl case_d $func () {
  $decl x   $call both ("4", "5")
  $decl y   $call both ("4", "z")
  $decl z   $call both ("q", "5")
  $decl ret 0
}.ret

// E: nothing owns it, so it is released at the end of its item, when built; a failure
// releases what was registered before the `$try`, inside the constructor. 33112
$decl case_e $func () {
  $decl a   $call say ($call n_of ($call parse ("3")))
  $decl b   $call n_of ($call parse ("y"))
  $decl c   $call say (2)
  $decl ret 0
}.ret

// F: in an arm; only the one that ran, and all of it only if it built. 691, then 16
$decl case_f $func ($decl c true, $decl src "") {
  $decl s   $if c ($call parse (src)) ($call parse ("8"))
  $decl r   $call say (6)
  $decl ret $call n_of (s)
}.ret

// G: no deferral, either way. 0
$decl case_g $func () {
  $decl x   $call bare ("3")
  $decl y   $call bare ("w")
  $decl ret $match x ($case {$prop tag "none"} 0, $case {$prop tag "ok"} x.n)
}.ret

// H: owned at the program's scope, run at exit after the answer.
$decl top   $call parse ("2")

$decl main $func () {
  $decl a   $call case_ab ("5")
  $decl b   $call case_ab ("x")
  $decl c   $call case_c ()
  $decl d   $call case_d ()
  $decl e   $call case_e ()
  $decl f   $call case_f (true, "9")
  $decl g   $call case_f (true, "v")
  $decl h   $call case_g ()
  $decl ret $call concat ($call sval (log), $call concat (" ",
              $call int_to_str ($call add (a, $call add (b, $call add (c, $call add (f,
                  $call add (g, $call add (h, $call n_of (top))))))))))
}.ret
