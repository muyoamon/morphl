// std/vec: a growable array, `$specialize V.vec <example>` per element type —
// `$decl ivec $specialize V.vec 0` — over §8's arrays (STDLIB.md, P3).
//
// A vec is a value carrying its operations, as a `std/list` list is (D9), but it changes
// in place: its array and its count live in `$mut $alloc` cells, which every copy of the
// value shares (D9, "Mutation"). `$call ivec.new (8)` makes one with room for 8; `push`
// doubles the room when it runs out, so a run of pushes costs O(1) each, amortised.
// `get` and `set` panic outside `0 .. length () - 1`, which is a bug (§4.15), and `pop`
// answers an option. `items` is the elements as a `std/seq` sequence, from the front.

$decl C $import "std/core"
$decl L $import "std/list"
$decl Q $import "std/seq"

$decl in_range $func ($decl i 0, $decl n 0) $if ($call lt (i, 0)) false ($call lt (i, n))

$decl vec $template T {
  $prop list $specialize L.list T

  // An element read out of the array (§5.4: `at` answers a reference, and a function's
  // result keeps one), as `C.ival` reads an `Int`.
  $prop val $func ($decl x T) x

  // `src`'s first `n` elements into `dst`.
  $prop copy $func ($decl src $call array (0, T), $decl dst $call array (0, T), $decl i 0,
                    $decl n 0)
    $if ($call lt (i, n))
        ($do ($set ($call at (dst, i)) ($call at (src, i)))
             ($call copy (src, dst, $call add (i, 1), n)))
        ()

  $prop new $func ($decl cap 0) {
    $decl v   {
      $decl data $mut $alloc ($call array (0, T))
      $decl n    $mut $alloc 0
      $prop length   $func () $call C.ival (v.n)
      $prop is_empty $func () $call eq ($call C.ival (v.n), 0)
      $prop capacity $func () $call alen (v.data)
      $prop push $func ($decl x T) {
        $decl k   $call C.ival (v.n)
        $decl old v.data
        // Full: a new array of twice the room, the elements copied across. `x` fills
        // it, since an array is made from an example (§8).
        $decl g   $if ($call eq (k, $call alen (old))) {
          $decl d    $call array ($call C.max_int ($call mul (k, 2), 4), x)
          $decl c    $call copy (old, d, 0, k)
          $decl s    $set v.data d
          $decl ret2 0
        }.ret2 0
        $decl w   $set ($call at (v.data, k)) x
        $decl ret $set v.n ($call add (k, 1))
      }.ret
      $prop get $func ($decl i 0)
        $if ($call in_range (i, $call C.ival (v.n))) ($call val ($call at (v.data, i)))
            ($call panic ("vec: get out of range"))
      $prop set $func ($decl i 0, $decl x T)
        $if ($call in_range (i, $call C.ival (v.n))) ($set ($call at (v.data, i)) x)
            ($call panic ("vec: set out of range"))
      // The last element, removed, as an option.
      $prop pop $func ()
        $if ($call eq ($call C.ival (v.n), 0)) none {
          $decl k    $call sub ($call C.ival (v.n), 1)
          $decl s    $set v.n k
          $decl ret2 $call C.some ($call val ($call at (v.data, k)))
        }.ret2
      $prop clear $func () $set v.n 0
      $prop items $func () $call view (v, 0)
      // The elements as a `std/list` list, in order.
      $prop to_list $func () $call list_go (v, $call sub ($call C.ival (v.n), 1),
                                             $call list.empty ())
    }
    $decl c   $if ($call lt (0, cap)) ($set v.data ($call array (cap, T))) ($call array (0, T))
    $decl ret v
  }.ret

  // From the back, pushing, so the list comes out in order.
  $prop list_go $func ($decl v ($call new (0)), $decl i 0, $decl acc ($call list.empty ()))
    $if ($call lt (i, 0)) acc
        ($call list_go (v, $call sub (i, 1), $call acc.push ($call v.get (i))))

  // A sequence over `v` from index `i`: what it reads is the vec as it is then.
  // A member reads only its receiver (§4.10), so the vec is a field.
  $prop view $func ($decl v ($call new (0)), $decl i 0) {
    $decl w   {
      $decl src  v
      $decl from i
      $prop is_empty $func () $call C.not ($call lt (w.from, $call w.src.length ()))
      $prop head     $func () $call w.src.get (w.from)
      $prop rest     $func () $call view (w.src, $call add (w.from, 1))
    }
    $decl ret w
  }.ret
}

// ---------------------------------------------------------------- sorted_vec

// A vec kept in the order `less` gives, by construction: `insert` puts an element after any
// equal to it, so equal elements keep the order they arrived in, and nothing can write a
// position — there is no `set` and no `push`. So `search` needs no precondition, unlike
// `std/seq`'s, which it is: a `sorted_vec` is `indexed_of` too.
//
//   $decl isv $specialize V.sorted_vec 0
//   $decl s   $call isv.new ($func ($decl a 0, $decl b 0) $call lt (a, b))
//
// `insert` and `remove` move the elements after the position, O(n); `search`, `get`,
// `min` and `max` are O(log n) or better.
$decl sorted_vec $template T {
  $prop base $specialize vec T

  // The first position whose element `x` is less than: where `x` goes after its equals.
  $prop upper_go $func ($decl v ($call base.new (0)), $decl x T,
                        $decl less $func ($decl a T, $decl b T) C.bool, $decl lo 0, $decl hi 0)
    $if ($call lt (lo, hi)) {
      $decl mid  $call div ($call add (lo, hi), 2)
      $decl ret2 $if ($call less (x, $call v.get (mid)))
                     ($call upper_go (v, x, less, lo, mid))
                     ($call upper_go (v, x, less, $call add (mid, 1), hi))
    }.ret2 lo

  // Each element from `j - 1` down to `i` moved up one place.
  $prop shift_up $func ($decl v ($call base.new (0)), $decl i 0, $decl j 0)
    $if ($call lt (i, j))
        ($do ($call v.set (j, $call v.get ($call sub (j, 1))))
             ($call shift_up (v, i, $call sub (j, 1))))
        ()
  // Each element from `i + 1` up to `n - 1` moved down one place.
  $prop shift_down $func ($decl v ($call base.new (0)), $decl i 0, $decl n 0)
    $if ($call lt ($call add (i, 1), n))
        ($do ($call v.set (i, $call v.get ($call add (i, 1))))
             ($call shift_down (v, $call add (i, 1), n)))
        ()

  $prop new $func ($decl l $func ($decl a T, $decl b T) C.bool, $decl cap 0) {
    $decl s   {
      $decl data $call base.new (cap)
      $decl less l
      $prop length   $func () $call s.data.length ()
      $prop is_empty $func () $call s.data.is_empty ()
      $prop get      $func ($decl i 0) $call s.data.get (i)
      $prop insert   $func ($decl x T) {
        $decl i   $call upper_go (s.data, x, s.less, 0, $call s.data.length ())
        $decl n   $call s.data.length ()
        $decl p   $call s.data.push (x)
        $decl u   $call shift_up (s.data, i, n)
        $decl ret $call s.data.set (i, x)
      }.ret
      // The first position holding `x`, as an option.
      $prop search   $func ($decl x T) $call Q.search_by (s.data, x, s.less)
      // The first element equal to `x` taken out; whether there was one.
      $prop remove   $func ($decl x T) {
        $decl o   $call Q.search_by (s.data, x, s.less)
        $decl ret $match o (
            $case {$prop tag "some"} {
              $decl d    $call shift_down (s.data, o.v, $call s.data.length ())
              $decl q    $call s.data.pop ()
              $decl ret2 true
            }.ret2,
            $case o false
          )
      }.ret
      $prop min      $func ()
        $if ($call s.data.is_empty ()) none ($call C.some ($call s.data.get (0)))
      $prop max      $func ()
        $if ($call s.data.is_empty ()) none
            ($call C.some ($call s.data.get ($call sub ($call s.data.length (), 1))))
      $prop clear    $func () $call s.data.clear ()
      $prop items    $func () $call s.data.items ()
      $prop to_list  $func () $call s.data.to_list ()
    }
    $decl ret s
  }.ret
}
