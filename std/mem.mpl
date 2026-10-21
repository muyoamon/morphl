// std/mem: allocators written in morphl, over §8's raw memory (STDLIB.md, D5).
//
// §7.6 resolves `allocator` where `$alloc` is *written*, so an arena serves the code in
// the scope that binds it and nothing else — a function written elsewhere still draws
// from whatever its own scope binds, the root's unless it says otherwise:
//
//   $decl M $import "std/mem"
//   $decl work $func () {
//     $decl allocator $call M.arena (65536)
//     $decl cell      $mut $alloc 0          // from the arena
//     …
//     $decl done      $call allocator.release ()
//     $decl ret …
//   }.ret
//
// Releasing is the author's decision and the author's responsibility (§4.2a): storage
// read after its allocator released it is the author's error, and nothing checks it.

$decl C $import "std/core"
$decl L $import "std/list"

// DEFER.md step 4: what `$alloc { … $defer … }` registers — the storage's address and the
// function running its deferrals — held newest first.
$decl fin       $func ($decl a 0, $decl f $func () ()) { $decl at a  $decl run f }
$decl proto_fin $call fin (0, $func () ())
$decl fins      $specialize L.list proto_fin
$decl fc        fins.cell

// The finaliser registered for `addr` run and taken out; the others kept, in order.
$decl run_at $func ($decl xs fins.node, $decl addr 0, $decl acc fins.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq (xs.head.at, addr))
        ($do ($call xs.head.run ()) ($call fc.reverse (acc, $call fc.val (xs.tail))))
        ($call run_at ($call fc.val (xs.tail), addr, $call fc.cons (xs.head, acc))),
  $case xs ($call fc.reverse (acc, fins.nil))
)
// Every finaliser, newest first — the reverse of registration, as a scope's deferrals run.
$decl run_all $func ($decl xs fins.node) $match xs (
  $case {$prop tag "cons"} $do ($call xs.head.run ()) ($call run_all ($call fc.val (xs.tail))),
  $case xs ()
)

// A bump arena of `cap` bytes. `alloc` hands out the next 16-aligned slice and panics
// when there is none, since an `$alloc` that came back empty would be a store through a
// null pointer; `free` gives nothing back, as an arena's does, but runs what `$alloc`
// registered for that storage (DEFER.md: `defer_at`); `reset` takes everything back at
// once and `release` returns the memory itself, both running every finaliser still
// registered first, newest first; and `used` is the bytes handed out.
// The state is the arena's own cells — reached through the receiver (§4.10), so a program
// may have as many arenas as it likes — made from the root allocator, which is what this
// function's scope binds.
$decl arena $func ($decl cap 0) {
  $decl b   $call raw_alloc (cap)
  $decl ok  $if ($if ($call lt (0, cap)) ($call eq (b, 0)) false)
                ($call panic ("arena: out of memory")) 0
  $decl a   { $decl base b  $decl top $mut $alloc b  $decl end $call add (b, cap)
    $decl fns $mut $alloc fins.node
    $prop alloc $func ($decl size 0) {
      $decl sz  $call mul ($call div ($call add (size, 15), 16), 16)
      $decl p   $call C.ival (a.top)
      $decl ok2 $if ($call lt (a.end, $call add (p, sz))) ($call panic ("arena: full")) 0
      $decl w   $set a.top ($call add (p, sz))
      $decl ret p
    }.ret
    $prop free    $func ($decl addr 0, $decl size 0)
      $do ($set a.fns ($call run_at ($call fc.val (a.fns), addr, fins.nil))) ()
    $prop defer_at $func ($decl addr 0, $decl f $func () ())
      $do ($set a.fns ($call fc.cons ($call fin (addr, f), $call fc.val (a.fns)))) ()
    $prop reset   $func () $do ($call run_all ($call fc.val (a.fns)))
      ($do ($set a.fns fins.nil) ($set a.top a.base))
    $prop release $func () $do ($call run_all ($call fc.val (a.fns)))
      ($do ($set a.fns fins.nil) ($call raw_free (a.base)))
    $prop used    $func () $call sub ($call C.ival (a.top), a.base)
  }
  $decl ret a
}.ret
