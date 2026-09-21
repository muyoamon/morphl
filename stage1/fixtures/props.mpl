// A round-trip fixture for §4.10's compile-time half.
//
// §4.5: "a block is scope, record, module, namespace and (props-only) trait at
// once." This is the namespace reading of it — a block whose members are all
// `$prop`, so it has no layout at all, and every projection onto it is
// answered by the compiler rather than emitted as a field read.
//
// 21 doubled is 42; `triple` of 5 is 15; summing 1..4 is 10; a scalar prop is
// 100 and a prop-only block nested in a prop gives 2. 169.

$decl math {
  // A function-valued prop: lifted to an ordinary top-level function, and a
  // call through the projection is a direct call.
  $prop double $func ($decl x 0) $call add (x, x)

  // One prop naming another: §4.10 makes a prop visible throughout its block
  // regardless of order, so `triple` may name `double` although it is written
  // after it — and `sum_to` may name itself.
  $prop triple $func ($decl x 0) $call add (x, $call double (x))

  // Self-recursive, in tail position (§7.7), so §6a turns it into a loop.
  $prop sum_to $func ($decl n 0, $decl acc 0)
    $if ($call eq_int (n, 0)) acc ($call sum_to ($call sub (n, 1), $call add (acc, n)))

  // A scalar prop: its value is in the block's type (§4.10), so this needs no
  // source at all — the type answers.
  $prop bonus 100

  // A prop-only block inside a prop. It has no layout either, so this is a
  // namespace inside a namespace.
  $prop inner { $prop two 2 }
}

// A function value taken from a prop, passed and called — §7.3's pair, with a
// null environment because a top-level function captures nothing.
$decl apply $func ($decl f $func ($decl x 0) 0, $decl v 0) $call f (v)

$decl main $func ()
  $call add ($call apply (math.double, 21),
      $call add ($call math.triple (5),
      $call add ($call math.sum_to (4, 0),
      $call add (math.bonus, math.inner.two))))
