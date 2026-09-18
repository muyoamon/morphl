// Stage-1 prelude: what SPEC.md §8 calls library code, written inside the
// BOOTSTRAP.md §1 subset.
//
// This is morphl source compiled by stage 1 and *run* by stage 0, so every
// rule in BOOTSTRAP.md §4 applies: catch-all arms everywhere, specific arms
// first, values read out of storage explicitly, and tail position preserved
// wherever a function recurses.

// §8's sanity check that the core suffices, verbatim.
$decl not $func ($decl b true) $match b ($case true false, $case false true)

// **Strict, not short-circuiting.** Evaluation is left to right and arguments
// are always evaluated (§7.1), so `$call and (p, q)` evaluates `q` even when
// `p` is false. A guard whose second operand is only safe when the first holds
// must use nested `$if` instead. The lexer avoids the problem by making `peek`
// return -1 past the end rather than panicking.
$decl and $func ($decl a true, $decl b true) $if a b false
$decl or  $func ($decl a true, $decl b true) $if a true b

// Read a value *out of* storage.
//
// §5.4 makes a reference transparent only where a value is expected, and a
// `$decl` initializer is explicitly not such a place — `$decl y n` aliases
// (§12 says so). Passing through a parameter whose default is a value is the
// way to snapshot the contents of a cell into an immutable binding.
$decl ival $func ($decl x 0) x
$decl sval $func ($decl s "") s

// A singly linked list.
//
// §12's version implements `map` by self-specializing (`$specialize list U`
// inside `list`), which BOOTSTRAP.md §1.1 excludes; this one stays within a
// single element type, and each caller specializes it once. `$specialize` is
// always explicit here — §1.1 also drops `$call`-time inference of `T`.
$decl list $template T {
  $prop nil  { $prop tag "nil" }

  // Recursive data the only way §5.5 offers: a `$union` whose later member
  // names the type being defined. That member is a type-only position (§5.7),
  // so it is never evaluated.
  $prop node $union (nil, { $prop tag "cons"  $decl head T  $decl tail node })

  $prop cons $func ($decl h T, $decl t node) { $prop tag "cons"  $decl head h  $decl tail t }

  $prop is_nil $func ($decl xs node) $match xs (
    $case {$prop tag "cons"} false,
    $case xs true
  )

  $prop length $func ($decl xs node, $decl acc 0) $match xs (
    $case {$prop tag "cons"} $call length (xs.tail, $call add (acc, 1)),
    $case xs acc
  )

  $prop reverse $func ($decl xs node, $decl acc node) $match xs (
    $case {$prop tag "cons"} $call reverse (xs.tail, $call cons (xs.head, acc)),
    $case xs acc
  )

  // Out of range is a bug, not an expected failure, so it panics (§4.15:
  // "Expected failures are values; bugs panic").
  $prop nth $func ($decl xs node, $decl i 0) $match xs (
    $case {$prop tag "cons"}
      $if ($call eq_int (i, 0)) xs.head ($call nth (xs.tail, $call sub (i, 1))),
    $case xs ($call panic ("nth: index out of range"))
  )
}

// A span, and a reader for it.
//
// §5.1 matches blocks by ordered prefix, and every token and every AST node
// begins with `line` then `col`, so this one accessor is typed to accept all of
// them — no per-kind dispatch, and the upcast is free (§7.4). It is the clearest
// payoff of the prefix rule in this codebase.
$decl proto_span { $decl line 0  $decl col 0 }
$decl span_of $func ($decl x proto_span) { $decl line x.line  $decl col x.col }
