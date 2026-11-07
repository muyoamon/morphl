// SPEC §5.3a, STORAGE.md R3: a function whose body is a `$new` constructs into its caller.
// The call is the `$new` written where it stands, so its owner is the caller's `$decl` and
// the block's deferral runs when that owner's scope ends (DEFER.md). These are
// `tmpl_own.mpl`'s cases written as functions, and the shapes R3 adds: forwarding, an
// alias, a `$mut` constructor, a constructor in another module, a local one, a call in an
// arm, one that may come back through a call, and one nothing owns. Each case appends
// digits to `log`, so the answer is the order. At the top level the program owns it: "t "
// is an effect's, released at its item's end; "e " and the module's "u " run at exit,
// after the answer, the entry's first.
$decl U    $import "ctor_util"
$decl log  $mut $alloc ""
$decl ival $func ($decl x 0) x
$decl sval $func ($decl x "") x
$decl say  $func ($decl d 0) $set log ($call concat ($call sval (log), $call int_to_str (d)))
$decl hits $mut $alloc 0
$decl bump $func ($decl d 0) $do ($set hits ($call add ($call ival (hits), 1))) d

$decl top    $call U.loud ("e ")
$call U.loud ("t ")

$decl owned $func ($decl k 0) $new { $decl v k  $defer $call say (v) }
// Forwarding: a default, and an alias of the constructor.
$decl owned0 $func () $call owned (0)
$decl own2   owned
// `$mut`: the deferral reads the block as it was built, as a `$new` written in place does.
$decl cell   $func ($decl k 0) $mut $new { $decl v k  $defer $call say (v) }
// A deferral reading two fields.
$decl pair   $func ($decl a 0, $decl b 0) $new {
  $decl x   a
  $decl y   b
  $defer    $call say ($call add ($call mul (x, 10), y))
}
// No deferral: storage the caller makes, nothing more.
$decl plain  $func ($decl k 0) $new { $decl v k }
$decl get    $func ($decl r $call plain (0)) r.v

// A: owned by an inner scope's $decl, released at that scope's end, after its work. 213
$decl case_a $func () {
  $decl a   {
    $decl s    $call owned (1)
    $decl ret2 $call say (2)
  }.ret2
  $decl ret $call say (3)
}.ret

// B: among the frame's own deferrals, by position. 654
$decl case_b $func () {
  $defer    $call say (4)
  $decl s   $call owned (5)
  $defer    $call say (6)
  $decl ret s.v
}.ret

// C: a $try leaving the scope runs it. 9
$decl case_c $func ($decl t "") {
  $decl s   $call owned (9)
  $decl n   $try ($call str_to_int (t)) none
  $decl ret n
}.ret

// D: two instances, reverse order — one forwarded, one through the alias. 870
$decl case_d $func () {
  $decl x   $call owned0 ()
  $decl y   $call own2 (7)
  $decl z   $call owned (8)
  $decl ret 0
}.ret

// E: one per activation of a recursion, each released as its activation ends. 321
$decl case_e $func ($decl n 0) {
  $decl s   $call owned (n)
  $decl r   $if ($call lt (n, 3)) ($call case_e ($call add (n, 1))) 0
  $decl ret r
}.ret

// F: borrowed by a callee, which reads it and does not release it. 11
$decl peek   $func ($decl r $call owned (0)) $call say (r.v)
$decl case_f $func () {
  $decl s   $call owned (1)
  $decl p   $call peek (s)
  $decl ret 0
}.ret

// G: the argument is evaluated once. hits == 1
$decl case_g $func () {
  $decl s   $call owned ($call bump (2))
  $decl ret s.v
}.ret

// H: `$mut` storage set after it was built; the deferral reads the 4 it was built with. 54
$decl case_h $func () {
  $decl m   $call cell (4)
  $decl w   $set m { $decl v 6 }
  $decl ret $call say (5)
}.ret

// I: nothing owns it, so it is released at the end of its item, before the next. 3132
$decl case_i $func () {
  $decl a   $call say ($call ival (($call owned (3)).v))
  $decl b   $call say (2)
  $decl ret $call get ($call plain (7))
}.ret

// J: in an arm; only the one built is released. 1
$decl case_j $func ($decl c true) {
  $decl s   $if c ($call owned (1)) ($call owned (2))
  $decl ret s.v
}.ret

// K: a call that may hand it back owns it only if it does. 12
$decl pass   $func ($decl r $call owned (0)) r
$decl drop   $func ($decl r $call owned (0)) 0
$decl case_k $func () {
  $decl a   {
    $decl s    $call pass ($call owned (1))
    $decl ret2 0
  }.ret2
  $decl b   $call drop ($call owned (2))
  $decl ret 0
}.ret

// L: a deferral reading two fields. 47
$decl case_l $func () {
  $decl p   $call pair (4, 7)
  $decl ret p.x
}.ret

// M: a block's own constructor. 8
$decl case_m $func () {
  $decl mk  $func ($decl k 0) $new { $decl v k  $defer $call say (v) }
  $decl s   $call mk (8)
  $decl ret s.v
}.ret

// N: another module's, by name; its log is its own. 50
$decl case_n $func () {
  $decl s   $call U.made (5)
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
  $decl h   $call case_h ()
  $decl i   $call case_i ()
  $decl j   $call case_j (true)
  $decl k   $call case_k ()
  $decl l   $call case_l ()
  $decl m   $call case_m ()
  $decl n   $call case_n ()
  $decl ret $call concat ($call sval (log), $call concat (" ",
              $call concat ($call int_to_str ($call U.ival (U.log)), $call concat (" hits=",
              $call int_to_str ($call ival (hits))))))
}.ret
