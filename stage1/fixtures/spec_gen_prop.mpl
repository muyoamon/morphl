// A props-only template whose props `$specialize` one of its own generics, a template
// argument. Lowering's compile-time-generics scan resolved the target in the template's
// environment, which does not bind its generics, and reported "unknown name 'B'".
$decl box  $template T { $prop k 1  $prop f $func ($decl n 0) $call add (n, 3) }
$decl box2 $template T { $prop k 2  $prop f $func ($decl n 0) $call mul (n, 2) }

$decl ctr $template (B, T) {
  $prop kk  ($specialize B 0).k
  $prop run $func ($decl n 0) $call ($specialize B T).f (n)
}

// The generic passed on to another template, which specialises it in turn.
$decl outer $template B {
  $prop kk ($specialize ctr (B, 0)).kk
}

$decl main $func () {
  $decl d1  ($specialize ctr (box, 5)).kk
  $decl d2  ($specialize ctr (box2, 5)).kk
  $decl d3  $call ($specialize ctr (box, 5)).run (4)
  $decl d4  $call ($specialize ctr (box2, 5)).run (4)
  $decl d5  ($specialize outer box2).kk
  $decl ret $call add ($call mul (d1, 10000), $call add ($call mul (d2, 1000),
                $call add ($call mul (d3, 100), $call add ($call mul (d4, 10), d5))))
}.ret
