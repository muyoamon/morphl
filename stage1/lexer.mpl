// Stage 1's lexer, written in morphl — BOOTSTRAP.md stage 1, step 1.
//
// Same job as lib/lexer/lexer.zig, but this one is the lexer that survives:
// stage 0's exists only to run this file. Two deliberate differences:
//
//   * **Keywords are not resolved here.** Stage 0 looks `$name` up in the
//     §2.2 table and reports unknown keywords. This lexer emits a `keyword`
//     token carrying its text and lets the parser resolve it, since the parser
//     must own the arity table anyway (§2.2 is what drives parsing). One table,
//     one owner.
//   * **Tokens are one uniform record**, not a tagged union. Prop tags are the
//     right tool where payload shapes genuinely differ per case and
//     exhaustiveness matters — the AST. A token always has a span, a line and a
//     column, and at most one payload, so a single shape with a `kind` string
//     costs less plumbing. §4.7 is explicit that dispatch on runtime *values*
//     is `$if` and `eq`, not `$match`, so this is in-idiom.
//
// Trivia (whitespace, `;`, both comment forms) is dropped here rather than
// emitted, exactly as in stage 0: §2.1 gives `;` no meaning, so no later stage
// should have to know it exists.

$decl P $import "prelude"

$decl not P.not
$decl and P.and
$decl or  P.or
$decl ival P.ival

// ---------------------------------------------------------------- characters
//
// There is no character literal in morphl (§3.1: a character is a
// one-code-point substring), so each code comes from `byte` on a one-character
// string. These are `$decl`, not `$prop`, because §4.10 forbids a `$call` in a
// prop initializer.

$decl c_tab    $call byte ("\t", 0)
$decl c_nl     $call byte ("\n", 0)
// §2.1 has exactly four single-character escapes — `\n \t \\ \"` — and CR is
// not among them, so it is spelled as the code point it is.
$decl c_cr     $call byte ("\u{d}", 0)
$decl c_space  $call byte (" ", 0)
$decl c_quote  $call byte ("\"", 0)
$decl c_dollar $call byte ("$", 0)
$decl c_dot    $call byte (".", 0)
$decl c_comma  $call byte (",", 0)
$decl c_lparen $call byte ("(", 0)
$decl c_rparen $call byte (")", 0)
$decl c_lbrace $call byte ("{", 0)
$decl c_rbrace $call byte ("}", 0)
$decl c_semi   $call byte (";", 0)
$decl c_slash  $call byte ("/", 0)
$decl c_star   $call byte ("*", 0)
$decl c_minus  $call byte ("-", 0)
$decl c_under  $call byte ("_", 0)
$decl c_bslash $call byte ("\\", 0)
$decl c_0      $call byte ("0", 0)
$decl c_9      $call byte ("9", 0)
$decl c_a      $call byte ("a", 0)
$decl c_f      $call byte ("f", 0)
$decl c_n      $call byte ("n", 0)
$decl c_t      $call byte ("t", 0)
$decl c_u      $call byte ("u", 0)
$decl c_z      $call byte ("z", 0)
$decl c_A      $call byte ("A", 0)
$decl c_F      $call byte ("F", 0)
$decl c_Z      $call byte ("Z", 0)

// The four escapes of §2.1 that are single characters. Stage 0's lexer decoded
// these when it read *this* file, so each is already the character itself.
$decl s_nl     "\n"
$decl s_tab    "\t"
$decl s_bslash "\\"
$decl s_quote  "\""

$decl in_range $func ($decl x 0, $decl lo 0, $decl hi 0)
  $call and ($call not ($call lt (x, lo)), $call not ($call lt (hi, x)))

$decl is_digit       $func ($decl ch 0) $call in_range (ch, c_0, c_9)
$decl is_lower       $func ($decl ch 0) $call in_range (ch, c_a, c_z)
$decl is_upper       $func ($decl ch 0) $call in_range (ch, c_A, c_Z)
$decl is_alpha       $func ($decl ch 0) $call or ($call is_lower (ch), $call is_upper (ch))

// §2.1: identifiers may not start with `$`, which is reserved for keywords.
$decl is_ident_start $func ($decl ch 0) $call or ($call is_alpha (ch), $call eq_int (ch, c_under))
$decl is_ident_cont  $func ($decl ch 0) $call or ($call is_ident_start (ch), $call is_digit (ch))

$decl is_space $func ($decl ch 0)
  $call or ($call eq_int (ch, c_space),
  $call or ($call eq_int (ch, c_tab),
  $call or ($call eq_int (ch, c_nl), $call eq_int (ch, c_cr))))

// -------------------------------------------------------------------- tokens

$decl token $func ($decl k "", $decl t "", $decl n 0, $decl l 0, $decl c 0)
  { $decl kind k  $decl text t  $decl num n  $decl line l  $decl col c }

$decl proto_token $call token ("eof", "", 0, 0, 0)
$decl toks $specialize P.list proto_token

$decl bad $func ($decl m "", $decl l 0, $decl c 0) $call token ("invalid", m, 0, l, c)

// -------------------------------------------------------------------- cursor
//
// A block of `$new` cells: the idiomatic mutable object. Copying the block
// copies its fields, and fields holding references still alias (§4.5), so
// passing the cursor around shares the same storage without any of it being
// implicit.

$decl cursor $func ($decl s "")
  { $decl src  s
    $decl pos  $mut $new 0
    $decl line $mut $new 1
    $decl col  $mut $new 1
    // Trivia scanning cannot return an error without breaking the tail
    // position that `scan` depends on, so it parks one here instead.
    $decl oops $mut $new "" }

$decl proto_cursor $call cursor ("")

$decl at_end $func ($decl cu proto_cursor)
  $call not ($call lt (cu.pos, $call len (cu.src)))

// -1 past the end, so classification never has to guard and strict `and`/`or`
// stay safe.
$decl peek_at $func ($decl cu proto_cursor, $decl k 0)
  { $decl i $call add (cu.pos, k)
    $decl out $if ($call lt (i, $call len (cu.src))) ($call byte (cu.src, i)) -1 }.out

$decl peek $func ($decl cu proto_cursor) $call peek_at (cu, 0)

$decl advance $func ($decl cu proto_cursor)
  { $decl ch $call peek (cu)
    $decl moved $if ($call eq_int (ch, c_nl))
        ($do ($set cu.line ($call add (cu.line, 1))) ($set cu.col 1))
        ($set cu.col ($call add (cu.col, 1)))
    $decl stepped $set cu.pos ($call add (cu.pos, 1)) }

// -------------------------------------------------------------------- trivia

$decl skip_line $func ($decl cu proto_cursor)
  $if ($call at_end (cu)) ()
  ($if ($call eq_int ($call peek (cu), c_nl)) ()
       ($do ($call advance (cu)) ($call skip_line (cu))))

// Non-nesting (§2.1): the first `*/` closes it. Called with `/*` consumed.
$decl skip_block $func ($decl cu proto_cursor)
  $if ($call at_end (cu)) ($set cu.oops "unterminated block comment")
  ($if ($call and ($call eq_int ($call peek (cu), c_star),
                   $call eq_int ($call peek_at (cu, 1), c_slash)))
       ($do ($call advance (cu)) ($call advance (cu)))
       ($do ($call advance (cu)) ($call skip_block (cu))))

$decl skip_trivia $func ($decl cu proto_cursor)
  $if ($call at_end (cu)) ()
  ($if ($call or ($call is_space ($call peek (cu)), $call eq_int ($call peek (cu), c_semi)))
       ($do ($call advance (cu)) ($call skip_trivia (cu)))
  ($if ($call and ($call eq_int ($call peek (cu), c_slash),
                   $call eq_int ($call peek_at (cu, 1), c_slash)))
       ($do ($call skip_line (cu)) ($call skip_trivia (cu)))
  ($if ($call and ($call eq_int ($call peek (cu), c_slash),
                   $call eq_int ($call peek_at (cu, 1), c_star)))
       ($do ($call advance (cu))
       ($do ($call advance (cu))
       ($do ($call skip_block (cu)) ($call skip_trivia (cu)))))
       ())))

// ------------------------------------------------------------------- scanning

$decl take_ident $func ($decl cu proto_cursor)
  $if ($call at_end (cu)) ()
  ($if ($call is_ident_cont ($call peek (cu)))
       ($do ($call advance (cu)) ($call take_ident (cu)))
       ())

$decl take_digits $func ($decl cu proto_cursor)
  $if ($call at_end (cu)) ()
  ($if ($call is_digit ($call peek (cu)))
       ($do ($call advance (cu)) ($call take_digits (cu)))
       ())

// `true` and `false` are literals, not keywords and not names (§2.1, §3.2).
$decl lex_name $func ($decl cu proto_cursor, $decl l 0, $decl c 0)
  { $decl start $call ival (cu.pos)
    $decl taken $call take_ident (cu)
    $decl text  $call slice (cu.src, start, cu.pos)
    $decl out $if ($call eq_str (text, "true"))  ($call token ("true", text, 0, l, c))
             ($if ($call eq_str (text, "false")) ($call token ("false", text, 0, l, c))
                  ($call token ("name", text, 0, l, c))) }.out

$decl lex_keyword $func ($decl cu proto_cursor, $decl l 0, $decl c 0)
  { $decl dollar $call advance (cu)
    $decl start  $call ival (cu.pos)
    $decl taken  $call take_ident (cu)
    $decl text   $call slice (cu.src, start, cu.pos)
    $decl out $if ($call eq_str (text, ""))
        ($call bad ("expected a keyword name after '$'", l, c))
        ($call token ("keyword", text, 0, l, c)) }.out

// A leading `-` belongs to the literal (§2.1); there are no infix operators
// for it to belong to.
$decl is_number_start $func ($decl cu proto_cursor, $decl ch 0)
  $call or ($call is_digit (ch),
            $call and ($call eq_int (ch, c_minus), $call is_digit ($call peek_at (cu, 1))))

// Float literals are kept as their source text: BOOTSTRAP.md §1.2 drops float
// arithmetic from the bootstrap, not float literals.
$decl lex_number $func ($decl cu proto_cursor, $decl l 0, $decl c 0)
  { $decl start $call ival (cu.pos)
    $decl sign  $if ($call eq_int ($call peek (cu), c_minus)) ($call advance (cu)) ()
    $decl whole $call take_digits (cu)
    // A `.` continues the number only when a digit follows, so `1.2` is a
    // float and `(a, b).1` is a projection.
    $decl is_float $call and ($call eq_int ($call peek (cu), c_dot),
                              $call is_digit ($call peek_at (cu, 1)))
    $decl out $if is_float
        { $decl dot   $call advance (cu)
          $decl frac  $call take_digits (cu)
          $decl text  $call slice (cu.src, start, cu.pos)
          $decl t     $call token ("float", text, 0, l, c) }.t
        { $decl text   $call slice (cu.src, start, cu.pos)
          $decl parsed $call str_to_int (text)
          $decl t $match parsed (
            $case {$prop tag "some"} $call token ("int", text, parsed.v, l, c),
            $case parsed ($call bad ($call concat ("integer literal does not fit in Int: ", text), l, c))
          ) }.t }.out

$decl lex_projection $func ($decl cu proto_cursor, $decl l 0, $decl c 0)
  { $decl dot   $call advance (cu)
    $decl start $call ival (cu.pos)
    $decl out $if ($call is_digit ($call peek (cu)))
        { $decl taken  $call take_digits (cu)
          $decl text   $call slice (cu.src, start, cu.pos)
          $decl parsed $call str_to_int (text)
          $decl t $match parsed (
            $case {$prop tag "some"}
              // §2.1: group indices are `.1`, `.2`, …
              $if ($call eq_int (parsed.v, 0))
                  ($call bad ("group indices start at .1, not .0", l, c))
                  ($call token ("proj_index", text, parsed.v, l, c)),
            $case parsed ($call bad ("group index is too large", l, c))
          ) }.t
        ($if ($call is_ident_start ($call peek (cu)))
            { $decl taken $call take_ident (cu)
              $decl text  $call slice (cu.src, start, cu.pos)
              $decl t     $call token ("proj_name", text, 0, l, c) }.t
            ($call bad ("expected a field name or group index after '.'", l, c))) }.out

// ------------------------------------------------------------ string literals

$decl escape_str $func ($decl ch 0)
  $if ($call eq_int (ch, c_n))      s_nl
  ($if ($call eq_int (ch, c_t))     s_tab
  ($if ($call eq_int (ch, c_bslash)) s_bslash
  ($if ($call eq_int (ch, c_quote))  s_quote "")))

$decl hex_val $func ($decl ch 0)
  $if ($call is_digit (ch))          ($call sub (ch, c_0))
  ($if ($call in_range (ch, c_a, c_f)) ($call add (10, $call sub (ch, c_a)))
  ($if ($call in_range (ch, c_A, c_F)) ($call add (10, $call sub (ch, c_A))) -1))

// Returns `(value, digit count)`.
$decl take_hex $func ($decl cu proto_cursor, $decl acc 0, $decl n 0)
  { $decl h $call hex_val ($call peek (cu))
    $decl out $if ($call lt (h, 0)) (acc, n)
        ($do ($call advance (cu))
             ($call take_hex (cu, $call add ($call mul (acc, 16), h), $call add (n, 1)))) }.out

$decl uni_fail $func ($decl m "") { $decl s ""  $decl msg m }

// `\u{…}`, with the `u` consumed. `from_code` is an addition to §8 — see
// BOOTSTRAP.md §7.
$decl lex_unicode $func ($decl cu proto_cursor)
  $if ($call not ($call eq_int ($call peek (cu), c_lbrace)))
      ($call uni_fail ("expected '{' after \\u"))
  { $decl open   $call advance (cu)
    $decl digits $call take_hex (cu, 0, 0)
    $decl out $if ($call eq_int (digits.2, 0)) ($call uni_fail ("'\\u{...}' needs at least one hex digit"))
        ($if ($call lt (6, digits.2))          ($call uni_fail ("'\\u{...}' takes at most 6 hex digits"))
        ($if ($call not ($call eq_int ($call peek (cu), c_rbrace)))
             ($call uni_fail ("expected '}' to close '\\u{'"))
        { $decl close $call advance (cu)
          $decl coded $call from_code (digits.1)
          $decl r $match coded (
            $case {$prop tag "some"} { $decl s coded.v  $decl msg "" },
            $case coded ($call uni_fail ("not a valid code point"))
          ) }.r )) }.out

// Accumulates whole runs between escapes rather than one byte at a time: a
// single byte of a multi-byte code point is not a valid `Str`, and §8's
// `slice` panics rather than let one be built (§3.1).
$decl scan_str $func ($decl cu proto_cursor, $decl acc "", $decl seg 0, $decl l 0, $decl c 0)
  // Refusing a raw newline keeps a missing close quote from swallowing the
  // rest of the file; the span stays on the opening quote.
  $if ($call or ($call at_end (cu), $call eq_int ($call peek (cu), c_nl)))
      ($call bad ("unterminated string literal", l, c))
  ($if ($call eq_int ($call peek (cu), c_quote))
      { $decl text  $call concat (acc, $call slice (cu.src, seg, cu.pos))
        $decl close $call advance (cu)
        $decl t     $call token ("str", text, 0, l, c) }.t
  ($if ($call eq_int ($call peek (cu), c_bslash))
      { $decl head $call concat (acc, $call slice (cu.src, seg, cu.pos))
        $decl slash $call advance (cu)
        $decl e     $call peek (cu)
        $decl t $if ($call eq_int (e, c_u))
            { $decl u $call advance (cu)
              $decl r $call lex_unicode (cu)
              $decl tt $if ($call eq_str (r.msg, ""))
                  ($call scan_str (cu, $call concat (head, r.s), $call ival (cu.pos), l, c))
                  ($call bad (r.msg, l, c)) }.tt
            { $decl s $call escape_str (e)
              $decl tt $if ($call eq_str (s, ""))
                  ($call bad ("unknown escape: morphl has \\n \\t \\\\ \\\" and \\u{...}", l, c))
                  ($do ($call advance (cu))
                       ($call scan_str (cu, $call concat (head, s), $call ival (cu.pos), l, c))) }.tt
        }.t
  ($do ($call advance (cu)) ($call scan_str (cu, acc, seg, l, c)))))

$decl lex_string $func ($decl cu proto_cursor, $decl l 0, $decl c 0)
  { $decl open $call advance (cu)
    $decl t    $call scan_str (cu, "", $call ival (cu.pos), l, c) }.t

$decl lex_simple $func ($decl cu proto_cursor, $decl ch 0, $decl l 0, $decl c 0)
  { $decl taken $call advance (cu)
    $decl out $if ($call eq_int (ch, c_lparen)) ($call token ("lparen", "(", 0, l, c))
             ($if ($call eq_int (ch, c_rparen)) ($call token ("rparen", ")", 0, l, c))
             ($if ($call eq_int (ch, c_lbrace)) ($call token ("lbrace", "{", 0, l, c))
             ($if ($call eq_int (ch, c_rbrace)) ($call token ("rbrace", "}", 0, l, c))
             ($if ($call eq_int (ch, c_comma))  ($call token ("comma",  ",", 0, l, c))
                  ($call bad ("unexpected character", l, c)))))) }.out

$decl next_token $func ($decl cu proto_cursor)
  { $decl l  $call ival (cu.line)
    $decl c  $call ival (cu.col)
    $decl ch $call peek (cu)
    $decl out $if ($call is_ident_start (ch))          ($call lex_name (cu, l, c))
             ($if ($call eq_int (ch, c_dollar))        ($call lex_keyword (cu, l, c))
             ($if ($call eq_int (ch, c_quote))         ($call lex_string (cu, l, c))
             ($if ($call eq_int (ch, c_dot))           ($call lex_projection (cu, l, c))
             ($if ($call is_number_start (cu, ch))     ($call lex_number (cu, l, c))
                  ($call lex_simple (cu, ch, l, c)))))) }.out

// Written without an enclosing block so the recursive call stays in tail
// position (§7.7): the body is a `$do`, whose second operand is tail, and
// `$if` arms in tail position are tail. A block here would make every token
// cost a stack frame.
$decl scan $func ($decl cu proto_cursor, $decl acc toks.node)
  $do ($call skip_trivia (cu))
      ($if ($call not ($call eq_str (cu.oops, "")))
           ($call toks.cons ($call bad (cu.oops, cu.line, cu.col), acc))
           ($if ($call at_end (cu))
                ($call toks.cons ($call token ("eof", "", 0, cu.line, cu.col), acc))
                ($call scan (cu, $call toks.cons ($call next_token (cu), acc)))))

$decl tokenize $func ($decl s "")
  { $decl cu  $call cursor (s)
    $decl rev $call scan (cu, toks.nil)
    $decl out $call toks.reverse (rev, toks.nil) }.out

// Lexing never stops at the first error: a bad token is reported as `invalid`
// and scanning continues, so one run surfaces several mistakes.
$decl count_kind $func ($decl xs toks.node, $decl k "", $decl acc 0) $match xs (
  $case {$prop tag "cons"}
    $call count_kind (xs.tail, k,
      $if ($call eq_str (xs.head.kind, k)) ($call add (acc, 1)) acc),
  $case xs acc
)
