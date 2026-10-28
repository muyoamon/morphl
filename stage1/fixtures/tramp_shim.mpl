// §6a's indirect case through a §7.4 shim. A function value used at another C signature is
// called through an adapter (`emit.mpl`, `emit_ad`), and so is an implementation's member
// whose signature differs from its trait's (`emit_tad`) or one trait object used as another
// (`emit_ad` with a slot). Each adapter used to drive a chain its call started before
// returning, so a chain whose every hop passed through one nested an adapter's frame and a
// driver's per hop, and 2,000,000 hops overflowed the stack (§7.7). Where the result needs
// no coercion the adapter's call is its tail call, and a pending block it leaves now goes
// back to its caller, which drives.
//
// The digits: a chain through a function shim (7), through a trait table's adapter (8),
// through a re-tabled object's thunk (6), each 2,000,000 hops at -O0; and a shim that does
// coerce its result, so must still drive what its call left pending (4, or 0 if it does
// not: the chain's answer lands in the caller's slot without the re-tag). 7864.

// 1. A function shim: `down` takes `{a}` and is stored where `({a, b}) -> Int` is expected.
$decl cell $mut $alloc $func ($decl x { $decl a 0  $decl b 0 }) 0
$decl down $func ($decl x { $decl a 0 }) $if ($call eq (x.a, 0)) 7
    ($call cell ({ $decl a ($call sub (x.a, 1))  $decl b 0 }))
$decl w0   $set cell down

// 2. A table's adapter: `eater`'s member takes `{a}` where the trait's passes `{a, b}`.
$decl eat_proto { $prop eat $func ($decl x { $decl a 0  $decl b 0 }) 0 }
$decl as_eat    $func ($decl p $traitsof eat_proto) p
$decl e_dummy   $alloc eat_proto
$decl e_cell    $mut $alloc $call as_eat (e_dummy)
$decl eater     $alloc { $prop eat $func ($decl x { $decl a 0 }) $if ($call eq (x.a, 0)) 8
    ($call e_cell.eat ({ $decl a ($call sub (x.a, 1))  $decl b 0 })) }
$decl w1        $set e_cell $call as_eat (eater)

// 3. A re-tabled object: a `short` object used as a `long` one, whose member passes more.
$decl short_proto { $prop eat $func ($decl x { $decl a 0 }) 0 }
$decl long_proto  { $prop eat $func ($decl x { $decl a 0  $decl b 0 }) 0 }
$decl as_short    $func ($decl p $traitsof short_proto) p
$decl as_long     $func ($decl p $traitsof long_proto) p
$decl l_dummy     $alloc long_proto
$decl l_cell      $mut $alloc $call as_long (l_dummy)
$decl shorter     $alloc { $prop eat $func ($decl x { $decl a 0 }) $if ($call eq (x.a, 0)) 6
    ($call l_cell.eat ({ $decl a ($call sub (x.a, 1))  $decl b 0 })) }
$decl w2          $set l_cell $call as_long ($call as_short (shorter))

// 4. A shim re-tagging the result: `mk` answers `<b, c>` and reports its tail call, and the
//    shim reading it as `<a, b, c>` moves `b` from discriminator 0 to 1 — so it has to finish
//    the chain before it can re-tag, or the caller reads `b`'s answer as an `a`.
$decl c_two    $mut $alloc $func ($decl n 0)
    $union ({ $prop tag "b"  $decl v 0 }, { $prop tag "c" })
$decl mk       $func ($decl n 0) $if ($call eq (n, 0)) { $prop tag "b"  $decl v 4 }
    ($call c_two ($call sub (n, 1)))
$decl w3       $set c_two mk
$decl c_three  $mut $alloc $func ($decl n 0)
    $union ({ $prop tag "a" }, { $prop tag "b"  $decl v 0 }, { $prop tag "c" })
$decl w4       $set c_three mk
$decl b_of     $func ($decl n 0) {
  $decl r   $call c_three (n)
  $decl ret $match r ($case { $prop tag "b" } r.v, $case r 0)
}.ret

$decl d $func ($decl acc 0, $decl x 0) $call add ($call mul (acc, 10), x)

$decl main $func () {
  $decl a   $call cell ({ $decl a 2000000  $decl b 0 })
  $decl b   $call e_cell.eat ({ $decl a 2000000  $decl b 0 })
  $decl c   $call l_cell.eat ({ $decl a 2000000  $decl b 0 })
  $decl e   $call b_of (1000)
  $decl ret $call d ($call d ($call d (a, b), c), e)
}.ret
