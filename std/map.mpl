// std/map: an ordered map, `$specialize M.map (<key example>, <value example>)` per pair of
// types — `$decl ages $specialize M.map ("", 0)` — over `std/vec` (STDLIB.md, D9).
//
//   $decl m $call ages.new (S.less)              // `std/str`'s order on `Str`
//   $call m.put ("ada", 36)          $call m.get ("ada")      // some 36
//
// The keys are kept sorted by `less` in one vec and the values beside them in another, by
// construction, as `sorted_vec` keeps its elements: so a lookup is a binary search, O(log
// n), and needs no precondition. Two keys are the same key when neither is less than the
// other. `put` and `remove` move the entries after the position, O(n) — the right trade for
// a map built once and read often; a balanced tree is the version for one that is not.
// Like a vec it changes in place, and every copy of a map is the same map (D9, "Mutation").

$decl C $import "std/core"
$decl Q $import "std/seq"
$decl V $import "std/vec"

$decl map $template (K, V0) {
  $prop kvec $specialize V.vec K
  $prop vvec $specialize V.vec V0

  $prop new $func ($decl l $func ($decl a K, $decl b K) C.bool) {
    $decl m   {
      $decl ks   $call kvec.new (0)
      $decl vs   $call vvec.new (0)
      $decl less l
      $prop length   $func () $call m.ks.length ()
      $prop is_empty $func () $call m.ks.is_empty ()
      // Where `k` is, or would go.
      $prop slot     $func ($decl k K) $call Q.lower_bound_by (m.ks, k, m.less)
      // Whether position `i` holds `k`: `slot` already says it is not less than `k`.
      $prop holds    $func ($decl i 0, $decl k K)
        $if ($call lt (i, $call m.ks.length ()))
            ($call C.not ($call m.less (k, $call m.ks.get (i)))) false
      $prop has      $func ($decl k K) $call m.holds ($call m.slot (k), k)
      $prop get      $func ($decl k K) {
        $decl i   $call m.slot (k)
        $decl ret $if ($call m.holds (i, k)) ($call C.some ($call m.vs.get (i))) none
      }.ret
      $prop get_or   $func ($decl k K, $decl d V0) {
        $decl i   $call m.slot (k)
        $decl ret $if ($call m.holds (i, k)) ($call m.vs.get (i)) d
      }.ret
      // `k` mapped to `v`, replacing what it was mapped to; whether `k` is new.
      $prop put      $func ($decl k K, $decl v V0) {
        $decl i   $call m.slot (k)
        $decl ret $if ($call m.holds (i, k)) ($do ($call m.vs.set (i, v)) false)
                      ($do ($call m.ks.insert_at (i, k)) ($do ($call m.vs.insert_at (i, v)) true))
      }.ret
      // `k` and its value taken out; whether there was one.
      $prop remove   $func ($decl k K) {
        $decl i   $call m.slot (k)
        $decl ret $if ($call m.holds (i, k))
                      ($do ($call m.ks.remove_at (i)) ($do ($call m.vs.remove_at (i)) true))
                      false
      }.ret
      // The entries by position, in key order.
      $prop key_at   $func ($decl i 0) $call m.ks.get (i)
      $prop value_at $func ($decl i 0) $call m.vs.get (i)
      $prop min_key  $func () $if ($call m.ks.is_empty ()) none ($call C.some ($call m.ks.get (0)))
      $prop max_key  $func ()
        $if ($call m.ks.is_empty ()) none
            ($call C.some ($call m.ks.get ($call sub ($call m.ks.length (), 1))))
      // The keys and the values as `std/seq` sequences, in key order.
      $prop keys     $func () $call m.ks.items ()
      $prop values   $func () $call m.vs.items ()
      $prop clear    $func () $do ($call m.ks.clear ()) ($call m.vs.clear ())
    }
    $decl ret m
  }.ret
}
