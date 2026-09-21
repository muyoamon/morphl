// A round-trip fixture for §4.9's monomorphisation.
//
// "$specialize substitutes the argument for the generic, types the substituted
// expression with ordinary rules, and has exactly its type." By the time the
// backend sees this there is no template left — ir.mpl has no `$template` node,
// because a monomorphic program is what makes a block type a C struct (§7.2).
//
// 40 + 2 + 1 = 43.

$decl pair $template T {
  $prop make $func ($decl a T, $decl b T) { $decl fst a  $decl snd b }

  // A sibling prop in a *parameter default*: §3.4 makes the default fix the
  // type, and §5.7 never evaluates it, so this names `make` purely to say what
  // shape `p` is. The generic reaches it the same way.
  $prop swap $func ($decl p $call make (T, T)) $call make (p.snd, p.fst)
}

// Two specialisations at two argument types. §4.9 memoises per argument type,
// so these are two different sets of lifted functions — and a third use at
// `Int` would share the first's rather than emit its own.
$decl ipair $specialize pair 0
$decl spair $specialize pair ""

$decl main $func ()
  { $decl p $call ipair.make (40, 2)
    $decl q $call ipair.swap (p)
    $decl s $call spair.make ("a", "b")
    $decl r $call add ($call add (p.fst, q.fst), $call len (s.fst)) }.r
