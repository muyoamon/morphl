// Tests for stage 1's inference traversal:
//
//   morphlc --run stage1/infer_test.mpl
//
// Each expectation is the rendered type of a source fragment, so the whole
// pipeline — lexer, parser, types, inference — is exercised end to end.

$decl I  $import "infer"
$decl T  $import "types"
$decl Pa $import "parser"
$decl P  $import "prelude"

$decl not P.not
$decl and P.and

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))

$decl check $func ($decl name "", $decl ok P.boolean)
  $if ok
      ($do ($call print ("ok   ")) ($call nl (name)))
      ($do ($call print ("FAIL ")) ($do ($call nl (name)) ($call panic (name))))

$decl check_str $func ($decl name "", $decl got "", $decl want "")
  $if ($call eq_str (got, want))
      ($do ($call print ("ok   ")) ($call nl (name)))
      ($do ($call print ("FAIL "))
      ($do ($call nl (name))
      ($do ($call nl ($call concat ("       want: ", want)))
      ($do ($call nl ($call concat ("       got:  ", got)))
           ($call panic (name))))))

// The type of the last `$decl` in a fragment, rendered.
$decl field_ty $func ($decl src "", $decl nm "")
  { $decl r $call I.check_source (src)
    $decl rty r.ty
    $decl f $match rty (
      $case {$prop tag "block"} ($call T.find_field ($call T.fields.val (rty.fields), nm)),
      $case rty T.proto_field
    )
    $decl out $if ($call eq_str (f.name, "")) "<no such field>" ($call T.show (f.ty)) }.out

$decl errs_of $func ($decl src "")
  { $decl r $call I.check_source (src)
    // `$if` does not narrow (§4.7 narrows a `$match` scrutinee, by its name).
    $decl es $call Pa.diags.val (r.errs)
    $decl out $match es (
        $case {$prop tag "cons"} es.head.msg,
        $case es ""
      ) }.out

$decl n_errs $func ($decl src "")
  { $decl r $call I.check_source (src)
    $decl out $call Pa.diags.length (r.errs, 0) }.out

// ------------------------------------------------------------------- literals

$decl t01 $call check_str ("an integer literal is Int",
  $call field_ty ("$decl x 1", "x"), "Int")
$decl t02 $call check_str ("a string literal is Str",
  $call field_ty ("$decl x \"s\"", "x"), "Str")
$decl t03 $call check_str ("a float literal is Float",
  $call field_ty ("$decl x 1.5", "x"), "Float")
// §3.2: a boolean literal's type is its own tag type, narrower than Bool.
$decl t04 $call check_str ("true has type true, not Bool",
  $call field_ty ("$decl x true", "x"), "true")
$decl t05 $call check_str ("unit", $call field_ty ("$decl x ()", "x"), "()")
$decl t06 $call check_str ("the empty block is unit too (§2.3)",
  $call field_ty ("$decl x {}", "x"), "()")

// ---------------------------------------------------------- blocks and groups

$decl t07 $call check_str ("a group is a tuple",
  $call field_ty ("$decl x (1, \"s\")", "x"), "(Int,Str)")
// §3.3: a block's type is its ordered `$decl` slots plus its props.
$decl t08 $call check_str ("a block records its fields in order",
  $call field_ty ("$decl x { $decl a 1  $decl b \"s\" }", "x"), "{a:Int,b:Str,}")
$decl t09 $call check_str ("a prop is in the type but takes no slot (§4.10)",
  $call field_ty ("$decl x { $prop k \"c\"  $decl a 1 }", "x"), "{a:Int,k=s\"c\",}")
$decl t10 $call check_str ("a trailing expression is discarded (§3.3, §10.1)",
  $call field_ty ("$decl x { $decl a 1  $call add (a, 1) }", "x"), "{a:Int,}")
$decl t11 $call check_str ("projection reads a field",
  $call field_ty ("$decl b { $decl a 1 }  $decl x b.a", "x"), "Int")
$decl t12 $call check_str ("projection reads a prop too (§4.10)",
  $call field_ty ("$decl b { $prop p 7 }  $decl x b.p", "x"), "Int")
$decl t13 $call check_str ("a group index",
  $call field_ty ("$decl g (1, \"s\")  $decl x g.2", "x"), "Str")
$decl t14 $call check_str ("a missing field is reported",
  $call errs_of ("$decl b { $decl a 1 }  $decl x b.zz"), "block has no field 'zz'")

// ------------------------------------------------------------------- storage

// §4.2: `$new` is the only way storage comes into existence.
$decl t15 $call check_str ("$new gives a reference",
  $call field_ty ("$decl x $new 0", "x"), "&Int")
$decl t16 $call check_str ("$mut gives a mutable view",
  $call field_ty ("$decl x $mut $new 0", "x"), "&mut Int")
// §4.2: "If `e` is itself a reference, it is dereferenced first."
$decl t17 $call check_str ("$new of a reference copies rather than nests",
  $call field_ty ("$decl n $new 0  $decl x $new n", "x"), "&Int")
// ----------------------------------------------- $alloc and §5.3a
//
// §3.5: storage has a **kind** as well as a qualifier. `$new` makes frame
// storage, released when the scope exits at no cost; `$alloc` draws from the
// `allocator` in lexical scope and may outlive anything. The kind is written
// `&^T` in diagnostics only — there is still no syntax for writing a type.

$decl a1 $call check_str ("$alloc gives allocated storage (§4.2a)",
  $call field_ty ("$decl x $alloc 0", "x"), "&^Int")

// §5.3: "$mut/$const produce views, and preserve the kind."
$decl a2 $call check_str ("a view preserves the kind",
  $call field_ty ("$decl x $mut $alloc 0", "x"), "&^mut Int")

// §4.2a: "As with `$new`, a reference operand is dereferenced first."
$decl a3 $call check_str ("$alloc of a reference copies rather than nests",
  $call field_ty ("$decl n $new 0  $decl x $alloc n", "x"), "&^Int")

// §5.3: "`&^T <: &T`. Allocated storage outlives every scope, so it is usable
// wherever frame storage is — never the reverse."
$decl a4 $call check ("allocated storage goes where frame storage is expected",
  $call eq_int ($call n_errs ("$decl f $func ($decl p $new 0) 1  $decl x $call f ($alloc 0)"), 0))

$decl a5 $call check ("...and frame storage does not go where allocated is",
  $call lt (0, $call n_errs ("$decl f $func ($decl p $alloc 0) 1  $decl x $call f ($new 0)")))

// §5.3a's first clause: "A frame-bound type may not appear in a function's
// result." The frame it was made in is gone by the time the caller has it.
$decl a6 $call check ("a function may not return frame storage (§5.3a)",
  $call lt (0, $call n_errs ("$decl f $func ($decl n 0) $new n")))

$decl a7 $call check ("...nor a block that merely holds some",
  $call lt (0, $call n_errs ("$decl f $func ($decl n 0) { $decl v $new n }")))

$decl a8 $call check ("...while the same function returning allocated storage is fine",
  $call eq_int ($call n_errs ("$decl f $func ($decl n 0) $alloc n"), 0))

// §5.3a's second clause: "a frame-bound value may not be written into storage
// that is not itself frame-bound". Allocated storage outlives every scope.
$decl a9 $call check ("frame storage may not be put into allocated storage",
  $call lt (0, $call n_errs ("$decl f $func ($decl n 0) $alloc { $decl v $new n }")))

// And the whole point: frame storage used *within* one scope costs nothing and
// is accepted.
$decl a10 $call check ("frame storage used inside one scope is fine",
  $call eq_int ($call n_errs ("$decl f $func ($decl n 0) { $decl t $new n  $decl r $call add (t, 1) }.r"), 0))

// §5.3a's closure clause: "A `$func` literal that captures a frame reference is
// itself frame-bound, so a closure cannot carry one out either (§7.3)." §7.3
// keeps captures out of the function type, so this is the one part of the rule
// that is not visible in the type being checked — it is recorded when the
// literal is typed.
$decl a11 $call check ("a closure capturing frame storage may not be returned (§5.3a)",
  $call lt (0, $call n_errs ($call concat (
      "$decl f $func ($decl n 0) { $decl cell $new n ",
      "$decl g $func () $call add (cell, 1)  $decl r g }.r"))))

$decl a12 $call check ("...but capturing allocated storage is fine",
  $call eq_int ($call n_errs ($call concat (
      "$decl f $func ($decl n 0) { $decl cell $alloc n ",
      "$decl g $func () $call add (cell, 1)  $decl r g }.r")), 0))

$decl a13 $call check ("...and so is calling it without carrying it out",
  $call eq_int ($call n_errs ($call concat (
      "$decl f $func ($decl n 0) { $decl cell $new n ",
      "$decl g $func () $call add (cell, 1)  $decl r $call g () }.r")), 0))

// The case a naive free-names walk gets wrong: a parameter that merely shares
// a name with frame storage outside is not a capture.
$decl a14 $call check ("a parameter shadowing outer frame storage is not a capture",
  $call eq_int ($call n_errs ($call concat (
      "$decl f $func ($decl n 0) { $decl cell $new n ",
      "$decl g $func ($decl cell 0) $call add (cell, 1)  $decl r g }.r")), 0))

$decl t18 $call check_str ("$mut needs storage (§4.3)",
  $call errs_of ("$decl x $mut 0"), "$mut expects storage, found Int; only $new creates storage")
// §4.4: `$set` writes through storage and evaluates to the written value.
$decl t19 $call check_str ("$set yields the written value",
  $call field_ty ("$decl n $mut $new 0  $decl x $set n 5", "x"), "Int")
$decl t20 $call check_str ("$set rejects a value field",
  $call errs_of ("$decl a 0  $decl x $set a 1"), "$set needs storage on the left, found Int")
$decl t21 $call check_str ("$set checks the written type",
  $call errs_of ("$decl n $mut $new 0  $decl x $set n \"s\""),
  "cannot write Str into storage of Int")
// §5.4: a reference is transparent where a value is expected.
$decl t22 $call check_str ("storage derefs into a call argument",
  $call field_ty ("$decl n $mut $new 5  $decl x $call add (n, 1)", "x"), "Int")

// ----------------------------------------------------------------- functions

// §3.4: each parameter's default fixes its type — which is why inference needs
// no unification variables here.
$decl t23 $call check_str ("a function type comes from its defaults and body",
  $call field_ty ("$decl f $func ($decl a 0, $decl b \"\") a", "f"), "[Int,Str]->Int")
$decl t24 $call check_str ("a nullary function",
  $call field_ty ("$decl f $func () 1", "f"), "[]->Int")
$decl t25 $call check_str ("a call yields the result type",
  $call field_ty ("$decl f $func ($decl a 0) a  $decl x $call f 1", "x"), "Int")
$decl t26 $call check_str ("an argument is checked against the parameter",
  $call errs_of ("$decl f $func ($decl a 0) a  $decl x $call f \"s\""),
  "argument 1 is Str, expected Int")
$decl t27 $call check_str ("too many arguments is reported",
  $call errs_of ("$decl f $func ($decl a 0) a  $decl x $call f (1, 2)"), "too many arguments")
$decl t28 $call check ("fewer arguments is fine: defaults fill in (§3.4)",
  $call eq_int ($call n_errs ("$decl f $func ($decl a 0, $decl b 0) a  $decl x $call f 1"), 0))
$decl t29 $call check_str ("calling a non-function is reported",
  $call errs_of ("$decl x $call 1 2"), "Int is not callable")
// §5.4: a parameter whose type is a reference wants storage, not a value.
$decl t30 $call check_str ("a storage parameter keeps the reference",
  $call field_ty ("$decl f $func ($decl c $mut $new 0) $set c 1  $decl n $mut $new 0  $decl x $call f (n)", "x"),
  "Int")
$decl t31 $call check_str ("...and rejects a plain value (§5.4)",
  $call errs_of ("$decl f $func ($decl c $mut $new 0) $set c 1  $decl x $call f (0)"),
  "argument 1 is Int, expected &mut Int")

// --------------------------------------------------------------- control flow

$decl t32 $call check_str ("$if joins its arms",
  $call field_ty ("$decl x $if true 1 \"s\"", "x"), "<Int,Str>")
$decl t33 $call check_str ("$if with one type does not widen",
  $call field_ty ("$decl x $if true 1 2", "x"), "Int")
$decl t34 $call check_str ("the condition must be Bool",
  $call errs_of ("$decl x $if 1 1 2"), "$if condition must be Bool, found Int")
$decl t35 $call check ("a Bool-valued call is an acceptable condition",
  $call eq_int ($call n_errs ("$decl x $if ($call eq_int (1, 1)) 1 2"), 0))
$decl t36 $call check_str ("$do has the type of its second operand (§4.8b)",
  $call field_ty ("$decl x $do 1 \"s\"", "x"), "Str")

// §4.8a: the value is the first member, the type is the union of all of them.
$decl t37 $call check_str ("$union joins every member's type",
  $call field_ty ("$decl x $union (1, \"s\")", "x"), "<Int,Str>")

// §4.7: arms are joined, and the scrutinee narrows inside each arm.
$decl t38 $call check_str ("$match joins its arms",
  $call field_ty ("$decl x $match 1 ($case 0 \"s\", $case x 1)", "x"), "<Int,Str>")
$decl t39 $call check_str ("the scrutinee narrows inside an arm (§4.7)",
  $call field_ty (
    "$decl c { $prop tag \"c\"  $decl r 1 }\n$decl s $union (c, 0)\n$decl x $match s ($case {$prop tag \"c\"} s.r, $case s 0)",
    "x"),
  "Int")

// ---------------------------------------------------------- recursion (§5.5)

// "the result is μR. B(R), or simply B if R does not occur."
// A function whose only result is its own call never returns: §3.6's ⊥.
$decl t40 $call check_str ("a function that only recurses has result bottom",
  $call field_ty ("$decl f $func ($decl n 0) $call f (n)", "f"), "[Int]->!")
$decl t41 $call check_str ("a non-recursive function has no binder",
  $call field_ty ("$decl f $func ($decl n 0) n", "f"), "[Int]->Int")
// The list from §5.5's own example, inferred rather than declared.
$decl t42 $call check_str ("recursive data is inferred, not declared",
  $call field_ty (
    "$decl f $func ($decl n 0) $if ($call eq_int (n, 0)) {} { $decl head n  $decl tail $call f ($call sub (n, 1)) }",
    "f"),
  "[Int]->mu.<(),{head:Int,tail:b0,}>")

// §4.10: props are visible throughout their block regardless of order.
// Asserted through the projection rather than the rendered block, so the test
// does not pin the fresh-variable counter.
$decl t43 $call check_str ("a prop may name a later prop",
  $call field_ty ("$decl b { $prop a c  $prop c 7 }  $decl x b.a", "x"), "Int")
// §4.10: "not ordered siblings (there is no instance to read them from)."
$decl t44 $call check_str ("a prop may not name an ordered sibling",
  $call errs_of ("$decl b { $decl d 1  $prop p d }"), "unknown name 'd'")

// §4.11: the slot's layout position is the `$fwd`, not the `$decl`.
$decl t45 $call check_str ("$fwd holds the layout position",
  $call field_ty ("$decl b { $fwd y  $decl a 1  $decl y 2 }", "b"), "{y:Int,a:Int,}")

// ------------------------------------------------------------ errors (§4.15)

// "The enclosing function's inferred return type gains `type(e) & pat` as
// union members. Error sets are therefore inferred."
$decl t46 $call check_str ("$try adds to the inferred return type",
  $call field_ty (
    "$decl f $func ($decl s \"\") { $decl v $try ($call str_to_int (s)) none  $decl out v.v }.out",
    "f"),
  "[Str]-><Int,{tag=s\"none\",}>")
$decl t47 $call check_str ("a function with no $try is unaffected",
  $call field_ty ("$decl f $func ($decl s \"\") 1", "f"), "[Str]->Int")
// §4.15: the target is the *nearest* enclosing `$func`, so error sets do not leak.
$decl t48 $call check_str ("an inner function's error set stays inside it",
  $call field_ty (
    "$decl f $func ($decl s \"\") { $decl g $func ($decl t \"\") { $decl v $try ($call str_to_int (t)) none  $decl o v.v }.o  $decl out 1 }.out",
    "f"),
  "[Str]->Int")

// --------------------------------------------------- unknown names and shapes

$decl t49 $call check_str ("an unknown name is reported",
  $call errs_of ("$decl x nope"), "unknown name 'nope'")
// A reported error is ⊥, and ⊥ <: everything (§3.6), so it does not cascade.
$decl t50 $call check ("one mistake yields one diagnostic",
  $call eq_int ($call n_errs ("$decl x $call add (nope, 1)"), 1))

// ------------------------------------------- the intrinsics have real types

$decl t51 $call check_str ("concat", $call field_ty ("$decl x $call concat (\"a\", \"b\")", "x"), "Str")
$decl t52 $call check_str ("len", $call field_ty ("$decl x $call len (\"a\")", "x"), "Int")
$decl t53 $call check_str ("eq_int yields Bool",
  $call field_ty ("$decl x $call eq_int (1, 2)", "x"), "<false,true>")
$decl t54 $call check_str ("panic yields bottom (§8)",
  $call field_ty ("$decl x $call panic (\"boom\")", "x"), "!")
$decl t55 $call check_str ("str_to_int yields an option (§8)",
  $call field_ty ("$decl x $call str_to_int (\"1\")", "x"),
  "<{tag=s\"none\",},{v:Int,tag=s\"some\",}>")
$decl t56 $call check_str ("an intrinsic's argument is checked",
  $call errs_of ("$decl x $call len (1)"), "argument 1 is Int, expected Str")

// §10.4: "Recursive return types are inferred, so adding a base case changes
// the function's type and errors surface at call sites."
$decl t57 $call check_str ("a prefix supertype is accepted as an argument (§5.1)",
  $call field_ty (
    "$decl f $func ($decl p { $decl a 0 }) p.a  $decl x $call f ({ $decl a 1  $decl b 2 })",
    "x"),
  "Int")
$decl t58 $call check_str ("...but a reordered block is not",
  $call errs_of ("$decl f $func ($decl p { $decl a 0 }) p.a  $decl x $call f ({ $decl b 2  $decl a 1 })"),
  "argument 1 is {b:Int,a:Int,}, expected {a:Int,}")

$decl done $call nl ("all inference tests passed")

// ------------------------------------------------------- $template (§4.9)

// §4.9: "`body` is **not** type-checked at declaration."
$decl t59 $call check ("a template body is not checked at declaration",
  $call eq_int ($call n_errs ("$decl t $template T $call nope_undefined (T)"), 0))
$decl t60 $call check_str ("...but it is checked at specialization",
  $call errs_of ("$decl t $template T $call nope_undefined (T)  $decl x $specialize t 0"),
  "unknown name 'nope_undefined'")

// §4.9: the argument is bound to the generic name, so the body types with it.
$decl t61 $call check_str ("a generic name stands for the argument's type",
  $call field_ty ("$decl id $template T $func ($decl x T) x  $decl f $specialize id 0", "f"),
  "[Int]->Int")
$decl t62 $call check_str ("...and a different argument gives a different type",
  $call field_ty ("$decl id $template T $func ($decl x T) x  $decl f $specialize id \"\"", "f"),
  "[Str]->Str")
$decl t63 $call check_str ("a template over a block",
  $call field_ty ("$decl p $template T { $decl a T  $decl b T }  $decl x $specialize p 1", "x"),
  "{a:Int,b:Int,}")
$decl t64 $call check_str ("several generic parameters take a group",
  $call field_ty ("$decl two $template (A, B) { $decl a A  $decl b B }  $decl x $specialize two (1, \"s\")", "x"),
  "{a:Int,b:Str,}")
$decl t65 $call check_str ("the wrong number of arguments is reported",
  $call errs_of ("$decl two $template (A, B) A  $decl x $specialize two 1"),
  "this template has 2 generic parameters, found 1")
$decl t66 $call check_str ("specializing a non-template is reported",
  $call errs_of ("$decl x $specialize 1 0"), "$specialize expects a template, found Int")
// BOOTSTRAP.md §1.1 drops §4.9's `$call`-time inference of `T`.
$decl t67 $call check_str ("calling a template directly is reported",
  $call errs_of ("$decl id $template T $func ($decl x T) x  $decl y $call id 5"),
  "$call on a template needs an explicit $specialize first (BOOTSTRAP.md §1.1)")

// The prelude's list, specialized — recursive data inside a template body.
// §5.5 requires the recursion to pass through storage, so the tail is storage;
// without it the type has no layout and the specialization is rejected.
//
// And it is `$alloc`, not `$new`: §5.3a says so in as many words — "a list
// returned to a caller is built with `$alloc`, while one built and consumed
// inside a single scope may use `$new`". `cons` returns the cell, so the cell
// outlives the frame that made it.
//
// Built with `concat` because a morphl string literal never spans a newline,
// and morphl needs no separators anyway.
$decl list_src $call concat (
  "$decl list $template T { $prop nil { $prop tag \"nil\" } ",
  $call concat (
  "$prop node $union (nil, { $prop tag \"cons\"  $decl head T  $decl tail $alloc node }) ",
  $call concat (
  "$prop cons $func ($decl h T, $decl t node) { $prop tag \"cons\"  $decl head h  $decl tail $alloc t } ",
  $call concat (
  "$prop length $func ($decl xs node, $decl acc 0) $match xs ( $case {$prop tag \"cons\"} $call length (xs.tail, $call add (acc, 1)), $case xs acc ) } ",
  "$decl ints $specialize list 0 "))))

$decl t68 $call check ("a template holding recursive data types cleanly",
  $call eq_int ($call n_errs (list_src), 0))

// §5.3a from the other side: the same list with a *frame* tail is rejected,
// because `cons` hands the cell back to a caller whose frame outlives it. This
// is the one place the two storage kinds are felt in ordinary code, and it is
// felt at the container.
$decl frame_list_src $call concat (
  "$decl list $template T { $prop nil { $prop tag \"nil\" } ",
  $call concat (
  "$prop node $union (nil, { $prop tag \"cons\"  $decl head T  $decl tail $new node }) ",
  $call concat (
  "$prop cons $func ($decl h T, $decl t node) { $prop tag \"cons\"  $decl head h  $decl tail $new t } } ",
  "$decl ints $specialize list 0 ")))

$decl t68b $call check ("...and a frame tail is rejected: the cell outlives the cons (§5.3a)",
  $call lt (0, $call n_errs (frame_list_src)))

// ...and the same list with the tail left as a value is rejected: §5.5 needs
// the recursion to pass through storage or the type has no layout. The error
// lands on the specialization, since a template body is checked there (§10.7).
$decl unguarded_src $call concat (
  "$decl list $template T { $prop nil { $prop tag \"nil\" } ",
  $call concat (
  "$prop node $union (nil, { $prop tag \"cons\"  $decl head T  $decl tail node }) } ",
  "$decl ints $specialize list 0 "))

$decl t68c $call check ("a recursive type that does not pass through storage is rejected",
  $call lt (0, $call n_errs (unguarded_src)))
// The raw type, for assertions that should not pin a variable's number.
$decl ty_of $func ($decl src "", $decl nm "")
  { $decl r $call I.check_source (src)
    $decl rty r.ty
    $decl f $match rty (
      $case {$prop tag "block"} ($call T.find_field ($call T.fields.val (rty.fields), nm)),
      $case rty T.proto_field
    )
    $decl out f.ty }.out

// §5.5's knot, asserted by what it means rather than by how it renders: a cell
// built by `cons` is a member of the recursive type `node` names.
$decl t69 $call check ("a cons cell is a subtype of the inferred list type",
  $call T.sub ($call ty_of ($call concat (list_src, "$decl c $call ints.cons (5, ints.nil)"), "c"),
               $call ty_of ($call concat (list_src, "$decl n ints.node"), "n")))
$decl t70 $call check_str ("nil carries its tag",
  $call field_ty ($call concat (list_src, "$decl n ints.nil"), "n"), "{tag=s\"nil\",}")
$decl t71 $call check_str ("a prop function over the recursive type returns Int",
  $call field_ty ($call concat (list_src, "$decl l $call ints.length (ints.nil, 0)"), "l"), "Int")
// The element type really is the one the list was specialized at.
$decl t71b $call check_str ("cons rejects the wrong element type",
  $call errs_of ($call concat (list_src, "$decl c $call ints.cons (\"s\", ints.nil)")),
  "argument 1 is Str, expected Int")

// §4.9: "Typing is memoized per **argument type**."
$decl t72 $call check ("specializing twice at the same type is consistent",
  $call eq_str ($call field_ty ($call concat (list_src, "$decl a ints.nil  $decl b ($specialize list 0).nil"), "a"),
                $call field_ty ($call concat (list_src, "$decl a ints.nil  $decl b ($specialize list 0).nil"), "b")))
$decl t73 $call check ("two element types give two lists",
  $call not ($call eq_str (
    $call field_ty ($call concat (list_src, "$decl a ints.node"), "a"),
    $call field_ty ($call concat (list_src, "$decl s ($specialize list \"\").node"), "s"))))

$decl done2 $call nl ("all template tests passed")

// ------------------------------------------- mutual recursion (§4.11, §5.5)

// §5.5: "`$fwd` slots share one system of equations." §12's own example.
$decl evenodd $call concat (
  "$fwd odd ",
  $call concat (
  "$decl even $func ($decl n 0) $if ($call eq_int (n, 0)) true  ($call odd  ($call sub (n, 1))) ",
  "$decl odd  $func ($decl n 0) $if ($call eq_int (n, 0)) false ($call even ($call sub (n, 1))) "))

$decl t74 $call check ("mutual recursion through $fwd types cleanly",
  $call eq_int ($call n_errs (evenodd), 0))
$decl t75 $call check_str ("both halves infer Bool -> Bool",
  $call field_ty (evenodd, "even"), "[Int]-><false,true>")
$decl t76 $call check_str ("...and so does the one declared by $fwd",
  $call field_ty (evenodd, "odd"), "[Int]-><false,true>")

// §4.11: the layout position is the `$fwd`, not the completing `$decl`.
$decl t77 $call check_str ("the $fwd holds the slot even with a function",
  $call field_ty ($call concat ("$decl b { ", $call concat (evenodd, "} ")), "b"),
  "{odd:[Int]-><false,true>,even:[Int]-><false,true>,}")

// A three-way cycle needs more than one round of substitution.
$decl three_cycle $call concat (
  "$fwd b $fwd c ",
  $call concat (
  "$decl a $func ($decl n 0) $if ($call eq_int (n, 0)) 1 ($call b ($call sub (n, 1))) ",
  $call concat (
  "$decl b $func ($decl n 0) $if ($call eq_int (n, 0)) \"s\" ($call c ($call sub (n, 1))) ",
  "$decl c $func ($decl n 0) $if ($call eq_int (n, 0)) true ($call a ($call sub (n, 1))) ")))

$decl t78 $call check ("a three-way cycle types cleanly",
  $call eq_int ($call n_errs (three_cycle), 0))
$decl t79 $call check_str ("every member of the cycle sees the whole union",
  $call field_ty (three_cycle, "a"), "[Int]-><Int,Str,true>")

// A `$fwd` never completed is still an error (§4.11) — unchanged by any of this.
$decl t80 $call check ("an uncompleted $fwd still reports",
  $call lt (0, $call n_errs ("$decl b { $fwd never  $decl other 1 }")))

$decl done3 $call nl ("all mutual-recursion tests passed")
