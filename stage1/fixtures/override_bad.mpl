// What §4.12a refuses: on a value, a prop the base lacks, a field, a member that is no
// subtype of the one it replaces, and a `$decl`; on a template, a prop its body lacks, an
// override not written in place, and overriding an `$override`'s template again.
$decl a { $decl w 1  $prop area $func () 2 }
$decl b1 $override a { $prop size $func () 3 }
$decl b2 $override a { $prop w 4 }
$decl b3 $override a { $prop area $func () "x" }
$decl b4 $override a { $decl area 5 }
$decl t  $template T { $prop make $func ($decl x T) x }
$decl t1 $override t { $prop take $func ($decl x 0) x }
$decl ps { $prop make $func ($decl x 0) x }
$decl t2 $override t ps
$decl t3 $override t { $prop make $func ($decl x "") x }
$decl t4 $override t3 { }
$decl main $func () 0
