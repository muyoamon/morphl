// §5.3a's constructing calls: what the checker refuses, beside the shapes it accepts.
$decl say  $func ($decl d 0) d
$decl mk   $func ($decl k 0) $new { $decl v k  $defer $call say (v) }
$decl mkm  $func ($decl k 0) $mut $new { $decl v k }
$decl mk0  $func () $call mk (0)
$decl h    mk
$decl lend $func ($decl r $new { $decl v 0 }) r.v
$decl fine $func () {
  $decl s   $call mk (1)
  $decl t   $call h (2)
  $decl m   $call mkm (3)
  $decl u   $call lend (s)
  $decl ret $call add (u, t.v)
}.ret

$decl rd   $func ($decl k 0) $new { $decl v k  $defer $call say (k) }
$decl tr   $func ($decl t "") $new { $decl v ($try ($call str_to_int (t)) none).v }
$decl pick $func ($decl c true) $if c ($new { $decl v 1 }) ($new { $decl v 2 })
$decl flow $func ($decl k 0) { $decl s $new { $decl v k }  $decl ret s }.ret
$decl out  $func () { $decl s $call mk (1)  $decl ret s }.ret
$decl pass $func () $call lend ($call mk (1))
$decl via  $func ($decl f mk) $call f (1)
$decl over $overload (mk, $func ($decl s "") 0)
$decl ov   $func () $call over (1)
$fwd later
$decl fw   $func () $call later (0)
$decl later $func ($decl k 0) $new { $decl v k }
$decl otr  $func () { $decl s $call tr ("1")  $decl ret s }.ret
$decl two  $func ($decl c true) $if c ($call mk (1)) ($call h (2))
$decl mix  $func ($decl c true) $if c ($call mk (1)) ($new { $decl v 2 })
$decl fa   $func ($decl k 0) $alloc { $decl v k }
$decl wm   $func ($decl f mk) 0
$decl wa   $func ($decl f fa) 0
$decl bad1 $func () $call wm (fa)
$decl bad2 $func () $call wa (mk)
$decl main $func () $call fine ()
