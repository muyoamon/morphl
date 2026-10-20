// std/seq: what a sequence can do, and the algorithms over any value that can (STDLIB.md, D9).
//
// A **capability** is a trait, and its generics are exactly the types its members mention:
//
// - `seq_of S` is `is_empty` and `rest`. `rest` answers the sequence itself, so the trait is
//   a template over the type that conforms — a list's `rest` is a list, a countdown's a
//   countdown.
// - `sized` is `length`, which mentions nothing, so it is a plain trait.
// - `indexed_of E` is `length` and `get`, random access. `get` answers the element, so the
//   trait is a template over `E`. A `std/vec` vec conforms; a `std/list` list does not, since
//   its positional read is `nth` and O(n), and "indexed" promises better.
//
// An algorithm takes `$decl S $traitsof ($specialize seq_of S)` and its body may still call
// `head`, which does mention the element type, because §4.9 types the body at the concrete
// `S`. Its generics are read off its arguments (§4.9's application), so a call needs none:
// `$call Q.count (xs)`, `$call Q.map (xs, $func ($decl n 0) …)`.
//
// Inference never reads a generic out of a bound, so an element type `E` must come from an
// argument: the value searched for, a function over elements, or — where the algorithm takes
// neither — one element passed to a helper as an example (`sort`, `max_of`). That is also
// where the element's own equality or order is required, as `std/core`'s `eq_proto`/
// `ord_proto` bounds, checked at the call.
//
// Every recursion is a tail call, so §7.7 makes each a loop.

$decl C $import "std/core"
$decl L $import "std/list"

$decl seq_of     $template S { $prop is_empty $func () C.bool  $prop rest $func () S }
$decl sized      { $prop length $func () 0 }
$decl indexed_of $template E { $prop length $func () 0  $prop get $func ($decl i 0) E }

// --------------------------------------------------------------- any sequence

$decl count $template ($decl S $traitsof ($specialize seq_of S))
  $func ($decl xs S, $decl n 0)
    $if ($call xs.is_empty ()) n ($call count ($call xs.rest (), $call add (n, 1)))

// Left to right: `f (f (acc, x0), x1)` and so on. `R` comes from `acc`, `A` from `f`.
$decl fold $template ($decl S $traitsof ($specialize seq_of S), R, A)
  $func ($decl xs S, $decl acc R, $decl f $func ($decl a R, $decl x A) R)
    $if ($call xs.is_empty ()) acc
        ($call fold ($call xs.rest (), $call f (acc, $call xs.head ()), f))

// `f` of each element, in order, for its effect.
$decl for_each $template ($decl S $traitsof ($specialize seq_of S), A, B)
  $func ($decl xs S, $decl f $func ($decl x A) B)
    $if ($call xs.is_empty ()) ()
        ($do ($call f ($call xs.head ())) ($call for_each ($call xs.rest (), f)))

$decl any $template ($decl S $traitsof ($specialize seq_of S), A)
  $func ($decl xs S, $decl p $func ($decl x A) C.bool)
    $if ($call xs.is_empty ()) false
        ($if ($call p ($call xs.head ())) true ($call any ($call xs.rest (), p)))
$decl all $template ($decl S $traitsof ($specialize seq_of S), A)
  $func ($decl xs S, $decl p $func ($decl x A) C.bool)
    $if ($call xs.is_empty ()) true
        ($if ($call p ($call xs.head ())) ($call all ($call xs.rest (), p)) false)

// The first element `p` accepts, as an option (§8).
$decl find $template ($decl S $traitsof ($specialize seq_of S), A)
  $func ($decl xs S, $decl p $func ($decl x A) C.bool)
    $if ($call xs.is_empty ()) none {
      $decl h    $call xs.head ()
      $decl ret2 $if ($call p (h)) ($call C.some (h)) ($call find ($call xs.rest (), p))
    }.ret2

// `f` of every element, as a `std/list` list of `f`'s result type `B`.
$decl map_go $template ($decl S $traitsof ($specialize seq_of S), A, B, O)
  $func ($decl xs S, $decl f $func ($decl x A) B, $decl acc O)
    $if ($call xs.is_empty ()) ($call acc.reverse ())
        ($call map_go ($call xs.rest (), f, $call acc.push ($call f ($call xs.head ()))))
$decl map $template ($decl S $traitsof ($specialize seq_of S), A, B)
  $func ($decl xs S, $decl f $func ($decl x A) B)
    $call map_go (xs, f, $call ($specialize L.list B).empty ())

// The elements of `xs`, in order, after those of `into` — a list whose type says which
// element type: `$call Q.to_list (xs, $call ints.empty ())`.
$decl to_list_go $template ($decl S $traitsof ($specialize seq_of S), O)
  $func ($decl xs S, $decl acc O)
    $if ($call xs.is_empty ()) ($call acc.reverse ())
        ($call to_list_go ($call xs.rest (), $call acc.push ($call xs.head ())))
$decl to_list $template ($decl S $traitsof ($specialize seq_of S), O)
  $func ($decl xs S, $decl into O) $call to_list_go (xs, $call into.reverse ())

// ------------------------------------------------- by the element's equality

// Whether `x` is an element, by the element's `eq`. `E` is `x`'s type, the element's.
$decl contains $template ($decl S $traitsof ($specialize seq_of S),
                          $decl E $traitsof ($specialize C.eq_proto E))
  $func ($decl xs S, $decl x E)
    $if ($call xs.is_empty ()) false
        ($if ($call x.eq ($call xs.head ())) true ($call contains ($call xs.rest (), x)))

// The position of the first element equal to `x`, as an option.
$decl index_of $template ($decl S $traitsof ($specialize seq_of S),
                          $decl E $traitsof ($specialize C.eq_proto E))
  $func ($decl xs S, $decl x E, $decl i 0)
    $if ($call xs.is_empty ()) none
        ($if ($call x.eq ($call xs.head ())) ($call C.some (i))
             ($call index_of ($call xs.rest (), x, $call add (i, 1))))

// ---------------------------------------------------- by the element's order

// `prev` is the element before `xs`, and the example that names `E`.
$decl sorted_go $template ($decl S $traitsof ($specialize seq_of S),
                           $decl E $traitsof ($specialize C.ord_proto E))
  $func ($decl xs S, $decl prev E)
    $if ($call xs.is_empty ()) true {
      $decl h    $call xs.head ()
      $decl ret2 $if ($call h.lt (prev)) false ($call sorted_go ($call xs.rest (), h))
    }.ret2
$decl is_sorted $template ($decl S $traitsof ($specialize seq_of S))
  $func ($decl xs S)
    $if ($call xs.is_empty ()) true ($call sorted_go ($call xs.rest (), $call xs.head ()))

// The greatest and the least, as options; on a tie the first.
$decl max_go $template ($decl S $traitsof ($specialize seq_of S),
                        $decl E $traitsof ($specialize C.ord_proto E))
  $func ($decl xs S, $decl best E)
    $if ($call xs.is_empty ()) best
        ($call max_go ($call xs.rest (), $call C.max_ord (best, $call xs.head ())))
$decl min_go $template ($decl S $traitsof ($specialize seq_of S),
                        $decl E $traitsof ($specialize C.ord_proto E))
  $func ($decl xs S, $decl best E)
    $if ($call xs.is_empty ()) best
        ($call min_go ($call xs.rest (), $call C.min_ord (best, $call xs.head ())))
$decl max_of $template ($decl S $traitsof ($specialize seq_of S))
  $func ($decl xs S)
    $if ($call xs.is_empty ()) none
        ($call C.some ($call max_go ($call xs.rest (), $call xs.head ())))
$decl min_of $template ($decl S $traitsof ($specialize seq_of S))
  $func ($decl xs S)
    $if ($call xs.is_empty ()) none
        ($call C.some ($call min_go ($call xs.rest (), $call xs.head ())))

// Sorted by the element's `lt`, stably, for a sequence that sorts by a function — a
// `std/list` list: `xs.sort_by` with `C.less`. `ex` names `E`.
$decl sort_as $template ($decl S $traitsof ($specialize seq_of S),
                         $decl E $traitsof ($specialize C.ord_proto E))
  $func ($decl xs S, $decl ex E)
    $call xs.sort_by ($func ($decl a ex, $decl b ex) $call C.less (a, b))
$decl sort $template ($decl S $traitsof ($specialize seq_of S))
  $func ($decl xs S) $if ($call xs.is_empty ()) xs ($call sort_as (xs, $call xs.head ()))

// ------------------------------------------------------- random access, sorted

// The first position of `x` in `xs`, sorted by `less`, as an option — O(log n) through
// `indexed_of`. Halving to the leftmost element not less than `x` finds the first of equal
// ones; it is `x` when `x` is not less than it either.
//
// **`xs` must be sorted by `less`**, and nothing checks it: sortedness is a fact about the
// values, not the type, so no trait can say it (a marker prop would be a claim, not a
// proof), and checking costs the O(n) the search exists to avoid — `is_sorted` is there for
// a caller who wants to. Unsorted input is still safe and never wrong: a `some i` has been
// compared with element `i` both ways, so it is always a position holding `x`. What it
// loses is completeness — `none` for a value that is present, and with duplicates not
// necessarily the first. A container that keeps its order by construction, `std/vec`'s
// `sorted_vec`, cannot be misused this way.
$decl lower_go $template (E, $decl S $traitsof ($specialize indexed_of E))
  $func ($decl xs S, $decl x E, $decl less $func ($decl a E, $decl b E) C.bool,
         $decl lo 0, $decl hi 0)
    $if ($call lt (lo, hi)) {
      $decl mid  $call div ($call add (lo, hi), 2)
      $decl ret2 $if ($call less ($call xs.get (mid), x))
                     ($call lower_go (xs, x, less, $call add (mid, 1), hi))
                     ($call lower_go (xs, x, less, lo, mid))
    }.ret2 lo
$decl search_by $template (E, $decl S $traitsof ($specialize indexed_of E))
  $func ($decl xs S, $decl x E, $decl less $func ($decl a E, $decl b E) C.bool) {
    $decl i   $call lower_go (xs, x, less, 0, $call xs.length ())
    $decl ret $if ($call lt (i, $call xs.length ()))
                  ($if ($call less (x, $call xs.get (i))) none ($call C.some (i))) none
  }.ret

// The same by the element's own `lt` (`std/core`'s `ord_proto`).
$decl search $template ($decl E $traitsof ($specialize C.ord_proto E),
                        $decl S $traitsof ($specialize indexed_of E))
  $func ($decl xs S, $decl x E)
    $call search_by (xs, x, $func ($decl a x, $decl b x) $call C.less (a, b))
