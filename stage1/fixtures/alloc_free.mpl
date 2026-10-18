// §7.6 with the root allocator: A4 refuses a tail call that passes its own `$new`, and the
// rewrite its diagnostic advises is this — the storage is `$alloc`'d, so it is a pointer
// value a tail call may pass, and each iteration releases the cell it was handed through
// the root allocator's `free`. `build.zig` runs it under a memory cap a million unreleased
// cells could not meet. Answers the last cell's value, 1.

$decl ival $func ($decl x 0) x

$decl fresh $func ($decl c $alloc 0, $decl n 0)
  $if ($call eq_int (n, 0)) ($call ival (c))
      ($do ($call allocator.free ($call box_ptr (c)))
           ($call fresh ($alloc n, $call sub (n, 1))))

$decl main $func () $call fresh ($alloc 0, 1000000)
