// A trait taken inside the block it describes — `$traitsof s3` in `s3`'s own `cmp` — is
// recursive, `μR. trait{cmp: (R, Int) -> {a}}`, and lowering ties it as §5.5's knot
// (`self_knot`): while `cmp` is lowered the trait is a placeholder, and the retry closes it.
// It used to come out `trait{cmp: !}`, and `t3`, whose `cmp` answers a longer block and so
// needs an adapter in its table (§5.1), was refused: "cannot coerce {a,b,c,e} to !". Four
// fields, so the C result goes through memory where the trait's one field does not, and a
// missing adapter cannot answer by luck. 50, then 1 through `s3` itself: 501.
$decl s3 { $decl k 1
           $prop cmp $func ($decl o $traitsof s3, $decl d 0)
             $if ($call lt (0, d)) ($call o.cmp (o, $call sub (d, 1))) { $decl a s3.k } }
$decl t3 { $decl k 5
           $prop cmp $func ($decl o $traitsof s3, $decl d 0)
             { $decl a 50  $decl b 60  $decl c 70  $decl e 80 } }
$decl main $func () $call add ($call mul (($call s3.cmp (t3, 1)).a, 10), ($call s3.cmp (s3, 2)).a)
