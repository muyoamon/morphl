// §4.16 with a C prototype in the symbol: libc bound directly, though §3.1 has one integer
// type. Each prototype is emitted verbatim, so it agrees with the header the runtime
// already includes; arguments are cast to their C types and results back, so an `int`
// arrives sign-extended and a pointer as an address.
//
// `puts` prints `hello`; then 5 * 1000 + 42 + 2 * 100000 + 9 * 10 = 205132: `strlen`,
// `abs (-42)`, where `strchr` found the `l` (through its pointer result), and `abs` used
// as a value through the wrapper a function value points at.

$decl puts   $extern "int puts(const char *)"            $func ($decl s 0) 0
$decl strlen $extern "size_t strlen(const char *)"       $func ($decl s 0) 0
$decl abs    $extern "int abs(int)"                      $func ($decl n 0) 0
$decl strchr $extern "char *strchr(const char *, int)"   $func ($decl s 0, $decl c 0) 0
$decl srand  $extern "void srand(unsigned int)"          $func ($decl n 0) ()

$decl apply $func ($decl f $func ($decl n 0) 0, $decl x 0) $call f (x)

$decl main $func () {
  $decl msg "hello\u{0}"
  $decl p   $call str_ptr (msg)
  $decl r   $call puts (p)
  $decl n   $call strlen (p)
  $decl a   $call abs (-42)
  $decl at  $call sub ($call strchr (p, 108), p)
  $decl s   $call srand (7)
  $decl v   $call apply (abs, -9)
  $decl ret $call add ($call add ($call mul (n, 1000), a),
                $call add ($call mul (at, 100000), $call mul (v, 10)))
}.ret
