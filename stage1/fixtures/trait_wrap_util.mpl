// `trait_wrap.mpl`'s module: a coercion of its own between two traits whose `make` differs,
// so this output carries a wrapper table of its own.
$decl wide_proto { $prop make $func ($decl n 0) { $decl a 0  $decl b 0 } }
$decl thin_proto { $prop make $func ($decl n 0) { $decl a 0 } }
$decl thin_a $func ($decl t $traitsof thin_proto) { $decl r $call t.make (8)  $decl ret r.a }.ret
$decl via    $func ($decl w $traitsof wide_proto) $call thin_a (w)
