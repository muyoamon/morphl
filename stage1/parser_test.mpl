// Tests for stage 1's parser, written in morphl and run by stage 0:
//
//   morphlc --run stage1/parser_test.mpl
//
// Run from the repository root — the self-parse check at the end reads the
// stage-1 sources by path.
//
// Assertions compare the S-expression dump, which is the same format stage 0's
// parser prints. That makes every expectation here checkable against the other
// implementation with `stage1/parse_dump.mpl`.

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

// The dump of the first top-level expression.
$decl dump1 $func ($decl src "")
  { $decl p $call Pa.parse (src)
    $decl out $call Pa.dump ($call Pa.nodes.nth (p.exprs, 0)) }.out

// The whole file, newline separated, as `parse_dump.mpl` prints it.
$decl dump_all $func ($decl src "")
  { $decl p $call Pa.parse (src)
    $decl out $call Pa.dump_file (p.exprs, "") }.out

$decl first_err $func ($decl src "")
  { $decl p $call Pa.parse (src)
    // Narrowing is by the scrutinee's name (§4.7), and `$if` does not narrow
    // at all — so the list is bound and matched.
    $decl es $call Pa.diags.val (p.errs)
    $decl out $match es (
        $case {$prop tag "cons"} es.head.msg,
        $case es ""
      ) }.out

$decl err_count $func ($decl src "")
  { $decl p $call Pa.parse (src)
    $decl out $call Pa.diags.length (p.errs, 0) }.out

// ------------------------------------------------------- arity drives the parse

$decl t01 $call check_str ("a two-operand form", $call dump1 ("$decl x 1"), "($decl x 1)")
$decl t02 $call check_str ("no separators needed", $call dump_all ("$decl x 1 $decl y 2"),
  "($decl x 1)\n($decl y 2)\n")
$decl t03 $call check_str ("a three-operand form", $call dump1 ("$if true 1 2"), "($if true 1 2)")
$decl t04 $call check_str ("a one-operand form", $call dump1 ("$new 0"), "($new 0)")

// §2.3: groups
$decl t05 $call check_str ("the empty group is unit", $call dump1 ("()"), "()")
$decl t06 $call check_str ("the empty block is the same value", $call dump1 ("{}"), "()")
$decl t07 $call check_str ("a one-element group is the element", $call dump1 ("(a)"), "a")
$decl t08 $call check_str ("a two-element group", $call dump1 ("(a, b)"), "(group a b)")
$decl t09 $call check_str ("a three-element group", $call dump1 ("(a, b, c)"), "(group a b c)")

// Only groups fold; a one-expression block is still a block.
$decl t10 $call check_str ("a one-expression block", $call dump1 ("{a}"), "(block a)")
$decl t11 $call check_str ("a two-expression block", $call dump1 ("{a b}"), "(block a b)")

// §2.1: `;` is permitted anywhere and means nothing.
$decl t12 $call check_str ("';' is not a separator", $call dump_all ("$decl x 1; $decl y 2"),
  "($decl x 1)\n($decl y 2)\n")
$decl t13 $call check_str ("';' inside a block", $call dump1 ("{a; b;}"), "(block a b)")

// Projection is postfix and binds tightest.
$decl t14 $call check_str ("a named projection", $call dump1 ("x.a"), "(. x a)")
$decl t15 $call check_str ("chained projections", $call dump1 ("x.a.b"), "(. (. x a) b)")
$decl t16 $call check_str ("an indexed projection", $call dump1 ("p.1"), "(. p 1)")
$decl t17 $call check_str ("projection off a block",
  $call dump1 ("{ $decl r 1 }.r"), "(. (block ($decl r 1)) r)")
$decl t18 $call check_str ("projection inside a call",
  $call dump1 ("$call f x.a"), "($call f (. x a))")

// §2.4 with §2.3: the syntactic group fixes the argument count.
$decl t19 $call check_str ("a folded single argument", $call dump1 ("$call f (x)"), "($call f x)")
$decl t20 $call check_str ("an unparenthesised argument", $call dump1 ("$call f x"), "($call f x)")
$decl t21 $call check_str ("two arguments", $call dump1 ("$call f (x, y)"), "($call f (group x y))")
$decl t22 $call check_str ("no arguments", $call dump1 ("$call f ()"), "($call f ())")

// Literals
$decl t23 $call check_str ("a negative integer", $call dump1 ("-7"), "-7")
$decl t24 $call check_str ("a float keeps its text", $call dump1 ("3.14"), "3.14")
$decl t25 $call check_str ("a string", $call dump1 ("\"hi\""), "\"hi\"")
$decl t26 $call check_str ("true and false", $call dump_all ("true false"), "true\nfalse\n")

// §4.9: a template's generic parameter is a name or a group of names.
$decl t27 $call check_str ("one generic parameter",
  $call dump1 ("$template T $func ($decl x T) x"), "($template T ($func ($decl x T) x))")
$decl t28 $call check_str ("a folded generic group", $call dump1 ("$template (T) x"), "($template T x)")
$decl t29 $call check_str ("a real generic group",
  $call dump1 ("$template (A, B) x"), "($template (group A B) x)")
$decl t30 $call check_str ("generic parameters must be names",
  $call first_err ("$template (A, 1) x"), "$template generic parameters must be plain names")

// Worked examples from SPEC.md §12.
$decl t31 $call check_str ("the counter example",
  $call dump_all ("$decl n $mut $new 0\n$set n ($call add (n, 1))"),
  "($decl n ($mut ($new 0)))\n($set n ($call add (group n 1)))\n")
$decl t32 $call check_str ("the while loop",
  $call dump1 ("$decl while $func ($decl cond $func () true, $decl body $func () {}) $if ($call cond ()) ($do ($call body ()) ($call while (cond, body))) {}"),
  "($decl while ($func (group ($decl cond ($func () true)) ($decl body ($func () ()))) ($if ($call cond ()) ($do ($call body ()) ($call while (group cond body))) ())))")
$decl t33 $call check_str ("a single-arm match keeps the $case directly",
  $call dump1 ("$match x ($case x 1)"), "($match x ($case x 1))")

// ------------------------------------------------------- operand kinds (§2.2)

$decl t34 $call check_str ("$decl needs a name",
  $call first_err ("$decl 1 2"), "$decl operand 1 must be a name, found integer literal")
$decl t35 $call check_str ("$decl rejects a keyword as its name",
  $call first_err ("$decl $new 0"), "$decl operand 1 must be a name, found keyword")
$decl t36 $call check_str ("$import needs a string literal",
  $call first_err ("$import foo"), "$import operand 1 must be a string literal, found identifier")
$decl t37 $call check_str ("$extern needs a string literal",
  $call first_err ("$extern add"), "$extern operand 1 must be a string literal, found identifier")
$decl t38 $call check_str ("an unknown keyword is the parser's problem",
  $call first_err ("$nope x"), "unknown keyword '$nope'")

// -------------------------------------------------- $case placement (§2.2)

$decl t39 $call check_str ("$case alone is rejected",
  $call first_err ("$case 1 2"), "$case is only valid as an arm of $match")
$decl t40 $call check_str ("$case buried in a function is rejected",
  $call first_err ("$decl f $func () ($case 1 2)"), "$case is only valid as an arm of $match")
$decl t41 $call check_str ("a non-$case arm is rejected",
  $call first_err ("$match x (1, $case 2 3)"), "$match arms must be $case forms")
$decl t42 $call check ("a nested match inside an arm is fine",
  $call eq_int ($call err_count ("$match x ($case x $match y ($case y 1))"), 0))

// -------------------------------------------------------------- delimiters

$decl t43 $call check_str ("an unclosed group names its opener",
  $call first_err ("(a, b"), "unclosed '(' — group is missing its ')'")
$decl t44 $call check_str ("an unclosed block names its opener",
  $call first_err ("{a b"), "unclosed '{' — block is missing its '}'")
$decl t45 $call check_str ("a missing comma",
  $call first_err ("(a b)"), "expected ',' or ')' in group, found identifier")
$decl t46 $call check_str ("a trailing comma", $call first_err ("(a, b,)"), "trailing ',' in group")
$decl t47 $call check_str ("a stray projection",
  $call first_err (".a"), "projection has nothing to its left")

// Parsing continues past an error, so one run surfaces several.
$decl t48 $call check ("more than one error per run",
  $call lt (1, $call err_count ("$decl 1 2 $decl 3 4")))

// A lexical error arrives as the lexer's own message rather than a worse one.
$decl t49 $call check_str ("the lexer's message survives",
  $call first_err ("x.0"), "group indices start at .1, not .0")

// ------------------------------------------------ the one that actually matters

$decl load $func ($decl p "")
  { $decl c $call read_file (p)
    $decl out $match c (
        $case {$prop tag "some"} c.v,
        $case c ($call panic ($call concat ("cannot read ", p)))
      ) }.out

$decl parse_clean $func ($decl p "")
  { $decl src $call load (p)
    $decl n   $call err_count (src) }.n

$decl t50 $call check ("it parses the prelude with no errors",
  $call eq_int ($call parse_clean ("stage1/prelude.mpl"), 0))
$decl t51 $call check ("it parses the lexer with no errors",
  $call eq_int ($call parse_clean ("stage1/lexer.mpl"), 0))
$decl t52 $call check ("it parses its own source with no errors",
  $call eq_int ($call parse_clean ("stage1/parser.mpl"), 0))

$decl self_p $call Pa.parse ($call load ("stage1/parser.mpl"))
$decl n_top  $call Pa.nodes.length (self_p.exprs, 0)
$decl r1 $call nl ($call concat ("      top-level expressions in parser.mpl: ", $call int_to_str (n_top)))

$decl done $call nl ("all parser tests passed")
