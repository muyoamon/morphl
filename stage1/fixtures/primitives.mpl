// §8's `$primitives`: a member is the primitive whatever the scopes between bind, so this
// file's own `concat` (named like it, and calling it) does not stand in for it. Covered:
// a call, a top-level alias, a block-local alias, the member as a value and as a parameter's
// default, and the option-returning members. Answers "ba[42]é?missing7".

$decl concat $func ($decl a "", $decl b "") $call $primitives.concat (b, a)
$decl cat    $primitives.concat

$decl apply $func ($decl f $primitives.concat, $decl a "", $decl b "") $call f (a, b)

$decl join $func ($decl n 0) {
  $decl c   $primitives.concat_all
  $decl a   $call array (3, "")
  $decl w0  $set ($call at (a, 0)) "["
  $decl w1  $set ($call at (a, 1)) ($call $primitives.to_str (n))
  $decl w2  $set ($call at (a, 2)) "]"
  $decl ret $call c (a)
}.ret

$decl code $func ($decl n 0) {
  $decl r   $call $primitives.from_code (n)
  $decl ret $match r ($case {$prop tag "some"} r.v, $case r "?")
}.ret

$decl main $func () {
  $decl a   $call concat ("a", "b")
  $decl b   $call cat (a, $call join (42))
  $decl c   $call apply ($primitives.concat, b, $call code (233))
  $decl d   $call $primitives.concat (c, $call code (-1))
  $decl f   $call $primitives.read_file ("/nonexistent/primitives")
  $decl e   $match f ($case {$prop tag "some"} "read", $case f "missing")
  $decl ret $call cat (d, $call cat (e, $call $primitives.int_to_str (7)))
}.ret
