// std/list: an immutable singly linked list, `$specialize L.list <example>` per element
// type — `$decl ints $specialize L.list 0`. A list is a **value carrying its operations**
// (STDLIB.md, D9): `$call ints.empty ()` and `$call ints.of (cells)` make one, and
// `$call xs.push (3)`, `$call xs.length ()` and `$call xs.rest ()` work on any list value,
// with nothing inferred. A parameter typed "a list of `Int`" is defaulted to an empty one,
// `$decl xs ($call ints.empty ())`, since a type is the type of an expression.
//
// The methods are the operations that keep the element type. Those that make another —
// `map`, `fold` — and those needing the element's own equality or order — `contains`,
// `sort` — are free algorithms over any sequence, in `std/seq`: a template-valued member
// cannot read its receiver (D9, point 4). `head` panics on an empty list, which is a bug
// (§4.15), and `first` is the option form; algorithms use `is_empty`/`head`/`rest`.
//
// The wrapper is only props over one field, `cells` — the `node` union, for code that wants
// to `$match` — so it is the cells' own C struct, and a method costs a call. `cell` holds the
// same operations over bare cells, which is what the methods are written in.
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

  $prop cell {
    $prop cons $func ($decl h T, $decl t node) { $prop tag "cons"  $decl head h  $decl tail $alloc t }

    // A list read out of storage (§5.4), as `C.ival` reads an `Int`.
    $prop val $func ($decl xs node) xs

    $prop is_nil $func ($decl xs node) $match xs (
      $case {$prop tag "cons"} false,
      $case xs true
    )
    $prop head $func ($decl xs node) $match xs (
      $case {$prop tag "cons"} xs.head,
      $case xs ($call panic ("head of an empty list"))
    )
    $prop first $func ($decl xs node) $match xs (
      $case {$prop tag "cons"} $call C.some (xs.head),
      $case xs none
    )
    // The empty list's rest is itself.
    $prop rest $func ($decl xs node) $match xs (
      $case {$prop tag "cons"} $call val (xs.tail),
      $case xs xs
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
  }

  // A list value over `c`. Each member reads the receiver (§4.10), so `xs.push` is a
  // closure over `xs`; one that answers a list answers it through `of` again.
  $prop of $func ($decl c node) {
    $decl w   {
      $decl cells c
      $prop is_empty $func () $call cell.is_nil (w.cells)
      $prop head     $func () $call cell.head (w.cells)
      $prop first    $func () $call cell.first (w.cells)
      $prop rest     $func () $call of ($call cell.rest (w.cells))
      $prop push     $func ($decl x T) $call of ($call cell.cons (x, w.cells))
      $prop length   $func () $call cell.length (w.cells, 0)
      $prop reverse  $func () $call of ($call cell.reverse (w.cells, nil))
      // A parameter defaulted to `w` is a list of the same type (§4.10: the declaring name,
      // in a member's default, is the block's type).
      $prop append   $func ($decl ys w) $call of ($call cell.append (w.cells, ys.cells))
      $prop nth      $func ($decl i 0) $call cell.nth (w.cells, i)
      $prop take     $func ($decl n 0) $call of ($call cell.take (w.cells, n, nil))
      $prop drop     $func ($decl n 0) $call of ($call cell.drop (w.cells, n))
      $prop filter   $func ($decl p $func ($decl x T) C.bool)
        $call of ($call cell.filter (w.cells, p, nil))
      $prop any      $func ($decl p $func ($decl x T) C.bool) $call cell.any (w.cells, p)
      $prop all      $func ($decl p $func ($decl x T) C.bool) $call cell.all (w.cells, p)
      $prop find     $func ($decl p $func ($decl x T) C.bool) $call cell.find (w.cells, p)
      $prop sort_by  $func ($decl less $func ($decl a T, $decl b T) C.bool)
        $call of ($call cell.sort_by (w.cells, less))
    }
    $decl ret w
  }.ret

  $prop empty      $func () $call of (nil)
  $prop from_array $func ($decl a $call array (0, T))
    $call of ($call cell.of_array (a, $call alen (a), nil))
}
