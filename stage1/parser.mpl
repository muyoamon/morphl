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

// `file` last, so the record stays a prefix extension of what it was (§5.1)
// and every existing reader keeps working. The parser leaves it empty — it is
// handed a source string and does not know where it came from; whoever did the
// reading fills it in.
$decl diag $func ($decl m "", $decl l 0, $decl c 0, $decl f "")
  { $decl msg m  $decl line l  $decl col c  $decl file f }

$decl proto_diag $call diag ("", 0, 0, "")
$decl diags      $specialize P.list proto_diag

// ------------------------------------------------------------------ AST nodes
//
// Leaf shapes first: the union below needs one of them evaluated.
//
// Every node starts with `line` and `col`. §5.1 matches blocks by ordered
// prefix, so that shared prefix is what makes `{line:Int, col:Int}` a supertype
// of every node type *and* of the token type — one span accessor, no per-kind
// dispatch, and the upcast is free (§7.4).

$decl n_int   $func ($decl v 0,     $decl l 0, $decl c 0) {
  $prop tag "int"   $decl line l  $decl col c  $decl value v
}
$decl n_float $func ($decl t "",    $decl l 0, $decl c 0) {
  $prop tag "float" $decl line l  $decl col c  $decl text t
}
$decl n_str   $func ($decl t "",    $decl l 0, $decl c 0) {
  $prop tag "str"   $decl line l  $decl col c  $decl text t
}
$decl n_bool  $func ($decl v P.boolean, $decl l 0, $decl c 0) {
  $prop tag "bool"  $decl line l  $decl col c  $decl value v
}
$decl n_name  $func ($decl t "",    $decl l 0, $decl c 0) {
  $prop tag "name"  $decl line l  $decl col c  $decl text t
}
$decl n_unit  $func ($decl l 0,
    $decl c 0)            { $prop tag "unit"  $decl line l  $decl col c }
$decl n_err   $func ($decl m "",    $decl l 0, $decl c 0) {
  $prop tag "error" $decl line l  $decl col c  $decl msg m
}

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
 {  // §5.5: every field that reaches a node again goes through storage. Boxing
   // the *list* is enough for a list of nodes — a cons cell holds its element
   // inline, so its size needs the node's, and putting the list behind a pointer
   // is what breaks that circle. The elements themselves stay values.
   $prop tag "group"      $decl line 0  $decl col 0
   $decl items $alloc ($specialize P.list proto_node).node
 },
  {
    $prop tag "block"      $decl line 0  $decl col 0
    $decl items $alloc ($specialize P.list proto_node).node
  },
  { $prop tag "proj_name"  $decl line 0  $decl col 0  $decl target $alloc proto_node  $decl field "" },
  { $prop tag "proj_index" $decl line 0  $decl col 0  $decl target $alloc proto_node  $decl index 0 },
  {
    $prop tag "form"       $decl line 0  $decl col 0  $decl keyword ""
    $decl operands $alloc ($specialize P.list proto_node).node
  }
)

$decl nodes $specialize P.list proto_node

// Aggregate shapes, now that there is a list of nodes to hold.
$decl n_group $func ($decl xs nodes.node, $decl l 0, $decl c 0)
  { $prop tag "group" $decl line l  $decl col c  $decl items $alloc xs }

$decl n_block $func ($decl xs nodes.node, $decl l 0, $decl c 0)
  { $prop tag "block" $decl line l  $decl col c  $decl items $alloc xs }

$decl n_projn $func ($decl tgt proto_node, $decl f "", $decl l 0, $decl c 0)
  { $prop tag "proj_name" $decl line l  $decl col c  $decl target $alloc tgt  $decl field f }

$decl n_proji $func ($decl tgt proto_node, $decl i 0, $decl l 0, $decl c 0)
  { $prop tag "proj_index" $decl line l  $decl col c  $decl target $alloc tgt  $decl index i }

$decl n_form $func ($decl kw "", $decl ops nodes.node, $decl l 0, $decl c 0)
  { $prop tag "form" $decl line l  $decl col c  $decl keyword kw  $decl operands $alloc ops }

// ------------------------------------------------------- the §2.2 arity table
//
// Operand kinds beyond "expr" exist because §2.2 names some operands "name" or
// "string literal": enforcing that here turns what would otherwise be a
// confusing downstream type error into a precise syntax error.

$decl kw_entry $func ($decl n "", $decl a 0, $decl k1 "", $decl k2 "", $decl k3 "")
  { $decl name n  $decl arity a  $decl o1 k1  $decl o2 k2  $decl o3 k3 }

$decl proto_kw $call kw_entry ("", 0, "", "", "")
$decl kws      $specialize P.list proto_kw
$decl no_kw    $call kw_entry ("", -1, "", "", "")

// `kws.node` rather than `kws.nil`: `$new` takes the type of its operand
// (§4.2), so initialising from `nil` would give storage that only a `nil`
// fits into. §4.8a is exactly the way to name the union without branching.
$decl kw_table $mut $alloc kws.node

$decl add_kw $func ($decl n "", $decl a 0, $decl k1 "", $decl k2 "", $decl k3 "")
  $set kw_table ($call kws.cons ($call kw_entry (n, a, k1, k2, k3), kw_table))

// Bare expressions in a block run for effect and are discarded (§3.3), so the
// table reads as a table instead of a chain of nested `cons`.
$call add_kw ("decl",       2, "name",  "expr", "")
$call add_kw ("prop",       2, "name",  "expr", "")
$call add_kw ("fwd",        1, "name",  "",     "")
$call add_kw ("new",        1, "expr",  "",     "")
$call add_kw ("alloc",      1, "expr",  "",     "")
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

$decl parser $func ($decl ts L.toks.node) {
  $decl rest $mut $alloc ts
  $decl errs $mut $alloc diags.node
}

$decl proto_parser $call parser (L.toks.nil)
$decl eof_token    $call L.token ("eof", "", 0, 0, 0)

// The list is read out of storage first so that it can be `$match`ed: only
// `$match` narrows (§4.7), and a bare `$if` would leave the union un-narrowed
// with nothing to project. Binding it also gives the catch-all a name.
$decl peek $func ($decl ps proto_parser) {
  $decl rest $call L.toks.val (ps.rest)
  $decl ret $match rest (
      $case {$prop tag "cons"} rest.head,
      $case rest eof_token
    )
}.ret

$decl at_kind $func ($decl ps proto_parser, $decl k "")
  $call eq_str (($call peek (ps)).kind, k)

// Never advances past `eof`, so `peek` is always answerable.
$decl bump $func ($decl ps proto_parser) {
  $decl t    $call peek (ps)
  $decl rest $call L.toks.val (ps.rest)
  $decl moved $match rest (
      $case {$prop tag "cons"} $if ($call eq_str (t.kind, "eof")) () ($set ps.rest rest.tail),
      $case rest ()
    )
  $decl ret t
}.ret

$decl note_at $func ($decl ps proto_parser, $decl m "", $decl l 0, $decl c 0)
  $set ps.errs ($call diags.cons ($call diag (m, l, c, ""), ps.errs))

// Accepts any node *or* token, because both begin with `line`/`col` and §5.1
// makes `{line:Int, col:Int}` a prefix supertype of each.
$decl note_at_span $func ($decl ps proto_parser, $decl m "", $decl x P.proto_span)
  $call note_at (ps, m, x.line, x.col)

$decl note $func ($decl ps proto_parser, $decl m "") {
  $decl t   $call peek (ps)
  $decl ret $call note_at (ps, m, t.line, t.col)
}.ret

$decl fail_at $func ($decl ps proto_parser, $decl m "", $decl l 0, $decl c 0) {
  $decl noted $call note_at (ps, m, l, c)
  $decl ret   $call n_err (m, l, c)
}.ret

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
$decl group_items $func ($decl ps proto_parser, $decl acc nodes.node, $decl open L.proto_token) {
  $decl e    $call parse_expr (ps)
  $decl acc2 $call nodes.cons (e, acc)
  $decl ret $if ($call at_kind (ps, "comma"))
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
                ($do ($call bump (ps)) ($call group_items (ps, acc2, open))))))
}.ret

$decl parse_group $func ($decl ps proto_parser) {
  $decl open $call bump (ps)
  $decl ret $if ($call at_kind (ps, "rparen"))
      // §2.3: the empty group and the empty block are the same value.
      ($do ($call bump (ps)) ($call n_unit (open.line, open.col))) {
        $decl rev   $call group_items (ps, nodes.nil, open)
        $decl items $call nodes.reverse (rev, nodes.nil)
        $decl n     $call nodes.length (items, 0)
        // §2.3: "A one-element group is the element." There is no one-tuple,
        // so a folded group never reaches the tree.
        $decl ret2 $if ($call eq_int (n, 1)) ($call nodes.nth (items, 0))
               ($if ($call eq_int (n, 0)) ($call n_unit (open.line, open.col))
                    ($call n_group (items, open.line, open.col)))
      }.ret2
}.ret

// `{ e e … }` — §2.3, no separator required. The recursive call is in tail
// position, which matters: a block can hold a whole file.
$decl block_items $func ($decl ps proto_parser, $decl acc nodes.node, $decl open L.proto_token)
  $if ($call at_kind (ps, "rbrace")) ($do ($call bump (ps)) acc)
  ($if ($call at_kind (ps, "eof"))
       ($do ($call note_at (ps, "unclosed '{' — block is missing its '}'", open.line, open.col)) acc)
       ($call block_items (ps, $call nodes.cons ($call parse_expr (ps), acc), open)))

$decl parse_block $func ($decl ps proto_parser) {
  $decl open $call bump (ps)
  $decl ret $if ($call at_kind (ps, "rbrace"))
      ($do ($call bump (ps)) ($call n_unit (open.line, open.col))) {
        $decl rev  $call block_items (ps, nodes.nil, open)
        $decl ret2 $call n_block ($call nodes.reverse (rev, nodes.nil), open.line, open.col)
      }.ret2
}.ret

$decl parse_name_operand $func ($decl ps proto_parser, $decl kwt L.proto_token, $decl idx 0)
  $if ($call at_kind (ps, "name")) {
    $decl t   $call bump (ps)
    $decl ret $call n_name (t.text, t.line, t.col)
  }.ret {
    $decl t $call peek (ps)
    $decl ret $call fail_at (ps,
        $call concat ("$", $call concat (kwt.text,
        $call concat (" operand ", $call concat ($call int_to_str (idx),
        $call concat (" must be a name, found ", $call describe (t.kind)))))),
        t.line, t.col)
  }.ret

$decl parse_str_operand $func ($decl ps proto_parser, $decl kwt L.proto_token, $decl idx 0)
  $if ($call at_kind (ps, "str")) {
    $decl t   $call bump (ps)
    $decl ret $call n_str (t.text, t.line, t.col)
  }.ret {
    $decl t $call peek (ps)
    $decl ret $call fail_at (ps,
        $call concat ("$", $call concat (kwt.text,
        $call concat (" operand ", $call concat ($call int_to_str (idx),
        $call concat (" must be a string literal, found ", $call describe (t.kind)))))),
        t.line, t.col)
  }.ret

// Every element of a `$template`'s generic group must be a plain name (§4.9).
// This is where prop tags pay for themselves: the check is a `$match` on the
// node's tag, not a field probe.
// The catch-all arm has to *name* something of the scrutinee's type (§4.7's
// idiom is `$match x ($case x …)`), so an expression scrutinee gets bound
// first. Note that `$decl h xs.head` is safe only because `xs.head` is a value:
// binding a reference would keep it a reference (§5.4) and the pattern would
// then be testing the wrong shape.
// §4.9: a generic is a bare name, unbounded, or `$decl name bound` — written as a `$func`
// parameter is, the bound standing where a default stands (TRAITS.md, design point 6).
$decl is_name_n $func ($decl h proto_node) $match h ($case {$prop tag "name"} true, $case h false)
$decl is_generic $func ($decl h proto_node) $match h (
  $case {$prop tag "name"} true,
  $case {$prop tag "form"}
    $if ($call eq_str (h.keyword, "decl")) ($call is_name_n ($call nodes.nth (h.operands, 0))) false,
  $case h false
)

// A generic's name, and its bound — unit when it has none. Shared, so both passes read a
// `$template`'s generics the same way.
$decl gname_of $func ($decl h proto_node) $match h ($case {$prop tag "name"} h.text, $case h "")
$decl generic_name $func ($decl h proto_node) $match h (
  $case {$prop tag "name"} h.text,
  $case {$prop tag "form"} ($call gname_of ($call nodes.nth (h.operands, 0))),
  $case h ""
)
$decl generic_bound $func ($decl h proto_node) $match h (
  $case {$prop tag "form"} ($call nodes.nth (h.operands, 1)),
  $case h ($call n_unit (0, 0))
)
$decl generic_bounds_list $func ($decl xs nodes.node, $decl acc nodes.node) $match xs (
  $case {$prop tag "cons"}
    $call generic_bounds_list ($call nodes.val (xs.tail),
        $call nodes.cons ($call generic_bound (xs.head), acc)),
  $case xs ($call nodes.reverse (acc, nodes.nil))
)
// One bound per generic, in order, for a `$template`'s generics operand.
$decl generic_bounds $func ($decl n proto_node) $match n (
  $case {$prop tag "group"} ($call generic_bounds_list ($call nodes.val (n.items), nodes.nil)),
  $case n ($call nodes.cons ($call generic_bound (n), nodes.nil))
)

$decl all_names $func ($decl xs nodes.node) $match xs (
  $case {$prop tag "cons"} $if ($call is_generic (xs.head)) ($call all_names (xs.tail)) false,
  $case xs true
)

$decl parse_names_operand $func ($decl ps proto_parser, $decl kwt L.proto_token, $decl idx 0)
  $if ($call at_kind (ps, "lparen")) {
    $decl g $call parse_group (ps)
    $decl ret $match g (
        // `(T)` folded to `T` — §2.3 again — and `($decl K b)` to the `$decl`.
        $case {$prop tag "name"} g,
        $case {$prop tag "form"} $if ($call is_generic (g)) g
            ($call fail_at (ps,
                $call concat ("$", $call concat (kwt.text, " expects a name or a group of names")),
                g.line, g.col)),
        $case {$prop tag "group"} $if ($call all_names (g.items)) g
            ($call fail_at (ps,
                $call concat ("$", $call concat (kwt.text,
                    " generic parameters must be names or $decl name bound")),
                g.line, g.col)),
        $case g ($call fail_at (ps,
            $call concat ("$", $call concat (kwt.text, " expects a name or a group of names")),
            g.line, g.col))
      )
  }.ret
      ($call parse_name_operand (ps, kwt, idx))

$decl parse_operand $func ($decl ps proto_parser, $decl kwt L.proto_token, $decl kind "",
    $decl idx 0)
  $if ($call eq_str (kind, "name"))  ($call parse_name_operand (ps, kwt, idx))
  ($if ($call eq_str (kind, "str"))   ($call parse_str_operand (ps, kwt, idx))
  ($if ($call eq_str (kind, "names")) ($call parse_names_operand (ps, kwt, idx))
       ($call parse_expr (ps))))

// A keyword form reads exactly its own operands — no precedence, no
// associativity, no separators (§2.2).
$decl parse_form $func ($decl ps proto_parser) {
  $decl t $call bump (ps)
  $decl s $call lookup_kw (t.text)
  $decl ret $if ($call eq_int (s.arity, -1))
      ($call fail_at (ps, $call concat ("unknown keyword '$", $call concat (t.text, "'")), t.line, t.col)) {
        // Operands are evaluated in source order (§7.1), so these three
        // `$decl`s consume tokens left to right.
        $decl o1 $if ($call lt (0, s.arity)) ($call parse_operand (ps, t, s.o1,
            1)) ($call n_unit (t.line, t.col))
        $decl o2 $if ($call lt (1, s.arity)) ($call parse_operand (ps, t, s.o2,
            2)) ($call n_unit (t.line, t.col))
        $decl o3 $if ($call lt (2, s.arity)) ($call parse_operand (ps, t, s.o3,
            3)) ($call n_unit (t.line, t.col))
        $decl ops $if ($call eq_int (s.arity, 1))
            ($call nodes.cons (o1, nodes.nil))
            ($if ($call eq_int (s.arity, 2))
                ($call nodes.cons (o1, $call nodes.cons (o2, nodes.nil)))
                ($call nodes.cons (o1, $call nodes.cons (o2, $call nodes.cons (o3, nodes.nil)))))
        $decl ret2 $call n_form (t.text, ops, t.line, t.col)
      }.ret2
}.ret

$decl parse_primary $func ($decl ps proto_parser) {
  $decl t $call peek (ps)
  $decl k t.kind
  $decl ret $if ($call eq_str (k, "int"))     ($do ($call bump (ps)) ($call n_int (t.num, t.line,
      t.col)))
           ($if ($call eq_str (k, "float"))   ($do ($call bump (ps)) ($call n_float (t.text, t.line,
               t.col)))
           ($if ($call eq_str (k, "str"))     ($do ($call bump (ps)) ($call n_str (t.text, t.line,
               t.col)))
           ($if ($call eq_str (k, "true"))    ($do ($call bump (ps)) ($call n_bool (true, t.line,
               t.col)))
           ($if ($call eq_str (k, "false"))   ($do ($call bump (ps)) ($call n_bool (false, t.line,
               t.col)))
           ($if ($call eq_str (k, "name"))    ($do ($call bump (ps)) ($call n_name (t.text, t.line,
               t.col)))
           ($if ($call eq_str (k, "lparen"))  ($call parse_group (ps))
           ($if ($call eq_str (k, "lbrace"))  ($call parse_block (ps))
           ($if ($call eq_str (k, "keyword")) ($call parse_form (ps))
           // The lexer already described what went wrong; carry its message
           // rather than inventing a worse one.
           ($if ($call eq_str (k, "invalid")) ($do ($call bump (ps)) ($call fail_at (ps, t.text,
               t.line, t.col)))
           ($if ($call eq_str (k, "eof"))
                ($call fail_at (ps, "unexpected end of file, expected an expression", t.line, t.col))
           ($if ($call or ($call eq_str (k, "proj_name"), $call eq_str (k, "proj_index")))
                ($do ($call bump (ps)) ($call fail_at (ps, "projection has nothing to its left", t.line, t.col)))
                ($do ($call bump (ps))
                     ($call fail_at (ps, $call concat ("expected an expression, found ", $call describe (k)),
                                     t.line, t.col))))))))))))))
}.ret

// Postfix projection binds tighter than everything else. Since there are no
// infix operators, a `.x` token can only be a projection.
$decl parse_postfix $func ($decl ps proto_parser, $decl n proto_node)
  $if ($call at_kind (ps, "proj_name")) {
    $decl t   $call bump (ps)
    $decl ret $call parse_postfix (ps, $call n_projn (n, t.text, n.line, n.col))
  }.ret
  ($if ($call at_kind (ps, "proj_index")) {
    $decl t   $call bump (ps)
    $decl ret $call parse_postfix (ps, $call n_proji (n, t.num, n.line, n.col))
  }.ret
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
  $case {$prop tag "cons"} $do ($call validate_arm (xs.head,
      ps)) ($call validate_arm_items (xs.tail, ps)),
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
    $call concat ("(. ", $call concat ($call dump (n.target), $call concat (" ",
        $call concat (n.field, ")")))),
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
$decl parse_tokens $func ($decl ts L.toks.node) {
  $decl ps  $call parser (ts)
  $decl rev $call file_items (ps, nodes.nil)
  // Not `$decl exprs`: the field below would then read the slot it is
  // itself initializing, which §4.1 forbids — a name is readable from
  // inside its own initializer only from within a `$func` body.
  $decl es      $call nodes.reverse (rev, nodes.nil)
  $decl checked $call validate_list (es, ps)
  $decl ret  {
    $decl exprs es
    $decl errs  $call diags.reverse (ps.errs, diags.nil)
  }
}.ret

$decl parse $func ($decl src "") $call parse_tokens ($call L.tokenize (src))

$decl dump_file $func ($decl xs nodes.node, $decl acc "") $match xs (
  $case {$prop tag "cons"}
    $call dump_file (xs.tail, $call concat (acc, $call concat ($call dump (xs.head), "\n"))),
  $case xs acc
)

// ------------------------------------------------------- names, for §5.3a
//
// Two walks over the AST, here because the AST is here: lowering needs the
// free names of a `$func` literal to build its capture list (§7.3), and
// inference needs them to decide whether a literal captured frame storage
// (§5.3a). One definition, two readers.

$decl pstrs $specialize P.list ""

$decl mem_pstr $func ($decl xs pstrs.node, $decl x "") $match xs (
  $case {$prop tag "cons"} $if ($call eq_str (xs.head, x)) true ($call mem_pstr (xs.tail, x)),
  $case xs false
)

$decl name_text $func ($decl n proto_node) $match n (
  $case {$prop tag "name"} n.text,
  $case n ""
)

$decl operand $func ($decl n proto_node, $decl i 0) $match n (
  $case {$prop tag "form"} ($call nodes.nth (n.operands, i)),
  $case n ($call n_err ("no operand", 0, 0))
)

$decl is_kw $func ($decl n proto_node, $decl k "") $match n (
  $case {$prop tag "form"} ($call eq_str (n.keyword, k)),
  $case n false
)

$fwd free_names

$decl free_names_list $func ($decl xs nodes.node, $decl acc pstrs.node) $match xs (
  $case {$prop tag "cons"}
    $call free_names_list (xs.tail, $call free_names (xs.head, acc)),
  $case xs acc
)

// Every name *mentioned*. Naive on purpose: lowering wants exactly this, since
// over-capturing costs a word and no correctness, and inference subtracts the
// bound names below.
$decl free_names $func ($decl n proto_node, $decl acc pstrs.node) $match n (
  $case {$prop tag "name"}
    $if ($call mem_pstr (acc, n.text)) acc ($call pstrs.cons (n.text, acc)),
  // §7.6: `$alloc` draws from the `allocator` in lexical scope, so it reads that name
  // although it never spells it — and a closure that allocates captures it.
  $case {$prop tag "form"}
    $call free_names_list (n.operands,
        $if ($call eq_str (n.keyword, "alloc"))
            ($if ($call mem_pstr (acc, "allocator")) acc ($call pstrs.cons ("allocator", acc)))
            acc),
  $case {$prop tag "group"} ($call free_names_list (n.items, acc)),
  $case {$prop tag "block"} ($call free_names_list (n.items, acc)),
  $case {$prop tag "proj_name"}  ($call free_names (n.target, acc)),
  $case {$prop tag "proj_index"} ($call free_names (n.target, acc)),
  $case n acc
)

$decl bound_group_list $func ($decl xs nodes.node, $decl acc pstrs.node) $match xs (
  $case {$prop tag "cons"} {
    $decl nm $call name_text (xs.head)
    $decl a2 $if ($call eq_str (nm, "")) acc
                 ($if ($call mem_pstr (acc, nm)) acc ($call pstrs.cons (nm, acc)))
    $decl ret  $call bound_group_list (xs.tail, a2)
  }.ret,
  $case xs acc
)

// A group of names, for `$template (A, B)` — and nothing for anything else.
$decl bound_group $func ($decl n proto_node, $decl acc pstrs.node) $match n (
  $case {$prop tag "group"} ($call bound_group_list (n.items, acc)),
  $case n acc
)

$fwd bound_names

$decl bound_names_list $func ($decl xs nodes.node, $decl acc pstrs.node) $match xs (
  $case {$prop tag "cons"}
    $call bound_names_list (xs.tail, $call bound_names (xs.head, acc)),
  $case xs acc
)

// Every name *bound* by a binder anywhere inside. Collected without regard to
// scope nesting, which is the one imprecision: a name both captured and
// shadowed deeper in is dropped from the capture set. That direction is a
// missed capture rather than a wrongly rejected program, which is the right
// way round for a check that would otherwise reject valid code.
$decl bound_names $func ($decl n proto_node, $decl acc pstrs.node) $match n (
  $case {$prop tag "form"} {
    $decl k n.keyword
    // §4.1/§4.10: these name their first operand. §4.7's `$case` binds its
    // pattern when the pattern is a bare name, and §4.9's `$template` binds
    // its generics.
    $decl binds $if ($call eq_str (k, "decl")) true
                    ($if ($call eq_str (k, "prop")) true
                         ($if ($call eq_str (k, "fwd")) true
                              ($if ($call eq_str (k, "case")) true
                                   ($call eq_str (k, "template")))))
    $decl here $if binds {
      $decl nm $call name_text ($call operand (n, 0))
      $decl gs $if ($call eq_str (nm, ""))
          // A `$template`'s generics may be a group, and a `$case`
          // pattern may be anything — a non-name binds nothing.
          ($call bound_group ($call operand (n, 0), acc))
          ($if ($call mem_pstr (acc, nm)) acc ($call pstrs.cons (nm, acc)))
      $decl ret2 gs
    }.ret2
        acc
    $decl ret $call bound_names_list (n.operands, here)
  }.ret,
  $case {$prop tag "group"} ($call bound_names_list (n.items, acc)),
  $case {$prop tag "block"} ($call bound_names_list (n.items, acc)),
  $case n acc
)

// ------------------------------------------------- §4.9's compile-time generics
//
// "A generic whose value reaches a prop after specialization is a *compile-time
// generic*." Whether one does is a question about the template's source, so it is
// answered here, where the AST is, for both readers: inference and lowering each
// supply `rs`, the one thing they answer differently — given a `$specialize`'s
// target, which of that template's generics are compile-time, by position. An
// entry's `prop` is the prop the generic reaches, for the diagnostic at a site that
// passes it something that is not a constant; "" means not compile-time.

$decl ctg_ent   $func ($decl g "", $decl p "") { $decl gen g  $decl prop p }
$decl proto_ctg $call ctg_ent ("", "")
$decl ctgs      $specialize P.list proto_ctg

$decl ctg_prop $func ($decl xs ctgs.node, $decl g "") $match xs (
  $case {$prop tag "cons"} $if ($call eq_str (xs.head.gen,
      g)) xs.head.prop ($call ctg_prop (xs.tail, g)),
  $case xs ""
)

// Position by position: the prop each generic reaches, or "".
$decl ctg_mask $func ($decl gs pstrs.node, $decl xs ctgs.node, $decl acc pstrs.node) $match gs (
  $case {$prop tag "cons"} $call ctg_mask (gs.tail, xs, $call pstrs.cons ($call ctg_prop (xs,
      gs.head), acc)),
  $case gs ($call pstrs.reverse (acc, pstrs.nil))
)

$decl pstrs_without $func ($decl xs pstrs.node, $decl drop pstrs.node,
    $decl acc pstrs.node) $match xs (
  $case {$prop tag "cons"}
    $call pstrs_without (xs.tail, drop,
        $if ($call mem_pstr (drop, xs.head)) acc ($call pstrs.cons (xs.head, acc))),
  $case xs ($call pstrs.reverse (acc, pstrs.nil))
)

// What a block binds directly — the scope a generic of the same name stops at.
$decl block_binders $func ($decl xs nodes.node, $decl acc pstrs.node) $match xs (
  $case {$prop tag "cons"}
    $call block_binders (xs.tail,
        $if ($call or ($call is_kw (xs.head, "decl"), $call or ($call is_kw (xs.head, "prop"),
                                                            $call is_kw (xs.head, "fwd"))))
            ($call pstrs.cons ($call name_text ($call operand (xs.head, 0)), acc)) acc),
  $case xs acc
)

// A `$func`'s parameters: one `$decl`, or a group of them (§3.4).
$decl param_binders $func ($decl n proto_node) $match n (
  $case {$prop tag "group"} ($call block_binders (n.items, pstrs.nil)),
  $case {$prop tag "form"}  ($call block_binders ($call nodes.cons (n, nodes.nil), pstrs.nil)),
  $case n pstrs.nil
)

$decl generic_binders $func ($decl n proto_node) $match n (
  $case {$prop tag "name"} ($call pstrs.cons (n.text, pstrs.nil)),
  $case n ($call bound_group (n, pstrs.nil))
)

$decl group_list $func ($decl n proto_node) $match n (
  $case {$prop tag "group"} ($call nodes.val (n.items)),
  $case n ($call nodes.cons (n, nodes.nil))
)

$decl proto_resolver $func ($decl x proto_node) pstrs.node

$fwd ct_reads

$decl ct_reads_list $func ($decl xs nodes.node, $decl gs pstrs.node, $decl pn "",
                           $decl rs proto_resolver, $decl acc ctgs.node) $match xs (
  $case {$prop tag "cons"}
    $call ct_reads_list (xs.tail, gs, pn, rs, $call ct_reads (xs.head, gs, pn, rs, acc)),
  $case xs acc
)

// A `$specialize`'s arguments, against the callee's mask: an argument for a
// compile-time generic of the callee is read for its value; any other is read for
// its type alone, which is static, so it reaches nothing.
$decl ct_spec_args $func ($decl xs nodes.node, $decl mask pstrs.node, $decl gs pstrs.node,
                          $decl pn "", $decl rs proto_resolver, $decl acc ctgs.node) $match xs (
  $case {$prop tag "cons"} $match mask (
    $case {$prop tag "cons"}
      $call ct_spec_args (xs.tail, mask.tail, gs, pn, rs,
          $if ($call eq_str (mask.head, "")) acc ($call ct_reads (xs.head, gs, pn, rs, acc))),
    $case mask acc),
  $case xs acc
)

// The generics a prop initializer reads in an *evaluated* position (§4.10's
// constant expressions). Type-only positions (§5.7) and a `$func`'s body read
// nothing here; a nested prop is found by `ct_walk`, not by this.
$decl ct_reads $func ($decl n proto_node, $decl gs pstrs.node, $decl pn "",
                      $decl rs proto_resolver, $decl acc ctgs.node) $match n (
  $case {$prop tag "name"}
    $if ($call mem_pstr (gs, n.text))
        ($if ($call eq_str ($call ctg_prop (acc, n.text),
            "")) ($call ctgs.cons ($call ctg_ent (n.text, pn), acc)) acc)
        acc,
  $case {$prop tag "proj_name"}  ($call ct_reads (n.target, gs, pn, rs, acc)),
  $case {$prop tag "proj_index"} ($call ct_reads (n.target, gs, pn, rs, acc)),
  $case {$prop tag "group"} ($call ct_reads_list (n.items, gs, pn, rs, acc)),
  $case {$prop tag "form"} {
    $decl k n.keyword
    $decl ret $if ($call eq_str (k, "union"))
        // §4.8a: the first member is the value; the rest are type-only.
        ($call ct_reads ($call nodes.nth ($call group_list ($call operand (n, 0)), 0), gs, pn, rs,
            acc))
      ($if ($call eq_str (k, "overload"))
        ($call ct_reads_list ($call group_list ($call operand (n, 0)), gs, pn, rs, acc))
      ($if ($call eq_str (k, "specialize")) {
        $decl mask $call rs ($call operand (n, 0))
        $decl args $if ($call eq_int ($call pstrs.length (mask, 0), 1))
            ($call nodes.cons ($call operand (n, 1), nodes.nil))
            ($call group_list ($call operand (n, 1)))
        $decl ret2 $call ct_spec_args (args, mask, gs, pn, rs, acc)
      }.ret2
      ($if ($call or ($call eq_str (k, "impl"), $call eq_str (k, "traitsof")))
        ($call ct_reads_list (n.operands, gs, pn, rs, acc))
        acc)))
  }.ret,
  $case n acc
)

$fwd ct_walk

$decl ct_walk_list $func ($decl xs nodes.node, $decl gs pstrs.node, $decl rs proto_resolver,
                          $decl acc ctgs.node) $match xs (
  $case {$prop tag "cons"} $call ct_walk_list (xs.tail, gs, rs, $call ct_walk (xs.head, gs, rs, acc)),
  $case xs acc
)

// Every `$prop` in the body, at any depth — a block literal inside a `$decl` or a
// `$func` has a type that depends on its props too. A binder of the same name ends
// a generic's scope; without that the scan would demand a constant for a generic a
// prop never reads, which rejects a valid program.
$decl ct_walk $func ($decl n proto_node, $decl gs pstrs.node, $decl rs proto_resolver,
                     $decl acc ctgs.node) $match n (
  $case {$prop tag "form"} {
    $decl k n.keyword
    $decl ret $if ($call eq_str (k, "prop")) {
      $decl init $call operand (n, 1)
      $decl a1   $call ct_reads (init, gs, $call name_text ($call operand (n, 0)), rs, acc)
      $decl ret2 $call ct_walk (init, gs, rs, a1)
    }.ret2
      ($if ($call eq_str (k, "func"))
        ($call ct_walk_list (n.operands,
             $call pstrs_without (gs, $call param_binders ($call operand (n, 0)),
                 pstrs.nil), rs, acc))
      ($if ($call eq_str (k, "template"))
        ($call ct_walk ($call operand (n, 1),
             $call pstrs_without (gs, $call generic_binders ($call operand (n, 0)),
                 pstrs.nil), rs, acc))
        ($call ct_walk_list (n.operands, gs, rs, acc))))
  }.ret,
  $case {$prop tag "block"}
    $call ct_walk_list (n.items,
        $call pstrs_without (gs, $call block_binders (n.items, pstrs.nil), pstrs.nil), rs, acc),
  $case {$prop tag "group"} ($call ct_walk_list (n.items, gs, rs, acc)),
  $case {$prop tag "proj_name"}  ($call ct_walk (n.target, gs, rs, acc)),
  $case {$prop tag "proj_index"} ($call ct_walk (n.target, gs, rs, acc)),
  $case n acc
)

$decl ct_generics $func ($decl body proto_node, $decl gs pstrs.node, $decl rs proto_resolver)
  $call ct_walk (body, gs, rs, ctgs.nil)

// A literal's part of §4.9's memo key, "" for anything that is not a literal. The
// value of a compile-time generic joins the key, and the two passes must spell it
// the same way, because the key is what every identity in the body is minted from.
$decl lit_key $func ($decl n proto_node) $match n (
  $case {$prop tag "int"}  ($call concat ("i", $call int_to_str (n.value))),
  $case {$prop tag "str"}  ($call concat ("s", n.text)),
  $case {$prop tag "bool"} ($if n.value "true" "false"),
  $case {$prop tag "unit"} "()",
  $case n ""
)

// §4.14: "Names are logical. The build program supplies the resolver (search roots and
// an explicit name→file map)." A name resolves against `base` — the entry file's
// directory, as it always has — and then against each library root in order, and the
// first that names a file is the module. When none does, the answer is `base`'s path, so
// a missing module is reported exactly where and as it was. Shared, because a module's
// resolved path is its identity in both passes (§4.14: "all imports of the same resolved
// file yield the same module"), and with no roots it reads nothing.
$decl join_path $func ($decl dir "", $decl nm "")
  $if ($call eq_str (dir, "")) ($call concat (nm, ".mpl"))
      ($call concat (dir, $call concat ("/", $call concat (nm, ".mpl"))))

$decl is_file $func ($decl path "") {
  $decl r   $call read_file (path)
  $decl ret $match r ($case {$prop tag "some"} true, $case r false)
}.ret

$decl resolve_in $func ($decl roots pstrs.node, $decl nm "", $decl dflt "") $match roots (
  $case {$prop tag "cons"} {
    $decl p   $call join_path (roots.head, nm)
    $decl ret $if ($call is_file (p)) p ($call resolve_in ($call pstrs.val (roots.tail), nm, dflt))
  }.ret,
  $case roots dflt
)

$decl resolve_import $func ($decl base "", $decl roots pstrs.node, $decl nm "") {
  $decl here $call join_path (base, nm)
  $decl ret  $if ($call pstrs.is_nil (roots)) here
                 ($if ($call is_file (here)) here ($call resolve_in (roots, nm, here)))
}.ret

// §4.9's application inference: where each generic of a `$func`-bodied template is read
// from. "Inference matches the shape of each parameter default one level deep" — a
// default that is exactly `T` makes `T` that argument's type (`kind` 0); a default that
// is a `$func` literal whose parameter defaults or body are exactly `T` makes it the
// corresponding parameter type (`kind` 1, `pos` its index) or result type (`kind` 2)
// of the argument's function type. The first in parameter order wins, and the call is
// checked against the rest. `arg` is -1 when nothing names the generic. Shared, so the
// two passes infer the same generics and so build the same memo key.
$decl app_src $func ($decl a -1, $decl k 0, $decl j 0) { $decl arg a  $decl kind k  $decl pos j }
$decl proto_app_src $call app_src (-1, 0, 0)
$decl app_srcs      $specialize P.list proto_app_src

$decl app_items $func ($decl n proto_node) $match n (
  $case {$prop tag "group"} ($call nodes.val (n.items)),
  $case {$prop tag "unit"}  nodes.nil,
  $case n ($call nodes.cons (n, nodes.nil))
)

$decl is_named $func ($decl n proto_node, $decl g "") $match n (
  $case {$prop tag "name"} ($call eq_str (n.text, g)),
  $case n false
)

// The default of a `$decl` parameter, or unit for anything else.
$decl param_default $func ($decl d proto_node)
  $if ($call is_kw (d, "decl")) ($call operand (d, 1)) ($call n_unit (0, 0))

// Which parameter of a `$func` literal is defaulted to exactly `g`, or -1.
$decl app_in_params $func ($decl ps nodes.node, $decl g "", $decl j 0) $match ps (
  $case {$prop tag "cons"}
    $if ($call is_named ($call param_default (ps.head), g)) j
        ($call app_in_params ($call nodes.val (ps.tail), g, $call add (j, 1))),
  $case ps -1
)

$decl app_find $func ($decl ps nodes.node, $decl g "", $decl i 0) $match ps (
  $case {$prop tag "cons"} {
    $decl df  $call param_default (ps.head)
    $decl fj  $if ($call is_kw (df, "func"))
                  ($call app_in_params ($call app_items ($call operand (df, 0)), g, 0)) -1
    $decl fr  $if ($call is_kw (df, "func")) ($call is_named ($call operand (df, 1), g)) false
    $decl ret $if ($call is_named (df, g)) ($call app_src (i, 0, 0))
                  ($if ($call lt (-1, fj)) ($call app_src (i, 1, fj))
                  ($if fr ($call app_src (i, 2, 0))
                       ($call app_find ($call nodes.val (ps.tail), g, $call add (i, 1)))))
  }.ret,
  $case ps ($call app_src (-1, 0, 0))
)

// One source per generic, in the generics' order. `fnb` is the template's `$func` body.
$decl app_sources $func ($decl fnb proto_node, $decl gs pstrs.node, $decl acc app_srcs.node)
  $match gs (
    $case {$prop tag "cons"}
      $call app_sources (fnb, $call pstrs.val (gs.tail), $call app_srcs.cons (
          $call app_find ($call app_items ($call operand (fnb, 0)), gs.head, 0), acc)),
    $case gs ($call app_srcs.reverse (acc, app_srcs.nil))
  )

// A compile-time generic bound to a literal is replaced by the literal, everywhere
// its scope reaches. That is the substitution §4.9 says it is not — "by reference,
// never textual" — made safe by what a literal is: evaluating one has no effect, so
// once or at every mention is the same program. It is what puts the *value* in the
// type: `$prop tag N` becomes `$prop tag "circle"`, a scalar prop, which both
// passes then read the same way.
$fwd subst_lit

$decl subst_lits $func ($decl xs nodes.node, $decl nm "", $decl lit proto_node,
    $decl acc nodes.node) $match xs (
  $case {$prop tag "cons"}
    $call subst_lits (xs.tail, nm, lit, $call nodes.cons ($call subst_lit (xs.head, nm, lit), acc)),
  $case xs ($call nodes.reverse (acc, nodes.nil))
)

$decl subst_lit $func ($decl n proto_node, $decl nm "", $decl lit proto_node) $match n (
  $case {$prop tag "name"} $if ($call eq_str (n.text, nm)) lit n,
  $case {$prop tag "proj_name"}
    $call n_projn ($call subst_lit (n.target, nm, lit), n.field, n.line, n.col),
  $case {$prop tag "proj_index"}
    $call n_proji ($call subst_lit (n.target, nm, lit), n.index, n.line, n.col),
  $case {$prop tag "group"} ($call n_group ($call subst_lits (n.items, nm, lit, nodes.nil), n.line,
      n.col)),
  $case {$prop tag "block"}
    $if ($call mem_pstr ($call block_binders (n.items, pstrs.nil), nm)) n
        ($call n_block ($call subst_lits (n.items, nm, lit, nodes.nil), n.line, n.col)),
  $case {$prop tag "form"}
    $if ($call or ($call and ($call eq_str (n.keyword, "func"),
                              $call mem_pstr ($call param_binders ($call operand (n, 0)), nm)),
                   $call and ($call eq_str (n.keyword, "template"),
                              $call mem_pstr ($call generic_binders ($call operand (n, 0)), nm))))
        n
        ($call n_form (n.keyword, $call subst_lits (n.operands, nm, lit, nodes.nil), n.line,
            n.col)),
  $case n n
)

// ------------------------------------------------------------ §4.10's receiver
//
// The block a `$decl`'s initializer is, directly or through `$new`, `$alloc`, `$mut`,
// `$const` or `$impl` — for `$impl` the override, whose props are the ones the declaring
// name is the receiver of (§4.12). Anything else answers itself. Inference and lowering
// both ask, so the answer is here.
$decl recv_target $func ($decl n proto_node) $match n (
  $case {$prop tag "form"}
    $if ($call or ($call or ($call eq_str (n.keyword, "new"), $call eq_str (n.keyword, "alloc")),
                   $call or ($call eq_str (n.keyword, "mut"), $call eq_str (n.keyword, "const"))))
        ($call recv_target ($call operand (n, 0)))
        ($if ($call eq_str (n.keyword, "impl")) ($call recv_target ($call operand (n, 2))) n),
  $case n n
)

// The receiver's qualifier: mutable when the declaration reaches its block through
// `$mut`, read-only otherwise.
$decl recv_qual $func ($decl n proto_node) $match n (
  $case {$prop tag "form"}
    $if ($call eq_str (n.keyword, "mut")) "mut"
        ($if ($call or ($call or ($call eq_str (n.keyword, "new"), $call eq_str (n.keyword, "alloc")),
                        $call eq_str (n.keyword, "const")))
             ($call recv_qual ($call operand (n, 0)))
             "const"),
  $case n "const"
)

// Whether the block sits in storage, and which kind (§3.5): "alloc" through `$alloc`,
// "frame" through `$new`, "" for a value.
$decl recv_kind $func ($decl n proto_node) $match n (
  $case {$prop tag "form"}
    $if ($call eq_str (n.keyword, "alloc")) "alloc"
        ($if ($call eq_str (n.keyword, "new")) "frame"
             ($if ($call or ($call eq_str (n.keyword, "mut"), $call eq_str (n.keyword, "const")))
                  ($call recv_kind ($call operand (n, 0))) "")),
  $case n ""
)

$decl is_block $func ($decl n proto_node) $match n ($case {$prop tag "block"} true, $case n false)

// Does a member's body name the receiver? Its free names, less the ones the member itself
// binds — a parameter of the same name is not the receiver.
$decl names_recv $func ($decl init proto_node, $decl rn "")
  $if ($call eq_str (rn, "")) false
      ($if ($call mem_pstr ($call free_names (init, pstrs.nil), rn))
           ($call not ($call mem_pstr ($call bound_names (init, pstrs.nil), rn))) false)
