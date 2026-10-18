// §7.6's allocators: a bump arena written in morphl over §8's raw memory, and `$alloc`
// drawing from it because `allocator` is rebound in its lexical scope. Everything written
// above the rebinding — the arena's own state — still comes from the root allocator, in
// §4.10's source order, and inference and lowering agree on which is which.
//
// The list is built twice: 10 cells, then 100 after `reset` takes the arena back. The
// second build's 3,200 bytes are measured from the arena's base, so had `reset` not given
// the first 320 back they would read 3,520.
//
// 5050 * 10^10 + 110 * 10^8 + 55 * 10^6 + 3200 * 10^3 + 320 = 50511058200320: the two
// sums, the allocations the arena served, and the bytes each build used.

$decl ival $func ($decl x 0) x

// The arena's state, made before `allocator` is rebound, so from the root's.
$decl a_base  $mut $alloc 0
$decl a_top   $mut $alloc 0
$decl a_end   $mut $alloc 0
$decl a_count $mut $alloc 0

// `alloc` hands out the next 16-aligned slice and counts it; `free` is nothing, as an
// arena's is; `reset` takes everything back at once, and `release` returns the memory.
$decl arena {
  $prop alloc $func ($decl size 0) {
    $decl sz  $call mul ($call div ($call add (size, 15), 16), 16)
    $decl p   $call ival (a_top)
    $decl ok  $if ($call lt ($call ival (a_end), $call add (p, sz))) ($call panic ("arena: full")) 0
    $decl w   $set a_top ($call add (p, sz))
    $decl c   $set a_count ($call add ($call ival (a_count), 1))
    $decl ret p
  }.ret
  $prop free    $func ($decl addr 0) ()
  $prop reset   $func () $set a_top ($call ival (a_base))
  $prop release $func () $call raw_free ($call ival (a_base))
}

$decl arena_init $func ($decl cap 0) {
  $decl b   $call raw_alloc (cap)
  $decl w1  $set a_base b
  $decl w2  $set a_top b
  $decl w3  $set a_end ($call add (b, cap))
  $decl ret b
}.ret

$decl used $func () $call sub ($call ival (a_top), $call ival (a_base))

// Everything below allocates from the arena: `allocator` is resolved where `$alloc` is
// written, and these are written in its scope.
$decl allocator arena

$decl node $union (0, { $decl head 0  $decl tail $alloc node })

$decl build $func ($decl n 0, $decl acc node)
  $if ($call eq_int (n, 0)) acc
      ($call build ($call sub (n, 1), { $decl head n  $decl tail $alloc acc }))

$decl total $func ($decl xs node, $decl acc 0) $match xs (
  $case {$decl head 0  $decl tail $alloc node} ($call total (xs.tail, $call add (acc, xs.head))),
  $case xs acc
)

$decl main $func () {
  $decl b    $call arena_init (8192)
  $decl xs   $call build (10, 0)
  $decl s1   $call total (xs, 0)
  $decl u1   $call used ()
  $decl r    $call arena.reset ()
  $decl ys   $call build (100, 0)
  $decl s2   $call total (ys, 0)
  $decl u2   $call used ()
  $decl rel  $call arena.release ()
  $decl ret  $call add ($call add ($call mul (s1, 1000000), $call mul (s2, 10000000000)),
                 $call add ($call add (u1, $call mul (u2, 1000)),
                     $call mul ($call ival (a_count), 100000000)))
}.ret
