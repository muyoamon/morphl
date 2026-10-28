// §4.10 in the entry file: an initializer sees what precedes it. `$decl isub sub` above the
// file's own `sub` is the idiom for keeping an intrinsic the file shadows (§2.1), and both
// stage 0 and the checker resolve it to the root's — but lowering binds every global up
// front, so it bound the thunk to the file's `sub`. Here that is a function of another
// type, which `cc` refused; with a matching type (`$decl cat concat` above a `concat` of
// the same signature) it compiled to the wrong function, silently. A `$func`'s body still
// resolves against the finished file, as stage 0 has it: `diff` reaches the file's `sub`.
$decl isub sub
$decl iadd add
$decl diff $func ($decl a 0, $decl b 0) $call sub (a, b)
$decl sub  $func ($decl a 0, $decl b 0) 99
$decl add  $func ($decl a 0, $decl b 0) 88
$decl main $func ()
  $call iadd ($call mul ($call isub (10, 3), 10000), $call iadd ($call mul ($call iadd (2, 3), 100),
      $call diff (1, 1)))
