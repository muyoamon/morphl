// §6: a trait member that is not a function — §9's test interface has `$prop name ""` —
// read through a trait object. The object erases the type that holds the value, so its
// table carries a zero-argument function answering it; before that the table entry was
// -1, and `verify` refused a program inference had accepted.
//
// (5 + 10) + (3 + 20) + 9 = 47: two implementations through a function in another
// module, and the scalar read directly off an object made here ("apple!!!!").
$decl U $import "tscalar_util"

$decl apple { $prop name "apple"  $prop size $func () 10 }
$decl fig   { $prop name "fig"    $prop size $func () 20 }

$decl main $func () {
  $decl o   $traitsof apple
  $decl ret $call add ($call add ($call U.weigh (apple), $call U.weigh (fig)),
                       $call len ($call concat (o.name, "!!!!")) )
}.ret
