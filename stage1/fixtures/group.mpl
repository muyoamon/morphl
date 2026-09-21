// A round-trip fixture for §2.3's group as a value.
//
// §7.2: "Groups are laid out elementwise" — a struct whose members have
// positions instead of names, which is what `.n` indexes. §4.6's `.n` is
// one-based and applies to a group only; a block's members have names.
//
// 40 + 2 + 7 = 49.

$decl pair $func ($decl a 0, $decl b 0) (a, b)

// Nested, and of mixed element type, so the layout is not just two words.
$decl tagged $func ($decl n 0, $decl s "") (n, s, $call pair (n, 7))

$decl main $func ()
  { $decl p $call pair (40, 2)
    $decl t $call tagged (1, "x")
    $decl r $call add ($call add (p.1, p.2), (t.3).2) }.r
