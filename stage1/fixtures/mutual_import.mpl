// §4.14 loads the module; the cycle inside it is what is being tested. The
// answer is the length of what `shw` builds, which is 5.
$decl M $import "mutual_util"
$decl main $func () $call len ($call M.shw (4))
