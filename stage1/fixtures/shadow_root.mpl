// SPEC §4.1: a name is "visible from this point onward in the enclosing block", so whatever
// reads a name sees the bindings above it — an initializer, and a `$func`'s body and defaults
// too, though they run later. Where a block's later `$decl` shadows an outer name, that is the
// difference between two functions. `$decl isub sub` above the file's own `sub` is §2.1's
// idiom for keeping the intrinsic, and `diff` gets the intrinsic the same way. The three
// implementations used to disagree: the checker read source order, stage 0 the finished block,
// and lowering the finished block at the top level and in a module but source order in a
// nested one — so `diff` answered 99, the same program lifted into a function answered 0, and
// a later `sub` of another type was a `cc`-time "cannot coerce" the checker never saw.
// Reaching the later binding is what `$fwd` is for (§4.11). Each case is a digit or two.
$decl U    $import "shadow_util"
$decl isub sub
$decl iadd add
// 1. A body above the shadowing `$decl`: the intrinsic, 9 - 1.
$decl diff $func ($decl a 0, $decl b 0) $call sub (a, b)
// 2. Its default, read in the same scope (§3.4): 5 - 2.
$decl dflt $func ($decl n $call sub (5, 2)) n
// 3. `$fwd` reserves the slot above the body, so the body reaches the file's `add`: 88.
$fwd add
$decl dsum $func ($decl a 0, $decl b 0) $call add (a, b)
$decl sub  $func ($decl a 0, $decl b 0) 99
$decl add  $func ($decl a 0, $decl b 0) 88
$decl main $func () {
  // 4. A module member (`shadow_util.mpl`): 6 - 4.
  $decl r4  $call U.mdiff (6, 4)
  // 5. A nested block: its own later `sub` (66) is out of `ld`'s sight, and the nearest one
  // in sight is the file's, above `main` (99).
  $decl r5  {
    $decl ld   $func ($decl a 0, $decl b 0) $call sub (a, b)
    $decl sub  $func ($decl a 0, $decl b 0) 66
    $decl ret2 $call isub ($call ld (9, 4), 90)
  }.ret2
  $decl ret $call iadd ($call mul ($call diff (9, 1), 10000), $call iadd ($call mul ($call dflt (),
      1000), $call iadd ($call mul (r4, 100), $call iadd ($call mul (r5, 10),
      $call isub ($call dsum (1, 1), 87)))))
}.ret
