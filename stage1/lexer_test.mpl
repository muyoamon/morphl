// Tests for stage 1's lexer, written in morphl and run by stage 0:
//
//   morphlc --run stage1/lexer_test.mpl
//
// Run from the repository root — the self-lexing check at the end reads
// stage1/lexer.mpl by path, and BOOTSTRAP.md §2's `read_file` resolves
// relative to the process's working directory.
//
// A failure panics, so the run aborts with a non-zero exit (§7.8: panics abort
// the whole program, there is no catch).

$decl L $import "lexer"
$decl P $import "prelude"

$decl not P.not
$decl and P.and
$decl toks L.toks

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))

$decl check $func ($decl name "", $decl ok true)
  $if ok
      ($do ($call print ("ok   ")) ($call nl (name)))
      ($do ($call print ("FAIL ")) ($do ($call nl (name)) ($call panic (name))))

$decl kind_at $func ($decl src "", $decl i 0)
  ($call toks.nth ($call L.tokenize (src), i)).kind

$decl text_at $func ($decl src "", $decl i 0)
  ($call toks.nth ($call L.tokenize (src), i)).text

$decl num_at $func ($decl src "", $decl i 0)
  ($call toks.nth ($call L.tokenize (src), i)).num

$decl count $func ($decl src "") $call toks.length ($call L.tokenize (src), 0)

// ------------------------------------------------------------------ the tests

$decl t01 $call check ("a keyword lexes as keyword",
  $call eq_str ($call kind_at ("$decl x 1", 0), "keyword"))
$decl t02 $call check ("the keyword carries its text without the $",
  $call eq_str ($call text_at ("$decl x 1", 0), "decl"))
$decl t03 $call check ("an identifier lexes as name",
  $call eq_str ($call kind_at ("$decl x 1", 1), "name"))
$decl t04 $call check ("an integer carries its value",
  $call eq_int ($call num_at ("$decl x 41", 2), 41))
$decl t05 $call check ("the stream ends with eof",
  $call eq_str ($call kind_at ("$decl x 1", 3), "eof"))

// Unlike stage 0, this lexer does not own the keyword table: the parser
// resolves arity, so an unknown keyword is still a `keyword` token here.
$decl t06 $call check ("an unknown keyword is not the lexer's problem",
  $call eq_str ($call kind_at ("$nope", 0), "keyword"))

// §2.1: trivia carries no meaning, and `;` is trivia too.
$decl t07 $call check ("whitespace, comments and ';' are dropped",
  $call eq_int ($call count ("// c\n a ; b /* block\n lines */ c"), 4))
$decl t08 $call check ("an unterminated block comment is reported",
  $call eq_str ($call kind_at ("a /* forever", 1), "invalid"))

// §3.2: true and false are literals, not names.
$decl t09 $call check ("true is its own token", $call eq_str ($call kind_at ("true", 0), "true"))
$decl t10 $call check ("false is its own token", $call eq_str ($call kind_at ("false", 0), "false"))
$decl t11 $call check ("truest is just a name", $call eq_str ($call kind_at ("truest", 0), "name"))

// §2.1: intrinsics are ordinary shadowable names, never keywords.
$decl t12 $call check ("add is an ordinary name", $call eq_str ($call kind_at ("add", 0), "name"))

// A leading `-` is part of the literal.
$decl t13 $call check ("negative integers", $call eq_int ($call num_at ("-7", 0), -7))
$decl t14 $call check ("floats keep their source text",
  $call eq_str ($call text_at ("3.14", 0), "3.14"))
$decl t15 $call check ("a negative float keeps its text",
  $call eq_str ($call text_at ("-2.5", 0), "-2.5"))
$decl t16 $call check ("an oversized integer is invalid",
  $call eq_str ($call kind_at ("99999999999999999999", 0), "invalid"))

// A dot continues a number only when a digit follows it.
$decl t17 $call check ("x.a is a named projection",
  $call eq_str ($call kind_at ("x.a", 1), "proj_name"))
$decl t18 $call check ("the projection carries the field name",
  $call eq_str ($call text_at ("x.a", 1), "a"))
$decl t19 $call check ("p.1 is an indexed projection",
  $call eq_int ($call num_at ("p.1", 1), 1))
$decl t20 $call check ("1.5 is one float, not a projection",
  $call eq_int ($call count ("1.5"), 2))
$decl t21 $call check ("group indices start at .1",
  $call eq_str ($call kind_at ("x.0", 1), "invalid"))

// §2.1 string escapes, decoded.
$decl t22 $call check ("a plain string",
  $call eq_str ($call text_at ("\"hi\"", 0), "hi"))
$decl t23 $call check ("\\n and \\t decode",
  $call eq_str ($call text_at ("\"a\\nb\\tc\"", 0), "a\nb\tc"))
$decl t24 $call check ("\\\\ and \\\" decode",
  $call eq_str ($call text_at ("\"q\\\\\\\"\"", 0), "q\\\""))
$decl t25 $call check ("\\u{41} is A",
  $call eq_str ($call text_at ("\"\\u{41}\"", 0), "A"))
$decl t26 $call check ("\\u{…} handles a multi-byte code point",
  $call eq_str ($call text_at ("\"\\u{e9}\"", 0), "\u{e9}"))
$decl t27 $call check ("a surrogate is not a code point",
  $call eq_str ($call kind_at ("\"\\u{d800}\"", 0), "invalid"))
$decl t28 $call check ("an unknown escape is reported",
  $call eq_str ($call kind_at ("\"oops \\q\"", 0), "invalid"))
$decl t29 $call check ("an unterminated string is reported",
  $call eq_str ($call kind_at ("\"no close\nnext", 0), "invalid"))
$decl t30 $call check ("text outside the escape survives",
  $call eq_str ($call text_at ("\"pre\\npost\"", 0), "pre\npost"))

// Multi-byte input is fine even though this file is ASCII (BOOTSTRAP.md §4.6):
// runs between escapes are sliced whole, so no code point is ever split.
$decl t31 $call check ("a multi-byte string literal passes through",
  $call eq_int ($call len ($call text_at ("\"h\u{e9}llo\"", 0)), 6))

// Delimiters.
$decl t32 $call check ("parens and braces",
  $call eq_str ($call kind_at ("(a, b) {c}", 0), "lparen"))
$decl t33 $call check ("commas", $call eq_str ($call kind_at ("(a, b)", 2), "comma"))
$decl t34 $call check ("an unexpected character is invalid",
  $call eq_str ($call kind_at ("a @ b", 1), "invalid"))

// Line and column tracking.
$decl lc $call L.tokenize ("a\n  bb\n")
$decl t35 $call check ("the first token is at 1:1",
  $call eq_int (($call toks.nth (lc, 0)).line, 1))
$decl t36 $call check ("the second token is at 2:3",
  $call and ($call eq_int (($call toks.nth (lc, 1)).line, 2),
             $call eq_int (($call toks.nth (lc, 1)).col, 3)))
$decl t37 $call check ("eof is on the last line",
  $call eq_int (($call toks.nth (lc, 2)).line, 3))

// Lexing continues past an error, so one run surfaces several.
$decl t38 $call check ("several errors in one run",
  $call eq_int ($call L.count_kind ($call L.tokenize ("x.0 y.0 z.0"), "invalid", 0), 3))

// ------------------------------------------------- the one that actually matters
//
// Lexing its own source is the prerequisite for self-hosting: if this reports
// an `invalid` token, stage 1 cannot read stage 1.

$decl self_src $func ($decl p "")
  { $decl c $try ($call read_file (p)) none
    $decl out c.v }.out

$decl src $call self_src ("stage1/lexer.mpl")
$decl t39 $call check ("its own source is readable", $call not ($call eq_str (src, "")))

$decl self_toks $call L.tokenize (src)
$decl n_self  $call toks.length (self_toks, 0)
$decl n_bad   $call L.count_kind (self_toks, "invalid", 0)
$decl n_kw    $call L.count_kind (self_toks, "keyword", 0)
$decl n_str   $call L.count_kind (self_toks, "str", 0)

$decl r1 $call nl ($call concat ("      tokens in lexer.mpl: ", $call int_to_str (n_self)))
$decl r2 $call nl ($call concat ("      keywords: ", $call int_to_str (n_kw)))
$decl r3 $call nl ($call concat ("      strings:  ", $call int_to_str (n_str)))

$decl t40 $call check ("it lexes its own source with no invalid tokens",
  $call eq_int (n_bad, 0))
$decl t41 $call check ("its own source is more than a handful of tokens",
  $call lt (1000, n_self))

// The prelude too, since stage 1 has to read that as well.
$decl psrc $call self_src ("stage1/prelude.mpl")
$decl t42 $call check ("it lexes the prelude with no invalid tokens",
  $call eq_int ($call L.count_kind ($call L.tokenize (psrc), "invalid", 0), 0))

$decl done $call nl ("all lexer tests passed")
