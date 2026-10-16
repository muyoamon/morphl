// Typed tree → C (BOOTSTRAP.md stage 1, the last piece).
//
// **Statements, not expressions.** A morphl `$if` is an expression and C's is a
// statement, so every node is emitted as statements that assign into a
// destination variable the caller declared. Emitting expressions instead would
// work until §7.7: a tail call has to become `continue`, which is a statement
// and cannot sit inside a `?:`.
//
// **§6a's self and mutual cases are both emitted.** A direct self tail call
// becomes `while (1)` with `continue`, and the parameters are updated *in
// parallel* — every new argument into a temporary first, then assigned — or
// `$call f (b, a)` would clobber `b` before reading it. A mutually
// tail-recursive group is contified: one function, a state variable, one
// dispatch loop, and a wrapper per member keeping its name. There are two
// contification paths, and `same_sig` is all that chooses between them — the
// fast one shares a parameter list and a `ret` across the members, the general
// one gives each member parameter variables of its own and returns through an
// out-parameter, because a C function has one return type and the members can
// have several. The **indirect** case is the one still missing: a tail call
// through a function *value* is emitted as a plain call carrying a marker, since
// the trampoline it calls for needs a whole-program calling convention this
// backend does not have.
//
// **Coverage is everything the bootstrap subset uses.** `Int`, the booleans and
// unit as `int64_t`; §3.1's `Str`; blocks as structs in §7.2 layout order;
// unions as §7.5's tag and payload; §4.2's storage as a thin pointer; §7.3's
// two-word closures; §4.15's `$try`; §4.9's specialisations, already
// monomorphic by the time lowering is done; §4.14's imports; §8's intrinsics,
// arrays included. What is refused by name rather than mis-emitted is `Float`
// (BOOTSTRAP §1.2 drops float arithmetic) and `write_file`; `emit_errs` is not
// empty when that happens, and the C is not worth compiling.

$decl P  $import "prelude"
$decl T  $import "types"
$decl Pa $import "parser"
$decl IR $import "ir"

$decl not P.not
$decl and P.and

$decl strs $specialize P.list ""

// A global and what it really names. §4.10 puts it here because `estate` below
// holds a list of these, and the functions that build and read them are down
// with `is_thunk`, where the reason they exist is written out.
$decl fnal $func ($decl f 0, $decl t 0, $decl pn "", $decl xn "")
  { $decl from f  $decl to t  $decl prim pn  $decl xsym xn }
$decl proto_fnal $call fnal (0, 0, "", "")
$decl fnals      $specialize P.list proto_fnal

// ------------------------------------------------------------------- state

$decl estate $func () {
  // The output, as the chunks `say` appended, newest first. Not one growing
  // `Str`: `concat` copies both operands, so appending n chunks totalling L
  // bytes that way copies O(L n) — 590 MB to produce the 350 KB of C that
  // `types.mpl` emits, which was 80% of everything an emit run allocated.
  // `out_of` joins them in one balanced pass instead.
  $decl out  $mut $alloc strs.node
  $decl ntmp $mut $alloc 0
  // The name of the §6a group being emitted. A group function is `static`, so its
  // name need only be unique within its output — but it used to be numbered by the
  // group's **position in the whole program's** group list, so adding a group
  // anywhere renamed it. Named from its first member instead, which is a stable
  // identity (§4.14 keeps a tail-call cycle inside one module, so the member is
  // this module's). Held here rather than passed, because the wrapper emitter is
  // reached after the member list has been walked away — the same reason `grp`,
  // `gen` and `retc` live here.
  $decl grpn $mut $alloc ""
  // The result type of the function being emitted. §4.15 returns from it
  // from arbitrary depth, so the type has to be reachable from anywhere in
  // the body rather than threaded through every node.
  $decl fnres $mut $alloc 0
  // The group being emitted, if any: §6a merges a mutually tail-recursive
  // set into one function, so a tail call to a member is a state change
  // rather than a call.
  $decl grp   $mut $alloc IR.ints.node
  // §6a's general case: a group whose members do *not* share a signature
  // becomes one function with an out-parameter, because there is no single C
  // return type to give it and no single parameter list to receive them. Two
  // things then differ from the shared-signature path, and both have to be
  // reachable from anywhere in a body: `retc` is the C type `retp` points at
  // (empty when the function simply returns), and `gen` says that a tail call
  // to a member assigns that member's own parameter variables rather than the
  // shared slots.
  $decl retc  $mut $alloc ""
  // `$union (false, true)`, not `P.boolean`: §4.8a makes a `$union` evaluate to
  // its *first* member, and `P.boolean` is `$union (true, false)` — so storage
  // typed with it starts out **true**. This one has to start false, and getting
  // it wrong made every ordinary function take the general path's naming, which
  // `cc` caught as `q-2_0` (the fast path's "this very function" marker run
  // through a name only a general group has).
  $decl gen   $mut $alloc $union (false, true)
  // Which globals are thunks. A thunk's index names a *static* holding a
  // value, not a function to call — so naming one is reading `mpl_g<i>`, and
  // calling one is an indirect call through the pair that static holds.
  $decl thunks $mut $alloc IR.ints.node
  // Which globals are aliases, and of what: a thunk whose body is one
  // `global` is a call to a compile-time-constant target, so it is direct
  // (§6a, and `res_fn` above says why).
  $decl aliases $mut $alloc fnals.node
  // §6a's indirect case. `reps` is the functions that *report* an indirect
  // tail call rather than make it, `tsigs` the callee types a driver has to be
  // able to call, and `inrep` whether the function being emitted right now is
  // one of the reporters — which is what its tail-call sites need to know.
  $decl reps  $mut $alloc IR.ints.node
  $decl tsigs $mut $alloc IR.ints.node
  $decl inrep $mut $alloc $union (false, true)
  // The struct definitions already written. A type is defined after
  // everything it contains *by value*, which is not index order — a `μ` is
  // interned before the members it embeds, because they name it.
  $decl emitted $mut $alloc IR.ints.node
  // The §4.16 function-pointer typedefs already written, by interned index.
  $decl fps $mut $alloc IR.ints.node
  // One C name per function, computed once from the table. §7.3's pair, §4.10's
  // statics and every direct call name a function from anywhere in the program, so
  // the name has to come from the function's own identity — `IR.fn`'s `mod` and
  // `rank` — and not from its table index, which every other module's contents
  // shift. Held here rather than threaded, because the expression emitter carries
  // `est` everywhere and the function table nowhere.
  $decl fnames $mut $alloc strs.node
  $decl errs   $mut $alloc Pa.diags.node
}

$decl proto_est $call estate ()

$decl eval_diags $func ($decl x Pa.diags.node) x

$decl emit_errs $func ($decl st proto_est) $call eval_diags (st.errs)

// Fold each adjacent pair of chunks into one, halving the list. The result
// comes out reversed, which is why `join_step` reverses between passes —
// pointer work, where getting the order wrong would concatenate backwards.
//
// Split in two so that every recursive call is a *tail* call (§7.7): reading
// `xs.tail` twice would need a `$decl` to bind it, and a block around a
// recursive call is a real frame (§7.7 again), which at half the chunk count
// per pass is thousands of them.
$fwd join_pass

$decl join_two $func ($decl a "", $decl t strs.node, $decl acc strs.node) $match t (
  $case {$prop tag "cons"}
    $call join_pass (t.tail, $call strs.cons ($call concat (a, t.head), acc)),
  $case t ($call join_pass (t, $call strs.cons (a, acc)))
)

$decl join_pass $func ($decl xs strs.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"} $call join_two (xs.head, xs.tail, acc),
  $case xs acc
)

$fwd join_all

// `a` is the first chunk and `t` the rest. One chunk left and the join is
// done; otherwise fold the pairs and go round again. Each pass copies the
// output once and there are log2(n) of them, so joining n chunks totalling L
// bytes costs O(L log n) against a left fold's O(L n).
$decl join_step $func ($decl xs strs.node, $decl a "", $decl t strs.node) $match t (
  $case {$prop tag "cons"}
    $call join_all ($call strs.reverse ($call join_pass (xs, strs.nil), strs.nil)),
  $case t a
)

$decl join_all $func ($decl xs strs.node) $match xs (
  $case {$prop tag "cons"} $call join_step (xs, xs.head, xs.tail),
  $case xs ""
)

$decl out_of $func ($decl st proto_est)
  $call join_all ($call strs.reverse (st.out, strs.nil))

// Take what has been said so far and start a fresh output. §9.1 makes `emit` answer a
// *list* of files, and this is how one accumulator serves all of them: the chunks are
// joined once per file, so the O(L log n) join of `out_of` is paid per file rather than
// once over everything.
$decl cut_out $func ($decl st proto_est) {
  $decl t   $call out_of (st)
  $decl c   $set st.out strs.nil
  $decl ret t
}.ret

$decl say $func ($decl st proto_est, $decl s "") {
  $decl w   $set st.out ($call strs.cons (s, st.out))
  $decl ret ()
}.ret

$decl eerr $func ($decl st proto_est, $decl m "") {
  $decl noted $set st.errs ($call Pa.diags.cons ($call Pa.diag (m, 0, 0, ""),
                                                 $call eval_diags (st.errs)))
  $decl ret ()
}.ret

// A fresh C temporary. Declared where it is used, so it lives in the C block
// the value is produced in — which is the block its destination lives in too.
$decl fresh_tmp $func ($decl st proto_est) {
  $decl i   $call P.ival (st.ntmp)
  $decl n   $set st.ntmp ($call add (i, 1))
  $decl ret $call concat ("t", $call int_to_str (i))
}.ret

$decl slot_name $func ($decl i 0) $call concat ("s", $call int_to_str (i))
// A member of a general §6a group has parameter variables of its own, named by
// the state it answers for — declared up here because the tail-call emitter
// names it long before the group emitter does, and §4.10 is source order.
$decl qpre $func ($decl si 0) $call concat ("q", $call concat ($call int_to_str (si), "_"))
// A member of a general §6a group has no C return type of its own — the group
// function is `void` and writes through `retp` — so every `return ret` in the
// backend goes through here. There are three: the end of an ordinary function,
// the end of a member's `case`, and §4.15's `$try`, which returns from
// arbitrary depth.
$decl emit_return $func ($decl st proto_est) {
  $decl c $call P.sval (st.retc)
  $decl ret $if ($call eq_str (c, "")) ($call say (st, "  return ret;\n"))
      ($call say (st, $call concat ("  *(", $call concat (c, " *)retp = ret;\n  return;\n"))))
}.ret
// A function's stable suffix: its module's short name and its rank within that
// module, so an edit to another module leaves it alone. The entry file has no module
// name and takes `e`.
// A function's C name comes from `nmod`, not `mod`: the first is its stable identity
// and the second is only which output it is emitted in. They differ for a
// `$specialize`'s members and for a props-bearing block literal's, which are named
// from themselves and emitted in the file whose source produced them.
// **Two allocators share `rank`, so the key has to separate them.** A module member's
// rank is its index among its module's props (source order, so it is stable); every
// other function's is `next_rank`'s counter. Both start at 0, so `parser`'s member #15
// (`n_err`) and `parser`'s 15th counter-allocated function — a §3.3 effect — came out
// with one C name, two definitions and two different signatures.
//
// That was a **miscompile, not a link error**: the duplicate was accepted and calls
// resolved to whichever definition won, which is how the emitted compiler lost
// `emit_fn`'s temporary reset. It showed up as self-compilation oscillating with
// period 2 instead of reaching BOOTSTRAP's stage-3 fixed point, and nothing smaller
// than the whole-compiler closure reproduced it.
//
// `pub` is exactly the distinction, not a proxy for it: it is set at the two sites
// that give a function a prop index (`lower_prop_body`, `lower_prop_thunk`) and
// nowhere else. So `_m` on a member makes the two spaces disjoint by construction.
// Within each, uniqueness is already guaranteed — §4.1 gives a module one binding per
// name, hence one prop index each, and a counter repeats nothing.
$decl fn_key $func ($decl f IR.proto_fn) {
  $decl nd $call P.sval (f.nmod)
  $decl ret  $call concat ($if ($call eq_str (nd, "")) "e" nd,
               $call concat ($if f.pub "_m" "_", $call int_to_str (f.rank)))
}.ret

$decl fn_keys $func ($decl fs IR.fns.node, $decl acc strs.node) $match fs (
  $case {$prop tag "cons"}
    $call fn_keys ($call IR.fns.val (fs.tail), $call strs.cons ($call fn_key (fs.head), acc)),
  $case fs ($call strs.reverse (acc, strs.nil))
)

// **The program being emitted, by index.** `fn_at`, `key_at` and `type_at` walked the
// function table, the name list and the type table from the head with `nth` — ~11% of a
// self-emit between them. `emit_program` indexes all three at its start, and they read
// these. Module storage rather than a field of `est` because `type_at` and `fn_at` take
// the table, not the state, at some forty call sites; nothing outside `emit_program`
// calls them, and each `emit_program` rebuilds both before emitting anything, so one
// program's index can never answer for another's.
$decl fent       $func ($decl i 0, $decl f IR.proto_fn,
    $decl k "") { $decl idx i  $decl fn f  $decl key k }
$decl proto_fent $call fent (-1, IR.proto_fn, "")
$decl fents      $specialize P.list proto_fent
$decl ftrie $union (
  { $prop tag "leaf"   $decl items $alloc fents.node },
  { $prop tag "branch" $decl lo $alloc ftrie  $decl hi $alloc ftrie }
)
$decl ft_leaf $func ($decl xs fents.node) { $prop tag "leaf" $decl items $alloc xs }
$decl ft_branch $func ($decl l ftrie, $decl h ftrie) {
  $prop tag "branch" $decl lo $alloc l  $decl hi $alloc h
}
$decl ft_val   $func ($decl x ftrie) x
$decl ft_items $func ($decl tr ftrie)
    $match tr ($case {$prop tag "leaf"} ($call fents.val (tr.items)), $case tr fents.nil)
// The one empty leaf every absent child shares: the trie is persistent, so it is
// never written, and a fresh one per child was an allocation per level (PERF.md).
$decl ft_nil $call ft_leaf (fents.nil)
$decl ft_kid $func ($decl tr ftrie, $decl hi P.boolean) $match tr (
  $case {$prop tag "branch"} ($call ft_val ($if hi tr.hi tr.lo)),
  $case tr ft_nil
)
$decl ft_add $func ($decl tr ftrie, $decl b 0, $decl d 0, $decl e proto_fent)
  $if ($call not ($call lt (d, 10))) ($call ft_leaf ($call fents.cons (e, $call ft_items (tr)))) {
    $decl lo $call ft_kid (tr, false)
    $decl hi $call ft_kid (tr, true)
    $decl up $call eq_int ($call mod (b, 2), 0)
    $decl ret  $if up ($call ft_branch ($call ft_add (lo, $call div (b, 2), $call add (d, 1), e),
        hi))
                    ($call ft_branch (lo, $call ft_add (hi, $call div (b, 2), $call add (d, 1), e)))
  }.ret
$decl ft_scan $func ($decl xs fents.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} $if ($call eq_int (xs.head.idx,
      i)) xs.head ($call ft_scan ($call fents.val (xs.tail), i)),
  $case xs proto_fent
)
$decl ft_find $func ($decl tr ftrie, $decl b 0, $decl i 0) $match tr (
  $case {$prop tag "branch"}
    $if ($call eq_int ($call mod (b, 2), 0)) ($call ft_find ($call ft_val (tr.lo), $call div (b, 2),
        i))
        ($call ft_find ($call ft_val (tr.hi), $call div (b, 2), i)),
  $case tr ($call ft_scan ($call ft_items (tr), i))
)
$decl ft_fill $func ($decl tr ftrie, $decl fs IR.fns.node, $decl ks strs.node,
    $decl i 0) $match fs (
  $case {$prop tag "cons"} $match ks (
      $case {$prop tag "cons"}
        $call ft_fill ($call ft_add (tr, $call mod (i, 1021), 0, $call fent (i, fs.head, ks.head)),
                       $call IR.fns.val (fs.tail), ks.tail, $call add (i, 1)),
      $case ks tr),
  $case fs tr
)

$decl em_fnix $mut $alloc ftrie
$decl em_tyix $mut $alloc IR.proto_trie
$decl em_at   $func ($decl i 0) $call ft_find ($call ft_val (em_fnix), $call mod (i, 1021), i)

$decl key_at $func ($decl st proto_est, $decl i 0) ($call em_at (i)).key

$decl gbl_name  $func ($decl st proto_est, $decl i 0)
  $call concat ("mpl_g", $call key_at (st, i))
$decl fn_name   $func ($decl st proto_est, $decl i 0)
  $call concat ("mpl_f", $call key_at (st, i))

// The C side of §8's string intrinsics.
//
// §3.1 makes a `Str` a pointer and a length, immutable and always valid UTF-8 —
// so `slice` shares the bytes and costs nothing, while `concat` and
// `int_to_str` have to put their result somewhere. That somewhere is `malloc`
// and never `free`, which is stage 0's model exactly (BOOTSTRAP.md §3) and what
// §7.6's regions are meant to replace.
$decl runtime_c "#include <stdint.h>\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n\ntypedef struct { const char *p; int64_t n; } mpl_str;\n\n/* A function value is a code pointer and an environment, two words whatever\n   its signature (7.3): captures belong to the body, not to the type. */\ntypedef struct { void *code; void *env; } mpl_fun;\n\nstatic _Noreturn void mpl_panic(const char *m) { fputs(m, stderr); fputc('\\n', stderr); abort(); }\n\nstatic char *mpl_alloc(int64_t n) {\n  char *p = (char *)malloc((size_t)(n > 0 ? n : 1));\n  if (!p) mpl_panic(\"out of memory\");\n  return p;\n}\n\n/* 8's `args`, as the host gave them. Set before `mpl_init` runs, because a\n   top-level `$decl` initializer may read them (4.10). */\nextern int mpl_argc;\nextern char **mpl_argv;\n\nstatic mpl_str mpl_concat(mpl_str a, mpl_str b) {\n  char *p = mpl_alloc(a.n + b.n);\n  memcpy(p, a.p, (size_t)a.n);\n  memcpy(p + a.n, b.p, (size_t)b.n);\n  return (mpl_str){ p, a.n + b.n };\n}\n\nstatic int64_t mpl_str_eq(mpl_str a, mpl_str b) {\n  return a.n == b.n && memcmp(a.p, b.p, (size_t)a.n) == 0;\n}\n\nstatic int64_t mpl_len(mpl_str s) { return s.n; }\n\nstatic mpl_str mpl_slice(mpl_str s, int64_t i, int64_t j) {\n  if (i < 0 || j < i || j > s.n) mpl_panic(\"slice: out of range\");\n  return (mpl_str){ s.p + i, j - i };\n}\n\nstatic int64_t mpl_byte(mpl_str s, int64_t i) {\n  if (i < 0 || i >= s.n) mpl_panic(\"byte: index out of range\");\n  return (int64_t)(unsigned char)s.p[i];\n}\n\nstatic mpl_str mpl_int_to_str(int64_t v) {\n  char buf[24];\n  int k = snprintf(buf, sizeof buf, \"%lld\", (long long)v);\n  char *p = mpl_alloc(k);\n  memcpy(p, buf, (size_t)k);\n  return (mpl_str){ p, k };\n}\n\nstatic int64_t mpl_print(mpl_str s) {\n  fwrite(s.p, 1, (size_t)s.n, stdout);\n  return 0;\n}\n\n/* BOOTSTRAP 2's `eprint`: `print` to stderr, which is how a compiled compiler\n   reports a warning without writing it into the C on stdout. */\nstatic int64_t mpl_eprint(mpl_str s) {\n  fwrite(s.p, 1, (size_t)s.n, stderr);\n  return 0;\n}\n\n/* 8's arithmetic and comparisons are C operators, so they have no address. A\n   value of function type is a pair (7.3), and a pair needs one - `$decl isub\n   sub` is an intrinsic used as a value, which the compiler's own sources do.\n   These are that address, and nothing else calls them: a *call* to an\n   intrinsic is still emitted infix. */\n#define MPL_BINOP(n, op) \\\n  static int64_t mpl_fn_##n(void *env, int64_t a, int64_t b) { (void)env; return a op b; }\nMPL_BINOP(add, +)\nMPL_BINOP(sub, -)\nMPL_BINOP(mul, *)\nMPL_BINOP(div, /)\nMPL_BINOP(mod, %)\nMPL_BINOP(lt, <)\nMPL_BINOP(eq_int, ==)\n#undef MPL_BINOP\n\n/* The rest of 8's overloads as values: unary `neg`, `to_float` and `to_str`, and\n   `eq` on strings. `eq` on `Int` and on `Bool` is `mpl_fn_eq_int`. */\nstatic int64_t mpl_fn_neg(void *env, int64_t a) { (void)env; return -a; }\nstatic double mpl_fn_to_float(void *env, int64_t a) { (void)env; return (double)a; }\nstatic mpl_str mpl_fn_to_str(void *env, int64_t a) { (void)env; return mpl_int_to_str(a); }\nstatic int64_t mpl_fns_eq(void *env, mpl_str a, mpl_str b) { (void)env; return mpl_str_eq(a, b); }\n\n/* 3.1's `Float` is a C double, and 8's arithmetic on it is C's. `mod` is computed\n   here rather than by libm's `fmod`, so a program links against nothing but libc.\n   It is exact: each step takes off the largest power-of-two multiple of `y` that\n   fits, and with t <= r < 2t that subtraction is exact (Sterbenz). The sign is the\n   dividend's, as C's `%` and `fmod` both have it. */\nstatic double mpl_fmod(double x, double y) {\n  double ax = x < 0 ? -x : x, ay = y < 0 ? -y : y, r;\n  if (x != x || y != y || ay == 0 || ax - ax != 0) return (ax - ax) / (ax - ax);\n  if (ax < ay) return x;\n  r = ax;\n  while (r >= ay) {\n    double t = ay;\n    while (t <= r - t) t += t;\n    r -= t;\n  }\n  return x < 0 ? -r : r;\n}\n\n/* The shortest of 15, 16 and 17 significant digits that reads back as the same\n   double, so `to_str` round-trips; and a `.0` when the digits alone would read as\n   an `Int`, so the text is a morphl float literal whenever it is finite. */\nstatic mpl_str mpl_float_to_str(double v) {\n  char buf[48];\n  int k = 0, prec, i, plain = 1;\n  char *p;\n  for (prec = 15; prec <= 17; prec++) {\n    k = snprintf(buf, 40, \"%.*g\", prec, v);\n    if (v != v || strtod(buf, NULL) == v) break;\n  }\n  for (i = 0; i < k; i++)\n    if (buf[i] == '.' || buf[i] == 'e' || buf[i] == 'n' || buf[i] == 'i') plain = 0;\n  if (plain) { buf[k++] = '.'; buf[k++] = '0'; }\n  p = mpl_alloc(k);\n  memcpy(p, buf, (size_t)k);\n  return (mpl_str){ p, k };\n}\n\n/* 8's `to_int` on a `Float` truncates toward zero, and a value outside `Int`'s\n   range - or NaN, which fails both comparisons - is `none`. */\nstatic int mpl_float_to_int(double v, int64_t *out) {\n  if (!(v >= -9223372036854775808.0 && v < 9223372036854775808.0)) return 0;\n  *out = (int64_t)v;\n  return 1;\n}\n\nstatic double mpl_fnf_add(void *env, double a, double b) { (void)env; return a + b; }\nstatic double mpl_fnf_sub(void *env, double a, double b) { (void)env; return a - b; }\nstatic double mpl_fnf_mul(void *env, double a, double b) { (void)env; return a * b; }\nstatic double mpl_fnf_div(void *env, double a, double b) { (void)env; return a / b; }\nstatic double mpl_fnf_mod(void *env, double a, double b) { (void)env; return mpl_fmod(a, b); }\nstatic int64_t mpl_fnf_lt(void *env, double a, double b) { (void)env; return a < b; }\nstatic int64_t mpl_fnf_eq(void *env, double a, double b) { (void)env; return a == b; }\nstatic double mpl_fnf_neg(void *env, double a) { (void)env; return -a; }\nstatic mpl_str mpl_fnf_to_str(void *env, double a) { (void)env; return mpl_float_to_str(a); }\n\n/* 7.8: `panic` aborts. It takes a morphl `Str`, which is bytes and not a C\n   string (3.1), so it is written out by length rather than by NUL. The return\n   type is a lie the call site needs and the body never tells: nothing after a\n   call to this runs. */\nstatic int64_t mpl_panic_str(mpl_str s) {\n  fwrite(s.p, 1, (size_t)s.n, stderr);\n  fputc('\\n', stderr);\n  abort();\n}\n\n/* 8 makes a failing operation answer an option rather than panic, and 7.5\n   lays that out as a tag and a union. These do the work and report whether it\n   succeeded; the *emitted* code builds the option, because only the call site\n   knows which position `some` and `none` took in its own interned union - 3.6\n   makes a union a set and 7.5 makes the order the discriminator, so the two\n   numbers are not fixed. */\nstatic int mpl_str_to_int(mpl_str s, int64_t *out) {\n  uint64_t v = 0;\n  uint64_t limit;\n  int64_t i = 0;\n  int neg = 0;\n  if (s.n == 0) return 0;\n  if (s.p[0] == '-' || s.p[0] == '+') { neg = (s.p[0] == '-'); i = 1; }\n  if (i >= s.n) return 0;\n  /* Stage 0 is Zig's parseInt, so `_` may separate digits but may not begin or\n     end the number; two implementations of one intrinsic have to agree. */\n  if (s.p[i] == '_' || s.p[s.n - 1] == '_') return 0;\n  /* The negative range is one larger, and -9223372036854775808 does parse. */\n  limit = neg ? (uint64_t)INT64_MAX + 1u : (uint64_t)INT64_MAX;\n  for (; i < s.n; i++) {\n    unsigned char c = (unsigned char)s.p[i];\n    if (c == '_') continue;\n    if (c < '0' || c > '9') return 0;\n    if (v > (limit - (uint64_t)(c - '0')) / 10u) return 0;\n    v = v * 10u + (uint64_t)(c - '0');\n  }\n  if (neg) *out = (v == (uint64_t)INT64_MAX + 1u) ? INT64_MIN : -(int64_t)v;\n  else *out = (int64_t)v;\n  return 1;\n}\n\n/* 3.1 makes a `Str` UTF-8, so this is the encoder, and a code point outside\n   the scalar range has no encoding - which is the `none`. */\nstatic int mpl_from_code(int64_t cp, mpl_str *out) {\n  char *p;\n  int64_t n;\n  if (cp < 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;\n  n = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;\n  p = mpl_alloc(n);\n  if (n == 1) { p[0] = (char)cp; }\n  else if (n == 2) { p[0] = (char)(0xC0 | (cp >> 6)); p[1] = (char)(0x80 | (cp & 0x3F)); }\n  else if (n == 3) { p[0] = (char)(0xE0 | (cp >> 12)); p[1] = (char)(0x80 | ((cp >> 6) & 0x3F)); p[2] = (char)(0x80 | (cp & 0x3F)); }\n  else { p[0] = (char)(0xF0 | (cp >> 18)); p[1] = (char)(0x80 | ((cp >> 12) & 0x3F)); p[2] = (char)(0x80 | ((cp >> 6) & 0x3F)); p[3] = (char)(0x80 | (cp & 0x3F)); }\n  out->p = p;\n  out->n = n;\n  return 1;\n}\n\n/* Stage 0 validates UTF-8 before answering `some` (3.1 again), so this does\n   too: a file that is not text is `none`, not a `Str` that lies about itself. */\nstatic int mpl_utf8_ok(const char *p, int64_t n) {\n  int64_t i = 0;\n  while (i < n) {\n    unsigned char c = (unsigned char)p[i];\n    int64_t k, j;\n    int64_t lo;\n    if (c < 0x80) { i++; continue; }\n    else if ((c & 0xE0) == 0xC0) { k = 2; lo = 0x80; }\n    else if ((c & 0xF0) == 0xE0) { k = 3; lo = 0x800; }\n    else if ((c & 0xF8) == 0xF0) { k = 4; lo = 0x10000; }\n    else return 0;\n    if (i + k > n) return 0;\n    {\n      int64_t cp = c & (0xFF >> (k + 1));\n      for (j = 1; j < k; j++) {\n        unsigned char cc = (unsigned char)p[i + j];\n        if ((cc & 0xC0) != 0x80) return 0;\n        cp = (cp << 6) | (cc & 0x3F);\n      }\n      if (cp < lo || cp > 0x10FFFF) return 0;\n      if (cp >= 0xD800 && cp <= 0xDFFF) return 0;\n    }\n    i += k;\n  }\n  return 1;\n}\n\n/* Read by growing, never by `ftell`: a directory opens for reading on Linux\n   and reports a size of LONG_MAX, which sized an allocation that aborted where\n   stage 0 simply answers `none`. `fread` failing is the only signal trusted. */\n/* 8's `write_file`, the counterpart of `mpl_read_file`. Answers 1 on success and\n   0 on any failure, which the call site turns into 8's `unit` or `err` - which of\n   the two positions each takes belongs to the call site's interned union (7.5),\n   not to this. Truncating, like stage 0's platform. */\nstatic int mpl_write_file(mpl_str path, mpl_str data) {\n  char *name = mpl_alloc(path.n + 1);\n  FILE *f;\n  size_t put;\n  memcpy(name, path.p, (size_t)path.n);\n  name[path.n] = 0;\n  f = fopen(name, \"wb\");\n  free(name);\n  if (!f) return 0;\n  put = data.n > 0 ? fwrite(data.p, 1, (size_t)data.n, f) : 0;\n  if (put != (size_t)data.n) { fclose(f); return 0; }\n  if (fclose(f) != 0) return 0;\n  return 1;\n}\n\nstatic int mpl_read_file(mpl_str path, mpl_str *out) {\n  char *name = mpl_alloc(path.n + 1);\n  FILE *f;\n  char *buf;\n  int64_t cap = 4096;\n  int64_t n = 0;\n  memcpy(name, path.p, (size_t)path.n);\n  name[path.n] = 0;\n  f = fopen(name, \"rb\");\n  free(name);\n  if (!f) return 0;\n  buf = mpl_alloc(cap);\n  for (;;) {\n    size_t got;\n    if (n == cap) {\n      char *nb = mpl_alloc(cap * 2);\n      memcpy(nb, buf, (size_t)n);\n      buf = nb;\n      cap *= 2;\n    }\n    got = fread(buf + n, 1, (size_t)(cap - n), f);\n    n += (int64_t)got;\n    if (got == 0) break;\n  }\n  if (ferror(f)) { fclose(f); return 0; }\n  fclose(f);\n  if (!mpl_utf8_ok(buf, n)) return 0;\n  out->p = buf;\n  out->n = n;\n  return 1;\n}\n"

// ------------------------------------------------------------------- types
//
// Everything in this subset is a machine word. §7.2's real layout — a block as
// a C struct in `$decl` order — is what the next slice adds; refusing by name
// is better than emitting a struct whose fields nothing yet writes.

// §8's `args`, as the host gave them — the one piece of the runtime that is *state*
// rather than code. The runtime's functions may be `static` in a shared header and
// duplicated per translation unit at no cost beyond size, but a copy of these per file
// would leave every file except the one holding `main` reading zero. So they are
// declared `extern` in the runtime and defined exactly once, beside `main`.
$decl runtime_state "int mpl_argc = 0;\nchar **mpl_argv = 0;\n"

$decl type_at $func ($decl ts T.tys.node, $decl i 0) $call IR.ix_get ($call IR.tval_trie (em_tyix),
    i)

// A struct's name is derived from the type's **content**, not from its position in
// §9.3's table. The index would do for one whole-program emit — one index per
// distinct type is the point of interning — but it makes the name depend on every
// other type in the program: interning one more type early renumbers everything
// after it, so two modules lowered separately would disagree about what `mpl_t7`
// is, and the emitted C changes under edits that have nothing to do with it.
// Hashing the structure gives a name two independent lowerings agree on, which is
// what any per-module or cached scheme needs first. A collision would be two
// conflicting definitions of one struct name, which `cc` rejects — see `hmod`.
$decl ty_name $func ($decl ts T.tys.node, $decl i 0)
  $call concat ("mpl_t", $call int_to_str ($call T.hash_of ($call T.tval ($call type_at (ts, i)))))

// A type's C spelling, by its interned index — the index is the struct's name,
// which is the whole point of interning (§5.1: one index per distinct type).
$fwd c_type

$decl c_scalar $func ($decl st proto_est, $decl t T.proto_ty)
  $if ($call T.same (t, T.t_int))   "int64_t"
  ($if ($call T.same (t, T.t_float)) "double"
  ($if ($call T.same (t, T.t_bool)) "int64_t"
  ($if ($call T.same (t, T.t_true)) "int64_t"
  ($if ($call T.same (t, T.t_false)) "int64_t"
  ($if ($call T.same (t, T.t_str))  "mpl_str"
  ($if ($call T.same (t, T.t_unit)) "int64_t"
  // §7.8: `panic` aborts, so it is a terminator and its type is ⊥ — the type
  // of an expression that does not return. No value ever has it, so the C
  // type is only a placeholder for a slot nothing will ever read.
  ($if ($call T.same (t, T.t_bot))  "int64_t" {
    $decl e   $call eerr (st, $call concat ("cannot emit the type ", $call T.show (t)))
    $decl ret "int64_t"
  }.ret)))))))

$decl c_type $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0) {
  $decl t   $call type_at (ts, i)
  $decl ret $match t (
      // §7.2: a block is a C struct in `$decl` order.
      $case {$prop tag "block"} ($call ty_name (ts, i)),
      // §5.5's `μ` is laid out as its unrolling, under its own index's name:
      // one struct however the type was spelled, which is what makes the
      // index a C struct name at all.
      $case {$prop tag "rec"} ($call ty_name (ts, i)),
      // §7.2: "Groups are laid out elementwise" — a struct whose members
      // have positions instead of names, which is what `.n` indexes.
      $case {$prop tag "group"} ($call ty_name (ts, i)),
      // §4.8: "at runtime an overload *is* that group", laid out as one.
      $case {$prop tag "over"} ($call ty_name (ts, i)),
      // §7.5: a value of union type carries a discriminator, and that is the
      // only construct that reads it (§4.7). Except `Bool` — §3.2 makes it
      // the union `true | false`, but its discriminator *is* its value, which
      // is what lets `$if` take one as a condition.
      $case {$prop tag "union"}
        $if ($call T.same (t, T.t_bool)) "int64_t" ($call ty_name (ts, i)),
      // §7.3: every function value has the same shape, which is what lets a
      // function-typed slot have a size at all (§7.2).
      $case {$prop tag "func"} "mpl_fun",
      // §7.2: a trait object is two pointers whatever its trait — the referent and its
      // implementation's table — so one C type serves them all, as `mpl_fun` does.
      $case {$prop tag "trait"} "mpl_tobj",
      // §4.12: props have no layout, so a `with` is laid out as its base.
      $case {$prop tag "with"} {
        $decl f    $call IR.find_ty (ts, t.base)
        $decl ret2 $if f.hit ($call c_type (st, ts, f.id)) {
          $decl e    $call eerr (st, "an $impl's base type that was never interned")
          $decl ret3 "int64_t"
        }.ret3
      }.ret2,
      $case {$prop tag "array"} ($call ty_name (ts, i)),
      // §7.4: `&T` and `&mut T` are thin pointers.
      $case {$prop tag "ref"} {
        $decl f $call IR.find_ty (ts, t.inner)
        $decl ret2 $if f.hit ($call concat ($call c_type (st, ts, f.id), " *")) {
          $decl e    $call eerr (st, "a reference to a type that was never interned")
          $decl ret3 "int64_t *"
        }.ret3
      }.ret2,
      $case t ($call c_scalar (st, t))
    )
}.ret

// §8's arithmetic and comparisons, as C operators. Everything else in the root
// block needs a runtime this slice does not emit.
$decl prim_op $func ($decl n "")
  $if ($call eq_str (n, "add")) "+"
  ($if ($call eq_str (n, "sub")) "-"
  ($if ($call eq_str (n, "mul")) "*"
  ($if ($call eq_str (n, "div")) "/"
  ($if ($call eq_str (n, "mod")) "%"
  ($if ($call eq_str (n, "lt")) "<"
  ($if ($call eq_str (n, "eq_int")) "=="
  ($if ($call eq_str (n, "eq_float")) "=="
       "")))))))

// §8's unary intrinsics that are C operators: a prefix, applied to one temporary.
$decl prim_un $func ($decl n "")
  $if ($call eq_str (n, "neg")) "-"
  ($if ($call eq_str (n, "to_float")) "(double)"
       "")

// §8's arithmetic is overloaded over `Int` and `Float` (and `eq`, `to_str` and
// `to_int` over more), so the C an intrinsic call becomes depends on which candidate
// lowering chose — read off the callee's type, whose first parameter says. The
// bootstrap's monomorphic names map to themselves.
$decl prim_kind $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "func"} {
    $decl ps  $call T.tys.val (t.params)
    $decl p0  $match ps ($case {$prop tag "cons"} ($call T.tval (ps.head)), $case ps T.t_unit)
    $decl ret $if ($call T.same (p0, T.t_float)) "f" ($if ($call T.same (p0, T.t_str)) "s" "")
  }.ret,
  $case t ""
)

$decl prim_resolve $func ($decl n "", $decl k "")
  $if ($call eq_str (n, "eq"))
      ($if ($call eq_str (k, "f")) "eq_float" ($if ($call eq_str (k, "s")) "eq_str" "eq_int"))
  ($if ($call eq_str (n, "to_str")) ($if ($call eq_str (k, "f")) "float_to_str" "int_to_str")
  ($if ($call eq_str (n, "to_int")) ($if ($call eq_str (k, "f")) "float_to_int" "str_to_int")
  ($if ($call and ($call eq_str (n, "mod"), $call eq_str (k, "f"))) "fmod"
       n)))

// The wrapper an intrinsic named as a *value* points at (§7.3), by candidate — ""
// for one that has none.
$decl prim_wrap $func ($decl n "", $decl k "") {
  $decl r   $call prim_resolve (n, k)
  $decl f   $call eq_str (k, "f")
  $decl ret $if ($call eq_str (r, "eq_float")) "mpl_fnf_eq"
      ($if ($call eq_str (r, "eq_str")) "mpl_fns_eq"
      ($if ($call eq_str (r, "fmod")) "mpl_fnf_mod"
      ($if ($call eq_str (r, "float_to_str")) "mpl_fnf_to_str"
      ($if ($call eq_str (r, "int_to_str")) "mpl_fn_to_str"
      ($if ($call P.or ($call not ($call eq_str ($call prim_op (r), "")),
                     $call not ($call eq_str ($call prim_un (r), ""))))
          ($call concat ($if f "mpl_fnf_" "mpl_fn_", r))
          "")))))
}.ret

// §7.2: the layout is the `$decl` order, and props occupy no space — so the
// struct is exactly the fields, named by position rather than by their morphl
// names, which need not be C identifiers.
$decl emit_fields $func ($decl st proto_est, $decl ts T.tys.node, $decl fs T.fields.node,
                         $decl i 0) $match fs (
  $case {$prop tag "cons"} {
    $decl f $call IR.find_ty (ts, fs.head.ty)
    $decl d $call say (st, $call concat (" ",
        $call concat ($if f.hit ($call c_type (st, ts, f.id)) "int64_t",
        $call concat (" f", $call concat ($call int_to_str (i), ";")))))
    $decl ret $call emit_fields (st, ts, fs.tail, $call add (i, 1))
  }.ret,
  $case fs ()
)

$decl emit_members $func ($decl st proto_est, $decl ts T.tys.node, $decl ms T.tys.node,
                          $decl i 0) $match ms (
  $case {$prop tag "cons"} {
    $decl f $call IR.find_ty (ts, ms.head)
    $decl d $call say (st, $call concat (" ",
        $call concat ($if f.hit ($call c_type (st, ts, f.id)) "int64_t",
        $call concat (" m", $call concat ($call int_to_str (i), ";")))))
    $decl ret $call emit_members (st, ts, ms.tail, $call add (i, 1))
  }.ret,
  $case ms ()
)

$decl eval_ints $func ($decl x IR.ints.node) x

$decl mem_int $func ($decl xs IR.ints.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_int (xs.head, i)) true ($call mem_int ($call IR.ints.val (xs.tail), i)),
  $case xs false
)

$decl mem_int_e $func ($decl xs IR.ints.node, $decl i 0) $match xs (
  $case {$prop tag "cons"} $if ($call eq_int (xs.head, i)) true ($call mem_int_e (xs.tail, i)),
  $case xs false
)
// A member of a contified group has no definition of its own — the group
// function holds its body and the wrapper carries its name (§6a).
$decl in_a_group $func ($decl gs IR.groups.node, $decl i 0) $match gs (
  $case {$prop tag "cons"}
    $if ($call mem_int_e ($call IR.ints.val (gs.head.members), i)) true
        ($call in_a_group ($call IR.groups.val (gs.tail), i)),
  $case gs false
)

// Which types get a C struct of their own.
$decl is_structy $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "block"} true,
  // §8's array is a pointer and a length, like §3.1's `Str` — one struct per
  // element type, because `at` has to index it and C needs the element's size.
  $case {$prop tag "array"} true,
  // §3.2 makes `Bool` the union `true | false`, but its discriminator *is* its
  // value, so it stays an `int64_t` and gets no struct.
  $case {$prop tag "union"} ($call not ($call T.same (t, T.t_bool))),
  $case {$prop tag "rec"}   true,
  $case {$prop tag "group"} true,
  $case {$prop tag "over"}  true,
  $case t false
)

// The first index *before* `i` naming the same type, or -1.
//
// §5.5 makes `μR. B(R)` and its one-step unrolling the same type, and the
// checker treats them so — which is why a value of one is assigned to a slot
// of the other. But they are distinct *terms*, so `T.same` separates them and
// `intern` gives them two indices, and two C structs for one type is what `cc`
// refuses. The later index becomes a `typedef` of the earlier, which is the
// truth and costs nothing: `T.unroll` agreeing means the members and their
// order are identical, so every discriminator already assigned still holds.
//
// Nothing but a `μ` can match here. Two structurally identical types that are
// not one are impossible — `intern` would have returned the first — so the
// only pairs this finds are a binder and its unrolling.
// Walks the table rather than indexing it: `type_at` is `nth` on a linked
// list, so indexing from inside this loop made it O(n^3) over the table and
// the whole compiler interns about 1,500 types. The target arrives already
// unrolled for the same reason — it does not change as the walk proceeds.
$decl is_rec $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "rec"} true,
  $case t false
)

// One side of the pair must be the `μ` — a `μ` is interned *before* the members
// it embeds, so it is usually the earlier index and its unrolling the later.
// Only `rec` entries are unrolled, and the target's unrolling is computed once
// by `alias_of`: unrolling every entry on every scan would be O(n^2) calls to
// `T.unroll`, and `T.unroll` of a `rec` is a whole `remap` traversal.
// Split out of `alias_at` so that its recursion stays in **tail position**.
// §7.7 makes a call inside a block a real frame, and this walks the whole type
// table: at the whole compiler's 6,348 types the block form cost a frame per
// entry and died with `call depth limit exceeded at 8763 nested calls`, 48 MB
// into the interpreter's 64 MB stack. Nothing about the work changed — only
// where the bindings live.
$decl alias_hit $func ($decl h T.proto_ty, $decl ut T.proto_ty, $decl tr P.boolean) {
  $decl e  $call T.tval (h)
  $decl er $call is_rec (e)
  $decl ret  $if ($call and ($call is_structy (e), $if er true tr))
      ($call T.same ($if er ($call T.unroll (e)) e, ut)) false
}.ret

$decl alias_at $func ($decl xs T.tys.node, $decl ut T.proto_ty, $decl tr P.boolean,
                      $decl j 0, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call not ($call lt (j, i))) -1
        ($if ($call alias_hit (xs.head, ut, tr)) j
             ($call alias_at ($call T.tys.val (xs.tail), ut, tr,
                  $call add (j, 1), i))),
  $case xs -1
)

$decl alias_of $func ($decl all T.tys.node, $decl t T.proto_ty, $decl j 0, $decl i 0)
  $call alias_at (all, $call T.unroll (t), $call is_rec (t), j, i)

// Every struct is declared before any is defined, so a field that is a
// *pointer* to one needs nothing else — §5.5 makes every recursive edge a
// pointer, which is what keeps the definitions themselves acyclic.
// One entry's forward declaration. Split out for the same reason as
// `alias_hit`: the walk below covers the whole type table, and §7.7 makes a
// call inside a block a real frame. The two used to nest — `emit_fwds` held a
// frame per entry *and* called `alias_of`, which held another per entry — which
// is how 6,348 types became 8,763 nested calls and 48 MB of a 64 MB stack.
$decl emit_fwd1 $func ($decl st proto_est, $decl all T.tys.node, $decl t0 T.proto_ty,
                       $decl i 0) {
  $decl t $call T.tval (t0)
  $decl ret $if ($call is_structy (t)) {
    $decl k $call alias_of (all, t, 0, i)
    // An alias always names a *lower* index, so the thing it names was
    // declared on an earlier turn of this same walk.
    $decl ret2 $if ($call lt (-1, k))
        ($call say (st, $call concat ("typedef ", $call concat ($call ty_name (all, k),
             $call concat (" ", $call concat ($call ty_name (all, i), ";\n"))))))
        ($call say (st, $call concat ("typedef struct ", $call concat ($call ty_name (all, i),
             $call concat (" ", $call concat ($call ty_name (all, i), ";\n"))))))
  }.ret2
      ()
}.ret

$decl emit_fwds $func ($decl st proto_est, $decl all T.tys.node, $decl ts T.tys.node,
                       $decl i 0) $match ts (
  $case {$prop tag "cons"}
    $do ($call emit_fwd1 (st, all, ts.head, i))
        ($call emit_fwds (st, all, $call T.tys.val (ts.tail), $call add (i, 1))),
  $case ts ()
)

$decl mark_emitted $func ($decl st proto_est, $decl i 0) {
  $decl m   $set st.emitted ($call IR.ints.cons (i, st.emitted))
  $decl ret 0
}.ret

$fwd emit_struct_at

// A type this one contains *by value*, so it has to be defined first. A `ref`
// is not one: it is a pointer, and the forward declaration covers it.
$decl emit_dep_tys $func ($decl st proto_est, $decl all T.tys.node, $decl xs T.tys.node)
  $match xs (
    $case {$prop tag "cons"} {
      $decl f   $call IR.find_ty (all, xs.head)
      $decl d   $if f.hit ($call emit_struct_at (st, all, f.id)) 0
      $decl ret $call emit_dep_tys (st, all, $call T.tys.val (xs.tail))
    }.ret,
    $case xs 0
  )

$decl emit_dep_flds $func ($decl st proto_est, $decl all T.tys.node, $decl xs T.fields.node)
  $match xs (
    $case {$prop tag "cons"} {
      $decl f   $call IR.find_ty (all, xs.head.ty)
      $decl d   $if f.hit ($call emit_struct_at (st, all, f.id)) 0
      $decl ret $call emit_dep_flds (st, all, $call T.fields.val (xs.tail))
    }.ret,
    $case xs 0
  )

$decl emit_gfields $func ($decl st proto_est, $decl ts T.tys.node, $decl xs T.tys.node,
                          $decl i 0) $match xs (
  $case {$prop tag "cons"} {
    $decl f $call IR.find_ty (ts, xs.head)
    $decl d $call say (st, $call concat (" ",
        $call concat ($if f.hit ($call c_type (st, ts, f.id)) "int64_t",
        $call concat (" f", $call concat ($call int_to_str (i), ";")))))
    $decl ret $call emit_gfields (st, ts, xs.tail, $call add (i, 1))
  }.ret,
  $case xs ()
)

$decl emit_group_struct $func ($decl st proto_est, $decl all T.tys.node,
                               $decl its T.tys.node, $decl i 0) {
  $decl d $call emit_dep_tys (st, all, its)
  $decl h $call say (st, $call concat ("struct ", $call concat ($call ty_name (all, i),
               $call concat (" {", $if ($call T.tys.is_nil (its)) " char unit;" ""))))
  $decl f   $call emit_gfields (st, all, its, 0)
  $decl ret $call say (st, " };\n")
}.ret

$decl emit_block_struct $func ($decl st proto_est, $decl all T.tys.node,
                               $decl fs T.fields.node, $decl i 0) {
  $decl d $call emit_dep_flds (st, all, fs)
  $decl h $call say (st, $call concat ("struct ", $call concat ($call ty_name (all, i),
               $call concat (" {", $if ($call T.fields.is_nil (fs)) " char unit;" ""))))
  $decl f   $call emit_fields (st, all, fs, 0)
  $decl ret $call say (st, " };\n")
}.ret

// §7.5's discriminator plus the members, which is what `$match` tests and
// nothing else reads.
$decl emit_union_struct $func ($decl st proto_est, $decl all T.tys.node,
                               $decl ms T.tys.node, $decl i 0) {
  $decl d $call emit_dep_tys (st, all, ms)
  $decl h $call say (st, $call concat ("struct ", $call concat ($call ty_name (all, i),
               " { int64_t tag; union {")))
  $decl m   $call emit_members (st, all, ms, 0)
  $decl ret $call say (st, " } u; };\n")
}.ret

// §8's array: a pointer to the elements and a count. The element is *behind*
// the pointer, so — unlike a block's fields — this embeds nothing and needs
// only the element's forward declaration, which `emit_fwds` has already made.
$decl emit_array_struct $func ($decl st proto_est, $decl all T.tys.node,
                               $decl el T.proto_ty, $decl i 0) {
  $decl f  $call IR.find_ty (all, el)
  $decl et $if f.hit ($call c_type (st, all, f.id)) "int64_t"
  $decl ret  $call say (st, $call concat ("struct ", $call concat ($call ty_name (all, i),
               $call concat (" { ", $call concat (et, " *p; int64_t n; };\n")))))
}.ret

// Marked *before* the dependencies are walked, which is what stops a cycle —
// and §5.5's guardedness is why marking early cannot emit a type before
// something it embeds: every recursive edge is a pointer, so it is not an
// embedding.
$decl emit_struct_at $func ($decl st proto_est, $decl all T.tys.node, $decl i 0)
  $if ($call mem_int (st.emitted, i)) () {
    $decl t $call T.tval ($call type_at (all, i))
    $decl m $call mark_emitted (st, i)
    // An index the forward pass aliased has no struct of its own — it *is*
    // the earlier index, which still has to be defined, and may not be
    // reached any other way.
    $decl k $if ($call is_structy (t)) ($call alias_of (all, t, 0, i)) -1
    // A type still holding a §5.5 placeholder was derived in a type-only
    // position (§5.7) whose tree was discarded — it is in the table only
    // because interning is unconditional, and nothing at run time has it.
    // Skipped rather than failed on; `c_type` still refuses it if
    // something live turns out to name it.
    $decl d $if ($call lt (-1, k)) ($call emit_struct_at (st, all, k))
        ($if ($call T.has_var (t, 0)) () ($match t (
        $case {$prop tag "block"}
          ($call emit_block_struct (st, all, $call T.fields.val (t.fields), i)),
        $case {$prop tag "group"}
          ($call emit_group_struct (st, all, $call T.tys.val (t.items), i)),
        $case {$prop tag "over"}
          ($call emit_group_struct (st, all, $call T.tys.val (t.cands), i)),
        $case {$prop tag "array"}
          ($call emit_array_struct (st, all, $call T.tval (t.elem), i)),
        $case {$prop tag "union"}
          $if ($call T.same (t, T.t_bool)) ()
              ($call emit_union_struct (st, all, $call T.tys.val (t.members), i)),
        // §5.5: a `μ` is laid out as its unrolling, under its own name.
        // The unrolling's parts were interned when the `μ` was, so they
        // have names of their own to be referred to by.
        $case {$prop tag "rec"} {
          $decl u $call T.unroll (t)
          $decl ret2 $match u (
              $case {$prop tag "block"}
                ($call emit_block_struct (st, all, $call T.fields.val (u.fields), i)),
              $case {$prop tag "union"}
                ($call emit_union_struct (st, all, $call T.tys.val (u.members), i)),
              $case u ()
            )
        }.ret2,
        $case t ()
      )))
    $decl ret ()
  }.ret

$decl emit_defs $func ($decl st proto_est, $decl ts T.tys.node, $decl all T.tys.node,
                       $decl i 0) $match ts (
  $case {$prop tag "cons"}
    $do ($call emit_struct_at (st, all, i))
        ($call emit_defs (st, $call T.tys.val (ts.tail), all, $call add (i, 1))),
  $case ts ()
)

$decl emit_structs $func ($decl st proto_est, $decl ts T.tys.node, $decl all T.tys.node,
                          $decl i 0)
  $do ($call emit_fwds (st, ts, ts, 0)) ($call emit_defs (st, ts, all, 0))

$decl join_args $func ($decl xs strs.node, $decl acc "", $decl first P.boolean) $match xs (
  $case {$prop tag "cons"}
    $call join_args (xs.tail, $call concat (acc, $call concat ($if first "" ", ", xs.head)), false),
  $case xs acc
)

// `  <dest> = <rhs>;` — the shape of almost every line this backend emits.
// Deep `$call concat` nesting is how the paren counts go wrong.
$decl assign $func ($decl st proto_est, $decl dest "", $decl rhs "")
  $call say (st, $call concat ("  ", $call concat (dest,
      $call concat (" = ", $call concat (rhs, ";\n")))))

// §8's intrinsics are C functions of their own and take no environment.
$decl prim_call $func ($decl f "", $decl as strs.node)
  $call concat (f, $call concat ("(", $call concat ($call join_args (as, "", true), ")")))

// Through a closure: cast the code pointer to the signature the call site
// knows, and hand it the environment the pair carries.
// §6a: filling the pending block instead of making the call. The arguments are
// already in temporaries (`emit_args` put them there), so nothing can clobber
// anything; `mpl_tc` goes last so a partly-filled block is never live. The
// destination is assigned a zero of its own type because the caller's `return`
// will hand it back and nothing may read it — a compound literal, which is valid
// for a struct and for a machine word alike.
$decl tc_stores $func ($decl st proto_est, $decl m "", $decl as strs.node, $decl k 0) $match as (
  $case {$prop tag "cons"} {
    $decl d $call say (st, $call concat ("  ", $call concat (m,
        $call concat (".a", $call concat ($call int_to_str (k),
        $call concat (" = ", $call concat (as.head, ";\n")))))))
    $decl ret $call tc_stores (st, m, as.tail, $call add (k, 1))
  }.ret,
  $case as ()
)

$decl emit_report $func ($decl st proto_est, $decl ts T.tys.node, $decl fv "",
                         $decl as strs.node, $decl dest "", $decl cty 0, $decl rty 0) {
  $decl m  $call concat ("mpl_tc_args.s", $call int_to_str (cty))
  $decl d0 $call tc_stores (st, m, as, 0)
  $decl d1 $call say (st, $call concat ("  mpl_tc_fn = ", $call concat (fv, ";\n")))
  $decl d2 $call say (st, $call concat ("  mpl_tc_tag = ", $call concat ($call int_to_str (cty), ";\n")))
  $decl d3 $call say (st, "  mpl_tc = 1;\n")
  $decl ret  $call assign (st, dest, $call concat ("(",
               $call concat ($call c_type (st, ts, rty), "){0}")))
}.ret

$decl indirect_call $func ($decl sig "", $decl fv "", $decl as strs.node)
  $call concat ("(", $call concat (sig,
      $call concat (fv, $call concat (".code)(",
      $call concat (fv, $call concat (".env",
      $call concat ($call join_args (as, "", false), ")")))))))

// A morphl function does, even called directly: §7.3 gives every function the
// same shape so that an indirect call can supply its own.
$decl call_expr $func ($decl f "", $decl as strs.node)
  $call concat (f, $call concat ("(NULL", $call concat ($call join_args (as, "", false), ")")))

$decl prim_fn $func ($decl n "")
  $if ($call eq_str (n, "concat"))     "mpl_concat"
  ($if ($call eq_str (n, "eq_str"))    "mpl_str_eq"
  ($if ($call eq_str (n, "len"))       "mpl_len"
  ($if ($call eq_str (n, "slice"))     "mpl_slice"
  ($if ($call eq_str (n, "byte"))      "mpl_byte"
  ($if ($call eq_str (n, "int_to_str")) "mpl_int_to_str"
  ($if ($call eq_str (n, "float_to_str")) "mpl_float_to_str"
  ($if ($call eq_str (n, "fmod"))      "mpl_fmod"
  ($if ($call eq_str (n, "print"))     "mpl_print"
  ($if ($call eq_str (n, "eprint"))    "mpl_eprint"
  ($if ($call eq_str (n, "panic"))     "mpl_panic_str"
       ""))))))))))

// A morphl `Str` is bytes, not a C string: it may hold a NUL, a quote or a
// newline, and it is not terminated. Every byte goes out as a three-digit
// octal escape — `\x` would be wrong, because C lets a hex escape run on into
// the next character if that happens to be a hex digit.
$decl oct3 $func ($decl b 0)
  $call concat ("\\", $call concat ($call int_to_str ($call div (b, 64)),
      $call concat ($call int_to_str ($call mod ($call div (b, 8), 8)),
                    $call int_to_str ($call mod (b, 8)))))

// Collected and joined in pairs (`join_all`), never appended: a left fold over `concat`
// copies O(L n) for an L-byte literal, and the runtime's own text is one, so this was
// 116 MB of a self-emit's 2.5 GB (PERF.md).
$decl c_bytes $func ($decl s "", $decl i 0, $decl acc strs.node)
  $if ($call not ($call lt (i, $call len (s))))
      ($call join_all ($call strs.reverse (acc, strs.nil)))
      ($call c_bytes (s, $call add (i, 1), $call strs.cons ($call oct3 ($call byte (s, i)), acc)))

$decl c_str_lit $func ($decl s "")
  $call concat ("(mpl_str){\"", $call concat ($call c_bytes (s, 0, strs.nil),
      $call concat ("\", ", $call concat ($call int_to_str ($call len (s)), "}"))))

// ------------------------------------------------------------- expressions

$fwd emit_expr

// Declare a temporary of the right type and emit `e` into it. Typed, because a
// reference is a pointer and a block is a struct — `int64_t` stopped being the
// answer two slices ago.
// §7.4: using a value where a supertype is expected costs a copy, and when the
// supertype is a union that copy is §7.5's discriminated value. Lowering leaves
// this to the backend, which has both types in the tree.
$decl member_index $func ($decl ms T.tys.node, $decl t T.proto_ty, $decl i 0) $match ms (
  $case {$prop tag "cons"}
    $if ($call T.same (ms.head, t)) i ($call member_index (ms.tail, t, $call add (i, 1))),
  $case ms -1
)

// The member a value *belongs in* when no member is exactly its type. §7.4
// coerces a value of type `S` into the member `S` is a subtype of — §5.1 makes
// a block a subtype of a longer prefix of itself, so the two need not be
// equal. First fit, in the union's own order (§4.7).
$decl member_sub_index $func ($decl ms T.tys.node, $decl t T.proto_ty, $decl i 0) $match ms (
  $case {$prop tag "cons"}
    $if ($call T.sub (t, ms.head)) i ($call member_sub_index (ms.tail, t, $call add (i, 1))),
  $case ms -1
)

$decl member_slot $func ($decl ms T.tys.node, $decl t T.proto_ty) {
  $decl k   $call member_index (ms, t, 0)
  $decl ret $if ($call lt (k, 0)) ($call member_sub_index (ms, t, 0)) k
}.ret

$decl block_is $func ($decl t0 T.proto_ty) {
  $decl t   $call T.unroll (t0)
  $decl ret $match t ($case {$prop tag "block"} true, $case t false)
}.ret

$decl block_fields $func ($decl t0 T.proto_ty) {
  $decl t $call T.unroll (t0)
  $decl ret $match t (
      $case {$prop tag "block"} ($call T.fields.val (t.fields)),
      $case t T.fields.nil
    )
}.ret

// A union's members, after §5.5's unrolling. Empty when the type is not one.
$decl union_members $func ($decl t0 T.proto_ty) {
  $decl t $call T.unroll (t0)
  $decl ret $match t (
      $case {$prop tag "union"} ($call T.tys.val (t.members)),
      $case t T.tys.nil
    )
}.ret

// The function-pointer type a call through a closure is cast to. §7.3 gives
// every function the same value shape, so the signature has to come from the
// static type at the call site — which is exactly what it is for.
$decl sig_params $func ($decl st proto_est, $decl ts T.tys.node, $decl ps T.tys.node,
                        $decl acc "") $match ps (
  $case {$prop tag "cons"} {
    $decl f $call IR.find_ty (ts, ps.head)
    $decl ret $call sig_params (st, ts, $call T.tys.val (ps.tail),
                $call concat (acc, $call concat (", ",
                    $if f.hit ($call c_type (st, ts, f.id)) "int64_t")))
  }.ret,
  $case ps acc
)

$decl fn_sig $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0) {
  $decl t $call type_at (ts, i)
  $decl ret $match t (
      $case {$prop tag "func"} {
        $decl rf $call IR.find_ty (ts, t.result)
        $decl ret2  $call concat ("(", $call concat (
            $if rf.hit ($call c_type (st, ts, rf.id)) "int64_t",
            $call concat ("(*)(void *",
            $call concat ($call sig_params (st, ts, $call T.tys.val (t.params), ""),
                          "))"))))
      }.ret2,
      $case t "(int64_t(*)(void *))"
    )
}.ret

// §7.4, where both sides are unions: `<A,B>` used where `<A,B,C>` is expected.
// The two agree on the *members* and disagree on the positions — §3.6 makes a
// union a set, so nothing fixes an order across two of them — and §7.5 makes
// the position the discriminator. So the coercion is a re-tag: one `case` per
// source member, writing the target's discriminator and moving the payload
// across.
//
// `boolish` is §3.2's exception. `Bool` is the union `true | false` but its
// discriminator *is* its value, so there is no `.tag` to read and no payload
// to move — its members are nullary tags, whose structs are empty.
$fwd emit_inject

$decl emit_retag_arms $func ($decl st proto_est, $decl ts T.tys.node, $decl dest "",
                             $decl src     "",
                             $decl fs      T.tys.node, $decl ws T.tys.node, $decl i 0,
                             $decl boolish P.boolean, $decl wt T.proto_ty) $match fs (
  $case {$prop tag "cons"} {
    $decl k  $call member_slot (ws, fs.head)
    // A source member that *is* the target — §3.6 cannot flatten a union
    // hidden behind a `μ`, so `<μ, X>` really can arrive with the whole
    // recursive type as one of its members. That case has the target's
    // layout already: the payload is moved across whole, with no tag to
    // rewrite, because it carries its own.
    $decl whole $call T.same (fs.head, wt)
    $decl d0 $call say (st, $call concat ("  case ",
                 $call concat ($call int_to_str (i), ":\n")))
    $decl d1 $if whole
        ($call assign (st, dest,
             $call concat (src, $call concat (".u.m", $call int_to_str (i)))))
    ($if ($call lt (k, 0))
        ($call eerr (st, $call concat ("no member of ", $call concat ($call T.show (wt),
             $call concat (" accepts ", $call T.show (fs.head)))))) {
          $decl a $call assign (st, $call concat (dest, ".tag"), $call int_to_str (k))
          // The payload is not always a plain move: `member_slot` finds a
          // member by `T.same` and *then* by `T.sub`, so the target member
          // can be a §5.1 prefix of the source's — which is §7.4's copy, not
          // an assignment. Going through `emit_inject` costs nothing when
          // the two are the same type, since that is its free case.
          $decl fi0 $call IR.find_ty (ts, fs.head)
          $decl wi0 $call IR.find_ty (ts, $call T.tys.nth (ws, k))
          $decl b $if boolish 0
              ($if ($call and (fi0.hit, wi0.hit))
                  ($call emit_inject (st, ts, $call concat (dest,
                       $call concat (".u.m", $call int_to_str (k))),
                       $call concat (src, $call concat (".u.m", $call int_to_str (i))),
                       fi0.id, wi0.id))
                  ($call assign (st, $call concat (dest,
                       $call concat (".u.m", $call int_to_str (k))),
                       $call concat (src, $call concat (".u.m", $call int_to_str (i))))))
          $decl ret2 0
        }.ret2)
    $decl d2 $call say (st, "  break;\n")
    $decl ret  $call emit_retag_arms (st, ts, dest, src, $call T.tys.val (fs.tail), ws,
                 $call add (i, 1), boolish, wt)
  }.ret,
  $case fs ()
)

$decl emit_retag $func ($decl st proto_est, $decl ts T.tys.node, $decl dest "",
                        $decl src "",
                        $decl ft  T.proto_ty, $decl fs T.tys.node, $decl ws T.tys.node,
                        $decl wt  T.proto_ty) {
  $decl bl $call T.same (ft, T.t_bool)
  $decl d0 $call say (st, $call concat ("  switch ((int)",
               $call concat (src, $if bl ") {\n" ".tag) {\n")))
  $decl d1 $call emit_retag_arms (st, ts, dest, src, fs, ws, 0, bl, wt)
  // The source's tag is always one of its own members, so this is as
  // unreachable as §5.6 makes a `$match`'s default.
  $decl d2  $call say (st, "  default: mpl_panic(\"bad discriminator\");\n  }\n")
  $decl ret ()
}.ret

// §5.1 again: a block's fields are an ordered prefix, so `S <: T` when `T`'s
// fields are `S`'s first fields — and §7.4 makes coercing a *value* that way a
// **copy**, field by field, because the target struct is shorter and nothing
// scatters. (Coercing a *reference* costs nothing and produces no node at all,
// which is why this only ever runs on values.)
//
// `thru` is how the source is reached. A union whose members all share the
// prefix has it in common (§5.1), and C guarantees a common initial sequence
// is readable through any member of a union of structs — so the first member
// serves, exactly as it does for a projection.
$decl emit_prefix_copy $func ($decl st proto_est, $decl dest "", $decl src "",
                              $decl thru "", $decl n 0, $decl i 0)
  $if ($call not ($call lt (i, n))) ()
      $do ($call assign (st, $call concat (dest, $call concat (".f", $call int_to_str (i))),
               $call concat (src, $call concat (thru,
                   $call concat (".f", $call int_to_str (i))))))
          ($call emit_prefix_copy (st, dest, src, thru, n, $call add (i, 1)))

// How to reach a block's fields from a value of this type: directly when it is
// a block, through the first member when it is a union of blocks sharing the
// prefix. Empty means there is no such reading.
$decl prefix_thru $func ($decl t0 T.proto_ty) {
  $decl t $call T.unroll (t0)
  $decl ret $match t (
      $case {$prop tag "block"} "b",
      $case {$prop tag "union"} $if ($call T.same (t, T.t_bool)) "" "u",
      $case t ""
    )
}.ret

// Rendering a type is what a diagnostic costs, and §7.1 makes morphl strict —
// so a message bound with `$decl` is built on *every* call, not only the ones
// that report. `emit_inject` runs at every coercion, and building this one
// eagerly put `T.show` at 438,239 calls and 21% of an emit that reports
// nothing at all. Behind a `$func` it is built only when it is used.
$decl coerce_err $func ($decl st proto_est, $decl ft T.proto_ty, $decl wt T.proto_ty)
  $call eerr (st, $call concat ("cannot coerce ", $call concat ($call T.show (ft),
      $call concat (" to ", $call T.show (wt)))))

$decl emit_inject $func ($decl st proto_est, $decl ts T.tys.node, $decl dest "",
                         $decl src "", $decl from 0, $decl want 0) {
  $decl wt $call type_at (ts, want)
  $decl ft $call type_at (ts, from)
  // §7.4: one C shape either way and the coercion is nothing — a change of
  // reference qualifier, or a member of `Bool`, whose discriminator is its
  // own value (§3.2).
  $decl free $call eq_str ($call c_type (st, ts, from), $call c_type (st, ts, want))
  // §5.5: a `μ` is laid out as its unrolling, so the members a value can be
  // injected into are the unrolling's — the discriminator is the member's
  // position there, which is also the order `emit_union_struct` wrote them
  // in.
  $decl ws $call union_members (wt)
  // A union on the *left* is a re-tag, not an injection: its value is
  // already discriminated, just against a different set of positions.
  $decl fs $if free T.tys.nil ($call union_members (ft))
  $decl k  $if free -1 ($call member_slot (ws, ft))
  // §7.8 again: coercing *from* ⊥ is coercing something that never arrives.
  // The code is unreachable — `mpl_panic` does not return — so there is
  // nothing to write and nothing to complain about.
  $decl from_bot $call T.same (ft, T.t_bot)
  // A *block* on the right is §7.4's prefix copy, whichever shape the source
  // is — and it has to be tested before the union cases, since a union on the
  // left is a re-tag only when the target is a union too.
  $decl wf  $call block_fields (wt)
  $decl how $if ($call block_is (wt)) ($call prefix_thru (ft)) ""
  $decl ret $if free ($call assign (st, dest, src))
      ($if from_bot ()
      ($if ($call not ($call eq_str (how, "")))
           ($call emit_prefix_copy (st, dest, src, $if ($call eq_str (how, "u")) ".u.m0" "",
                $call T.fields.length (wf, 0), 0))
      ($if ($call not ($call T.tys.is_nil (fs)))
           ($if ($call T.tys.is_nil (ws)) ($call coerce_err (st, ft, wt))
                ($call emit_retag (st, ts, dest, src, ft, fs, ws, wt)))
      ($if ($call lt (k, 0)) ($call coerce_err (st, ft, wt)) {
        $decl a  $call assign (st, $call concat (dest, ".tag"), $call int_to_str (k))
        // The payload is not always a plain move. `member_slot` finds a
        // member by `T.same` and *then* by `T.sub`, so the member chosen
        // can be a §5.1 prefix of what is being injected — and §7.4 makes
        // that a copy. Guarded on the two being different types, which is
        // also what stops this recurring on itself.
        $decl wk $call IR.find_ty (ts, $call T.tys.nth (ws, k))
        $decl ret2  $if ($call and (wk.hit, $call not ($call eq_int (wk.id, from))))
            ($call emit_inject (st, ts, $call concat (dest,
                 $call concat (".u.m", $call int_to_str (k))), src, from, wk.id))
            ($call assign (st, $call concat (dest,
                 $call concat (".u.m", $call int_to_str (k))), src))
      }.ret2))))
}.ret

// Emit `e` into `dest`, injecting into a union first if `e` is a member of one
// — which is where subsumption shows up, at an `$if` or `$match` arm.
$decl emit_as $func ($decl st proto_est, $decl fi 0, $decl e IR.proto_expr,
                     $decl dest "", $decl want 0, $decl ts T.tys.node)
  $if ($call eq_int (e.ty, want)) ($call emit_expr (st, fi, e, dest, ts)) {
    $decl tv $call fresh_tmp (st)
    $decl d0 $call say (st, $call concat ("  ", $call concat ($call c_type (st, ts, e.ty),
                 $call concat (" ", $call concat (tv, ";\n")))))
    $decl d1  $call emit_expr (st, fi, e, tv, ts)
    $decl ret $call emit_inject (st, ts, dest, tv, e.ty, want)
  }.ret

// The interned index of what a `&T` points at, or -1.
//
// §4.2 types storage from its operand, but the *node's* type is regularly
// wider: §4.8a makes a `$union` evaluate to its first member while carrying
// the whole union's type, and §5.1 makes a block a subtype of a shorter prefix
// of itself. So storage has to be sized and typed from the node and the
// operand coerced into it — sizing it from the operand emits a `mpl_tA *` into
// a `mpl_tB *`, which is what `cc` refused.
$decl pointee_of $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0) {
  $decl t $call T.unroll ($call type_at (ts, i))
  $decl ret $match t (
      $case {$prop tag "ref"} {
        $decl f    $call IR.find_ty (ts, t.inner)
        $decl ret2 $if f.hit f.id -1
      }.ret2,
      $case t -1
    )
}.ret

// A declared temporary of a *given* type, where `into_tmp` gives one of the
// expression's own type.
$decl decl_tmp $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0) {
  $decl tv $call fresh_tmp (st)
  $decl d0 $call say (st, $call concat ("  ", $call concat ($call c_type (st, ts, i),
               $call concat (" ", $call concat (tv, ";\n")))))
  $decl ret  tv
}.ret

$decl into_tmp $func ($decl st proto_est, $decl fi 0, $decl e IR.proto_expr, $decl ts T.tys.node) {
  $decl tv $call fresh_tmp (st)
  $decl d0 $call say (st, $call concat ("  ", $call concat ($call c_type (st, ts, e.ty),
               $call concat (" ", $call concat (tv, ";\n")))))
  $decl d1  $call emit_expr (st, fi, e, tv, ts)
  $decl ret tv
}.ret

// Each argument into its own temporary, left to right (§7.1), so the caller can
// use them all at once — which is what a parallel parameter update needs.
// Each argument into its own temporary, left to right (§7.1), so the caller can
// use them all at once — which is what a parallel parameter update needs.
//
// The temporary has the *parameter's* type, not the argument's: passing a
// member where a union is expected is subsumption, and §7.4 makes that a copy —
// here, §7.5's discriminated value. The callee's own type carries the parameter
// types, so nothing else has to be threaded in.
$decl emit_args $func ($decl st proto_est, $decl fi 0, $decl xs IR.exprs.node,
                       $decl ps T.tys.node, $decl ts T.tys.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"} {
    $decl want $match ps (
        $case {$prop tag "cons"} {
          $decl f    $call IR.find_ty (ts, ps.head)
          $decl ret2 $if f.hit f.id xs.head.ty
        }.ret2,
        $case ps xs.head.ty
      )
    $decl tv $call fresh_tmp (st)
    $decl d1 $call say (st, $call concat ("  ", $call concat ($call c_type (st, ts, want),
                 $call concat (" ", $call concat (tv, ";\n")))))
    $decl d2   $call emit_as (st, fi, xs.head, tv, want, ts)
    $decl rest $match ps ($case {$prop tag "cons"} ($call T.tys.val (ps.tail)), $case ps T.tys.nil)
    $decl ret  $call emit_args (st, fi, $call IR.exprs.val (xs.tail), rest, ts,
                 $call strs.cons (tv, acc))
  }.ret,
  $case xs ($call strs.reverse (acc, strs.nil))
)

// Every operator in `prim_op` is binary, so the two temporaries go either side
// of it — `join_args` is for an argument list, which this is not.
$decl binop_expr $func ($decl xs strs.node, $decl op "")
  $call concat ("(", $call concat ($call strs.nth (xs, 0),
      $call concat (" ", $call concat (op,
      $call concat (" ", $call concat ($call strs.nth (xs, 1), ")"))))))

// A self tail call (§6a): every argument is already in a temporary, so the
// slots can be overwritten in one go and the loop re-entered.
// §6a's parameter update. `pre` is what a parameter is called where the tail
// call stands: the shared slots on the fast path, and the target member's own
// parameter variables in a general group, where no two members share a name.
$decl assign_slots $func ($decl st proto_est, $decl xs strs.node, $decl i 0,
                          $decl pre "s") $match xs (
  $case {$prop tag "cons"} {
    $decl d $call say (st, $call concat ("  ", $call concat (pre,
        $call concat ($call int_to_str (i),
        $call concat (" = ", $call concat (xs.head, ";\n"))))))
    $decl ret $call assign_slots (st, xs.tail, $call add (i, 1), pre)
  }.ret,
  $case xs ()
)

// §6a's cheap case: the callee is this very function. The mutual case asks the
// same question of the whole group — the answer is which state to jump to.
$decl state_of $func ($decl g IR.ints.node, $decl f 0, $decl i 0) $match g (
  $case {$prop tag "cons"}
    $if ($call eq_int (g.head, f)) i ($call state_of (g.tail, f, $call add (i, 1))),
  $case g -1
)

$decl is_thunk $func ($decl st proto_est, $decl i 0)
  $call mem_int (st.thunks, i)

$decl thunk_ids $func ($decl fs IR.fns.node, $decl i 0, $decl acc IR.ints.node) $match fs (
  $case {$prop tag "cons"}
    $call thunk_ids ($call IR.fns.val (fs.tail), $call add (i, 1),
        $if fs.head.thunk ($call IR.ints.cons (i, acc)) acc),
  $case fs acc
)

// An **alias is a thunk whose whole body is one `global`**, and resolving it is
// what §6a's indirect case mostly consists of in practice.
//
// `$decl not P.not` and `$decl isub sub` — the idiom CLAUDE.md prescribes for
// keeping an intrinsic a file shadows — are top-level `$decl`s that are not
// `$func`s, so they lower to thunks (§7.3: a thunk's index names a *static*, not
// something to call). A call through one is therefore a call through a function
// *value*, which §6a cannot turn into a loop because the target is unknown until
// run time. Except that here it is not unknown at all: the static is assigned
// once from a `global` naming a real function, so the callee is a compile-time
// constant and the call can be direct.
//
// Every one of the fifteen indirect tail calls in the compiler's own emitted C
// was this — `not`, `and`, `or` and `isub` — and none of them was a genuinely
// dynamic target. Resolving them makes §7.7 hold for all of them and turns the
// most-called helpers in the codebase into direct calls.
//
// This lives in the backend rather than in the tree, which is deliberate: §6a is
// an obligation on emit, the whole function table is right here to derive it
// from, and nothing about the tree changes — so `verify` still checks what
// lowering built and no node gains a second index (§9.3).
// An alias's body is one node, and there are two kinds worth resolving: a
// `global`, which names another function, and a **`prim`**, which names an §8
// intrinsic. `$decl isub sub` is the second — it is the idiom for keeping an
// operator a file shadows, and §8's operators are emitted *infix* when called,
// so resolving it turns the call back into `a - b` rather than a call at all.
// That was the fifteenth of the fifteen, and the one an alias-of-a-function test
// alone does not catch.
$decl alias_of_body $func ($decl i 0, $decl e IR.proto_expr) $match e (
  $case {$prop tag "global"} ($call fnal (i, e.fn, "", "")),
  $case {$prop tag "prim"} ($call fnal (i, -1, e.name, "")),
  // §4.16: the idiomatic binding is `$decl puts $extern "puts" sig` at top level,
  // which is a thunk whose whole body is one extern node — so calling it by name
  // resolves to a direct C call, exactly as an aliased intrinsic does.
  $case {$prop tag "extern"} ($call fnal (i, -1, "", e.sym)),
  $case e ($call fnal (i, -1, "", ""))
)

$decl is_alias $func ($decl a proto_fnal)
  $if ($call lt (-1, a.to)) true
      ($if ($call not ($call eq_str (a.prim, ""))) true
           ($call not ($call eq_str (a.xsym, ""))))

$decl collect_aliases $func ($decl fs IR.fns.node, $decl i 0, $decl acc fnals.node) $match fs (
  $case {$prop tag "cons"} {
    $decl a $if fs.head.thunk ($call alias_of_body (i, $call IR.eval (fs.head.body)))
                              ($call fnal (i, -1, "", ""))
    $decl ret $call collect_aliases ($call IR.fns.val (fs.tail), $call add (i, 1),
                $if ($call is_alias (a)) ($call fnals.cons (a, acc)) acc)
  }.ret,
  $case fs acc
)

$decl fnal_at $func ($decl as fnals.node, $decl i 0) $match as (
  $case {$prop tag "cons"}
    $if ($call eq_int (as.head.from, i)) as.head ($call fnal_at (as.tail, i)),
  $case as ($call fnal (i, -1, "", ""))
)

// An alias may name an alias, so follow the chain as far as it goes and answer
// the index it ends at. Bounded by the number of aliases, because nothing here
// rules out a cycle and a compiler must not hang on one; running out of budget
// stops where it is, which resolves to "not an alias" below.
$decl chase_alias $func ($decl as fnals.node, $decl i 0, $decl n 0)
  $if ($call lt (n, 1)) i {
    $decl t   $call fnal_at (as, i)
    $decl ret $if ($call lt (t.to, 0)) i ($call chase_alias (as, t.to, $call sub (n, 1)))
  }.ret

$decl end_of_alias $func ($decl st proto_est, $decl i 0) {
  $decl as  $call fnals.val (st.aliases)
  $decl ret $call chase_alias (as, i, $call fnals.length (as, 0))
}.ret

// The index a global callee really names: itself when it is an ordinary
// function, the end of the alias chain when it is one, and -1 when it is a thunk
// this cannot see through — a static holding a function value computed at run
// time, which is §6a's genuinely indirect case.
$decl res_fn $func ($decl st proto_est, $decl i 0)
  $if ($call not ($call is_thunk (st, i))) i {
    $decl j   $call end_of_alias (st, i)
    $decl ret $if ($call is_thunk (st, j)) -1 j
  }.ret

// The intrinsic a global callee names, if it aliases one.
$decl alias_prim $func ($decl st proto_est, $decl i 0)
  $if ($call not ($call is_thunk (st, i))) "" {
    $decl as  $call fnals.val (st.aliases)
    $decl a   $call fnal_at (as, $call end_of_alias (st, i))
    $decl ret $call P.sval (a.prim)
  }.ret

// The intrinsic a callee names, directly or through an alias — "" when it names none.
// A `global` is a thunk whose whole body is a `prim`, which is what `$decl isub sub`
// lowers to; a `field` of one is that alias's candidate, chosen at an overloaded
// intrinsic (§4.8). Either way the callee is a compile-time constant, so §8 emits it
// exactly as a direct call.
$decl callee_prim $func ($decl st proto_est, $decl c IR.proto_expr) $match c (
  $case {$prop tag "prim"} c.name,
  $case {$prop tag "global"} ($call alias_prim (st, c.fn)),
  $case {$prop tag "field"} {
    $decl t   $call IR.eval (c.target)
    $decl ret $match t ($case {$prop tag "global"} ($call alias_prim (st, t.fn)), $case t "")
  }.ret,
  $case c ""
)

// And the C symbol, if it aliases a §4.16 extern.
$decl alias_xsym $func ($decl st proto_est, $decl i 0)
  $if ($call not ($call is_thunk (st, i))) "" {
    $decl as  $call fnals.val (st.aliases)
    $decl a   $call fnal_at (as, $call end_of_alias (st, i))
    $decl ret $call P.sval (a.xsym)
  }.ret

// An alias resolves to its target here too, so a tail call through one gets the
// same treatment its target would: the group's state if the target is a member,
// and otherwise a direct call.
//
// **The `-2` test deliberately asks about the *unresolved* callee.** `-2` means
// "this very function", which makes emit write `continue` — and the `while (1)`
// around it is there only if lowering set `self_tail`, which it decided from the
// tree, where the callee is still the alias. So resolving in the `-2` test would
// be emit contradicting the tree, and the result would be a `continue` outside
// any loop. As it happens that cannot arise — §4.10 makes an alias strictly
// later than its target and a body can only name what precedes it, so a call
// through an alias never reaches the function it sits in, and the checker
// rejects both ways of trying — but the agreement is free here and `verify`
// cannot see a disagreement between the tree and the C.
//
// The *group* case is safe resolved: if the target is a member then this code is
// inside that group's function and its dispatch loop exists, and if it is not
// then `st.grp` is nil and `state_of` answers -1.
$decl tail_state $func ($decl st proto_est, $decl c IR.proto_expr, $decl fi 0) $match c (
  $case {$prop tag "global"} {
    $decl fn $call res_fn (st, c.fn)
    $decl g  $if ($call lt (fn, 0)) IR.ints.nil ($call IR.ints.val (st.grp))
    $decl s  $call state_of (g, fn, 0)
    // -1: not a loop at all. -2: this very function, so the state does not
    // change. Otherwise the state to jump to.
    $decl ret $if ($call eq_int (s, -1)) ($if ($call eq_int (c.fn, fi)) -2 -1) s
  }.ret,
  $case c -1
)

// A call to a global is direct only when that global is a *function*. A
// top-level `$decl` that is not a `$func` — `$decl and P.and`, an alias — is a
// thunk, and its index names the static, not something to call. Calling it is
// an indirect call through the function value that static holds (§7.3), which
// is the branch below.
$decl is_global $func ($decl st proto_est, $decl c IR.proto_expr) $match c (
  $case {$prop tag "global"} ($call lt (-1, $call res_fn (st, c.fn))),
  $case c false
)

$decl callee_name $func ($decl st proto_est, $decl c IR.proto_expr) $match c (
  $case {$prop tag "global"} ($call fn_name (st, $call res_fn (st, c.fn))),
  $case c "0"
)

// --------------------------------------------------------------- §4.16 externs
//
// `$extern "symbol" sig` binds a C function, and §4.16's ABI mapping is a
// function of the signature alone — a block is a struct in `$decl` order, `&T` is
// a thin pointer, `Int` is `int64_t`, `Str` is pointer + length — which `c_type`
// already implements for every other purpose. So the backend needs two things
// from a program: the declarations to emit, and a wrapper for each symbol that is
// used as a *value* rather than called.
//
// The wrapper is the same device §8's operators need. A C function has no
// `void *env` first parameter, and §7.3 makes a function value a pair, so a
// symbol used as a value has to point at something with morphl's calling
// convention. `mpl_fn_sub` is the precedent; these are generated per symbol
// because their signatures come from the program.
//
// Both need the whole set before any body is emitted, which is why this walks the
// tree. It is the one full traversal in the backend: everything else emit needs
// it reads off `IR.fn` or the type table.
// §4.16's ABI mapping differs from §7.2's layout in exactly one place, and the
// section does not say so: it lists blocks, `&T`, `Int`, `Float`, `Str` and
// `array`, and omits **functions**. §7.3 makes a morphl function value two words,
// a code pointer and an environment, and C wants one pointer — so rendering a
// function-typed parameter with `c_type` declared `extern int64_t host_apply
// (mpl_fun, int64_t);` against a host `int64_t host_apply(int64_t (*)(int64_t),
// int64_t)`. That links (C has no mangling) and miscompiles: on SysV the pair
// takes two registers, so every later argument is read from the wrong one. It
// answered 1000 where 1042 was correct, silently.
//
// So a function crossing to C is its **code pointer alone**, which is exactly why
// §4.16 rule 2 requires the captured set to be empty — a closure's code pointer
// without its environment is meaningless. `emit_ffi_arg` and the rule in
// `infer.mpl` are two halves of one thing.
// §4.16's ABI mapping names blocks, `&T`, `Int`, `Float`, `Str` and `array`, and
// says nothing about a **function**. It has to: §7.3 makes a morphl function value
// a two-word pair, which occupies two argument registers, so declaring a callback
// parameter as the pair puts every argument after it in the wrong register — a
// silent miscompile, not a `cc` error, since the pair is a perfectly good struct.
// What crosses is the *code pointer alone*, and §4.16 rule 2 — a callback may not
// capture — is exactly what makes dropping the environment word sound.
//
// The C type is spelt through a **typedef** rather than inline. A function-pointer
// type in C is a declarator and not a type name: as a parameter `int64_t (*)(int64_t)`
// works, but as a *result* the declarator wraps itself around the function's own
// name (`int64_t (*host_pick(void))(int64_t)`), which no `concat` of a type and a
// name can produce. One `typedef` per function type makes every FFI position a
// plain identifier and the problem disappears.
$decl fp_name $func ($decl i 0) $call concat ("mpl_fp", $call int_to_str (i))

// A C function pointer cannot be §7.3's `code`: every morphl function takes
// `void *env` first, and a C one does not, so calling it through the pair shifts
// every argument by a register. The pair points at a generated **adapter**
// instead and carries the C pointer as its *environment* — which is exactly what
// the environment word is for, and needs no allocation because a C function
// pointer is one word.
$decl fpw_name $func ($decl i 0) $call concat ("mpl_fpw", $call int_to_str (i))

$decl c_type_ffi $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0) {
  $decl t $call type_at (ts, i)
  $decl ret $match t (
      $case {$prop tag "func"} ($call fp_name (i)),
      $case t ($call c_type (st, ts, i))
    )
}.ret

$decl ffi_params $func ($decl st proto_est, $decl ts T.tys.node, $decl ps T.tys.node,
                        $decl acc "", $decl first P.boolean) $match ps (
  $case {$prop tag "cons"} {
    $decl f $call IR.find_ty (ts, ps.head)
    $decl ret $call ffi_params (st, ts, ps.tail,
                $call concat (acc, $call concat ($if first "" ", ",
                    $if f.hit ($call c_type_ffi (st, ts, f.id)) "int64_t")), false)
  }.ret,
  $case ps acc
)

// Resolving a parameter *type value* to its interned index, tolerating a list
// that has run out — §3.4 fixes a parameter's type, not its presence.
$decl ps_id $func ($decl ts T.tys.node, $decl ps T.tys.node) $match ps (
  $case {$prop tag "cons"} {
    $decl f   $call IR.find_ty (ts, ps.head)
    $decl ret $if f.hit f.id -1
  }.ret,
  $case ps -1
)

$decl ps_rest $func ($decl ps T.tys.node) $match ps (
  $case {$prop tag "cons"} ($call T.tys.val (ps.tail)),
  $case ps T.tys.nil
)

$decl is_func_ty $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0) {
  $decl t   $call type_at (ts, i)
  $decl ret $match t ($case {$prop tag "func"} true, $case t false)
}.ret

// One argument on its way to C. Everything but a function crosses as itself;
// a function crosses as its **code pointer**, cast to the signature §4.16 gives
// it, because C has no place to put §7.3's environment word. §4.16 rule 2 is what
// makes discarding it sound — an empty captured set means there is nothing in it.
$decl ffi_one $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0, $decl a "")
  $if ($call lt (i, 0)) a
      ($if ($call is_func_ty (st, ts, i))
           ($call concat ("(", $call concat ($call c_type_ffi (st, ts, i),
               $call concat (")", $call concat (a, ".code")))))
           a)

// The other direction: a C function *returned* has no environment, so §7.3's pair
// is the pointer and a NULL env. §4.16 rule 2 is symmetric here — a C function
// cannot capture, so there is nothing the missing word could have held.
$decl ffi_ret $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0,
                     $decl dest "", $decl rhs "")
  $if ($call is_func_ty (st, ts, i)) {
    $decl d0 $call say (st, $call concat ("  ", $call concat (dest,
                 $call concat (".code = (void *)", $call concat ($call fpw_name (i), ";\n")))))
    $decl ret $call assign (st, $call concat (dest, ".env"),
                 $call concat ("(void *)", rhs))
  }.ret
      ($call assign (st, dest, rhs))

$decl ffi_args $func ($decl st proto_est, $decl ts T.tys.node, $decl ps T.tys.node,
                      $decl as strs.node, $decl acc "", $decl first P.boolean) $match as (
  $case {$prop tag "cons"} {
    $decl one $call ffi_one (st, ts, $call ps_id (ts, ps), as.head)
    $decl ret $call ffi_args (st, ts, $call ps_rest (ps), as.tail,
                $call concat (acc, $call concat ($if first "" ", ", one)), false)
  }.ret,
  $case as acc
)

// The same for the generated wrapper, whose parameters are `x0`, `x1`, … and whose
// own signature stays morphl-side because morphl is what calls it.
$decl ffi_wargs $func ($decl st proto_est, $decl ts T.tys.node, $decl ps T.tys.node,
                       $decl k 0, $decl acc "", $decl first P.boolean) $match ps (
  $case {$prop tag "cons"} {
    $decl one $call ffi_one (st, ts, $call ps_id (ts, ps),
                  $call concat ("x", $call int_to_str (k)))
    $decl ret $call ffi_wargs (st, ts, $call ps_rest (ps), $call add (k, 1),
                $call concat (acc, $call concat ($if first "" ", ", one)), false)
  }.ret,
  $case ps acc
)

$decl xt       $func ($decl y "", $decl t 0) { $decl sym y  $decl ty t }
$decl proto_xt $call xt ("", 0)
$decl xts      $specialize P.list proto_xt

$decl has_xt $func ($decl xs xts.node, $decl y "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.sym, y)) true ($call has_xt (xs.tail, y)),
  $case xs false
)

$fwd xt_of

$decl xt_of_list $func ($decl xs IR.exprs.node, $decl acc xts.node) $match xs (
  $case {$prop tag "cons"}
    $call xt_of_list ($call IR.exprs.val (xs.tail), $call xt_of (xs.head, acc)),
  $case xs acc
)

$decl xt_of_slots $func ($decl xs IR.bslots.node, $decl acc xts.node) $match xs (
  $case {$prop tag "cons"}
    $call xt_of_slots ($call IR.bslots.val (xs.tail), $call xt_of (xs.head.init, acc)),
  $case xs acc
)

$decl xt_of_arms $func ($decl xs IR.arms.node, $decl acc xts.node) $match xs (
  $case {$prop tag "cons"}
    $call xt_of_arms ($call IR.arms.val (xs.tail), $call xt_of (xs.head.body, acc)),
  $case xs acc
)

// Every position, not only tail ones: an extern may stand anywhere a value may.
$decl xt_of $func ($decl e IR.proto_expr, $decl acc xts.node) $match e (
  $case {$prop tag "extern"}
    $if ($call has_xt (acc, e.sym)) acc ($call xts.cons ($call xt (e.sym, e.ty), acc)),
  $case {$prop tag "field"}   ($call xt_of ($call IR.eval (e.target), acc)),
  $case {$prop tag "new"}     ($call xt_of ($call IR.eval (e.init), acc)),
  $case {$prop tag "deref"}   ($call xt_of ($call IR.eval (e.src), acc)),
  $case {$prop tag "copy"}    ($call xt_of ($call IR.eval (e.src), acc)),
  $case {$prop tag "try"}     ($call xt_of ($call IR.eval (e.value), acc)),
  $case {$prop tag "set"}
    $call xt_of ($call IR.eval (e.value), $call xt_of ($call IR.eval (e.target), acc)),
  $case {$prop tag "do"}
    $call xt_of ($call IR.eval (e.then), $call xt_of ($call IR.eval (e.first), acc)),
  $case {$prop tag "if"}
    $call xt_of ($call IR.eval (e.els),
        $call xt_of ($call IR.eval (e.then), $call xt_of ($call IR.eval (e.cond), acc))),
  $case {$prop tag "call"}
    $call xt_of_list ($call IR.exprs.val (e.args), $call xt_of ($call IR.eval (e.callee), acc)),
  $case {$prop tag "group"}   ($call xt_of_list ($call IR.exprs.val (e.items), acc)),
  $case {$prop tag "closure"} ($call xt_of_list ($call IR.exprs.val (e.captures), acc)),
  $case {$prop tag "block"}   ($call xt_of_slots ($call IR.bslots.val (e.slots), acc)),
  $case {$prop tag "switch"}
    $call xt_of ($call IR.eval (e.default),
        $call xt_of_arms ($call IR.arms.val (e.arms), $call xt_of ($call IR.eval (e.scrut), acc))),
  $case {$prop tag "tobj"}    ($call xt_of ($call IR.eval (e.ref), acc)),
  $case {$prop tag "tmem"}    ($call xt_of ($call IR.eval (e.obj), acc)),
  $case {$prop tag "addr"}    ($call xt_of ($call IR.eval (e.src), acc)),
  $case e acc
)

// Linkage is decided by `IR.fn.pub` — a property of each function on its own, so a
// module's emitted text depends on its own source and not on who calls it. The walk
// that used to derive it from the whole table is gone; what it computed (a symbol is
// external iff a *different* module names it) was finer, and finer was the problem.

$decl xts_of_fns $func ($decl fs IR.fns.node, $decl acc xts.node) $match fs (
  $case {$prop tag "cons"}
    $call xts_of_fns ($call IR.fns.val (fs.tail), $call xt_of (fs.head.body, acc)),
  $case fs acc
)

$decl xt_sym $func ($decl st proto_est, $decl y "")
  $call concat ("mpl_x_", y)

// `extern R sym(T0, T1);` — the declaration §4.16's ABI mapping asks for. The
// parameter *names* are omitted: a prototype needs only types, and a name here
// could collide with a macro the headers define.
$decl xt_params $func ($decl st proto_est, $decl ts T.tys.node, $decl xs T.tys.node,
                       $decl acc "", $decl first P.boolean) $match xs (
  $case {$prop tag "cons"} {
    $decl f $call IR.find_ty (ts, xs.head)
    $decl ret $call xt_params (st, ts, xs.tail,
                $call concat (acc, $call concat ($if first "" ", ",
                    $if f.hit ($call c_type_ffi (st, ts, f.id)) "int64_t")), false)
  }.ret,
  $case xs acc
)

// The wrapper's parameters, which do need names because the body passes them on.
$decl xt_wparams $func ($decl st proto_est, $decl ts T.tys.node, $decl xs T.tys.node,
                        $decl k 0, $decl acc "") $match xs (
  $case {$prop tag "cons"} {
    $decl f $call IR.find_ty (ts, xs.head)
    $decl ret $call xt_wparams (st, ts, xs.tail, $call add (k, 1),
                $call concat (acc, $call concat (", ",
                    $call concat ($if f.hit ($call c_type (st, ts, f.id)) "int64_t",
                    $call concat (" x", $call int_to_str (k))))))
  }.ret,
  $case xs acc
)

$decl xt_wargs $func ($decl n 0, $decl k 0, $decl acc "", $decl first P.boolean)
  $if ($call not ($call lt (k, n))) acc
      ($call xt_wargs (n, $call add (k, 1),
          $call concat (acc, $call concat ($if first "" ", ",
              $call concat ("x", $call int_to_str (k)))), false))

// What a C function's result becomes on the morphl side. A plain value is
// returned as itself; a *function* is §7.3's pair, built around the adapter above.
$fwd fn_inside

// Whether a `$func` appears somewhere §4.16's mapping cannot spell it. A function
// directly, or behind a `&T`, is fine: the first crosses as a code pointer and the
// second as a pointer to §7.3's pair, and C can write either. Inside a **block
// field, group member, union member or array element** it is not, because §7.2
// lays the pair out inline and two words is not one — a C struct declared with a
// function pointer where morphl put a pair disagrees about every field after it,
// silently. §4.16's mapping says nothing about this shape, so it is reported here
// rather than emitted; the workaround is to pass the callback beside the block.
$decl fn_in_flds $func ($decl ts T.tys.node, $decl fs T.fields.node) $match fs (
  $case {$prop tag "cons"}
    $if ($call fn_inside (ts, $call T.tval (fs.head.ty), true)) true
        ($call fn_in_flds (ts, $call T.fields.val (fs.tail))),
  $case fs false
)

$decl fn_in_tys $func ($decl ts T.tys.node, $decl xs T.tys.node, $decl inner P.boolean)
  $match xs (
    $case {$prop tag "cons"}
      $if ($call fn_inside (ts, $call T.tval (xs.head), inner)) true
          ($call fn_in_tys (ts, $call T.tys.val (xs.tail), inner)),
    $case xs false
  )

$decl fn_inside $func ($decl ts T.tys.node, $decl t T.proto_ty, $decl inner P.boolean)
  $match t (
    // A callback's own signature is an FFI position too, by the same argument, so
    // the rule applies inside it at top-level status rather than stopping here.
    $case {$prop tag "func"}
      $if inner true
          ($if ($call fn_in_tys (ts, $call T.tys.val (t.params), false)) true
               ($call fn_inside (ts, $call T.tval (t.result), false))),
    // A reference crosses as a pointer, so what it points at is written through
    // the pointer and the pair is fine there — the top-level status carries.
    $case {$prop tag "ref"} ($call fn_inside (ts, $call T.tval (t.inner), inner)),
    $case {$prop tag "block"} ($call fn_in_flds (ts, $call T.fields.val (t.fields))),
    $case {$prop tag "group"} ($call fn_in_tys (ts, $call T.tys.val (t.items), true)),
    $case {$prop tag "union"} ($call fn_in_tys (ts, $call T.tys.val (t.members), true)),
    $case {$prop tag "array"} ($call fn_inside (ts, $call T.tval (t.elem), true)),
    $case {$prop tag "rec"} ($call fn_inside (ts, $call T.tval (t.body), true)),
    $case t false
  )

$decl chk_ffi_ty $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0, $decl sym "",
                        $decl what "")
  $if ($if ($call lt (i, 0)) false
           ($call fn_inside (ts, $call type_at (ts, i), false))) {
    $decl m $call concat ("$extern \"", $call concat (sym,
                $call concat ("\": §4.16's ABI mapping cannot cross a $func inside a block, group, union or array (",
                $call concat (what, ")"))))
    // Said in the C as well as in the diagnostics. An emit diagnostic is
    // non-fatal (a library with no `main` reports one), so the declaration
    // below is emitted anyway — and unlike §6a's refusal, which emits
    // something correct that is merely not a loop, this one emits a struct
    // the C side cannot match. The artifact has to say so on its own.
    // ASCII, like `runtime_c`: the emitted file is bytes and `emit_test`
    // slices it by byte. The detail is in the diagnostic, which is text.
    $decl d $call say (st, $call concat ("/* unmappable (4.16 ABI): a $func inside a block, group, union or array, in ",
                $call concat (what, " */\n")))
    $decl ret $call eerr (st, m)
  }.ret ()

$decl chk_ffi_ps $func ($decl st proto_est, $decl ts T.tys.node, $decl ps T.tys.node,
                        $decl sym "", $decl k 0) $match ps (
  $case {$prop tag "cons"} {
    $decl d $call chk_ffi_ty (st, ts, $call ps_id (ts, ps), sym,
                $call concat ("parameter ", $call int_to_str (k)))
    $decl ret $call chk_ffi_ps (st, ts, $call ps_rest (ps), sym, $call add (k, 1))
  }.ret,
  $case ps ()
)

$decl ffi_retstmt $func ($decl st proto_est, $decl ts T.tys.node, $decl ri 0, $decl c "")
  $if ($if ($call lt (ri, 0)) false ($call is_func_ty (st, ts, ri)))
      ($call concat ("mpl_fun r; r.code = (void *)",
          $call concat ($call fpw_name (ri),
          $call concat ("; r.env = (void *)", $call concat (c, "; return r; }\n")))))
      ($call concat ("return ", $call concat (c, "; }\n")))

$fwd emit_fp

// A function type reached through another one's signature needs its own typedef,
// and needs it *first*: C has no forward declaration for a typedef name.
$decl emit_fp_ps $func ($decl st proto_est, $decl ts T.tys.node, $decl ps T.tys.node)
  $match ps (
    $case {$prop tag "cons"} {
      $decl f   $call IR.find_ty (ts, ps.head)
      $decl d   $if f.hit ($call emit_fp (st, ts, f.id)) ()
      $decl ret $call emit_fp_ps (st, ts, $call T.tys.val (ps.tail))
    }.ret,
    $case ps ()
  )

$decl emit_fp $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0)
  $if ($call mem_int (st.fps, i)) () {
    $decl t $call type_at (ts, i)
    $decl ret $match t (
        $case {$prop tag "func"} {
          $decl m  $set st.fps ($call IR.ints.cons (i, st.fps))
          $decl ps $call T.tys.val (t.params)
          $decl np $call T.tys.length (ps, 0)
          $decl rf $call IR.find_ty (ts, t.result)
          $decl d0 $if rf.hit ($call emit_fp (st, ts, rf.id)) ()
          $decl d1 $call emit_fp_ps (st, ts, ps)
          $decl d2 $call say (st, $call concat ("typedef ",
                       $call concat ($if rf.hit ($call c_type_ffi (st, ts, rf.id)) "int64_t",
                       $call concat (" (*", $call concat ($call fp_name (i),
                       $call concat (")(", $call concat ($if ($call eq_int (np, 0)) "void"
                               ($call ffi_params (st, ts, ps, "", true)),
                           ");\n")))))))
          // The adapter: morphl's convention outside, C's inside. Its own
          // parameters are the morphl ones, so a nested callback still
          // crosses through `ffi_wargs` rather than by assignment.
          $decl w0 $call say (st, $call concat ("static ",
                       $call concat ($if rf.hit ($call c_type (st, ts, rf.id)) "int64_t",
                       $call concat (" ", $call concat ($call fpw_name (i),
                       $call concat ("(void *env", $call concat ($call xt_wparams (st, ts, ps, 0, ""),
                                     ") { ")))))))
          $decl ret2 $call say (st, $call ffi_retstmt (st, ts, $if rf.hit rf.id -1,
                       $call concat ("((", $call concat ($call fp_name (i),
                       $call concat (")env)(", $call concat ($call ffi_wargs (st, ts, ps, 0, "", true),
                                     ")"))))))
        }.ret2,
        $case t ()
      )
  }.ret


$decl emit_xt $func ($decl st proto_est, $decl ts T.tys.node, $decl x proto_xt) {
  $decl t $call type_at (ts, x.ty)
  $decl ret $match t (
      $case {$prop tag "func"} {
        $decl ps $call T.tys.val (t.params)
        $decl np $call T.tys.length (ps, 0)
        $decl rf $call IR.find_ty (ts, t.result)
        // The typedefs first: they are what `c_type_ffi` names below, and a
        // typedef name has no forward declaration in C.
        $decl c0 $call chk_ffi_ps (st, ts, ps, x.sym, 0)
        $decl c1 $call chk_ffi_ty (st, ts, $if rf.hit rf.id -1, x.sym, "the result")
        $decl f0 $if rf.hit ($call emit_fp (st, ts, rf.id)) ()
        $decl f1 $call emit_fp_ps (st, ts, ps)
        $decl rc $if rf.hit ($call c_type_ffi (st, ts, rf.id)) "int64_t"
        $decl d0 $call say (st, $call concat ("extern ", $call concat (rc,
                     $call concat (" ", $call concat (x.sym,
                     $call concat ("(", $call concat ($if ($call eq_int (np, 0)) "void"
                             ($call xt_params (st, ts, ps, "", true)), ");\n")))))))
        // §7.3's pair needs morphl's convention, which a C function does not
        // have — so a symbol used as a *value* points at this instead.
        // The wrapper is called *by morphl*, so its own signature is the
        // morphl one — `c_type`, not `c_type_ffi`. When the result is itself a
        // function the two differ, and the pair has to be built here.
        $decl wc $if rf.hit ($call c_type (st, ts, rf.id)) "int64_t"
        $decl d1 $call say (st, $call concat ("static ", $call concat (wc,
                     $call concat (" ", $call concat ($call xt_sym (st, x.sym),
                     $call concat ("(void *env", $call concat ($call xt_wparams (st, ts, ps, 0, ""),
                                   ") { (void)env; ")))))))
        $decl ret2 $call say (st, $call ffi_retstmt (st, ts, $if rf.hit rf.id -1,
                     $call concat (x.sym, $call concat ("(",
                     $call concat ($call ffi_wargs (st, ts, ps, 0, "", true), ")")))))
      }.ret2,
      $case t ($call eerr (st, $call concat ("the signature of $extern \"",
                   $call concat (x.sym, "\" is not a function type"))))
    )
}.ret

$decl emit_xts $func ($decl st proto_est, $decl ts T.tys.node, $decl xs xts.node) $match xs (
  $case {$prop tag "cons"}
    $do ($call emit_xt (st, ts, xs.head)) ($call emit_xts (st, ts, xs.tail)),
  $case xs ()
)

// ------------------------------------------- §6a's indirect case: reporting
//
// A tail call through a function *value* cannot become a loop: the target is
// unknown until run time, so there is no body to jump back into. §6a's answer is
// a trampoline, and this is it — the smallest one that keeps §7.7.
//
// **The function reports the call instead of making it.** It fills a pending
// block, returns a zero of its own result type, and whoever called it drives the
// chain to completion. So the chain costs one frame per *hop*, reused, instead of
// one frame per hop accumulated. Nothing about any function's C signature
// changes, which is what makes this affordable: BOOTSTRAP §6a expected "every
// function returns a value or a pending call", a whole-program calling
// convention, and that is not needed if the pending call travels beside the
// value rather than inside it.
//
// The pending block is static. §7.8 puts concurrency behind `$extern` and gives
// the language none of its own, so there is one chain at a time; the driver
// copies the block into locals *before* calling, so a nested drive — an indirect
// call in a non-tail position, say — cannot clobber the outer one.
//
// Who reports and who drives:
//
//   - a function containing an indirect tail call **reports** it, and every call
//     site that can reach such a function drives afterwards: every indirect call
//     site (the target is unknown, so it might), and every direct call to a
//     function known to report.
//   - a member of a contified group is excluded and **drives locally** instead.
//     Reporting from inside a group function would have to travel out through
//     the wrappers, and one frame per such member is bounded anyway.
//
// A call is indirect exactly when emit would not make it directly — which is the
// same question `is_global` and the alias resolution answer, so it is asked
// through them rather than duplicated.
$decl is_direct_callee $func ($decl st proto_est, $decl c IR.proto_expr) $match c (
  $case {$prop tag "prim"} true,
  $case {$prop tag "global"}
    $if ($call is_global (st, c)) true
        ($call not ($call eq_str ($call alias_prim (st, c.fn), ""))),
  $case c ($call not ($call eq_str ($call callee_prim (st, c), "")))
)

$fwd indirect_tails

$decl indirect_tails_arms $func ($decl st proto_est, $decl xs IR.arms.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call indirect_tails (st, xs.head.body)) true
        ($call indirect_tails_arms (st, xs.tail)),
  $case xs false
)

// Only tail positions, for the same reason `self_tails` walks only these: §7.7
// says what they are, and a call anywhere else is not a tail call at all.
$decl indirect_tails $func ($decl st proto_est, $decl e IR.proto_expr) $match e (
  $case {$prop tag "call"}
    $if e.tail ($call not ($call is_direct_callee (st, $call IR.eval (e.callee)))) false,
  $case {$prop tag "if"}
    $if ($call indirect_tails (st, e.then)) true ($call indirect_tails (st, e.els)),
  $case {$prop tag "do"} ($call indirect_tails (st, e.then)),
  $case {$prop tag "switch"}
    $if ($call indirect_tails_arms (st, $call IR.arms.val (e.arms))) true
        ($call indirect_tails (st, e.default)),
  $case e false
)

$fwd tail_sigs

$decl tail_sigs_arms $func ($decl st proto_est, $decl xs IR.arms.node, $decl acc IR.ints.node)
  $match xs (
    $case {$prop tag "cons"}
      $call tail_sigs_arms (st, xs.tail, $call tail_sigs (st, xs.head.body, acc)),
    $case xs acc
  )

// The callee *type* at every indirect tail call: one `case` in the driver's
// switch and one member of its argument union, because the driver has to make
// the call with the right C signature and §3.6 gives it no other way to know.
$decl tail_sigs $func ($decl st proto_est, $decl e IR.proto_expr, $decl acc IR.ints.node)
  $match e (
    $case {$prop tag "call"} {
      $decl c $call IR.eval (e.callee)
      $decl ret $if e.tail
          ($if ($call is_direct_callee (st, c)) acc
               ($if ($call mem_int (acc, c.ty)) acc ($call IR.ints.cons (c.ty, acc))))
          acc
    }.ret,
    $case {$prop tag "if"}
      $call tail_sigs (st, e.els, $call tail_sigs (st, e.then, acc)),
    $case {$prop tag "do"} ($call tail_sigs (st, e.then, acc)),
    $case {$prop tag "switch"}
      $call tail_sigs (st, e.default, $call tail_sigs_arms (st, $call IR.arms.val (e.arms), acc)),
    $case e acc
  )

$decl reporter_ids $func ($decl st proto_est, $decl fs IR.fns.node, $decl gs IR.groups.node,
                          $decl i 0, $decl acc IR.ints.node) $match fs (
  $case {$prop tag "cons"} {
    $decl rep $if ($call in_a_group (gs, i)) false
                  ($call indirect_tails (st, fs.head.body))
    $decl ret $call reporter_ids (st, $call IR.fns.val (fs.tail), gs, $call add (i, 1),
                $if rep ($call IR.ints.cons (i, acc)) acc)
  }.ret,
  $case fs acc
)

$decl all_tail_sigs $func ($decl st proto_est, $decl fs IR.fns.node, $decl acc IR.ints.node)
  $match fs (
    $case {$prop tag "cons"}
      $call all_tail_sigs (st, $call IR.fns.val (fs.tail), $call tail_sigs (st, fs.head.body, acc)),
    $case fs acc
  )

$decl reports $func ($decl st proto_est, $decl i 0) $call mem_int (st.reps, i)

// Whether the driver exists at all. It is emitted only for a program that has an
// indirect *tail* call, since only one of those ever reports — so a program with
// an ordinary indirect call and no tail call through a value must not drive after
// it: there is nothing that could have left a pending block, and naming
// `mpl_tcdrive` where it was never emitted is a link error.
$decl any_reports $func ($decl st proto_est)
  $call not ($call IR.ints.is_nil ($call IR.ints.val (st.tsigs)))

// Whether a *direct* call needs driving afterwards: the callee is resolved first,
// because an alias reports exactly when the function it names does.
$decl callee_reports $func ($decl st proto_est, $decl c IR.proto_expr) $match c (
  $case {$prop tag "global"} ($call reports (st, $call res_fn (st, c.fn))),
  $case c false
)

// One union member per participating signature: the arguments of a pending call,
// which the driver has to hold across the hop.
$decl tcargs_fields $func ($decl st proto_est, $decl ts T.tys.node, $decl xs T.tys.node,
                           $decl k 0, $decl acc "") $match xs (
  $case {$prop tag "cons"} {
    $decl f $call IR.find_ty (ts, xs.head)
    $decl ret $call tcargs_fields (st, ts, xs.tail, $call add (k, 1),
                $call concat (acc, $call concat (" ",
                $call concat ($if f.hit ($call c_type (st, ts, f.id)) "int64_t",
                $call concat (" a", $call concat ($call int_to_str (k), ";"))))))
  }.ret,
  $case xs acc
)

$decl tcargs_member $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0) {
  $decl t $call type_at (ts, i)
  $decl ret $match t (
      $case {$prop tag "func"}
        ($call concat ("  struct {",
            $call concat ($call tcargs_fields (st, ts, $call T.tys.val (t.params), 0, ""),
            $call concat (" } s", $call concat ($call int_to_str (i), ";\n"))))),
      $case t ""
    )
}.ret

$decl tcargs_members $func ($decl st proto_est, $decl ts T.tys.node, $decl xs IR.ints.node,
                            $decl acc "") $match xs (
  $case {$prop tag "cons"}
    $call tcargs_members (st, ts, $call IR.ints.val (xs.tail),
        $call concat (acc, $call tcargs_member (st, ts, xs.head))),
  $case xs acc
)

// The arguments of a pending call, read out of the union member its tag names.
$decl tcd_args $func ($decl m "", $decl n 0, $decl k 0, $decl acc "")
  $if ($call not ($call lt (k, n))) acc
      ($call tcd_args (m, n, $call add (k, 1),
          $call concat (acc, $call concat (", ", $call concat (m,
              $call concat (".a", $call int_to_str (k)))))))

// One `case` per signature: make the call with that signature and write the
// result through `out`. The result type comes from the signature too, and along a
// chain it never changes — §7.7 makes a tail call's result the calling
// function's, so every hop answers what the original call site asked for.
$decl tcdrive_case $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0) {
  $decl t $call type_at (ts, i)
  $decl ret $match t (
      $case {$prop tag "func"} {
        $decl rf $call IR.find_ty (ts, t.result)
        $decl rc $if rf.hit ($call c_type (st, ts, rf.id)) "int64_t"
        $decl np $call T.tys.length ($call T.tys.val (t.params), 0)
        $decl m  $call concat ("a.s", $call int_to_str (i))
        $decl ret2  $call concat ("  case ", $call concat ($call int_to_str (i),
            $call concat (": *(", $call concat (rc,
            $call concat (" *)out = (", $call concat ($call fn_sig (st, ts, i),
            $call concat ("f.code)(f.env", $call concat ($call tcd_args (m, np, 0, ""),
                          "); break;\n"))))))))
      }.ret2,
      $case t ""
    )
}.ret

$decl tcdrive_cases $func ($decl st proto_est, $decl ts T.tys.node, $decl xs IR.ints.node,
                           $decl acc "") $match xs (
  $case {$prop tag "cons"}
    $call tcdrive_cases (st, ts, $call IR.ints.val (xs.tail),
        $call concat (acc, $call tcdrive_case (st, ts, xs.head))),
  $case xs acc
)

// The pending block and the driver, emitted only when the program has an
// indirect tail call at all. The copy into locals *before* the call is what makes
// a nested drive safe; `mpl_tc = 0` after the copy, so a hop that reports again
// sets it afresh.
$decl emit_tramp $func ($decl st proto_est, $decl ts T.tys.node) {
  $decl sg $call IR.ints.val (st.tsigs)
  $decl ret  $if ($call IR.ints.is_nil (sg)) ()
      ($call say (st, $call concat (
          "\n/* 6a's indirect case: a tail call through a function value is reported\n   here rather than made, and driven by the loop below - one frame per hop,\n   reused. One block for the program because 7.8 gives the language no concurrency\n   of its own - and *one*: a callee in another output reports into it and this\n   output's caller drives it, so it is declared here and defined beside main. */\ntypedef union {\n",
          $call concat ($call tcargs_members (st, ts, sg, ""),
          $call concat ("} mpl_tcargs;\nextern int mpl_tc;\nextern int mpl_tc_tag;\nextern mpl_fun mpl_tc_fn;\nextern mpl_tcargs mpl_tc_args;\n\nstatic void mpl_tcdrive(void *out) {\n  while (mpl_tc) {\n    mpl_fun f = mpl_tc_fn;\n    int tag = mpl_tc_tag;\n    mpl_tcargs a = mpl_tc_args;\n    (void)a;\n    mpl_tc = 0;\n    switch (tag) {\n",
          $call concat ($call tcdrive_cases (st, ts, sg, ""),
                        "    default: mpl_panic(\"bad tail-call signature\");\n    }\n  }\n}\n"))))))
}.ret


// §8's failing operations: `str_to_int`, `from_code` and `read_file` answer an
// *option* — `<{tag "none"}, {tag "some", v T}>` — where every other intrinsic
// answers a machine word or a `mpl_str`. So they cannot be a `prim_fn` entry:
// §7.5 lays a union out as a tag and a payload, and §3.6 makes a union a *set*,
// so which position `some` and `none` hold is a property of the call site's own
// interned union and not of the intrinsic. The runtime does the work and says
// whether it succeeded; the option is built here, from the members in front of
// us.
$decl opt_fn $func ($decl n "")
  $if ($call eq_str (n, "str_to_int")) "mpl_str_to_int"
  ($if ($call eq_str (n, "from_code")) "mpl_from_code"
  ($if ($call eq_str (n, "read_file")) "mpl_read_file"
  ($if ($call eq_str (n, "float_to_int")) "mpl_float_to_int"
       "")))

// The position of the option's two members. `some` is the one with a field to
// carry (§4.10 erases the `tag` prop, so it has exactly one slot); `none` is
// the one with none.
$decl opt_slot $func ($decl ms T.tys.node, $decl want_field P.boolean, $decl i 0) $match ms (
  $case {$prop tag "cons"} {
    $decl has $call not ($call T.fields.is_nil ($call block_fields (ms.head)))
    $decl ret $if ($call eq_int ($if has 1 0, $if want_field 1 0)) i
                ($call opt_slot (ms.tail, want_field, $call add (i, 1)))
  }.ret,
  $case ms -1
)

// The C type the payload is carried in — read off `some`'s one field rather
// than assumed from the intrinsic, the way `emit_fields` reads every other
// field's type.
$decl opt_payload_c $func ($decl st proto_est, $decl ts T.tys.node, $decl m T.proto_ty) {
  $decl fs $call block_fields (m)
  $decl ret  $match fs (
      $case {$prop tag "cons"} {
        $decl f    $call IR.find_ty (ts, fs.head.ty)
        $decl ret2 $if f.hit ($call c_type (st, ts, f.id)) "int64_t"
      }.ret2,
      $case fs "int64_t"
    )
}.ret

// §8's `write_file` answers `<unit, err>`, where **both** members are nullary — so
// `opt_slot`, which tells `some` from `none` by which one has a field, cannot separate
// them. They are told apart structurally instead: one *is* the unit type and the other
// is §4.15's `err` tag block. The positions still belong to the call site's interned
// union and not to the intrinsic, for the reason §7.5 gives.
$decl res_slot $func ($decl ms T.tys.node, $decl wantu P.boolean, $decl i 0) $match ms (
  $case {$prop tag "cons"} {
    $decl isu $call T.same ($call T.tval (ms.head), T.t_unit)
    $decl hit $if wantu isu ($call not (isu))
    $decl ret   $if hit i
                  ($call res_slot ($call T.tys.val (ms.tail), wantu, $call add (i, 1)))
  }.ret,
  $case ms -1
)

// Not `res_fn`: that name is already the alias resolver, and §4.1 binds a name once
// per block — which is what reported this.
$decl unit_err_fn $func ($decl n "")
  $if ($call eq_str (n, "write_file")) "mpl_write_file" ""

// Only the tag is written, as `emit_opt_prim` does for `none`: §4.7 narrows to the
// member the discriminator selected and neither of these carries anything to bind.
$decl emit_res_prim $func ($decl st proto_est, $decl ts T.tys.node, $decl cf "",
                           $decl as strs.node, $decl dest "", $decl ty 0) {
  $decl wt $call type_at (ts, ty)
  $decl ms $call union_members (wt)
  $decl ku $call res_slot (ms, true, 0)
  $decl ke $call res_slot (ms, false, 0)
  $decl ok $if ($call lt (-1, ku)) ($call lt (-1, ke)) false
  $decl ret $if ($call not (ok))
      ($call eerr (st, $call concat ("the result of ", $call concat (cf,
           " is not <unit, err>; cannot emit it")))) {
        $decl d0 $call say (st, $call concat ("  if (", $call concat (cf,
                     $call concat ("(", $call concat ($call join_args (as, "", true),
                     ")) {\n")))))
        $decl d1   $call assign (st, $call concat (dest, ".tag"), $call int_to_str (ku))
        $decl d2   $call say (st, "  } else {\n")
        $decl d3   $call assign (st, $call concat (dest, ".tag"), $call int_to_str (ke))
        $decl ret2 $call say (st, "  }\n")
      }.ret2
}.ret

$decl emit_opt_prim $func ($decl st proto_est, $decl ts T.tys.node, $decl cf "",
                           $decl as strs.node, $decl dest "", $decl ty 0) {
  $decl wt $call type_at (ts, ty)
  $decl ms $call union_members (wt)
  $decl ks $call opt_slot (ms, true, 0)
  $decl kn $call opt_slot (ms, false, 0)
  $decl ok $if ($call lt (-1, ks)) ($call lt (-1, kn)) false
  $decl ret $if ($call not (ok))
      ($call eerr (st, $call concat ("the result of ", $call concat (cf,
           " is not an option; cannot emit it")))) {
        $decl tmp $call fresh_tmp (st)
        $decl pc  $call opt_payload_c (st, ts, $call T.tys.nth (ms, ks))
        $decl d0  $call say (st, $call concat ("  ", $call concat (pc,
                      $call concat (" ", $call concat (tmp, ";\n")))))
        $decl d1  $call say (st, $call concat ("  if (", $call concat (cf,
                      $call concat ("(", $call concat ($call join_args (as, "", true),
                      $call concat (", &", $call concat (tmp, ")) {\n")))))))
        $decl d2  $call assign (st, $call concat (dest, ".tag"), $call int_to_str (ks))
        $decl d3  $call assign (st, $call concat (dest, $call concat (".u.m",
                      $call concat ($call int_to_str (ks), ".f0"))), tmp)
        $decl d4   $call say (st, "  } else {\n")
        $decl d5   $call assign (st, $call concat (dest, ".tag"), $call int_to_str (kn))
        $decl ret2 $call say (st, "  }\n")
      }.ret2
}.ret

// §8's array intrinsics. None can be a `prim_fn`: `at` answers a *reference*
// into the elements (stage 0 returns `.ref = &a.elems[i]`, and §5.4 reads it
// through where a value is wanted), `alen` is a field, and `array` needs the
// element's size. So they are emitted inline, the way the option-returning ones
// are and for the same kind of reason.
//
// The bounds check is not decoration: stage 0 *panics* on an out-of-range index
// and two implementations of one intrinsic have to agree (§8). The text differs
// — stage 0 formats the index and the length into the message and `mpl_panic`
// takes a C string — but the behaviour does not.
$decl arr_prim $func ($decl n "")
  $if ($call eq_str (n, "at")) true
  ($if ($call eq_str (n, "alen")) true
  ($if ($call eq_str (n, "array")) true
  ($if ($call eq_str (n, "args")) true false)))

$decl emit_arr_prim $func ($decl st proto_est, $decl ts T.tys.node, $decl nm "",
                           $decl as strs.node, $decl dest "", $decl ty 0)
  // §8's `args`, built from the host's `argv` **without** the program name, so
  // that `$call at (argv, 0)` is the first real argument — which is what stage 0
  // answers, since its platform hands over the arguments and not the
  // interpreter's own name.
  $if ($call eq_str (nm, "args")) {
    $decl k  $call fresh_tmp (st)
    $decl d0 $call assign (st, $call concat (dest, ".n"),
                 "(int64_t)(mpl_argc > 1 ? mpl_argc - 1 : 0)")
    $decl d1 $call say (st, $call concat ("  ", $call concat (dest,
                 $call concat (".p = (mpl_str *)mpl_alloc(", $call concat (dest,
                 ".n * (int64_t)sizeof(mpl_str));\n")))))
    $decl d2 $call say (st, $call concat ("  { int64_t ", $call concat (k,
                 $call concat ("; for (", $call concat (k,
                 $call concat (" = 0; ", $call concat (k,
                 $call concat (" < ", $call concat (dest,
                 $call concat (".n; ", $call concat (k,
                 $call concat ("++) { ", $call concat (dest,
                 $call concat (".p[", $call concat (k,
                 $call concat ("].p = mpl_argv[", $call concat (k,
                 $call concat (" + 1]; ", $call concat (dest,
                 $call concat (".p[", $call concat (k,
                 $call concat ("].n = (int64_t)strlen(mpl_argv[", $call concat (k,
                 " + 1]); } }\n")))))))))))))))))))))))
    $decl ret  ()
  }.ret
  ($if ($call eq_str (nm, "alen"))
      ($call assign (st, dest, $call concat ($call strs.nth (as, 0), ".n")))
  ($if ($call eq_str (nm, "at")) {
    $decl a $call strs.nth (as, 0)
    $decl i $call strs.nth (as, 1)
    $decl g $call say (st, $call concat ("  if (", $call concat (i,
                $call concat (" < 0 || ", $call concat (i,
                $call concat (" >= ", $call concat (a,
                ".n) mpl_panic(\"at: index out of range\");\n")))))))
    $decl ret $call assign (st, dest, $call concat ("&", $call concat (a,
                $call concat (".p[", $call concat (i, "]")))))
  }.ret {
    // §8: `array (n, init)` is `n` copies of `init`, and a negative length
    // panics — again matching stage 0.
    $decl at0 $call type_at (ts, ty)
    $decl el  $match at0 ($case {$prop tag "array"} ($call T.tval (at0.elem)), $case at0 T.t_bot)
    $decl f   $call IR.find_ty (ts, el)
    $decl et  $if f.hit ($call c_type (st, ts, f.id)) "int64_t"
    $decl n   $call strs.nth (as, 0)
    $decl v   $call strs.nth (as, 1)
    $decl k   $call fresh_tmp (st)
    $decl g   $call say (st, $call concat ("  if (", $call concat (n,
                  " < 0) mpl_panic(\"array: negative length\");\n")))
    $decl d0  $call say (st, $call concat ("  ", $call concat (dest,
                  $call concat (".p = (", $call concat (et,
                  $call concat (" *)mpl_alloc(", $call concat (n,
                  $call concat (" * (int64_t)sizeof(", $call concat (et, "));\n")))))))))
    $decl d1  $call assign (st, $call concat (dest, ".n"), n)
    $decl d2  $call say (st, $call concat ("  { int64_t ", $call concat (k,
                  $call concat ("; for (", $call concat (k,
                  $call concat (" = 0; ", $call concat (k,
                  $call concat (" < ", $call concat (n,
                  $call concat ("; ", $call concat (k,
                  $call concat ("++) ", $call concat (dest,
                  $call concat (".p[", $call concat (k,
                  $call concat ("] = ", $call concat (v, "; }\n")))))))))))))))))
    $decl ret   ()
  }.ret))

// The call shape, since narrowing does not cross a call (§5.7).
$decl proto_call $call IR.e_call (0, $call IR.e_unit (0), IR.exprs.nil, false)

$decl emit_call $func ($decl st proto_est, $decl fi 0, $decl e proto_call,
                       $decl dest "", $decl ts T.tys.node) {
  $decl cal $call IR.eval (e.callee)
  $decl cty $call type_at (ts, cal.ty)
  $decl ps  $match cty ($case {$prop tag "func"} ($call T.tys.val (cty.params)), $case cty T.tys.nil)
  $decl as  $call emit_args (st, fi, $call IR.exprs.val (e.args), ps, ts, strs.nil)
  // The intrinsic this call names (`callee_prim`), resolved to the candidate the
  // callee's type selects.
  $decl pnm $call prim_resolve ($call callee_prim (st, cal), $call prim_kind (cty))
  // §4.16: the C symbol this call names, directly or through the thunk a
  // top-level `$decl` of an `$extern` lowers to. The call is emitted as an
  // ordinary C call — **no `void *env`**, because the callee is a C function
  // and not a morphl one, which is the whole of what the ABI mapping asks for
  // on this side.
  $decl xnm $match cal (
      $case {$prop tag "extern"} cal.sym,
      $case {$prop tag "global"} ($call alias_xsym (st, cal.fn)),
      $case cal ""
    )
  $decl ret $if ($call not ($call eq_str (xnm, "")))
      // A tail call to a C function cannot be a loop and needs no trampoline:
      // §7.7 is a rule about morphl functions, and C's stack is C's business —
      // an extern is opaque (§4.16 rule 1), so it does not tail-call back in.
      ($call ffi_ret (st, ts, e.ty, dest, $call concat (xnm,
          $call concat ("(", $call concat ($call ffi_args (st, ts, ps, as, "", true), ")")))))
    ($if ($call not ($call eq_str (pnm, ""))) {
      // §8's operators inline; nothing else in the root block has a C form
      // this slice can emit.
      $decl op $call prim_op (pnm)
      $decl uo $call prim_un (pnm)
      $decl cf $call prim_fn (pnm)
      $decl of $call opt_fn (pnm)
      $decl rf $call unit_err_fn (pnm)
      $decl ret2  $if ($call not ($call eq_str (op, "")))
          ($call assign (st, dest, $call binop_expr (as, op)))
        ($if ($call not ($call eq_str (uo, "")))
          ($call assign (st, dest, $call concat ("(", $call concat (uo,
              $call concat ($call strs.nth (as, 0), ")")))))
        ($if ($call not ($call eq_str (cf, "")))
          ($call assign (st, dest, $call prim_call (cf, as)))
        ($if ($call not ($call eq_str (of, "")))
          ($call emit_opt_prim (st, ts, of, as, dest, e.ty))
        ($if ($call not ($call eq_str (rf, "")))
          ($call emit_res_prim (st, ts, rf, as, dest, e.ty))
        ($if ($call arr_prim (pnm))
          ($call emit_arr_prim (st, ts, pnm, as, dest, e.ty))
          ($call eerr (st, $call concat ("cannot emit the intrinsic ", pnm))))))))
    }.ret2
    $match cal (
      $case cal {
        // §6a: a direct self tail call is the loop; anything else is a plain
        // call, which is correct but is not §7.7's guarantee.
        $decl ts2 $if e.tail ($call tail_state (st, cal, fi)) -1
        $decl ret2 $if ($call eq_int (ts2, -1))
          ($if ($call is_global (st, cal)) {
            // A direct call, and it has to **drive** afterwards if the
            // callee is one of the functions that report an indirect tail
            // call: the value it handed back is a zero and the real answer
            // is at the end of the chain it left pending (§6a).
            $decl d0 $call assign (st, dest, $call call_expr ($call callee_name (st, cal), as))
            $decl ret3  $if ($call callee_reports (st, cal))
                ($call say (st, $call concat ("  mpl_tcdrive(&", $call concat (dest, ");\n"))))
                ()
          }.ret3 {
            // §7.3: through the pair. The signature comes from the static
            // type at the call site, since every function value has the
            // same shape and carries none of it.
            $decl fv $call into_tmp (st, fi, cal, ts)
            // §6a's indirect case. In **tail** position, inside a
            // function that reports, the call is not made at all: the
            // pending block is filled and a zero returned, and the
            // driver above whoever called us makes the call. That is
            // what keeps §7.7 — the chain reuses one frame per hop
            // instead of accumulating one.
            //
            // Anywhere else the call is made and then driven to
            // completion here, because this position needs the value:
            // a non-tail call, or a tail call in a function that is not
            // a reporter (a contified group's member, which drives
            // locally rather than reporting out through its wrapper).
            $decl rep $if e.tail ($call P.bval (st.inrep)) false
            $decl ret3  $if rep
                ($call emit_report (st, ts, fv, as, dest, cal.ty, e.ty)) {
                  $decl d0 $call assign (st, dest,
                      $call indirect_call ($call fn_sig (st, ts, cal.ty), fv, as))
                  $decl ret4 $if ($call any_reports (st))
                      ($call say (st, $call concat ("  mpl_tcdrive(&",
                                $call concat (dest, ");\n")))) ()
                }.ret4
          }.ret3) {
            // §6a: the parameters are updated *in parallel* — every new
            // argument is already in a temporary — then the loop re-enters,
            // at another member's state if this is a mutual call.
            $decl a $call assign_slots (st, as, 0,
                $if ($call P.bval (st.gen)) ($call qpre (ts2)) "s")
            $decl b $if ($call eq_int (ts2, -2)) ()
                ($call assign (st, "state", $call int_to_str (ts2)))
            $decl ret3 $call say (st, "  continue;\n")
          }.ret3
      }.ret2
    ))
}.ret

// §7.2: "Groups are laid out elementwise." Each item is evaluated into a
// temporary of its own first, because an item may need statements and a C
// initializer cannot hold one — the same reason a block is built this way.
$decl emit_gitems $func ($decl st proto_est, $decl fi 0, $decl xs IR.exprs.node,
                         $decl ts T.tys.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"} {
    $decl nm $call fresh_tmp (st)
    $decl d0 $call say (st, $call concat ("  ", $call concat ($call c_type (st, ts, xs.head.ty),
                 $call concat (" ", $call concat (nm, ";\n")))))
    $decl d1 $call emit_expr (st, fi, xs.head, nm, ts)
    $decl ret  $call emit_gitems (st, fi, $call IR.exprs.val (xs.tail), ts,
                 $call strs.cons (nm, acc))
  }.ret,
  $case xs ($call strs.reverse (acc, strs.nil))
)

$decl emit_slot_inits $func ($decl st proto_est, $decl fi 0, $decl xs IR.bslots.node,
                             $decl ts T.tys.node) $match xs (
  $case {$prop tag "cons"} {
    $decl d   $call emit_expr (st, fi, xs.head.init, $call slot_name (xs.head.slot), ts)
    $decl ret $call emit_slot_inits (st, fi, xs.tail, ts)
  }.ret,
  $case xs ()
)

$decl emit_slot_reads $func ($decl st proto_est, $decl xs IR.bslots.node,
                             $decl first P.boolean) $match xs (
  $case {$prop tag "cons"} {
    $decl d   $call say (st, $call concat ($if first " " ", ", $call slot_name (xs.head.slot)))
    $decl ret $call emit_slot_reads (st, xs.tail, false)
  }.ret,
  $case xs ()
)

$decl env_name $func ($decl i 0) $call concat ("mpl_env", $call int_to_str (i))

$decl env_fields $func ($decl st proto_est, $decl ts T.tys.node, $decl xs IR.ints.node,
                        $decl i 0, $decl acc "") $match xs (
  $case {$prop tag "cons"}
    $call env_fields (st, ts, xs.tail, $call add (i, 1),
        $call concat (acc, $call concat (" ", $call concat ($call c_type (st, ts, xs.head),
            $call concat (" c", $call concat ($call int_to_str (i), ";")))))),
  $case xs acc
)

// One per capturing function: the body names it to read a capture, and the
// closure names it to fill one in (§7.3).
$decl emit_envs $func ($decl st proto_est, $decl fs IR.fns.node, $decl ts T.tys.node,
                       $decl i 0) $match fs (
  $case {$prop tag "cons"} {
    $decl ev $call IR.ints.val (fs.head.env)
    $decl d  $if ($call IR.ints.is_nil (ev)) ()
        ($call say (st, $call concat ("typedef struct {",
            $call concat ($call env_fields (st, ts, ev, 0, ""),
            $call concat (" } ", $call concat ($call env_name (i), ";\n"))))))
    $decl ret $call emit_envs (st, $call IR.fns.val (fs.tail), ts, $call add (i, 1))
  }.ret,
  $case fs ()
)

$decl emit_env $func ($decl st proto_est, $decl fi 0, $decl xs IR.exprs.node,
                      $decl ev "", $decl i 0, $decl ts T.tys.node) $match xs (
  $case {$prop tag "cons"} {
    $decl d $call emit_expr (st, fi, xs.head,
        $call concat (ev, $call concat ("->c", $call int_to_str (i))), ts)
    $decl ret $call emit_env (st, fi, $call IR.exprs.val (xs.tail), ev, $call add (i, 1), ts)
  }.ret,
  $case xs ()
)

// The member `$try` leaves behind. §1.3 keeps the bootstrap's patterns to one
// tag, so exactly one other member survives; anything else needs a re-tag that
// this slice does not emit.
$decl other_disc $func ($decl ms T.tys.node, $decl taken 0, $decl i 0) $match ms (
  $case {$prop tag "cons"}
    $if ($call eq_int (i, taken)) ($call other_disc ($call T.tys.val (ms.tail), taken,
                                       $call add (i, 1))) i,
  $case ms 0
)

// The C value a discriminator tests against. For an ordinary union that is the
// member's index; for `Bool` it is the member's own value (§3.2), since a
// boolean is a machine word and carries no separate tag.
$decl disc_label $func ($decl ms T.tys.node, $decl d 0, $decl boolish P.boolean)
  $if ($call not (boolish)) d
      ($if ($call T.same ($call T.tys.nth (ms, d), T.t_true)) 1 0)

$decl emit_labels $func ($decl st proto_est, $decl xs IR.ints.node, $decl ms T.tys.node,
                         $decl boolish P.boolean) $match xs (
  $case {$prop tag "cons"} {
    $decl d $call say (st, $call concat ("  case ",
        $call concat ($call int_to_str ($call disc_label (ms, xs.head, boolish)), ": ")))
    $decl ret $call emit_labels (st, xs.tail, ms, boolish)
  }.ret,
  $case xs ()
)

$decl emit_first_arm $func ($decl st proto_est, $decl fi 0, $decl xs IR.arms.node,
                            $decl dest "", $decl want 0, $decl ts T.tys.node) $match xs (
  $case {$prop tag "cons"} ($call emit_as (st, fi, xs.head.body, dest, want, ts)),
  $case xs ($call eerr (st, "a $match with no arms"))
)

$decl emit_cases $func ($decl st proto_est, $decl fi 0, $decl xs IR.arms.node,
                        $decl dest    "", $decl want 0, $decl ts T.tys.node,
                        $decl scrut   "", $decl ms T.tys.node,
                        $decl boolish P.boolean) $match xs (
  $case {$prop tag "cons"} {
    $decl ds $call IR.ints.val (xs.head.discs)
    $decl d0 $call emit_labels (st, ds, ms, boolish)
    $decl d1 $call say (st, "{\n")
    // §4.7's narrowing: the arm's slot holds the member the discriminator
    // selected, which is what the body reads the fields off.
    // An arm whose body ignores the narrowed value is ordinary — `$case
    // {$prop tag "none"} 0` reads nothing — so say the slot may go unread
    // rather than silence the warning for the file.
    $decl d2 $if ($call eq_int (xs.head.slot, -1)) () {
      $decl a $call assign (st, $call slot_name (xs.head.slot),
          $if boolish scrut
              ($call concat (scrut, $call concat (".u.m",
                  $call int_to_str ($call IR.ints.nth (ds, 0))))))
      $decl ret2 $call say (st, $call concat ("  (void)",
          $call concat ($call slot_name (xs.head.slot), ";\n")))
    }.ret2
    $decl d3  $call emit_as (st, fi, xs.head.body, dest, want, ts)
    $decl d4  $call say (st, "  } break;\n")
    $decl ret $call emit_cases (st, fi, xs.tail, dest, want, ts, scrut, ms, boolish)
  }.ret,
  $case xs ()
)

// Named from its members' own names, which are stable (`fn_key`), so a table's name is
// a function of the implementation and not of the program.
$decl tbl_key $func ($decl st proto_est, $decl xs IR.ints.node, $decl acc "") $match xs (
  $case {$prop tag "cons"}
    $call tbl_key (st, $call IR.ints.val (xs.tail),
        $call concat (acc, $call concat (",", $call key_at (st, $call res_fn (st, xs.head))))),
  $case xs acc
)

$decl tbl_name $func ($decl st proto_est, $decl xs IR.ints.node)
  $call concat ("mpl_tbl", $call int_to_str ($call T.hash_str ($call tbl_key (st, xs, ""), 0, 0)))

// §4.13: the storage a name already has — a frame slot, a capture in the environment, or
// a global's static (§4.10). `verify` has checked it is one of the three.
$decl addr_of $func ($decl st proto_est, $decl fi 0, $decl x IR.proto_expr) $match x (
  $case {$prop tag "local"}   ($call concat ("&", $call slot_name (x.slot))),
  $case {$prop tag "capture"}
    ($call concat ("&((", $call concat ($call env_name (fi),
        $call concat (" *)env)->c", $call int_to_str (x.slot))))),
  $case {$prop tag "global"}  ($call concat ("&", $call gbl_name (st, x.fn))),
  $case x ($do ($call eerr (st, "an address of something that is not a name")) "0")
)

$decl prim_pairs $func ($decl st proto_est, $decl n "", $decl cs T.tys.node,
                        $decl acc strs.node) $match cs (
  $case {$prop tag "cons"} {
    $decl w    $call prim_wrap (n, $call prim_kind ($call T.tval (cs.head)))
    $decl e    $if ($call eq_str (w, ""))
                   ($call eerr (st, $call concat ("cannot emit the intrinsic ", n))) ()
    $decl ret  $call prim_pairs (st, n, $call T.tys.val (cs.tail), $call strs.cons (
                   $call concat ("(mpl_fun){(void *)", $call concat ($if ($call eq_str (w, ""))
                       "0" w, ", NULL}")), acc))
  }.ret,
  $case cs ($call strs.reverse (acc, strs.nil))
)

$decl emit_expr $func ($decl st proto_est, $decl fi 0, $decl e IR.proto_expr,
                       $decl dest "", $decl ts T.tys.node) $match e (
  $case {$prop tag "int"}
    $call say (st, $call concat ("  ", $call concat (dest,
        $call concat (" = ", $call concat ($call int_to_str (e.v), ";\n"))))),
  // §3.1: a float literal is kept as its source text, which is a valid C double.
  $case {$prop tag "float"} ($call assign (st, dest, e.text)),
  $case {$prop tag "bool"}
    $call say (st, $call concat ("  ", $call concat (dest, $if e.v " = 1;\n" " = 0;\n"))),
  $case {$prop tag "unit"}
    $call say (st, $call concat ("  ", $call concat (dest, " = 0;\n"))),
  $case {$prop tag "str"} ($call assign (st, dest, $call c_str_lit (e.text))),
  $case {$prop tag "local"}
    $call say (st, $call concat ("  ", $call concat (dest,
        $call concat (" = ", $call concat ($call slot_name (e.slot), ";\n"))))),
  // Naming a global is one of two things, and the type says which. A function
  // named as a value is §7.3's pair — and a top-level function captures
  // nothing, so its environment is null, which is what makes the pair two
  // words whatever the signature. Anything else is a top-level `$decl` that
  // was lowered to a thunk and has a static of its own, assigned once by
  // `mpl_init` (§4.10, source order).
  $case {$prop tag "global"}
    // A thunk's index names its static and nothing else (§4.10: one cell,
    // assigned once in source order). Every other global is a function, and a
    // function named as a value is §7.3's pair — with a null environment,
    // because a top-level function captures nothing, which is what makes the
    // pair two words whatever the signature.
    $if ($call is_thunk (st, e.fn)) ($call assign (st, dest, $call gbl_name (st, e.fn)))
        ($do ($call assign (st, $call concat (dest, ".code"),
                  $call concat ("(void *)", $call fn_name (st, e.fn))))
             ($call assign (st, $call concat (dest, ".env"), "NULL"))),
  // §4.15: the root block declares `err` and `none` as prop-only blocks, so a
  // `prim` can stand in value position as well as callee position. With no
  // fields there is nothing to initialise but the placeholder C needs.
  $case {$prop tag "prim"} {
    $decl t $call type_at (ts, e.ty)
    $decl ret $match t (
        $case {$prop tag "block"}
          $if ($call T.fields.is_nil ($call T.fields.val (t.fields)))
              ($call assign (st, dest, $call concat ("(", $call concat ($call c_type (st, ts, e.ty),
                   "){0}"))))
              ($call eerr (st, $call concat ("cannot emit the intrinsic ", e.name))),
        // §7.3: an intrinsic named as a value is the pair, like any other
        // function. §8's arithmetic is emitted infix when it is *called*, so
        // the pair points at a wrapper that exists only to have an address.
        $case {$prop tag "func"} {
          $decl w    $call prim_wrap (e.name, $call prim_kind (t))
          $decl ret2 $if ($call eq_str (w, ""))
              ($call eerr (st, $call concat ("cannot emit the intrinsic ", e.name)))
              ($do ($call assign (st, $call concat (dest, ".code"), $call concat ("(void *)", w)))
                   ($call assign (st, $call concat (dest, ".env"), "NULL")))
        }.ret2,
        // §4.8: an overloaded intrinsic as a value is the group of its candidates,
        // each a pair at its wrapper.
        $case {$prop tag "over"} {
          $decl ws   $call prim_pairs (st, e.name, $call T.tys.val (t.cands), strs.nil)
          $decl ret2 $call assign (st, dest, $call concat ("(", $call concat (
              $call c_type (st, ts, e.ty), $call concat ("){", $call concat (
              $call join_args (ws, "", true), "}")))))
        }.ret2,
        $case t ($call eerr (st, $call concat ("cannot emit the intrinsic ", e.name)))
      )
  }.ret,
  // §4.16: an extern named as a *value* rather than called. §7.3 makes a function
  // value a pair and a C function has no `void *env`, so the pair points at the
  // generated wrapper — the same device §8's operators need, and for the same
  // reason. The environment is `NULL`: a C function has nothing to capture.
  $case {$prop tag "extern"}
    $do ($call assign (st, $call concat (dest, ".code"),
             $call concat ("(void *)", $call xt_sym (st, e.sym))))
        ($call assign (st, $call concat (dest, ".env"), "NULL")),
  $case {$prop tag "call"} ($call emit_call (st, fi, e, dest, ts)),
  $case {$prop tag "if"} {
    $decl c   $call fresh_tmp (st)
    $decl d0  $call say (st, $call concat ("  int64_t ", $call concat (c, ";\n")))
    $decl d1  $call emit_expr (st, fi, e.cond, c, ts)
    $decl d2  $call say (st, $call concat ("  if (", $call concat (c, ") {\n")))
    $decl d3  $call emit_as (st, fi, e.then, dest, e.ty, ts)
    $decl d4  $call say (st, "  } else {\n")
    $decl d5  $call emit_as (st, fi, e.els, dest, e.ty, ts)
    $decl ret $call say (st, "  }\n")
  }.ret,
  $case {$prop tag "do"} {
    $decl tv $call into_tmp (st, fi, e.first, ts)
    // §4.8b runs the first operand for effect and discards it, so C is right
    // that the temporary is never read — say so rather than silence the
    // warning for the whole file.
    $decl d1  $call say (st, $call concat ("  (void)", $call concat (tv, ";\n")))
    $decl ret $call emit_expr (st, fi, e.then, dest, ts)
  }.ret,
  // §4.5: each entry is assigned to its slot in order — a later `$decl` may
  // name an earlier one — and the block's value is the struct of those slots
  // afterwards.
  // §7.2: "Groups are laid out elementwise." Each item into its own temporary
  // first, then the struct literal — the same shape a block gets, and for the
  // same reason: a C initializer cannot hold the statements an item may need.
  $case {$prop tag "group"} {
    $decl ns $call emit_gitems (st, fi, $call IR.exprs.val (e.items), ts, strs.nil)
    $decl ret  $call say (st, $call concat ("  ", $call concat (dest,
        $call concat (" = (", $call concat ($call c_type (st, ts, e.ty),
        $call concat ("){", $call concat ($call join_args (ns, "", true), "};\n")))))))
  }.ret,
  $case {$prop tag "block"} {
    $decl d0 $call emit_slot_inits (st, fi, $call IR.bslots.val (e.slots), ts)
    $decl d1 $call say (st, $call concat ("  ", $call concat (dest,
        $call concat (" = (", $call concat ($call c_type (st, ts, e.ty), "){")))))
    $decl d2  $call emit_slot_reads (st, $call IR.bslots.val (e.slots), true)
    $decl ret $call say (st, "};\n")
  }.ret,
  // §4.6 as a layout position (§7.2).
  $case {$prop tag "field"} {
    $decl tgt $call IR.eval (e.target)
    $decl tv  $call fresh_tmp (st)
    $decl d0  $call say (st, $call concat ("  ", $call concat ($call c_type (st, ts, tgt.ty),
                  $call concat (" ", $call concat (tv, ";\n")))))
    $decl d1  $call emit_expr (st, fi, tgt, tv, ts)
    // §5.1: a union whose members share an ordered prefix has that prefix in
    // common, and C guarantees a common initial sequence is readable through
    // any member of a union of structs — so the first member serves for all
    // of them. Lowering already checked that every member has the field at
    // this position.
    $decl tt  $call T.unroll ($call type_at (ts, tgt.ty))
    $decl thru $match tt (
        $case {$prop tag "union"} $if ($call T.same (tt, T.t_bool)) "" ".u.m0",
        $case tt ""
      )
    $decl ret   $call say (st, $call concat ("  ", $call concat (dest,
                  $call concat (" = ", $call concat (tv, $call concat (thru,
                  $call concat (".f", $call concat ($call int_to_str (e.index), ";\n"))))))))
  }.ret,
  // §4.2: the only way storage comes into existence. §7.4 makes `&T` a thin
  // pointer, so this is one allocation and one store.
  $case {$prop tag "new"} {
    $decl v   $call IR.eval (e.init)
    $decl pid $call pointee_of (st, ts, e.ty)
    // Not a reference type is not supposed to happen; falling back to the
    // operand keeps the old behaviour rather than inventing a worse one.
    $decl wnt $if ($call lt (-1, pid)) pid v.ty
    $decl vt  $call c_type (st, ts, wnt)
    $decl tv  $call decl_tmp (st, ts, wnt)
    $decl d1  $call emit_as (st, fi, v, tv, wnt, ts)
    $decl d0  $call assign (st, dest, $call concat ("(", $call concat (vt,
                  $call concat (" *)mpl_alloc((int64_t)sizeof(", $call concat (vt, "))")))))
    $decl ret   $call say (st, $call concat ("  *", $call concat (dest,
                  $call concat (" = ", $call concat (tv, ";\n")))))
  }.ret,
  // §5.4's implicit read, which lowering made explicit.
  $case {$prop tag "deref"} {
    $decl sv  $call into_tmp (st, fi, e.src, ts)
    $decl ret $call assign (st, dest, $call concat ("*", sv))
  }.ret,
  // §4.4: writes *through* storage, and evaluates to the written value.
  $case {$prop tag "set"} {
    $decl tn $call IR.eval (e.target)
    $decl tg $call into_tmp (st, fi, tn, ts)
    $decl vn $call IR.eval (e.value)
    // What is *stored* is what the storage holds, not what the value node
    // happens to be — §5.1 and §4.8a again. But the node's own type is the
    // **written value's**: §4.4 makes `$set` evaluate to the value written,
    // and both `infer_set` and lowering answer `v.ty`.
    //
    // So the value is built at the node's type and coerced **up** into the
    // storage's, not the other way round. Building it at the storage's type
    // first and coercing from there into the node's went the wrong direction:
    // a member written into union-typed storage needed union -> member, which
    // is a narrowing and not a §7.4 coercion at all, so `emit_inject` emitted
    // *nothing* and the destination slot was left uninitialised. There were
    // five in the compiler's own C — every one a `$decl … $set …` whose
    // enclosing `{ … $decl out e }.out` then read every slot to build its
    // struct, which is reading an uninitialised automatic. `cc -Wall` on the
    // emitted C is what found it; nothing in the morphl suites could.
    $decl pid $call pointee_of (st, ts, tn.ty)
    $decl wnt $if ($call lt (-1, pid)) pid vn.ty
    $decl vl  $call decl_tmp (st, ts, e.ty)
    $decl d1  $call emit_as (st, fi, vn, vl, e.ty, ts)
    $decl up  $call decl_tmp (st, ts, wnt)
    $decl d2  $call emit_inject (st, ts, up, vl, e.ty, wnt)
    $decl d0  $call say (st, $call concat ("  *", $call concat (tg,
                  $call concat (" = ", $call concat (up, ";\n")))))
    // §4.4: the result is the value that was written, at its own type.
    $decl ret   $call assign (st, dest, vl)
  }.ret,
  // §4.7, as §7.5's discriminator test — the one construct that reads runtime
  // type information. Several `case` labels may share a body, because an arm
  // answers for every member no earlier arm claimed.
  // §4.7, as §7.5's discriminator test — the one construct that reads runtime
  // type information. Several `case` labels may share a body, because an arm
  // answers for every member no earlier arm claimed.
  $case {$prop tag "switch"} {
    $decl sc $call IR.eval (e.scrut)
    // §5.5: a `μ` *is* its unrolling, so the members `$match` discriminates
    // over are the unrolling's — and they are in the order
    // `emit_union_struct` laid the C union out in, because both ask
    // `T.unroll` the same question.
    $decl st2 $call T.unroll ($call type_at (ts, sc.ty))
    $decl ret $match st2 (
        $case {$prop tag "union"} {
          $decl sv $call into_tmp (st, fi, sc, ts)
          // §3.2: a boolean is its own discriminator.
          $decl bl $call T.same (st2, T.t_bool)
          $decl ms $call T.tys.val (st2.members)
          $decl d0 $call say (st, $call concat ("  switch ((int)",
                       $call concat (sv, $if bl ") {\n" ".tag) {\n")))
          $decl d1 $call emit_cases (st, fi, $call IR.arms.val (e.arms), dest, e.ty, ts, sv,
                       ms, bl)
          // §5.6 checked exhaustiveness, so nothing reaches this.
          $decl d2   $call say (st, "  default: mpl_panic(\"no $match arm applied\");\n  }\n")
          $decl ret2 ()
        }.ret2,
        // Not a union, so there is no discriminator and no choice: §4.7's
        // first arm covers the whole type.
        $case st2 ($call emit_first_arm (st, fi, $call IR.arms.val (e.arms), dest, e.ty, ts))
      )
  }.ret,
  // §7.3: the captures are copied *here*, where the literal stood, into an
  // environment the pair points at. The struct is anonymous — nothing reads it
  // but the lifted body, which knows its shape from the capture order.
  // §7.3: the pair is a code pointer and an environment. **A literal with no
  // free names has no environment**, and `emit_envs` emits `mpl_env<N>` only for
  // a function that captures — so allocating one unconditionally named a struct
  // that was never declared. Unreached for a long time because every `$func`
  // literal in the compiler's own source captures something; `cc` is what found
  // it, on a `$func` used as a value whose body mentions nothing outside itself.
  $case {$prop tag "closure"} {
    $decl cs $call IR.exprs.val (e.captures)
    $decl en $call env_name (e.fn)
    $decl d2 $call assign (st, $call concat (dest, ".code"),
                 $call concat ("(void *)", $call fn_name (st, e.fn)))
    $decl ret  $if ($call IR.exprs.is_nil (cs))
        ($call assign (st, $call concat (dest, ".env"), "0")) {
          $decl ev $call fresh_tmp (st)
          $decl d0 $call say (st, $call concat ("  ", $call concat (en,
                       $call concat (" *", $call concat (ev,
                       $call concat (" = (", $call concat (en,
                       $call concat (" *)mpl_alloc((int64_t)sizeof(", $call concat (en, "));\n")))))))))
          $decl d1 $call emit_env (st, fi, cs, ev, 0, ts)
          $decl ret2  $call assign (st, $call concat (dest, ".env"),
                       $call concat ("(void *)", ev))
        }.ret2
  }.ret,
  // §6: a trait object is its referent's address and its implementation's table.
  $case {$prop tag "tobj"} {
    $decl rv  $call into_tmp (st, fi, $call IR.eval (e.ref), ts)
    $decl d0  $call assign (st, $call concat (dest, ".ref"), $call concat ("(void *)", rv))
    $decl ret $call assign (st, $call concat (dest, ".tbl"),
                  $call concat ($call tbl_name (st, $call IR.ints.val (e.fns)), "()"))
  }.ret,
  // A member through the object is §7.3's pair: the table's shim, whose environment
  // *is* the referent — so a call is an ordinary indirect call (§10 item 13).
  $case {$prop tag "tmem"} {
    $decl ov  $call into_tmp (st, fi, $call IR.eval (e.obj), ts)
    $decl d0  $call assign (st, $call concat (dest, ".code"),
                  $call concat (ov, $call concat (".tbl[",
                      $call concat ($call int_to_str (e.idx), "]"))))
    $decl ret $call assign (st, $call concat (dest, ".env"), $call concat (ov, ".ref"))
  }.ret,
  $case {$prop tag "addr"}
    ($call assign (st, dest, $call addr_of (st, fi, $call IR.eval (e.src)))),
  // §7.3 again: a capture is read out of the environment the pair carried in.
  $case {$prop tag "capture"}
    $call assign (st, dest, $call concat ("((", $call concat ($call env_name (fi),
        $call concat (" *)env)->c", $call int_to_str (e.slot))))),
  // §4.15: evaluate, and if the discriminator says the pattern matched, inject
  // that member into the function's result and return. Otherwise carry on with
  // what is left — which lowering already computed as this node's type.
  $case {$prop tag "try"} {
    $decl v  $call IR.eval (e.value)
    $decl vt $call type_at (ts, v.ty)
    $decl tv $call into_tmp (st, fi, v, ts)
    $decl ms $match vt ($case {$prop tag "union"} ($call T.tys.val (vt.members)), $case vt T.tys.nil)
    $decl mf $call IR.find_ty (ts, $call T.tys.nth (ms, e.disc))
    $decl rf $call IR.find_ty (ts, $call type_at (ts, e.ty))
    $decl d0 $call say (st, $call concat ("  if ((int)", $call concat (tv,
                 $call concat (".tag == ", $call concat ($call int_to_str (e.disc), ") {\n")))))
    $decl d1 $call emit_inject (st, ts, "ret",
                 $call concat (tv, $call concat (".u.m", $call int_to_str (e.disc))),
                 $if mf.hit mf.id 0, $call P.ival (st.fnres))
    $decl d2 $do ($call emit_return (st)) ($call say (st, "  }\n"))
    // What survives is a single member, so reading it out is the narrowing.
    $decl ret  $call assign (st, dest, $call concat (tv,
                 $call concat (".u.m", $call int_to_str ($call other_disc (ms, e.disc, 0)))))
  }.ret,
  // §7.4's coercion, made explicit by lowering where it could not be left to
  // the use site — `$union`'s value is a member and its type is the union.
  $case {$prop tag "copy"} {
    $decl sv  $call IR.eval (e.src)
    $decl tv  $call into_tmp (st, fi, sv, ts)
    $decl ret $call emit_inject (st, ts, dest, tv, sv.ty, e.ty)
  }.ret,
  $case e ($call eerr (st, $call concat ("cannot emit ", $call IR.show (e))))
)

// -------------------------------------------------------------- functions

$decl emit_params $func ($decl st proto_est, $decl xs IR.ints.node, $decl ts T.tys.node,
                         $decl i 0, $decl first P.boolean) $match xs (
  $case {$prop tag "cons"} {
    $decl d $call say (st, $call concat ($if first "" ", ",
        $call concat ($call c_type (st, ts, xs.head),
        $call concat (" ", $call slot_name (i)))))
    $decl ret $call emit_params (st, xs.tail, ts, $call add (i, 1), false)
  }.ret,
  $case xs ()
)

// The slots past the parameters, each with its own type (§7.2).
$decl emit_slots $func ($decl st proto_est, $decl xs IR.ints.node, $decl ts T.tys.node,
                        $decl i 0, $decl skip 0) $match xs (
  $case {$prop tag "cons"} {
    $decl d $if ($call lt (i, skip)) ()
        ($call say (st, $call concat ("  ", $call concat ($call c_type (st, ts, xs.head),
            $call concat (" ", $call concat ($call slot_name (i), ";\n"))))))
    $decl ret $call emit_slots (st, xs.tail, ts, $call add (i, 1), skip)
  }.ret,
  $case xs ()
)

$decl emit_fn $func ($decl st proto_est, $decl i 0, $decl f IR.proto_fn, $decl ts T.tys.node) {
  $decl np  $call IR.ints.length (f.params, 0)
  // A temporary is a C **local**, so its number need only be unique inside this
  // function — and resetting here is what makes a body's text depend on the body
  // alone. It used to run from one counter across the whole program, so emitting
  // a module later in the walk renamed every temporary in it: `prelude.c` differed
  // between two programs in nothing but `t1955` against `t2115`.
  $decl z0  $set st.ntmp 0
  // `static` unless the function is a module member. §4.14 makes a projection onto a
  // module the only way to name one across that edge, so `pub` is a property of the
  // function alone — which is what lets a module's text be cached on its own source.
  $decl h0  $call say (st, $call concat ($if f.pub "\n" "\nstatic ",
                $call concat ($call c_type (st, ts, f.result),
                $call concat (" ", $call concat ($call fn_name (st, i), "(void *env")))))
  $decl h1 $call emit_params (st, f.params, ts, 0, false)
  $decl h2 $call say (st, $call concat (") {  /* ", $call concat (f.name, " */\n")))
  $decl h3 $call say (st, "  (void)env;\n")
  $decl s0 $call emit_slots (st, $call IR.ints.val (f.slots), ts, 0, np)
  $decl fr $set st.fnres f.result
  // §6a: whether an indirect tail call in this body reports or drives.
  $decl ir0 $set st.inrep ($call reports (st, i))
  $decl r0  $call say (st, $call concat ("  ",
                $call concat ($call c_type (st, ts, f.result), " ret;\n")))
  $decl l0  $if f.self_tail ($call say (st, "  while (1) {\n")) ()
  $decl b0  $call emit_as (st, i, f.body, "ret", f.result, ts)
  $decl r1  $call emit_return (st)
  $decl l1  $if f.self_tail ($call say (st, "  }\n")) ()
  $decl ir1 $set st.inrep false
  $decl ret $call say (st, "}\n")
}.ret

// §6a's mutual case: the group becomes one function with a state variable and
// one dispatch loop, and each member becomes a wrapper that enters at its own
// state — so calls from outside the group are unchanged.
//
// Restricted to a group whose members share a signature, which is what lets one
// parameter list and one `ret` serve them all. A group that does not is left as
// ordinary calls and reported, because emitting it wrongly would be worse.
$decl same_ints $func ($decl a IR.ints.node, $decl b IR.ints.node) $match a (
  $case {$prop tag "cons"}
    $match b (
        $case {$prop tag "cons"}
          $if ($call eq_int (a.head, b.head)) ($call same_ints (a.tail, b.tail)) false,
        $case b false
      ),
  $case a ($call IR.ints.is_nil (b))
)
$decl slot_args $func ($decl xs IR.ints.node, $decl i 0, $decl acc "") $match xs (
  $case {$prop tag "cons"}
    $call slot_args (xs.tail, $call add (i, 1),
        $call concat (acc, $call concat (", ", $call slot_name (i)))),
  $case xs acc
)
$decl grp_name $func ($decl st proto_est) $call concat ("mpl_grp", $call P.sval (st.grpn))

// Set once at the top of each group emitter, from the group's first member's key.
$decl set_grpn $func ($decl st proto_est, $decl g IR.ints.node)
  $set st.grpn ($call key_at (st, $call IR.ints.nth (g, 0)))

$decl fn_at $func ($decl fs IR.fns.node, $decl i 0) ($call em_at (i)).fn

$decl same_sig $func ($decl fs IR.fns.node, $decl g IR.ints.node, $decl p IR.ints.node,
                      $decl res 0) $match g (
  $case {$prop tag "cons"} {
    $decl f $call fn_at (fs, g.head)
    $decl ret $if ($call and ($call eq_int (f.result, res),
                            $call same_ints ($call IR.ints.val (f.params), p)))
                ($call same_sig (fs, g.tail, p, res)) false
  }.ret,
  $case g true
)


$decl emit_member $func ($decl st proto_est, $decl fs IR.fns.node, $decl g IR.ints.node,
                         $decl ts T.tys.node, $decl i 0) $match g (
  $case {$prop tag "cons"} {
    $decl f  $call fn_at (fs, g.head)
    $decl np $call IR.ints.length ($call IR.ints.val (f.params), 0)
    $decl d0 $call say (st, $call concat ("  case ", $call concat ($call int_to_str (i),
                 $call concat (": {  /* ", $call concat (f.name, " */\n")))))
    // The non-parameter slots live in the case's own block, so members do
    // not collide over a slot number.
    $decl d1  $call emit_slots (st, $call IR.ints.val (f.slots), ts, 0, np)
    $decl d2  $call emit_as (st, g.head, f.body, "ret", f.result, ts)
    $decl d3  $do ($call emit_return (st)) ($call say (st, "  }\n"))
    $decl ret $call emit_member (st, fs, g.tail, ts, $call add (i, 1))
  }.ret,
  $case g ()
)

$decl emit_wrappers $func ($decl st proto_est, $decl fs IR.fns.node, $decl g IR.ints.node,
                           $decl gi 0, $decl ts T.tys.node, $decl i 0) $match g (
  $case {$prop tag "cons"} {
    $decl f  $call fn_at (fs, g.head)
    // A group *member* keeps its own name, so another module can call it — `T.same` and
    // `T.sub` are both members of one — and its linkage has to match what the header
    // declared. The group *function* (`mpl_grpN`) stays `static`: it has no name outside
    // this file, because §4.14 keeps a tail-call cycle inside one module.
    $decl h0 $call say (st, $call concat ($if f.pub "\n" "\nstatic ",
                 $call concat ($call c_type (st, ts, f.result),
                 $call concat (" ", $call concat ($call fn_name (st, g.head), "(void *env")))))
    $decl h1 $call emit_params (st, $call IR.ints.val (f.params), ts, 0, false)
    $decl h2 $call say (st, $call concat (") {  /* ", $call concat (f.name, " */\n  return ")))
    $decl h3 $call say (st, $call concat ($call grp_name (st),
                 $call concat ("(env, ", $call concat ($call int_to_str (i),
                 $call concat ($call slot_args ($call IR.ints.val (f.params), 0, ""),
                               ");\n}\n")))))
    $decl ret  $call emit_wrappers (st, fs, g.tail, gi, ts, $call add (i, 1))
  }.ret,
  $case g ()
)


// §6a's *general* case: a group whose members do not share a signature.
//
// The restriction above exists because the fast path gives the group function
// one parameter list and one `ret`, which only serves members that agree. The
// way out is to stop sharing either. Each member gets parameter variables of its
// own — `q<state>_<k>`, so no two members can collide — and the result leaves
// through an out-parameter, because a C function has exactly one return type and
// the members have several. Everything else is the fast path exactly: one
// dispatch loop, a `case` per member holding its body, a wrapper per member
// keeping its name and entering at its own state.
//
// The group function's parameters are therefore *every* member's parameters
// concatenated. A wrapper passes its own arguments in its own positions and a
// zero compound literal everywhere else — the other members' parameters are dead
// on entry at that state, and C needs something there.
//
// A tail call to member j fills `q<j>_*` and `continue`s, and the parallel-update
// problem the fast path has does not arise: a member reads its parameters out of
// `q` into its slots when its `case` is entered, so writing `q` cannot clobber
// what the arguments are being computed from.
$decl emit_qparams $func ($decl st proto_est, $decl xs IR.ints.node, $decl ts T.tys.node,
                          $decl si 0, $decl k 0) $match xs (
  $case {$prop tag "cons"} {
    $decl d $call say (st, $call concat (", ",
        $call concat ($call c_type (st, ts, xs.head),
        $call concat (" ", $call concat ($call qpre (si), $call int_to_str (k))))))
    $decl ret $call emit_qparams (st, xs.tail, ts, si, $call add (k, 1))
  }.ret,
  $case xs ()
)

$decl emit_gparams $func ($decl st proto_est, $decl fs IR.fns.node, $decl g IR.ints.node,
                          $decl ts T.tys.node, $decl si 0) $match g (
  $case {$prop tag "cons"} {
    $decl f   $call fn_at (fs, g.head)
    $decl d   $call emit_qparams (st, $call IR.ints.val (f.params), ts, si, 0)
    $decl ret $call emit_gparams (st, fs, g.tail, ts, $call add (si, 1))
  }.ret,
  $case g ()
)

// §7.2 puts the parameters in the first slots, so a member's `case` declares
// every slot it has and opens by copying the parameters in from its own `q`.
$decl copy_qparams $func ($decl st proto_est, $decl xs IR.ints.node, $decl si 0, $decl k 0)
  $match xs (
    $case {$prop tag "cons"}
      $do ($call say (st, $call concat ("  ", $call concat ($call slot_name (k),
               $call concat (" = ", $call concat ($call qpre (si),
               $call concat ($call int_to_str (k), ";\n")))))))
          ($call copy_qparams (st, xs.tail, si, $call add (k, 1))),
    $case xs ()
  )

$decl emit_member_gen $func ($decl st proto_est, $decl fs IR.fns.node, $decl g IR.ints.node,
                             $decl ts T.tys.node, $decl si 0) $match g (
  $case {$prop tag "cons"} {
    $decl f  $call fn_at (fs, g.head)
    $decl rc $call c_type (st, ts, f.result)
    $decl d0 $call say (st, $call concat ("  case ", $call concat ($call int_to_str (si),
                 $call concat (": {  /* ", $call concat (f.name, " */\n")))))
    $decl d1  $call emit_slots (st, $call IR.ints.val (f.slots), ts, 0, 0)
    $decl d2  $call copy_qparams (st, $call IR.ints.val (f.params), si, 0)
    $decl d3  $call say (st, $call concat ("  ", $call concat (rc, " ret;\n")))
    $decl fr  $set st.fnres f.result
    $decl rr  $set st.retc rc
    $decl d4  $call emit_as (st, g.head, f.body, "ret", f.result, ts)
    $decl d5  $do ($call emit_return (st)) ($call say (st, "  }\n"))
    $decl ret $call emit_member_gen (st, fs, g.tail, ts, $call add (si, 1))
  }.ret,
  $case g ()
)

$decl emit_zeros $func ($decl st proto_est, $decl xs IR.ints.node, $decl ts T.tys.node)
  $match xs (
    $case {$prop tag "cons"}
      $do ($call say (st, $call concat (", (",
               $call concat ($call c_type (st, ts, xs.head), "){0}"))))
          ($call emit_zeros (st, xs.tail, ts)),
    $case xs ()
  )

$decl emit_owns $func ($decl st proto_est, $decl xs IR.ints.node, $decl k 0) $match xs (
  $case {$prop tag "cons"}
    $do ($call say (st, $call concat (", ", $call slot_name (k))))
        ($call emit_owns (st, xs.tail, $call add (k, 1))),
  $case xs ()
)

$decl emit_fillers $func ($decl st proto_est, $decl fs IR.fns.node, $decl g IR.ints.node,
                          $decl ts T.tys.node, $decl si 0, $decl want 0) $match g (
  $case {$prop tag "cons"} {
    $decl f $call fn_at (fs, g.head)
    $decl d $if ($call eq_int (si, want))
        ($call emit_owns (st, $call IR.ints.val (f.params), 0))
        ($call emit_zeros (st, $call IR.ints.val (f.params), ts))
    $decl ret $call emit_fillers (st, fs, g.tail, ts, $call add (si, 1), want)
  }.ret,
  $case g ()
)

$decl emit_wrappers_gen $func ($decl st proto_est, $decl fs IR.fns.node, $decl g IR.ints.node,
                               $decl gi 0, $decl ts T.tys.node, $decl all IR.ints.node,
                               $decl si 0) $match g (
  $case {$prop tag "cons"} {
    $decl f  $call fn_at (fs, g.head)
    $decl rc $call c_type (st, ts, f.result)
    $decl h0 $call say (st, $call concat ($if f.pub "\n" "\nstatic ",
                 $call concat (rc, $call concat (" ",
                 $call concat ($call fn_name (st, g.head), "(void *env")))))
    $decl h1 $call emit_params (st, $call IR.ints.val (f.params), ts, 0, false)
    $decl h2 $call say (st, $call concat (") {  /* ", $call concat (f.name,
                 $call concat (" */\n  ", $call concat (rc, " r;\n  ")))))
    $decl h3 $call say (st, $call concat ($call grp_name (st),
                 $call concat ("(env, ", $call concat ($call int_to_str (si), ", &r"))))
    $decl h4  $call emit_fillers (st, fs, all, ts, 0, si)
    $decl h5  $call say (st, ");\n  return r;\n}\n")
    $decl ret $call emit_wrappers_gen (st, fs, g.tail, gi, ts, all, $call add (si, 1))
  }.ret,
  $case g ()
)

$decl emit_group_gen $func ($decl st proto_est, $decl fs IR.fns.node, $decl g IR.ints.node,
                            $decl gi 0, $decl ts T.tys.node) {
  // One C function for the whole group (§6a), so one reset at its top: the
  // members share its scope, so their temporaries must be unique across the group
  // and need be unique no further.
  $decl z0 $set st.ntmp 0
  $decl z1 $call set_grpn (st, g)
  $decl h0  $call say (st, $call concat ("\nstatic void ",
                $call concat ($call grp_name (st), "(void *env, int64_t state, void *retp")))
  $decl h1  $call emit_gparams (st, fs, g, ts, 0)
  $decl h2  $call say (st, ") {\n  (void)env;\n")
  $decl g0  $set st.grp g
  $decl gn  $set st.gen true
  $decl l0  $call say (st, "  while (1) {\n  switch ((int)state) {\n")
  $decl m0  $call emit_member_gen (st, fs, g, ts, 0)
  $decl l1  $call say (st, "  default: mpl_panic(\"bad state\");\n  }\n  }\n}\n")
  $decl g1  $set st.grp IR.ints.nil
  $decl gn2 $set st.gen false
  $decl rr  $set st.retc ""
  $decl ret $call emit_wrappers_gen (st, fs, g, gi, ts, g, 0)
}.ret

$decl emit_group $func ($decl st proto_est, $decl fs IR.fns.node, $decl g IR.ints.node,
                        $decl gi 0, $decl ts T.tys.node) {
  // One C function for the whole group (§6a), so one reset at its top: the
  // members share its scope, so their temporaries must be unique across the group
  // and need be unique no further.
  $decl z0 $set st.ntmp 0
  $decl z1 $call set_grpn (st, g)
  $decl f0 $call fn_at (fs, $call IR.ints.nth (g, 0))
  $decl np $call IR.ints.length ($call IR.ints.val (f0.params), 0)
  $decl h0  $call say (st, $call concat ("\nstatic ",
                $call concat ($call c_type (st, ts, f0.result),
                $call concat (" ", $call concat ($call grp_name (st), "(void *env, int64_t state")))))
  $decl h1 $call emit_params (st, $call IR.ints.val (f0.params), ts, 0, false)
  $decl h2 $call say (st, ") {\n  (void)env;\n")
  $decl r0  $call say (st, $call concat ("  ",
                $call concat ($call c_type (st, ts, f0.result), " ret;\n")))
  $decl g0  $set st.grp g
  $decl fr  $set st.fnres f0.result
  $decl l0  $call say (st, "  while (1) {\n  switch ((int)state) {\n")
  $decl m0  $call emit_member (st, fs, g, ts, 0)
  $decl l1  $call say (st, "  default: mpl_panic(\"bad state\");\n  }\n  }\n}\n")
  $decl g1  $set st.grp IR.ints.nil
  $decl ret $call emit_wrappers (st, fs, g, gi, ts, 0)
}.ret

// Filtered by module like `emit_fns`, and a group *has* one: §4.14 lowers a module
// against the root block alone, so a module cannot name its importer and a tail-call
// cycle cannot cross that edge — every contified group therefore lives inside one
// module, which is checked (all five of the compiler's own are within `parser`, `types`
// or `emit`). Its module is its lowest member's.
$decl emit_groups $func ($decl st proto_est, $decl fs IR.fns.node, $decl gs IR.groups.node,
                         $decl gi 0, $decl ts T.tys.node, $decl md "") $match gs (
  $case {$prop tag "cons"} {
    $decl g    $call IR.ints.val (gs.head.members)
    $decl f0   $call fn_at (fs, $call IR.ints.nth (g, 0))
    $decl mine $call eq_str (f0.mod, md)
    $decl ok   $call same_sig (fs, g, $call IR.ints.val (f0.params), f0.result)
    // Both paths contify, so §7.7 holds either way; the fast one is kept
    // because it is what the emitted compiler's own hot mutual recursions go
    // through, and a shared signature lets it pass parameters as parameters
    // and return a value as a value.
    $decl d  $if ($call not (mine)) ()
                 ($if ok ($call emit_group (st, fs, g, gi, ts))
                         ($call emit_group_gen (st, fs, g, gi, ts)))
    $decl ret  $call emit_groups (st, fs, $call IR.groups.val (gs.tail), $call add (gi, 1),
                 ts, md)
  }.ret,
  $case gs ()
)

// Forward declarations first: §4.10 is source order, but C needs every callee
// visible before its caller, and a `$fwd` group is mutually recursive by
// construction (§5.5).
// `pub` picks which half. The shared header declares the functions another module names,
// with no `static` because they must be reachable from another translation unit; a
// module's own output declares the rest `static`, because a `static` declaration in the
// header would be a promise every *other* file could not keep.
$decl emit_protos $func ($decl st proto_est, $decl fs IR.fns.node, $decl ts T.tys.node,
                         $decl i 0, $decl md "", $decl pub P.boolean) $match fs (
  $case {$prop tag "cons"} {
    $decl ex   fs.head.pub
    $decl mine $if pub ex ($if ex false ($call eq_str (fs.head.mod, md)))
    $decl h0 $if ($call not (mine)) ()
        ($call say (st, $call concat ($if pub "" "static ",
            $call concat ($call c_type (st, ts, fs.head.result),
            $call concat (" ", $call concat ($call fn_name (st, i), "(void *env"))))))
    $decl h1 $if mine ($call emit_params (st, fs.head.params, ts, 0, false)) ()
    $decl h2 $if mine ($call say (st, ");\n")) ()
    $decl ret  $call emit_protos (st, $call IR.fns.val (fs.tail), ts, $call add (i, 1),
                 md, pub)
  }.ret,
  $case fs ()
)

// One static per thunk, and one assignment each in source order (§4.10). A
// later global may name an earlier one, and index order is source order, so
// running them in order is all it takes.
// §4.10's statics, **declared** in the header and **defined once** beside the `mpl_init`
// that assigns them. `static` was right while there was one output and is wrong with
// several: each file would take a private copy, and `mpl_init` would assign its own while
// every other module read a zero. Defining them all in one place also keeps `mpl_init`
// whole — a `static` global could only be assigned from its own file, which is what would
// force an `mpl_init` per module.
$decl emit_globals $func ($decl st proto_est, $decl fs IR.fns.node, $decl ts T.tys.node,
                          $decl i 0, $decl decl_only P.boolean) $match fs (
  $case {$prop tag "cons"} {
    $decl d $if fs.head.thunk
        ($call say (st, $call concat ($if decl_only "extern " "",
            $call concat ($call c_type (st, ts, fs.head.result),
            $call concat (" ", $call concat ($call gbl_name (st, i),
            $call concat (";  /* ", $call concat (fs.head.name, " */\n")))))))) ()
    $decl ret $call emit_globals (st, $call IR.fns.val (fs.tail), ts, $call add (i, 1),
                decl_only)
  }.ret,
  $case fs ()
)

// §3.3's top-level expressions, at their position in §4.10's order. `after` is
// how many globals precede one, so everything with `after` equal to the global
// about to be assigned runs first. The result is dropped — that is what "and is
// discarded" means — and `(void)` says so to a C compiler that might warn.
// The whole list is scanned at every index rather than consumed as it goes: a
// file and each module it imports both append here, so the entries are not in
// `after` order and a walk that kept its place would stop at the first one out
// of turn. There are a handful of effects against a few thousand functions, so
// the cost is nothing and the independence is worth having.
$decl same_bool $func ($decl a P.boolean, $decl b P.boolean) $if a b ($call not (b))

// `inmod` selects which numbering this pass is walking: a module's effects count
// lifted indices and a file's count fields, and the two collide at `fnbase`
// (`IR.effect` says why). Without it a trailing bare expression in the entry
// file would fire in the module pass, which is before the globals it is meant to
// run after.
// An effect belongs to the module its *function* was lowered in, which is how it finds
// its way into that module's initialiser.
// `all` is the **whole** function table, not the suffix `emit_inits` is walking: an
// effect's `fn` is a global index, and indexing a suffix with one is out of range. That
// is what an empty emitted file and a missing `main` turned out to be.
$decl emit_effects $func ($decl st proto_est, $decl all IR.fns.node,
                          $decl es    IR.effects.node, $decl i 0,
                          $decl inmod P.boolean, $decl md "") $match es (
  $case {$prop tag "cons"}
    $do ($if ($call and ($call eq_int (es.head.after, i),
                  $call and ($call same_bool (es.head.inmod, inmod),
                             $call eq_str (($call fn_at (all, es.head.fn)).mod, md))))
             ($call say (st, $call concat ("  (void)",
                 $call concat ($call fn_name (st, es.head.fn), "(NULL);\n"))))
             ())
        ($call emit_effects (st, all, $call IR.effects.val (es.tail), i, inmod, md)),
  $case es ()
)

// One pass over the table, assigning the thunks whose index falls in `[glo, ghi)`
// and running the effects of the matching kind. The effects need no window of
// their own: `inmod` already separates them, and each fires at the single `i`
// its `after` names.
// `md` narrows this to one module's own globals and effects, which is what lets each
// module carry its own `mpl_init_<mod>`. The index window and `inmod` stay: they encode
// *which numbering* `after` is in — a file's effect counts fields and a module's counts
// lifted indices, and the two spaces meet at `fnbase` — and §4.10's order here has
// already been got wrong once silently (`stage1/fixtures/init_order.mpl`, answer 106).
// Adding a filter beside them changes which entries a pass acts on and nothing about the
// order it acts in.
$decl emit_inits $func ($decl st proto_est, $decl all IR.fns.node, $decl fs IR.fns.node,
                        $decl es IR.effects.node,
                        $decl i  0, $decl glo 0, $decl ghi 0, $decl inmod P.boolean,
                        $decl md "") $match fs (
  $case {$prop tag "cons"} {
    $decl e    $call emit_effects (st, all, es, i, inmod, md)
    $decl w    $if ($call lt (i, glo)) false ($call lt (i, ghi))
    $decl mine $call eq_str (fs.head.mod, md)
    $decl d $if ($call and (w, $call and (mine, fs.head.thunk)))
        ($call assign (st, $call gbl_name (st, i), $call concat ($call fn_name (st, i), "(NULL)"))) ()
    $decl ret $call emit_inits (st, all, $call IR.fns.val (fs.tail), es, $call add (i, 1),
                glo, ghi, inmod, md)
  }.ret,
  $case fs ($call emit_effects (st, all, es, i, inmod, md))
)



// A module's initialiser, in **source order**: §4.10 initialises a `$decl` once, in the
// order it is written, and an effect runs between the members around it.
//
// This used to be `emit_inits` over the table in index order, on the claim that a
// module's members are lifted in source order so index order already is source order.
// Lowering does lift them eagerly in source order — but a `$fwd`'d function is lowered
// at the `$fwd`'s position, and its body may name members written later, so lowering it
// lifts those first, and whatever *their* initialisers name after them:
//
//   $fwd f
//   $decl a 5
//   $decl b $call add (a, 1)   // assigned before `a`, so it read 0
//   $decl f $func () b
//
// answered 1 where stage 0 answers 6, with no diagnostic. A member's `rank` is its
// position among the module's items (`prop_rank`) and a module effect's `after` is its
// position too (`lower_effect`), so sorting on those is source order however the table
// came to be numbered. Only a member is ranked that way, which `pub` says; any other
// thunk placed in a module follows in index order, as before.
$decl ient       $func ($decl k 0, $decl e P.boolean,
    $decl i 0) { $decl key k  $decl eff e  $decl idx i }
$decl proto_ient $call ient (0, false, 0)
$decl ients      $specialize P.list proto_ient

$decl ient_insert $func ($decl x proto_ient, $decl xs ients.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call lt (x.key, xs.head.key)) ($call ients.cons (x, xs))
        ($call ients.cons (xs.head, $call ient_insert (x, $call ients.val (xs.tail)))),
  $case xs ($call ients.cons (x, ients.nil))
)

$decl init_thunks $func ($decl fs IR.fns.node, $decl i 0, $decl md "", $decl ranked P.boolean,
                         $decl acc ients.node) $match fs (
  $case {$prop tag "cons"} {
    $decl f  fs.head
    $decl ok $if ($call and (f.thunk, $call eq_str (f.mod,
        md))) ($if ranked f.pub ($call not (f.pub))) false
    $decl a   $if ok ($call ient_insert ($call ient ($if ranked f.rank i, false, i), acc)) acc
    $decl ret $call init_thunks ($call IR.fns.val (fs.tail), $call add (i, 1), md, ranked, a)
  }.ret,
  $case fs acc
)

$decl init_effects $func ($decl all IR.fns.node, $decl es IR.effects.node, $decl md "",
                          $decl acc ients.node) $match es (
  $case {$prop tag "cons"} {
    $decl ok  $if es.head.inmod ($call eq_str (($call fn_at (all, es.head.fn)).mod, md)) false
    $decl a   $if ok ($call ient_insert ($call ient (es.head.after, true, es.head.fn), acc)) acc
    $decl ret $call init_effects (all, $call IR.effects.val (es.tail), md, a)
  }.ret,
  $case es acc
)

$decl emit_ients $func ($decl st proto_est, $decl xs ients.node) $match xs (
  $case {$prop tag "cons"}
    $do ($if xs.head.eff
             ($call say (st, $call concat ("  (void)", $call concat ($call fn_name (st, xs.head.idx), "(NULL);\n"))))
             ($call assign (st, $call gbl_name (st, xs.head.idx),
                 $call concat ($call fn_name (st, xs.head.idx), "(NULL)"))))
        ($call emit_ients (st, $call ients.val (xs.tail))),
  $case xs ()
)

$decl emit_mod_init $func ($decl st proto_est, $decl all IR.fns.node, $decl es IR.effects.node,
    $decl md "") {
  $decl ranked $call init_effects (all, es, md, $call init_thunks (all, 0, md, true, ients.nil))
  $decl a      $call emit_ients (st, ranked)
  $decl ret    $call emit_ients (st, $call init_thunks (all, 0, md, false, ients.nil))
}.ret

// `md` is the module whose bodies this pass emits — §9.1's list of outputs means one
// file per module, and a function's `mod` is what says which. The *index* stays global,
// because a name comes from `st.fnames` by index and every file must agree on it.
$decl emit_fns $func ($decl st proto_est, $decl fs IR.fns.node, $decl ts T.tys.node,
                      $decl i 0, $decl gs IR.groups.node, $decl md "") $match fs (
  $case {$prop tag "cons"} {
    $decl mine $call eq_str (fs.head.mod, md)
    $decl d $if ($call not (mine)) ()
        ($if ($call in_a_group (gs, i)) () ($call emit_fn (st, i, fs.head, ts)))
    $decl ret $call emit_fns (st, $call IR.fns.val (fs.tail), ts, $call add (i, 1), gs, md)
  }.ret,
  $case fs ()
)

// The `main` a hosted C program needs: whichever top-level `$decl` was named
// `main`, printed. §9 leaves the entry point to the build program; this is the
// stand-in that makes an emitted file runnable.
$decl append_ofiles $func ($decl xs IR.ofiles.node, $decl ys IR.ofiles.node) $match xs (
  $case {$prop tag "cons"}
    $call IR.ofiles.cons (xs.head, $call append_ofiles ($call IR.ofiles.val (xs.tail), ys)),
  $case xs ys
)

$decl has_str $func ($decl xs strs.node, $decl n "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head, n)) true ($call has_str (xs.tail, n)),
  $case xs false
)

// The modules this program is made of, in the order they first appear, with the entry
// file's own ("") left out — it is emitted last, because it is the one that holds
// `mpl_init` and `main`.
$decl mods_of $func ($decl fs IR.fns.node, $decl acc strs.node) $match fs (
  $case {$prop tag "cons"} {
    $decl m fs.head.mod
    $decl a $if ($call eq_str (m, "")) acc
                ($if ($call has_str ($call strs.val (acc), m)) acc ($call strs.cons (m, acc)))
    $decl ret $call mods_of ($call IR.fns.val (fs.tail), a)
  }.ret,
  $case fs ($call strs.reverse (acc, strs.nil))
)

// **In the order the modules' loading completed, which `IR.program.mods` carries.** Not
// the order their functions appear in the table: a module's `$import` member takes its
// index before the imported module's members are lifted, so index order puts the
// importer *first* and its initialiser then reads a static its dependency has not
// assigned yet. That was a SIGFPE at startup — `mpl_init_infer` before
// `mpl_init_types`, dividing by a zero `hmod`.
//
// Filtered to the modules that actually have an output, so a call can never name an
// `mpl_init_<mod>` that was never defined.
$decl emit_mod_calls $func ($decl st proto_est, $decl ms strs.node, $decl have strs.node)
  $match ms (
  $case {$prop tag "cons"} {
    $decl ok $call has_str (have, ms.head)
    $decl a  $if ok ($call say (st, $call concat ("  mpl_init_",
                 $call concat (ms.head, "();\n")))) ()
    $decl ret  $call emit_mod_calls (st, $call strs.val (ms.tail), have)
  }.ret,
  $case ms ()
)

// Declared in the shared header, because the entry file's `mpl_init` calls them and they
// are defined in another translation unit.
$decl emit_mod_init_decls $func ($decl st proto_est, $decl ms strs.node) $match ms (
  $case {$prop tag "cons"}
    $do ($call say (st, $call concat ("void mpl_init_", $call concat (ms.head, "(void);\n"))))
        ($call emit_mod_init_decls (st, ms.tail)),
  $case ms ()
)

// One output per module: that module's function bodies and its contified groups, and
// nothing else — every declaration is in the header, which is what makes the outputs
// valid to concatenate *and* separately compilable.
$decl emit_mod_files $func ($decl st proto_est, $decl fs IR.fns.node, $decl ts T.tys.node,
                            $decl gs  IR.groups.node, $decl ms strs.node,
                            $decl efs IR.effects.node, $decl fb 0, $decl nf 0,
                            $decl acc IR.ofiles.node) $match ms (
  $case {$prop tag "cons"} {
    $decl pr $call emit_protos (st, fs, ts, 0, ms.head, false)
    $decl d0 $call emit_fns (st, fs, ts, 0, gs, ms.head)
    $decl d1 $call emit_groups (st, fs, gs, 0, ts, ms.head)
    // This module's own initialiser: §4.10's source order over *its* globals and
    // effects. It exists so a module's thunks and effect functions can stay private —
    // the one initialiser in the entry file had to be able to call every one of them,
    // which is what forced 269 extra exports.
    $decl j0 $call say (st, $call concat ("\nvoid mpl_init_", $call concat (ms.head,
                  "(void) {\n")))
    $decl j1 $call emit_mod_init (st, fs, $call IR.effects.val (efs), ms.head)
    $decl j2 $call say (st, "}\n")
    $decl f  $call IR.ofile ($call concat (ms.head, ".c"), $call cut_out (st))
    $decl ret  $call emit_mod_files (st, fs, ts, gs, ms.tail, efs, fb, nf,
                 $call IR.ofiles.cons (f, acc))
  }.ret,
  $case ms ($call IR.ofiles.reverse (acc, IR.ofiles.nil))
)

// How many functions need external linkage, for the header's comment. A count over the
// bits, not a walk over bodies — which is the whole of what changed.
$decl pub_count $func ($decl fs IR.fns.node, $decl acc 0) $match fs (
  $case {$prop tag "cons"}
    $call pub_count ($call IR.fns.val (fs.tail), $if fs.head.pub ($call add (acc, 1)) acc),
  $case fs acc
)

$decl find_main $func ($decl fs IR.fns.node, $decl i 0) $match fs (
  $case {$prop tag "cons"}
    $if ($call eq_str (fs.head.name, "main")) i
        ($call find_main ($call IR.fns.val (fs.tail), $call add (i, 1))),
  $case fs -1
)

// ------------------------------------------------------------- §6's tables
//
// One table per distinct implementation — a list of member functions in the trait's
// order — found by walking every body, as `xt_of` finds §4.16's symbols. An entry is a
// **shim** with the ordinary calling convention whose `env` is the referent: it builds
// the member's own environment from it, the reference itself for a `$mut` receiver or
// a copy of the value for a read-only one (§4.10), and calls the member. So a member
// through an object is a pair like any other function value, and the table holds no
// captures (§10 item 13). A table is a function returning its array, because a static
// array a translation unit does not use is a warning where a static function is not.

$decl itabs $specialize P.list IR.ints.node

$decl is_ref_c $func ($decl t T.proto_ty) $match t ($case {$prop tag "ref"} true, $case t false)

$decl ints_eq $func ($decl xs IR.ints.node, $decl ys IR.ints.node) $match xs (
  $case {$prop tag "cons"} $match ys (
      $case {$prop tag "cons"}
        $if ($call eq_int (xs.head, ys.head))
            ($call ints_eq ($call IR.ints.val (xs.tail), $call IR.ints.val (ys.tail))) false,
      $case ys false),
  $case xs ($call IR.ints.is_nil (ys))
)

$decl has_tab $func ($decl xs itabs.node, $decl t IR.ints.node) $match xs (
  $case {$prop tag "cons"} $if ($call ints_eq (xs.head, t)) true ($call has_tab (xs.tail, t)),
  $case xs false
)

$fwd tobs_of

$decl tobs_list $func ($decl xs IR.exprs.node, $decl acc itabs.node) $match xs (
  $case {$prop tag "cons"}
    $call tobs_list ($call IR.exprs.val (xs.tail), $call tobs_of (xs.head, acc)),
  $case xs acc
)

$decl tobs_slots $func ($decl xs IR.bslots.node, $decl acc itabs.node) $match xs (
  $case {$prop tag "cons"}
    $call tobs_slots ($call IR.bslots.val (xs.tail), $call tobs_of (xs.head.init, acc)),
  $case xs acc
)

$decl tobs_arms $func ($decl xs IR.arms.node, $decl acc itabs.node) $match xs (
  $case {$prop tag "cons"}
    $call tobs_arms ($call IR.arms.val (xs.tail), $call tobs_of (xs.head.body, acc)),
  $case xs acc
)

$decl tobs_of $func ($decl e IR.proto_expr, $decl acc itabs.node) $match e (
  $case {$prop tag "tobj"} {
    $decl fs  $call IR.ints.val (e.fns)
    $decl a2  $if ($call has_tab (acc, fs)) acc ($call itabs.cons (fs, acc))
    $decl ret $call tobs_of ($call IR.eval (e.ref), a2)
  }.ret,
  $case {$prop tag "tmem"}    ($call tobs_of ($call IR.eval (e.obj), acc)),
  $case {$prop tag "addr"}    ($call tobs_of ($call IR.eval (e.src), acc)),
  $case {$prop tag "field"}   ($call tobs_of ($call IR.eval (e.target), acc)),
  $case {$prop tag "new"}     ($call tobs_of ($call IR.eval (e.init), acc)),
  $case {$prop tag "deref"}   ($call tobs_of ($call IR.eval (e.src), acc)),
  $case {$prop tag "copy"}    ($call tobs_of ($call IR.eval (e.src), acc)),
  $case {$prop tag "try"}     ($call tobs_of ($call IR.eval (e.value), acc)),
  $case {$prop tag "set"}
    $call tobs_of ($call IR.eval (e.value), $call tobs_of ($call IR.eval (e.target), acc)),
  $case {$prop tag "do"}
    $call tobs_of ($call IR.eval (e.then), $call tobs_of ($call IR.eval (e.first), acc)),
  $case {$prop tag "if"}
    $call tobs_of ($call IR.eval (e.els),
        $call tobs_of ($call IR.eval (e.then), $call tobs_of ($call IR.eval (e.cond), acc))),
  $case {$prop tag "call"}
    $call tobs_list ($call IR.exprs.val (e.args), $call tobs_of ($call IR.eval (e.callee), acc)),
  $case {$prop tag "group"}   ($call tobs_list ($call IR.exprs.val (e.items), acc)),
  $case {$prop tag "closure"} ($call tobs_list ($call IR.exprs.val (e.captures), acc)),
  $case {$prop tag "block"}   ($call tobs_slots ($call IR.bslots.val (e.slots), acc)),
  $case {$prop tag "switch"}
    $call tobs_of ($call IR.eval (e.default),
        $call tobs_arms ($call IR.arms.val (e.arms), $call tobs_of ($call IR.eval (e.scrut), acc))),
  $case e acc
)

$decl tobs_of_fns $func ($decl fs IR.fns.node, $decl acc itabs.node) $match fs (
  $case {$prop tag "cons"}
    $call tobs_of_fns ($call IR.fns.val (fs.tail), $call tobs_of (fs.head.body, acc)),
  $case fs acc
)

$decl tsh_name $func ($decl st proto_est, $decl i 0)
  $call concat ("mpl_tsh", $call key_at (st, $call res_fn (st, i)))

$decl shim_args $func ($decl n 0, $decl i 0, $decl acc "")
  $if ($call lt (i, n)) ($call shim_args (n, $call add (i, 1),
      $call concat (acc, $call concat (", ", $call slot_name (i)))))
      acc

// A trait object's referent is the receiver, so the environment a member reads is
// built from it: a `$mut` receiver is the reference (§4.10), a read-only one a copy.
$decl emit_shim $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0) {
  $decl k   $call res_fn (st, i)
  $decl f   $call fn_at (IR.fns.nil, k)
  $decl ps  $call IR.ints.val (f.params)
  $decl ev  $call IR.ints.val (f.env)
  $decl d0  $call say (st, $call concat ("static ", $call concat ($call c_type (st, ts, f.result),
                $call concat (" ", $call concat ($call tsh_name (st, i), "(void *env")))))
  $decl d1  $call emit_params (st, ps, ts, 0, false)
  $decl d2  $call say (st, ") {\n")
  $decl as  $call shim_args ($call IR.ints.length (ps, 0), 0, "")
  $decl ret $match ev (
      $case {$prop tag "cons"} {
        $decl ct   $call c_type (st, ts, ev.head)
        $decl rf   $call is_ref_c ($call T.tval ($call type_at (ts, ev.head)))
        $decl ld   $if rf ($call concat ("(", $call concat (ct, ")env;\n")))
                       ($call concat ("*(", $call concat (ct, " *)env;\n")))
        $decl d3   $call say (st, $call concat ("  ", $call concat ($call env_name (k),
                       $call concat (" e; e.c0 = ", ld))))
        $decl ret2 $call say (st, $call concat ("  return ", $call concat ($call fn_name (st, k),
                       $call concat ("(&e", $call concat (as, ");\n}\n")))))
      }.ret2,
      $case ev $call say (st, $call concat ("  (void)env;\n  return ", $call concat (
          $call fn_name (st, k), $call concat ("(NULL", $call concat (as, ");\n}\n")))))
    )
}.ret

$decl shims_add $func ($decl xs IR.ints.node, $decl acc IR.ints.node) $match xs (
  $case {$prop tag "cons"}
    $call shims_add ($call IR.ints.val (xs.tail),
        $if ($call mem_int (acc, xs.head)) acc ($call IR.ints.cons (xs.head, acc))),
  $case xs acc
)

$decl shims_of $func ($decl xs itabs.node, $decl acc IR.ints.node) $match xs (
  $case {$prop tag "cons"} $call shims_of (xs.tail, $call shims_add (xs.head, acc)),
  $case xs acc
)

$decl emit_shims $func ($decl st proto_est, $decl ts T.tys.node, $decl xs IR.ints.node)
    $match xs (
  $case {$prop tag "cons"}
    $do ($call emit_shim (st, ts, xs.head))
        ($call emit_shims (st, ts, $call IR.ints.val (xs.tail))),
  $case xs ()
)

$decl tbl_entries $func ($decl st proto_est, $decl xs IR.ints.node, $decl acc "") $match xs (
  $case {$prop tag "cons"}
    $call tbl_entries (st, $call IR.ints.val (xs.tail),
        $call concat (acc, $call concat ($if ($call eq_str (acc, "")) "" ", ",
        $call concat ("(void *)", $call tsh_name (st, xs.head))))),
  $case xs acc
)

$decl emit_tbls $func ($decl st proto_est, $decl xs itabs.node) $match xs (
  $case {$prop tag "cons"} {
    $decl es  $call tbl_entries (st, xs.head, "")
    $decl d0  $call say (st, $call concat ("static void *const *", $call concat (
                  $call tbl_name (st, xs.head), $call concat (
                  "(void) {\n  static void *const t[] = { ",
                  $call concat ($if ($call eq_str (es, "")) "0" es, " };\n  return t;\n}\n")))))
    $decl ret $call emit_tbls (st, xs.tail)
  }.ret,
  $case xs ()
)

$decl emit_tables $func ($decl st proto_est, $decl ts T.tys.node, $decl xs itabs.node)
  $do ($call emit_shims (st, ts, $call shims_of (xs, IR.ints.nil))) ($call emit_tbls (st, xs))

// Whether any trait type is interned — so that a program without one emits exactly
// what it did before trait objects existed.
$decl has_trait $func ($decl ts T.tys.node) $match ts (
  $case {$prop tag "cons"}
    $if ($call T.is_trait ($call T.tval (ts.head))) true
        ($call has_trait ($call T.tys.val (ts.tail))),
  $case ts false
)

$decl emit_program $func ($decl st proto_est, $decl p IR.proto_program) {
  $decl ts $call T.tys.val (p.types)
  $decl fs $call IR.fns.val (p.funcs)
  // Before anything is emitted: every name comes from here.
  $decl nms $set st.fnames ($call fn_keys (fs, strs.nil))
  // And every lookup by index — `fn_at`, `key_at`, `type_at` — from these.
  $decl fx $set em_fnix ($call ft_fill ($call ft_leaf (fents.nil), fs, $call strs.val (st.fnames),
      0))
  $decl tx $set em_tyix ($call IR.ix_of (ts))
  $decl tk $set st.thunks ($call thunk_ids (fs, 0, IR.ints.nil))
  // Before anything is emitted: `res_fn` is asked at every global callee.
  $decl al $set st.aliases ($call collect_aliases (fs, 0, fnals.nil))
  $decl gs $call IR.groups.val (p.groups)
  // §6a's indirect case, both halves of it, before any body is emitted: a call
  // site has to know whether its callee reports, and the driver's switch has to
  // know every signature it may be handed.
  $decl rp $set st.reps ($call reporter_ids (st, fs, gs, 0, IR.ints.nil))
  $decl sg $set st.tsigs ($call all_tail_sigs (st, fs, IR.ints.nil))
  // Reported in the artifact: how much of the program needs external linkage under
  // the local rule. It is a whole-program figure and lives in the shared header,
  // which is the one output that is a whole-program artifact anyway.
  $decl xp $call pub_count (fs, 0)
  $decl nf $call IR.fns.length (fs, 0)
  $decl hx $call say (st, $call concat ("/* cross-module references: ",
               $call concat ($call int_to_str (xp), $call concat (" of ",
               $call concat ($call int_to_str (nf), " functions */\n")))))
  $decl h   $call say (st, $call concat (runtime_c, "\n"))
  $decl tro $call has_trait (ts)
  $decl tty $if tro ($call say (st,
                "/* 7.2: a trait object - the referent and its implementation (6). */\ntypedef struct { void *ref; void *const *tbl; } mpl_tobj;\n\n"))
                ()
  $decl sd  $call emit_structs (st, ts, ts, 0)
  $decl gap $call say (st, "\n")
  // §9.1's first output: everything a *shared* header holds — the runtime and §7.2's
  // layouts. Split here because this is exactly the part that is not any one module's:
  // every file needs the struct for a type it touches, and with content-derived names
  // two files spell the same type the same way, so C is content to see the definition
  // in each translation unit that includes this.
  // §4.16's declarations and wrappers, before anything that may call one. They go
  // after the structs, because a signature may name one, and before the prototypes.
  $decl xs  $call emit_xts (st, ts, $call xts_of_fns (fs, xts.nil))
  $decl d0  $call emit_protos (st, fs, ts, 0, "", true)
  $decl tr  $call emit_tramp (st, ts)
  $decl en  $call emit_envs (st, fs, ts, 0)
  $decl tb  $if tro ($call emit_tables (st, ts, $call tobs_of_fns (fs, itabs.nil))) ()
  $decl gv  $call emit_globals (st, fs, ts, 0, true)
  $decl mid $call emit_mod_init_decls (st, $call mods_of (fs, strs.nil))
  // §9.1's first output. Everything above is a *declaration* — the runtime, §7.2's
  // layouts, §4.16's extern decls, every prototype, §6a's driver, the capture structs
  // and §4.10's statics — and every declaration has to precede every definition both
  // for the outputs to be valid concatenated and for each to compile on its own.
  $decl hdr $call cut_out (st)
  // One output per imported module, then the entry file's own below. A module's
  // functions are *not* a contiguous range of the table — loading one module can load
  // another partway through a member — so each pass walks the whole table and keeps
  // what is its own, which costs a scan per module and nothing else.
  $decl nfn0 $call IR.fns.length (fs, 0)
  $decl mods $call mods_of (fs, strs.nil)
  $decl mfs $call emit_mod_files (st, fs, ts, gs, mods,
                $call IR.effects.val (p.effs), p.fnbase, nfn0, IR.ofiles.nil)
  $decl ep $call emit_protos (st, fs, ts, 0, "", false)
  $decl eg $call emit_globals (st, fs, ts, 0, false)
  $decl e0 $call emit_fns (st, fs, ts, 0, gs, "")
  $decl e1 $call emit_groups (st, fs, gs, 0, ts, "")
  // §4.10 in two passes, and the order between them is the whole point.
  // `$import` evaluates the module's block where it stands, so everything that
  // was *lifted* — a module's members above all — is initialised before the
  // entry file's own globals, not after them as index order would have it. §4.10
  // makes the coarseness exact: an item can only name what precedes it, so a
  // file global can only depend on an import declared above it, and §4.14
  // lowers a module against the root block alone so no module member can
  // depend on the importer at all.
  $decl nfn $call IR.fns.length (fs, 0)
  $decl i0  $call say (st, "\nstatic void mpl_init(void) {\n")
  // Each module's initialiser first, in the order their loading **completed**, then
  // the entry file's own globals. The order comes from `IR.program.mods`, recorded by
  // lowering, and is *not* derived from the table: this comment used to claim that a
  // module's first index is lower than its importer's, and it is the other way round —
  // the importer's `$import` member takes its index before the imported module's
  // members are lifted. See `emit_mod_calls`.
  $decl i1 $call emit_mod_calls (st, $call IR.strs.val (p.mods), mods)
  $decl i1b $call emit_inits (st, fs, fs, $call IR.effects.val (p.effs), 0, 0, p.fnbase,
                 false, "")
  $decl i2  $call say (st, "}\n")
  $decl mi  $call find_main (fs, 0)
  $decl mfn $if ($call lt (mi, 0)) IR.proto_fn ($call IR.fns.nth (fs, mi))
  // §9 leaves the entry point to the build program; this prints whichever of
  // `Int` or `Str` the entry returns, which is as far as a stand-in goes.
  $decl mt  $if ($call lt (mi, 0)) T.t_bot ($call type_at (ts, mfn.result))
  // Guarded on `mi`, and it did not need to be until names became a *lookup*.
  // §7.1 makes morphl strict, so this `$decl` is built on every emit including one
  // with no `main` — harmless while the name was `concat ("mpl_f", int_to_str (-1))`
  // and a panic now that it indexes `st.fnames`. Same shape as the `$decl bad
  // $call concat (…T.show…)` that used to render two types at every coercion:
  // a `$decl` is not a branch.
  // §6a: a `main` whose body ends in a tail call through a value *reports* it and
  // returns a placeholder, like any reporting function — and every other caller of one
  // drives the pending call afterwards. The entry point has to as well, or the program
  // prints the placeholder.
  $decl drv  $if ($call lt (mi, 0)) false ($call reports (st, mi))
  $decl ct   $if ($call T.same (mt, T.t_str)) "mpl_str" "int64_t"
  $decl call $if ($call lt (mi, 0)) "" ($call concat ($call fn_name (st, mi), "(NULL)"))
  $decl val  $if drv "mpl_r" call
  $decl pre  $if drv
      ($call concat ("  ", $call concat (ct, $call concat (" mpl_r = ", $call concat (call,
          ";\n  mpl_tcdrive(&mpl_r);\n"))))) ""
  $decl body $if ($call lt (mi, 0)) ""
      ($call concat (pre, $if ($call T.same (mt, T.t_str))
          ($call concat ("  mpl_print(", $call concat (val, ");\n")))
          ($call concat ("  printf(\"%lld\\n\", (long long)", $call concat (val, ");\n")))))
  $decl d2 $if ($call lt (mi, 0))
      ($call eerr (st, "no top-level $decl named 'main'"))
      ($call say (st, $call concat ($call concat ("\n", $call concat (runtime_state,
           // §6a's pending block, when there is one: shared state, so defined once.
           $if ($call IR.ints.is_nil ($call IR.ints.val (st.tsigs))) ""
               "int mpl_tc = 0;\nint mpl_tc_tag = 0;\nmpl_fun mpl_tc_fn;\nmpl_tcargs mpl_tc_args;\n")),
           $call concat ("\nint main(int argc, char **argv) {\n  mpl_argc = argc;\n  mpl_argv = argv;\n  mpl_init();\n",
           $call concat (body, "  return 0;\n}\n")))))
  // One entry for now: the shape §9.1 asks for, with the split still to come, so
  // the text is byte-for-byte what a single-artifact emit produced before.
  // The body, and for now one of it: the per-module split is the next slice, and
  // keeping the content in one piece here makes this step's output byte-for-byte what
  // a single artifact already was.
  // The entry file's output holds `mpl_init` and `main`, which is why it is last and
  // why it is the one place `runtime_state` is defined.
  $decl bdy $call cut_out (st)
  $decl ret   $call IR.ofiles.cons ($call IR.ofile ("mpl.h", hdr),
                $call append_ofiles (mfs,
                    $call IR.ofiles.cons ($call IR.ofile ("main.c", bdy), IR.ofiles.nil)))
}.ret
