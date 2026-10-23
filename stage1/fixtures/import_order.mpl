// §4.14: a module's top-level effects run "once, at first import, depth-first from the entry
// file in source order of `$import`s" — at the `$import`, not before the importer's first
// item (§4.10: no hoisting). So the entry's effect above its `$import` runs first, a
// module's own `$import` initialises its dependency where it stands, and the second
// import of one already loaded runs nothing. Deferrals follow, in reverse.
// Prints "e1 m1 i m2 e2 5", then "de2 dm di de1".
$call print ("e1 ")
$defer $call print ("de1 ")
$decl M $import "import_order_util"
$decl N $import "import_order_inner"
$call print ("e2 ")
$defer $call print ("de2 ")
$decl main $func () $call add (M.v, N.w)
