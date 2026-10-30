// A `$func` prop naming a template declared in the same function. §4.9 gives a template no
// runtime value, so naming one captures nothing; what its body reads from the frame would
// be a capture, and a prop has nowhere to evaluate one (§4.10). Lowering counted the
// template's own slot as a capture and refused all of these, where the checker and stage 0
// accept them. `selfspec.mpl` and the rest are written at the top level, where a template
// is a global. Each case is a digit.
$decl outer $func ($decl k 0) {
  // 1. Self-specialisation: `again` names `box` from inside `box`.
  $decl box $template T {
    $prop mk    $func ($decl v T) { $decl val v }
    $prop again $func ($decl v T) $call ($specialize box T).mk (v)
  }
  // 2. One template's prop naming another.
  $decl two $template T {
    $prop via $func ($decl v T) $call ($specialize box T).mk ($call add (v, 1))
  }
  // 3. A template that reads the frame stays a frame read where it is used directly, as it
  // always was (`spec_frame.mpl`): `k` is this call's.
  $decl gen $template T { $decl v k }
  $decl b   $specialize box 0
  $decl w   $specialize two 0
  $decl x   $call b.again (5)
  $decl y   $call w.via (6)
  $decl ret $call add ($call mul (x.val, 100), $call add ($call mul (y.val, 10),
              ($specialize gen 0).v))
}.ret

$decl main $func () $call add ($call mul ($call outer (3), 1000), $call outer (8))
