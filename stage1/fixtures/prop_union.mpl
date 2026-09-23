// A round-trip fixture for §4.8a read *twice*: a `$prop` whose value is a
// `$union`, projected more than once from the same module.
//
// §4.10 makes a prop compile-time, so lowering keeps its **source** and lowers
// it afresh at every projection — except that it memoises the result and, for
// a prop with nothing to rebuild, replays it as a bare literal of the prop's
// own type. That shortcut asked the wrong question: "does this type have
// `$decl` fields". A union has none, being no block at all, so the *second*
// and every later `ints.node` was emitted as a zeroed struct — §7.5's
// discriminator reading 0, which selects `cons`, with a null tail — instead of
// §4.8a's first member injected as `nil`. The first projection was correct, so
// nothing caught it until a function used two.
//
// `a` is the first projection and `b` the second; `c` is a third from another
// function, since the memo is per module and not per frame.
//
// 1 + 2 + 5 + 1 = 9.

$decl P $import "../prelude"

$decl ints $specialize P.list 0

// §4.2 types storage from its operand and §4.8a makes `node` evaluate to
// `nil`, so this is an empty list in storage wide enough for any list — the
// `$mut $new xs.node` idiom, with §5.3a's `$alloc` because it is returned.
$decl fresh $func () $mut $alloc ints.node

$decl main $func ()
  { $decl a  $mut $alloc ints.node
    $decl b  $mut $alloc ints.node
    $decl c  $call fresh ()
    $decl s1 $set a ($call ints.cons (4, $call ints.val (a)))
    $decl s2 $set b ($call ints.cons (5, $call ints.cons (6, $call ints.val (b))))
    $decl n0 $if ($call ints.is_nil ($call ints.val (c))) 1 0
    $decl r  $call add ($call ints.length ($call ints.val (a), 0),
                 $call add ($call ints.length ($call ints.val (b), 0),
                      $call add ($call ints.nth ($call ints.val (b), 0), n0))) }.r
