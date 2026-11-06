// An intrinsic's result type comes from the root block, never from an expression lowering
// built, so an option nothing projected reached the type table without its members, and
// the backend laid it out as two `int64_t`s — then wrote a `Str` into one, which `cc`
// refused. Every shape below reads no payload: a `$match` on the call itself, the same
// through an alias, an overload's candidate, and results bound and never read.
$decl rf read_file
$decl main $func () {
  $decl a   $match ($call read_file ("/nonexistent/x")) ($case {$prop tag "some"} 1, $case () 2)
  $decl b   $match ($call rf ("/nonexistent/x")) (
              $case {$prop tag "some"} 10,
              $case {$prop tag "none"} 20)
  $decl c   $call run ($call array (1, "true"))
  $decl d   $match ($call str_to_int ("12")) ($case {$prop tag "some"} 300, $case () 400)
  $decl e   $match ($call from_code (-1)) ($case {$prop tag "some"} 5000, $case () 6000)
  $decl f   $call write_file ("/nonexistent/dir/x", "y")
  $decl g   $match ($call to_int ("x")) ($case {$prop tag "some"} 70000, $case () 80000)
  $decl ret $call add (a, $call add (b, $call add (d, $call add (e, g))))
}.ret
