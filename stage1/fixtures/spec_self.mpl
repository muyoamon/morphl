// §4.9's self-reaching instance: a template body whose `$func` member specialises the
// template it is in. Legal — the use is evaluated when the function is called, not when the
// instance is built — and stage 0 always ran it; lowering refused it, because lowering the
// instance inline lowers the member, whose body is one more instance. It is lowered as a
// builder function now (`lower.mpl`, `spec_knot`), whose type is §5.5's knot.
//
// The digits: a counter stepped a million times through its own `next`, whose type is a `μ`
// (6, from 1,000,006); a use projected inside the member, whose type needs a second round to
// settle (8); a use two `$func`s deep (4); a template with a prop, read off a value the
// builder made (1); and one template at two argument types, two builders (7, 3). 684173.

// 1. `next` answers an instance of the template it is in.
$decl counter $template T {
  $decl n    T
  $decl next $func () $specialize counter ($call add (n, 1))
}
$decl walk $func ($decl c ($specialize counter 0), $decl k 0)
  $if ($call eq (k, 0)) c.n ($call walk ($call c.next (), $call sub (k, 1)))

// 2. The use is projected, so `succ` answers `Int` — known only once `v` has been seen.
$decl peek $template T {
  $decl v    T
  $decl succ $func () ($specialize peek ($call add (v, 1))).v
}

// 3. Two `$func`s deep.
$decl deep $template T {
  $decl n  T
  $decl mk $func () $func () $specialize deep ($call mul (n, 2))
}

// 4. A prop, read off an instance the builder made.
$decl box $template T {
  $prop kind "box"
  $decl v    T
  $decl put  $func ($decl x T) $specialize box x
}

// 5. One template, two argument types: each has its own builder.
$decl keep $template T {
  $decl v     T
  $decl again $func ($decl x T) $specialize keep x
}

$decl d $func ($decl acc 0, $decl x 0) $call add ($call mul (acc, 10), x)

$decl main $func () {
  $decl a   $call sub ($call walk ($specialize counter 6, 1000000), 1000000)
  $decl p   $specialize peek 7
  $decl b   $call p.succ ()
  $decl q   $specialize deep 1
  $decl q1  $call ($call q.mk ()) ()
  $decl q2  $call ($call q1.mk ()) ()
  $decl c   q2.n
  $decl bx  $specialize box 0
  $decl b2  $call bx.put (5)
  $decl e   $if ($call eq_str (b2.kind, "box")) ($call sub (b2.v, 4)) 0
  $decl ki  $specialize keep 0
  $decl ks  $specialize keep ""
  $decl f   ($call ki.again (7)).v
  $decl g   $call len (($call ks.again ("abc")).v)
  $decl ret $call d ($call d ($call d ($call d ($call d (a, b), c), e), f), g)
}.ret
