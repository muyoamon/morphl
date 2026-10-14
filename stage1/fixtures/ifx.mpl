// A module declaring its own `$template` and a non-scalar `$prop`, so that loading it
// before the prelude advances both of inference's compile-time counters. Under the old
// counter-derived ids that shifted the prelude's `t_tmpl` and every `cv_opaque` in the
// program; `test-iface` is the check that it no longer does.
$decl P    $import "../prelude"
$decl pair $template T { $prop mk $func ($decl a T) { $decl v a } }
$decl one  $func () 1
