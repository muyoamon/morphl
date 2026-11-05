// A module whose two members return each other's function in their result, so the type
// recurses through both: `f` gives `{v, k: &^g}` or what `g` gives, and `g` the other
// way round. Inference closes that into one `μ` and lowering, which derives a module
// member's type rather than reading inference's (§4.14), has to close it too. Retrying the
// member only went one level deeper each time — `{v, k: &^[Int] -> {v, k: &^!}}` — and
// emit refused the ⊥ left inside.
$fwd g
$decl f $func ($decl n 0) $if ($call eq (n, 0)) { $decl v 1  $decl k $alloc g }
  ($call g ($call sub (n, 1)))
$decl g $func ($decl n 0) $if ($call eq (n, 0)) { $decl v 2  $decl k $alloc f }
  ($call f ($call sub (n, 1)))
