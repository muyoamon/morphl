// SPEC §5.3a, composition: the storage a constructor's own call makes — a frame `$new`, or a
// constructing call's block — is built in place in its caller's frame, beside the block, and
// ends with it (`compose_alloc.mpl` is `$alloc`'s side). Each case writes through one field
// and reads the same cell through another after `clobber` has reused the stack the
// constructor ran in.
$decl dropped $mut $new 0

$decl cell $func ($decl n 0) $new {
  $decl a $mut $new n
  $decl b a
  $defer $set dropped ($call add (dropped, 1))
}
// A constructor whose block holds another's, and storage of its own beside it.
$decl pair $func ($decl n 0) $new {
  $decl x $call cell (n)
  $decl y $mut $new $call mul (n, 10)
}
// A `$new` whose own block has a deferral: it runs from `logged`'s `drop`, which has none of
// `logged`'s frame, so what it reads was copied into the region where it was registered.
$decl logged $func ($decl n 0) $new {
  $decl c $new { $decl v n  $defer $set dropped ($call add (dropped, v)) }
}
// A function forwarding to one passes its caller's region on.
$decl fwd $func ($decl n 0) $call cell (n)

$decl clobber $func ($decl n 0)
  $if ($call lt (n, 1)) 0 ($call add (1, $call clobber ($call sub (n, 1))))

$decl t_a $func () {
  $decl c   $call cell (4)
  $decl k   $call clobber (50)
  $decl w   $set c.b 7
  $decl ret $call add (c.a, 0)
}.ret
$decl t_b $func () {
  $decl p   $call pair (3)
  $decl k   $call clobber (50)
  $decl w   $set p.x.b 5
  $decl ret $call add (p.x.a, p.y)
}.ret
$decl t_c $func () {
  $decl q   $call fwd (6)
  $decl k   $call clobber (50)
  $decl w   $set q.b 8
  $decl ret $call add (q.a, 0)
}.ret
// Through a value the region is not known, so the shim allocates it and `drop` frees it.
$decl t_e $func ($decl f cell) {
  $decl c   $call f (3)
  $decl k   $call clobber (50)
  $decl w   $set c.b 4
  $decl ret $call add (c.a, 0)
}.ret
// A block's own constructor, and a short call (§3.4).
$decl t_f $func () {
  $decl lc  $func ($decl n 0) $new { $decl a $mut $new n  $decl b a }
  $decl c   $call lc (2)
  $decl s   $call cell ()
  $decl k   $call clobber (50)
  $decl w   $set c.b 6
  $decl w2  $set s.b 2
  $decl ret $call add (c.a, $call sub (s.a, 2))
}.ret

$decl t_g $func () {
  $decl x   $call logged (3)
  $decl k   $call clobber (50)
  $decl ret $call add (x.c.v, 0)
}.ret

$decl main $func () {
  $decl r1  $call t_a ()
  $decl r2  $call t_b ()
  $decl r3  $call t_c ()
  $decl r5  $call t_e (cell)
  $decl r6  $call t_f ()
  $decl r7  $call t_g ()
  $decl d   $call add (dropped, 0)
  $decl ret $call add ($call mul ($call add ($call mul ($call add ($call mul ($call add (
                $call mul ($call add ($call mul ($call add ($call mul (r1, 100), r2), 10), r3), 10),
                r5), 10), r6), 10), r7), 10), d)
}.ret
