// Stage 1's typed tree — what `check` hands to `emit` (BOOTSTRAP.md stage 1).
//
// This is deliberately *not* "the AST plus a type on every node". The AST is
// what the source says; C needs several things the source does not say, and
// every one of them is knowledge inference already had and would otherwise
// throw away. Lowering into this shape is where that knowledge is written down.
//
// What the AST does not carry, and this does:
//
//   * **Names are resolved.** A name in the AST is a string; here it is a frame
//     slot, a capture index, or a global. §4.10's source-order scoping and
//     §4.11's `$fwd` slots are exactly a slot numbering, so resolving them once
//     is cheaper and less error-prone than making the backend walk scopes.
//   * **Projections are indices.** §4.6's `.name` and `.1` both become a
//     position, because §7.2 makes the `$decl` order the layout. `$prop` is
//     gone entirely: props occupy no space, and their values are already part
//     of the type.
//   * **Dereferences are explicit.** §5.4 makes a reference transparent
//     wherever a value is expected and there is no way to write a dereference.
//     The backend cannot reconstruct that without redoing the typing, so
//     lowering inserts `deref` where the rule fired.
//   * **Coercions are explicit.** §7.4's prefix upcast of a *value* is a copy;
//     of a `&const` it is free. `copy` marks the ones that cost something.
//   * **Templates are gone.** §4.9 memoises specialisation by argument type,
//     so by this point every `$specialize` has become an ordinary function and
//     the program is monomorphic. There is no `$template` node.
//   * **Tail position is marked.** §7.7 makes tail-call elimination mandatory
//     and §6a decides how: a self tail call becomes a loop, a `$fwd` group
//     becomes one function with a dispatch loop, anything else a trampoline.
//     Which calls are in tail position is a property of where they sit in the
//     tree, so it is recorded here rather than rediscovered.
//   * **Types are interned.** A type is an index into the program's table, so
//     each distinct block type gets exactly one C struct, and comparing two
//     types is comparing two integers. Interning is only sound because binders
//     are de Bruijn indices (§5.5): alpha-equivalent types are *identical*, so
//     `T.same` is the right key.
//
// What is deliberately still here: `$if` and `$match` stay separate from a
// plain jump, because §7.5 makes `$match` the one construct that reads runtime
// type information, and the discriminator test is the backend's business.

$decl P $import "prelude"
$decl T $import "types"

$decl not P.not

$decl ints $specialize P.list 0
$decl strs $specialize P.list ""

// ------------------------------------------------------------------- types
//
// A `tyid` is an index into `program.types`. Zero is not special; the table is
// built by interning, so equal types share an index and every index names one C
// struct.

$decl tyid $func ($decl i 0) i

// ----------------------------------------------------------------- identity
//
// Every node carries an index of its own, distinct within a program. It is
// what a pass keys an annotation on: §7.4 makes a node extended with an extra
// field a *prefix copy* on the way into any function expecting the plain one,
// so analysis results live beside the tree rather than inside it (§9.3) — and
// a side table needs something to key on.
//
// Ids come from a counter, which is the one piece of mutable state here. They
// are therefore assigned in construction order, and construction order is
// deterministic — which the bootstrap's byte-identical gate depends on.
$decl next_id $mut $alloc 0

$decl fresh_id $func ()
  { $decl i $call P.ival (next_id)
    $decl n $set next_id ($call add (i, 1))
    $decl r i }.r

// `ty` then `id` are the first two slots of every node, so this block is a
// prefix supertype of all of them (§5.1) — which is how a pass reads either
// without knowing the shape.
$decl any_node { $decl ty 0  $decl id 0 }

$decl id_of $func ($decl n any_node) n.id
$decl ty_of $func ($decl n any_node) n.ty

// --------------------------------------------------------------- expressions
//
// Every node carries its type. The shapes are written out rather than named
// through the constructors below, for the reason `T.proto_ty` gives: §5.7 lets
// a type-only position name a declaration that is *in progress*, which
// `proto_expr` is inside its own `$union`, but not one that has not started.
//
// Recursive fields are `$new` (§5.5): a node holds its children through
// storage, so a node has a size. A list of children is boxed as a whole rather
// than element by element — a cons cell holds its element inline, so its size
// needs the element's, and one pointer in front of the list breaks that circle
// for every element at once.

$decl proto_expr $union (
  // Literals. §3.1: `Float` is carried as its source text, never parsed.
  { $prop tag "int"     $decl ty 0  $decl id 0  $decl v 0 },
  { $prop tag "float"   $decl ty 0  $decl id 0  $decl text "" },
  { $prop tag "str"     $decl ty 0  $decl id 0  $decl text "" },
  { $prop tag "bool"    $decl ty 0  $decl id 0  $decl v P.boolean },
  { $prop tag "unit"    $decl ty 0  $decl id 0 },

  // §7.8: `panic` aborts, so it is a terminator rather than a call — it has
  // type ⊥ and no continuation.
  { $prop tag "panic"   $decl ty 0  $decl id 0  $decl msg "" },

  // A frame slot: a parameter or a `$decl` of the enclosing function, numbered
  // in source order. §4.11's `$fwd` reserves its slot at its own position, so a
  // forward-completed name is an ordinary slot here and `$fwd` disappears.
  { $prop tag "local"   $decl ty 0  $decl id 0  $decl slot 0 },
  // A copied binding from the closure's environment (§7.3: capture by copy).
  { $prop tag "capture" $decl ty 0  $decl id 0  $decl slot 0 },
  // A top-level function, by index into `program.funcs`.
  { $prop tag "global"  $decl ty 0  $decl id 0  $decl fn 0 },
  // A root-block intrinsic (§8), by name: the backend maps these to C.
  { $prop tag "prim"    $decl ty 0  $decl id 0  $decl name "" },

  // §4.6, as a layout position (§7.2).
  { $prop tag "field"   $decl ty 0  $decl id 0  $decl target $alloc proto_expr  $decl index 0 },

  // §4.2. `new` is the only allocation in the language, so it is the only node
  // the region pass (§7.6) has to look at when there is one.
  { $prop tag "new"     $decl ty 0  $decl id 0  $decl init $alloc proto_expr },
  // §5.4's implicit read, made explicit.
  { $prop tag "deref"   $decl ty 0  $decl id 0  $decl src $alloc proto_expr },
  // §4.4: writes *through* storage.
  { $prop tag "set"     $decl ty 0  $decl id 0  $decl target $alloc proto_expr  $decl value $alloc proto_expr },

  // §7.4: a value coerced to a prefix supertype. A prefix copy, no scatter.
  // A reference coercion costs nothing and produces no node.
  { $prop tag "copy"    $decl ty 0  $decl id 0  $decl src $alloc proto_expr },

  // §4.5: a block's value is its `$decl` slots, in layout order. Non-`$decl`
  // expressions ran for effect during lowering and are `do` chains by now.
  //
  // Each entry is evaluated in order and assigned to its slot before the next
  // runs, because a later `$decl` may name an earlier one (§4.10, source
  // order); the block's value is the struct of those slots afterwards. The
  // slot number is carried rather than implied by position: a nested block
  // inside an initializer takes slots of its own, so a block's are not
  // contiguous.
  { $prop tag "block"   $decl ty 0  $decl id 0
    $decl slots $alloc ($specialize P.list { $decl slot 0  $decl init proto_expr }).node },
  { $prop tag "group"   $decl ty 0  $decl id 0  $decl items $alloc ($specialize P.list proto_expr).node },

  // §7.3: a function value is a code pointer and an environment, two words
  // whatever its signature — which is what lets a function type be a valid
  // recursion guard and a function-typed slot have a size.
  { $prop tag "closure" $decl ty 0  $decl id 0  $decl fn 0
    $decl captures $alloc ($specialize P.list proto_expr).node },

  // §7.7 decides `tail`, §6a decides what the backend does with it.
  { $prop tag "call"    $decl ty 0  $decl id 0  $decl callee $alloc proto_expr
    $decl args $alloc ($specialize P.list proto_expr).node  $decl tail P.boolean },

  { $prop tag "if"      $decl ty 0  $decl id 0  $decl cond $alloc proto_expr
    $decl then $alloc proto_expr  $decl els $alloc proto_expr },

  // §4.7 lowered: §7.5 gives a union value a discriminator, and §1.3 keeps
  // patterns to tag blocks and literals, so an arm is a discriminator test.
  // Exhaustiveness was checked (§5.6), so `default` is the catch-all every
  // `$match` must end in.
  { $prop tag "switch"  $decl ty 0  $decl id 0  $decl scrut $alloc proto_expr
    $decl arms $alloc ($specialize P.list { $decl discs ($specialize P.list 0).node  $decl slot 0  $decl body proto_expr }).node
    $decl default $alloc proto_expr },

  // §4.8b. The reason this form exists at all is that a call inside a block is
  // never in tail position, so it is the only way to sequence and keep §7.7.
  { $prop tag "do"      $decl ty 0  $decl id 0  $decl first $alloc proto_expr  $decl then $alloc proto_expr },

  // §4.15, the only non-local exit: if the value matches, return it from the
  // enclosing function. `disc` is the discriminator the pattern selects.
  { $prop tag "try"     $decl ty 0  $decl id 0  $decl value $alloc proto_expr  $decl disc 0 }
)

// Reading a child out of storage: §5.4 makes a reference transparent only
// where a value is expected, and a `$decl` initializer is not such a place.
$decl eval $func ($decl e proto_expr) e

$decl exprs $specialize P.list proto_expr

$decl bslot $func ($decl i 0, $decl e proto_expr) { $decl slot i  $decl init e }
$decl proto_bslot $call bslot (0, { $prop tag "unit" $decl ty 0  $decl id 0 })
$decl bslots $specialize P.list proto_bslot

// One source arm, and the discriminators it covers: §4.7 is first fit, so an
// arm answers for every union member no earlier arm already claimed — which in
// C is several `case` labels on one body, not a body per member.
$decl arm $func ($decl d ints.node, $decl s 0, $decl b proto_expr)
  { $decl discs d  $decl slot s  $decl body b }
$decl proto_arm $call arm (ints.nil, 0, { $prop tag "unit" $decl ty 0  $decl id 0 })
$decl arms $specialize P.list proto_arm

// ------------------------------------------------------------- constructors

$decl e_int   $func ($decl t 0, $decl n 0)    { $prop tag "int"   $decl ty t  $decl id ($call fresh_id ())  $decl v n }
$decl e_float $func ($decl t 0, $decl s "")   { $prop tag "float" $decl ty t  $decl id ($call fresh_id ())  $decl text s }
$decl e_str   $func ($decl t 0, $decl s "")   { $prop tag "str"   $decl ty t  $decl id ($call fresh_id ())  $decl text s }
$decl e_bool  $func ($decl t 0, $decl b P.boolean) { $prop tag "bool" $decl ty t  $decl id ($call fresh_id ())  $decl v b }
$decl e_unit  $func ($decl t 0)               { $prop tag "unit"  $decl ty t  $decl id ($call fresh_id ()) }
$decl e_panic $func ($decl t 0, $decl m "")   { $prop tag "panic" $decl ty t  $decl id ($call fresh_id ())  $decl msg m }

$decl e_local   $func ($decl t 0, $decl i 0) { $prop tag "local"   $decl ty t  $decl id ($call fresh_id ())  $decl slot i }
$decl e_capture $func ($decl t 0, $decl i 0) { $prop tag "capture" $decl ty t  $decl id ($call fresh_id ())  $decl slot i }
$decl e_global  $func ($decl t 0, $decl i 0) { $prop tag "global"  $decl ty t  $decl id ($call fresh_id ())  $decl fn i }
$decl e_prim    $func ($decl t 0, $decl n "") { $prop tag "prim"   $decl ty t  $decl id ($call fresh_id ())  $decl name n }

$decl e_field $func ($decl t 0, $decl e proto_expr, $decl i 0)
  { $prop tag "field" $decl ty t  $decl id ($call fresh_id ())  $decl target $alloc e  $decl index i }

$decl e_new   $func ($decl t 0, $decl e proto_expr) { $prop tag "new"   $decl ty t  $decl id ($call fresh_id ())  $decl init $alloc e }
$decl e_deref $func ($decl t 0, $decl e proto_expr) { $prop tag "deref" $decl ty t  $decl id ($call fresh_id ())  $decl src $alloc e }
$decl e_copy  $func ($decl t 0, $decl e proto_expr) { $prop tag "copy"  $decl ty t  $decl id ($call fresh_id ())  $decl src $alloc e }

$decl e_set $func ($decl t 0, $decl dst proto_expr, $decl v proto_expr)
  { $prop tag "set" $decl ty t  $decl id ($call fresh_id ())  $decl target $alloc dst  $decl value $alloc v }

$decl e_block $func ($decl t 0, $decl xs bslots.node) { $prop tag "block" $decl ty t  $decl id ($call fresh_id ())  $decl slots $alloc xs }
$decl e_group $func ($decl t 0, $decl xs exprs.node) { $prop tag "group" $decl ty t  $decl id ($call fresh_id ())  $decl items $alloc xs }

$decl e_closure $func ($decl t 0, $decl f 0, $decl cs exprs.node)
  { $prop tag "closure" $decl ty t  $decl id ($call fresh_id ())  $decl fn f  $decl captures $alloc cs }

$decl e_call $func ($decl t 0, $decl f proto_expr, $decl xs exprs.node, $decl tl P.boolean)
  { $prop tag "call" $decl ty t  $decl id ($call fresh_id ())  $decl callee $alloc f  $decl args $alloc xs  $decl tail tl }

$decl e_if $func ($decl t 0, $decl c proto_expr, $decl a proto_expr, $decl b proto_expr)
  { $prop tag "if" $decl ty t  $decl id ($call fresh_id ())  $decl cond $alloc c  $decl then $alloc a  $decl els $alloc b }

$decl e_switch $func ($decl t 0, $decl s proto_expr, $decl xs arms.node, $decl d proto_expr)
  { $prop tag "switch" $decl ty t  $decl id ($call fresh_id ())  $decl scrut $alloc s  $decl arms $alloc xs  $decl default $alloc d }

$decl e_do $func ($decl t 0, $decl a proto_expr, $decl b proto_expr)
  { $prop tag "do" $decl ty t  $decl id ($call fresh_id ())  $decl first $alloc a  $decl then $alloc b }

$decl e_try $func ($decl t 0, $decl v proto_expr, $decl d 0)
  { $prop tag "try" $decl ty t  $decl id ($call fresh_id ())  $decl value $alloc v  $decl disc d }

// ---------------------------------------------------------------- functions
//
// One entry per *specialisation* (§4.9), since the program is monomorphic by
// the time it gets here. `slots` is the frame size §7.2 says is knowable: the
// parameters plus every `$decl` in the body, which is what the backend declares
// as C locals.
//
// `self_tail` is what §6a's cheap case needs: a direct self tail call becomes
// `while (1)` with the parameters updated in parallel. A mutually recursive
// group needs the whole group, so that is recorded on the program instead.

// `slots` is the *type* of every frame slot, in order — §7.2 makes a frame the
// sum of its slots, and a backend cannot declare one without knowing what it
// holds. The parameters take the first of them.
// `thunk` marks a top-level `$decl` that was *not* a `$func` — its body
// computes a value rather than being one. §4.10 initialises those once, in
// source order, so a backend has to give each a static and run them at start
// up; a zero-argument `$func` looks identical otherwise and must not be.
// `env` is the type of each value this function captured, in order (§7.3) —
// the body reads them out of the environment the closure carried in, so it has
// to know their shape, and the type is where that lives.
$decl fn $func ($decl nm "", $decl ps ints.node, $decl res 0, $decl ns ints.node,
                $decl bd proto_expr, $decl st P.boolean, $decl th P.boolean,
                $decl ev ints.node)
  { $decl name nm  $decl params ps  $decl result res  $decl slots ns
    $decl body $alloc bd  $decl self_tail st  $decl thunk th  $decl env ev }

$decl proto_fn $call fn ("", ints.nil, 0, ints.nil, $call e_unit (0), false, false, ints.nil)
$decl fns $specialize P.list proto_fn

// ------------------------------------------------------------------ program
//
// `types` is the interned table: an index into it is a C struct name, and
// `T.same` is the interning key because de Bruijn binders make alpha-equivalent
// types identical (§5.5).
//
// `groups` holds the mutually recursive `$fwd` sets (§4.11, §5.5: "`$fwd` slots
// share one system of equations"). §6a contifies each into a single C function
// with a state variable, which needs the group, not just its members.

$decl group_of $func ($decl xs ints.node) { $decl members xs }
$decl proto_group $call group_of (ints.nil)
$decl groups $specialize P.list proto_group

// §3.3: "a non-`$decl` expression runs for effect and is discarded" — the value
// is discarded, not the expression. §4.10 initialises a file's items **once, in
// source order**, so such an item has a position among them and the backend has
// to keep it: `after` is the number of top-level `$decl`s that precede it, and
// `fn` the zero-argument function its expression was lifted into. `mpl_init`
// assigns globals in index order and runs an effect once the globals before it
// are assigned, which is exactly §4.10's order.
//
// Not a thunk: a thunk *is* a global and is named by its static. An effect has
// no name and nothing reads it, so it is an ordinary function that is called
// and whose result is dropped.
$decl effect $func ($decl a 0, $decl f 0) { $decl after a  $decl fn f }
$decl proto_effect $call effect (0, 0)
$decl effects $specialize P.list proto_effect

$decl program $func ($decl ts T.tys.node, $decl fs fns.node, $decl gs groups.node,
                     $decl e 0, $decl efs effects.node)
  { $decl types ts  $decl funcs fs  $decl groups gs  $decl entry e  $decl effs efs }

$decl proto_program $call program (T.tys.nil, fns.nil, groups.nil, 0, effects.nil)

// ------------------------------------------------------------------ interning
//
// Linear, which is right for the size of program stage 1 is: the table holds
// one entry per *distinct* type, and a compiler's type count is small even when
// its node count is not. A hash would need `T.show`, which allocates a string
// proportional to the whole type.

$decl found $func ($decl ok P.boolean, $decl i 0) { $decl hit ok  $decl id i }

$decl find_ty_at $func ($decl xs T.tys.node, $decl t T.proto_ty, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call T.same (xs.head, t)) ($call found (true, i))
        ($call find_ty_at (xs.tail, t, $call add (i, 1))),
  $case xs ($call found (false, i))
)

$decl find_ty $func ($decl ts T.tys.node, $decl t T.proto_ty) $call find_ty_at (ts, t, 0)

// ------------------------------------------------------------------ printing
//
// Enough to diff two lowerings and to read one by eye; the backend's own output
// is the real test.

$fwd show

$decl show_list $func ($decl xs exprs.node, $decl acc "", $decl first P.boolean) $match xs (
  $case {$prop tag "cons"}
    $call show_list (xs.tail,
        $call concat (acc, $call concat ($if first "" " ", $call show (xs.head))), false),
  $case xs acc
)

$decl show_slots $func ($decl xs bslots.node, $decl acc "") $match xs (
  $case {$prop tag "cons"}
    $call show_slots (xs.tail, $call concat (acc,
        $call concat (" [", $call concat ($call int_to_str (xs.head.slot),
        $call concat (" ", $call concat ($call show (xs.head.init), "]")))))),
  $case xs acc
)

$decl show_discs $func ($decl xs ints.node, $decl acc "", $decl first P.boolean) $match xs (
  $case {$prop tag "cons"}
    $call show_discs (xs.tail, $call concat (acc,
        $call concat ($if first "" ",", $call int_to_str (xs.head))), false),
  $case xs acc
)

$decl show_arms $func ($decl xs arms.node, $decl acc "") $match xs (
  $case {$prop tag "cons"}
    $call show_arms (xs.tail, $call concat (acc,
        $call concat (" [", $call concat ($call show_discs (xs.head.discs, "", true),
        $call concat (" ", $call concat ($call show (xs.head.body), "]")))))),
  $case xs acc
)

$decl show $func ($decl e proto_expr) $match e (
  $case {$prop tag "int"}     $call concat ("(int ", $call concat ($call int_to_str (e.v), ")")),
  $case {$prop tag "float"}   $call concat ("(float ", $call concat (e.text, ")")),
  $case {$prop tag "str"}     $call concat ("(str \"", $call concat (e.text, "\")")),
  $case {$prop tag "bool"}    $if e.v "(bool true)" "(bool false)",
  $case {$prop tag "unit"}    "(unit)",
  $case {$prop tag "panic"}   $call concat ("(panic \"", $call concat (e.msg, "\")")),
  $case {$prop tag "local"}   $call concat ("(local ", $call concat ($call int_to_str (e.slot), ")")),
  $case {$prop tag "capture"} $call concat ("(capture ", $call concat ($call int_to_str (e.slot), ")")),
  $case {$prop tag "global"}  $call concat ("(global ", $call concat ($call int_to_str (e.fn), ")")),
  $case {$prop tag "prim"}    $call concat ("(prim ", $call concat (e.name, ")")),
  $case {$prop tag "field"}
    $call concat ("(field ", $call concat ($call show (e.target),
        $call concat (" ", $call concat ($call int_to_str (e.index), ")")))),
  $case {$prop tag "new"}     $call concat ("(new ", $call concat ($call show (e.init), ")")),
  $case {$prop tag "deref"}   $call concat ("(deref ", $call concat ($call show (e.src), ")")),
  $case {$prop tag "copy"}    $call concat ("(copy ", $call concat ($call show (e.src), ")")),
  $case {$prop tag "set"}
    $call concat ("(set ", $call concat ($call show (e.target),
        $call concat (" ", $call concat ($call show (e.value), ")")))),
  $case {$prop tag "block"}
    $call concat ("(block", $call concat ($call show_slots (e.slots, ""), ")")),
  $case {$prop tag "group"}
    $call concat ("(group ", $call concat ($call show_list (e.items, "", true), ")")),
  $case {$prop tag "closure"}
    $call concat ("(closure ", $call concat ($call int_to_str (e.fn),
        $call concat (" ", $call concat ($call show_list (e.captures, "", true), ")")))),
  $case {$prop tag "call"}
    $call concat ($if e.tail "(tailcall " "(call ", $call concat ($call show (e.callee),
        $call concat (" ", $call concat ($call show_list (e.args, "", true), ")")))),
  $case {$prop tag "if"}
    $call concat ("(if ", $call concat ($call show (e.cond),
        $call concat (" ", $call concat ($call show (e.then),
        $call concat (" ", $call concat ($call show (e.els), ")")))))),
  $case {$prop tag "switch"}
    $call concat ("(switch ", $call concat ($call show (e.scrut),
        $call concat ($call show_arms (e.arms, ""),
        $call concat (" ", $call concat ($call show (e.default), ")"))))),
  $case {$prop tag "do"}
    $call concat ("(do ", $call concat ($call show (e.first),
        $call concat (" ", $call concat ($call show (e.then), ")")))),
  $case {$prop tag "try"}
    $call concat ("(try ", $call concat ($call show (e.value),
        $call concat (" ", $call concat ($call int_to_str (e.disc), ")")))),
  $case e "(?)"
)
