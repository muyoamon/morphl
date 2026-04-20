$decl x {
  $decl a $mut 10;
  $decl f $func ($decl n 0) $set $member $parent a n;
};

$set $member x a 100;
$call $member x f 900;
$exit $member x a;
