$decl add $func ($decl x 0, $implicit $decl y 10) {
  $ret $add x y;
};

$decl r1 $call add (5);
$decl r2 $call add (5, 3);

$decl repeat $func ($implicit $decl times 3, $decl n 0) {
  $decl i $mut 0;
  $decl sum $mut 0;
  $while $lt i times {
    $set sum $add sum n;
    $set i $add i 1;
  };
  $ret sum;
};

$decl r3 $call repeat (7);
$decl r4 $call repeat (5, 7);

$decl state $mut ($implicit 0, 0, 0);
$set state (10, 20);

$decl record $mut (0, 0, $implicit 42);
$set record (100, 200);

$exit $add r1 ($add r2 ($add r3 r4));
