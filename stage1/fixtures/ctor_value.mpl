// §5.3a: a constructor is a value. A call through one constructs as a call naming it does, and
// since two constructors of one type may differ in their deferrals, the value answers them
// beside the block: a call through it is dynamic, `{b, d}`, and a constructor named as a value
// is the pair of a shim that answers that (STORAGE.md "A constructor as a value").
//
// wawbkbuaubwawtptoawdawb 12344567068119 — each letter pair a call and its deferral, which
// runs at its owner's end:
//   wa wb   `with` passed `mk` and `mk2`, one type and two deferrals;
//   kb      `mk2` held in a block's field and called through it;
//   ua ub   `either` forwarding through the value its `$if` chose, called by name;
//   wa      an alias of `mk`, whose static holds the shim;
//   w       `plain`, with no deferrals: its value answers a `drop` that does nothing;
//   tp t    `parse`, which can fail: built, its deferral runs; failed, nothing was built;
//   oa      `mk` as an `$overload`'s candidate, called through the group;
//   w       another module's member, whose deferral bumps that module's `hits`;
//   da      `hop`, forwarding through a value 2,000,000 deep: one trampolined frame;
//   wb      a top-level `$decl` holding a constructor that its `$if` chose, called by name.
// The number is each call's answer, a digit apiece, then `U.hits` and `deep`'s and `chosen`'s.

$decl U $import "ctor_value_util"

$decl log $mut $alloc ""
$decl say $func ($decl s "") $set log ($call concat (log, s))

$decl mk    $func ($decl n 0) $new { $decl v n  $defer $call say ("a") }
$decl mk2   $func ($decl n 0) $new { $decl v n  $defer $call say ("b") }
$decl plain $func ($decl n 0) $new { $decl v n }
$decl h     mk

$decl with $func ($decl make mk, $decl n 0) {
  $decl r   $call make (n)
  $decl z   $call say ("w")
  $decl ret r.v
}.ret

$decl kit { $decl make mk2  $decl n 3 }
$decl from_kit $func () {
  $decl r   $call kit.make (kit.n)
  $decl z   $call say ("k")
  $decl ret r.v
}.ret

$decl either $func ($decl c $union (false, true), $decl n 0) $call ($if c mk mk2) (n)
$decl use $func ($decl c $union (false, true)) {
  $decl r   $call either (c, 4)
  $decl z   $call say ("u")
  $decl ret r.v
}.ret

$decl parse $func ($decl s "") $new {
  $prop tag "ok"
  $decl n ($try ($call str_to_int (s)) none).v
  $defer $call say ("p")
}
$decl tryit $func ($decl p parse, $decl s "") {
  $decl r   $call p (s)
  $decl z   $call say ("t")
  $decl ret $match r ($case { $prop tag "none" } 0, $case { $prop tag "ok" } r.n)
}.ret

$decl over $overload (mk, $func ($decl s "") 0)
$decl via_over $func () {
  $decl r   $call over (6)
  $decl z   $call say ("o")
  $decl ret r.v
}.ret

$decl cell $mut $alloc mk
$decl hop  $func ($decl n 0) $call ($if ($call lt (n, 1)) mk cell) ($call sub (n, 1))
$decl wire $set cell hop
$decl deep $func () {
  $decl r   $call hop (2000000)
  $decl z   $call say ("d")
  $decl ret $call add (r.v, 2)
}.ret

$decl chosen $if ($call lt (2, 1)) mk mk2
$decl from_chosen $func () {
  $decl r   $call chosen (9)
  $decl z   $call say ("w")
  $decl ret r.v
}.ret

$decl digit $func ($decl acc 0, $decl d 0) $call add ($call mul (acc, 10), d)

$decl main $func () {
  $decl a   $call with (mk, 1)
  $decl b   $call with (mk2, 2)
  $decl c   $call from_kit ()
  $decl d   $call use (true)
  $decl e   $call use (false)
  $decl f   $call with (h, 5)
  $decl g   $call with (plain, 6)
  $decl p1  $call tryit (parse, "7")
  $decl p2  $call tryit (parse, "x")
  $decl o   $call via_over ()
  $decl m   $call with (U.um, 8)
  $decl q   $call deep ()
  $decl x   $call from_chosen ()
  $decl n   $call digit ($call digit ($call digit ($call digit ($call digit ($call digit (
                $call digit ($call digit ($call digit ($call digit ($call digit ($call digit (
                $call digit ($call digit (0, a), b), c), d), e), f), g), p1), p2), o), m),
                U.hits), q), x)
  $decl ret $call concat (log, $call concat (" ", $call int_to_str (n)))
}.ret
