// Stage 1's parser, written in morphl — BOOTSTRAP.md stage 1, step 2.
//
// Table-driven off the fixed-arity table of SPEC.md §2.2, which now lives here
// rather than in the lexer: the lexer emits `keyword` tokens carrying their
// text, and this file decides what a keyword means. One table, one owner.
//
// **AST nodes are prop-tagged blocks.** §4.10 makes a prop's value part of its
// block's type identity, so `{$prop tag "form" …}` and `{$prop tag "name" …}`
// are different types and `$match` dispatches on them structurally. Unlike the
// token record, where every case has the same fields, node payloads genuinely
// differ — a `form` has a keyword and operands, a `proj_index` has a target and
// an index — and exhaustiveness over them is worth real money in a compiler.
// The node type is the union of those shapes, tied by §5.5's knot.

$decl L $import "lexer"
$decl P $import "prelude"

$decl not  P.not
$decl and  P.and
$decl or   P.or
$decl ival P.ival

// ---------------------------------------------------------------- diagnostics
//
// §6 of BOOTSTRAP.md: every type in a morphl diagnostic is one the compiler
// inferred, so a diagnostic must point at an expression. Spans live on nodes
// and tokens from the start for that reason.

$decl diag $func ($decl m "", $decl l 0, $decl c 0)
  { $decl msg m  $decl line l  $decl col c }

$decl proto_diag $call diag ("", 0, 0)
$decl diags $specialize P.list proto_diag

// ------------------------------------------------------------------ AST nodes
//
// Leaf shapes first: the union below needs one of them evaluated.
//
// Every node starts with `line` and `col`. §5.1 matches blocks by ordered
// prefix, so that shared prefix is what makes `{line:Int, col:Int}` a supertype
// of every node type *and* of the token type — one span accessor, no per-kind
// dispatch, and the upcast is free (§7.4).

$decl n_int   $func ($decl v 0,     $decl l 0, $decl c 0) { $prop tag "int"   $decl line l  $decl col c  $decl value v }
$decl n_float $func ($decl t "",    $decl l 0, $decl c 0) { $prop tag "float" $decl line l  $decl col c  $decl text t }
$decl n_str   $func ($decl t "",    $decl l 0, $decl c 0) { $prop tag "str"   $decl line l  $decl col c  $decl text t }
$decl n_bool  $func ($decl v P.boolean, $decl l 0, $decl c 0) { $prop tag "bool"  $decl line l  $decl col c  $decl value v }
$decl n_name  $func ($decl t "",    $decl l 0, $decl c 0) { $prop tag "name"  $decl line l  $decl col c  $decl text t }
$decl n_unit  $func ($decl l 0,     $decl c 0)            { $prop tag "unit"  $decl line l  $decl col c }
$decl n_err   $func ($decl m "",    $decl l 0, $decl c 0) { $prop tag "error" $decl line l  $decl col c  $decl msg m }

// The node type.
//
// Only the first member is evaluated (§4.8a); the rest are **type-only
// positions** (§5.7), which is what lets them name `n_group`, `n_form` and
// `nodes` — all declared *below* this point. That is §5.5's knot doing exactly
// the job it exists for: a recursive type, named before its parts exist, with
// no forward declaration and no hoisting.
// The aggregate shapes are written out rather than named through their
// constructors. §5.7 lets a type-only position reference a declaration that is
// *in progress* — which `proto_node` is, inside its own `$union` — but not one
// that has not started, and the constructors below have not. Naming them here
// would be the forward reference §4.11 forbids; it only appeared to work
// because a type-only position is never evaluated.
$decl proto_node $union (
  $call n_int   (0, 0, 0),
  $call n_float ("", 0, 0),
  $call n_str   ("", 0, 0),
  $call n_bool  (true, 0, 0),
  $call n_name  ("", 0, 0),
  $call n_unit  (0, 0),
  $call n_err   ("", 0, 0),
  { $prop tag "group"      $decl line 0  $decl col 0  $decl items ($specialize P.list proto_node).node },
  { $prop tag "block"      $decl line 0  $decl col 0  $decl items ($specialize P.list proto_node).node },
  { $prop tag "proj_name"  $decl line 0  $decl col 0  $decl target proto_node  $decl field "" },
  { $prop tag "proj_index" $decl line 0  $decl col 0  $decl target proto_node  $decl index 0 },
  { $prop tag "form"       $decl line 0  $decl col 0  $decl keyword ""  $decl operands ($specialize P.list proto_node).node }
)

$decl nodes $specialize P.list proto_node

// Aggregate shapes, now that there is a list of nodes to hold.
$decl n_group $func ($decl xs nodes.node, $decl l 0, $decl c 0)
  { $prop tag "group" $decl line l  $decl col c  $decl items xs }

$decl n_block $func ($decl xs nodes.node, $decl l 0, $decl c 0)
  { $prop tag "block" $decl line l  $decl col c  $decl items xs }

$decl n_projn $func ($decl tgt proto_node, $decl f "", $decl l 0, $decl c 0)
  { $prop tag "proj_name" $decl line l  $decl col c  $decl target tgt  $decl field f }

$decl n_proji $func ($decl tgt proto_node, $decl i 0, $decl l 0, $decl c 0)
  { $prop tag "proj_index" $decl line l  $decl col c  $decl target tgt  $decl index i }

$decl n_form $func ($decl kw "", $decl ops nodes.node, $decl l 0, $decl c 0)
  { $prop tag "form" $decl line l  $decl col c  $decl keyword kw  $decl operands ops }

// ------------------------------------------------------- the §2.2 arity table
//
// Operand kinds beyond "expr" exist because §2.2 names some operands "name" or
// "string literal": enforcing that here turns what would otherwise be a
// confusing downstream type error into a precise syntax error.

$decl kw_entry $func ($decl n "", $decl a 0, $decl k1 "", $decl k2 "", $decl k3 "")
  { $decl name n  $decl arity a  $decl o1 k1  $decl o2 k2  $decl o3 k3 }

$decl proto_kw $call kw_entry ("", 0, "", "", "")
$decl kws $specialize P.list proto_kw
$decl no_kw $call kw_entry ("", -1, "", "", "")

// `kws.node` rather than `kws.nil`: `$new` takes the type of its operand
// (§4.2), so initialising from `nil` would give storage that only a `nil`
// fits into. §4.8a is exactly the way to name the union without branching.
$decl kw_table $mut $new kws.node

$decl add_kw $func ($decl n "", $decl a 0, $decl k1 "", $decl k2 "", $decl k3 "")
  $set kw_table ($call kws.cons ($call kw_entry (n, a, k1, k2, k3), kw_table))

// Bare expressions in a block run for effect and are discarded (§3.3), so the
// table reads as a table instead of a chain of nested `cons`.
$call add_kw ("decl",       2, "name",  "expr", "")
$call add_kw ("prop",       2, "name",  "expr", "")
$call add_kw ("fwd",        1, "name",  "",     "")
$call add_kw ("new",        1, "expr",  "",     "")
$call add_kw ("mut",        1, "expr",  "",     "")
$call add_kw ("const",      1, "expr",  "",     "")
$call add_kw ("set",        2, "expr",  "expr", "")
$call add_kw ("func",       2, "expr",  "expr", "")
$call add_kw ("call",       2, "expr",  "expr", "")
$call add_kw ("match",      2, "expr",  "expr", "")
$call add_kw ("case",       2, "expr",  "expr", "")
$call add_kw ("if",         3, "expr",  "expr", "expr")
$call add_kw ("do",         2, "expr",  "expr", "")
$call add_kw ("overload",   1, "expr",  "",     "")
$call add_kw ("union",      1, "expr",  "",     "")
$call add_kw ("template",   2, "names", "expr", "")
$call add_kw ("specialize", 2, "expr",  "expr", "")
$call add_kw ("impl",       3, "expr",  "expr", "expr")
$call add_kw ("traitsof",   1, "expr",  "",     "")
$call add_kw ("import",     1, "str",   "",     "")
$call add_kw ("try",        2, "expr",  "expr", "")
$call add_kw ("extern",     2, "str",   "expr", "")

$decl find_kw $func ($decl xs kws.node, $decl n "") $match xs (
  $case {$prop tag "cons"}
    $if ($call eq_str (xs.head.name, n)) xs.head ($call find_kw (xs.tail, n)),
  $case xs no_kw
)

$decl lookup_kw $func ($decl n "") $call find_kw (kw_table, n)

// -------------------------------------------------------------- parser state

$decl parser $func ($decl ts L.toks.node)
  { $decl rest $mut $new ts
    $decl errs $mut $new diags.node }

$decl proto_parser $call parser (L.toks.nil)
$decl eof_token $call L.token ("eof", "", 0, 0, 0)

// The list is read out of storage first so that it can be `$match`ed: only
// `$match` narrows (§4.7), and a bare `$if` would leave the union un-narrowed
// with nothing to project. Binding it also gives the catch-all a name.
$decl peek $func ($decl ps proto_parser)
  { $decl rest $call L.toks.val (ps.rest)
    $decl out $match rest (
        $case {$prop tag "cons"} rest.head,
        $case rest eof_token
      ) }.out

$decl at_kind $func ($decl ps proto_parser, $decl k "")
  $call eq_str (($call peek (ps)).kind, k)

// Never advances past `eof`, so `peek` is always answerable.
$decl bump $func ($decl ps proto_parser)
  { $decl t    $call peek (ps)
    $decl rest $call L.toks.val (ps.rest)
    $decl moved $match rest (
        $case {$prop tag "cons"} $if ($call eq_str (t.kind, "eof")) () ($set ps.rest rest.tail),
        $case rest ()
      )
    $decl out t }.out

$decl note_at $func ($decl ps proto_parser, $decl m "", $decl l 0, $decl c 0)
  $set ps.errs ($call diags.cons ($call diag (m, l, c), ps.errs))

// Accepts any node *or* token, because both begin with `line`/`col` and §5.1
// makes `{line:Int, col:Int}` a prefix supertype of each.
$decl note_at_span $func ($decl ps proto_parser, $decl m "", $decl x P.proto_span)
  $call note_at (ps, m, x.line, x.col)

$decl note $func ($decl ps proto_parser, $decl m "")
  { $decl t $call peek (ps)
    $decl out $call note_at (ps, m, t.line, t.col) }.out

$decl fail_at $func ($decl ps proto_parser, $decl m "", $decl l 0, $decl c 0)
  { $decl noted $call note_at (ps, m, l, c)
    $decl out $call n_err (m, l, c) }.out

$decl describe $func ($decl k "")
  $if ($call eq_str (k, "int"))     "integer literal"
  ($if ($call eq_str (k, "float"))   "float literal"
  ($if ($call eq_str (k, "str"))     "string literal"
  ($if ($call eq_str (k, "name"))    "identifier"
  ($if ($call eq_str (k, "keyword")) "keyword"
  ($if ($call eq_str (k, "lparen"))  "("
  ($if ($call eq_str (k, "rparen"))  ")"
  ($if ($call eq_str (k, "lbrace"))  "{"
  ($if ($call eq_str (k, "rbrace"))  "}"
  ($if ($call eq_str (k, "comma"))   ","
  ($if ($call eq_str (k, "eof"))     "end of file" k))))))))))

// ------------------------------------------------------------------- parsing
//
// `parse_expr` and everything it reaches are mutually recursive, so the knot is
// tied with `$fwd` (§4.11): there is no hoisting, and a `$func` body may name a
// `$fwd` slot before its completing `$decl`.

$fwd parse_expr

// `( e, e, … )` — §2.3. Comma separated, unlike a block.
$decl group_items $func ($decl ps proto_parser, $decl acc nodes.node, $decl open L.proto_token)
  { $decl e    $call parse_expr (ps)
    $decl acc2 $call nodes.cons (e, acc)
    $decl out $if ($call at_kind (ps, "comma"))
        ($do ($call bump (ps))
             ($if ($call at_kind (ps, "rparen"))
                  ($do ($call note (ps, "trailing ',' in group"))
                       ($do ($call bump (ps)) acc2))
                  ($call group_items (ps, acc2, open))))
        ($if ($call at_kind (ps, "rparen"))
             ($do ($call bump (ps)) acc2)
        ($if ($call at_kind (ps, "eof"))
             ($do ($call note_at (ps, "unclosed '(' — group is missing its ')'", open.line, open.col)) acc2)
             // Consuming here is what guarantees progress, so one bad token
             // cannot hang the parse.
             ($do ($call note (ps, $call concat ("expected ',' or ')' in group, found ",
                                                 $call describe (($call peek (ps)).kind))))
                  ($do ($call bump (ps)) ($call group_items (ps, acc2, open)))))) }.out

$decl parse_group $func ($decl ps proto_parser)
  { $decl open $call bump (ps)
    $decl out $if ($call at_kind (ps, "rparen"))
        // §2.3: the empty group and the empty block are the same value.
        ($do ($call bump (ps)) ($call n_unit (open.line, open.col)))
        { $decl rev   $call group_items (ps, nodes.nil, open)
          $decl items $call nodes.reverse (rev, nodes.nil)
          $decl n     $call nodes.length (items, 0)
          // §2.3: "A one-element group is the element." There is no one-tuple,
          // so a folded group never reaches the tree.
          $decl o $if ($call eq_int (n, 1)) ($call nodes.nth (items, 0))
                 ($if ($call eq_int (n, 0)) ($call n_unit (open.line, open.col))
                      ($call n_group (items, open.line, open.col))) }.o }.out

// `{ e e … }` — §2.3, no separator required. The recursive call is in tail
// position, which matters: a block can hold a whole file.
$decl block_items $func ($decl ps proto_parser, $decl acc nodes.node, $decl open L.proto_token)
  $if ($call at_kind (ps, "rbrace")) ($do ($call bump (ps)) acc)
  ($if ($call at_kind (ps, "eof"))
       ($do ($call note_at (ps, "unclosed '{' — block is missing its '}'", open.line, open.col)) acc)
       ($call block_items (ps, $call nodes.cons ($call parse_expr (ps), acc), open)))

$decl parse_block $func ($decl ps proto_parser)
  { $decl open $call bump (ps)
    $decl out $if ($call at_kind (ps, "rbrace"))
        ($do ($call bump (ps)) ($call n_unit (open.line, open.col)))
        { $decl rev $call block_items (ps, nodes.nil, open)
          $decl o   $call n_block ($call nodes.reverse (rev, nodes.nil), open.line, open.col) }.o }.out

$decl parse_name_operand $func ($decl ps proto_parser, $decl kwt L.proto_token, $decl idx 0)
  $if ($call at_kind (ps, "name"))
      { $decl t $call bump (ps)
        $decl o $call n_name (t.text, t.line, t.col) }.o
      { $decl t $call peek (ps)
        $decl o $call fail_at (ps,
            $call concat ("$", $call concat (kwt.text,
            $call concat (" operand ", $call concat ($call int_to_str (idx),
            $call concat (" must be a name, found ", $call describe (t.kind)))))),
            t.line, t.col) }.o

$decl parse_str_operand $func ($decl ps proto_parser, $decl kwt L.proto_token, $decl idx 0)
  $if ($call at_kind (ps, "str"))
      { $decl t $call bump (ps)
        $decl o $call n_str (t.text, t.line, t.col) }.o
      { $decl t $call peek (ps)
        $decl o $call fail_at (ps,
            $call concat ("$", $call concat (kwt.text,
            $call concat (" operand ", $call concat ($call int_to_str (idx),
            $call concat (" must be a string literal, found ", $call describe (t.kind)))))),
            t.line, t.col) }.o

// Every element of a `$template`'s generic group must be a plain name (§4.9).
// This is where prop tags pay for themselves: the check is a `$match` on the
// node's tag, not a field probe.
// The catch-all arm has to *name* something of the scrutinee's type (§4.7's
// idiom is `$match x ($case x …)`), so an expression scrutinee gets bound
// first. Note that `$decl h xs.head` is safe only because `xs.head` is a value:
// binding a reference would keep it a reference (§5.4) and the pattern would
// then be testing the wrong shape.
$decl all_names $func ($decl xs nodes.node) $match xs (
  $case {$prop tag "cons"}
    { $decl h xs.head
      $decl out $match h (
          $case {$prop tag "name"} $call all_names (xs.tail),
          $case h false
        ) }.out,
  $case xs true
)

$decl parse_names_operand $func ($decl ps proto_parser, $decl kwt L.proto_token, $decl idx 0)
  $if ($call at_kind (ps, "lparen"))
      { $decl g $call parse_group (ps)
        $decl o $match g (
            // `(T)` folded to `T` — §2.3 again.
            $case {$prop tag "name"} g,
            $case {$prop tag "group"} $if ($call all_names (g.items)) g
                ($call fail_at (ps,
                    $call concat ("$", $call concat (kwt.text, " generic parameters must be plain names")),
                    g.line, g.col)),
            $case g ($call fail_at (ps,
                $call concat ("$", $call concat (kwt.text, " expects a name or a group of names")),
                g.line, g.col))
          ) }.o
      ($call parse_name_operand (ps, kwt, idx))

$decl parse_operand $func ($decl ps proto_parser, $decl kwt L.proto_token, $decl kind "", $decl idx 0)
  $if ($call eq_str (kind, "name"))  ($call parse_name_operand (ps, kwt, idx))
  ($if ($call eq_str (kind, "str"))   ($call parse_str_operand (ps, kwt, idx))
  ($if ($call eq_str (kind, "names")) ($call parse_names_operand (ps, kwt, idx))
       ($call parse_expr (ps))))

// A keyword form reads exactly its own operands — no precedence, no
// associativity, no separators (§2.2).
$decl parse_form $func ($decl ps proto_parser)
  { $decl t $call bump (ps)
    $decl s $call lookup_kw (t.text)
    $decl out $if ($call eq_int (s.arity, -1))
        ($call fail_at (ps, $call concat ("unknown keyword '$", $call concat (t.text, "'")), t.line, t.col))
        // Operands are evaluated in source order (§7.1), so these three
        // `$decl`s consume tokens left to right.
        { $decl o1 $if ($call lt (0, s.arity)) ($call parse_operand (ps, t, s.o1, 1)) ($call n_unit (t.line, t.col))
          $decl o2 $if ($call lt (1, s.arity)) ($call parse_operand (ps, t, s.o2, 2)) ($call n_unit (t.line, t.col))
          $decl o3 $if ($call lt (2, s.arity)) ($call parse_operand (ps, t, s.o3, 3)) ($call n_unit (t.line, t.col))
          $decl ops $if ($call eq_int (s.arity, 1))
              ($call nodes.cons (o1, nodes.nil))
              ($if ($call eq_int (s.arity, 2))
                  ($call nodes.cons (o1, $call nodes.cons (o2, nodes.nil)))
                  ($call nodes.cons (o1, $call nodes.cons (o2, $call nodes.cons (o3, nodes.nil)))))
          $decl n $call n_form (t.text, ops, t.line, t.col) }.n }.out

$decl parse_primary $func ($decl ps proto_parser)
  { $decl t $call peek (ps)
    $decl k t.kind
    $decl out $if ($call eq_str (k, "int"))     ($do ($call bump (ps)) ($call n_int (t.num, t.line, t.col)))
             ($if ($call eq_str (k, "float"))   ($do ($call bump (ps)) ($call n_float (t.text, t.line, t.col)))
             ($if ($call eq_str (k, "str"))     ($do ($call bump (ps)) ($call n_str (t.text, t.line, t.col)))
             ($if ($call eq_str (k, "true"))    ($do ($call bump (ps)) ($call n_bool (true, t.line, t.col)))
             ($if ($call eq_str (k, "false"))   ($do ($call bump (ps)) ($call n_bool (false, t.line, t.col)))
             ($if ($call eq_str (k, "name"))    ($do ($call bump (ps)) ($call n_name (t.text, t.line, t.col)))
             ($if ($call eq_str (k, "lparen"))  ($call parse_group (ps))
             ($if ($call eq_str (k, "lbrace"))  ($call parse_block (ps))
             ($if ($call eq_str (k, "keyword")) ($call parse_form (ps))
             // The lexer already described what went wrong; carry its message
             // rather than inventing a worse one.
             ($if ($call eq_str (k, "invalid")) ($do ($call bump (ps)) ($call fail_at (ps, t.text, t.line, t.col)))
             ($if ($call eq_str (k, "eof"))
                  ($call fail_at (ps, "unexpected end of file, expected an expression", t.line, t.col))
             ($if ($call or ($call eq_str (k, "proj_name"), $call eq_str (k, "proj_index")))
                  ($do ($call bump (ps)) ($call fail_at (ps, "projection has nothing to its left", t.line, t.col)))
                  ($do ($call bump (ps))
                       ($call fail_at (ps, $call concat ("expected an expression, found ", $call describe (k)),
                                       t.line, t.col)))))))))))))) }.out

// Postfix projection binds tighter than everything else. Since there are no
// infix operators, a `.x` token can only be a projection.
$decl parse_postfix $func ($decl ps proto_parser, $decl n proto_node)
  $if ($call at_kind (ps, "proj_name"))
      { $decl t $call bump (ps)
        $decl o $call parse_postfix (ps, $call n_projn (n, t.text, n.line, n.col)) }.o
  ($if ($call at_kind (ps, "proj_index"))
      { $decl t $call bump (ps)
        $decl o $call parse_postfix (ps, $call n_proji (n, t.num, n.line, n.col)) }.o
      n)

$decl parse_expr $func ($decl ps proto_parser)
  $call parse_postfix (ps, $call parse_primary (ps))

// ---------------------------------------------------------------- validation
//
// One rule the arity table cannot express: §2.2 says `$case` is "only inside
// `$match`". Checked after parsing, because the arms sit inside a group and
// threading a "we are in arms" flag through group parsing would be both fiddly
// and easy to get subtly wrong.

$fwd validate

$decl validate_list $func ($decl xs nodes.node, $decl ps proto_parser) $match xs (
  $case {$prop tag "cons"} $do ($call validate (xs.head, ps)) ($call validate_list (xs.tail, ps)),
  $case xs ()
)

$decl validate_arm $func ($decl a proto_node, $decl ps proto_parser) $match a (
  $case {$prop tag "form"} $if ($call eq_str (a.keyword, "case"))
      // The pattern is a type-only position (§5.7) and is never evaluated, but
      // it is still an expression and can still hide a stray `$case`.
      ($call validate_list (a.operands, ps))
      ($do ($call note_at_span (ps, "$match arms must be $case forms", a))
           ($call validate (a, ps))),
  $case a ($call note_at_span (ps, "$match arms must be $case forms", a))
)

$decl validate_arm_items $func ($decl xs nodes.node, $decl ps proto_parser) $match xs (
  $case {$prop tag "cons"} $do ($call validate_arm (xs.head, ps)) ($call validate_arm_items (xs.tail, ps)),
  $case xs ()
)

// Because `(e)` folds to `e` (§2.3), a single-arm match has the `$case` form
// here directly rather than a group.
$decl validate_arms $func ($decl arms proto_node, $decl ps proto_parser) $match arms (
  $case {$prop tag "form"} $call validate_arm (arms, ps),
  $case {$prop tag "group"} $call validate_arm_items (arms.items, ps),
  $case arms ($call note_at_span (ps, "$match arms must be a group of $case forms", arms))
)

$decl validate $func ($decl n proto_node, $decl ps proto_parser) $match n (
  $case {$prop tag "form"}
    $if ($call eq_str (n.keyword, "match"))
        ($do ($call validate ($call nodes.nth (n.operands, 0), ps))
             ($call validate_arms ($call nodes.nth (n.operands, 1), ps)))
        ($if ($call eq_str (n.keyword, "case"))
             ($do ($call note_at_span (ps, "$case is only valid as an arm of $match", n))
                  ($call validate_list (n.operands, ps)))
             ($call validate_list (n.operands, ps))),
  $case {$prop tag "group"}      $call validate_list (n.items, ps),
  $case {$prop tag "block"}      $call validate_list (n.items, ps),
  $case {$prop tag "proj_name"}  $call validate (n.target, ps),
  $case {$prop tag "proj_index"} $call validate (n.target, ps),
  $case n ()
)

// --------------------------------------------------------------------- output
//
// The same compact S-expression stage 0's parser prints, so the two can be
// diffed against each other on real files.

$fwd dump

$decl dump_items $func ($decl xs nodes.node, $decl acc "") $match xs (
  $case {$prop tag "cons"}
    $call dump_items (xs.tail, $call concat (acc, $call concat (" ", $call dump (xs.head)))),
  $case xs acc
)

$decl dump_list $func ($decl head "", $decl xs nodes.node)
  $call concat (head, $call concat ($call dump_items (xs, ""), ")"))

$decl dump $func ($decl n proto_node) $match n (
  $case {$prop tag "int"}   $call int_to_str (n.value),
  $case {$prop tag "float"} n.text,
  $case {$prop tag "str"}   $call concat ("\"", $call concat (n.text, "\"")),
  $case {$prop tag "bool"}  $if n.value "true" "false",
  $case {$prop tag "name"}  n.text,
  $case {$prop tag "unit"}  "()",
  $case {$prop tag "group"} $call dump_list ("(group", n.items),
  $case {$prop tag "block"} $call dump_list ("(block", n.items),
  $case {$prop tag "proj_name"}
    $call concat ("(. ", $call concat ($call dump (n.target), $call concat (" ", $call concat (n.field, ")")))),
  $case {$prop tag "proj_index"}
    $call concat ("(. ", $call concat ($call dump (n.target),
                  $call concat (" ", $call concat ($call int_to_str (n.index), ")")))),
  $case {$prop tag "form"} $call dump_list ($call concat ("($", n.keyword), n.operands),
  $case n "<error>"
)

// ---------------------------------------------------------------------- entry

$decl file_items $func ($decl ps proto_parser, $decl acc nodes.node)
  $if ($call at_kind (ps, "eof")) acc
      // `parse_expr` always consumes at least one token except at `eof`, which
      // is checked first, so this terminates.
      ($call file_items (ps, $call nodes.cons ($call parse_expr (ps), acc)))

// §3.3: "A source file is a block." Returns the expressions plus any
// diagnostics; a tree comes back either way, with the unparsable parts marked.
$decl parse_tokens $func ($decl ts L.toks.node)
  { $decl ps      $call parser (ts)
    $decl rev     $call file_items (ps, nodes.nil)
    // Not `$decl exprs`: the field below would then read the slot it is
    // itself initializing, which §4.1 forbids — a name is readable from
    // inside its own initializer only from within a `$func` body.
    $decl es      $call nodes.reverse (rev, nodes.nil)
    $decl checked $call validate_list (es, ps)
    $decl result  { $decl exprs es
                    $decl errs  $call diags.reverse (ps.errs, diags.nil) } }.result

$decl parse $func ($decl src "") $call parse_tokens ($call L.tokenize (src))

$decl dump_file $func ($decl xs nodes.node, $decl acc "") $match xs (
  $case {$prop tag "cons"}
    $call dump_file (xs.tail, $call concat (acc, $call concat ($call dump (xs.head), "\n"))),
  $case xs acc
)
