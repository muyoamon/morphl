// P10 (STDLIB.md): a `$func` a block's `$decl` binds may name itself. It ran under stage 0
// and type-checked, and lowering said "unknown name". Inside its own body the name is the
// closure over itself — its own index and captures — so a tail call to it is §7.7's loop,
// and a call elsewhere reuses the environment it already has.
//
// 2000000 + 610 + 30 + 96 = 2000736: a loop 2,000,000 deep at -O0 capturing `k`, a doubly
// recursive call, and a list built by a local recursive helper from a local arena — three
// 32-byte cells — the shape that found it: §7.6 makes an allocator lexical, so its helpers
// are local too. That needed the closure to capture `allocator` at all, which it did not
// (lowering's own `free_names` lacked `$alloc`'s implicit read). Compiled only: the arena is
// built from §8's raw memory, outside stage 0's subset.

$decl ival $func ($decl x 0) x

$decl arena $func ($decl cap 0) {
  $decl b   $call raw_alloc (cap)
  $decl a   { $decl base b  $decl top $mut $alloc b  $decl end $call add (b, cap)
    $prop alloc $func ($decl size 0) {
      $decl sz  $call mul ($call div ($call add (size, 15), 16), 16)
      $decl p   $call ival (a.top)
      $decl w   $set a.top ($call add (p, sz))
      $decl ret p
    }.ret
    $prop free  $func ($decl addr 0) ()
    $prop used  $func () $call sub ($call ival (a.top), a.base)
  }
  $decl ret a
}.ret

$decl node $union (0, { $decl head 0  $decl tail $alloc node })
$decl total $func ($decl xs node, $decl acc 0) $match xs (
  $case {$decl head 0  $decl tail $alloc node} ($call total (xs.tail, $call add (acc, xs.head))),
  $case xs acc
)

$decl run $func ($decl k 0) {
  $decl sum $func ($decl n 0, $decl acc 0)
    $if ($call eq_int (n, 0)) acc ($call sum ($call sub (n, 1), $call add (acc, k)))
  $decl fib $func ($decl n 0)
    $if ($call lt (n, 2)) n ($call add ($call fib ($call sub (n, 1)), $call fib ($call sub (n, 2))))
  $decl ret $call add ($call sum (2000000, 0), $call fib (15))
}.ret

$decl built $func () {
  $decl allocator $call arena (4096)
  $decl build $func ($decl n 0, $decl acc node)
    $if ($call eq_int (n, 0)) acc
        ($call build ($call sub (n, 1), { $decl head n  $decl tail $alloc acc }))
  $decl xs  $call build (3, 0)
  $decl ret $call add ($call mul ($call total (xs, 0), 5), $call allocator.used ())
}.ret

$decl main $func () $call add ($call run (1), $call built ())
