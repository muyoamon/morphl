// §6a's indirect case, when a chain passes through a *direct* tail call. A function that
// tail-calls a reporter directly used to drive the chain the reporter left in its own
// frame — so `go` → value → `f` → `go` nested `f`'s frame and a driver's per hop, and
// 2,000,000 hops overflowed the stack (§7.7). Such a function reports too now, to a fixed
// point (`emit.mpl`, `reporter_ids`), and hands the chain up to its caller (`passes_up`).
//
// And the functions `mpl_init` calls must never report, because nothing drives after them:
// a top-level `$decl` whose initializer tail-called through a value was assigned the
// placeholder zero, and a §3.3 effect's call was never made — left pending for whichever
// indirect call drove next.
//
// The digits: one direct hop per cycle (5), two, which only a second round of the fixed
// point finds (3), both 2,000,000 cycles at -O0; a thunk (6, was 0); an effect (9, was 0);
// a direct tail call whose result is re-tagged, which must still drive (2, or 0 if the
// chain is handed up anyway); and the same through a function value, an *indirect* tail
// call, which reported regardless and answered 0 (2). 536922.

// 1. `go` reports its call through `cell`; `f`, stored there, tail-calls `go` directly.
$decl cell $mut $alloc $func ($decl n 0) 0
$decl go   $func ($decl n 0) $if ($call eq (n, 0)) 5 ($call cell ($call sub (n, 1)))
$decl f    $func ($decl n 0) $call go (n)
$decl w0   $set cell f

// 2. Two direct hops: `h` reaches the reporter `go2` only through `g`.
$decl cell2 $mut $alloc $func ($decl n 0) 0
$decl go2   $func ($decl n 0) $if ($call eq (n, 0)) 3 ($call cell2 ($call sub (n, 1)))
$decl g     $func ($decl n 0) $call go2 (n)
$decl h     $func ($decl n 0) $call g (n)
$decl w1    $set cell2 h

// 3. A thunk: `x`'s initializer is a tail call through a value.
$decl cell3 $mut $alloc $func ($decl n 0) 0
$decl six   $func ($decl n 0) 6
$decl w2    $set cell3 six
$decl x     $call cell3 (3)

// 4. An effect: a bare top-level call through a value, which writes `cnt`.
$decl cnt   $mut $alloc 0
$decl cell4 $mut $alloc $func ($decl n 0) 0
$decl put   $func ($decl n 0) $do ($set cnt n) n
$decl w3    $set cell4 put
$call cell4 (9)
$decl ival  $func ($decl n 0) n

// 5. `wide` re-tags `go5`'s `<b, c>` into its own `<a, b, c>`, so it needs the chain's end.
$decl cell5 $mut $alloc $func ($decl n 0)
    $union ({ $prop tag "b"  $decl v 0 }, { $prop tag "c" })
$decl go5   $func ($decl n 0) $if ($call eq (n, 0)) { $prop tag "b"  $decl v 2 }
    ($call cell5 ($call sub (n, 1)))
$decl w4    $set cell5 go5
$decl wide  $func ($decl n 0) $if ($call lt (n, 0)) { $prop tag "a" } ($call go5 (n))
$decl b_of  $func ($decl n 0) {
  $decl r   $call wide (n)
  $decl ret $match r ($case { $prop tag "b" } r.v, $case r 0)
}.ret

// 6. The same through a value: `wider`'s indirect tail call is re-tagged too, so it may
// not report — the driver above would write `<b, c>` into `<a, b, c>` untagged.
$decl wider  $func ($decl n 0, $decl k go5)
    $if ($call lt (n, 0)) { $prop tag "a" } ($call k (n))
$decl b_of_v $func ($decl n 0) {
  $decl r   $call wider (n, go5)
  $decl ret $match r ($case { $prop tag "b" } r.v, $case r 0)
}.ret

$decl d $func ($decl acc 0, $decl x 0) $call add ($call mul (acc, 10), x)

$decl main $func () {
  // First, before any indirect call here could drive a stale pending one.
  $decl e   $call ival (cnt)
  $decl a   $call go (2000000)
  $decl b   $call h (2000000)
  $decl c   x
  $decl g5  $call b_of (1000)
  $decl g6  $call b_of_v (1000)
  $decl ret $call d ($call d ($call d ($call d ($call d (a, b), c), e), g5), g6)
}.ret
