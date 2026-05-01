$decl int 0;
$decl cstr "";

$decl File {
  $decl handle int;
  $decl owned int;
  $decl ok int;
};

$decl print $extern "print" $func ($decl s "") int;

$decl helper $func ($decl s "") {
  $decl print $member $file print;
  $ret $call print s;
};

$decl stdout_file $extern "stdout_file" $func () File;
$decl stdout_val $call stdout_file ();
