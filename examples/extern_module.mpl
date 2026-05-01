$decl int 0;
$decl cstr "";

$decl stdin $extern 0;
$decl ext_f $extern $func () int;
$decl printstr $extern "print" $func (cstr) int;

$decl file {
  $decl text cstr;
  $decl len int;
  $decl raw int;
  $decl ok int;
};


