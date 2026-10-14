// §3.3 makes a file a block and §2.1 makes `{}` and `()` the same value, so an **empty**
// module is a valid empty block, not an error. §8's `read_file` answers an option and
// both passes used to flatten it to a string, which made a file that could not be read
// and a file that is empty the same case: importing this reported "cannot read" for a
// file that was read perfectly well.
//
// Answer 9. A missing module is still reported — that half was never broken.
$decl E    $import "empty_util"
$decl P    $import "../prelude"
$decl main $func () $if ($call P.not (false)) 9 0
