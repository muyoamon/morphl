// SPEC §4.10: a constructor's members name their receiver by the constructor's own name —
// the block its body makes (§5.3a), which the caller provides. Members of an entry-file
// constructor, a `$mut` one, a block's local one and a module's, called through a frame
// place, a heap one, a trait object, a member answering a block holding the receiver, and
// a member called on a constructing call.
// Compiled only: stage 0 refuses a constructor's receiver (BOOTSTRAP 1.2).
$decl U    $import "ctor_recv_util"
$decl log  $mut $alloc ""
$decl sval $func ($decl x "") x
$decl ival $func ($decl x 0) x
$decl say  $func ($decl d 0) $set log ($call concat ($call sval (log), $call int_to_str (d)))

// A: the entry file's own, with a deferral reading a field, and members calling each other.
$decl counter $func ($decl start 0) $new {
  $decl n   $mut $alloc start
  $prop bump $func () $set counter.n ($call add ($call ival (counter.n), 1))
  $prop get  $func () $call ival (counter.n)
  $prop both $func () $do ($call counter.bump ()) ($call counter.get ())
  $defer $call say ($call ival (n))
}
$decl case_a $func () {
  $decl c   $call counter (4)
  $decl b   $call c.bump ()
  $decl ret $call c.both ()
}.ret

// B: `$mut`, so the receiver is mutable: a member writes a cell through it.
$decl pair $func ($decl a 0, $decl b 0) $mut $new {
  $decl x   $mut $alloc a
  $decl y   b
  $prop swap $func () $set pair.x ($call add ($call ival (pair.x), pair.y))
  $prop sum  $func () $call add ($call ival (pair.x), pair.y)
}
$decl case_b $func () {
  $decl p   $call pair (1, 2)
  $decl s   $call p.swap ()
  $decl ret $call p.sum ()
}.ret

// C: a block's local constructor.
$decl case_c $func ($decl k 0) {
  $decl acc $func ($decl s 0) $new {
    $decl v   $mut $alloc s
    $prop put $func ($decl d 0) $set acc.v ($call mul ($call ival (acc.v), d))
    $prop get $func () $call ival (acc.v)
  }
  $decl a   $call acc (k)
  $decl w   $call a.put (3)
  $decl ret $call a.get ()
}.ret

// D: a module's, and its block holding the receiver.
$decl case_d $func () {
  $decl t   $call U.tally (5)
  $decl w   $call t.plus (2)
  $decl w2  $call t.twice ()
  $decl p   $call t.peek ()
  $decl ret $call add (p.at, $call p.of.get ())
}.ret

// E: allocated, and called through it; then freed, which runs the deferral.
$decl case_e $func () {
  $decl h   $alloc $call counter (8)
  $decl b   $call h.bump ()
  $decl g   $call h.get ()
  $decl f   $free h
  $decl ret g
}.ret

// F: through a trait object.
$decl get_of $func ($decl o $traitsof $call counter (0)) $call o.get ()
$decl case_f $func () {
  $decl c   $call counter (6)
  $decl b   $call c.bump ()
  $decl ret $call get_of (c)
}.ret

// G: a member called on a constructing call, whose storage is released once the call
// returns and not where the member is read off it: 44, where releasing early said 34.
$decl case_g $func () { $decl ret $call ($call counter (3)).both () }.ret

$decl main $func () {
  $decl a   $call say ($call case_a ())
  $decl b   $call say ($call case_b ())
  $decl c   $call say ($call case_c (7))
  $decl d   $call say ($call case_d ())
  $decl e   $call say ($call case_e ())
  $decl f   $call say ($call case_f ())
  $decl g   $call say ($call case_g ())
  $decl ret $call sval (log)
}.ret
