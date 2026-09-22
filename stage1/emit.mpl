// Typed tree → C (BOOTSTRAP.md stage 1, the last piece).
//
// **Statements, not expressions.** A morphl `$if` is an expression and C's is a
// statement, so every node is emitted as statements that assign into a
// destination variable the caller declared. Emitting expressions instead would
// work until §7.7: a tail call has to become `continue`, which is a statement
// and cannot sit inside a `?:`.
//
// **§6a's cheap case is the one implemented here.** A direct self tail call
// becomes `while (1)` with `continue`, and the parameters are updated *in
// parallel* — every new argument into a temporary first, then assigned — or
// `$call f (b, a)` would clobber `b` before reading it. The mutual and indirect
// cases (contification, trampoline) are not emitted yet; a tail call to another
// function is emitted as an ordinary call, which is correct but does not keep
// §7.7's guarantee.
//
// **Coverage: the Int subset.** `Int`, the booleans and unit, which all become
// `int64_t`; literals, slots, calls, `$if`, `$do`, and §8's arithmetic and
// comparisons. Blocks, `Str`, storage and closures are refused by name rather
// than mis-emitted — `emit_errs` is not empty when that happens, and the C is
// not worth compiling.

$decl P  $import "prelude"
$decl T  $import "types"
$decl Pa $import "parser"
$decl IR $import "ir"

$decl not P.not
$decl and P.and

$decl strs $specialize P.list ""

// ------------------------------------------------------------------- state

$decl estate $func ()
  { $decl out  $mut $alloc ""
    $decl ntmp $mut $alloc 0
    // The result type of the function being emitted. §4.15 returns from it
    // from arbitrary depth, so the type has to be reachable from anywhere in
    // the body rather than threaded through every node.
    $decl fnres $mut $alloc 0
    // The group being emitted, if any: §6a merges a mutually tail-recursive
    // set into one function, so a tail call to a member is a state change
    // rather than a call.
    $decl grp   $mut $alloc IR.ints.node
    // Which globals are thunks. A thunk's index names a *static* holding a
    // value, not a function to call — so naming one is reading `mpl_g<i>`, and
    // calling one is an indirect call through the pair that static holds.
    $decl thunks $mut $alloc IR.ints.node
    // The struct definitions already written. A type is defined after
    // everything it contains *by value*, which is not index order — a `μ` is
    // interned before the members it embeds, because they name it.
    $decl emitted $mut $alloc IR.ints.node
    $decl errs $mut $alloc Pa.diags.node }

$decl proto_est $call estate ()

$decl eval_diags $func ($decl x Pa.diags.node) x

$decl emit_errs $func ($decl st proto_est) $call eval_diags (st.errs)

$decl out_of $func ($decl st proto_est) $call P.sval (st.out)

$decl say $func ($decl st proto_est, $decl s "")
  { $decl w $set st.out ($call concat ($call P.sval (st.out), s))
    $decl r () }.r

$decl eerr $func ($decl st proto_est, $decl m "")
  { $decl noted $set st.errs ($call Pa.diags.cons ($call Pa.diag (m, 0, 0, ""),
                                                   $call eval_diags (st.errs)))
    $decl r () }.r

// A fresh C temporary. Declared where it is used, so it lives in the C block
// the value is produced in — which is the block its destination lives in too.
$decl fresh_tmp $func ($decl st proto_est)
  { $decl i $call P.ival (st.ntmp)
    $decl n $set st.ntmp ($call add (i, 1))
    $decl r $call concat ("t", $call int_to_str (i)) }.r

$decl slot_name $func ($decl i 0) $call concat ("s", $call int_to_str (i))
$decl gbl_name  $func ($decl i 0) $call concat ("mpl_g", $call int_to_str (i))
$decl fn_name   $func ($decl i 0) $call concat ("mpl_f", $call int_to_str (i))

// The C side of §8's string intrinsics.
//
// §3.1 makes a `Str` a pointer and a length, immutable and always valid UTF-8 —
// so `slice` shares the bytes and costs nothing, while `concat` and
// `int_to_str` have to put their result somewhere. That somewhere is `malloc`
// and never `free`, which is stage 0's model exactly (BOOTSTRAP.md §3) and what
// §7.6's regions are meant to replace.
$decl runtime_c "#include <stdint.h>\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n\ntypedef struct { const char *p; int64_t n; } mpl_str;\n\n/* A function value is a code pointer and an environment, two words whatever\n   its signature (7.3): captures belong to the body, not to the type. */\ntypedef struct { void *code; void *env; } mpl_fun;\n\nstatic _Noreturn void mpl_panic(const char *m) { fputs(m, stderr); fputc('\\n', stderr); abort(); }\n\nstatic char *mpl_alloc(int64_t n) {\n  char *p = (char *)malloc((size_t)(n > 0 ? n : 1));\n  if (!p) mpl_panic(\"out of memory\");\n  return p;\n}\n\nstatic mpl_str mpl_concat(mpl_str a, mpl_str b) {\n  char *p = mpl_alloc(a.n + b.n);\n  memcpy(p, a.p, (size_t)a.n);\n  memcpy(p + a.n, b.p, (size_t)b.n);\n  return (mpl_str){ p, a.n + b.n };\n}\n\nstatic int64_t mpl_str_eq(mpl_str a, mpl_str b) {\n  return a.n == b.n && memcmp(a.p, b.p, (size_t)a.n) == 0;\n}\n\nstatic int64_t mpl_len(mpl_str s) { return s.n; }\n\nstatic mpl_str mpl_slice(mpl_str s, int64_t i, int64_t j) {\n  if (i < 0 || j < i || j > s.n) mpl_panic(\"slice: out of range\");\n  return (mpl_str){ s.p + i, j - i };\n}\n\nstatic int64_t mpl_byte(mpl_str s, int64_t i) {\n  if (i < 0 || i >= s.n) mpl_panic(\"byte: index out of range\");\n  return (int64_t)(unsigned char)s.p[i];\n}\n\nstatic mpl_str mpl_int_to_str(int64_t v) {\n  char buf[24];\n  int k = snprintf(buf, sizeof buf, \"%lld\", (long long)v);\n  char *p = mpl_alloc(k);\n  memcpy(p, buf, (size_t)k);\n  return (mpl_str){ p, k };\n}\n\nstatic int64_t mpl_print(mpl_str s) {\n  fwrite(s.p, 1, (size_t)s.n, stdout);\n  return 0;\n}\n\n/* 8's arithmetic and comparisons are C operators, so they have no address. A\n   value of function type is a pair (7.3), and a pair needs one - `$decl isub\n   sub` is an intrinsic used as a value, which the compiler's own sources do.\n   These are that address, and nothing else calls them: a *call* to an\n   intrinsic is still emitted infix. */\n#define MPL_BINOP(n, op) \\\n  static int64_t mpl_fn_##n(void *env, int64_t a, int64_t b) { (void)env; return a op b; }\nMPL_BINOP(add, +)\nMPL_BINOP(sub, -)\nMPL_BINOP(mul, *)\nMPL_BINOP(div, /)\nMPL_BINOP(mod, %)\nMPL_BINOP(lt, <)\nMPL_BINOP(eq_int, ==)\n#undef MPL_BINOP\n\n/* 7.8: `panic` aborts. It takes a morphl `Str`, which is bytes and not a C\n   string (3.1), so it is written out by length rather than by NUL. The return\n   type is a lie the call site needs and the body never tells: nothing after a\n   call to this runs. */\nstatic int64_t mpl_panic_str(mpl_str s) {\n  fwrite(s.p, 1, (size_t)s.n, stderr);\n  fputc('\\n', stderr);\n  abort();\n}\n"

// ------------------------------------------------------------------- types
//
// Everything in this subset is a machine word. §7.2's real layout — a block as
// a C struct in `$decl` order — is what the next slice adds; refusing by name
// is better than emitting a struct whose fields nothing yet writes.

$decl type_at $func ($decl ts T.tys.node, $decl i 0) $call T.tys.nth (ts, i)

$decl ty_name $func ($decl i 0) $call concat ("mpl_t", $call int_to_str (i))

// A type's C spelling, by its interned index — the index is the struct's name,
// which is the whole point of interning (§5.1: one index per distinct type).
$fwd c_type

$decl c_scalar $func ($decl st proto_est, $decl t T.proto_ty)
  $if ($call T.same (t, T.t_int))   "int64_t"
  ($if ($call T.same (t, T.t_bool)) "int64_t"
  ($if ($call T.same (t, T.t_true)) "int64_t"
  ($if ($call T.same (t, T.t_false)) "int64_t"
  ($if ($call T.same (t, T.t_str))  "mpl_str"
  ($if ($call T.same (t, T.t_unit)) "int64_t"
  // §7.8: `panic` aborts, so it is a terminator and its type is ⊥ — the type
  // of an expression that does not return. No value ever has it, so the C
  // type is only a placeholder for a slot nothing will ever read.
  ($if ($call T.same (t, T.t_bot))  "int64_t"
    { $decl e $call eerr (st, $call concat ("cannot emit the type ", $call T.show (t)))
      $decl r "int64_t" }.r))))))

$decl c_type $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0)
  { $decl t   $call type_at (ts, i)
    $decl out $match t (
        // §7.2: a block is a C struct in `$decl` order.
        $case {$prop tag "block"} ($call ty_name (i)),
        // §5.5's `μ` is laid out as its unrolling, under its own index's name:
        // one struct however the type was spelled, which is what makes the
        // index a C struct name at all.
        $case {$prop tag "rec"} ($call ty_name (i)),
        // §7.2: "Groups are laid out elementwise" — a struct whose members
        // have positions instead of names, which is what `.n` indexes.
        $case {$prop tag "group"} ($call ty_name (i)),
        // §7.5: a value of union type carries a discriminator, and that is the
        // only construct that reads it (§4.7). Except `Bool` — §3.2 makes it
        // the union `true | false`, but its discriminator *is* its value, which
        // is what lets `$if` take one as a condition.
        $case {$prop tag "union"}
          $if ($call T.same (t, T.t_bool)) "int64_t" ($call ty_name (i)),
        // §7.3: every function value has the same shape, which is what lets a
        // function-typed slot have a size at all (§7.2).
        $case {$prop tag "func"} "mpl_fun",
        // §7.4: `&T` and `&mut T` are thin pointers.
        $case {$prop tag "ref"}
          { $decl f $call IR.find_ty (ts, $call T.tval (t.inner))
            $decl r $if f.hit ($call concat ($call c_type (st, ts, f.id), " *"))
                { $decl e $call eerr (st, "a reference to a type that was never interned")
                  $decl x "int64_t *" }.x }.r,
        $case t ($call c_scalar (st, t))
      ) }.out

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
       ""))))))

// §7.2: the layout is the `$decl` order, and props occupy no space — so the
// struct is exactly the fields, named by position rather than by their morphl
// names, which need not be C identifiers.
$decl emit_fields $func ($decl st proto_est, $decl ts T.tys.node, $decl fs T.fields.node,
                         $decl i 0) $match fs (
  $case {$prop tag "cons"}
    { $decl f $call IR.find_ty (ts, fs.head.ty)
      $decl d $call say (st, $call concat (" ",
          $call concat ($if f.hit ($call c_type (st, ts, f.id)) "int64_t",
          $call concat (" f", $call concat ($call int_to_str (i), ";")))))
      $decl r $call emit_fields (st, ts, fs.tail, $call add (i, 1)) }.r,
  $case fs ()
)

$decl emit_members $func ($decl st proto_est, $decl ts T.tys.node, $decl ms T.tys.node,
                          $decl i 0) $match ms (
  $case {$prop tag "cons"}
    { $decl f $call IR.find_ty (ts, ms.head)
      $decl d $call say (st, $call concat (" ",
          $call concat ($if f.hit ($call c_type (st, ts, f.id)) "int64_t",
          $call concat (" m", $call concat ($call int_to_str (i), ";")))))
      $decl r $call emit_members (st, ts, ms.tail, $call add (i, 1)) }.r,
  $case ms ()
)

$decl eval_ints $func ($decl x IR.ints.node) x

$decl mem_int $func ($decl xs IR.ints.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_int (xs.head, i)) true ($call mem_int ($call IR.ints.val (xs.tail), i)),
  $case xs false
)

// Which types get a C struct of their own.
$decl is_structy $func ($decl t T.proto_ty) $match t (
  $case {$prop tag "block"} true,
  // §3.2 makes `Bool` the union `true | false`, but its discriminator *is* its
  // value, so it stays an `int64_t` and gets no struct.
  $case {$prop tag "union"} ($call not ($call T.same (t, T.t_bool))),
  $case {$prop tag "rec"}   true,
  $case {$prop tag "group"} true,
  $case t false
)

// Every struct is declared before any is defined, so a field that is a
// *pointer* to one needs nothing else — §5.5 makes every recursive edge a
// pointer, which is what keeps the definitions themselves acyclic.
$decl emit_fwds $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0) $match ts (
  $case {$prop tag "cons"}
    { $decl d $if ($call is_structy ($call T.tval (ts.head)))
          ($call say (st, $call concat ("typedef struct ", $call concat ($call ty_name (i),
               $call concat (" ", $call concat ($call ty_name (i), ";\n")))))) ()
      $decl r $call emit_fwds (st, $call T.tys.val (ts.tail), $call add (i, 1)) }.r,
  $case ts ()
)

$decl mark_emitted $func ($decl st proto_est, $decl i 0)
  { $decl m $set st.emitted ($call IR.ints.cons (i, $call eval_ints (st.emitted)))
    $decl r 0 }.r

$fwd emit_struct_at

// A type this one contains *by value*, so it has to be defined first. A `ref`
// is not one: it is a pointer, and the forward declaration covers it.
$decl emit_dep_tys $func ($decl st proto_est, $decl all T.tys.node, $decl xs T.tys.node)
  $match xs (
    $case {$prop tag "cons"}
      { $decl f $call IR.find_ty (all, xs.head)
        $decl d $if f.hit ($call emit_struct_at (st, all, f.id)) 0
        $decl r $call emit_dep_tys (st, all, $call T.tys.val (xs.tail)) }.r,
    $case xs 0
  )

$decl emit_dep_flds $func ($decl st proto_est, $decl all T.tys.node, $decl xs T.fields.node)
  $match xs (
    $case {$prop tag "cons"}
      { $decl f $call IR.find_ty (all, xs.head.ty)
        $decl d $if f.hit ($call emit_struct_at (st, all, f.id)) 0
        $decl r $call emit_dep_flds (st, all, $call T.fields.val (xs.tail)) }.r,
    $case xs 0
  )

$decl emit_gfields $func ($decl st proto_est, $decl ts T.tys.node, $decl xs T.tys.node,
                          $decl i 0) $match xs (
  $case {$prop tag "cons"}
    { $decl f $call IR.find_ty (ts, xs.head)
      $decl d $call say (st, $call concat (" ",
          $call concat ($if f.hit ($call c_type (st, ts, f.id)) "int64_t",
          $call concat (" f", $call concat ($call int_to_str (i), ";")))))
      $decl r $call emit_gfields (st, ts, xs.tail, $call add (i, 1)) }.r,
  $case xs ()
)

$decl emit_group_struct $func ($decl st proto_est, $decl all T.tys.node,
                               $decl its T.tys.node, $decl i 0)
  { $decl d $call emit_dep_tys (st, all, its)
    $decl h $call say (st, $call concat ("struct ", $call concat ($call ty_name (i),
                 $call concat (" {", $if ($call T.tys.is_nil (its)) " char unit;" ""))))
    $decl f $call emit_gfields (st, all, its, 0)
    $decl e $call say (st, " };\n") }.e

$decl emit_block_struct $func ($decl st proto_est, $decl all T.tys.node,
                               $decl fs T.fields.node, $decl i 0)
  { $decl d $call emit_dep_flds (st, all, fs)
    $decl h $call say (st, $call concat ("struct ", $call concat ($call ty_name (i),
                 $call concat (" {", $if ($call T.fields.is_nil (fs)) " char unit;" ""))))
    $decl f $call emit_fields (st, all, fs, 0)
    $decl e $call say (st, " };\n") }.e

// §7.5's discriminator plus the members, which is what `$match` tests and
// nothing else reads.
$decl emit_union_struct $func ($decl st proto_est, $decl all T.tys.node,
                               $decl ms T.tys.node, $decl i 0)
  { $decl d $call emit_dep_tys (st, all, ms)
    $decl h $call say (st, $call concat ("struct ", $call concat ($call ty_name (i),
                 " { int64_t tag; union {")))
    $decl m $call emit_members (st, all, ms, 0)
    $decl e $call say (st, " } u; };\n") }.e

// Marked *before* the dependencies are walked, which is what stops a cycle —
// and §5.5's guardedness is why marking early cannot emit a type before
// something it embeds: every recursive edge is a pointer, so it is not an
// embedding.
$decl emit_struct_at $func ($decl st proto_est, $decl all T.tys.node, $decl i 0)
  $if ($call mem_int ($call eval_ints (st.emitted), i)) ()
      { $decl t $call T.tval ($call type_at (all, i))
        $decl m $call mark_emitted (st, i)
        // A type still holding a §5.5 placeholder was derived in a type-only
        // position (§5.7) whose tree was discarded — it is in the table only
        // because interning is unconditional, and nothing at run time has it.
        // Skipped rather than failed on; `c_type` still refuses it if
        // something live turns out to name it.
        $decl d $if ($call T.has_var (t, 0)) () ($match t (
            $case {$prop tag "block"}
              ($call emit_block_struct (st, all, $call T.fields.val (t.fields), i)),
            $case {$prop tag "group"}
              ($call emit_group_struct (st, all, $call T.tys.val (t.items), i)),
            $case {$prop tag "union"}
              $if ($call T.same (t, T.t_bool)) ()
                  ($call emit_union_struct (st, all, $call T.tys.val (t.members), i)),
            // §5.5: a `μ` is laid out as its unrolling, under its own name.
            // The unrolling's parts were interned when the `μ` was, so they
            // have names of their own to be referred to by.
            $case {$prop tag "rec"}
              { $decl u $call T.unroll (t)
                $decl r $match u (
                    $case {$prop tag "block"}
                      ($call emit_block_struct (st, all, $call T.fields.val (u.fields), i)),
                    $case {$prop tag "union"}
                      ($call emit_union_struct (st, all, $call T.tys.val (u.members), i)),
                    $case u ()
                  ) }.r,
            $case t ()
          ))
        $decl r () }.r

$decl emit_defs $func ($decl st proto_est, $decl ts T.tys.node, $decl all T.tys.node,
                       $decl i 0) $match ts (
  $case {$prop tag "cons"}
    $do ($call emit_struct_at (st, all, i))
        ($call emit_defs (st, $call T.tys.val (ts.tail), all, $call add (i, 1))),
  $case ts ()
)

$decl emit_structs $func ($decl st proto_est, $decl ts T.tys.node, $decl all T.tys.node,
                          $decl i 0)
  $do ($call emit_fwds (st, ts, 0)) ($call emit_defs (st, ts, all, 0))

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
  ($if ($call eq_str (n, "print"))     "mpl_print"
  ($if ($call eq_str (n, "panic"))     "mpl_panic_str"
       "")))))))

// A morphl `Str` is bytes, not a C string: it may hold a NUL, a quote or a
// newline, and it is not terminated. Every byte goes out as a three-digit
// octal escape — `\x` would be wrong, because C lets a hex escape run on into
// the next character if that happens to be a hex digit.
$decl oct3 $func ($decl b 0)
  $call concat ("\\", $call concat ($call int_to_str ($call div (b, 64)),
      $call concat ($call int_to_str ($call mod ($call div (b, 8), 8)),
                    $call int_to_str ($call mod (b, 8)))))

$decl c_bytes $func ($decl s "", $decl i 0, $decl acc "")
  $if ($call not ($call lt (i, $call len (s)))) acc
      ($call c_bytes (s, $call add (i, 1),
          $call concat (acc, $call oct3 ($call byte (s, i)))))

$decl c_str_lit $func ($decl s "")
  $call concat ("(mpl_str){\"", $call concat ($call c_bytes (s, 0, ""),
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

$decl member_slot $func ($decl ms T.tys.node, $decl t T.proto_ty)
  { $decl k $call member_index (ms, t, 0)
    $decl r $if ($call lt (k, 0)) ($call member_sub_index (ms, t, 0)) k }.r

$decl block_is $func ($decl t0 T.proto_ty)
  { $decl t $call T.unroll (t0)
    $decl r $match t ($case {$prop tag "block"} true, $case t false) }.r

$decl block_fields $func ($decl t0 T.proto_ty)
  { $decl t $call T.unroll (t0)
    $decl r $match t (
        $case {$prop tag "block"} ($call T.fields.val (t.fields)),
        $case t T.fields.nil
      ) }.r

// A union's members, after §5.5's unrolling. Empty when the type is not one.
$decl union_members $func ($decl t0 T.proto_ty)
  { $decl t $call T.unroll (t0)
    $decl r $match t (
        $case {$prop tag "union"} ($call T.tys.val (t.members)),
        $case t T.tys.nil
      ) }.r

// The function-pointer type a call through a closure is cast to. §7.3 gives
// every function the same value shape, so the signature has to come from the
// static type at the call site — which is exactly what it is for.
$decl sig_params $func ($decl st proto_est, $decl ts T.tys.node, $decl ps T.tys.node,
                        $decl acc "") $match ps (
  $case {$prop tag "cons"}
    { $decl f $call IR.find_ty (ts, ps.head)
      $decl r $call sig_params (st, ts, $call T.tys.val (ps.tail),
                  $call concat (acc, $call concat (", ",
                      $if f.hit ($call c_type (st, ts, f.id)) "int64_t"))) }.r,
  $case ps acc
)

$decl fn_sig $func ($decl st proto_est, $decl ts T.tys.node, $decl i 0)
  { $decl t $call type_at (ts, i)
    $decl r $match t (
        $case {$prop tag "func"}
          { $decl rf $call IR.find_ty (ts, $call T.tval (t.result))
            $decl o  $call concat ("(", $call concat (
                $if rf.hit ($call c_type (st, ts, rf.id)) "int64_t",
                $call concat ("(*)(void *",
                $call concat ($call sig_params (st, ts, $call T.tys.val (t.params), ""),
                              "))")))) }.o,
        $case t "(int64_t(*)(void *))"
      ) }.r

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
$decl emit_retag_arms $func ($decl st proto_est, $decl dest "", $decl src "",
                             $decl fs T.tys.node, $decl ws T.tys.node, $decl i 0,
                             $decl boolish P.boolean, $decl wt T.proto_ty) $match fs (
  $case {$prop tag "cons"}
    { $decl k  $call member_slot (ws, fs.head)
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
               $call concat (" accepts ", $call T.show (fs.head))))))
          { $decl a $call assign (st, $call concat (dest, ".tag"), $call int_to_str (k))
            $decl b $if boolish 0
                ($call assign (st, $call concat (dest,
                     $call concat (".u.m", $call int_to_str (k))),
                     $call concat (src, $call concat (".u.m", $call int_to_str (i)))))
            $decl c 0 }.c)
      $decl d2 $call say (st, "  break;\n")
      $decl r  $call emit_retag_arms (st, dest, src, $call T.tys.val (fs.tail), ws,
                   $call add (i, 1), boolish, wt) }.r,
  $case fs ()
)

$decl emit_retag $func ($decl st proto_est, $decl dest "", $decl src "",
                        $decl ft T.proto_ty, $decl fs T.tys.node, $decl ws T.tys.node,
                        $decl wt T.proto_ty)
  { $decl bl $call T.same (ft, T.t_bool)
    $decl d0 $call say (st, $call concat ("  switch ((int)",
                 $call concat (src, $if bl ") {\n" ".tag) {\n")))
    $decl d1 $call emit_retag_arms (st, dest, src, fs, ws, 0, bl, wt)
    // The source's tag is always one of its own members, so this is as
    // unreachable as §5.6 makes a `$match`'s default.
    $decl d2 $call say (st, "  default: mpl_panic(\"bad discriminator\");\n  }\n")
    $decl r  () }.r

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
$decl prefix_thru $func ($decl t0 T.proto_ty)
  { $decl t $call T.unroll (t0)
    $decl r $match t (
        $case {$prop tag "block"} "b",
        $case {$prop tag "union"} $if ($call T.same (t, T.t_bool)) "" "u",
        $case t ""
      ) }.r

$decl emit_inject $func ($decl st proto_est, $decl ts T.tys.node, $decl dest "",
                         $decl src "", $decl from 0, $decl want 0)
  { $decl wt $call type_at (ts, want)
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
    $decl k $if free -1 ($call member_slot (ws, ft))
    $decl bad $call concat ("cannot coerce ", $call concat ($call T.show (ft),
                  $call concat (" to ", $call T.show (wt))))
    // §7.8 again: coercing *from* ⊥ is coercing something that never arrives.
    // The code is unreachable — `mpl_panic` does not return — so there is
    // nothing to write and nothing to complain about.
    $decl from_bot $call T.same (ft, T.t_bot)
    // A *block* on the right is §7.4's prefix copy, whichever shape the source
    // is — and it has to be tested before the union cases, since a union on the
    // left is a re-tag only when the target is a union too.
    $decl wf $call block_fields (wt)
    $decl how $if ($call block_is (wt)) ($call prefix_thru (ft)) ""
    $decl r $if free ($call assign (st, dest, src))
        ($if from_bot ()
        ($if ($call not ($call eq_str (how, "")))
             ($call emit_prefix_copy (st, dest, src, $if ($call eq_str (how, "u")) ".u.m0" "",
                  $call T.fields.length (wf, 0), 0))
        ($if ($call not ($call T.tys.is_nil (fs)))
             ($if ($call T.tys.is_nil (ws)) ($call eerr (st, bad))
                  ($call emit_retag (st, dest, src, ft, fs, ws, wt)))
        ($if ($call lt (k, 0)) ($call eerr (st, bad))
            { $decl a $call assign (st, $call concat (dest, ".tag"), $call int_to_str (k))
              $decl b $call assign (st, $call concat (dest,
                          $call concat (".u.m", $call int_to_str (k))), src) }.b)))) }.r

// Emit `e` into `dest`, injecting into a union first if `e` is a member of one
// — which is where subsumption shows up, at an `$if` or `$match` arm.
$decl emit_as $func ($decl st proto_est, $decl fi 0, $decl e IR.proto_expr,
                     $decl dest "", $decl want 0, $decl ts T.tys.node)
  $if ($call eq_int (e.ty, want)) ($call emit_expr (st, fi, e, dest, ts))
      { $decl tv $call fresh_tmp (st)
        $decl d0 $call say (st, $call concat ("  ", $call concat ($call c_type (st, ts, e.ty),
                     $call concat (" ", $call concat (tv, ";\n")))))
        $decl d1 $call emit_expr (st, fi, e, tv, ts)
        $decl r  $call emit_inject (st, ts, dest, tv, e.ty, want) }.r

$decl into_tmp $func ($decl st proto_est, $decl fi 0, $decl e IR.proto_expr, $decl ts T.tys.node)
  { $decl tv $call fresh_tmp (st)
    $decl d0 $call say (st, $call concat ("  ", $call concat ($call c_type (st, ts, e.ty),
                 $call concat (" ", $call concat (tv, ";\n")))))
    $decl d1 $call emit_expr (st, fi, e, tv, ts)
    $decl r  tv }.r

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
  $case {$prop tag "cons"}
    { $decl want $match ps (
          $case {$prop tag "cons"}
            { $decl f $call IR.find_ty (ts, ps.head)
              $decl w $if f.hit f.id xs.head.ty }.w,
          $case ps xs.head.ty
        )
      $decl tv $call fresh_tmp (st)
      $decl d1 $call say (st, $call concat ("  ", $call concat ($call c_type (st, ts, want),
                   $call concat (" ", $call concat (tv, ";\n")))))
      $decl d2 $call emit_as (st, fi, xs.head, tv, want, ts)
      $decl rest $match ps ($case {$prop tag "cons"} ($call T.tys.val (ps.tail)), $case ps T.tys.nil)
      $decl r  $call emit_args (st, fi, $call IR.exprs.val (xs.tail), rest, ts,
                   $call strs.cons (tv, acc)) }.r,
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
$decl assign_slots $func ($decl st proto_est, $decl xs strs.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    { $decl d $call say (st, $call concat ("  ", $call concat ($call slot_name (i),
          $call concat (" = ", $call concat (xs.head, ";\n")))))
      $decl r $call assign_slots (st, xs.tail, $call add (i, 1)) }.r,
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
  $call mem_int ($call eval_ints (st.thunks), i)

$decl thunk_ids $func ($decl fs IR.fns.node, $decl i 0, $decl acc IR.ints.node) $match fs (
  $case {$prop tag "cons"}
    $call thunk_ids ($call IR.fns.val (fs.tail), $call add (i, 1),
        $if fs.head.thunk ($call IR.ints.cons (i, acc)) acc),
  $case fs acc
)

$decl tail_state $func ($decl st proto_est, $decl c IR.proto_expr, $decl fi 0) $match c (
  $case {$prop tag "global"}
    { $decl g $if ($call is_thunk (st, c.fn)) IR.ints.nil ($call IR.ints.val (st.grp))
      $decl s $call state_of (g, c.fn, 0)
      // -1: not a loop at all. -2: this very function, so the state does not
      // change. Otherwise the state to jump to.
      $decl r $if ($call eq_int (s, -1)) ($if ($call eq_int (c.fn, fi)) -2 -1) s }.r,
  $case c -1
)

// A call to a global is direct only when that global is a *function*. A
// top-level `$decl` that is not a `$func` — `$decl and P.and`, an alias — is a
// thunk, and its index names the static, not something to call. Calling it is
// an indirect call through the function value that static holds (§7.3), which
// is the branch below.
$decl is_global $func ($decl st proto_est, $decl c IR.proto_expr) $match c (
  $case {$prop tag "global"} ($call not ($call is_thunk (st, c.fn))),
  $case c false
)

$decl callee_name $func ($decl c IR.proto_expr) $match c (
  $case {$prop tag "global"} ($call fn_name (c.fn)),
  $case c "0"
)

// The call shape, since narrowing does not cross a call (§5.7).
$decl proto_call $call IR.e_call (0, $call IR.e_unit (0), IR.exprs.nil, false)

$decl emit_call $func ($decl st proto_est, $decl fi 0, $decl e proto_call,
                       $decl dest "", $decl ts T.tys.node)
  { $decl cal $call IR.eval (e.callee)
    $decl cty $call type_at (ts, cal.ty)
    $decl ps  $match cty ($case {$prop tag "func"} ($call T.tys.val (cty.params)), $case cty T.tys.nil)
    $decl as  $call emit_args (st, fi, $call IR.exprs.val (e.args), ps, ts, strs.nil)
    $decl out $match cal (
        // §8's operators inline; nothing else in the root block has a C form
        // this slice can emit.
        $case {$prop tag "prim"}
          { $decl op $call prim_op (cal.name)
            $decl cf $call prim_fn (cal.name)
            $decl r  $if ($call not ($call eq_str (op, "")))
                ($call assign (st, dest, $call binop_expr (as, op)))
              ($if ($call not ($call eq_str (cf, "")))
                ($call assign (st, dest, $call prim_call (cf, as)))
                ($call eerr (st, $call concat ("cannot emit the intrinsic ", cal.name)))) }.r,
        $case cal
          // §6a: a direct self tail call is the loop; anything else is a plain
          // call, which is correct but is not §7.7's guarantee.
          { $decl ts2 $if e.tail ($call tail_state (st, cal, fi)) -1
            $decl o $if ($call eq_int (ts2, -1))
              ($if ($call is_global (st, cal))
                  ($call assign (st, dest, $call call_expr ($call callee_name (cal), as)))
                  // §7.3: through the pair. The signature comes from the static
                  // type at the call site, since every function value has the
                  // same shape and carries none of it.
                  { $decl fv $call into_tmp (st, fi, cal, ts)
                    // §6a's third case. A tail call through a function *value*
                    // cannot become a loop — the target is unknown until run
                    // time — and its answer is a trampoline, which needs every
                    // function to return "a value or a pending call" and so a
                    // calling convention this backend does not have. A plain
                    // call is correct but not §7.7's guarantee, so it is marked
                    // in the output rather than left to look eliminated.
                    $decl mk $if e.tail
                        ($call say (st, "  /* tail call through a value: not eliminated (6a) */\n")) ()
                    $decl r  $call assign (st, dest,
                        $call indirect_call ($call fn_sig (st, ts, cal.ty), fv, as)) }.r)
                // §6a: the parameters are updated *in parallel* — every new
                // argument is already in a temporary — then the loop re-enters,
                // at another member's state if this is a mutual call.
                { $decl a $call assign_slots (st, as, 0)
                  $decl b $if ($call eq_int (ts2, -2)) ()
                      ($call assign (st, "state", $call int_to_str (ts2)))
                  $decl c $call say (st, "  continue;\n") }.c }.o
      ) }.out

// §7.2: "Groups are laid out elementwise." Each item is evaluated into a
// temporary of its own first, because an item may need statements and a C
// initializer cannot hold one — the same reason a block is built this way.
$decl emit_gitems $func ($decl st proto_est, $decl fi 0, $decl xs IR.exprs.node,
                         $decl ts T.tys.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"}
    { $decl nm $call fresh_tmp (st)
      $decl d0 $call say (st, $call concat ("  ", $call concat ($call c_type (st, ts, xs.head.ty),
                   $call concat (" ", $call concat (nm, ";\n")))))
      $decl d1 $call emit_expr (st, fi, xs.head, nm, ts)
      $decl r  $call emit_gitems (st, fi, $call IR.exprs.val (xs.tail), ts,
                   $call strs.cons (nm, acc)) }.r,
  $case xs ($call strs.reverse (acc, strs.nil))
)

$decl emit_slot_inits $func ($decl st proto_est, $decl fi 0, $decl xs IR.bslots.node,
                             $decl ts T.tys.node) $match xs (
  $case {$prop tag "cons"}
    { $decl d $call emit_expr (st, fi, xs.head.init, $call slot_name (xs.head.slot), ts)
      $decl r $call emit_slot_inits (st, fi, xs.tail, ts) }.r,
  $case xs ()
)

$decl emit_slot_reads $func ($decl st proto_est, $decl xs IR.bslots.node,
                             $decl first P.boolean) $match xs (
  $case {$prop tag "cons"}
    { $decl d $call say (st, $call concat ($if first " " ", ", $call slot_name (xs.head.slot)))
      $decl r $call emit_slot_reads (st, xs.tail, false) }.r,
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
  $case {$prop tag "cons"}
    { $decl ev $call IR.ints.val (fs.head.env)
      $decl d  $if ($call IR.ints.is_nil (ev)) ()
          ($call say (st, $call concat ("typedef struct {",
              $call concat ($call env_fields (st, ts, ev, 0, ""),
              $call concat (" } ", $call concat ($call env_name (i), ";\n"))))))
      $decl r $call emit_envs (st, $call IR.fns.val (fs.tail), ts, $call add (i, 1)) }.r,
  $case fs ()
)

$decl emit_env $func ($decl st proto_est, $decl fi 0, $decl xs IR.exprs.node,
                      $decl ev "", $decl i 0, $decl ts T.tys.node) $match xs (
  $case {$prop tag "cons"}
    { $decl d $call emit_expr (st, fi, xs.head,
          $call concat (ev, $call concat ("->c", $call int_to_str (i))), ts)
      $decl r $call emit_env (st, fi, $call IR.exprs.val (xs.tail), ev, $call add (i, 1), ts) }.r,
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
  $case {$prop tag "cons"}
    { $decl d $call say (st, $call concat ("  case ",
          $call concat ($call int_to_str ($call disc_label (ms, xs.head, boolish)), ": ")))
      $decl r $call emit_labels (st, xs.tail, ms, boolish) }.r,
  $case xs ()
)

$decl emit_first_arm $func ($decl st proto_est, $decl fi 0, $decl xs IR.arms.node,
                            $decl dest "", $decl want 0, $decl ts T.tys.node) $match xs (
  $case {$prop tag "cons"} ($call emit_as (st, fi, xs.head.body, dest, want, ts)),
  $case xs ($call eerr (st, "a $match with no arms"))
)

$decl emit_cases $func ($decl st proto_est, $decl fi 0, $decl xs IR.arms.node,
                        $decl dest "", $decl want 0, $decl ts T.tys.node,
                        $decl scrut "", $decl ms T.tys.node,
                        $decl boolish P.boolean) $match xs (
  $case {$prop tag "cons"}
    { $decl ds $call IR.ints.val (xs.head.discs)
      $decl d0 $call emit_labels (st, ds, ms, boolish)
      $decl d1 $call say (st, "{\n")
      // §4.7's narrowing: the arm's slot holds the member the discriminator
      // selected, which is what the body reads the fields off.
      // An arm whose body ignores the narrowed value is ordinary — `$case
      // {$prop tag "none"} 0` reads nothing — so say the slot may go unread
      // rather than silence the warning for the file.
      $decl d2 $if ($call eq_int (xs.head.slot, -1)) ()
          { $decl a $call assign (st, $call slot_name (xs.head.slot),
                $if boolish scrut
                    ($call concat (scrut, $call concat (".u.m",
                        $call int_to_str ($call IR.ints.nth (ds, 0))))))
            $decl b $call say (st, $call concat ("  (void)",
                $call concat ($call slot_name (xs.head.slot), ";\n"))) }.b
      $decl d3 $call emit_as (st, fi, xs.head.body, dest, want, ts)
      $decl d4 $call say (st, "  } break;\n")
      $decl r  $call emit_cases (st, fi, xs.tail, dest, want, ts, scrut, ms, boolish) }.r,
  $case xs ()
)

$decl emit_expr $func ($decl st proto_est, $decl fi 0, $decl e IR.proto_expr,
                       $decl dest "", $decl ts T.tys.node) $match e (
  $case {$prop tag "int"}
    $call say (st, $call concat ("  ", $call concat (dest,
        $call concat (" = ", $call concat ($call int_to_str (e.v), ";\n"))))),
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
    $if ($call is_thunk (st, e.fn)) ($call assign (st, dest, $call gbl_name (e.fn)))
        ($do ($call assign (st, $call concat (dest, ".code"),
                  $call concat ("(void *)", $call fn_name (e.fn))))
             ($call assign (st, $call concat (dest, ".env"), "NULL"))),
  // §4.15: the root block declares `err` and `none` as prop-only blocks, so a
  // `prim` can stand in value position as well as callee position. With no
  // fields there is nothing to initialise but the placeholder C needs.
  $case {$prop tag "prim"}
    { $decl t $call type_at (ts, e.ty)
      $decl r $match t (
          $case {$prop tag "block"}
            $if ($call T.fields.is_nil ($call T.fields.val (t.fields)))
                ($call assign (st, dest, $call concat ("(", $call concat ($call c_type (st, ts, e.ty),
                     "){0}"))))
                ($call eerr (st, $call concat ("cannot emit the intrinsic ", e.name))),
          // §7.3: an intrinsic named as a value is the pair, like any other
          // function. §8's arithmetic is emitted infix when it is *called*, so
          // the pair points at a wrapper that exists only to have an address.
          $case {$prop tag "func"}
            $if ($call eq_str ($call prim_op (e.name), ""))
                ($call eerr (st, $call concat ("cannot emit the intrinsic ", e.name)))
                ($do ($call assign (st, $call concat (dest, ".code"),
                          $call concat ("(void *)mpl_fn_", e.name)))
                     ($call assign (st, $call concat (dest, ".env"), "NULL"))),
          $case t ($call eerr (st, $call concat ("cannot emit the intrinsic ", e.name)))
        ) }.r,
  $case {$prop tag "call"} ($call emit_call (st, fi, e, dest, ts)),
  $case {$prop tag "if"}
    { $decl c  $call fresh_tmp (st)
      $decl d0 $call say (st, $call concat ("  int64_t ", $call concat (c, ";\n")))
      $decl d1 $call emit_expr (st, fi, $call IR.eval (e.cond), c, ts)
      $decl d2 $call say (st, $call concat ("  if (", $call concat (c, ") {\n")))
      $decl d3 $call emit_as (st, fi, $call IR.eval (e.then), dest, e.ty, ts)
      $decl d4 $call say (st, "  } else {\n")
      $decl d5 $call emit_as (st, fi, $call IR.eval (e.els), dest, e.ty, ts)
      $decl r  $call say (st, "  }\n") }.r,
  $case {$prop tag "do"}
    { $decl tv $call into_tmp (st, fi, $call IR.eval (e.first), ts)
      // §4.8b runs the first operand for effect and discards it, so C is right
      // that the temporary is never read — say so rather than silence the
      // warning for the whole file.
      $decl d1 $call say (st, $call concat ("  (void)", $call concat (tv, ";\n")))
      $decl r  $call emit_expr (st, fi, $call IR.eval (e.then), dest, ts) }.r,
  // §4.5: each entry is assigned to its slot in order — a later `$decl` may
  // name an earlier one — and the block's value is the struct of those slots
  // afterwards.
  // §7.2: "Groups are laid out elementwise." Each item into its own temporary
  // first, then the struct literal — the same shape a block gets, and for the
  // same reason: a C initializer cannot hold the statements an item may need.
  $case {$prop tag "group"}
    { $decl ns $call emit_gitems (st, fi, $call IR.exprs.val (e.items), ts, strs.nil)
      $decl r  $call say (st, $call concat ("  ", $call concat (dest,
          $call concat (" = (", $call concat ($call c_type (st, ts, e.ty),
          $call concat ("){", $call concat ($call join_args (ns, "", true), "};\n"))))))) }.r,
  $case {$prop tag "block"}
    { $decl d0 $call emit_slot_inits (st, fi, $call IR.bslots.val (e.slots), ts)
      $decl d1 $call say (st, $call concat ("  ", $call concat (dest,
          $call concat (" = (", $call concat ($call c_type (st, ts, e.ty), "){")))))
      $decl d2 $call emit_slot_reads (st, $call IR.bslots.val (e.slots), true)
      $decl r  $call say (st, "};\n") }.r,
  // §4.6 as a layout position (§7.2).
  $case {$prop tag "field"}
    { $decl tgt $call IR.eval (e.target)
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
      $decl r   $call say (st, $call concat ("  ", $call concat (dest,
                    $call concat (" = ", $call concat (tv, $call concat (thru,
                    $call concat (".f", $call concat ($call int_to_str (e.index), ";\n")))))))) }.r,
  // §4.2: the only way storage comes into existence. §7.4 makes `&T` a thin
  // pointer, so this is one allocation and one store.
  $case {$prop tag "new"}
    { $decl v  $call IR.eval (e.init)
      $decl vt $call c_type (st, ts, v.ty)
      $decl tv $call into_tmp (st, fi, v, ts)
      $decl d0 $call assign (st, dest, $call concat ("(", $call concat (vt,
                   $call concat (" *)mpl_alloc((int64_t)sizeof(", $call concat (vt, "))")))))
      $decl r  $call say (st, $call concat ("  *", $call concat (dest,
                   $call concat (" = ", $call concat (tv, ";\n"))))) }.r,
  // §5.4's implicit read, which lowering made explicit.
  $case {$prop tag "deref"}
    { $decl sv $call into_tmp (st, fi, $call IR.eval (e.src), ts)
      $decl r  $call assign (st, dest, $call concat ("*", sv)) }.r,
  // §4.4: writes *through* storage, and evaluates to the written value.
  $case {$prop tag "set"}
    { $decl tg $call into_tmp (st, fi, $call IR.eval (e.target), ts)
      $decl vl $call into_tmp (st, fi, $call IR.eval (e.value), ts)
      $decl d0 $call say (st, $call concat ("  *", $call concat (tg,
                   $call concat (" = ", $call concat (vl, ";\n")))))
      $decl r  $call assign (st, dest, vl) }.r,
  // §4.7, as §7.5's discriminator test — the one construct that reads runtime
  // type information. Several `case` labels may share a body, because an arm
  // answers for every member no earlier arm claimed.
  // §4.7, as §7.5's discriminator test — the one construct that reads runtime
  // type information. Several `case` labels may share a body, because an arm
  // answers for every member no earlier arm claimed.
  $case {$prop tag "switch"}
    { $decl sc $call IR.eval (e.scrut)
      // §5.5: a `μ` *is* its unrolling, so the members `$match` discriminates
      // over are the unrolling's — and they are in the order
      // `emit_union_struct` laid the C union out in, because both ask
      // `T.unroll` the same question.
      $decl st2 $call T.unroll ($call type_at (ts, sc.ty))
      $decl r $match st2 (
          $case {$prop tag "union"}
            { $decl sv $call into_tmp (st, fi, sc, ts)
              // §3.2: a boolean is its own discriminator.
              $decl bl $call T.same (st2, T.t_bool)
              $decl ms $call T.tys.val (st2.members)
              $decl d0 $call say (st, $call concat ("  switch ((int)",
                           $call concat (sv, $if bl ") {\n" ".tag) {\n")))
              $decl d1 $call emit_cases (st, fi, $call IR.arms.val (e.arms), dest, e.ty, ts, sv,
                           ms, bl)
              // §5.6 checked exhaustiveness, so nothing reaches this.
              $decl d2 $call say (st, "  default: mpl_panic(\"no $match arm applied\");\n  }\n")
              $decl o  () }.o,
          // Not a union, so there is no discriminator and no choice: §4.7's
          // first arm covers the whole type.
          $case st2 ($call emit_first_arm (st, fi, $call IR.arms.val (e.arms), dest, e.ty, ts))
        ) }.r,
  // §7.3: the captures are copied *here*, where the literal stood, into an
  // environment the pair points at. The struct is anonymous — nothing reads it
  // but the lifted body, which knows its shape from the capture order.
  $case {$prop tag "closure"}
    { $decl cs $call IR.exprs.val (e.captures)
      $decl ev $call fresh_tmp (st)
      $decl en $call env_name (e.fn)
      $decl d0 $call say (st, $call concat ("  ", $call concat (en,
                   $call concat (" *", $call concat (ev,
                   $call concat (" = (", $call concat (en,
                   $call concat (" *)mpl_alloc((int64_t)sizeof(", $call concat (en, "));\n")))))))))
      $decl d1 $call emit_env (st, fi, cs, ev, 0, ts)
      $decl d2 $call assign (st, $call concat (dest, ".code"),
                   $call concat ("(void *)", $call fn_name (e.fn)))
      $decl r  $call assign (st, $call concat (dest, ".env"), $call concat ("(void *)", ev)) }.r,
  // §7.3 again: a capture is read out of the environment the pair carried in.
  $case {$prop tag "capture"}
    $call assign (st, dest, $call concat ("((", $call concat ($call env_name (fi),
        $call concat (" *)env)->c", $call int_to_str (e.slot))))),
  // §4.15: evaluate, and if the discriminator says the pattern matched, inject
  // that member into the function's result and return. Otherwise carry on with
  // what is left — which lowering already computed as this node's type.
  $case {$prop tag "try"}
    { $decl v  $call IR.eval (e.value)
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
      $decl d2 $call say (st, "  return ret;\n  }\n")
      // What survives is a single member, so reading it out is the narrowing.
      $decl r  $call assign (st, dest, $call concat (tv,
                   $call concat (".u.m", $call int_to_str ($call other_disc (ms, e.disc, 0))))) }.r,
  // §7.4's coercion, made explicit by lowering where it could not be left to
  // the use site — `$union`'s value is a member and its type is the union.
  $case {$prop tag "copy"}
    { $decl sv $call IR.eval (e.src)
      $decl tv $call into_tmp (st, fi, sv, ts)
      $decl r  $call emit_inject (st, ts, dest, tv, sv.ty, e.ty) }.r,
  $case e ($call eerr (st, $call concat ("cannot emit ", $call IR.show (e))))
)

// -------------------------------------------------------------- functions

$decl emit_params $func ($decl st proto_est, $decl xs IR.ints.node, $decl ts T.tys.node,
                         $decl i 0, $decl first P.boolean) $match xs (
  $case {$prop tag "cons"}
    { $decl d $call say (st, $call concat ($if first "" ", ",
          $call concat ($call c_type (st, ts, xs.head),
          $call concat (" ", $call slot_name (i)))))
      $decl r $call emit_params (st, xs.tail, ts, $call add (i, 1), false) }.r,
  $case xs ()
)

// The slots past the parameters, each with its own type (§7.2).
$decl emit_slots $func ($decl st proto_est, $decl xs IR.ints.node, $decl ts T.tys.node,
                        $decl i 0, $decl skip 0) $match xs (
  $case {$prop tag "cons"}
    { $decl d $if ($call lt (i, skip)) ()
          ($call say (st, $call concat ("  ", $call concat ($call c_type (st, ts, xs.head),
              $call concat (" ", $call concat ($call slot_name (i), ";\n"))))))
      $decl r $call emit_slots (st, xs.tail, ts, $call add (i, 1), skip) }.r,
  $case xs ()
)

$decl emit_fn $func ($decl st proto_est, $decl i 0, $decl f IR.proto_fn, $decl ts T.tys.node)
  { $decl np  $call IR.ints.length (f.params, 0)
    $decl h0  $call say (st, $call concat ("\nstatic ",
                  $call concat ($call c_type (st, ts, f.result),
                  $call concat (" ", $call concat ($call fn_name (i), "(void *env")))))
    $decl h1  $call emit_params (st, f.params, ts, 0, false)
    $decl h2  $call say (st, $call concat (") {  /* ", $call concat (f.name, " */\n")))
    $decl h3  $call say (st, "  (void)env;\n")
    $decl s0  $call emit_slots (st, $call IR.ints.val (f.slots), ts, 0, np)
    $decl fr  $set st.fnres f.result
    $decl r0  $call say (st, $call concat ("  ",
                  $call concat ($call c_type (st, ts, f.result), " ret;\n")))
    $decl l0  $if f.self_tail ($call say (st, "  while (1) {\n")) ()
    $decl b0  $call emit_as (st, i, f.body, "ret", f.result, ts)
    $decl r1  $call say (st, "  return ret;\n")
    $decl l1  $if f.self_tail ($call say (st, "  }\n")) ()
    $decl r2  $call say (st, "}\n") }.r2

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
$decl grp_name $func ($decl i 0) $call concat ("mpl_grp", $call int_to_str (i))

$decl fn_at $func ($decl fs IR.fns.node, $decl i 0) $call IR.fns.nth (fs, i)

$decl same_sig $func ($decl fs IR.fns.node, $decl g IR.ints.node, $decl p IR.ints.node,
                      $decl res 0) $match g (
  $case {$prop tag "cons"}
    { $decl f $call fn_at (fs, g.head)
      $decl r $if ($call and ($call eq_int (f.result, res),
                              $call same_ints ($call IR.ints.val (f.params), p)))
                  ($call same_sig (fs, g.tail, p, res)) false }.r,
  $case g true
)


$decl emit_member $func ($decl st proto_est, $decl fs IR.fns.node, $decl g IR.ints.node,
                         $decl ts T.tys.node, $decl i 0) $match g (
  $case {$prop tag "cons"}
    { $decl f  $call fn_at (fs, g.head)
      $decl np $call IR.ints.length ($call IR.ints.val (f.params), 0)
      $decl d0 $call say (st, $call concat ("  case ", $call concat ($call int_to_str (i),
                   $call concat (": {  /* ", $call concat (f.name, " */\n")))))
      // The non-parameter slots live in the case's own block, so members do
      // not collide over a slot number.
      $decl d1 $call emit_slots (st, $call IR.ints.val (f.slots), ts, 0, np)
      $decl d2 $call emit_as (st, g.head, f.body, "ret", f.result, ts)
      $decl d3 $call say (st, "  return ret;\n  }\n")
      $decl r  $call emit_member (st, fs, g.tail, ts, $call add (i, 1)) }.r,
  $case g ()
)

$decl emit_wrappers $func ($decl st proto_est, $decl fs IR.fns.node, $decl g IR.ints.node,
                           $decl gi 0, $decl ts T.tys.node, $decl i 0) $match g (
  $case {$prop tag "cons"}
    { $decl f  $call fn_at (fs, g.head)
      $decl h0 $call say (st, $call concat ("\nstatic ",
                   $call concat ($call c_type (st, ts, f.result),
                   $call concat (" ", $call concat ($call fn_name (g.head), "(void *env")))))
      $decl h1 $call emit_params (st, $call IR.ints.val (f.params), ts, 0, false)
      $decl h2 $call say (st, $call concat (") {  /* ", $call concat (f.name, " */\n  return ")))
      $decl h3 $call say (st, $call concat ($call grp_name (gi),
                   $call concat ("(env, ", $call concat ($call int_to_str (i),
                   $call concat ($call slot_args ($call IR.ints.val (f.params), 0, ""),
                                 ");\n}\n")))))
      $decl r  $call emit_wrappers (st, fs, g.tail, gi, ts, $call add (i, 1)) }.r,
  $case g ()
)


$decl emit_group $func ($decl st proto_est, $decl fs IR.fns.node, $decl g IR.ints.node,
                        $decl gi 0, $decl ts T.tys.node)
  { $decl f0  $call fn_at (fs, $call IR.ints.nth (g, 0))
    $decl np  $call IR.ints.length ($call IR.ints.val (f0.params), 0)
    $decl h0  $call say (st, $call concat ("\nstatic ",
                  $call concat ($call c_type (st, ts, f0.result),
                  $call concat (" ", $call concat ($call grp_name (gi), "(void *env, int64_t state")))))
    $decl h1  $call emit_params (st, $call IR.ints.val (f0.params), ts, 0, false)
    $decl h2  $call say (st, ") {\n  (void)env;\n")
    $decl r0  $call say (st, $call concat ("  ",
                  $call concat ($call c_type (st, ts, f0.result), " ret;\n")))
    $decl g0  $set st.grp g
    $decl fr  $set st.fnres f0.result
    $decl l0  $call say (st, "  while (1) {\n  switch ((int)state) {\n")
    $decl m0  $call emit_member (st, fs, g, ts, 0)
    $decl l1  $call say (st, "  default: mpl_panic(\"bad state\");\n  }\n  }\n}\n")
    $decl g1  $set st.grp IR.ints.nil
    $decl w0  $call emit_wrappers (st, fs, g, gi, ts, 0) }.w0

$decl emit_groups $func ($decl st proto_est, $decl fs IR.fns.node, $decl gs IR.groups.node,
                         $decl gi 0, $decl ts T.tys.node) $match gs (
  $case {$prop tag "cons"}
    { $decl g  $call IR.ints.val (gs.head.members)
      $decl f0 $call fn_at (fs, $call IR.ints.nth (g, 0))
      $decl ok $call same_sig (fs, g, $call IR.ints.val (f0.params), f0.result)
      $decl d  $if ok ($call emit_group (st, fs, g, gi, ts))
                  ($call eerr (st, "a mutually tail-recursive group whose members differ in signature is not contified yet"))
      $decl r  $call emit_groups (st, fs, $call IR.groups.val (gs.tail), $call add (gi, 1), ts) }.r,
  $case gs ()
)

// Forward declarations first: §4.10 is source order, but C needs every callee
// visible before its caller, and a `$fwd` group is mutually recursive by
// construction (§5.5).
$decl emit_protos $func ($decl st proto_est, $decl fs IR.fns.node, $decl ts T.tys.node,
                         $decl i 0) $match fs (
  $case {$prop tag "cons"}
    { $decl h0 $call say (st, $call concat ("static ",
          $call concat ($call c_type (st, ts, fs.head.result),
          $call concat (" ", $call concat ($call fn_name (i), "(void *env")))))
      $decl h1 $call emit_params (st, fs.head.params, ts, 0, false)
      $decl h2 $call say (st, ");\n")
      $decl r  $call emit_protos (st, $call IR.fns.val (fs.tail), ts, $call add (i, 1)) }.r,
  $case fs ()
)

// One static per thunk, and one assignment each in source order (§4.10). A
// later global may name an earlier one, and index order is source order, so
// running them in order is all it takes.
$decl emit_globals $func ($decl st proto_est, $decl fs IR.fns.node, $decl ts T.tys.node,
                          $decl i 0) $match fs (
  $case {$prop tag "cons"}
    { $decl d $if fs.head.thunk
          ($call say (st, $call concat ("static ",
              $call concat ($call c_type (st, ts, fs.head.result),
              $call concat (" ", $call concat ($call gbl_name (i),
              $call concat (";  /* ", $call concat (fs.head.name, " */\n")))))))) ()
      $decl r $call emit_globals (st, $call IR.fns.val (fs.tail), ts, $call add (i, 1)) }.r,
  $case fs ()
)

$decl emit_inits $func ($decl st proto_est, $decl fs IR.fns.node, $decl i 0) $match fs (
  $case {$prop tag "cons"}
    { $decl d $if fs.head.thunk
          ($call assign (st, $call gbl_name (i), $call concat ($call fn_name (i), "(NULL)"))) ()
      $decl r $call emit_inits (st, $call IR.fns.val (fs.tail), $call add (i, 1)) }.r,
  $case fs ()
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


$decl emit_fns $func ($decl st proto_est, $decl fs IR.fns.node, $decl ts T.tys.node,
                      $decl i 0, $decl gs IR.groups.node) $match fs (
  $case {$prop tag "cons"}
    { $decl d $if ($call in_a_group (gs, i)) () ($call emit_fn (st, i, fs.head, ts))
      $decl r $call emit_fns (st, $call IR.fns.val (fs.tail), ts, $call add (i, 1), gs) }.r,
  $case fs ()
)

// The `main` a hosted C program needs: whichever top-level `$decl` was named
// `main`, printed. §9 leaves the entry point to the build program; this is the
// stand-in that makes an emitted file runnable.
$decl find_main $func ($decl fs IR.fns.node, $decl i 0) $match fs (
  $case {$prop tag "cons"}
    $if ($call eq_str (fs.head.name, "main")) i
        ($call find_main ($call IR.fns.val (fs.tail), $call add (i, 1))),
  $case fs -1
)

$decl emit_program $func ($decl st proto_est, $decl p IR.proto_program)
  { $decl ts $call T.tys.val (p.types)
    $decl fs $call IR.fns.val (p.funcs)
    $decl tk $set st.thunks ($call thunk_ids (fs, 0, IR.ints.nil))
    $decl h  $call say (st, $call concat (runtime_c, "\n"))
    $decl sd $call emit_structs (st, ts, ts, 0)
    $decl gap $call say (st, "\n")
    $decl d0 $call emit_protos (st, fs, ts, 0)
    $decl en $call emit_envs (st, fs, ts, 0)
    $decl gv $call emit_globals (st, fs, ts, 0)
    $decl gs $call IR.groups.val (p.groups)
    $decl d1 $call emit_fns (st, fs, ts, 0, gs)
    $decl d3 $call emit_groups (st, fs, gs, 0, ts)
    $decl i0 $call say (st, "\nstatic void mpl_init(void) {\n")
    $decl i1 $call emit_inits (st, fs, 0)
    $decl i2 $call say (st, "}\n")
    $decl mi  $call find_main (fs, 0)
    $decl mfn $if ($call lt (mi, 0)) IR.proto_fn ($call IR.fns.nth (fs, mi))
    // §9 leaves the entry point to the build program; this prints whichever of
    // `Int` or `Str` the entry returns, which is as far as a stand-in goes.
    $decl mt  $if ($call lt (mi, 0)) T.t_bot ($call type_at (ts, mfn.result))
    $decl body $if ($call T.same (mt, T.t_str))
        ($call concat ("  mpl_print(", $call concat ($call fn_name (mi), "(NULL));\n")))
        ($call concat ("  printf(\"%lld\\n\", (long long)",
             $call concat ($call fn_name (mi), "(NULL));\n")))
    $decl d2 $if ($call lt (mi, 0))
        ($call eerr (st, "no top-level $decl named 'main'"))
        ($call say (st, $call concat ("\nint main(void) {\n  mpl_init();\n",
             $call concat (body, "  return 0;\n}\n"))))
    $decl r  $call out_of (st) }.r
