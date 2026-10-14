// §4.9's instances with the generic in **type-only** positions inside `$decl`s:
// a nested `$specialize`, a list's storage, a parameter's default. The generic is
// bound to the argument's *value* (step 1), so these have to read its type off a
// slot rather than off the argument's source, which is what the props-only path
// does. Two element types, and two instances at one of them.
//
// 2 + 1 + 3 = 6.

$decl P $import "../prelude"

$decl stack $template T {
  $decl L $specialize P.list T
  $decl items $mut $alloc L.node
  $decl push $func ($decl x T) $set items ($call L.cons (x, items))
  $decl size $func () $call L.length (items, 0)
}

$decl main $func ()
  { $decl s $specialize stack 0
    $decl a $call s.push (4)
    $decl b $call s.push (5)
    $decl u $specialize stack ""
    $decl c $call u.push ("x")
    // A second `Int` instance starts empty: storage belongs to the instance.
    $decl t $specialize stack 0
    $decl d $call t.push (1)
    $decl e $call t.push (2)
    $decl f $call t.push (3)
    $decl r $call add ($call add ($call s.size (), $call u.size ()), $call t.size ()) }.r
