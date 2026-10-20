// std/seq: what a sequence can do, and the algorithms over any value that can (STDLIB.md, D9).
//
// A **capability** is a trait of the members that do not mention the element type, so one
// trait serves every element type and a bound names only the sequence (D9, point 3):
// `seq_of S` is `is_empty` and `rest`, `sized_of S` is `length`. A `std/list` list has both.
// An algorithm takes `$decl S $traitsof ($specialize seq_of S)` and its body may still call
// `head`, which does mention the element type, because §4.9 types the body at the concrete
// `S`. Its generics are read off its arguments (§4.9's application), so a call needs none:
// `$call Q.count (xs)`, `$call Q.map (xs, $func ($decl n 0) …)`.
//
// The element type is never a generic of the algorithm itself — nothing would say what it
// is — so where it must be named, a helper takes one element as an example and reads the
// generic off that (`E`). That is also where the element's own equality or order is
// required, as `std/core`'s `eq_proto`/`ord_proto` bounds, checked at the call.
//
// Every recursion is a tail call, so §7.7 makes each a loop.

$decl C $import "std/core"
$decl L $import "std/list"

$decl seq_of   $template S { $prop is_empty $func () C.bool  $prop rest $func () S }
$decl sized_of $template S { $prop length $func () 0 }

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
