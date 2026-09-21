// Tests for the C backend:
//
//   morphlc --run stage1/emit_test.mpl
//
// These check the emitted *text*, because that is all a morphl test can reach —
// it cannot invoke a C compiler. The properties that matter are the ones §6a
// and §7.7 turn on: a self tail call becomes a loop, and its parameters are
// updated in parallel. `zig build test-emit` runs the round trip through `cc`.

$decl I  $import "infer"
$decl L  $import "lower"
$decl E  $import "emit"
$decl IR $import "ir"
$decl Pa $import "parser"
$decl P  $import "prelude"

$decl not P.not

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))

$decl check $func ($decl name "", $decl ok P.boolean)
  $if ok
      ($do ($call print ("ok   ")) ($call nl (name)))
      ($do ($call print ("FAIL ")) ($do ($call nl (name)) ($call panic (name))))

// Does `hay` contain `needle`? §8 gives `slice` and `len`, which is enough.
$decl has_at $func ($decl hay "", $decl needle "", $decl i 0)
  $if ($call lt ($call sub ($call len (hay), $call len (needle)), i)) false
      ($if ($call eq_str ($call slice (hay, i, $call add (i, $call len (needle))), needle)) true
           ($call has_at (hay, needle, $call add (i, 1))))

$decl has $func ($decl hay "", $decl needle "") $call has_at (hay, needle, 0)

// The index of the first occurrence, or -1 — for asserting that one thing is
// emitted before another.
$decl idx_at $func ($decl hay "", $decl needle "", $decl i 0)
  $if ($call lt ($call sub ($call len (hay), $call len (needle)), i)) -1
      ($if ($call eq_str ($call slice (hay, i, $call add (i, $call len (needle))), needle)) i
           ($call idx_at (hay, needle, $call add (i, 1))))

$decl idx $func ($decl hay "", $decl needle "") $call idx_at (hay, needle, 0)

$decl result $func ($decl c "", $decl n 0) { $decl code c  $decl nerrs n }

$decl compile $func ($decl src "")
  { $decl r     $call I.check_source (src, "", "")
    $decl ast   $call Pa.parse (src)
    $decl st    $call L.lstate ()
    $decl prims $call L.prims_from ($call I.eval_env (I.root_env), L.benv.nil)
    $decl prog  $call L.lower_file (st, $call Pa.nodes.val (ast.exprs), r.ty, prims)
    $decl est   $call E.estate ()
    $decl c     $call E.emit_program (est, prog)
    $decl out   $call result (c, $call Pa.diags.length ($call E.emit_errs (est), 0)) }.out

// ---------------------------------------------------------------- the cases

$decl loop_src $call concat (
  "$decl count $func ($decl n 0, $decl acc 0) ",
  $call concat ("$if ($call eq_int (n, 0)) acc ($call count ($call sub (n, 1), $call add (acc, 1))) ",
                "$decl main $func () $call count (3, 0) "))

$decl loop_c $call compile (loop_src)

$decl t1 $call check ("a program with no unsupported construct emits cleanly",
  $call eq_int (loop_c.nerrs, 0))

// §7.7/§6a: the recursion is a loop, not a call.
$decl t2 $call check ("a self tail call becomes a loop",
  $if ($call has (loop_c.code, "while (1) {")) ($call has (loop_c.code, "continue;")) false)

// The sharp form: `main` may call `count`, but `count`'s own body must not —
// that call is what became the `continue`.
$decl body_of $func ($decl code "", $decl marker "")
  { $decl at   $call idx (code, marker)
    $decl rest $call slice (code, at, $call len (code))
    $decl nxt  $call idx ($call slice (rest, 1, $call len (rest)), "\nstatic ")
    $decl out  $if ($call lt (nxt, 0)) rest ($call slice (rest, 0, nxt)) }.out

$decl t3 $call check ("...and its own body does not call it",
  $call not ($call has ($call body_of (loop_c.code, "/* count */"), "mpl_f0(")))

// §6a's hazard: `$call f (b, a)` must not clobber `b` before reading it, so
// every new argument lands in a temporary before any slot is written.
$decl t4 $call check ("the parameters are updated in parallel",
  { $decl first_write $call idx (loop_c.code, "  s0 = t")
    $decl last_temp   $call idx (loop_c.code, "  s1 = t")
    $decl out $if ($call lt (0, first_write)) ($call lt (first_write, last_temp)) false }.out)

// A binary intrinsic is an operator, not a call.
$decl t5 $call check ("§8's arithmetic is emitted infix",
  $if ($call has (loop_c.code, " == ")) ($call has (loop_c.code, " - ")) false)

// §7.3 gives every function value the same shape, so every function takes an
// environment — even one that captures nothing, which is handed NULL.
$decl t6 $call check ("every function takes an environment",
  $if ($call has (loop_c.code, "mpl_f1(void *env)"))
      ($call has (loop_c.code, "(NULL")) false)

// §9 leaves the entry point to the build program; this is the stand-in.
$decl t7 $call check ("a top-level `main` gets a C main",
  $call has (loop_c.code, "int main(void)"))

// Refused rather than mis-emitted. `$try` is emitted now, so what is left
// without a C form is `Float` — BOOTSTRAP §1.2 leaves float arithmetic out and
// §3.1 keeps a literal as its source text.
$decl t8 $call check ("an unsupported construct is refused, not guessed at",
  { $decl r $call compile ("$decl main $func () 1.5 ")
    $decl out $call lt (0, r.nerrs) }.out)

// And a program with no `main` is refused, since the emitted file would not
// link.
$decl t9 $call check ("a program with no main is refused",
  { $decl r $call compile ("$decl f $func ($decl n 0) n ")
    $decl out $call lt (0, r.nerrs) }.out)

// ------------------------------------------------------------------ blocks

$decl blk_src $call concat (
  "$decl point $func ($decl a 0, $decl b 0) { $decl x a  $decl y b } ",
  $call concat ("$decl seg $func ($decl p $call point (0,0), $decl q $call point (0,0)) { $decl lo p  $decl hi q } ",
  $call concat ("$decl tag1 { $prop tag \"t\"  $decl x 7 } ",
                "$decl main $func () $call add (($call seg ($call point (1,2), $call point (3,4))).hi.y, tag1.x) ")))

$decl blk_c $call compile (blk_src)

$decl t10 $call check ("a program using blocks emits cleanly",
  $call eq_int (blk_c.nerrs, 0))

// §7.2: the layout is the `$decl` order, so `point` is two fields by position.
//
// Every struct is *declared* first and defined separately, because §5.5 lets a
// type reach itself through storage and a pointer to a struct needs only the
// declaration. That is what lets a recursive type be laid out at all.
$decl t11 $call check ("a block becomes a struct in $decl order",
  $call has (blk_c.code, "struct mpl_t1 { int64_t f0; int64_t f1; };"))

$decl t11b $call check ("...declared before it is defined",
  $call has (blk_c.code, "typedef struct mpl_t1 mpl_t1;"))

// §4.10: a prop is in the type but occupies no space, so this struct has one
// field, not two.
$decl t12 $call check ("a $prop takes no space in the struct",
  $call has (blk_c.code, "{ int64_t f0; };"))

// Blocks nest by value, and the inner struct must be declared first — which it
// is, because lowering interns a field's type before the block containing it,
// and §5.5 makes the nesting acyclic.
$decl t13 $call check ("a nested block is a struct of structs, declared in order",
  { $decl inner $call idx (blk_c.code, "int64_t f0; int64_t f1; }")
    $decl outer $call idx (blk_c.code, "mpl_t1 f0; mpl_t1 f1; }")
    $decl out $if ($call lt (0, inner)) ($call lt (inner, outer)) false }.out)

// §4.6 as a layout position.
$decl t14 $call check ("projection is a field by index",
  $call has (blk_c.code, ".f1;"))

// A top-level `$decl` that is not a `$func` has a static of its own (§4.10,
// initialised once in source order), and naming it reads that.
$decl t15 $call check ("global data is read from its static",
  $if ($call has (blk_c.code, "= mpl_g2;"))
      ($call has (blk_c.code, "mpl_g2 = mpl_f2(NULL);")) false)

// ----------------------------------------------------------------- strings

$decl str_c $call compile ($call concat (
  "$decl greet $func ($decl who \"\") $call concat (\"hi \", who) ",
  "$decl main $func () $call greet (\"x\") "))

$decl t16 $call check ("a program using Str emits cleanly",
  $call eq_int (str_c.nerrs, 0))

// §3.1: pointer and length.
$decl t17 $call check ("Str is a pointer and a length",
  $call has (str_c.code, "typedef struct { const char *p; int64_t n; } mpl_str;"))

// A `Str` is bytes, not a C string, so every byte is an octal escape — `\x`
// would run on into a following hex digit.
$decl t18 $call check ("a string literal is escaped byte by byte",
  $call has (str_c.code, "(mpl_str){\"\\150\\151\\040\", 3}"))

// §8's string intrinsics are calls; only the arithmetic is infix.
$decl t19 $call check ("a string intrinsic is a call, not an operator",
  $call has (str_c.code, "= mpl_concat("))

// §9 leaves the entry point to the build program; a `Str` result is written
// out rather than printed as a number.
$decl t20 $call check ("a Str-returning main is printed as bytes",
  $call has (str_c.code, "mpl_print(mpl_f1(NULL));"))

// The escaping has to survive a quote, a backslash, a newline and a multi-byte
// code point — and the length is bytes, not characters (§3.1).
$decl tricky_c $call compile ($call concat (
  "$decl t \"a\\\"b\\\\c\\nd\\u{00e9}\" ",
  "$decl main $func () $call len (t) "))

$decl t21 $call check ("a quote, a backslash, a newline and UTF-8 all survive",
  $call has (tricky_c.code, "\\141\\042\\142\\134\\143\\012\\144\\303\\251\", 9}"))

// ----------------------------------------------------------------- storage

$decl sto_c $call compile ($call concat (
  "$decl c $mut $new 0 ",
  $call concat ("$decl bump $func ($decl by 0) $set c ($call add (c, by)) ",
                "$decl main $func () $do ($call bump (5)) c ")))

$decl t22 $call check ("a program using storage emits cleanly",
  $call eq_int (sto_c.nerrs, 0))

// §4.2: one allocation and one store. §7.4 makes `&T` a thin pointer.
$decl t23 $call check ("$new is an allocation and a store",
  $if ($call has (sto_c.code, "mpl_alloc((int64_t)sizeof(int64_t))"))
      ($call has (sto_c.code, "int64_t * ")) false)

// §4.4: writes *through* storage.
$decl t24 $call check ("$set writes through the pointer",
  $call has (sto_c.code, "  *t"))

// §4.10: a global is initialised once, in source order — not re-evaluated at
// each mention, which for storage would mean a different cell every time.
$decl t25 $call check ("a global has a static, assigned once by mpl_init",
  $if ($call has (sto_c.code, "static int64_t * mpl_g0;"))
      ($call has (sto_c.code, "mpl_g0 = mpl_f0(NULL);")) false)

$decl t26 $call check ("...and mpl_init runs before the entry point",
  { $decl i $call idx (sto_c.code, "mpl_init();")
    $decl m $call idx (sto_c.code, "int main(void)")
    $decl out $if ($call lt (0, m)) ($call lt (m, i)) false }.out)

// §4.8b discards the first operand, so C is right that its temporary is never
// read — the cast says so rather than silencing the warning file-wide.
$decl t27 $call check ("a discarded $do operand is cast to void",
  $call has (sto_c.code, "  (void)t"))

// ------------------------------------------------------------------- match

$decl mat_c $call compile ($call concat (
  "$decl c { $prop k \"c\"  $decl r 3 } $decl q { $prop k \"q\"  $decl w 4 } ",
  $call concat ("$decl area $func ($decl s $union (c, q)) $match s ( ",
  $call concat ("$case {$prop k \"c\"} $call mul (s.r, s.r), ",
  $call concat ("$case {$prop k \"q\"} $call mul (s.w, s.w)) ",
                "$decl main $func () $call area (c) ")))))

$decl t28 $call check ("a program using $match emits cleanly",
  $call eq_int (mat_c.nerrs, 0))

// §7.5: a value of union type carries a discriminator.
$decl t29 $call check ("a union is a tag and the members",
  $call has (mat_c.code, "int64_t tag; union {"))

// §4.7's test, and nothing else reads it.
$decl t30 $call check ("$match is a switch on that discriminator",
  $if ($call has (mat_c.code, "switch ((int)")) ($call has (mat_c.code, ".tag) {")) false)

// §4.7: inside an arm the scrutinee is narrowed, which is what lets the body
// reach a field only that member has.
$decl t31 $call check ("an arm loads the member it selected",
  $call has (mat_c.code, ".u.m"))

// §7.4: using a member where the union is expected is a copy — here, the
// discriminated value.
$decl t32 $call check ("passing a member where a union is wanted injects it",
  $call has (mat_c.code, ".tag = "))

// §5.6 checked exhaustiveness, so the C default cannot be reached.
$decl t33 $call check ("the default is unreachable",
  $call has (mat_c.code, "default: mpl_panic("))

// ---------------------------------------------------------------- closures

$decl clo_c $call compile ($call concat (
  "$decl adder $func ($decl n 0) $func ($decl m 0) $call add (n, m) ",
  $call concat ("$decl apply $func ($decl f $func ($decl m 0) 0, $decl x 0) $call f (x) ",
                "$decl main $func () $call apply ($call adder (40), 2) ")))

$decl t34 $call check ("a program using closures emits cleanly",
  $call eq_int (clo_c.nerrs, 0))

// §7.3: two words, whatever the signature.
$decl t35 $call check ("a function value is a code pointer and an environment",
  $call has (clo_c.code, "typedef struct { void *code; void *env; } mpl_fun;"))

// The captures are copied where the literal stood, into an environment the
// pair points at — so the value outlives the frame they came from.
$decl t36 $call check ("the captures are copied into an environment",
  $if ($call has (clo_c.code, "typedef struct { int64_t c0; } mpl_env"))
      ($call has (clo_c.code, ".code = (void *)mpl_f")) false)

// And the lifted body reads them back out of it.
$decl t37 $call check ("the lifted body reads its captures from the environment",
  $call has (clo_c.code, " *)env)->c0"))

// §7.3 keeps captures out of the type, so the call site supplies the signature.
$decl t38 $call check ("an indirect call casts to the signature the type gives",
  $call has (clo_c.code, "(*)(void *, int64_t))"))

// --------------------------------------------------------------------- try

$decl try_c $call compile ($call concat (
  "$decl half $func ($decl n 0) $if ($call eq_int ($call mod (n, 2), 0)) ($call div (n, 2)) none ",
  $call concat ("$decl q $func ($decl n 0) $try ($call half (n)) none ",
                "$decl main $func () 0 ")))

$decl t39 $call check ("a program using $try emits cleanly",
  $call eq_int (try_c.nerrs, 0))

// §4.15: a conditional return from the nearest enclosing `$func`.
$decl t40 $call check ("$try is a discriminator test and a return",
  $if ($call has (try_c.code, ".tag == 0) {")) ($call has (try_c.code, "  return ret;")) false)

// Nothing declares the failure: §4.15 widens the *inferred* result to include
// it, so the C function returns the union rather than the body's own type.
$decl t41 $call check ("the function's result is widened to carry the failure",
  $call has (try_c.code, "static mpl_t"))

// §4.15 again: what survives is `type(e) & ¬pat`, read straight out.
$decl t42 $call check ("what survives is the other member",
  $call has (try_c.code, ".u.m1;"))

// §4.15's shapes are root-block values, not callees — a prop-only block with
// no fields.
$decl t43 $call check ("none is emitted as a value",
  $call has (try_c.code, "){0}"))

// -------------------------------------------------- mutual and indirect tails

$decl mut_c $call compile ($call concat (
  "$fwd odd ",
  $call concat ("$decl even $func ($decl n 0) $if ($call eq_int (n, 0)) 1 ($call odd ($call sub (n, 1))) ",
  $call concat ("$decl odd $func ($decl n 0) $if ($call eq_int (n, 0)) 0 ($call even ($call sub (n, 1))) ",
                "$decl main $func () $call even (4) "))))

$decl t44 $call check ("a mutually tail-recursive group emits cleanly",
  $call eq_int (mut_c.nerrs, 0))

// §6a: one function, a state variable, one dispatch loop.
$decl t45 $call check ("the group is contified into one dispatch loop",
  $if ($call has (mut_c.code, "mpl_grp0(void *env, int64_t state"))
      ($call has (mut_c.code, "switch ((int)state) {")) false)

// A tail call to another member changes the state and re-enters the loop,
// rather than calling.
$decl t46 $call check ("a mutual tail call is a state change, not a call",
  $if ($call has (mut_c.code, "  state = 1;")) ($call has (mut_c.code, "  continue;")) false)

// Calls from outside the group are unchanged: each member keeps its name as a
// wrapper that enters at its own state.
$decl t47 $call check ("each member keeps a wrapper entering at its state",
  $call has (mut_c.code, "return mpl_grp0(env, 1, s0);"))

// §6a's third case has no answer here: a trampoline needs every function to
// return "a value or a pending call", which is a calling convention this
// backend does not have. The plain call is correct but not §7.7's guarantee,
// so it is marked in the output rather than left looking eliminated.
$decl t48 $call check ("an indirect tail call is marked, not silently un-eliminated",
  $call has (clo_c.code, "not eliminated (6a)"))

// ------------------------------------------------------------------ unions

$decl uni_c $call compile ($call concat (
  "$decl c { $prop k \"c\"  $decl r 3 } $decl q { $prop k \"q\"  $decl w 4 } ",
  $call concat ("$decl s $union (c, q) ",
  $call concat ("$decl area $func ($decl x $union (c, q)) $match x ( ",
  $call concat ("$case {$prop k \"c\"} x.r, $case {$prop k \"q\"} x.w) ",
                "$decl main $func () $call area (s) ")))))

$decl t49 $call check ("a program using $union emits cleanly",
  $call eq_int (uni_c.nerrs, 0))

// §4.8a: the value is the *first* member, coerced to the join — so the tag is
// set where the union is built, not where it is matched.
$decl t50 $call check ("a union value is its first member, injected",
  $call has (uni_c.code, ".tag = "))

// §3.2 makes `Bool` the union `true | false`, but its discriminator is its own
// value — so it stays a machine word and a `$match` on one is an `$if`.
$decl bool_c $call compile ($call concat (
  "$decl f $mut $new ($union (false, true)) ",
  "$decl main $func () $match f ($case true 1, $case f 0) "))

$decl t51 $call check ("a Bool union stays a machine word",
  $if ($call eq_int (bool_c.nerrs, 0))
      ($call has (bool_c.code, "static int64_t * mpl_g0;")) false)

$decl t52 $call check ("...and a $match on one is an $if, not a switch",
  $call not ($call has (bool_c.code, "switch")))

// ------------------------------------------------- recursive types (§5.5)
//
// A `μ` is laid out as its unrolling: the cons cell is a struct of its own and
// the union the `μ` names embeds it by value, so the cell has to be *defined*
// first — which is not the order they were interned in, since the cell names
// the `μ`. What makes that order exist is §5.5's guardedness: every recursive
// edge goes through storage, so it is a pointer, and a pointer needs only the
// forward declaration.
$decl rec_src $call concat (
  "$decl lst $template T { $prop nil { $prop tag \"nil\" } ",
  $call concat ("$prop node $union (nil, { $prop tag \"cons\"  $decl head T  $decl tail $new node }) ",
  $call concat ("$prop cons $func ($decl h T, $decl t node) { $prop tag \"cons\"  $decl head h  $decl tail $new t } } ",
                "$decl ints $specialize lst 0  $decl main $func () ($call ints.cons (1, ints.nil)).head ")))

$decl rec_c $call compile (rec_src)

$decl t30 $call check ("a program with a recursive type emits cleanly",
  $call eq_int (rec_c.nerrs, 0))

$decl t31 $call check ("the recursive field is a pointer, which is why the layout terminates",
  $call has (rec_c.code, " * f1; };"))

$decl t32 $call check ("the type a recursive binder names is a discriminated union (§7.5)",
  $call has (rec_c.code, "{ int64_t tag; union {"))

// --------------------------------------------- union into union (§7.4)
//
// §3.6 makes a union a set and §7.5 makes its order the discriminator, so
// using `<a,b>` where `<c,a,b>` is expected is a re-tag, not a copy: the same
// member sits at a different position in each.
$decl u2u_src $call concat (
  "$decl a { $prop tag \"a\"  $decl v 1 }  $decl b { $prop tag \"b\"  $decl v 2 } ",
  $call concat ("$decl c { $prop tag \"c\"  $decl v 3 }  $decl small $union (a, b)  $decl big $union (c, a, b) ",
                "$decl widen $func ($decl x big) $match x ($case {$prop tag \"a\"} x.v, $case x x.v) "))

$decl u2u_c $call compile ($call concat (u2u_src, "$decl main $func () $call widen (small) "))

$decl t33 $call check ("a union coerced into a larger union emits cleanly",
  $call eq_int (u2u_c.nerrs, 0))

$decl t34 $call check ("...as a switch on the source's discriminator",
  $call has (u2u_c.code, "switch ((int)"))

$decl t35 $call check ("...that writes the target's position, not the source's",
  $call has (u2u_c.code, ".tag = 2;"))

$decl done $call nl ("all C backend tests passed")
