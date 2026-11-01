// §8's intrinsics are ordinary names (§2.1), so any of them can be a value, and §7.3 makes
// a function value a pair, which needs a function to point at. The runtime had one only for
// the operators (`mpl_fn_sub`), so naming `concat`, `str_to_int` or `read_file` as a value
// was "cannot emit the intrinsic" — at the top level and in a function alike. Emit now
// generates the wrapper, whose body is a call to the intrinsic emitted as any call to it is.
//
// Answer 2555862: the top level's 42, `outer (7)` 1271345 and `outer (20)` 1284475, with each
// intrinsic reached through a local `$decl`, an alias of that, a higher-order call, a
// closure, and an overload whose candidate on `Float` the program never otherwise uses.
$decl toi str_to_int
$decl top $func () {
  $decl o   $call toi ("42")
  $decl ret $match o ($case {$prop tag "some"} o.v, $case o 0)
}.ret
$decl ap2 $func ($decl f ($func ($decl a "", $decl b "") ""), $decl x "", $decl y "")
  $call f (x, y)
$decl ap1 $func ($decl f ($func ($decl a 0) $union ({ $prop tag "none" },
                    { $prop tag "some" $decl v "" })), $decl x 0) $call f (x)
$decl outer $func ($decl k 0) {
  $decl cc concat
  $decl ln len
  $decl sl slice
  $decl by byte
  $decl rf read_file
  $decl wf write_file
  $decl ti to_int
  $decl ts to_str
  $decl isub sub
  $decl i2 isub
  $decl s  $call ap2 (cc, $call ts (k), "5")
  $decl c  $call ap1 (from_code, $call add (64, k))
  $decl cs $match c ($case {$prop tag "some"} c.v, $case c "")
  $decl w  $call wf ("/nonexistent/dir/f", "z")
  $decl wn $match w ($case {$prop tag "ok"} 1, $case w 2)
  $decl r  $call rf ("/nonexistent/f")
  $decl rn $match r ($case {$prop tag "some"} 5, $case r 7)
  $decl i  $call ti (s)
  $decl iv $match i ($case {$prop tag "some"} i.v, $case i 0)
  // A closure over the alias, in tail position 1,000,000 deep.
  $decl loop $func ($decl n 0, $decl acc 0) $if ($call eq (n, 0)) acc
      ($call loop ($call i2 (n, 1), $call add (acc, 1)))
  $decl ret $call add ($call mul (100000, $call ln ($call sl (s, 0, 2))),
              $call add ($call mul (1000, $call by (cs, 0)), $call add ($call mul (100, wn),
              $call add ($call mul (10, rn), $call add (iv, $call loop (1000000))))))
}.ret
$decl main $func () $call add ($call top (), $call add ($call outer (7), $call outer (20)))
