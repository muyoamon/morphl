// A template instance's `$new` is frame storage of the scope the `$specialize` stands in
// (SPEC §4.9), so returning it is §5.3a's escape. It was accepted, and the compiled program
// read the dead frame: 0 where stage 0 says 3.
$decl owned $template k $new { $decl v k }
$decl make  $func ($decl n 0) $specialize owned n
$decl main  $func () ($call make (3)).v
