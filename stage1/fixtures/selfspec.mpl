// §4.9's self-specialisation: a template whose body specialises itself.
//
// "Self-specialization ties the recursion knot via memoization on the argument
// type (§5.5)." Inference used to refuse every one of these — the template's own
// name was still §5.5's placeholder in the environment its body is typed in, so
// `$specialize box T` said "expects a template, found v1" — and lowering refused
// them for the same reason one pass later.
//
// 5 + 3 + 9 + 4 = 21.
//
// `wrap` is a prop whose value *is* its own specialisation. Stage 0 used to force
// every prop when a block was built, so it recursed to its instantiation depth
// limit there while the compiler accepted it; props are forced on first read now,
// and `w.self.k` makes one nested instance and stops.

$decl U $import "selfspec_util"

// Same argument type: the memo hands back the in-progress entry, and the body is
// typed again against the first pass's answer so a projection off it works.
$decl box $template T {
  $prop mk $func ($decl v T) { $decl val v }
  $prop again $func ($decl v T) $call ($specialize box T).mk (v)
}

// A prop whose value is the specialisation itself.
$decl wrap $template T {
  $prop self $specialize wrap T
  $prop k 3
}

$decl b $specialize box 0
$decl w $specialize wrap 0
$decl p $specialize U.pair 0

$decl main $func ()
  { $decl x $call b.again (5)
    $decl q $call p.swap ($call p.mk (4, 9))
    $decl r $call add ($call add (x.val, w.self.k), $call add (q.fst, q.snd)) }.r
