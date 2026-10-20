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
$decl field_ty $func ($decl src "", $decl nm "") {
  $decl r   $call I.check_source (src)
  $decl rty r.ty
  $decl f $match rty (
    $case {$prop tag "block"} ($call T.find_field ($call T.fields.val (rty.fields), nm)),
    $case rty T.proto_field
  )
  $decl ret $if ($call eq_str (f.name, "")) "<no such field>" ($call T.show (f.ty))
}.ret

$decl errs_of $func ($decl src "") {
  $decl r $call I.check_source (src)
  // `$if` does not narrow (§4.7 narrows a `$match` scrutinee, by its name).
  $decl es $call Pa.diags.val (r.errs)
  $decl ret $match es (
      $case {$prop tag "cons"} es.head.msg,
      $case es ""
    )
}.ret

// Whether `m` is among the diagnostics, answering `m` if so — for a check whose
// own report is followed by the cascade it causes, so it is not the newest.
$decl has_err_in $func ($decl es Pa.diags.node, $decl m "") $match es (
  $case {$prop tag "cons"}
    $if ($call eq_str (es.head.msg, m)) m ($call has_err_in ($call Pa.diags.val (es.tail), m)),
  $case es ""
)

$decl has_err $func ($decl src "", $decl m "") {
  $decl r   $call I.check_source (src)
  $decl ret $call has_err_in ($call Pa.diags.val (r.errs), m)
}.ret

$decl n_errs $func ($decl src "") {
  $decl r   $call I.check_source (src)
  $decl ret $call Pa.diags.length (r.errs, 0)
}.ret

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
// Reported as an ordinary unknown name, because the prop-only environment does
// not contain it at all — which is the more useful thing to say, so the §4.10
// check below deliberately defers to it for a name that does not resolve.
$decl t44 $call check_str ("a prop may not name an ordered sibling",
  $call errs_of ("$decl b { $decl d 1  $prop p d }"), "unknown name 'd'")

// §4.10: "`e` must be fully evaluable by the compiler … Never `$new`, never
// `$call`." Nothing enforced this, and the consequences were live: a `$call` in a
// prop ran at *run time* under stage 0, and a prop over an enclosing parameter
// became a per-call value there while the backend refused it at each use. §4.10
// also said an initializer "may reference … enclosing scopes", which cannot hold
// alongside "fully evaluable" — a parameter is an enclosing scope. The spec now
// says enclosing *compile-time* bindings, because the alternative is incoherent:
// a prop's value is part of its block's type and §5.1 matches props by value
// equality, so a prop reading a parameter gives its block a type per call.
$decl t44b $call check_str ("a $prop may not be a $call",
  $call errs_of ("$decl f $func () 3  $decl b { $prop p $call f () }"),
  "a $prop must be a constant expression (§4.10), and $call is not")

$decl t44c $call check_str ("a $prop may not read an enclosing parameter",
  $call errs_of ("$decl mk $func ($decl x 0) { $prop tag x  $decl y 1 }"),
  "a $prop must be a constant expression (§4.10), and 'x' is not")

// §4.10 allows "a block made only of props"; one with a `$decl` has a layout, so
// it is a runtime value and cannot be a compile-time constant.
$decl t44d $call check_str ("a $prop may not be a block with a $decl",
  $call errs_of ("$decl b { $prop p { $decl y 1 }  $decl z 2 }"),
  "a $prop must be a constant expression (§4.10), and a block with a $decl in it is not")

// And the legitimate shapes stay legitimate: a `$func`, a `$union`, a prop-only
// block, a scalar, and a sibling prop by name (t43 above).
$decl t44e $call check_str ("the compile-time shapes are accepted",
  $call errs_of ($call concat ("$decl b { $prop f $func ($decl n 0) n  $prop u $union (1, 2) ",
                               " $prop n { $prop two 2 }  $prop k 7 }")), "")

// §4.9's compile-time generics. A generic a prop reads is compile-time: the prop's
// value is part of the type, so the generic's argument must be a constant, and its
// value joins the memo key. `$specialize t 5` and `$specialize t 6` are two types.
$decl t44j $call check_str ("a prop may read a generic, given a constant",
  $call errs_of ("$decl t $template T { $prop k T }  $decl s $specialize t 5  $decl x s.k"), "")

$decl t44j2 $call check_str ("...and the value is in the type",
  $call field_ty ("$decl t $template T { $prop k T }  $decl s $specialize t 5", "s"), "{k=i5,}")

$decl t44j3 $call check_str ("...so two values are two types",
  $call errs_of ($call concat ("$decl t $template T { $prop k T }",
      $call concat ("  $decl f $func ($decl x $specialize t 5) 0",
                    "  $decl y $call f ($specialize t 6)"))),
  "argument 1 is {k=i6,}, expected {k=i5,}")

$decl t44k $call check_str ("a compile-time generic's argument must be a constant",
  $call errs_of ("$decl t $template T { $prop k T.a }  $decl s $specialize t { $decl a 1 }"),
  "'T' reaches $prop k, so its argument must be a constant expression (§4.9), and a block with a $decl in it is not")

$decl t44k2 $call check_str ("...which a $decl is not",
  $call errs_of ("$decl t $template T { $prop k T }  $decl n 5  $decl s $specialize t n"),
  "'T' reaches $prop k, so its argument must be a constant expression (§4.9), and 'n' is not")

// §4.10's constant expressions, judged after specialisation: a `$specialize`
// argument inside a prop is evaluated, so it must be a name or a constant — and a
// body with a `$decl` has storage, which no constant can own.
$decl t44o $call check_str ("a $call hidden in a prop's $specialize argument is refused",
  $call errs_of ($call concat ("$decl f $func () 3  $decl t $template T { $prop k 1 }",
                               "  $decl b { $prop p $specialize t $call f () }")),
  "a $prop must be a constant expression (§4.10), and $call is not")

$decl t44p $call check_str ("a prop may not hold an instance with storage",
  $call errs_of ($call concat ("$decl cell $template T { $decl v $mut $alloc T }",
                               "  $decl b { $prop c $specialize cell 1 }")),
  "a $prop must be a constant expression (§4.10), and a $specialize of a template whose body has a $decl is not")

$decl t44q $call check_str ("a $union's first member is evaluated, so it is held too",
  $call errs_of ("$decl f $func () 3  $decl b { $prop u $union ($call f (), 2) }"),
  "a $prop must be a constant expression (§4.10), and $call is not")

// §4.10: "never `$impl` or `$traitsof`, which make references (§6)." A trait object
// refers to a value, so it is not a constant, and a prop may not hold one.
$decl t44s $call check_str ("a prop may not hold a $traitsof",
  $call has_err ("$decl p { $prop area 0 }  $decl b { $prop t $traitsof p }",
      "a $prop must be a constant expression (§4.10), and $traitsof, which makes a trait object (§6), is not"),
  "a $prop must be a constant expression (§4.10), and $traitsof, which makes a trait object (§6), is not")

$decl t44t $call check_str ("a prop may hold an $impl of constants (its value is the base's)",
  $call has_err ("$decl p { $prop area 0 }  $decl b { $prop t $impl 7 ($traitsof p) {} }",
      "a $prop must be a constant expression (§4.10), and $impl, which makes a trait object (§6), is not"),
  "")

$decl t44t2 $call check_str ("...but not one whose base is a runtime binding",
  $call has_err ("$decl p { $prop area 0 }  $decl n 7  $decl b { $prop t $impl n ($traitsof p) {} }",
      "a $prop must be a constant expression (§4.10), and 'n' is not"),
  "a $prop must be a constant expression (§4.10), and 'n' is not")

// §4.10's receiver: inside a member, the name of the `$decl` holding its block is the
// value the member was reached through — a reference at the declaration's qualifier.
$decl t44u $call check_str ("a member reads its receiver's fields",
  $call field_ty ($call concat ("$decl rect { $decl w 3  $decl h 4",
      "  $prop area $func () $call mul (rect.w, rect.h) }  $decl a $call rect.area ()"), "a"),
  "Int")

$decl t44u2 $call check_str ("...with no error",
  $call errs_of ($call concat ("$decl rect { $decl w 3  $decl h 4",
      "  $prop area $func () $call mul (rect.w, rect.h) }  $decl a $call rect.area ()")), "")

// Only the qualifier and the fields are compared: the props render as content-derived
// identities, which a test may not pin.
$decl t44v $call check_str ("the receiver of a value is read-only",
  $call slice ($call field_ty ("$decl b { $decl w 3  $prop me $func () b }  $decl t $call b.me ()",
      "t"), 0, 14),
  "&const {w:Int,")

$decl t44v2 $call check_str ("a member that writes its receiver needs it mutable, and says so",
  $call slice ($call field_ty (
      "$decl b $mut $alloc { $decl w 3  $prop again $func () $set b b }  $decl t b.again", "t"),
      0, 3),
  "mut")

$decl t44v3 $call check_str ("...and through a read-only one, cannot (§5.3)",
  $call errs_of ("$decl b { $decl w 3  $prop again $func () $set b b }"),
  "$set through a read-only reference (§5.3)")

$decl t44v4 $call check_str ("a member that only reads stays unmarked, even on $mut storage",
  $call slice ($call field_ty ("$decl b $mut $alloc { $decl w 3  $prop me $func () b.w }  $decl t b.me",
      "t"), 0, 2),
  "[]")

$decl t44w $call check_str ("a block declared inside a function has its receiver too",
  $call errs_of ($call concat ("$decl f $func () { $decl r { $decl w 2  $prop g $func () r.w }",
      "  $decl ret $call r.g () }.ret")), "")

// A member is typed provisionally, quietly, before its receiver's type exists. A block in
// the member's body used to end that quiet pass early, so its placeholder errors came out
// as real ones — "cannot project '.top' from v3" for `std/mem`'s arena.
$decl t44w2 $call check_str ("a member whose body is a block reads its receiver",
  $call errs_of ($call concat ("$decl f $func () { $decl r { $decl w 2  $prop g $func () ",
      "{ $decl p r.w  $decl ret p }.ret }  $decl ret $call r.g () }.ret")), "")

$decl t44x $call check_str ("a parameter sharing the declaring name is not the receiver",
  $call field_ty ("$decl b { $decl w 3  $prop g $func ($decl b 0) b }  $decl t $call b.g (5)", "t"),
  "Int")

// A name is fine as an argument, whatever it is bound to, when the generic it
// is passed to is not compile-time: only its type reaches the specialisation.
$decl t44r $call check_str ("a runtime name may be a non-compile-time argument",
  $call errs_of ($call concat ("$decl t $template T { $prop mk $func ($decl v T) v }",
                               "  $decl n 5  $decl b { $prop s $specialize t n }")), "")

// ...but the type-only positions stay legal: a parameter default, a `$union`
// member after the first, and a nested `$specialize` — the shapes the prelude's
// `list T` is written in.
$decl t44l $call check_str ("a generic in a type-only position of a prop is fine",
  $call errs_of ($call concat ("$decl t $template T { $prop mk $func ($decl v T) v  $prop u $union (1, T) }",
                               "  $decl s $specialize t 5  $decl x $call s.mk (3)")), "")

// §4.9's self-specialisation. The template's own name used to be §5.5's
// placeholder in the environment its body is typed in, so `$specialize box T`
// inside `box` said "expects a template, found v1". A projection off the
// in-progress entry needs the body typed a second time against the first answer.
$decl t44m $call check_str ("a template may specialise itself",
  $call errs_of ($call concat ("$decl box $template T { $prop mk $func ($decl v T) { $decl val v }",
      $call concat ("  $prop again $func ($decl v T) $call ($specialize box T).mk (v) }",
      "  $decl b $specialize box 0  $decl x $call b.again (5)  $decl y x.val"))), "")

// "A chain of *distinct* argument types is unbounded; there is a fixed
// instantiation depth limit and exceeding it is an error."
$decl t44n $call check_str ("a growing chain of specialisations stops at the depth limit",
  $call has_err ($call concat ("$decl grow $template T { $prop up $func ($decl v T)",
      $call concat (" $call ($specialize grow { $decl inner T }).up ({ $decl inner v }) }",
      "  $decl g $specialize grow 0")),
      "$specialize: the instantiation depth limit (64) is exceeded — a chain of distinct argument types (§4.9)"),
  "$specialize: the instantiation depth limit (64) is exceeded — a chain of distinct argument types (§4.9)")

// §4.7's first fit, and §5.7's reason it bites. A pattern is a type-only position
// and there is no type syntax, so `$case 1` denotes `Int` and claims every integer
// — the second arm then answers for nothing, silently, and `classify (7)` returns
// the *first* arm's value. This was a documented footgun with no diagnostic.
$decl t44f $call check_str ("an arm covering the whole scrutinee kills the arms after it",
  $call errs_of ("$decl f $func ($decl n 0) $match n ($case 1 100, $case n 200)"),
  "this arm's pattern is the whole scrutinee type, so the arms after it cannot be reached (§4.7 is first fit). A pattern is a *type* (§5.7): `$case 1` means Int, not the value 1")

// The test that keeps it usable: §5.6 requires exhaustiveness and BOOTSTRAP §1.3
// makes a trailing catch-all the idiom throughout stage 1, so an arm the *types*
// say is unreachable is the normal shape of correct code. Only an arm that covers
// everything by itself is evidence of the mistake — which is why the check asks
// about the whole scrutinee and not about what earlier arms left.
$decl t44g $call check_str ("...but a trailing catch-all after exhaustive arms is fine",
  $call errs_of ($call concat ("$decl a { $prop k \"a\" }  $decl b { $prop k \"b\" } ",
      "$decl f $func ($decl x $union (a, b)) $match x ($case {$prop k \"a\"} 1, $case {$prop k \"b\"} 2, $case x 3)")),
  "")

// §4.15: "Outside a `$func` (file top level, prop initializer) it is a compile
// error." Nothing enforced this. Such a program was rejected only *incidentally* —
// the backend could not coerce the matched member into the thunk's result type —
// with a message that named the symptom rather than the rule.
$decl t44h $call check_str ("$try outside a $func is refused",
  $call errs_of ("$decl v $union (1, none)  $decl x $try v none"),
  "$try is only valid inside a $func: it returns from the nearest enclosing one, and a file's top level or a $prop initializer has none (§4.15)")

// And the case that keeps it usable: a `$try` nested inside a `$func` is fine
// wherever that `$func` lives, including one a `$prop` holds — §4.15 is about
// having no enclosing function, not about where the function sits.
$decl t44i $call check_str ("...but one inside a $func is fine, even a prop-held one",
  $call errs_of ("$decl v $union (1, none)  $decl b { $prop p $func () $try v none }"), "")

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
// §4.9's application: a default that is exactly `T`, and a `$func` default mentioning it.
// (Stage 0 still refuses it — BOOTSTRAP.md §1.1 keeps it out of the subset.)
$decl t67 $call check_str ("application infers T from an argument",
  $call field_ty ("$decl id $template T $func ($decl x T) x  $decl y $call id (\"s\")", "y"), "Str")
$decl t67b $call check_str ("application reads a function argument's result type",
  $call field_ty ("$decl run $template R $func ($decl g $func () R) $call g ()  $decl y $call run ($func () 4)", "y"),
  "Int")
$decl t67c $call check_str ("a generic no argument shapes is reported",
  $call errs_of ("$decl id $template T $func ($decl x T) x  $decl y $call id ()"),
  "cannot infer 'T' from this call: its argument is not passed; write the $specialize (§4.9)")
$decl t67d $call check_str ("application needs a $func body",
  $call errs_of ("$decl b $template T { $prop k $func ($decl x T) x }  $decl y $call b (1)"),
  "$call on a template needs its body to be a $func, which §4.9 infers its generics from; write the $specialize")
$decl t67e $call check_str ("a compile-time generic is never inferred",
  $call errs_of ("$decl s $template N $func ($decl x N) { $prop k N }  $decl y $call s (1)"),
  "this template has a compile-time generic, which application never infers; write the $specialize (§4.9)")

// §4.9's bounds (TRAITS.md, design point 6): checked at every specialisation, explicit or by
// application, with the generics bound to the arguments — so an F-bound names the generic
// itself. A failed bound is what is reported; the body is not typed.
$decl t67f $call check_str ("a trait bound accepts a conforming argument",
  $call errs_of ("$decl sp { $prop area $func () 0 }  $decl d $template ($decl S $traitsof sp) $func ($decl s S) 1  $decl sq { $prop area $func () 9 }  $decl y $call d (sq)"),
  "")
$decl t67g $call check_str ("...and refuses one that does not conform",
  $call errs_of ("$decl sp { $prop area $func () 0 }  $decl d $template ($decl S $traitsof sp) $func ($decl s S) 1  $decl y $call d (5)"),
  "the argument for 'S' does not satisfy its bound: Int is not trait{area:[]->Int,} (§4.9)")
$decl t67h $call check_str ("an F-bound names the generic it bounds",
  $call errs_of ("$decl ilt lt  $decl op $template T { $prop lt $func ($decl o T) true }  $decl m $template ($decl K $traitsof ($specialize op K)) $func ($decl a K) a  $decl q { $decl x 1  $prop lt $func ($decl o q) true }  $decl y $call m (q)"),
  "")
// A prefix, since the rest names a prop's content-derived identity.
$decl begins $func ($decl s "", $decl p "")
  $if ($call lt ($call len (s), $call len (p))) false
      ($call eq_str ($call slice (s, 0, $call len (p)), p))
$decl t67i $call check ("...and refuses a type whose member takes something else",
  $call begins ($call errs_of ("$decl op $template T { $prop lt $func ($decl o T) true }  $decl m $template ($decl K $traitsof ($specialize op K)) $func ($decl a K) a  $decl q { $prop lt $func ($decl o 0) true }  $decl y $call m (q)"),
      "the argument for 'K' does not satisfy its bound: "))
$decl t67j $call check_str ("an explicit $specialize is checked too",
  $call errs_of ("$decl sp { $prop area $func () 0 }  $decl d $template ($decl S $traitsof sp) $func ($decl s S) 1  $decl y $specialize d 5"),
  "the argument for 'S' does not satisfy its bound: Int is not trait{area:[]->Int,} (§4.9)")

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
$decl ty_of $func ($decl src "", $decl nm "") {
  $decl r   $call I.check_source (src)
  $decl rty r.ty
  $decl f $match rty (
    $case {$prop tag "block"} ($call T.find_field ($call T.fields.val (rty.fields), nm)),
    $case rty T.proto_field
  )
  $decl ret f.ty
}.ret

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

// ------------------------------------------------- C callbacks (§4.16 rule 2)

// "C callbacks must be capture-free. A `$func` maps to a C function pointer only
// if its captured set is empty … Captures are not in the type (§7.3), so this is a
// property of the *expression* in the argument position: it holds when the
// compiler can see which `$func` literal the value came from."
//
// So the check has exactly three answers, and all three are here. A literal is
// seen. A name bound to a literal by one `$decl` is seen. Anything else is not,
// which is what "a closure arriving through a mutable function slot is rejected
// because it cannot be seen" means.
$decl xsig "$decl cb $extern \"host_apply\" $func ($decl f ($func ($decl n 0) n), $decl x 0) 0 "

$decl t81 $call check_str ("a capture-free literal crosses",
  $call errs_of ($call concat (xsig,
      "$decl m $func () $call cb ($func ($decl n 0) ($call mul (n, 2)), 21)")), "")

$decl t82 $call check_str ("a capturing literal is refused, and the capture named",
  $call errs_of ($call concat (xsig,
      "$decl m $func () { $decl k 3  $decl r $call cb ($func ($decl n 0) ($call mul (n, k)), 21) }.r")),
  "a callback passed to C must be capture-free (§4.16 rule 2): it captures k")

// Reading a *global* is not a capture — §7.3 reaches one through a static, not
// through the environment word — so a literal that names a top-level `$decl` or a
// root-block intrinsic is still capture-free. Without this the rule would reject
// nearly every callback anyone would write.
$decl t83 $call check_str ("naming a global is not capturing it",
  $call errs_of ($call concat ("$decl two 2 ", $call concat (xsig,
      "$decl m $func () $call cb ($func ($decl n 0) ($call mul (n, two)), 21)"))), "")

$decl t84 $call check_str ("a name bound to a capture-free literal crosses",
  $call errs_of ($call concat (xsig,
      "$decl d $func ($decl n 0) $call mul (n, 2)  $decl m $func () $call cb (d, 21)")), "")

$decl t85 $call check_str ("...and one bound to a capturing literal does not",
  $call errs_of ($call concat (xsig,
      "$decl m $func () { $decl k 3  $decl c $func ($decl n 0) ($call mul (n, k))  $decl r $call cb (c, 21) }.r")),
  "a callback passed to C must be capture-free (§4.16 rule 2): c captures k")

// The mutable slot §4.16 names outright: the value read out of it could have been
// written anywhere, so no literal is in view.
$decl t86 $call check_str ("a function read out of a $mut slot is refused",
  $call errs_of ($call concat (xsig,
      "$decl d $func ($decl n 0) $call mul (n, 2) $decl m $func () { $decl s $mut $new d  $decl r $call cb (s, 21) }.r")),
  "a callback passed to C must be capture-free (§4.16 rule 2): s is not a $decl of a $func literal")

// The rule is about crossing into C, so an ordinary morphl call is untouched:
// §7.3's pair carries the environment and a capture costs nothing there.
$decl t87 $call check_str ("an ordinary higher-order call is unaffected",
  $call errs_of ($call concat (
      "$decl ap $func ($decl f ($func ($decl n 0) n), $decl x 0) $call f (x) ",
      "$decl m $func () { $decl k 3  $decl r $call ap ($func ($decl n 0) ($call mul (n, k)), 21) }.r")),
  "")

$decl done4 $call nl ("all C-callback tests passed")

// ------------------------------------------- §4.11: reads before a $fwd completes
//
// "References to `name` before its completing `$decl` are allowed only inside a
// `$func` or `$template` body" — and a body an initializer *calls* runs before
// the `$decl` too. Stage 0 refuses each of these at run time; the checker
// accepted all of them, and the compiled backend gave them a value.
$decl fwmsg $func ($decl nm "", $decl via "")
  $call concat ("'", $call concat (nm,
      $call concat ("' is read before the $decl completing its $fwd has run (§4.11): this runs first and reaches a call to '",
      $call concat (via, "', whose body reads it"))))

$decl t88 $call check_str ("a $fwd name read directly before its $decl",
  $call errs_of ("$fwd y  $decl x y  $decl y 7"),
  "'y' is read before the $decl completing its $fwd has run (§4.11); until then only a $func or $template body may name it")

$decl t88b $call check_str ("...and through a call made before it",
  $call errs_of ("$fwd f  $decl g $func () $call f ()  $decl x $call g ()  $decl f $func () 7"),
  $call fwmsg ("f", "g"))

// The reader is named, not the first callee: that is the body to look at.
$decl t88c $call check_str ("...and through a chain of calls",
  $call errs_of ("$fwd v  $decl k $func () v  $decl h $func () $call k ()  $decl y $call h ()  $decl v 5"),
  $call fwmsg ("v", "k"))

// The completing `$decl`'s own initializer runs before its slot is filled.
$decl t88d $call check_str ("...and from the completing $decl's own initializer",
  $call errs_of ("$fwd v  $decl k $func () v  $decl v $call k ()"),
  $call fwmsg ("v", "k"))

$decl t88e $call check_str ("...and inside a nested block",
  $call errs_of ("$decl b { $fwd f  $decl g $func () $call f ()  $decl x $call g ()  $decl f $func () 7 }"),
  $call fwmsg ("f", "g"))

// A `$func` literal called where it stands runs where it stands.
$decl t88f $call check_str ("...and through a $func literal in callee position",
  $call errs_of ("$fwd v  $decl x $call ($func () v) ()  $decl v 5"),
  "'v' is read before the $decl completing its $fwd has run (§4.11); until then only a $func or $template body may name it")

// What must stay legal — the ordinary use of `$fwd` is exactly a body naming it.
$decl t88g $call check_str ("mutual recursion through $fwd is unaffected",
  $call errs_of ("$fwd ev  $decl od $func ($decl n 0) $call ev (n)  $decl ev $func ($decl n 0) n  $decl r $call od (3)"),
  "")

$decl t88h $call check_str ("a call between that does not reach the name is fine",
  $call errs_of ("$fwd f  $decl g $func () 1  $decl x $call g ()  $decl h $func () $call f ()  $decl f $func () 7"),
  "")

$decl t88i $call check_str ("building a closure that names it runs nothing",
  $call errs_of ("$fwd f  $decl mk $func () $func () $call f ()  $decl c $call mk ()  $decl f $func () 7"),
  "")

$decl t88j $call check_str ("a parameter sharing the name is not the slot",
  $call errs_of ("$fwd v  $decl s $func ($decl v 0) v  $decl x $call s (1)  $decl v 5"),
  "")

// §4.8a evaluates a `$union` to its first member; the rest are type-only (§5.7).
$decl t88k $call check_str ("a later $union member is not a read",
  $call errs_of ("$fwd v  $decl x $union (0, v)  $decl v 5"),
  "")

$decl done5 $call nl ("all $fwd-initialisation tests passed")

// §4.13: `$traitsof e` is `e`'s props' signatures, `e`'s type abstracted as `Self`.
$decl tt01 $call check_str ("$traitsof a name gives its props' signatures",
  $call field_ty ("$decl s { $prop area $func () 3  $decl w 1 }  $decl x $traitsof s", "x"), "trait{area:[]->Int,}")

$decl tt02 $call check_str ("$traitsof takes an expression literal",
  $call field_ty ("$decl x $traitsof { $prop k $func ($decl n 0) n }", "x"), "trait{k:[Int]->Int,}")

// TRAITS.md: a trait is its props' signatures as written. A parameter defaulted to the
// declaring name is that concrete type in the trait — not `Self`, which no longer exists —
// so an object over the block takes an `s` and nothing else.
$decl tt03 $call check_str ("a trait records the declaring name as that type",
  $call errs_of ("$decl s { $prop eq $func ($decl o s) true }  $decl x $traitsof s  $decl y $call x.eq (s)"),
  "")
$decl tt03b $call check ("...so another type is refused",
  $call not ($call eq_str ($call errs_of (
      "$decl s { $prop eq $func ($decl o s) true }  $decl x $traitsof s  $decl y $call x.eq (5)"), "")))

// TRAITS.md, design point 7: a trait naming itself is tied by §5.5, so its own members are
// in it — `bigger [!]` before, which nothing conformed to — through the block's name and
// through a specialisation of the template being typed.
$decl tt03c $call check_str ("a trait naming itself by its block's name closes",
  $call errs_of ($call concat ("$decl p { $prop area $func () 0  $prop big $func ($decl o $traitsof p) true }",
      $call concat ("  $decl q { $prop area $func () 1  $prop big $func ($decl o $traitsof p) true }",
          "  $decl u $func ($decl s $traitsof p) 0  $decl v $call u (q)"))), "")
$decl tt03d $call check_str ("...and its members are typed against it",
  $call errs_of ("$decl p { $decl k 1  $prop size $func () p.k  $prop big $func ($decl o $traitsof p) $call lt ($call o.size (), 2) }"),
  "")
$decl tt03e $call check_str ("a trait naming its own specialisation closes",
  $call errs_of ($call concat ("$decl s $template T { $prop first $func () T  $prop rest $func () $traitsof $alloc ($specialize s T) }",
      $call concat ("  $decl t $traitsof ($specialize s 0)",
          "  $decl c { $prop first $func () 4  $prop rest $func () $traitsof c }  $decl u $func ($decl x t) 0  $decl v $call u (c)"))),
  "")

$decl tt04 $call check_str ("a member is read through the object",
  $call field_ty ("$decl s { $prop area $func () 3 }  $decl o $traitsof s  $decl x o.area", "x"), "[]->Int")

// Every member of a trait object is callable: every implementation has the trait's shape,
// so there is no object-safety rule left to apply (TRAITS.md).
$decl tt05 $call check_str ("a member taking its block's type is callable through an object",
  $call errs_of ("$decl s { $prop eq $func ($decl o s) true }  $decl o $traitsof s  $decl x o.eq"),
  "")

$decl tt06 $call check_str ("a trait object has only its members",
  $call errs_of ("$decl s { $prop k $func () 1  $decl w 2 }  $decl o $traitsof s  $decl x o.w"), "this trait has no member 'w'")

$decl tt07 $call check_str ("$traitsof needs a block",
  $call errs_of ("$decl x $traitsof 1"), "$traitsof needs a block, found Int")

// §5.3a: a literal operand is placed in frame storage, so the object cannot leave the frame.
$decl tt08 $call check_str ("an object over a literal is frame-bound",
  $call errs_of ("$decl f $func () $traitsof { $prop k $func () 1 }"), "this function's result holds frame storage made in this call (a trait object referring to frame storage), which ends when it returns; return a place the caller passed in, or $alloc storage (§5.3a)")

$decl tt09 $call check_str ("an object over a top-level name is not",
  $call errs_of ("$decl s { $prop k $func () 1 }  $decl f $func () $traitsof s"), "")

$decl tt10 $call check_str ("an object over allocated storage is not",
  $call errs_of ("$decl f $func () $traitsof $alloc { $prop k $func () 1 }"), "")

$decl done6 $call nl ("all $traitsof tests passed")

// §4.12: `$impl x trait override` is `x`'s value with the override's props added.
$decl im_shape "$decl shape { $prop area $func () 0 }  "

$decl im01 $call check_str ("$impl over a block adds its props to the block",
  $call field_ty ($call concat (im_shape,
      "$decl b { $decl w 3 }  $decl x $impl b ($traitsof shape) { $prop area $func () 7 }  $decl y $call x.area ()"),
      "y"), "Int")

$decl im02 $call check_str ("...and keeps the base's fields",
  $call field_ty ($call concat (im_shape,
      "$decl b { $decl w 3 }  $decl x $impl b ($traitsof shape) { $prop area $func () 7 }  $decl y x.w"),
      "y"), "Int")

// The receiver is the `$decl` over the `$impl`, at the result's type (§4.10, §4.12).
$decl im03 $call check_str ("$impl over an Int, whose member reads the receiver",
  $call errs_of ($call concat (im_shape,
      "$decl n 7  $decl n_s $impl n ($traitsof shape) { $prop area $func () $call add (n_s, 0) }  $decl y $call n_s.area ()")),
  "")

$decl im04 $call check_str ("...and is still usable as its base (§5.1)",
  $call field_ty ($call concat (im_shape,
      "$decl n 7  $decl n_s $impl n ($traitsof shape) { $prop area $func () 1 }  $decl y $call add (n_s, 1)"),
      "y"), "Int")

$decl im05 $call check_str ("...and conforms to the trait it implements (§6)",
  $call errs_of ($call concat (im_shape,
      "$decl f $func ($decl s $traitsof shape) $call s.area ()  $decl n 7  $decl n_s $impl n ($traitsof shape) { $prop area $func () 1 }  $decl y $call f (n_s)")),
  "")

$decl im06 $call check_str ("every member must be implemented",
  $call errs_of ($call concat (im_shape, "$decl n_s $impl 7 ($traitsof shape) {}")), "this $impl does not implement 'area', and a trait has no defaults (§4.12)")

$decl im07 $call check_str ("and nothing but the members",
  $call errs_of ($call concat (im_shape,
      "$decl n_s $impl 7 ($traitsof shape) { $prop area $func () 1  $prop more 2 }")), "'more' is not a member of the trait this $impl implements (§4.12)")

$decl im08 $call check_str ("each at the trait's type",
  $call errs_of ($call concat (im_shape,
      "$decl n_s $impl 7 ($traitsof shape) { $prop area $func () \"s\" }")), "member 'area' of this $impl is []->Str, but the trait wants []->Int")

$decl im09 $call check_str ("a prop the base has is bound twice (§4.1)",
  $call errs_of ($call concat (im_shape,
      "$decl b { $prop area $func () 3 }  $decl x $impl b ($traitsof shape) { $prop area $func () 7 }")),
  "'area' is already bound by the $impl's base, so this binds it twice (§4.1)")

$decl im10 $call check_str ("the trait operand must be a trait",
  $call errs_of ("$decl x $impl 7 5 { $prop area $func () 7 }"),
  "an $impl implements a trait, and this is Int — write $traitsof (§4.12)")

$decl im11 $call check_str ("the override holds props only",
  $call errs_of ($call concat (im_shape,
      "$decl x $impl 7 ($traitsof shape) { $prop area $func () 7  $decl w 1 }")), "an $impl's override is a block of props only (§4.12)")

$decl im12 $call check_str ("a block base's fields are read through the receiver",
  $call errs_of ($call concat (im_shape,
      "$decl b { $decl w 3 }  $decl x $impl b ($traitsof shape) { $prop area $func () x.w }  $decl y $call x.area ()")),
  "")

$decl done7 $call nl ("all $impl tests passed")

// §6: a coercion to a trait object refers to the value, so it needs something referable,
// and allocated storage cannot hold one referring to frame storage (§5.3a).
$decl co_pre "$decl shape { $prop area $func () 0 }  $decl f $func ($decl s $traitsof shape) $call s.area ()  $decl cur $mut $alloc $traitsof shape  "

$decl co01 $call check_str ("an expression is not referable",
  $call errs_of ($call concat (co_pre, "$decl y $call f ({ $prop area $func () 2 })")), "a trait object refers to its value, so this must be a name or a reference (§6); $traitsof makes one from an expression")

$decl co02 $call check_str ("a reference is",
  $call errs_of ($call concat (co_pre, "$decl y $call f ($new { $prop area $func () 2 })")), "")

$decl co03 $call check_str ("a trait object passes on as itself",
  $call errs_of ($call concat (co_pre, "$decl g $func ($decl s $traitsof shape) $call f (s)")), "")

$decl co04 $call check_str ("$set of a top-level name into allocated trait storage",
  $call errs_of ($call concat (co_pre, "$decl r { $prop area $func () 2 }  $decl w $set cur r")), "")

$decl co05 $call check_str ("...of a local is refused",
  $call errs_of ($call concat (co_pre,
      "$decl h $func () { $decl r { $prop area $func () 2 }  $decl w $set cur r  $decl ret 0 }.ret")),
  "this trait object would refer to frame storage, which allocated storage outlives (§5.3a); store a reference to $alloc storage instead")

$decl co06 $call check_str ("...of allocated storage is not",
  $call errs_of ($call concat (co_pre,
      "$decl h $func () { $decl r $alloc { $prop area $func () 2 }  $decl w $set cur r  $decl ret 0 }.ret")),
  "")

// §5.3a's A0: storage never holds a place, and a trait object over a local is one. The
// type cannot tell this call's cell from one a caller lent, which would outlive the local.
$decl co07 $call check_str ("...and nor does frame trait storage, whoever's cell it is",
  $call errs_of ($call concat (co_pre,
      "$decl h $func () { $decl c $mut $new $traitsof shape  $decl r { $prop area $func () 2 }  $decl w $set c r  $decl ret 0 }.ret")),
  "storage cannot hold a place: this trait object would refer to frame storage (§6, §5.3a); store a reference to $alloc storage instead")

$decl co08 $call check_str ("$set of an expression into trait storage",
  $call errs_of ($call concat (co_pre, "$decl w $set cur { $prop area $func () 2 }")), "a trait object refers to its value, so this must be a name or a reference (§6); $traitsof makes one from an expression")

$decl done8 $call nl ("all trait coercion tests passed")

// §4.7: "A trait object is not inspected."
$decl tm01 $call check_str ("a catch-all on a trait object",
  $call errs_of ($call concat (co_pre, "$decl g $func ($decl s $traitsof shape) $match s ($case s $call s.area ())")),
  "")

$decl tm02 $call check_str ("a pattern that is not a supertype never matches",
  $call errs_of ($call concat (co_pre, "$decl g $func ($decl s $traitsof shape) $match s ($case 1 0, $case s 1)")),
  "a trait object is not inspected (§4.7): this pattern is not a supertype of its trait, so the arm can never match; match on a union holding it, or ask it through a member")

$decl tm03 $call check_str ("a wider trait always matches, so later arms are dead",
  $call errs_of ($call concat (co_pre,
      "$decl two { $prop area $func () 0  $prop w $func () 0 }  $decl g $func ($decl s $traitsof two) $match s ($case ($traitsof shape) 0, $case s 1)")),
  "this arm always matches a trait object (§4.7), so the arms after it cannot be reached")

// §6: a trait object's qualifier is its referent's.
$decl tq_pre "$decl c $mut $alloc { $decl n 0  $prop bump $func () $do ($set c c) 0 }  $decl k $mut $alloc { $prop area $func () 1 }  "

$decl tq01 $call check_str ("a mutable object calls a member needing a mutable receiver",
  $call errs_of ($call concat (tq_pre, "$decl t $traitsof c  $decl y $call t.bump ()")), "")

$decl tq02 $call check_str ("...and a read-only one does not",
  $call errs_of ($call concat (tq_pre, "$decl g $func ($decl s $traitsof $const c) $call s.bump ()")),
  "member 'bump' needs a mutable receiver, and this trait object is read-only (§4.10, §6)")

// The found type renders a prop's opaque identity (§4.10), which a test may not pin, so
// only the message's end is compared.
$decl tail_of $func ($decl x "", $decl k 0)
  $call slice (x, $call sub ($call len (x), k), $call len (x))

$decl tq03 $call check_str ("a value makes only a read-only object",
  $call tail_of ($call errs_of ($call concat (tq_pre,
      "$decl f $func ($decl s $traitsof k) 0  $decl r { $prop area $func () 1 }  $decl y $call f (r)")),
      35),
  ", expected mut trait{area:[]->Int,}")

$decl tq04 $call check_str ("a mutable object stands for a read-only one",
  $call errs_of ($call concat (tq_pre,
      "$decl r { $prop area $func () 1 }  $decl g $func ($decl s $traitsof r) 0  $decl y $call g ($traitsof k)")),
  "")

$decl tq05 $call check_str ("$mut storage coerces to a mutable object",
  $call errs_of ($call concat (tq_pre, "$decl f $func ($decl s $traitsof k) 0  $decl y $call f (k)")),
  "")

$decl done9 $call nl ("all trait object tests passed")

// §5.3a for parameters: which parameters escape is inferred and is in the function's
// type, and a frame-bound argument may not be passed to one that does.
$decl es_pre "$decl keep $mut $alloc $func () 0  $decl save $func ($decl f $func () 0) $do ($set keep f) 0  "

$decl es01 $call check_str ("a parameter stored in allocated storage escapes",
  $call field_ty (es_pre, "save"), "esc(0)[[]->Int]->Int")

$decl es02 $call check_str ("...so a frame-bound argument to it is refused",
  $call errs_of ($call concat (es_pre,
      "$decl h $func () { $decl c $new 1  $decl r $call save ($func () $call add (c, 0))  $decl ret 0 }.ret")),
  "argument 1 refers to frame storage, and this function lets that parameter escape (§5.3a); pass $alloc storage instead")

$decl es03 $call check_str ("a parameter only called does not escape",
  $call errs_of ($call concat (es_pre,
      "$decl run $func ($decl f $func () 0) $call add ($call f (), 1)  $decl h $func () { $decl c $new 1  $decl r $call run ($func () $call add (c, 0))  $decl ret 0 }.ret")),
  "")

$decl es04 $call check_str ("...and its type says so",
  $call field_ty ("$decl run $func ($decl f $func () 0) $call add ($call f (), 1)", "run"), "[[]->Int]->Int")

// §5.3a's borrowing: a parameter that reaches only the result goes back to its owner, so
// it is borrowed, not escaping — and the result is frame-bound when the argument was.
$decl es05 $call check_str ("returning a parameter borrows it",
  $call field_ty ("$decl id $func ($decl f $func () 0) f", "id"), "brw(0)[[]->Int]->[]->Int")

$decl es06 $call check_str ("...and so does returning a closure that captures it",
  $call field_ty ("$decl wrap $func ($decl f $func () 0) $func () $call f ()", "wrap"), "brw(0)[[]->Int]->[]->Int")

$decl es07 $call check_str ("passing it on to an escaping parameter makes it escape",
  $call field_ty ($call concat (es_pre, "$decl pass $func ($decl g $func () 0) $call save (g)"),
      "pass"), "esc(0)[[]->Int]->Int")

$decl es08 $call check_str ("a trait parameter stored in allocated storage escapes",
  $call errs_of ("$decl shape { $prop area $func () 0 }  $decl cur $mut $alloc $traitsof shape  $decl put $func ($decl s $traitsof shape) $do ($set cur s) 0  $decl h $func () { $decl r { $prop area $func () 1 }  $decl w $call put (r)  $decl ret 0 }.ret"),
  "argument 1 refers to frame storage, and this function lets that parameter escape (§5.3a); pass $alloc storage instead")

$decl es09 $call check_str ("a function letting a parameter escape is not one that does not",
  $call errs_of ($call concat (es_pre,
      "$decl use $func ($decl k $func ($decl f $func () 0) 0) 0  $decl y $call use (save)")),
  "argument 1 is esc(0)[[]->Int]->Int, expected [[]->Int]->Int")

// A call to a function still being typed — itself, or a `$fwd` before its completion — is
// checked once the function's escaping parameters are known.
$decl sr01 $call check_str ("a frame-bound argument in a self-call to an escaping parameter",
  $call errs_of ($call concat (es_pre,
      "$decl loop $func ($decl n 0, $decl f $func () 0) $if ($call lt (n, 1)) ($do ($set keep f) 0) { $decl c $new 1  $decl ret $call loop ($call sub (n, 1), $func () $call add (c, 0)) }.ret")),
  "argument 2 refers to frame storage, and this function lets that parameter escape (§5.3a); pass $alloc storage instead")

$decl sr02 $call check_str ("a parameter passed to one's own escaping parameter escapes",
  $call field_ty ($call concat (es_pre,
      "$decl loop2 $func ($decl n 0, $decl f $func () 0, $decl g $func () 0) $if ($call lt (n, 1)) ($do ($set keep f) 0) ($call loop2 ($call sub (n, 1), g, g))"),
      "loop2"), "esc(1,2)[Int,[]->Int,[]->Int]->Int")

$decl sr03 $call check_str ("a call to a $fwd before its completion is checked when it completes",
  $call errs_of ($call concat (es_pre,
      "$fwd sv  $decl user $func () { $decl c $new 1  $decl r $call sv ($func () $call add (c, 0))  $decl ret 0 }.ret  $decl sv $func ($decl f $func () 0) $do ($set keep f) 0")),
  "argument 1 refers to frame storage, and this function lets that parameter escape (§5.3a); pass $alloc storage instead")

$decl sr04 $call check_str ("a self-call to a parameter that does not escape is fine",
  $call errs_of ($call concat (es_pre,
      "$decl loop3 $func ($decl n 0, $decl f $func () 0) $if ($call lt (n, 1)) ($call f ()) { $decl c $new 1  $decl ret $call loop3 ($call sub (n, 1), $func () $call add (c, 0)) }.ret")),
  "")

// Mutual recursion through `$fwd`: a member passing its own parameter to a later one that
// lets it escape learns of it when the block is typed again.
$decl mr_grp "$fwd g  $decl f $func ($decl k $func () 0) $call g (k)  "
$decl mr_end "$decl g $func ($decl h $func () 0) $do ($set keep h) 0"

$decl mr01 $call check_str ("a $fwd member's parameter escaping through a later one",
  $call field_ty ($call concat (es_pre, $call concat (mr_grp, mr_end)), "f"), "esc(0)[[]->Int]->Int")

$decl mr02 $call check_str ("...is checked at a call typed between the two",
  $call errs_of ($call concat (es_pre, $call concat (mr_grp, $call concat (
      "$decl user $func () { $decl c $new 1  $decl r $call f ($func () $call add (c, 0))  $decl ret 0 }.ret  ",
      mr_end)))),
  "argument 1 refers to frame storage, and this function lets that parameter escape (§5.3a); pass $alloc storage instead")

$decl mr03 $call check_str ("a mutual recursion that lets nothing escape stays clean",
  $call errs_of ($call concat (es_pre,
      "$fwd ev  $decl od $func ($decl n 0, $decl f $func () 0) $if ($call lt (n, 1)) ($call f ()) ($call ev ($call sub (n, 1), f))  $decl ev $func ($decl n 0, $decl f $func () 0) $call od (n, f)  $decl h $func () { $decl c $new 1  $decl r $call od (3, $func () $call add (c, 0))  $decl ret 0 }.ret")),
  "")

// The block is typed twice to find that, and the first typing's diagnostics are dropped.
$decl err_count $func ($decl src "") {
  $decl r   $call I.check_source (src)
  $decl ret $call int_to_str ($call Pa.diags.length ($call Pa.diags.val (r.errs), 0))
}.ret

$decl mr04 $call check_str ("...and reported once",
  $call err_count ($call concat (es_pre, $call concat (mr_grp, $call concat (
      "$decl user $func () { $decl c $new 1  $decl r $call f ($func () $call add (c, 0))  $decl ret 0 }.ret  ",
      mr_end)))),
  "1")

$decl done12 $call nl ("all mutual escape tests passed")

// §4.8: `$overload` — first fit, left to right, resolving where one type is expected.
$decl ov_pre "$decl fi $func ($decl n 0) n  $decl fs $func ($decl s \"\") s  $decl o $overload (fi, fs)  "

$decl ov01 $call check_str ("an Int argument chooses the Int candidate",
  $call field_ty ($call concat (ov_pre, "$decl x $call o (3)"), "x"), "Int")
$decl ov02 $call check_str ("...and a Str argument the Str one",
  $call field_ty ($call concat (ov_pre, "$decl x $call o (\"a\")"), "x"), "Str")
$decl ov03 $call check_str ("a $decl of an overload keeps it one",
  $call field_ty (ov_pre, "o"), "O<[Int]->Int,[Str]->Str>")
$decl ov04 $call check_str ("a candidate that is an overload fits when one of its own does",
  $call field_ty ($call concat (ov_pre,
      "$decl fb $func ($decl b $union (true, false)) 0  $decl o2 $overload (fb, o)  $decl x $call o2 (\"a\")"),
      "x"), "Str")
$decl ov05 $call check_str ("an overload passed as an argument resolves against the parameter",
  $call field_ty ($call concat (ov_pre,
      "$decl apply $func ($decl k $func ($decl s \"\") \"\") $call k (\"z\")  $decl x $call apply (o)"),
      "x"), "Str")
$decl ov06 $call check_str ("no candidate accepting the arguments is an error",
  $call errs_of ($call concat (ov_pre, "$decl x $call o (true)")), "no candidate of O<[Int]->Int,[Str]->Str> accepts these arguments (§4.8)")
$decl ov07 $call check_str ("a candidate an earlier one covers is never chosen",
  $call errs_of ("$decl fi $func ($decl n 0) n  $decl gi $func ($decl n 0) 1  $decl o $overload (fi, gi)"),
  "this candidate is never chosen: an earlier one accepts every argument it does, and §4.8 is first fit")

$decl done13 $call nl ("all overload tests passed")

// §8's numeric intrinsics are overloads over `(Int,Int)` and `(Float,Float)`, with no
// implicit conversion; `eq`, `to_int` and `to_str` are overloaded too.
$decl fl01 $call check_str ("Float arithmetic is the Float candidate",
  $call field_ty ("$decl x $call add (1.5, 2.25)", "x"), "Float")
$decl fl02 $call check_str ("...and Int arithmetic still the Int one",
  $call field_ty ("$decl x $call mod (7, 2)", "x"), "Int")
$decl fl03 $call check_str ("mixing Int and Float is an error",
  $call errs_of ("$decl x $call add (1, 2.0)"),
  "no candidate of O<[Int,Int]->Int,[Float,Float]->Float> accepts these arguments (§4.8)")
$decl fl04 $call check_str ("to_int on a Float is an option",
  $call field_ty ("$decl x $call to_int (2.5)", "x"), "<{tag=s\"none\",},{v:Int,tag=s\"some\",}>")
$decl fl05 $call check_str ("to_str and to_float",
  $call field_ty ("$decl x $call to_str ($call to_float (3))", "x"), "Str")
$decl fl06 $call check_str ("eq on strings",
  $call field_ty ("$decl x $call eq (\"a\", \"b\")", "x"), "<false,true>")
$decl fl07 $call check_str ("an aliased intrinsic keeps both candidates",
  $call field_ty ("$decl isub sub  $decl x $call isub (5, 3)", "x"), "Int")

$decl done14 $call nl ("all float tests passed")

// §8's FFI intrinsics: an address is an `Int`, `box_ptr` takes storage, and `unbox`
// is typed by its example. Both are bound at markers, so a user's own `unbox`
// shadows the intrinsic like any other.
$decl ff01 $call check_str ("box_ptr of storage is an Int",
  $call field_ty ("$decl c $mut $alloc 1  $decl x $call box_ptr (c)", "x"), "Int")
$decl ff02 $call check_str ("box_ptr of a value is an error",
  $call errs_of ("$decl x $call box_ptr (3)"), "box_ptr takes storage, found Int")
$decl ff03 $call check_str ("unbox is allocated, writable storage of the example's type",
  $call field_ty ("$decl x $call unbox (0, \"\")", "x"), "&^mut Str")
$decl ff04 $call check_str ("unbox's address must be an Int",
  $call errs_of ("$decl x $call unbox (\"a\", 0)"), "unbox's address is Str, expected Int")
$decl ff05 $call check_str ("a user's unbox shadows the intrinsic",
  $call field_ty ("$decl unbox $func ($decl a 0) a  $decl x $call unbox (4)", "x"), "Int")
$decl ff06 $call check_str ("run answers an option of the exit status",
  $call field_ty ("$decl x $call run ($call args ())", "x"),
  "<{tag=s\"none\",},{v:Int,tag=s\"some\",}>")

$decl ff07 $call check_str ("str_from_ptr answers an option of a Str",
  $call field_ty ("$decl x $call str_from_ptr (0, 0)", "x"),
  "<{tag=s\"none\",},{v:Str,tag=s\"some\",}>")

// §8's arrays at any element type (STDLIB.md, P3), typed per call like `unbox`.
$decl ff08 $call check_str ("an array takes its element type from the example",
  $call field_ty ("$decl x $call array (3, 0)", "x"), "[]Int")
$decl ff09 $call check_str ("at is the element's storage",
  $call field_ty ("$decl a $call array (2, { $decl k 1 })  $decl x $call at (a, 0)", "x"),
  "&mut {k:Int,}")
$decl ff10 $call check_str ("at takes an array",
  $call errs_of ("$decl x $call at (5, 0)"), "at takes an array, found Int")
$decl ff11 $call check_str ("an array's length is an Int",
  $call errs_of ("$decl x $call array (\"3\", 0)"), "array's length is Str, expected Int")
// An argument is a value position (§5.4), so `array (2, c)` holds `c`'s Int; a place can
// only reach an array inside a value.
$decl ff12 $call check_str ("an array holds no place (A0)",
  $call errs_of ("$decl f $func () { $decl c $mut $new 0  $decl a $call array (2, { $decl r c })  $decl ret 0 }.ret"),
  "storage cannot hold a place: this value holds frame storage (&mut Int), and only a pointer value may be stored (§5.3a); store $alloc storage instead")
$decl ff13 $call check_str ("a user's at shadows the intrinsic",
  $call field_ty ("$decl at $func ($decl a 0, $decl b 0) \"s\"  $decl x $call at (1, 2)", "x"), "Str")

$decl done15 $call nl ("all FFI tests passed")

// §5.3a's provenance (STORAGE.md): a frame reference is a place. A result may hold one
// only if it came in (§R, borrowing); storage may hold none (A0); a tail call may not pass
// one this call made (A4).
$decl st_pre "$decl ival $func ($decl x 0) x  $decl id_ref $func ($decl p $mut $new 0) p  "

$decl st01 $call check_str ("a result may hand back a place it was given",
  $call errs_of ($call concat (st_pre, "$decl pass $func ($decl q $mut $new 0) $call id_ref (q)")), "")
$decl st02 $call check_str ("...and a place reached through a parameter",
  $call errs_of ("$decl pick $func ($decl b { $decl r $mut $new 0 }) b.r"), "")
$decl st03 $call check_str ("...and a place its enclosing function made, from a closure",
  $call errs_of ("$decl use $func () { $decl ctr { $decl n $mut $new 0 }  $decl get $func () ctr.n  $decl ret 0 }.ret"), "")
$decl st04 $call check_str ("a result may not hold a place this call made",
  $call errs_of ("$decl own $func () $new 3"),
  "this function's result holds frame storage made in this call (&Int), which ends when it returns; return a place the caller passed in, or $alloc storage (§5.3a)")
$decl st05 $call check_str ("...nor one it lent to a call that hands it back",
  $call errs_of ($call concat (st_pre, "$decl bad $func () { $decl c $mut $new 0  $decl ret $call id_ref (c) }.ret")),
  "this function's result holds frame storage made in this call (&mut Int), which ends when it returns; return a place the caller passed in, or $alloc storage (§5.3a)")
$decl st06 $call check_str ("storage may not hold a value carrying a place",
  $call errs_of ("$decl f $func () { $decl loc $mut $new 7  $decl b $mut $new { $decl r loc }  $decl ret 0 }.ret"),
  "storage cannot hold a place: this value holds frame storage (&mut Int), and only a pointer value may be stored (§5.3a); store $alloc storage instead")
$decl st07 $call check_str ("...but a place used as a value is read through, and may be",
  $call errs_of ("$decl f $func ($decl p $mut $new 0) { $decl loc $mut $new 7  $decl w $set p loc  $decl ret 0 }.ret"), "")
$decl st08 $call check_str ("a tail call may not pass a place this call made",
  $call errs_of ($call concat (st_pre, "$decl fresh $func ($decl c $new 0, $decl n 0) $if ($call eq_int (n, 0)) ($call ival (c)) ($call fresh ($new n, $call sub (n, 1)))")),
  "this tail call passes $new storage made in this call, and a tail call ends the call (§7.7): allocate it with $alloc and release it when done, or make the call non-tail")
$decl st09 $call check_str ("...but may pass one it borrowed",
  $call errs_of ($call concat (st_pre, "$decl count $func ($decl c $mut $new 0, $decl n 0) $if ($call eq_int (n, 0)) ($call ival (c)) ($call count (c, $call sub (n, 1)))")), "")
$decl st10 $call check_str ("...or a value read out of its own",
  $call errs_of ($call concat (st_pre, "$decl scratch $func ($decl n 0, $decl acc 0) $if ($call eq_int (n, 0)) acc ($call scratch ($call sub (n, 1), $call ival ($new n)))")), "")
$decl st11 $call check_str ("...or its own place to an intrinsic, which ends nothing",
  $call errs_of ("$decl f $func ($decl n 0) $call box_ptr ($new n)"), "")

$decl done16 $call nl ("all storage tests passed")

// §7.6's allocators: `$alloc` draws from the `allocator` in lexical scope, which must have
// an `alloc` taking a size and answering an address; the root's members are §8's raw memory.
$decl al01 $call check_str ("the root allocator's members are raw memory",
  $call field_ty ("$decl x allocator.alloc", "x"), "[Int]->Int")
$decl al02 $call check_str ("...and free takes an address",
  $call errs_of ("$decl c $alloc 1  $decl x $call allocator.free ($call box_ptr (c))"), "")
$decl al03 $call check_str ("an allocator of one's own serves $alloc",
  $call errs_of ("$decl a { $prop alloc $func ($decl n 0) $call raw_alloc (n) }  $decl allocator a  $decl f $func () $alloc 5"), "")
$decl al04 $call check_str ("...if its alloc answers an address",
  $call errs_of ("$decl a { $prop alloc $func ($decl n 0) \"x\" }  $decl allocator a  $decl f $func () $alloc 5"),
  "the allocator in scope cannot serve $alloc: its alloc is [Int]->Str, which must take a size and answer an address (§7.6)")
$decl al05 $call check_str ("...and only below it, in source order",
  $call errs_of ("$decl a { $prop alloc $func ($decl n 0) \"x\" }  $decl f $func () $alloc 5  $decl allocator a"), "")

$decl done17 $call nl ("all allocator tests passed")

// §6's coercion makes a trait object referring to the argument's own storage: a name's
// slot, or fresh frame storage. A tail call ends both (§7.7), and a cell outlives them.
$decl tr_pre "$decl shape { $prop area $func () 0 }  $decl seven { $decl v 7  $prop area $func () seven.v }  $decl k $mut $alloc $func ($decl t $traitsof shape, $decl n 0) 0  "

$decl tc01 $call check_str ("a tail call may not coerce this call's own parameter",
  $call errs_of ($call concat (tr_pre, "$decl hop $func ($decl r seven, $decl n 0) $call k (r, n)")),
  "this tail call makes a trait object referring to storage of this call (§6), and a tail call ends the call (§7.7): pass a reference the caller lent, or $alloc storage, or make the call non-tail")
$decl tc02 $call check_str ("...but may coerce a global",
  $call errs_of ($call concat (tr_pre, "$decl g $func ($decl n 0) $call k (seven, n)")), "")
$decl tc03 $call check_str ("...or a reference the caller lent",
  $call errs_of ($call concat (tr_pre, "$decl g $func ($decl r $new seven, $decl n 0) $call k (r, n)")), "")
$decl tc04 $call check_str ("a cell the caller lent may not hold an object over this call's parameter",
  $call errs_of ("$decl shape { $prop area $func () 0 }  $decl seven { $decl v 7  $prop area $func () seven.v }  $decl stash $func ($decl c $mut $new $traitsof shape, $decl r seven) { $decl w $set c r  $decl ret 0 }.ret"),
  "storage cannot hold a place: this trait object would refer to frame storage (§6, §5.3a); store a reference to $alloc storage instead")

$decl done18 $call nl ("all trait storage tests passed")

// §5.3a's borrowing for trait- and function-typed parameters: handed back, not escaped.
$decl bw_pre "$decl shape { $prop area $func () 0 }  $decl tri { $decl b 6  $prop area $func () tri.b }  $decl bigger $func ($decl a $traitsof shape, $decl b $traitsof shape) $if ($call lt ($call a.area (), $call b.area ())) b a  "

$decl bw01 $call check_str ("a function handing back a trait parameter borrows it",
  $call errs_of ($call concat (bw_pre, "$decl use $func () { $decl loc { $prop area $func () 5 }  $decl w $call bigger ($traitsof loc, $traitsof tri)  $decl ret $call w.area () }.ret")), "")
$decl bw02 $call check_str ("...and what it hands back is the caller's own place",
  $call errs_of ($call concat (bw_pre, "$decl bad $func () { $decl loc { $prop area $func () 5 }  $decl ret $call bigger ($traitsof loc, $traitsof tri) }.ret")),
  "this function's result holds frame storage made in this call (a trait object referring to frame storage), which ends when it returns; return a place the caller passed in, or $alloc storage (§5.3a)")
$decl bw03 $call check_str ("...so it may not be stored",
  $call errs_of ($call concat (bw_pre, "$decl cell $mut $alloc $traitsof shape  $decl bad $func () { $decl loc { $prop area $func () 5 }  $decl w $set cell ($call bigger ($traitsof loc, $traitsof tri))  $decl ret 0 }.ret")),
  "this value holds frame storage (a trait object referring to frame storage), which cannot outlive the scope its $new made it in. Write $alloc there instead (§4.2a, §5.3a)")
$decl bw04 $call check_str ("a wrapper passing them on borrows them in turn",
  $call field_ty ($call concat (bw_pre, "$decl pick $func ($decl a $traitsof shape, $decl b $traitsof shape) $call bigger (a, b)"), "pick"),
  "brw(0,1)[trait{area:[]->Int,},trait{area:[]->Int,}]->trait{area:[]->Int,}")

$decl bw05 $call check_str ("a join keeps the frame-bound side, whichever arm it is in",
  $call errs_of ($call concat (bw_pre, "$decl bad $func ($decl c $union (false, true)) { $decl loc { $prop area $func () 5 }  $decl ret $if c ($traitsof loc) ($traitsof tri) }.ret")),
  "this function's result holds frame storage made in this call (a trait object referring to frame storage), which ends when it returns; return a place the caller passed in, or $alloc storage (§5.3a)")

$decl done19 $call nl ("all borrowing tests passed")
