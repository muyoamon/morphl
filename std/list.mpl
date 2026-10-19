// std/list: an immutable singly linked list, `$specialize L.list <example>` per element
// type — `$decl ints $specialize L.list 0` — with the operations as its members, so
// `$call ints.length (xs)` needs nothing inferred. `map` and `fold` introduce a second
// type and are templates themselves, whose generics §4.9's application reads off the
// function argument: `$call ints.map (xs, $func ($decl n 0) …)`.
//
// Every recursion is a tail call, so §7.7 makes each a loop: a list's length bounds
// nothing but its memory. `sort_by`'s halving recursion is the exception, and it is
// log₂ n deep.

$decl C $import "std/core"

$decl list $template T {
  $prop nil  { $prop tag "nil" }

  // §5.5: recursive data is a `$union` whose later member names the type being made,
  // through storage — `$alloc`, since a list is what a function hands back (§5.3a).
  $prop node $union (nil, { $prop tag "cons"  $decl head T  $decl tail $alloc node })

  $prop cons $func ($decl h T, $decl t node) { $prop tag "cons"  $decl head h  $decl tail $alloc t }

  // A list read out of storage (§5.4), as `C.ival` reads an `Int`.
  $prop val $func ($decl xs node) xs

  $prop is_nil $func ($decl xs node) $match xs (
    $case {$prop tag "cons"} false,
    $case xs true
  )

  $prop length $func ($decl xs node, $decl acc 0) $match xs (
    $case {$prop tag "cons"} $call length (xs.tail, $call add (acc, 1)),
    $case xs acc
  )

  // `xs` reversed in front of `acc`.
  $prop reverse $func ($decl xs node, $decl acc node) $match xs (
    $case {$prop tag "cons"} $call reverse (xs.tail, $call cons (xs.head, acc)),
    $case xs acc
  )

  $prop append $func ($decl xs node, $decl ys node) $call reverse ($call reverse (xs, nil), ys)

  // Out of range is a bug, not an expected failure, so it panics (§4.15).
  $prop nth $func ($decl xs node, $decl i 0) $match xs (
    $case {$prop tag "cons"}
      $if ($call eq (i, 0)) xs.head ($call nth (xs.tail, $call sub (i, 1))),
    $case xs ($call panic ("nth: index out of range"))
  )

  // The first `n`, or all of a shorter list; and what follows them.
  $prop take $func ($decl xs node, $decl n 0, $decl acc node) $match xs (
    $case {$prop tag "cons"}
      $if ($call lt (0, n)) ($call take (xs.tail, $call sub (n, 1), $call cons (xs.head, acc)))
          ($call reverse (acc, nil)),
    $case xs ($call reverse (acc, nil))
  )
  $prop drop $func ($decl xs node, $decl n 0) $match xs (
    $case {$prop tag "cons"} $if ($call lt (0, n)) ($call drop (xs.tail, $call sub (n, 1))) xs,
    $case xs xs
  )

  $prop any $func ($decl xs node, $decl p $func ($decl x T) C.bool) $match xs (
    $case {$prop tag "cons"} $if ($call p (xs.head)) true ($call any (xs.tail, p)),
    $case xs false
  )
  $prop all $func ($decl xs node, $decl p $func ($decl x T) C.bool) $match xs (
    $case {$prop tag "cons"} $if ($call p (xs.head)) ($call all (xs.tail, p)) false,
    $case xs true
  )

  // The first element `p` accepts, as an option (§8).
  $prop find $func ($decl xs node, $decl p $func ($decl x T) C.bool) $match xs (
    $case {$prop tag "cons"}
      $if ($call p (xs.head)) ($call C.some (xs.head)) ($call find (xs.tail, p)),
    $case xs none
  )

  $prop filter $func ($decl xs node, $decl p $func ($decl x T) C.bool, $decl acc node)
    $match xs (
      $case {$prop tag "cons"}
        $call filter (xs.tail, p, $if ($call p (xs.head)) ($call cons (xs.head, acc)) acc),
      $case xs ($call reverse (acc, nil))
    )

  // A stable merge sort by `less`: halves, so equal elements keep their order because
  // `merge` takes from the left unless the right is strictly less. Not named `lt`, which
  // would shadow the intrinsic `sort_by` needs.
  $prop merge $func ($decl xs node, $decl ys node,
                     $decl less $func ($decl a T, $decl b T) C.bool, $decl acc node) $match xs (
    $case {$prop tag "cons"} $match ys (
      $case {$prop tag "cons"}
        $if ($call less (ys.head, xs.head))
            ($call merge (xs, ys.tail, less, $call cons (ys.head, acc)))
            ($call merge (xs.tail, ys, less, $call cons (xs.head, acc))),
      $case ys ($call reverse (acc, xs))),
    $case xs ($call reverse (acc, ys))
  )
  $prop sort_by $func ($decl xs node, $decl less $func ($decl a T, $decl b T) C.bool) {
    $decl n   $call length (xs, 0)
    $decl h   $call div (n, 2)
    $decl ret $if ($call lt (n, 2)) xs
                  ($call merge ($call sort_by ($call take (xs, h, nil), less),
                                $call sort_by ($call drop (xs, h), less), less, nil))
  }.ret

  // The elements of an array, in order (§8).
  // No block around the recursion: §7.7 would make it a frame per element.
  $prop of_array $func ($decl a $call array (0, T), $decl i 0, $decl acc node)
    $if ($call lt (0, i))
        ($call of_array (a, $call sub (i, 1), $call cons ($call at (a, $call sub (i, 1)), acc)))
        acc
  $prop from_array $func ($decl a $call array (0, T)) $call of_array (a, $call alen (a), nil)

  // `f` of every element. `B` comes from `f`'s result, and the new list is `list B` —
  // the template specialising itself (§4.9), memoised per element type.
  $prop map_go $template B $func ($decl xs node, $decl f $func ($decl x T) B,
                                  $decl acc ($specialize list B).node) $match xs (
    $case {$prop tag "cons"}
      $call map_go (xs.tail, f, $call ($specialize list B).cons ($call f (xs.head), acc)),
    $case xs $call ($specialize list B).reverse (acc, ($specialize list B).nil)
  )
  $prop map $template B $func ($decl xs node, $decl f $func ($decl x T) B)
    $call map_go (xs, f, ($specialize list B).nil)

  // Left to right: `f (f (acc, x0), x1)` and so on. `R` comes from `acc`.
  $prop fold $template R $func ($decl xs node, $decl acc R,
                                $decl f $func ($decl a R, $decl x T) R) $match xs (
    $case {$prop tag "cons"} $call fold (xs.tail, $call f (acc, xs.head), f),
    $case xs acc
  )
}
