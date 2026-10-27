// `trait_coerce.mpl`'s module: a trait, an implementation whose member answers a subtype of
// the trait's, and a function over the trait, so the member is defined in this output and
// reached through an adapter in the shared header.

$decl maker_proto { $prop make $func ($decl n 0) { $decl a 0 } }

$decl big $alloc { $decl k 2
  $prop make $func ($decl n 0) { $decl a $call add (n, big.k)  $decl b 0  $decl c 0  $decl d 0 }
}

$decl use $func ($decl m $traitsof maker_proto, $decl n 0) {
  $decl r   $call m.make (n)
  $decl ret r.a
}.ret
