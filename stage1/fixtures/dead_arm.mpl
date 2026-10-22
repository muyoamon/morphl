// §4.7: an arm whose pattern no member of the scrutinee's union is of can never run. The
// usual cause is a misspelt tag, as here: the compiler's own AST tags an error node
// "error", and three such arms in the compiler's source — two misspelt tags and a type's
// — went unnoticed until this was checked. The `$case x` catch-all is not one, even with
// `x` naming storage, whose type is read through.
$decl nil  { $prop tag "nil" }
$decl node $union (nil, { $prop tag "cons"  $decl head 0  $decl tail $alloc node })
$decl len  $func ($decl x node) $match x (
  $case {$prop tag "cons"} 1,
  $case {$prop tag "conz"} 2,
  $case x 0
)
$decl flag $mut $new ($union (false, true))
$decl main $func () $match flag ($case true 1, $case flag 0)
