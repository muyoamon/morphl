$decl x {
  $decl a $mut 10;
  $decl f $func ($decl n 0) $set $member $parent a n;
  $decl s $static $mut 0;
};

$decl s1 $static $mut 0;
$set $member x a 100;
$call $member x f 900;
$decl str $member x $$type;
$exit $member x a;
