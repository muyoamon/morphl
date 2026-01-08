$decl factorial $func $decl n 0
    $if $lte n 1 $ret 1 $ret $mul n $call factorial $sub n 1;
$decl result $call factorial 5;
