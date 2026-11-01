// Lowering's diagnostics name the file they are in. One in a base template's body,
// reached through an `$override` of it (§4.12a), is at the base's own line — not here at
// the line `Pa.ov_shift` moved it to — and one in a plain module member is the module's,
// not this file's. Both are refusals only lowering makes (see the module).

$decl U $import "override_diag_util"

$decl ob $override U.box { $prop k 1 }
$decl B  $specialize ob 0

$decl main $func () $call add ($call B.ap ($alloc 0), $call U.ap2 ())
