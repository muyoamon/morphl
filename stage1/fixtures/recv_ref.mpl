// §4.10: "The receiver is a reference." A read-only member used to receive a *copy* of
// its block, so `$traitsof a` inside one referred to the copy — on the heap when the
// member was reached by projection, which hid it, and in the shim's frame when it was
// reached through a trait object, which did not: a stack-use-after-return, and stage 0's
// 10 came out as 2. Every receiver is now captured as the target's own storage.
//
// 10 + 2 + 21 = 33: five steps through a trait object whose `rest` answers an object over
// its receiver (the shim path), one step by projection, and three over a block a function
// returned, held in a local.

$decl seq_proto { $prop size $func () 0  $prop rest $func () $traitsof seq_proto }
$decl seq       $traitsof seq_proto

$decl a  { $decl k 2  $prop size $func () a.k  $prop rest $func () $traitsof a }
$decl mk $func ($decl n 0) {
  $decl b   { $decl k n  $prop size $func () b.k  $prop rest $func () $traitsof b }
  $decl ret b
}.ret

$decl walk $func ($decl s seq, $decl n 0, $decl acc 0)
  $if ($call eq (n, 0)) acc
      ($call walk ($call s.rest (), $call sub (n, 1), $call add (acc, $call s.size ())))

$decl main $func () {
  $decl s1  $call walk (a, 5, 0)
  $decl o   $call a.rest ()
  $decl s2  $call o.size ()
  $decl m   $call mk (7)
  $decl s3  $call walk (m, 3, 0)
  $decl ret $call add ($call add (s1, s2), s3)
}.ret
