// §4.9's self-specialisation: a template whose body specialises itself.
//
// "Self-specialization ties the recursion knot via memoization on the argument
// type (§5.5)." Inference used to refuse every one of these — the template's own
// name was still §5.5's placeholder in the environment its body is typed in, so
// `$specialize box T` said "expects a template, found v1" — and lowering refused
// them for the same reason one pass later.
//
// 5 + 9 + 4 = 18.
//
// Not here: a prop whose value *is* the specialisation (`$prop self $specialize
// wrap T`). The compiler types and lowers it, but stage 0 forces every prop when a
// block is built, so it recurses to its instantiation depth limit there — and a
// fixture has to mean the same thing to both.

$decl U $import "selfspec_util"

// Same argument type: the memo hands back the in-progress entry, and the body is
// typed again against the first pass's answer so a projection off it works.
$decl box $template T {
  $prop mk $func ($decl v T) { $decl val v }
  $prop again $func ($decl v T) $call ($specialize box T).mk (v)
}

$decl b $specialize box 0
$decl p $specialize U.pair 0

$decl main $func ()
  { $decl x $call b.again (5)
    $decl q $call p.swap ($call p.mk (4, 9))
    $decl r $call add (x.val, $call add (q.fst, q.snd)) }.r
