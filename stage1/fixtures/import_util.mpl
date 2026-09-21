// The module half of the `$import` fixture. §3.3: a file is a block, so this
// is one — its top-level `$decl`s are its members.

// A `$decl` that is not a `$func`: one cell, initialised once in source order
// (§4.10), which the backend gives a static of its own.
$decl bias 5

$decl double $func ($decl x 0) $call add (x, x)

// Names a member declared above it, and itself. Both resolve through the
// module, not through the importer — §4.14: "a file sees the root block plus
// what it imports, nothing else".
$decl biased $func ($decl x 0) $call add ($call double (x), bias)

$decl countdown $func ($decl n 0, $decl acc 0)
  $if ($call eq_int (n, 0)) acc ($call countdown ($call sub (n, 1), $call add (acc, n)))

// A template, exported. §4.9 memoises a specialisation per argument type, and
// the importer's `$specialize` of this is the first test that the memo and the
// module survive the trip across files.
$decl boxed $template T {
  $prop wrap $func ($decl x T) { $decl v x }
}
