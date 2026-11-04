// DEFER.md step 4's routing, refused by the checker as lowering refuses it: `$free r` needs a
// name this function bound from storage whose allocator is known, freed where that allocator
// is in scope, and a callee freeing its argument (through the root) needs root storage.
$decl arena $func () {
  $decl a   { $prop alloc $func ($decl n 0) $call raw_alloc (n)
              $prop free  $func ($decl p 0, $decl s 0) $call raw_free (p) }
  $decl ret a
}.ret
$decl open  $func ($decl id 0) $alloc { $decl k id }
$decl close $func ($decl f ($call open (0))) $free f
$decl glob  $alloc 5
$decl capt $func () {
  $decl r   $alloc 0
  $decl g   $func () $free r
  $decl ret $call g ()
}.ret
$decl top $func () $free glob
$decl other $func () {
  $decl r   $alloc 0
  $decl ret { $decl allocator $call arena ()  $free r  $decl ret2 0 }.ret2
}.ret
$decl pass $func () {
  $decl allocator $call arena ()
  $decl a   $alloc { $decl k 1 }
  $decl x   $call close (a)
  $decl ret 0
}.ret
$decl lend $func ($decl b { $decl c ($call open (0)) }) $call close (b.c)
// A local constructor's result: its type is no promise lowering can read (`call_root`).
$decl loc $func () {
  $decl mk  $func () $call open (1)
  $decl ret $call close ($call mk ())
}.ret
$decl loc2 $func () {
  $decl mk  $func () $call open (1)
  $decl c   $call mk ()
  $decl ret $free c
}.ret
// Legal: the allocator that made it, a copy, a root constructor's result, a parameter
// passed on, and storage freed under its own arena.
$decl ok $func () {
  $decl r   $alloc 0
  $decl r2  r
  $decl x   $free r2
  $decl y   $call close ($call open (1))
  $decl z   { $decl allocator $call arena ()  $decl s $mut $alloc 2  $free s  $decl ret2 0 }.ret2
  $decl ret 0
}.ret
$decl fwd $func ($decl f ($call open (0))) $call close (f)
$decl main $func () $call ok ()
