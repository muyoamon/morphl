$decl Result $mut $template (T, E) {
  $decl val T;
  $decl err E;
};

$decl res $specialize Result (10, $null);
$decl res2 $specialize Result ($null, "Not found");

$member res $$type;
$member res2 $$type;

$set Result $template (T,E) {
  $decl val T;
  $decl err E;
  $decl ok 0;
};

$decl res3 $specialize Result (1.0, $null);

$decl f $template T $func $decl res T {
  $ret $add $member res val 1;
};


$exit $call $specialize f res res;

