// P11: a non-generic function whose parameter is a block type with members that read
// their receiver. The body reaches them through the parameter's *type*, before the code
// building such a block is lowered, and lowering used to defer the read, build no
// closure and call the member with a NULL environment: a segfault. Covers the entry
// file, a module member, and a `$fwd`'d function. 3294.
$decl U $import "recv_param_util"

$decl count $func ($decl xs ($call U.strs.empty ()), $decl n 0)
  $if ($call xs.is_empty ()) n ($call count ($call xs.rest (), $call add (n, 1)))

$fwd longest
$decl firsts $func ($decl xs ($call U.strs.empty ()))
  $call longest ($call xs.rest (), $call len ($call xs.head ()))
$decl longest $func ($decl xs ($call U.strs.empty ()), $decl best 0)
  $if ($call xs.is_empty ()) best
      ($call longest ($call xs.rest (), {
         $decl k    $call len ($call xs.head ())
         $decl ret2 $if ($call lt (best, k)) k best
       }.ret2))

$decl main $func () {
  $decl a   $call ($call ($call ($call U.strs.empty ()).push ("abc")).push ("de")).push ("wxyz")
  $decl ret $call add ($call add ($call mul ($call count (a, 0), 1000),
                                  $call mul ($call U.total_len (a, 0), 10)),
                       $call add ($call firsts (a), 200))
}.ret
