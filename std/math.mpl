"math.mpl - math library";

$alias _ff_f_func $func ($decl l 0.0, $decl r 0.0) 0.0;
$alias _f_f_func $func ($decl x 0.0) 0.0;

$decl pow $extern "_native_pow" _ff_f_func;

$decl sqrt $extern "_native_sqrt" _ff_f_func;

$decl sin $extern "_native_sin" _f_f_func;
$decl cos $extern "_native_cos" _f_f_func;
$decl tan $extern "_native_tan" _f_f_func;

$decl pi  3.14159265358979323846;
$decl e   2.71828182845904523536;

