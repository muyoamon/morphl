// An `$overload` of templates (STDLIB.md, P7): the first candidate whose bounds accept the
// arguments, §4.8's rule with a bound standing where a parameter type stands. Before it,
// `$specialize` refused an overload ("expects a template") and a `$call` found no
// candidate. Inference chooses and records the choice per site; lowering follows it.
//
// Each digit is one choice. `$specialize`: an `Int` bound, a trait bound, the unbounded
// fallback, and a nested overload taking two generics, then one — 12341. `$call`: a
// function candidate before the templates, a template whose generic application cannot
// infer (skipped, not reported), and the fallback; then the same site inside a template
// body, which chooses per instance — 381821. A module's overload from outside and from
// inside, 107 and 105. Stage 0 has no types to check a bound against.

$decl U $import "overload_tmpl_util"

$decl named_proto { $prop name $func () 0 }
$decl thing       { $prop name $func () 7 }

$decl by_int   $template ($decl T 0) { $prop d 1 }
$decl by_named $template ($decl T $traitsof named_proto) { $prop d 2 }
$decl by_any   $template T { $prop d 3 }
$decl pair     $template (A, B) { $prop d 4 }
$decl kind     $overload (by_int, by_named, by_any)
$decl both     $overload ($overload (by_int, pair), by_any)

$decl str_len   $func ($decl s "") $call len (s)
$decl uninfer   $template T $func ($decl x 0) 9
$decl twice_int $template ($decl T 0) $func ($decl x T) $call mul (x, 2)
$decl any_one   $template T $func ($decl x T) 1
$decl mixed     $overload (str_len, uninfer, twice_int, any_one)
$decl via       $template T $func ($decl x T) $call mixed (x)

$decl digit $func ($decl acc 0, $decl d 0) $call add ($call mul (acc, 10), d)

$decl main $func () {
  $decl s1  ($specialize kind 5).d
  $decl s2  ($specialize kind thing).d
  $decl s3  ($specialize kind "x").d
  $decl s4  ($specialize both (1, "y")).d
  $decl s5  ($specialize both 9).d
  $decl a   $call digit ($call digit ($call digit ($call digit (s1, s2), s3), s4), s5)
  $decl c1  $call mixed ("abc")
  $decl c2  $call mixed (4)
  $decl c3  $call mixed (thing)
  $decl c4  $call via (4)
  $decl c5  $call via ("ab")
  $decl c6  $call via (thing)
  $decl b   $call digit ($call digit ($call digit ($call digit ($call digit ($call digit (a,
                c1), c2), c3), c4), c5), c6)
  $decl m   $call add ($call mul (b, 1000), $call U.pick (7))
  $decl ret $call add ($call mul (m, 1000), $call U.use ())
}.ret
