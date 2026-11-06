// A value template whose body is `$new { … $defer … }` is an inline constructor: SPEC §4.9
// makes the `$new` frame storage of the scope the `$specialize` is evaluated in, so its
// owner is the `$decl` there and its deferral runs when that owner's scope ends (DEFER.md).
// Each case appends digits to `log`, so the answer is the order. Three things broke it: a
// top-level such template was taken for top-level storage and lost (`Pa.storage_defers`),
// lowering's flow rule did not follow the place through the `$specialize`, so each
// deferral ran as soon as its instance was built (compiled 123564978123112), and §5.3a did
// not count the instance as a place at all, so returning one was accepted
// (`tmpl_escape.mpl`).
$decl log  $mut $alloc 0
$decl ival $func ($decl x 0) x
$decl say  $func ($decl d 0) $set log ($call add ($call mul ($call ival (log), 10), d))
$decl hits $mut $alloc 0
$decl bump $func ($decl d 0) $do ($set hits ($call add ($call ival (hits), 1))) d

$decl owned $template k $new { $decl v k  $defer $call say (v) }

// A: owned by an inner scope's $decl, released at that scope's end, after its work. 213
$decl case_a $func () {
  $decl a   {
    $decl s    $specialize owned 1
    $decl ret2 $call say (2)
  }.ret2
  $decl ret $call say (3)
}.ret

// B: among the frame's own deferrals, by position. 654
$decl case_b $func () {
  $defer    $call say (4)
  $decl s   $specialize owned 5
  $defer    $call say (6)
  $decl ret s.v
}.ret

// C: a $try leaving the scope runs it. 9
$decl case_c $func ($decl t "") {
  $decl s   $specialize owned 9
  $decl n   $try ($call str_to_int (t)) none
  $decl ret n
}.ret

// D: two instances, reverse order. 87
$decl case_d $func () {
  $decl x   $specialize owned 7
  $decl y   $specialize owned 8
  $decl ret 0
}.ret

// E: one instance per activation of a recursion; each is released as its activation ends.
// The recursion is inside a block, so each level is released after the levels below. 321
$decl case_e $func ($decl n 0) {
  $decl s   $specialize owned n
  $decl r   $if ($call lt (n, 3)) ($call case_e ($call add (n, 1))) 0
  $decl ret r
}.ret

// F: borrowed by a callee, which reads it and does not release it. 11
$decl peek   $func ($decl r $specialize owned 0) $call say (r.v)
$decl case_f $func () {
  $decl s   $specialize owned 1
  $decl p   $call peek (s)
  $decl ret 0
}.ret

// G: the argument is evaluated once. hits == 1
$decl case_g $func () {
  $decl s   $specialize owned ($call bump (2))
  $decl ret s.v
}.ret

$decl main $func () {
  $decl a   $call case_a ()
  $decl b   $call case_b ()
  $decl c   $call case_c ("x")
  $decl d   $call case_d ()
  $decl e   $call case_e (1)
  $decl f   $call case_f ()
  $decl g   $call case_g ()
  $decl ret $call concat ($call int_to_str ($call ival (log)),
              $call concat (" hits=", $call int_to_str ($call ival (hits))))
}.ret
