// SPEC §5.3a, composition, allocated (`compose.mpl` is the frame's side): `$alloc` of a
// constructing call allocates the block and the region its own storage is built in as one
// object, which `$free` releases after running the block's deferral. Compiled only: stage 0
// releases nothing.
// Allocated: a function capturing frame storage — even the top level's — could have put it
// in the block, which `$alloc` would then outlive (§5.3a).
$decl dropped $mut $alloc 0
$decl ival    $func ($decl x 0) x

$decl cell $func ($decl n 0) $new {
  $decl a $mut $new n
  $decl b a
  $defer $set dropped ($call add ($call ival (dropped), 1))
}
$decl pair $func ($decl n 0) $new {
  $decl x $call cell (n)
  $decl y $mut $new 1
}
$decl bare $func ($decl n 0) $new { $decl a $mut $new n  $decl b a }

$decl clobber $func ($decl n 0)
  $if ($call lt (n, 1)) 0 ($call add (1, $call clobber ($call sub (n, 1))))

// From an allocator of the program's own, through its `alloc` member: the object's size is
// asked for once.
$decl a_count $mut $alloc 0
$decl from_arena $func () {
  $decl allocator {
    $prop alloc $func ($decl size 0) {
      $decl c   $set a_count ($call add ($call ival (a_count), 1))
      $decl ret $call raw_alloc (size)
    }.ret
    $prop free  $func ($decl addr 0, $decl size 0) $call raw_free (addr)
  }
  $decl h   $alloc $call bare (7)
  $decl k   $call clobber (50)
  $decl w   $set h.b 3
  $decl ret $call add (h.a, $call ival (a_count))
}.ret

$decl main $func () {
  $decl h   $alloc $call cell (2)
  $decl k   $call clobber (50)
  $decl w   $set h.b 9
  $decl v   $call add (h.a, 0)
  $decl d0  $call ival (dropped)
  $decl f   $free h
  $decl d1  $call ival (dropped)
  $decl g   $alloc $call pair (3)
  $decl k2  $call clobber (50)
  $decl w2  $set g.x.b 4
  $decl v2  $call add (g.x.a, g.y)
  $decl f2  $free g
  $decl d2  $call ival (dropped)
  $decl v3  $call from_arena ()
  $decl ret $call add ($call mul ($call add ($call mul ($call add ($call mul ($call add (
                $call mul ($call add ($call mul (v, 10), d0), 10), d1), 10), v2), 10), d2), 10), v3)
}.ret
