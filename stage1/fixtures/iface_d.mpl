$decl X $import "ifx"
$prop box $func ($decl v 0) { $decl val v }
$decl main $func () ($call add (($call box (6)).val, $call X.one ()))
