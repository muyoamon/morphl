// std/mem's tests: `mplc std/mem_test.mpl -L . -o …` from the repository root. A failure
// is reported on stderr and aborts; `main` answers how many passed.

$decl C $import "std/core"
$decl M $import "std/mem"
$decl T $import "std/test"

// Everything here allocates from `a`, which it binds as `allocator` (§7.6); the second
// arena is only measured, so it shows the two keep separate state.
$decl in_arena $func ($decl r T.proto_results) {
  $decl allocator $call M.arena (1024)
  $decl other     $call M.arena (1024)
  $decl x   $alloc 7
  $decl y   $alloc { $decl a 1  $decl b 2 }
  $decl z   $mut $alloc 0
  $decl w   $set z 30
  $decl c1  $call T.expect (r, "values read back", $call eq ($call add ($call C.ival (x),
                $call C.ival (z)), 37))
  $decl c2  $call T.expect (r, "a block reads back", $call eq ($call add (y.a, y.b), 3))
  $decl c3  $call T.expect (r, "three 16-byte slices", $call eq ($call allocator.used (), 48))
  $decl c4  $call T.expect (r, "another arena is separate", $call eq ($call other.used (), 0))
  $decl rs  $call allocator.reset ()
  $decl c5  $call T.expect (r, "reset takes it all back", $call eq ($call allocator.used (), 0))
  $decl v   $alloc 5
  $decl c6  $call T.expect (r, "and it serves again", $call eq ($call allocator.used (), 16))
  $decl f1  $call allocator.release ()
  $decl f2  $call other.release ()
  $decl ret 0
}.ret

// DEFER.md step 4: `$alloc { … $defer … }` registers its deferrals with the arena
// (`defer_at`), and the arena runs them when the storage is `$free`d, or — any still
// registered — on `reset` and `release`, newest first. Each appends a digit to `seen`.
$decl seen $mut $alloc 0
$decl note $func ($decl d 0) $set seen ($call add ($call mul ($call C.ival (seen), 10), d))

$decl deferring $func ($decl r T.proto_results) {
  $decl allocator $call M.arena (1024)
  $decl a   $alloc { $decl k 1  $defer $call note (1) }
  $decl b   $alloc { $decl k 2  $defer $call note (2) }
  $decl c   $alloc { $decl k 3  $defer $call note (k) }
  $decl f   $free b
  $decl c7  $call T.expect (r, "$free runs that storage's deferrals", $call eq ($call C.ival (seen), 2))
  $decl rs  $call allocator.reset ()
  $decl c8  $call T.expect (r, "reset runs the rest, newest first, reading the fields",
                $call eq ($call C.ival (seen), 231))
  $decl d   $alloc { $decl k 4  $defer $call note (4) }
  $decl rl  $call allocator.release ()
  $decl c9  $call T.expect (r, "release runs what is left", $call eq ($call C.ival (seen), 2314))
  $decl ret 0
}.ret

// The idiom: the arena released by a deferral registered first, so it runs last, after
// the `$defer $free` beside each `$alloc`.
$decl idiom $func () {
  $decl allocator $call M.arena (1024)
  $defer    $call allocator.release ()
  $decl a   $alloc { $decl k 1  $defer $call note (5) }
  $defer    $free a
  $decl ret 0
}.ret

// SPEC §5.3a: `$alloc` of a constructing call allocates the block the call constructs from the
// allocator in scope, whose `defer_at` takes the block's deferrals. So one constructor serves
// a frame, where the scope releases it, and the arena, where `$free` or the arena does.
$decl made $func ($decl d 0) $new { $decl k d  $defer $call note (k) }
$decl constructed $func ($decl r T.proto_results) {
  $decl allocator $call M.arena (1024)
  $decl a   $alloc $call made (6)
  $decl b   $alloc $call made (7)
  $decl f   $free b
  $decl c11 $call T.expect (r, "$free runs a constructed block's deferrals",
                $call eq ($call C.ival (seen), 7))
  $decl in  { $decl s $call made (8)  $decl ret2 $call C.ival (s.k) }.ret2
  $decl c12 $call T.expect (r, "the one in a frame runs at its scope's end",
                $call eq ($call C.ival (seen), 78))
  $decl rl  $call allocator.release ()
  $decl c13 $call T.expect (r, "release runs the arena's",
                $call eq ($call C.ival (seen), 786))
  $decl ret 0
}.ret

$decl main $func () {
  $decl r   $call T.results ()
  $decl a   $call in_arena (r)
  $decl d   $call deferring (r)
  $decl z   $set seen 0
  $decl i   $call idiom ()
  $decl c10 $call T.expect (r, "$defer $free beside the $alloc, the arena released last",
                $call eq ($call C.ival (seen), 5))
  $decl z2  $set seen 0
  $decl cs  $call constructed (r)
  $decl ret $call T.finish (r)
}.ret
