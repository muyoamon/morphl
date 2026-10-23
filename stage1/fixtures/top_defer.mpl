// DEFER.md example 12: a file's top level is the program's scope. Its deferrals, and its
// storage's, run once `main` has returned and its answer is printed, newest first — so the
// entry file's run before those of the module it imports, which was initialised first.
// Prints "tmp init main 18", then "c b a e1 u2 u1".
$decl U   $import "top_defer_util"
$decl id  $func ($decl c $new { $decl k 0 }) c
$decl use $func ($decl c $new { $decl k 0 }) c.k
$defer    $call print ("e1 ")
// Owned by `a`; then storage that dies at its item's end, since `use` answers a value.
$decl a   $new { $decl k 3  $defer $call print ("a ") }
$decl t   $call use ($new { $decl k 4  $defer $call print ("tmp ") })
// Owned through a call that hands it back, and only the arm that ran.
$decl b   $call id ($new { $decl k 5  $defer $call print ("b ") })
$decl c   $if ($call lt (a.k, 0)) ($new { $decl k 6  $defer $call print ("no ") })
              ($new { $decl k 7  $defer $call print ("c ") })
$call print ("init ")
$decl main $func () {
  $decl r   $call print ("main ")
  $decl ret $call add (U.val, $call add (a.k, $call add (b.k, c.k)))
}.ret
