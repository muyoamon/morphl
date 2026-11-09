// SPEC §5.3a: `$alloc` of a constructing call allocates the block the call constructs, and its
// deferrals are then the allocator's — run by `$free`, never by the frame the call stands in —
// so one constructor serves both lifetimes. Each case appends digits to `log`.
$decl log  $mut $alloc ""
$decl sval $func ($decl x "") x
$decl ival $func ($decl x 0) x
$decl say  $func ($decl d 0) $set log ($call concat ($call sval (log), $call int_to_str (d)))

$decl mk   $func ($decl d 0) $new { $decl k d  $defer $call say (k) }
// Handed back allocated: `keep`'s frame ends without running the deferral.
$decl keep $func ($decl d 0) $alloc $call mk (d)

// Fallible: `<&^T, none>`, and the deferrals registered before a `$try` that leaves run in
// the constructor, as for a frame one. `$try` is what leaves the reference to `$free`: an arm
// of a `$match` narrows to the pointee (§4.7).
$decl parse $func ($decl src "") $new {
  $prop tag "ok"
  $decl a   1
  $defer    $call say (a)
  $decl n   ($try ($call str_to_int (src)) none).v
  $defer    $call say (n)
}
$decl kept $func ($decl src "") $alloc $call parse (src)
$decl n_of $func ($decl src "") {
  $decl h   $try ($call kept (src)) none
  $decl n   $call ival (h.n)
  $decl f   $free h
  $decl ret n
}.ret
$decl or0 $func ($decl x $union (0, none)) $match x ($case {$prop tag "none"} 0, $case 0 x)

$decl main $func () {
  // A: in a frame, released at its scope's end. 32
  $decl a   { $decl s $call mk (2)  $decl t $call say (3)  $decl ret2 $call ival (s.k) }.ret2
  // B: allocated, released by `$free`, after what came between. 54
  $decl h   $call keep (4)
  $decl b   $call say (5)
  $decl fb  $free h
  // C: allocated and never released: nothing runs.
  $decl g   $call keep (9)
  // D: `$mut`, written through, then released. 6
  $decl m   $mut $alloc $call mk (6)
  $decl fm  $free m
  // E: fallible and built: `$free` runs both, newest first; then its `n`. 717
  $decl e   $call say ($call or0 ($call n_of ("7")))
  // F: fallible and not built: the constructor ran `a`'s, and there is nothing to free. 10
  $decl f   $call say ($call or0 ($call n_of ("x")))
  $decl ret $call sval (log)
}.ret
