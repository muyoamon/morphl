// The trait and the code reading its scalar member, in a module of their own, so the
// table — in the shared header — calls functions another module made (`tscalar.mpl`).
$decl named  { $prop name ""  $prop size $func () 0 }
$decl named_t $traitsof named
$decl weigh $func ($decl t named_t) $call add ($call len (t.name), $call t.size ())
