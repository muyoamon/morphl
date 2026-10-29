// A `$fwd` inside a block whose function takes a block with members (P11's wrapper), with
// a tail call through the name before its `$decl` completes it — so through a value, and
// §6a's trampoline spells the call's signature. The slot's type is inference's, which
// closes the wrapper into a μ where lowering does not, and nothing had interned that μ:
// the parameter was spelled `int64_t` and `cc` refused the C. `recv_param.mpl` has the
// same shape at the top level, where its own functions intern the μ, which hid it; here
// the block is the only user. 6.
$decl U $import "recv_param_util"

$decl main $func () {
  $decl a   $call ($call ($call ($call U.strs.empty ()).push ("abc")).push ("de")).push ("wxyz")
  $fwd lg
  $decl fs  $func ($decl xs ($call U.strs.empty ()))
    $call lg ($call xs.rest (), $call len ($call xs.head ()))
  $decl lg  $func ($decl xs ($call U.strs.empty ()), $decl best 0)
    $if ($call xs.is_empty ()) best ($call lg ($call xs.rest (), $call add (best, 1)))
  $decl ret $call fs (a)
}.ret
