// §9's `compiler`: the pipeline as values.
//
// "The compiler is a library: the root-block value `compiler` exposes `parse`,
// `check`, `verify`, `emit`, `link`, the typed tree it passes between them
// (§9.1), and props describing host and targets." This is that value. Until
// the build program is a morphl program too (§9's `build` file), it is an
// ordinary module the drivers import.
//
// Each step takes and returns a block, so a pipeline is ordinary composition
// and a pass is an ordinary function (§9.2):
//
//   $decl src $call C.parse (text, "src/main.mpl")
//   $decl ckd $call C.check (src)
//   $decl opt $call my.fold (ckd.program)
//   $decl bad $call C.verify (opt)            // while developing the pass
//   $decl app $call C.emit (opt)
//
// There is no registry and no hook: pass order is the order the calls are
// written, and a conditional pass is an `$if`.
//
// Two places where this differs from §9.1's table, both for the same reason —
// a step that can fail has to say so in its result rather than out of band:
//
//   * `parse` takes the path beside the source. §9's resolution lives in the
//     build program, but a diagnostic names its file and `$import` resolves
//     relative to the entry (§4.14), so the path travels with the text rather
//     than being remembered by the caller.
//   * `emit` returns text *and* diagnostics. §6a's indirect case and the
//     constructs the C backend does not cover yet are reported there; the
//     alternative is a backend that panics, and §4.15 keeps expected failures
//     values.
//
// `verify` is the one that does not fail: it *is* the diagnostics (§9.2).

$decl P  $import "prelude"
$decl Pa $import "parser"
$decl T  $import "types"
$decl I  $import "infer"
$decl IR $import "ir"
$decl L  $import "lower"
$decl E  $import "emit"
$decl V  $import "verify"

// ------------------------------------------------------- what travels between
//
// §5.1 makes field order the interface, so each of these grows only at the end
// (§10.9) — and §9.3 binds that to every pass in every project, not just to
// the compiler's own modules.

$decl parsed $func ($decl a Pa.nodes.node, $decl p "", $decl b "", $decl d Pa.diags.node)
  { $decl ast a  $decl path p  $decl base b  $decl diagnostics d }

$decl proto_parsed $call parsed (Pa.nodes.nil, "", "", Pa.diags.nil)

$decl checked $func ($decl pr IR.proto_program, $decl d Pa.diags.node)
  { $decl program pr  $decl diagnostics d }

$decl proto_checked $call checked (IR.proto_program, Pa.diags.nil)

$decl emitted $func ($decl s "", $decl d Pa.diags.node)
  { $decl text s  $decl diagnostics d }

$decl proto_emitted $call emitted ("", Pa.diags.nil)

$decl artifact $func ($decl p "", $decl d Pa.diags.node)
  { $decl path p  $decl diagnostics d }

// A program with nothing in it: what a step that could not do its job returns,
// so that the *next* step still has a `program` to be handed and the
// diagnostics carry the reason (§4.15: expected failures are values).
$decl empty_program $call IR.program (T.tys.nil, IR.fns.nil, IR.groups.nil, 0, IR.effects.nil)

// ------------------------------------------------------------------- parse

$decl parse $func ($decl src "", $decl path "")
  { $decl p $call Pa.parse (src)
    // The parser is handed a string and does not know where it came from; the
    // reader stamps the file in (parser.mpl says so above `diag`).
    $decl out $call parsed ($call Pa.nodes.val (p.exprs), path, $call P.dirname (path),
                   $call I.stamp_file (p.errs, path, Pa.diags.nil)) }.out

// ------------------------------------------------------------------- check
//
// §9.1's `check` is inference *and* lowering: what it returns is the typed
// tree, and neither half of that is a `program` on its own. Each half stops if
// the one before it failed — a tree lowered from a file inference rejected is
// not a program, and handing one to a pass would be handing it nonsense.

// The first half on its own. §9.1 does not name it, because a build wants the
// program and not the type — but a file's type *is* the answer to "does this
// check?" (§3.3 makes a file a block), and a tool that only reports diagnostics
// has no use for the tree. `check` is this followed by lowering.
$decl typed $func ($decl t T.proto_ty, $decl d Pa.diags.node)
  { $decl ty t  $decl diagnostics d }

$decl infer_ok $func ($decl items Pa.nodes.node, $decl base "", $decl path "")
  { $decl r   $call I.infer_file (items, I.root_env, base, path)
    $decl out $call typed (r.ty, $call Pa.diags.val (r.errs)) }.out

$decl infer $func ($decl p proto_parsed)
  $if ($call Pa.diags.is_nil ($call Pa.diags.val (p.diagnostics)))
      ($call infer_ok ($call Pa.nodes.val (p.ast), p.base, p.path))
      ($call typed (T.t_bot, $call Pa.diags.val (p.diagnostics)))


$decl lower_ok $func ($decl items Pa.nodes.node, $decl fty T.proto_ty, $decl base "")
  { $decl st    $call L.lstate ()
    // §2's root block, straight from inference: a `binding` is `{name, ty}`,
    // which is a `T.field`, so one converter reads both (§5.1).
    $decl prims $call L.prims_from (I.root_env, L.benv.nil)
    $decl prog  $call L.lower_file (st, items, fty, prims, base)
    $decl out   $call checked (prog, st.errs) }.out

$decl check_ok $func ($decl items Pa.nodes.node, $decl base "", $decl path "")
  { $decl r   $call infer_ok (items, base, path)
    $decl out $if ($call Pa.diags.is_nil ($call Pa.diags.val (r.diagnostics)))
        ($call lower_ok (items, r.ty, base))
        ($call checked (empty_program, $call Pa.diags.val (r.diagnostics))) }.out

$decl check $func ($decl p proto_parsed)
  $if ($call Pa.diags.is_nil ($call Pa.diags.val (p.diagnostics)))
      ($call check_ok ($call Pa.nodes.val (p.ast), p.base, p.path))
      ($call checked (empty_program, $call Pa.diags.val (p.diagnostics)))

// ------------------------------------------------------------------ verify
//
// §9.2: a pass is ordinary code, so it can be wrong, and this is how a
// pipeline finds out. Re-exported rather than wrapped — it already has the
// shape §9.1 gives it, `program -> diagnostics`.

$decl verify V.verify

// ------------------------------------------------------------------- emit

$decl emit $func ($decl pr IR.proto_program)
  { $decl st  $call E.estate ()
    $decl c   $call E.emit_program (st, pr)
    $decl out $call emitted (c, $call E.emit_errs (st)) }.out

// -------------------------------------------------------------------- link
//
// §9.1's last step, and the one this build cannot take: §9 makes `$extern` the
// only door to the platform and stage 1 has none, so there is no way to run a
// linker from here. It reports that rather than pretending to have done it —
// the caller writes `emit`'s text out and runs the platform's C compiler.
$decl link $func ($decl e proto_emitted, $decl path "")
  $call artifact ("", $call Pa.diags.cons (
      $call Pa.diag ("link: no linker is reachable from this build; write emit's text out and compile it", 0, 0, ""),
      Pa.diags.nil))

// --------------------------------------------------------- the whole of it
//
// §9.1's project-level form is "a convenience over these, not a separate
// mechanism". This is that convenience, and it is exactly the three calls.

$decl compile $func ($decl src "", $decl path "")
  { $decl ckd $call check ($call parse (src, path))
    $decl out $if ($call Pa.diags.is_nil ($call Pa.diags.val (ckd.diagnostics)))
        ($call emit (ckd.program))
        ($call emitted ("", $call Pa.diags.val (ckd.diagnostics))) }.out

// ------------------------------------------------------------ host and target
//
// A target is a prop-only block, so its name is part of its type (§4.3) and a
// build program selects on it with `$match` rather than with a string compare.
// C is the only one this build emits, so `targets` is `host`.

$decl target_c { $prop name "c"  $prop dialect "c99" }

$decl host    target_c
$decl targets target_c

// ------------------------------------------------------------- the tree itself
//
// §9.1: "`compiler.program` is an example value of it — types are still never
// written, only exemplified (§5.7)." These are what a pass writes its parameter
// defaults against.

$decl program IR.proto_program
$decl fn      IR.proto_fn
$decl node    IR.proto_expr

// The constructors, so a pass can build nodes as well as read them —
// `ir.fresh_id` in particular, since §9.3 makes a node's index distinct in a
// program and a pass that duplicates a subtree has to re-index the copy.
//
// §9.3 says the exposed tree should be "deliberately smaller than whatever the
// compiler uses internally". It is not yet: this is the compiler's own module,
// and narrowing it is the work §9.3 describes rather than something already
// done.
$decl ir    IR
$decl types T
