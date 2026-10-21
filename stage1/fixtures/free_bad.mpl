// DEFER.md step 4's checks in inference. `$free` takes allocated storage it may end: not
// frame storage, released with its frame, nor a `$const` view, which only reads. An
// allocator serving `$free` needs `free (addr, size)`; one serving an `$alloc` block's
// deferrals needs `defer_at`; a parameter is freed only through the root, since which
// allocator is not in a function's type; and an `$alloc` block's deferrals run at `$free`,
// after their frame is gone, so they may name only the block's fields and globals.
$decl old $func () {
  $decl a   { $prop alloc $func ($decl n 0) 0  $prop free $func ($decl p 0) () }
  $decl ret a
}.ret
$decl new $func () {
  $decl a   { $prop alloc $func ($decl n 0) 0  $prop free $func ($decl p 0, $decl s 0) ()
              $prop defer_at $func ($decl p 0, $decl f $func () ()) () }
  $decl ret a
}.ret
$decl frame $func () {
  $decl c   $new 1
  $decl x   $free c
  $decl ret 0
}.ret
$decl view $func () {
  $decl r   $alloc 1
  $decl x   $free ($const r)
  $decl ret 0
}.ret
$decl oldf $func () {
  $decl allocator $call old ()
  $decl r   $alloc 1
  $decl x   $free r
  $decl ret 0
}.ret
$decl param $func ($decl r $alloc 1) {
  $decl allocator $call new ()
  $decl x   $free r
  $decl ret 0
}.ret
$decl capt $func ($decl s "") {
  $decl allocator $call new ()
  $decl r   $alloc { $decl k 1  $defer $call print (s) }
  $decl ret 0
}.ret
