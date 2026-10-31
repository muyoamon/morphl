// §4.10 makes a prop visible throughout its block, and a block inside a function is no
// exception — but lowering bound a block's props only for a projection onto the block, so
// the block's own items could not name them: `k` was an "unknown name" here, where the
// checker and stage 0 accept it. A file's top-level props worked, which is why this showed
// only once `topprop.mpl` was lifted into a function (tools/sweep.sh --lift).
//
// Answer 217646: `outer (3)` is 107000 + 1800 + 17 + 3 and `outer (5)` 107000 + 1800 + 21 + 5.
// It covers a scalar, a props-only block, a `$func` prop reading a sibling, a template, a
// nested block whose own `k` shadows the outer one, and `$func`s naming each of them.
$decl outer $func ($decl n 0) {
  $prop k 11
  $prop tagged { $prop tag "t" $prop m 7 }
  $prop twice $func ($decl x 0) ($call add (x, $call add (x, k)))
  $prop box $template T { $prop mk $func ($decl v T) { $decl val v } }
  $decl inner {
    $prop k 100
    $decl r $call add (k, tagged.m)
  }
  $decl f $func () ($call add (k, tagged.m))
  $decl g $func () ($call twice (n))
  $decl ret $call add ($call mul (1000, inner.r),
              $call add ($call mul (100, $call f ()),
              $call add ($call g (), ($call ($specialize box 0).mk (n)).val)))
}.ret
$decl main $func () $call add ($call outer (3), $call outer (5))
