$decl io $import "std/io.mpl";
$decl fact $import "examples/factorial.mpl";

$decl ret $call $member fact fact 4;

$call $member io print_int ret;
$call $member io println "Hello, World!";

$exit 0;
