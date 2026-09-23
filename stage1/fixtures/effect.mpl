// A round-trip fixture for §3.3's "a non-`$decl` expression runs for effect and
// is discarded" — the *value* is discarded, not the expression.
//
// §4.10 runs a file's items once in source order, so such an item has a
// position among them and the backend has to keep it. It was dropped outright:
// `lower_top` walks the file type's **fields**, so an item declaring nothing
// was never reached, and `file_props_at` skipped one in a module for the same
// reason. Nothing in stage 1 noticed until the compiled `parser.mpl` — whose
// §2.2 arity table is twenty-three of these — answered `unknown keyword
// '$decl'` for every form it was given.
//
// Both halves are covered because they are separate paths: `here` is an item
// of the entry file, `effect_util.mpl`'s two are members of a module.
//
// Order is the other half of the claim. `$set` is not commutative with the
// read below it, so `seen` is 4 only if the item ran *before* `$decl seen` and
// after `$decl slot` — which is what §4.10's source order means.
$decl P $import "../prelude"
$decl U $import "effect_util"

$decl slot $mut $alloc 0

$call P.ival ($set slot 4)

$decl seen $call P.ival (slot)

// 4 + 6 + 36 = 46.
$decl main $func ()
  { $decl r $call add (seen, $call add (U.snapshot, $call U.total ())) }.r
