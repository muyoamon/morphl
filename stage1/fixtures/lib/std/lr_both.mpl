// A library module importing another by the same logical name the entry uses, so §4.14
// makes the two imports one module.
$decl W    $import "std/lr_twice"
$decl four $func ($decl n 0) $call W.twice ($call W.twice (n))
