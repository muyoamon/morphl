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

// A bump arena of `cap` bytes. `alloc` hands out the next 16-aligned slice and panics
// when there is none, since an `$alloc` that came back empty would be a store through a
// null pointer; `free` gives nothing back, as an arena's does; `reset` takes everything
// back at once, `release` returns the memory itself, and `used` is the bytes handed out.
// The state is the arena's own cells — reached through the receiver (§4.10), so a program
// may have as many arenas as it likes — made from the root allocator, which is what this
// function's scope binds.
$decl arena $func ($decl cap 0) {
  $decl b   $call raw_alloc (cap)
  $decl ok  $if ($if ($call lt (0, cap)) ($call eq (b, 0)) false)
                ($call panic ("arena: out of memory")) 0
  $decl a   { $decl base b  $decl top $mut $alloc b  $decl end $call add (b, cap)
    $prop alloc $func ($decl size 0) {
      $decl sz  $call mul ($call div ($call add (size, 15), 16), 16)
      $decl p   $call C.ival (a.top)
      $decl ok2 $if ($call lt (a.end, $call add (p, sz))) ($call panic ("arena: full")) 0
      $decl w   $set a.top ($call add (p, sz))
      $decl ret p
    }.ret
    $prop free    $func ($decl addr 0) ()
    $prop reset   $func () $set a.top a.base
    $prop release $func () $call raw_free (a.base)
    $prop used    $func () $call sub ($call C.ival (a.top), a.base)
  }
  $decl ret a
}.ret
