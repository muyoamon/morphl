// §3.4: "Defaults are evaluated at call time when the argument is omitted." Prints 247.
//
// A short call used to be lowered as written, and `verify` refused the arity mismatch —
// a program inference accepted and stage 0 ran could not be compiled. Now a short call
// to a known function calls a wrapper lowered in the *callee's* definition context,
// which evaluates the omitted defaults there and tail-calls the function. Each line is
// a different way to reach a callee, or a different property the default must keep.
$decl U $import "defaults_util"
$decl P $import "../prelude"

$decl k 100
$decl f $func ($decl a 0, $decl b k) $call add (a, b)

// Reached before its definition: the wrapper is built at the end of the file.
$fwd h
$decl early $func () $call h (1)
$decl h $func ($decl a 0, $decl b 5) $call add (a, b)

// Through an alias, which is a thunk the wrapper has to see through.
$decl al f

// A short self-call in tail position, 2,000,000 deep: the wrapper and the function
// form a tail-call group, so this must not cost a frame per call (§7.7).
$decl cnt $func ($decl n 0, $decl acc 0) $if ($call eq_int (n, 0)) ($call add (acc, 9)) ($call cnt ($call sub (n, 1)))

// A default with an effect runs once per call that omits it.
$decl c $mut $alloc 0
$decl bump $func () $set c ($call add (c, 1))
$decl eff $func ($decl a 0, $decl b ($call bump ())) b

$decl L $specialize P.list 0

$decl main $func ()
  { // Shadows the global: `f`'s default still reads the `k` in *its* scope.
    $decl k  1
    $decl x1 $call f (2)
    $decl x2 $call early ()
    $decl x3 $call al (3)
    $decl x4 $call cnt (2000000)
    $decl x5 $call eff (0)
    $decl x6 $call eff (0)
    $decl x7 $call U.g (3)
    $decl x8 $call L.length ($call L.cons (1, $call L.cons (2, L.nil)))
    // 102 + 6 + 103 + 9 + 1 + 2 + 21 + 2 + 1 = 247.
    $decl r  $call add (x1, $call add (x2, $call add (x3, $call add (x4, $call add (x5,
                 $call add (x6, $call add (x7, $call add (x8, k)))))))) }.r
