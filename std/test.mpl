"This module is just a temporary module for testing std library";
$alias io $import "io.mpl"
$alias Array $member $import "array.mpl" Array;

$decl x $specialize Array ("A", 5);

$decl print_elem $func ($decl str "") {
  $call $member io println str;
  $ret ();
}

$call $member x $foreach print_elem;


