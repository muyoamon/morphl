// A round-trip fixture for §3.5's two storage kinds.
//
// `$new` makes **frame** storage: released when the scope exits, at no cost
// and with no allocator, and §5.3a stops it escaping. `$alloc` draws from the
// `allocator` in lexical scope and may outlive anything — which is what a
// structure handed back to a caller needs, so `cons` allocates its tail.
//
// §7.6 makes both a thin pointer, so the distinction costs nothing at run
// time; it exists to be checked.
//
// 30 from the frame cell, 2 for the list's length, 9 for its two elements. 41.

$decl P $import "../prelude"

$decl ints $specialize P.list 0

// Frame storage, used and finished with inside one scope — §5.3a's "one built
// and consumed inside a single scope may use `$new` and costs nothing".
$decl scaled $func ($decl n 0)
  { $decl acc $mut $new n
    $decl a   $set acc ($call mul ($call P.ival (acc), 3))
    $decl r   $call P.ival (acc) }.r

// A list *returned* to a caller: its cells outlive the frame that consed them,
// so prelude's `cons` allocates. §5.3a is explicit that this is the one place
// the distinction is felt in ordinary code.
$decl build $func ($decl n 0)
  $call ints.cons (n, $call ints.cons ($call add (n, 1), ints.nil))

$decl main $func ()
  { $decl xs $call build (4)
    $decl r  $call add ($call scaled (10),
                 $call add ($call ints.length (xs, 0), $call add ($call ints.nth (xs, 0),
                     $call ints.nth (xs, 1)))) }.r
