// §4.10: "In a type-only position the declaring name is the block's complete type, so a
// member takes another value of its own type as `$prop same_w $func ($decl other rect) …`."
// That is the shape of every `eq`, `lt` and `compare` (STDLIB.md, P6). Inference typed the
// default as the receiver — a reference — so every call was refused with "argument 1 is
// {…}, expected &const {…}".
//
// 1 + 10 + 100 + 4000 = 4111: equal values compare equal, unequal ones do not, a member
// is reached through a specialised template, and a member on `$mut` storage — typed a
// second time against a mutable receiver — takes its own type too.

$decl ieq  eq
$decl ival $func ($decl x 0) x

$decl mk $func ($decl a 0, $decl b 0) {
  $decl p   { $decl x a  $decl y b
    $prop eq $func ($decl other p) $if ($call ieq (p.x, other.x)) ($call ieq (p.y, other.y)) false
  }
  $decl ret p
}.ret

// Static dispatch through a generic: `a.eq` is `p`'s member once `T` is substituted.
$decl same_t $template T { $prop same $func ($decl a T, $decl b T) $call a.eq (b) }
$decl p0     $call mk (0, 0)
$decl same_p $specialize same_t p0

// A member that writes through its receiver needs a mutable one (§4.10), and is typed
// again for it; the parameter default must see the block there as well.
$decl acc $mut $alloc { $decl n $mut $alloc 1
  $prop absorb $func ($decl other acc)
    $set acc.n ($call add ($call ival (acc.n), $call ival (other.n)))
}

$decl main $func () {
  $decl a   $call mk (3, 4)
  $decl s1  $if ($call a.eq ($call mk (3, 4))) 1 0
  $decl s2  $if ($call a.eq ($call mk (3, 5))) 0 10
  $decl s3  $if ($call same_p.same ($call mk (1, 2), $call mk (1, 2))) 100 0
  $decl s4  $do ($call acc.absorb (acc)) ($do ($call acc.absorb (acc)) ($call ival (acc.n)))
  $decl ret $call add ($call add (s1, s2), $call add (s3, $call mul (s4, 1000)))
}.ret
