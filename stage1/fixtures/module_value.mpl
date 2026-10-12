// §4.14 makes `$import` evaluate to the file's block and §4.5 makes that block a
// record like any other, so a module used as a *value* must have the layout its
// type says. Prints 41.
//
// Lowering used to give a module the empty block — a namespace, which a projection
// `M.f` never noticed, since it resolves to the member's global without reading the
// value. Everything below received the value instead: inference accepted it and stage
// 0 ran it, while the backend emitted a field read of a struct with no fields (`cc`
// rejected it) or refused the program with "no field". Each line is one way a module
// value leaves the namespace.
$decl M $import "modval_util"

// Passed to a function, and a member called through the parameter.
$decl twice $func ($decl m M, $decl x 0) $call m.double (x)
// A record inside the record, read through a parameter.
$decl inner $func ($decl m M) m.Q.q
// A scalar prop through a parameter: read off the type, not the layout.
$decl tagged $func ($decl m M) $if ($call eq_str (m.tag, "util")) 1 0
// Returned from a function.
$decl get $func () M
// Held in a block's field.
$decl boxed { $decl m M }

$decl main $func ()
  { // `$new` copies the record, and its storage fields still alias the module's own
    // storage — a module is loaded once (§4.14), not instanced.
    $decl c  $mut $new M
    $decl w  $set c.cell 9
    $decl a  $call twice (M, 5)
    $decl b  $call inner (M)
    $decl g  $call get ()
    $decl e  boxed.m.k
    $decl f  $call add (M.cell, 0)
    // The cell can be `$set` to another block of the same type, so a field read
    // through it is a run-time fact — it must not resolve to the module's member.
    $decl s  $set c { $decl Q M.Q  $decl cell $mut $alloc 0  $decl k 4  $decl double M.double
                      $prop tag "util" }
    $decl h  c.k
    $decl t  $call tagged (M)
    // 10 + 11 + 3 + 3 + 9 + 4 + 1 = 41.
    $decl r  $call add (a, $call add (b, $call add (g.k, $call add (e, $call add (f, $call add (h, t)))))) }.r
