// `ctor_recv.mpl`'s module: a constructor whose members name their receiver, and one member
// answering a block that holds it (§5.3a: a borrowed place, which a result may hold).
$decl ival $func ($decl x 0) x

$decl tally $func ($decl k 0) $new {
  $decl n $mut $alloc k
  $prop plus $func ($decl d 0) $set tally.n ($call add ($call ival (tally.n), d))
  $prop get  $func () $call ival (tally.n)
  $prop twice $func () $do ($call tally.plus ($call tally.get ())) ()
  $prop peek $func () { $decl of tally  $decl at $call tally.get () }
}
