// A program that checks and emits but does not link: the extern is defined nowhere,
// so `cc` fails and §9.1's `link` must say so rather than hand back a path.
$decl nope $extern "no_such_c_symbol_anywhere" $func ($decl x 0) 0
$decl main $func () $call nope (1)
