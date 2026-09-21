// A round-trip fixture for §4.14's `$import`.
//
// §3.3 makes a file a block and §4.14 makes `$import` load one, so a module is
// a namespace the compiler resolves — a projection onto it names the global
// its member was lifted to, and the module itself has no layout. Its members
// are lowered eagerly in source order, which is what makes `$decl bias`'s
// static get assigned before anything reads it (§4.10).
//
// 41 + 15 + 1 = 57.

$decl U $import "import_util"

// §4.14: "loaded once" — this resolves to the same file, so it is the same
// module and not a second copy of everything in it.
$decl V $import "import_util"

$decl ibox $specialize U.boxed 0

$decl main $func ()
  $call add ($call U.biased (18),
      $call add ($call V.countdown (5, 0), ($call ibox.wrap (1)).v))
